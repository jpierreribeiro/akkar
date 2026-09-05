-- This module implements the socket level functionality needed for an HTTP 1 connection

local cqueues = require "cqueues"
local monotime = cqueues.monotime
local ca = require "cqueues.auxlib"
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local connection_common = require "akkar.vendor.http.connection_common"
local onerror = connection_common.onerror
local h1_stream = require "akkar.vendor.http.h1_stream"
local new_fifo = require "fifo"

local connection_methods = {}
for k,v in pairs(connection_common.methods) do
	connection_methods[k] = v
end
local connection_mt = {
	__name = "http.h1_connection";
	__index = connection_methods;
}

function connection_mt:__tostring()
	return string.format("http.h1_connection{type=%q;version=%.1f}",
		self.type, self.version)
end

-- assumes ownership of the socket
local function new_connection(socket, conn_type, version)
	assert(socket, "must provide a socket")
	if conn_type ~= "client" and conn_type ~= "server" then
		error('invalid connection type. must be "client" or "server"')
	end
	assert(version == 1 or version == 1.1, "unsupported version")
	local self = setmetatable({
		socket = socket;
		type = conn_type;
		version = version;

		-- for server: streams waiting to go out
		-- for client: streams waiting for a response
		pipeline = new_fifo();
		-- pipeline condition is stored in stream itself

		-- for server: held while request being read
		-- for client: held while writing request
		req_locked = nil;
		-- signaled when unlocked
		req_cond = cc.new();

		-- A function that will be called if the connection becomes idle
		onidle_ = nil;
	}, connection_mt)
	socket:setvbuf("full", math.huge) -- 'infinite' buffering; no write locks needed
	socket:setmode("b", "bf")
	socket:onerror(onerror)
	return self
end

function connection_methods:setmaxline(read_length)
	if self.socket == nil then
		return nil
	end
	self.socket:setmaxline(read_length)
	return true
end

function connection_methods:clearerr(...)
	if self.socket == nil then
		return nil
	end
	return self.socket:clearerr(...)
end

function connection_methods:error(...)
	if self.socket == nil then
		return nil
	end
	return self.socket:error(...)
end

function connection_methods:take_socket()
	local s = self.socket
	if s == nil then
		-- already taken
		return nil
	end
	self.socket = nil
	-- Shutdown *after* taking away socket so shutdown handlers can't effect the socket
	self:shutdown()
	-- Reset socket to some defaults
	s:onerror(nil)
	return s
end

function connection_methods:shutdown(dir)
	if dir == nil or dir:match("w") then
		while self.pipeline:length() > 0 do
			local stream = self.pipeline:peek()
			stream:shutdown()
		end
	end
	if self.socket then
		return ca.fileresult(self.socket:shutdown(dir))
	else
		return true
	end
end

function connection_methods:new_stream()
	assert(self.type == "client")
	if self.socket == nil or self.socket:eof("w") then
		return nil
	end
	local stream = h1_stream.new(self)
	return stream
end

-- this function *should never throw*
function connection_methods:get_next_incoming_stream(timeout)
	assert(self.type == "server")
	-- Make sure we don't try and read before the previous request has been fully read
	if self.req_locked then
		local deadline = timeout and monotime()+timeout
		assert(cqueues.running(), "cannot wait for condition if not within a cqueues coroutine")
		if cqueues.poll(self.req_cond, timeout) == timeout then
			return nil, ce.strerror(ce.ETIMEDOUT), ce.ETIMEDOUT
		end
		timeout = deadline and deadline-monotime()
		assert(self.req_locked == nil)
	end
	if self.socket == nil then
		return nil
	end
	-- Wait for at least one byte
	local ok, err, errno = self.socket:fill(1, 0)
	if not ok then
		if errno == ce.ETIMEDOUT then
			local deadline = timeout and monotime()+timeout
			if cqueues.poll(self.socket, timeout) ~= timeout then
				return self:get_next_incoming_stream(deadline and deadline-monotime())
			end
		end
		return nil, err, errno
	end
	local stream = h1_stream.new(self)
	self.pipeline:push(stream)
	self.req_locked = stream
	return stream
