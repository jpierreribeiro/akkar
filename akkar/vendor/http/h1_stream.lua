local cqueues = require "cqueues"
local monotime = cqueues.monotime
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local new_fifo = require "fifo"
local lpeg = require "lpeg"
local http_patts = require "lpeg_patterns.http"
local new_headers = require "akkar.vendor.http.headers".new
local reason_phrases = require "akkar.vendor.http.h1_reason_phrases"
local stream_common = require "akkar.vendor.http.stream_common"
local util = require "akkar.vendor.http.util"
-- Vendored, like everything else in this directory. This line said
-- `http.zlib` until the namespace rewrite missed it, because it is the one
-- require in the file that is not resolved at load: it reaches into the
-- upstream rock we no longer depend on, so it silently answered "no zlib"
-- for an installed copy of akkar and "upstream's zlib" for a development
-- one. Two different behaviours from the same source is worse than either.
local has_zlib, zlib = pcall(require, "akkar.vendor.http.zlib")

--[[ Maximum amount of data to read during shutdown before giving up on a clean stream shutdown
500KB seems is a round number that is:
  - larger than most bandwidth-delay products
  - larger than most dynamically generated http documents]]
local clean_shutdown_limit = 500*1024

local EOF = lpeg.P(-1)
local Connection = lpeg.Ct(http_patts.Connection) * EOF
local Content_Encoding = lpeg.Ct(http_patts.Content_Encoding) * EOF
local Transfer_Encoding = lpeg.Ct(http_patts.Transfer_Encoding) * EOF
local TE = lpeg.Ct(http_patts.TE) * EOF

local function has(list, val)
	if list then
		for i=1, #list do
			if list[i] == val then
				return true
			end
		end
	end
	return false
end

local function has_any(list, val, ...)
	if has(list, val) then
		return true
	elseif (...) then
		return has(list, ...)
	else
		return false
	end
end

local stream_methods = {
	use_zlib = has_zlib;
	max_header_lines = 100;
}
for k,v in pairs(stream_common.methods) do
	stream_methods[k] = v
end
local stream_mt = {
	__name = "http.h1_stream";
	__index = stream_methods;
}

function stream_mt:__tostring()
	return string.format("http.h1_stream{connection=%s;state=%q}",
		tostring(self.connection), self.state)
end

-- TWO CONDITIONS THAT NOBODY COULD EVER WAIT ON.
--
-- `headers_cond` and `chunk_cond` were created here per stream -- so per
-- request, in HTTP/1.1 -- and signalled in five places. Nothing in lua-http
-- ever waited on either of them, and that is not an artefact of vendoring:
-- upstream's own h1_stream signals them and never polls them either. Only
-- `h2_stream` has real waiters (`cqueues.poll(self.chunk_cond, ...)`), and
-- h2 went when this half was vendored.
--
-- h1 does not need them by construction. A connection reads in one coroutine
-- and a stream is served by that same coroutine, so there is no second party
-- to wake: `get_next_chunk` looks in the fifo and, finding it empty, reads
-- the socket itself.
--
-- Removed rather than kept "in case": a condition object per request that can
-- have no waiter is not a hook, it is a cost. If h1 ever grows a concurrent
-- reader, it will need a condition designed for that reader.
local function new_stream(connection)
	local self = setmetatable({
		connection = connection;
		type = connection.type;

		state = "idle";
		stats_sent = 0;
		stats_recv = 0;

		pipeline_cond = cc.new(); -- signalled when stream reaches front of pipeline

		has_main_headers = false;
		headers_fifo = new_fifo();
		-- `chunk_fifo` IS NOT HERE. It is built by `queue_chunk` below, on the
		-- first chunk that is actually read ahead -- which for a GET with no
		-- body never happens, and a GET with no body is what this runtime
		-- mostly serves. Measured: a fifo is 265 bytes.
		--
		-- `headers_fifo` stays eager because every request uses it: `step`
		-- pushes the main headers into it and `read_headers` pops them, on
		-- the ordinary path, so making it lazy would trade an allocation for
		-- a branch and save nothing.

		-- THE FIELDS THAT USED TO BE HERE SET TO nil ARE DOCUMENTED BELOW
		-- INSTEAD, and the difference is 384 bytes on every request.
		--
		-- `k = nil` in a constructor stores nothing, but Lua sizes the hash
		-- part from the SYNTACTIC key count, so ten documentation fields
		-- reserved ten slots that held nothing and pushed the table from 16
		-- to 32. Measured directly, 20,000 tables each way:
		--
		--     9 real keys + 10 nil keys   850 bytes
		--     9 real keys                 466 bytes
		--
		-- The nine that remain plus the seven a served request actually
		-- assigns come to sixteen, which is exactly what a 16-slot hash
		-- holds -- so this trades a permanent 384 bytes for a rehash that
		-- does not happen. That is a claim, and the allocation harness
		-- checked it: 14,450 -> 14,070 bytes per request, byte-identical
		-- across three runs. A rehash would have shown up as no change or
		-- as worse.
		--
		--   req_method                   string
		--   peer_version                 1.0 or 1.1
		--   headers_in_progress          headers being parsed
		--   body_write_type              "closed", "chunked", "length", "missing"
		--   body_write_left              integer; only when type == "length"
		--   body_write_deflate_encoding  string
		--   body_write_deflate           stateful deflate closure
		--   body_read_type               as body_write_type
		--   body_read_inflate            stateful inflate closure
		--   close_when_done              boolean
	}, stream_mt)
	return self