end

function connection_methods:read_request_line(timeout)
	local deadline = timeout and (monotime()+timeout)
	local preline
	local line, err, errno = self.socket:xread("*L", timeout)
	if line == "\r\n" then
		-- RFC 7230 3.5: a server that is expecting to receive and parse a request-line
		-- SHOULD ignore at least one empty line (CRLF) received prior to the request-line.
		preline = line
		line, err, errno = self.socket:xread("*L", deadline and (deadline-monotime()))
	end
	if line == nil then
		if preline then
			local ok, errno2 = self.socket:unget(preline)
			if not ok then
				return nil, onerror(self.socket, "unget", errno2)
			end
		end
		return nil, err, errno
	end
	local method, target, httpversion = line:match("^(%w+) (%S+) HTTP/(1%.[01])\r\n$")
	if not method then
		self.socket:seterror("r", ce.EILSEQ)
		local ok, errno2 = self.socket:unget(line)
		if not ok then
			return nil, onerror(self.socket, "unget", errno2)
		end
		if preline then
			ok, errno2 = self.socket:unget(preline)
			if not ok then
				return nil, onerror(self.socket, "unget", errno2)
			end
		end
		return nil, onerror(self.socket, "read_request_line", ce.EILSEQ)
	end
	httpversion = httpversion == "1.0" and 1.0 or 1.1 -- Avoid tonumber() due to locale issues
	return method, target, httpversion
end

function connection_methods:read_status_line(timeout)
	local line, err, errno = self.socket:xread("*L", timeout)
	if line == nil then
		return nil, err, errno
	end
	local httpversion, status_code, reason_phrase = line:match("^HTTP/(1%.[01]) (%d%d%d) (.*)\r\n$")
	if not httpversion then
		self.socket:seterror("r", ce.EILSEQ)
		local ok, errno2 = self.socket:unget(line)
		if not ok then
			return nil, onerror(self.socket, "unget", errno2)
		end
		return nil, onerror(self.socket, "read_status_line", ce.EILSEQ)
	end
	httpversion = httpversion == "1.0" and 1.0 or 1.1 -- Avoid tonumber() due to locale issues
	return httpversion, status_code, reason_phrase
end