end

local valid_states = {
	["idle"] = 1; -- initial
	["open"] = 2; -- have sent or received headers; haven't sent body yet
	["half closed (local)"] = 3; -- have sent whole body
	["half closed (remote)"] = 3; -- have received whole body
	["closed"] = 4; -- complete
}
function stream_methods:set_state(new)
	local new_order = assert(valid_states[new])
	local old = self.state
	if new_order <= valid_states[old] then
		error("invalid state progression ('"..old.."' to '"..new.."')")
	end
	local have_lock, want_no_lock
	local blocking_pipeline, notify_pipeline
	if self.type == "server" then
		-- If we have just finished reading the request then remove our read lock
		have_lock = old == "idle" or old == "open" or old == "half closed (local)"
		want_no_lock = new == "half closed (remote)" or new == "closed"
		-- If we have just finished writing the response
		blocking_pipeline = old == "idle" or old == "open" or old == "half closed (remote)"
		notify_pipeline = blocking_pipeline and (new == "half closed (local)" or new == "closed")
	else -- client
		-- If we have just finished writing the request then remove our write lock
		have_lock = old == "open" or old == "half closed (remote)"
		want_no_lock = new == "half closed (local)" or new == "closed"
		-- If we have just finished reading the response;
		blocking_pipeline = old == "idle" or old == "open" or old == "half closed (local)"
		notify_pipeline = blocking_pipeline and (new == "half closed (remote)" or new == "closed")
	end
	self.state = new
	if have_lock then
		assert(self.connection.req_locked == self)
		if want_no_lock then
			self.connection.req_locked = nil
			self.connection.req_cond:signal(1)
		end
	end
	local pipeline_empty
	if notify_pipeline then
		assert(self.connection.pipeline:pop() == self)
		local next_stream = self.connection.pipeline:peek()
		if next_stream then
			pipeline_empty = false
			next_stream.pipeline_cond:signal()
		else
			pipeline_empty = true
		end
	else
		pipeline_empty = not blocking_pipeline
	end
	if self.close_when_done then
		if new == "half closed (remote)" then
			self.connection:shutdown("r")
		elseif new == "half closed (local)" and self.type == "server" then
			-- NOTE: Do not shutdown("w") the socket when a client moves to
			-- "half closed (local)", many servers will close a connection
			-- immediately if a client closes their write stream
			self.connection:shutdown("w")
		elseif new == "closed" then
			self.connection:shutdown()
		end
	end
	if want_no_lock and pipeline_empty then
		self.connection:onidle()(self.connection)
	end
end

local bad_request_headers = new_headers()
bad_request_headers:append(":status", "400")
local server_error_headers = new_headers()
server_error_headers:append(":status", "503")
function stream_methods:shutdown()
	if self.state == "idle" then
		self:set_state("closed")
	else
		if self.type == "server" and (self.state == "open" or self.state == "half closed (remote)") then
			-- Make sure we're at the front of the pipeline
			if self.connection.pipeline:peek() ~= self then
				-- FIXME: shouldn't have time-taking operation here
				self.pipeline_cond:wait() -- wait without a timeout should never fail
				assert(self.connection.pipeline:peek() == self)
			end
			if not self.body_write_type then
				-- Can send an automatic error response
				local error_headers
				if self.connection:error("r") == ce.EILSEQ then
					error_headers = bad_request_headers
				else
					error_headers = server_error_headers
				end
				self:write_headers(error_headers, true, 0)
			end
		end
		-- read any remaining available response and get out of the way
		--
		-- AKKAR: two denial-of-service repairs live in this loop. THE EIGHT
		-- LINES BELOW ARE NOT UPSTREAM'S -- do not "simplify" them back to the
		-- original two conditions, which is the defect.
		--
		-- `docs/substrate/lua-http-wedge.md` is the whole account: the
		-- reproduction, the measurements taken off a running process, the two
		-- obvious repairs that do not work, and why the idle limit is eight.
		-- Its "Where the repair lives, and where it used to live" section
		-- records the history -- these were monkey-patches in a now-deleted
		-- `akkar/substrate.lua` until this file was vendored, and folding them
		-- in is most of why it was vendored. Sixty lines of instance
		-- overrides, `rawset` juggling and defensive shape checks became the
		-- eight below, and they can no longer silently stop applying when this
		-- file changes shape.
		--
		-- `spec/substrate_repair_spec.lua` is the proof: it swaps this module
		-- for the upstream rock's and requires that server to die.
		--
		-- ONE: the spin. `step(0)` can return true -- "I did something" --
		-- while `stats_recv` never advances, and then neither condition of
		-- this loop ever goes false and the coroutine burns a core for ever.
		-- One header is enough to trigger it. Eight idle steps is the limit:
		-- one would do, since the wedge produces them without limit, but a
		-- healthy stream against a slow peer can legitimately answer "nothing
		-- right now" once or twice, and being generous costs microseconds on a
		-- path that is already tearing the connection down.
		--
		-- TWO: the raise. `Content-Length: -5` sets `body_read_left = -5`, and
		-- `read_next_chunk` answers that with a bare `error("invalid length")`.
		-- `handle_stream` in server.lua calls `shutdown` with no pcall around
		-- it, so the error leaves the coroutine, `cq:loop()` returns it, and
		-- the whole server loop exits -- one malformed header ends the
		-- process. Shutting a connection down is cleanup, and cleanup that
		-- raises has nothing useful to say.
		local start = self.stats_recv
		local seen = start   -- the most bytes any step has reported so far
		local idle = 0       -- consecutive steps that reported no new bytes
		while (self.state == "open" or self.state == "half closed (local)") and (self.stats_recv - start) < clean_shutdown_limit do
			local ok, advanced = pcall(self.step, self, 0)
			if not ok or not advanced then
				break
			end
			if self.stats_recv > seen then
				seen, idle = self.stats_recv, 0
			else
				idle = idle + 1
				if idle > 8 then
					break
				end
			end
		end

		if self.state ~= "closed" then
			-- This is a bad situation: we are trying to shutdown a connection that has the body partially sent
			-- Especially in the case of Connection: close, where closing indicates EOF,
			-- this will result in a client only getting a partial response.
			-- Could also end up here if a client sending headers fails.
			if self.connection.socket then
				self.connection.socket:shutdown()
			end
			self:set_state("closed")
		end
	end
	return true
end

function stream_methods:step(timeout)
	if self.state == "open" or self.state == "half closed (local)" or (self.state == "idle" and self.type == "server") then
		if self.connection.socket == nil then
			return nil, ce.strerror(ce.EPIPE), ce.EPIPE
		end
		if not self.has_main_headers then
			local headers, err, errno = self:read_headers(timeout)
			if headers == nil then
				return nil, err, errno
			end
			self.headers_fifo:push(headers)
			return true
		end
		if self.body_read_left ~= 0 then
			local chunk, err, errno = self:read_next_chunk(timeout)
			if chunk == nil then
				if err == nil then
					return true
				end
				return nil, err, errno
			end
			self:queue_chunk(chunk)
			return true
		end
		if self.body_read_type == "chunked" then
			local trailers, err, errno = self:read_headers(timeout)
			if trailers == nil then
				return nil, err, errno
			end
			self.headers_fifo:push(trailers)
			return true
		end
	end
	if self.state == "half closed (remote)" then
		return nil, ce.strerror(ce.EIO), ce.EIO
	end
	return true
end