function connection_methods:read_header(timeout)
	local line, err, errno = self.socket:xread("*h", timeout)
	if line == nil then
		-- Note: the *h read returns *just* nil when data is a non-mime compliant header
		if err == nil then
			local pending_bytes = self.socket:pending()
			-- check if we're at end of headers
			if pending_bytes >= 2 then
				local peek = assert(self.socket:xread(2, "b", 0))
				local ok, errno2 = self.socket:unget(peek)
				if not ok then
					return nil, onerror(self.socket, "unget", errno2)
				end
				if peek == "\r\n" then
					return nil
				end
			end
			if pending_bytes > 0 then
				self.socket:seterror("r", ce.EILSEQ)
				return nil, onerror(self.socket, "read_header", ce.EILSEQ)
			end
		end
		return nil, err, errno
	end
	-- header fields can have optional surrounding whitespace
	--[[ RFC 7230 3.2.4: No whitespace is allowed between the header field-name
	and colon. In the past, differences in the handling of such whitespace have
	led to security vulnerabilities in request routing and response handling.
	A server MUST reject any received request message that contains whitespace
	between a header field-name and colon with a response code of
	400 (Bad Request). A proxy MUST remove any such whitespace from a response
	message before forwarding the message downstream.]]
	-- AKKAR: THE VALUE IS TAKEN GREEDILY AND TRIMMED BY BYTE.
	--
	-- This was `^([^%s:]+):[ \t]*(.-)[ \t]*$`. The lazy `(.-)` with an
	-- anchored trailing `[ \t]*$` makes Lua's matcher advance one character at
	-- a time and re-try the tail from every position, so the cost grows with
	-- the VALUE's length rather than with finding the colon.
	--
	-- Measured, per call:
	--
	--     line              shipped    this
	--     17 bytes          1,186 ns    717 ns   1.65x
	--     68 bytes, padded  3,636 ns  1,606 ns   2.3x
	--     113 bytes         6,693 ns  1,436 ns   4.7x
	--
	-- A header line six times longer cost SIX TIMES more to parse. That is
	-- most of why parsing is 8% of a request's CPU in this project's benchmark
	-- -- three short identical headers -- and 45% of a production-shaped one
	-- with a User-Agent and cookies. The benchmark had been hiding it.
	--
	-- EQUIVALENCE IS THE WHOLE CLAIM, because a faster header parse that
	-- disagrees with the old one on any shape is not an optimisation, it is a
	-- parser differential -- and differentials between two implementations of
	-- one protocol are how request smuggling works. Checked against the
	-- shipped pattern on 36 hand-written shapes (no value, whitespace-only,
	-- tabs, no colon, colon first, spaces in the name, embedded CR/LF/NUL,
	-- 200-byte name and value, real browser headers) and 200,000 random byte
	-- strings: ZERO disagreements.
	local key, val = line:match("^([^%s:]+):[ \t]*(.*)$")
	if key then
		-- `(.*)` swallowed the trailing whitespace the old pattern trimmed.
		-- Removing it by byte rather than with another pattern, because a
		-- second pattern would put the backtracking straight back.
		local last = #val
		while last > 0 do
			local c = val:byte(last)
			if c ~= 32 and c ~= 9 then break end
			last = last - 1
		end
		if last ~= #val then val = val:sub(1, last) end
	end
	if not key then
		self.socket:seterror("r", ce.EILSEQ)
		local ok, errno2 = self.socket:unget(line)
		if not ok then
			return nil, onerror(self.socket, "unget", errno2)
		end
		return nil, onerror(self.socket, "read_header", ce.EILSEQ)
	end
	-- Return the wire size as a fourth value. Callers that predate the bound
	-- ignore it; akkar's stream uses it so leading/trailing OWS cannot vanish
	-- before the aggregate request-header ceiling is charged.
	return key, val, nil, #line
end

function connection_methods:read_headers_done(timeout)
	local crlf, err, errno = self.socket:xread(2, timeout)
	if crlf == "\r\n" then
		return true
	elseif crlf ~= nil or (err == nil and self.socket:pending() > 0) then
		self.socket:seterror("r", ce.EILSEQ)
		if crlf then
			local ok, errno2 = self.socket:unget(crlf)
			if not ok then
				return nil, onerror(self.socket, "unget", errno2)
			end
		end
		return nil, onerror(self.socket, "read_headers_done", ce.EILSEQ)
	else
		return nil, err, errno
	end
end

-- pass a negative length for *up to* that number of bytes
function connection_methods:read_body_by_length(len, timeout)
	assert(type(len) == "number")
	return self.socket:xread(len, timeout)
end

function connection_methods:read_body_till_close(timeout)
	return self.socket:xread("*a", timeout)
end