-- read_headers may be called more than once for a stream
-- e.g. for 100 Continue
-- this function *should never throw* under normal operation
function stream_methods:read_headers(timeout)
	local deadline = timeout and (monotime()+timeout)
	if self.state == "closed" or self.state == "half closed (remote)" then
		return nil
	end
	local status_code
	local is_trailers = self.body_read_type == "chunked"
	local headers = self.headers_in_progress
	if not headers then
		if is_trailers then
			headers = new_headers()
		elseif self.type == "server" then
			if self.state == "half closed (local)" then
				return nil
			end
			local method, target, httpversion = self.connection:read_request_line(0)
			if method == nil then
				if httpversion == ce.ETIMEDOUT then
					timeout = deadline and deadline-monotime()
					if cqueues.poll(self.connection.socket, timeout) ~= timeout then
						return self:read_headers(deadline and deadline-monotime())
					end
				end
				return nil, target, httpversion
			end
			self.req_method = method
			self.peer_version = httpversion
			headers = new_headers()
			headers:append(":method", method)
			if method == "CONNECT" then
				headers:append(":authority", target)
			else
				headers:append(":path", target)
			end
			headers:append(":scheme", self:checktls() and "https" or "http")
			self:set_state("open")
		else -- client
			-- Make sure we're at front of connection pipeline
			if self.connection.pipeline:peek() ~= self then
				assert(cqueues.running(), "cannot wait for condition if not within a cqueues coroutine")
				if cqueues.poll(self.pipeline_cond, timeout) == timeout then
					return nil, ce.strerror(ce.ETIMEDOUT), ce.ETIMEDOUT
				end
				assert(self.connection.pipeline:peek() == self)
			end
			local httpversion, reason_phrase
			httpversion, status_code, reason_phrase = self.connection:read_status_line(0)
			if httpversion == nil then
				if reason_phrase == ce.ETIMEDOUT then
					timeout = deadline and deadline-monotime()
					if cqueues.poll(self.connection.socket, timeout) ~= timeout then
						return self:read_headers(deadline and deadline-monotime())
					end
				elseif status_code == nil then
					return nil, ce.strerror(ce.EPIPE), ce.EPIPE
				end
				return nil, status_code, reason_phrase
			end
			self.peer_version = httpversion
			headers = new_headers()
			headers:append(":status", status_code)
			-- reason phase intentionally does not exist in HTTP2; discard for consistency
		end
		self.headers_in_progress = headers
	else
		if not is_trailers and self.type == "client" then
			status_code = headers:get(":status")
		end
	end

	-- Use while loop for lua 5.1 compatibility
	while true do
		if headers:len() >= self.max_header_lines then
			return nil, ce.strerror(ce.E2BIG), ce.E2BIG
		end
		local k, v, errno = self.connection:read_header(0)
		if k == nil then
			if v ~= nil then
				if errno == ce.ETIMEDOUT then
					timeout = deadline and deadline-monotime()
					if cqueues.poll(self.connection.socket, timeout) ~= timeout then
						return self:read_headers(deadline and deadline-monotime())
					end
				end
				return nil, v, errno
			end
			break -- Success: End of headers.
		end
		k = k:lower() -- normalise to lower case
		if k == "host" and not is_trailers then
			k = ":authority"
		end
		headers:append(k, v)
	end

	do
		local ok, err, errno = self.connection:read_headers_done(0)
		if ok == nil then
			if errno == ce.ETIMEDOUT then
				timeout = deadline and deadline-monotime()
				if cqueues.poll(self.connection.socket, timeout) ~= timeout then
					return self:read_headers(deadline and deadline-monotime())
				end
			elseif err == nil then
				return nil, ce.strerror(ce.EPIPE), ce.EPIPE
			end
			return nil, err, errno
		end
		self.headers_in_progress = nil
		self.has_main_headers = status_code == nil or status_code:sub(1,1) ~= "1" or status_code == "101"
	end

	do -- if client is sends `Connection: close`, server knows it can close at end of response
		local h = headers:get_comma_separated("connection")
		if h then
			local connection_header = Connection:match(h)
			if connection_header and has(connection_header, "close") then
				self.close_when_done = true
			end
		end
	end

	-- Now guess if there's a body...
	-- RFC 7230 Section 3.3.3
	local no_body
	if is_trailers then
		-- there cannot be a body after trailers
		no_body = true
	elseif self.type == "client" and (
		self.req_method == "HEAD"
		or status_code == "204"
		or status_code == "304"
	) then
		no_body = true
	elseif self.type == "client" and (
		status_code:sub(1,1) == "1"
	) then
		-- note: different to spec:
		-- we don't want to go into body reading mode;
		-- we want to stay in header modes
		no_body = false
		if status_code == "101" then
			self.body_read_type = "close"
		end
	elseif headers:has("transfer-encoding") then
		no_body = false
		local transfer_encoding = Transfer_Encoding:match(headers:get_comma_separated("transfer-encoding"))
		local n = #transfer_encoding
		local last_transfer_encoding = transfer_encoding[n][1]
		if last_transfer_encoding == "chunked" then
			self.body_read_type = "chunked"
			n = n - 1
			if n == 0 then
				last_transfer_encoding = nil
			else
				last_transfer_encoding = transfer_encoding[n][1]
			end
		else
			self.body_read_type = "close"
		end
		if last_transfer_encoding == "gzip" or last_transfer_encoding == "deflate" or last_transfer_encoding == "x-gzip" then
			self.body_read_inflate = zlib.inflate()
			n = n - 1
		end
		if n > 0 then
			return nil, "unknown transfer-encoding"
		end
	elseif headers:has("content-length") then
		local cl = tonumber(headers:get("content-length"), 10)
		if cl == nil then
			return nil, "invalid content-length"
		end
		if cl == 0 then
			no_body = true
		else
			no_body = false
			self.body_read_type = "length"
			self.body_read_left = cl
		end
	elseif self.type == "server" then
		-- A request defaults to no body
		no_body = true
	else -- client
		no_body = false
		self.body_read_type = "close"
	end
	if self.use_zlib and self.type == "server" and self.state == "open" and not is_trailers and headers:has("te") then
		local te = TE:match(headers:get_comma_separated("te"))
		for _, v in ipairs(te) do
			local tcoding = v[1]
			if (tcoding == "gzip" or tcoding == "x-gzip" or tcoding == "deflate") and v.q ~= 0 then
				v.q = nil
				self.body_write_deflate_encoding = v
				self.body_write_deflate = zlib.deflate()
				break
			end
		end
	end
	if no_body then
		if self.state == "open" then
			self:set_state("half closed (remote)")
		else -- self.state == "half closed (local)"
			self:set_state("closed")
		end
	end
	return headers
end

function stream_methods:get_headers(timeout)
	if self.headers_fifo:length() > 0 then
		return self.headers_fifo:pop()
	else
		if self.state == "closed" or self.state == "half closed (remote)" then
			return nil
		end
		local deadline = timeout and monotime()+timeout
		local ok, err, errno = self:step(timeout)
		if not ok then
			return nil, err, errno
		end
		return self:get_headers(deadline and deadline-monotime())
	end
end

local ignore_fields = {
	[":authority"] = true;
	[":method"] = true;
	[":path"] = true;
	[":scheme"] = true;
	[":status"] = true;
	[":protocol"] = true; -- from RFC 8441
	-- fields written manually in :write_headers
	["connection"] = true;
	["content-length"] = true;
	["transfer-encoding"] = true;
}
-- Writes the given headers to the stream; optionally ends the stream at end of headers
--
-- We're free to insert any of the "Hop-by-hop" headers (as listed in RFC 2616 Section 13.5.1)
-- Do this by directly writing the headers, rather than adding them to the passed headers object,
-- as we don't want to modify the caller owned object.
-- Note from RFC 7230 Appendix 2:
--     "hop-by-hop" header fields are required to appear in the Connection header field;
--     just because they're defined as hop-by-hop doesn't exempt them.
function stream_methods:write_headers(headers, end_stream, timeout)
	local deadline = timeout and (monotime()+timeout)
	assert(headers, "missing argument: headers")
	-- Validate up front
	local connection_header do
		local h = headers:get_comma_separated("connection")
		if h then
			connection_header = Connection:match(h)
			if not connection_header then
				error("invalid connection header")
			end
		else
			connection_header = {}
		end
	end
	local transfer_encoding_header do
		local h = headers:get_comma_separated("transfer-encoding")
		if h then
			transfer_encoding_header = Transfer_Encoding:match(h)
			if not transfer_encoding_header then
				error("invalid transfer-encoding header")
			end
		end
	end
	assert(type(end_stream) == "boolean", "'end_stream' MUST be a boolean")
	if self.state == "closed" or self.state == "half closed (local)" or self.connection.socket == nil then
		return nil, ce.strerror(ce.EPIPE), ce.EPIPE
	end
	local status_code, method
	local is_trailers
	if self.body_write_type == "chunked" then
		-- we are writing trailers; close off body
		is_trailers = true
		local ok, err, errno = self.connection:write_body_last_chunk(nil, 0)
		if not ok then
			return nil, err, errno
		end
	elseif self.type == "server" then
		if self.state == "idle" then
			error("cannot write headers when stream is idle")
		end
		status_code = headers:get(":status")
		-- RFC 7231 Section 6.2:
		-- Since HTTP/1.0 did not define any 1xx status codes, a server MUST NOT send a 1xx response to an HTTP/1.0 client.
		if status_code and status_code:sub(1,1) == "1" and self.peer_version < 1.1 then
			error("a server MUST NOT send a 1xx response to an HTTP/1.0 client")
		end
		-- Make sure we're at the front of the pipeline
		if self.connection.pipeline:peek() ~= self then
			assert(cqueues.running(), "cannot wait for condition if not within a cqueues coroutine")
			headers = headers:clone() -- don't want user to edit it and send wrong headers
			if cqueues.poll(self.pipeline_cond, timeout) == timeout then
				return nil, ce.strerror(ce.ETIMEDOUT), ce.ETIMEDOUT
			end
			assert(self.connection.pipeline:peek() == self)
		end
		if status_code then
			-- Should send status line
			local reason_phrase = reason_phrases[status_code]
			local version = math.min(self.connection.version, self.peer_version)
			local ok, err, errno = self.connection:write_status_line(version, status_code, reason_phrase, 0)
			if not ok then
				return nil, err, errno
			end
		end
	else -- client
		if self.state == "idle" then
			method = assert(headers:get(":method"), "missing method")
			self.req_method = method
			local target
			if method == "CONNECT" then
				target = assert(headers:get(":authority"), "missing authority")
				assert(not headers:has(":path"), "CONNECT requests should not have a path")
			else
				-- RFC 7230 Section 5.4: A client MUST send a Host header field in all HTTP/1.1 request messages.
				assert(self.connection.version < 1.1 or headers:has(":authority"), "missing authority")
				target = assert(headers:get(":path"), "missing path")
			end
			if self.connection.req_locked then
				-- Wait until previous request has been fully written
				assert(cqueues.running(), "cannot wait for condition if not within a cqueues coroutine")
				headers = headers:clone() -- don't want user to edit it and send wrong headers
				if cqueues.poll(self.connection.req_cond, timeout) == timeout then
					return nil, ce.strerror(ce.ETIMEDOUT), ce.ETIMEDOUT
				end
				assert(self.connection.req_locked == nil)
			end
			self.connection.pipeline:push(self)
			self.connection.req_locked = self
			-- write request line
			local ok, err, errno = self.connection:write_request_line(method, target, self.connection.version, 0)
			if not ok then
				return nil, err, errno
			end
			self:set_state("open")
		else
			assert(self.state == "open")
		end
	end

	local cl = headers:get("content-length") -- ignore subsequent content-length values
	local add_te_gzip = false
	if self.req_method == "CONNECT" and (self.type == "client" or status_code == "200") then
		-- successful CONNECT requests always continue until the connection is closed
		self.body_write_type = "close"
		self.close_when_done = true
		if self.type == "server" and (cl or transfer_encoding_header) then
			-- RFC 7231 Section 4.3.6:
			-- A server MUST NOT send any Transfer-Encoding or Content-Length header
			-- fields in a 2xx (Successful) response to CONNECT.
			error("Content-Length and Transfer-Encoding not allowed with successful CONNECT response")
		end
	elseif self.type == "server" and status_code and status_code:sub(1, 1) == "1" then
		assert(not end_stream, "cannot end stream directly after 1xx status code")
		-- A server MUST NOT send a Content-Length header field in any response
		-- with a status code of 1xx (Informational) or 204 (No Content)
		if cl then
			error("Content-Length not allowed in response with 1xx status code")
		end
		if status_code == "101" then
			self.body_write_type = "switched protocol"
		end
	elseif not self.body_write_type then -- only figure out how to send the body if we haven't figured it out yet... TODO: use better check
		if self.close_when_done == nil then
			if self.connection.version == 1.0 or (self.type == "server" and self.peer_version == 1.0) then
				self.close_when_done = not has(connection_header, "keep-alive")
			else
				self.close_when_done = has(connection_header, "close")
			end
		end
		if cl then
			-- RFC 7230 Section 3.3.2:
			-- A sender MUST NOT send a Content-Length header field in any
			-- message that contains a Transfer-Encoding header field.
			if transfer_encoding_header then
				error("Content-Length not allowed in message with a transfer-encoding")
			elseif self.type == "server" then
				-- A server MUST NOT send a Content-Length header field in any response
				-- with a status code of 1xx (Informational) or 204 (No Content)
				if status_code == "204" then
					error("Content-Length not allowed in response with 204 status code")
				end
			end
		end
		if end_stream then
			-- Make sure 'end_stream' is respected
			if self.type == "server" and (self.req_method == "HEAD" or status_code == "304") then
				self.body_write_type = "missing"
			elseif transfer_encoding_header then
				if transfer_encoding_header[#transfer_encoding_header][1] == "chunked" then
					-- Set body type to chunked so that we know how to end the stream
					self.body_write_type = "chunked"
				else
					error("unknown transfer-encoding")
				end
			else
				-- By adding `content-length: 0` we can be sure that our peer won't wait for a body
				-- This is somewhat suggested in RFC 7231 section 8.1.2
				if cl then -- might already have content-length: 0
					assert(cl:match("^ *0+ *$"), "cannot end stream after headers if you have a non-zero content-length")
				elseif self.type ~= "client" or (method ~= "GET" and method ~= "HEAD") then
					cl = "0"
				end
				self.body_write_type = "length"
				self.body_write_left = 0
			end
		else
			-- The order of these checks matter:
				-- chunked must be checked first, as it totally changes the body format
				-- content-length is next
				-- closing the connection is ordered after length
					-- this potentially means an early EOF can be caught if a connection
					-- closure occurs before body size reaches the specified length
				-- for HTTP/1.1, we can fall-back to a chunked encoding
					-- chunked is mandatory to implement in HTTP/1.1
					-- this requires amending the transfer-encoding header
				-- for an HTTP/1.0 server, we fall-back to closing the connection at the end of the stream
				-- else is an HTTP/1.0 client with `connection: keep-alive` but no other header indicating the body form.
					-- this cannot be reasonably handled, so throw an error.
			if transfer_encoding_header and transfer_encoding_header[#transfer_encoding_header][1] == "chunked" then
				self.body_write_type = "chunked"
			elseif cl then
				self.body_write_type = "length"
				self.body_write_left = assert(tonumber(cl, 10), "invalid content-length")
			elseif self.close_when_done then -- ordered after length delimited
				self.body_write_type = "close"
			elseif self.connection.version == 1.1 and (self.type == "client" or self.peer_version == 1.1) then
				self.body_write_type = "chunked"
				-- transfer-encodings are ordered. we need to make sure we place "chunked" last
				if not transfer_encoding_header then
					transfer_encoding_header = {nil} -- preallocate
				end
				table.insert(transfer_encoding_header, {"chunked"})
			elseif self.type == "server" then
				-- default for servers if they don't send a particular header
				self.body_write_type = "close"
				self.close_when_done = true
			else
				error("a client cannot send a body with connection: keep-alive without indicating body delimiter in headers")
			end
		end
		-- Add 'Connection: close' header if we're going to close after
		if self.close_when_done and not has(connection_header, "close") then
			table.insert(connection_header, "close")
		end
		if self.use_zlib then
			if self.type == "client" then
				-- If we support zlib; add a "te" header indicating we support the gzip transfer-encoding
				add_te_gzip = true
			else -- server
				-- Whether to use transfer-encoding: gzip
				if self.body_write_deflate -- only use if client sent the TE header allowing it
					and not cl -- not allowed to use both content-length *and* transfer-encoding
					and not end_stream -- no point encoding body if there isn't one
					and not has_any(Content_Encoding:match(headers:get_comma_separated("content-encoding") or ""), "gzip", "x-gzip", "deflate")
					-- don't bother if content-encoding is already gzip/deflate
					-- TODO: need to take care of quality suffixes ("deflate; q=0.5")
				then
					if transfer_encoding_header then
						local n = #transfer_encoding_header
						-- Possibly need to insert before "chunked"
						if transfer_encoding_header[n][1] == "chunked" then
							transfer_encoding_header[n+1] = transfer_encoding_header[n]
							transfer_encoding_header[n] = self.body_write_deflate_encoding
						else
							transfer_encoding_header[n+1] = self.body_write_deflate_encoding
						end
					else
						transfer_encoding_header = {self.body_write_deflate_encoding}
					end
				else
					-- discard the encoding context (if there was one)
					self.body_write_deflate_encoding = nil
					self.body_write_deflate = nil
				end
			end
		end
	end

	for name, value in headers:each() do
		if not ignore_fields[name] then
			local ok, err, errno = self.connection:write_header(name, value, 0)
			if not ok then
				return nil, err, errno
			end
		elseif name == ":authority" then
			-- for CONNECT requests, :authority is the path
			if self.req_method ~= "CONNECT" then
				-- otherwise it's the Host header
				local ok, err, errno = self.connection:write_header("host", value, 0)
				if not ok then
					return nil, err, errno
				end
			end
		end
	end

	if add_te_gzip then
		-- Doesn't matter if it gets added more than once.
		if not has(connection_header, "te") then
			table.insert(connection_header, "te")
		end
		local ok, err, errno = self.connection:write_header("te", "gzip, deflate", 0)
		if not ok then
			return nil, err, errno
		end
	end
	-- Write transfer-encoding, content-length and connection headers separately
	if transfer_encoding_header and transfer_encoding_header[1] then
		-- Add to connection header
		if not has(connection_header, "transfer-encoding") then
			table.insert(connection_header, "transfer-encoding")
		end
		local value = {}
		for i, v in ipairs(transfer_encoding_header) do
			local params = {v[1]}
			for k, vv in pairs(v) do
				if type(k) == "string" then
					params[#params+1] = k .. "=" .. util.maybe_quote(vv)
				end
			end
			value[i] = table.concat(params, ";")
		end
		value = table.concat(value, ",")
		local ok, err, errno = self.connection:write_header("transfer-encoding", value, 0)
		if not ok then
			return nil, err, errno
		end
	elseif cl then
		local ok, err, errno = self.connection:write_header("content-length", cl, 0)
		if not ok then
			return nil, err, errno
		end
	end
	if connection_header and connection_header[1] then
		local value = table.concat(connection_header, ",")
		local ok, err, errno = self.connection:write_header("connection", value, 0)
		if not ok then
			return nil, err, errno
		end
	end

	do
		local ok, err, errno = self.connection:write_headers_done(deadline and (deadline-monotime()))
		if not ok then
			return nil, err, errno
		end
	end

	if end_stream then
		if is_trailers then
			if self.state == "half closed (remote)" then
				self:set_state("closed")
			else
				self:set_state("half closed (local)")
			end
		else
			local ok, err, errno = self:write_chunk("", true)
			if not ok then
				return nil, err, errno
			end
		end
	end

	return true
end

function stream_methods:read_next_chunk(timeout)
	if self.state == "closed" or self.state == "half closed (remote)" then
		return nil
	end
	local end_stream
	local chunk, err, errno
	if self.body_read_type == "chunked" then
		local deadline = timeout and (monotime()+timeout)
		if self.body_read_left == 0 then
			chunk = false
		else
			chunk, err, errno = self.connection:read_body_chunk(timeout)
		end
		if chunk == false then
			-- last chunk, :read_headers should be called to get trailers
			self.body_read_left = 0
			-- for API compat: attempt to read trailers
			local ok
			ok, err, errno = self:step(deadline and deadline-monotime())
			if not ok then
				return nil, err, errno
			end
			return nil
		else
			end_stream = false
			if chunk == nil and err == nil then
				return nil, ce.strerror(ce.EPIPE), ce.EPIPE
			end
		end
	elseif self.body_read_type == "length" then
		local length_n = self.body_read_left
		if length_n > 0 then
			-- Read *upto* length_n bytes
			-- This function only has to read chunks; not the whole body
			chunk, err, errno = self.connection:read_body_by_length(-length_n, timeout)
			if chunk ~= nil then
				self.body_read_left = length_n - #chunk
				end_stream = (self.body_read_left == 0)
			elseif err == nil then
				-- BACKPORT of upstream ddab283 (2023-08-22), which landed after
				-- v0.4 and has never been released.
				--
				-- A peer that announces `content-length: 100` and hangs up after
				-- forty bytes produces `nil, nil` here: not an error, and not the
				-- end of the body. `shutdown` drains until the body is done, so it
				-- drains for ever on a connection that is already gone. The
				-- `chunked` branch thirty lines above already answers EPIPE for
				-- exactly this shape; this is the `length` branch catching up.
				return nil, ce.strerror(ce.EPIPE), ce.EPIPE
			end
		elseif length_n == 0 then
			chunk = ""
			end_stream = true
		else
			error("invalid length: "..tostring(length_n))
		end
	elseif self.body_read_type == "close" then
		-- Use a big negative number instead of *a. see https://github.com/wahern/cqueues/issues/89
		chunk, err, errno = self.connection:read_body_by_length(-0x80000000, timeout)
		end_stream = chunk == nil and err == nil
	elseif self.body_read_type == nil then
		-- Might get here if haven't read headers yet, or if only headers so far have been 1xx codes
		local deadline = timeout and (monotime()+timeout)
		local headers
		headers, err, errno = self:read_headers(timeout)
		if not headers then
			return nil, err, errno
		end
		self.headers_fifo:push(headers)
		return self:get_next_chunk(deadline and deadline-monotime())
	else
		error("unknown body read type")
	end
	if chunk then
		if self.body_read_inflate then
			chunk = self.body_read_inflate(chunk, end_stream)
		end
		self.stats_recv = self.stats_recv + #chunk
	end
	if end_stream then
		if self.state == "half closed (local)" then
			self:set_state("closed")
		else
			self:set_state("half closed (remote)")
		end
	end
	return chunk, err, errno
end

--- Puts a chunk into the read-ahead queue, building the queue if this is the
--- first one.
---
--- The ONE place that creates `chunk_fifo`, so `get_next_chunk` has one
--- condition to check and there is no path that assumes the field exists.
--- `at_front` is `unget`'s case: a chunk handed back, which must be read
--- before anything already queued.
function stream_methods:queue_chunk(chunk, at_front)
	local queued = self.chunk_fifo
	if not queued then
		queued = new_fifo()
		self.chunk_fifo = queued
	end
	if at_front then
		queued:insert(1, chunk)
	else
		queued:push(chunk)
	end
end

function stream_methods:get_next_chunk(timeout)
	local queued = self.chunk_fifo
	if queued and queued:length() > 0 then
		return queued:pop()
	end
	return self:read_next_chunk(timeout)
end

function stream_methods:unget(str)
	self:queue_chunk(str, true)
	return true
end

local empty_headers = new_headers()
function stream_methods:write_chunk(chunk, end_stream, timeout)
	if self.state == "idle" then
		error("cannot write chunk when stream is " .. self.state)
	elseif self.state == "closed" or self.state == "half closed (local)" or self.connection.socket == nil then
		return nil, ce.strerror(ce.EPIPE), ce.EPIPE
	elseif self.body_write_type == nil then
		error("cannot write body before headers")
	end
	if self.type == "client" then
		assert(self.connection.req_locked == self)
	else
		assert(self.connection.pipeline:peek() == self)
	end
	local orig_size = #chunk
	if self.body_write_deflate then
		chunk = self.body_write_deflate(chunk, end_stream)
	end
	if #chunk > 0 then
		if self.body_write_type == "chunked" then
			local deadline = timeout and monotime()+timeout
			local ok, err, errno = self.connection:write_body_chunk(chunk, nil, timeout)
			if not ok then
				return nil, err, errno
			end
			timeout = deadline and (deadline-monotime())
		elseif self.body_write_type == "length" then
			assert(self.body_write_left >= #chunk, "invalid content-length")
			local ok, err, errno = self.connection:write_body_plain(chunk, timeout)
			if not ok then
				return nil, err, errno
			end
			self.body_write_left = self.body_write_left - #chunk
		elseif self.body_write_type == "close" then
			local ok, err, errno = self.connection:write_body_plain(chunk, timeout)
			if not ok then
				return nil, err, errno
			end
		elseif self.body_write_type ~= "missing" then
			error("unknown body writing method")
		end
	end
	self.stats_sent = self.stats_sent + orig_size
	if end_stream then
		if self.body_write_type == "chunked" then
			return self:write_headers(empty_headers, true, timeout)
		elseif self.body_write_type == "length" then
			assert(self.body_write_left == 0, "invalid content-length")
		end
		if self.state == "half closed (remote)" then
			self:set_state("closed")
		else
			self:set_state("half closed (local)")
		end
	end
	return true
end

return {
	new = new_stream;
	methods = stream_methods;
	mt = stream_mt;
}