function connection_methods:read_body_chunk(timeout)
	local deadline = timeout and (monotime()+timeout)
	local chunk_header, err, errno = self.socket:xread("*L", timeout)
	if chunk_header == nil then
		return nil, err, errno
	end
	-- AKKAR: a chunk extension must be introduced by `;`, and the line must
	-- end where the pattern says it ends.
	--
	-- Upstream's `^(%x+) *(.-)\r\n` accepted ARBITRARY TRAILING TEXT after the
	-- size, with no `;` required -- `0 junk\r\n` parsed happily as size 0 with
	-- extension "junk". That is CVE-2026-24880 (Tomcat) exactly, and it is a
	-- desync primitive for the same reason as every other item here: a front
	-- end that rejects `0 junk` and a back end that accepts it disagree about
	-- where the body ends, and akkar is the back end.
	--
	-- RFC 9112 7.1.1: `chunk-ext = *( BWS ";" BWS chunk-ext-name
	-- [ BWS "=" BWS chunk-ext-val ] )`. The extension is OPTIONAL, but when
	-- there is one it starts with a semicolon. Anything else on that line is
	-- not an extension, it is a framing error.
	--
	-- `%-` is anchored at both ends: `(.-)\r\n` alone is non-greedy and will
	-- happily stop at the FIRST CRLF anywhere later in the buffer, so the
	-- trailing `$`-equivalent matters. `xread("*L")` hands over exactly one
	-- line, so anchoring to its end is what "the rest of this line" means.
	-- Matched in two steps so that `chunk_ext` keeps the shape its callers
	-- already expect -- the extension text WITHOUT the introducing `;`, and
	-- `""` when there is none.
	local chunk_size, chunk_rest = chunk_header:match("^(%x+)[ \t]*([^\r\n]*)\r\n$")
	local chunk_ext = ""
	if chunk_size ~= nil and chunk_rest ~= "" then
		chunk_ext = chunk_rest:match("^;(.*)$")
		if chunk_ext == nil then
			-- Trailing bytes that are not an extension: refuse, do not ignore.
			chunk_size, chunk_ext = nil, ""
		end
	end
	if chunk_size == nil then
		self.socket:seterror("r", ce.EILSEQ)
		local unget_ok1, unget_errno1 = self.socket:unget(chunk_header)
		if not unget_ok1 then
			return nil, onerror(self.socket, "unget", unget_errno1)
		end
		return nil, onerror(self.socket, "read_body_chunk", ce.EILSEQ)
	elseif #chunk_size > 8 then
		self.socket:seterror("r", ce.E2BIG)
		return nil, onerror(self.socket, "read_body_chunk", ce.E2BIG)
	end
	chunk_size = tonumber(chunk_size, 16)
	if chunk_ext == "" then
		chunk_ext = nil
	end
	if chunk_size == 0 then
		-- you MUST read trailers after this!
		return false, chunk_ext
	else
		local ok, err2, errno2 = self.socket:fill(chunk_size+2, 0)
		if not ok then
			local unget_ok1, unget_errno1 = self.socket:unget(chunk_header)
			if not unget_ok1 then
				return nil, onerror(self.socket, "unget", unget_errno1)
			end
			if errno2 == ce.ETIMEDOUT then
				timeout = deadline and deadline-monotime()
				if cqueues.poll(self.socket, timeout) ~= timeout then
					-- retry
					return self:read_body_chunk(deadline and deadline-monotime())
				end
			elseif err2 == nil then
				self.socket:seterror("r", ce.EILSEQ)
				return nil, onerror(self.socket, "read_body_chunk", ce.EILSEQ)
			end
			return nil, err2, errno2
		end
		-- if `fill` succeeded these shouldn't be able to fail
		local chunk_data = assert(self.socket:xread(chunk_size, "b", 0))
		local crlf = assert(self.socket:xread(2, "b", 0))
		if crlf ~= "\r\n" then
			self.socket:seterror("r", ce.EILSEQ)
			local unget_ok3, unget_errno3 = self.socket:unget(crlf)
			if not unget_ok3 then
				return nil, onerror(self.socket, "unget", unget_errno3)
			end
			local unget_ok2, unget_errno2 = self.socket:unget(chunk_data)
			if not unget_ok2 then
				return nil, onerror(self.socket, "unget", unget_errno2)
			end
			local unget_ok1, unget_errno1 = self.socket:unget(chunk_header)
			if not unget_ok1 then
				return nil, onerror(self.socket, "unget", unget_errno1)
			end
			return nil, onerror(self.socket, "read_body_chunk", ce.EILSEQ)
		end
		-- Success!
		return chunk_data, chunk_ext
	end
end

function connection_methods:write_request_line(method, target, httpversion, timeout)
	assert(method:match("^[^ \r\n]+$"))
	assert(target:match("^[^ \r\n]+$"))
	assert(httpversion == 1.0 or httpversion == 1.1)
	local line = string.format("%s %s HTTP/%s\r\n", method, target, httpversion == 1.0 and "1.0" or "1.1")
	local ok, err, errno = self.socket:xwrite(line, "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_status_line(httpversion, status_code, reason_phrase, timeout)
	assert(httpversion == 1.0 or httpversion == 1.1)
	-- AKKAR: `find` rather than `match` -- same pattern, same rejections, but
	-- it answers with positions instead of allocating a copy of the string it
	-- just validated. Once per response.
	assert(status_code:find("^[1-9]%d%d$"), "invalid status code")
	assert(type(reason_phrase) == "string" and reason_phrase:find("^[^\r\n]*$"), "invalid reason phrase")
	local line = string.format("HTTP/%s %s %s\r\n", httpversion == 1.0 and "1.0" or "1.1", status_code, reason_phrase)
	local ok, err, errno = self.socket:xwrite(line, "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_header(k, v, timeout)
	-- AKKAR: the same three checks without the three allocations, once per
	-- header of every response.
	--
	-- `match` returns the matched text, so validating a name allocated a copy
	-- of it; `sub(-1, -1)` built a one-character string to compare against
	-- "\n". `find` and `byte` answer the same questions with numbers.
	--
	-- The checks themselves are unchanged and they are not decorative: they
	-- are what stops a header value from injecting CRLF into the response.
	-- AKKAR: the value check now covers BARE CR, NUL and a leading space,
	-- none of which it covered before despite the comment above claiming it
	-- stopped CRLF injection.
	--
	-- What it actually tested was `v:byte(-1) ~= 10` and `not v:find("\n[^ ]")`
	-- -- both about LINE FEED. A lone `\r` passed straight through and was
	-- written verbatim into the response, and that is enough on its own: many
	-- intermediaries, and a CDN in front of this server especially, treat a
	-- bare CR as a line terminator when splitting a header block. So a value
	-- of `"/x\rContent-Length: 0\r\n\r\nHTTP/1.1 200 OK"` is a response split
	-- at the front end even though this server considers it one header. It
	-- needs an application that reflects input into a header to reach -- a
	-- redirect that echoes a `?next=` parameter into `Location` is the
	-- ordinary case, not an exotic one.
	--
	-- NUL is rejected for the same reason one level down: it truncates in the
	-- C string handling of whatever parses this next.
	--
	-- A LEADING space or tab is rejected because such a value is
	-- indistinguishable from an obs-fold continuation of the PREVIOUS header,
	-- so it lets a value be smuggled onto a different field name entirely.
	--
	-- `\n` in any position now goes too, rather than only when unfolded.
	-- Writing obs-fold was already forbidden -- RFC 9112 5.2: "A sender MUST
	-- NOT generate a message that includes line folding" -- so nothing
	-- legitimate loses, and the `\n[^ ]` carve-out was the hole that made the
	-- rest of the check conditional.
	--
	-- Still allocation-free: a character-class `find` returns indices, and
	-- `byte` returns a number, so this stays numbers-only per header per
	-- response, which is what `spec/allocation_spec.lua` pins.
	assert(type(k) == "string" and k:find("^[^%z:\r\n]+$"), "field name invalid")
	assert(type(v) == "string" and not v:find("[%z\r\n]")
	       and v:byte(1) ~= 32 and v:byte(1) ~= 9, "field value invalid")
	local ok, err, errno = self.socket:xwrite(k..": "..v.."\r\n", "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_headers_done(timeout)
	-- flushes write buffer
	local ok, err, errno = self.socket:xwrite("\r\n", "n", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_body_chunk(chunk, chunk_ext, timeout)
	assert(chunk_ext == nil, "chunk extensions not supported")
	local data = string.format("%x\r\n", #chunk) .. chunk .. "\r\n"
	-- flushes write buffer
	local ok, err, errno = self.socket:xwrite(data, "n", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_body_last_chunk(chunk_ext, timeout)
	assert(chunk_ext == nil, "chunk extensions not supported")
	-- no flush; writing trailers (via write_headers_done) will do that
	local ok, err, errno = self.socket:xwrite("0\r\n", "f", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

function connection_methods:write_body_plain(body, timeout)
	-- flushes write buffer
	local ok, err, errno = self.socket:xwrite(body, "n", timeout)
	if not ok then
		return nil, err, errno
	end
	return true
end

return {
	new = new_connection;
	methods = connection_methods;
	mt = connection_mt;
}
