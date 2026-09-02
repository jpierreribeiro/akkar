local cqueues = require "cqueues"
local monotime = cqueues.monotime
local ca = require "cqueues.auxlib"
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local cs = require "cqueues.socket"
local connection_common = require "akkar.vendor.http.connection_common"
local onerror = connection_common.onerror
local h1_connection = require "akkar.vendor.http.h1_connection"
local http_tls = require "akkar.vendor.http.tls"
local http_util = require "akkar.vendor.http.util"
local openssl_bignum = require "openssl.bignum"
local pkey = require "openssl.pkey"
local openssl_rand = require "openssl.rand"
local openssl_ssl = require "openssl.ssl"
local openssl_ctx = require "openssl.ssl.context"
local x509 = require "openssl.x509"
local name = require "openssl.x509.name"
local altname = require "openssl.x509.altname"

local hang_timeout = 0.03

--- The h2 half, LOADED WHEN A SERVER THAT COULD SPEAK IT IS CONSTRUCTED, and
--- not at `require` time.
---
--- `h2_connection` has exactly two uses in this file, both per-connection and
--- both already guarded -- the preface sniff under `self.h2c`, and
--- `h2_connection.new` under `version == 2`. `h2_stream`, `hpack`, `h2_error`
--- and `vendor/http/bit` arrive only behind it, so deferring this one require
--- drops all five: **~19 ms of 47.6 and 5 modules of 69**, measured, on every
--- boot of every application.
---
--- ALPN IS NOT AFFECTED AND MUST NOT BE. `alpn_select` below is a pure
--- function over strings and never touches this module, so a TLS server still
--- offers h2 exactly as before -- it is the connection machinery that waits,
--- not the negotiation.
---
--- WHERE IT IS FORCED IS THE WHOLE DESIGN; see `new_server`.
local h2_module_
local function h2_module()
	h2_module_ = h2_module_ or require "akkar.vendor.http.h2_connection"
	return h2_module_
end

-- Sense for TLS or SSL client hello
-- returns `true`, `false` or `nil, err`
local function is_tls_client_hello(socket, timeout)
	-- reading for 6 bytes should be safe, as no HTTP version
	-- has a valid client request shorter than 6 bytes
	local first_bytes, err, errno = socket:xread(6, timeout)
	if first_bytes == nil then
		return nil, err or ce.EPIPE, errno
	end
	local use_tls = not not (
		first_bytes:match("^[\21\22]\3[\1\2\3]..\1") or -- TLS
		first_bytes:match("^[\128-\255][\9-\255]\1") -- SSLv2
	)
	local ok
	ok, errno = socket:unget(first_bytes)
	if not ok then
		return nil, onerror(socket, "unget", errno, 2)
	end
	return use_tls
end

-- Wrap a bare cqueues socket in an HTTP connection of a suitable version
-- Starts TLS if necessary
-- this function *should never throw*
local function wrap_socket(self, socket, timeout)
	local deadline = timeout and monotime()+timeout
	socket:setmode("b", "b")
	socket:onerror(onerror)
	local version = self.version
	local use_tls = self.tls
	if use_tls == nil then
		local err, errno
		use_tls, err, errno = is_tls_client_hello(socket, deadline and (deadline-monotime()))
		if use_tls == nil then
			return nil, err, errno
		end
	end
	if use_tls then
		local ok, err, errno = socket:starttls(self.ctx, deadline and (deadline-monotime()))
		if not ok then
			return nil, err, errno
		end
		local ssl = assert(socket:checktls())
		if http_tls.has_alpn then
			local proto = ssl:getAlpnSelected()
			if proto then
				if proto == "h2" and (version == nil or version == 2) then
					version = 2
				elseif proto == "http/1.1" and (version == nil or version < 2) then
					version = 1.1
				elseif proto == "http/1.0" and (version == nil or version == 1.0) then
					version = 1.0
				else
					return nil, "unexpected ALPN protocol: " .. proto, ce.EILSEQNOSUPPORT
				end
			end
		end
	end
	-- CLEARTEXT h2 IS OPT-IN, AND THE REASON IS A READ PER CONNECTION.
	--
	-- Over TLS the version is settled by ALPN above, for free. Without TLS
	-- there is nothing to negotiate with, so upstream sniffs the connection
	-- for h2's `PRI * HTTP/2.0` preface -- and that sniff is a read on EVERY
	-- connection, h1 ones included, before a byte of request is parsed.
	-- Browsers never speak cleartext h2; what wants it is a proxy or a gRPC
	-- client reaching akkar on a private network.
	--
	-- So it is `h2c = true` rather than the default, and with it off the
	-- HTTP/1.1 path is byte for byte what it was before h2 came back.
	--
	-- With it off, a client that sends the preface anyway gets it parsed as
	-- HTTP/1.1, where `PRI * HTTP/2.0` is a request with an unknown method and
	-- is rejected as one. Wrong protocol, clean refusal, no hang.
	if version == nil then
		if self.h2c then
			-- Already loaded: `self.h2c` is one of the three conditions that
			-- force it in `new_server`, so this call cannot be the one that
			-- pays for the require -- which matters because this function
			-- *should never throw* and a `require` can.
			local is_h2, sniff_err, sniff_errno = h2_module().socket_has_preface(
				socket, true, deadline and (deadline-monotime()))
			if is_h2 == nil then
				return nil, sniff_err or ce.EPIPE, sniff_errno
			end
			version = is_h2 and 2 or 1.1
		else
			version = 1.1
		end
	end
	local conn, err, errno
	if version == 2 then
		-- A CEILING ON CONCURRENT STREAMS, advertised in the connection's
		-- SETTINGS.
		--
		-- Upstream's default is `math.huge`, and the consequence is not
		-- theoretical: h2spec skips 5.1.2, "sends HEADERS that cause the
		-- advertised concurrent stream limit to be exceeded", precisely
		-- because there is no limit to exceed. Measured here, 500 concurrent
		-- streams on ONE connection were all accepted, at 10 KB each, with
		-- `max_concurrent` doing nothing because `max_concurrent` counts
		-- CONNECTIONS and this is one.
		--
		-- 100 is what nginx and most servers advertise. A browser opens six.
		-- Also already loaded. `version == 2` here arrives from
		-- `tbl.version == 2`, from ALPN (which needs `tbl.tls ~= false`), or
		-- from the h2c preface sniff -- and every one of those three is a
		-- condition `new_server` forced the load on.
		conn, err, errno = h2_module().new(socket, "server",
			self.h2_max_concurrent_streams and
			{ [0x3] = self.h2_max_concurrent_streams } or nil)
	else
		conn, err, errno = h1_connection.new(socket, "server", version)
	end
	if not conn then
		return nil, err, errno
	end
	return conn
end

--- ACCEPT ERRORS THAT LEAVE THE CONNECTION ON THE QUEUE, which is the whole
--- difference between one dropped connection and a dead process.
---
--- `accept()` fails in two unrelated ways and upstream only separated one of
--- them. `ECONNABORTED`, `EPROTO` and `EPERM` are about ONE pending
--- connection: the kernel takes it off the queue and hands back the error, so
--- the next call makes progress and the loop self-limits at one iteration per
--- bad connection. `EMFILE`, `ENFILE`, `ENOBUFS` and `ENOMEM` are about the
--- PROCESS or the MACHINE: nothing is dequeued, the listening socket stays
--- readable, and calling `accept()` again reproduces the error immediately and
--- for ever.
---
--- Upstream throttles `EMFILE` and sends the other three to `onerror` in the
--- `else` branch -- which returns, and the `while` runs `accept()` again. That
--- is an unyielding busy loop, and unyielding is the word that matters:
--- measured here at 349,000 accept() calls a second under `ENFILE`, and a
--- sibling coroutine in the same controller got **one turn in a full second**
--- against the ~100 it should get. Every in-flight request, every registered
--- task and the signal handler that makes SIGTERM work are all in that same
--- controller. The process holds the port, burns a core, and serves nothing.
---
--- akkar's `onerror` logs this branch, so it is also a log flood: 61,216 lines
--- a second, 3.8 MB/s, measured through `akkar.log` -- which fills a small
--- disk in under an hour and turns a transient kernel condition into the
--- ENOSPC failure two sections of `docs/UNKNOWNS.md` down.
---
--- akkar's own `descriptor_ceiling` keeps a Linux process off `EMFILE` by
--- capping `max_concurrent` at 66% of the soft limit, and that was measured to
--- work -- 0.0% CPU where an uncapped server sat at 92.6%. It cannot help
--- here. `ENFILE` is system-wide and `ENOMEM`/`ENOBUFS` are the kernel's, so
--- no per-process ceiling can prevent them, and off Linux no ceiling is
--- derived at all.
local RETRY_LATER = {
	[ce.EMFILE]  = true, -- this process is at its descriptor limit
	[ce.ENFILE]  = true, -- the machine is at its descriptor limit
	[ce.ENOBUFS] = true, -- the kernel has no buffer for the new socket
	[ce.ENOMEM]  = true, -- ... and no memory for it either
}

-- How many identical failures in a row before an errno NOT in the table above
-- is treated as one anyway. A per-connection error self-limits, so under an
-- RST flood this counter is reset by every successful accept in between and
-- throughput is untouched. An errno nobody anticipated that does NOT dequeue
-- reaches this count in microseconds and then throttles like the rest: the
-- point is that no accept error, known or not, can starve the loop.
local repeat_before_throttle = 20

local function server_loop(self)
	local last_errno, repeats = nil, 0
	while self.socket do
		if self.paused then
			cqueues.poll(self.pause_cond)
		elseif self.n_connections >= self.max_concurrent then
			cqueues.poll(self.connection_done)
		else
			local socket, accept_errno = self.socket:accept({nodelay = true;}, 0)
			if socket == nil then
				if accept_errno == last_errno then
					repeats = repeats + 1
				else
					last_errno, repeats = accept_errno, 1
				end

				if accept_errno == ce.ETIMEDOUT then
					-- Yield this thread until a client arrives
					cqueues.poll(self.socket, self.pause_cond)
				else
					local stuck = RETRY_LATER[accept_errno]
						or repeats > repeat_before_throttle

					-- Reported whatever we then do about it. Throttling an
					-- error must not also hide it, and `ENFILE` with no line
					-- in the log is a server that has stopped accepting for a
					-- reason nobody can name. Reported ONCE per run of
					-- identical failures rather than per iteration, because
					-- the second line says nothing the first did not and the
					-- sixty-thousandth costs a disk.
					if not stuck or repeats == 1 then
						self:onerror()(self, self, "accept",
							ce.strerror(accept_errno), accept_errno)
					end

					if stuck then
						-- Wait for another request to finish
						if cqueues.poll(self.connection_done, hang_timeout) == hang_timeout then
							-- If we're stuck waiting, run a garbage collection
							-- sweep. This can prevent a hang: a descriptor held
							-- by an unreachable object is only released by a
							-- collection, so this is how a leak-induced EMFILE
							-- recovers on its own.
							--
							-- AT MOST ONCE A SECOND, not on every 30 ms
							-- timeout. A full sweep 33 times a second costs in
							-- proportion to the heap and nothing else: measured
							-- at 4.6% of a core on an empty heap, 28.0% at
							-- 40,000 live tables and 92.6% at 1.2 million. An
							-- application heap is the large end of that range,
							-- so the recovery mechanism was itself pinning the
							-- core it was trying to save. Once a second frees
							-- exactly the same descriptors.
							local now = monotime()
							if now - (self.last_accept_gc or 0) >= 1 then
								self.last_accept_gc = now
								collectgarbage()
							end
						end
					end
				end
			else
				last_errno, repeats = nil, 0
				self:add_socket(socket)
			end
		end
	end
end

-- Forward-declared because `handle_socket` now calls it directly; the
-- definition stays where it was, just below.
local handle_stream

local function handle_socket(self, socket)
	local error_operation, error_context
	local conn, err, errno = wrap_socket(self, socket, self.connection_setup_timeout)
	if not conn then
		socket:close()
		if err ~= ce.EPIPE -- client closed connection
			and errno ~= ce.ETIMEDOUT -- an operation timed out
			and errno ~= ce.ECONNRESET then
			error_operation = "wrap"
			error_context = socket
		end
	else
		local cond = cc.new()
		local idle = true
		local deadline
		conn:onidle(function()
			idle = true
			deadline = self.intra_stream_timeout + monotime()
			cond:signal(1)
		end)
		while true do
			local timeout = deadline and deadline-monotime() or self.intra_stream_timeout
			local stream
			stream, err, errno = conn:get_next_incoming_stream(timeout)
			if stream == nil then
				if (err ~= nil -- client closed connection
					and errno ~= ce.ECONNRESET
					and errno ~= ce.ENOTCONN
					and errno ~= ce.ETIMEDOUT) then
					error_operation = "get_next_incoming_stream"
					error_context = conn
					break
				elseif errno ~= ce.ETIMEDOUT or not idle or (deadline and deadline <= monotime()) then -- want to go around loop again if deadline not hit
					break
				end
			else
				idle = false
				deadline = nil

				-- HTTP/1.1 RUNS THE STREAM RIGHT HERE, WITH NO COROUTINE OF
				-- ITS OWN.
				--
				-- `add_stream` does `cq:wrap(handle_stream, ...)`, one coroutine
				-- per REQUEST, and it costs ~3,900 bytes -- 43% of a request's
				-- allocation once the other per-request coroutine, akkar's
				-- deadline, became a reused worker.
				--
				-- And in h1 it buys no concurrency at all. This loop sits parked
				-- inside `get_next_incoming_stream` while the stream runs,
				-- because h1 is serial: a connection does not produce the next
				-- stream before the current one finishes. The two coroutines
				-- take turns and never run together. The wrap exists because
				-- lua-http speaks HTTP/2, where the streams of one connection
				-- ARE concurrent.
				--
				-- CONDITIONAL, NOT UNCONDITIONAL, and the condition earned
				-- itself. It was written while akkar spoke only h1, so that
				-- "h1 only for now" would not silently become "h1 only
				-- structurally" -- and when the h2 half was vendored back in on
				-- 2026-08-18, multiplexing worked on the first attempt because
				-- this line already routed h2 to `add_stream`.
				--
				-- `spec/http2_spec.lua` asserts what it protects: two streams
				-- that each sleep 0.4 s must finish in about 0.4 s on one
				-- connection. Making this call unconditional takes them to
				-- 0.81 s, which is that spec going red on wall clock rather
				-- than on a crash. Measured, by doing it.
				if conn.version and conn.version < 2 then
					handle_stream(self, stream)
				else
					self:add_stream(stream)
				end
			end
		end
		-- wait for streams to complete
		if not idle then
			cond:wait()
		end
		conn:close()
	end
	self.n_connections = self.n_connections - 1
	self.connection_done:signal(1)
	if error_operation then
		self:onerror()(self, error_context, error_operation, err, errno)
	end
end

function handle_stream(self, stream)
	local ok, err = http_util.yieldable_pcall(self.onstream, self, stream)
	stream:shutdown()
	if not ok then
		self:onerror()(self, stream, "onstream", err)
	end
end

-- Prefer whichever comes first
local function alpn_select(ssl, protos, version)
	-- h2 IS offered, and offering it over TLS costs the HTTP/1.1 path nothing:
	-- a client that does not ask for h2 never reaches the h2 branch. The
	-- cleartext side is where a cost would appear, and it is gated separately
	-- -- see `h2c` below.
	for _, proto in ipairs(protos) do
		if (proto == "h2" and (version == nil or version == 2))
			or (proto == "http/1.1" and (version == nil or version < 2))
			or (proto == "http/1.0" and (version == nil or version == 1.0)) then
			return proto
		end
	end
	return nil
end

-- create a new self signed cert
local function new_ctx(host, version)
	local ctx = http_tls.new_server_context()
	if http_tls.has_alpn then
		ctx:setAlpnSelect(alpn_select, version)
	end
	if version == 2 then
		ctx:setOptions(openssl_ctx.OP_NO_TLSv1 + openssl_ctx.OP_NO_TLSv1_1)
	end
	local crt = x509.new()
	crt:setVersion(3)
	-- serial needs to be unique or browsers will show uninformative error messages
	crt:setSerial(openssl_bignum.fromBinary(openssl_rand.bytes(16)))
	-- use the host we're listening on as canonical name
	local dn = name.new()
	dn:add("CN", host)
	crt:setSubject(dn)
	crt:setIssuer(dn) -- should match subject for a self-signed
	local alt = altname.new()
	alt:add("DNS", host)
	crt:setSubjectAlt(alt)
	-- lasts for 10 years
	crt:setLifetime(os.time(), os.time()+86400*3650)
	-- can't be used as a CA
	crt:setBasicConstraints{CA=false}
	crt:setBasicConstraintsCritical(true)
	-- generate a new private/public key pair
	local key = pkey.new({bits=2048})
	crt:setPublicKey(key)
	crt:sign(key)
	assert(ctx:setPrivateKey(key))
	assert(ctx:setCertificate(crt))
	return ctx
end

local server_methods = {
	version = nil;
	max_concurrent = math.huge;
	connection_setup_timeout = 10;
	intra_stream_timeout = 10;
}
local server_mt = {
	__name = "http.server";
	__index = server_methods;
}

function server_mt:__tostring()
	return string.format("http.server{socket=%s;n_connections=%d}",
		tostring(self.socket), self.n_connections)
end

--[[ Creates a new server object

Takes a table of options:
  - `.cq` (optional): A cqueues controller to use
  - `.socket` (optional): A cqueues socket object to accept() from
  - `.onstream`: function to call back for each stream read
  - `.onerror`: function that will be called when an error occurs (default: throw an error)
  - `.tls`: `nil`: allow both tls and non-tls connections
  -         `true`: allows tls connections only
  -         `false`: allows non-tls connections only
  - `.ctx`: an `openssl.ssl.context` object to use for tls connections
  - `       `nil`: a self-signed context will be generated
  - `.version`: the http version to allow to connect (default: any)
  - `.max_concurrent`: Maximum number of connections to allow live at a time (default: infinity)
  - `.connection_setup_timeout`: Timeout (in seconds) to wait for client to send first bytes and/or complete TLS handshake (default: 10)
  - `.intra_stream_timeout`: Timeout (in seoncds) to wait between start of client streams (default: 10)
]]
local function new_server(tbl)
	local cq = tbl.cq
	if cq == nil then
		cq = cqueues.new()
	else
		assert(cqueues.type(cq) == "controller", "optional cq field should be a cqueue controller")
	end
	local socket = tbl.socket
	if socket ~= nil then
		assert(cs.type(socket), "optional socket field should be a cqueues socket")
	end
	local onstream = assert(tbl.onstream, "missing 'onstream'")
	if tbl.ctx == nil and tbl.tls ~= false then
		error("OpenSSL context required if .tls isn't false")
	end

	-- FORCE THE h2 LOAD HERE, AND HERE SPECIFICALLY.
	--
	-- The deferral above is only safe if the require happens somewhere a
	-- raise is already the contract. `wrap_socket` is documented as a
	-- function that *should never throw*, and it is called under the `xpcall`
	-- in `add_socket` -- so a `require` that failed in there would be caught,
	-- turned into a per-connection error, and h2 would be SILENTLY BROKEN in
	-- production while HTTP/1.1 kept working perfectly. Today a broken h2
	-- half fails loudly at `require "akkar"`; that is the property being
	-- preserved.
	--
	-- `new_server` is the funnel -- `listen(tbl)` comes through it and so
	-- does a direct `server.new{}` -- and it ALREADY throws, twice, in the
	-- ten lines above. `listen` was the tempting alternative and is the wrong
	-- one: its own comment says you need not call it.
	--
	-- THE COST IS REAL AND IT IS THE DESIGN. An application with TLS pays the
	-- full ~19 ms right here and saves nothing, because ALPN can hand it an
	-- h2 connection at any moment and there is no honest way to be ready for
	-- that without the module. What is saved is the cleartext, non-h2c
	-- server -- which is exactly the process-per-tenant shape `akkar/init.lua`
	-- names as the reason boot time is worth anything at all. Nobody should
	-- "optimise" this forcing away to widen the saving; the saving is not the
	-- point, a server that quietly cannot speak h2 is the thing being
	-- prevented.
	--
	-- NOT conditioned on `http_tls.has_alpn`. Predicting "h2 is unreachable
	-- because this OpenSSL lacks ALPN" is the same class of silently-no-h2
	-- that the export note at the bottom of this file and `akkar/init.lua`
	-- both exist at length to prevent.
	if tbl.version == 2 or tbl.h2c or tbl.tls ~= false then
		h2_module()
	end

	local self = setmetatable({
		cq = cq;
		socket = socket;
		onstream = onstream;
		onerror_ = tbl.onerror;
		tls = tbl.tls;
		ctx = tbl.ctx;
		version = tbl.version;
		h2c = tbl.h2c;
		h2_max_concurrent_streams = tbl.h2_max_concurrent_streams;
		max_concurrent = tbl.max_concurrent;
		n_connections = 0;
		pause_cond = cc.new();
		paused = false;
		connection_done = cc.new(); -- signalled when connection has been closed
		connection_setup_timeout = tbl.connection_setup_timeout;
		intra_stream_timeout = tbl.intra_stream_timeout;
	}, server_mt)

	if socket then
		-- Return errors rather than throwing
		socket:onerror(function(socket, op, why, lvl) -- luacheck: ignore 431 212
			return why
		end)
		cq:wrap(server_loop, self)
	end

	return self
end

--[[
Extra options:
  - `.family`: protocol family
  - `.host`: address to bind to (required if not `.path`)
  - `.port`: port to bind to (optional if tls isn't `nil`, in which case defaults to 80 for `.tls == false` or 443 if `.tls == true`)
  - `.path`: path to UNIX socket (required if not `.host`)
  - `.v6only`: allow ipv6 only (no ipv4-mapped-ipv6)
  - `.mode`: fchmod or chmod socket after creating UNIX domain socket
  - `.mask`: set and restore umask when binding UNIX domain socket
  - `.unlink`: unlink socket path before binding?
  - `.reuseaddr`: turn on SO_REUSEADDR flag?
  - `.reuseport`: turn on SO_REUSEPORT flag?
]]
local function listen(tbl)
	local tls = tbl.tls
	local host = tbl.host
	local path = tbl.path
	assert(host or path, "need host or path")
	local port = tbl.port
	if host and port == nil then
		if tls == true then
			port = "443"
		elseif tls == false then
			port = "80"
		else
			error("need port")
		end
	end
	local ctx = tbl.ctx
	if ctx == nil and tls ~= false then
		if host then
			ctx = new_ctx(host, tbl.version)
		else
			error("Custom OpenSSL context required when using a UNIX domain socket")
		end
	end
	local s, err, errno = ca.fileresult(cs.listen {
		family = tbl.family;
		host = host;
		port = port;
		path = path;
		mode = tbl.mode;
		mask = tbl.mask;
		unlink = tbl.unlink;
		reuseaddr = tbl.reuseaddr;
		reuseport = tbl.reuseport;
		v6only = tbl.v6only;
	})
	if not s then
		return nil, err, errno
	end
	return new_server {
		cq = tbl.cq;
		socket = s;
		onstream = tbl.onstream;
		onerror = tbl.onerror;
		tls = tls;
		ctx = ctx;
		version = tbl.version;
		h2c = tbl.h2c;
		h2_max_concurrent_streams = tbl.h2_max_concurrent_streams;
		max_concurrent = tbl.max_concurrent;
		connection_setup_timeout = tbl.connection_setup_timeout;
		intra_stream_timeout = tbl.intra_stream_timeout;
	}
end

function server_methods:onerror_(context, op, err, errno) -- luacheck: ignore 212
	local msg = op
	if err then
		msg = msg .. ": " .. tostring(err)
	end
	error(msg, 2)
end

function server_methods:onerror(...)
	local old_handler = self.onerror_
	if select("#", ...) > 0 then
		self.onerror_ = ...
	end
	return old_handler
end

-- Actually wait for and *do* the binding
-- Don't *need* to call this, as if not it will be done lazily
function server_methods:listen(timeout)
	if self.socket then
		local ok, err, errno = ca.fileresult(self.socket:listen(timeout))
		if not ok then
			return nil, err, errno
		end
	end
	return true
end

function server_methods:localname()
	if self.socket == nil then
		return
	end
	return ca.fileresult(self.socket:localname())
end

function server_methods:pause()
	self.paused = true
	self.pause_cond:signal()
	return true
end

function server_methods:resume()
	self.paused = false
	self.pause_cond:signal()
	return true
end

function server_methods:close()
	if self.cq then
		cqueues.cancel(self.cq:pollfd())
		cqueues.poll()
		cqueues.poll()
		self.cq = nil
	end
	if self.socket then
		self.socket:close()
		self.socket = nil
	end
	self.pause_cond:signal()
	self.connection_done:signal()
	return true
end

function server_methods:pollfd()
	return self.cq:pollfd()
end

function server_methods:events()
	return self.cq:events()
end

function server_methods:timeout()
	return self.cq:timeout()
end

function server_methods:empty()
	return self.cq:empty()
end

function server_methods:step(...)
	return self.cq:step(...)
end

function server_methods:loop(...)
	return self.cq:loop(...)
end

function server_methods:add_socket(socket)
	self.n_connections = self.n_connections + 1
	-- ONE CONNECTION MUST NOT BE ABLE TO KILL THE SERVER, and until this
	-- wrapper existed it could.
	--
	-- `cq:wrap` puts each connection in its own coroutine, and cqueues
	-- propagates a raise out of `cq:loop()`. So an unexpected error anywhere
	-- under `handle_socket` -- the framing layers, the TLS handshake, a
	-- vendored parser meeting bytes it did not consider -- travelled out of
	-- `app:run` and took the ACCEPT LOOP with it. The process stayed up and
	-- the listening socket stayed open, and nothing was ever accepted again.
	--
	-- That is not hypothetical. It happened twice in this tree, from opposite
	-- directions: `Content-Length: banana` on the h1 side, recorded in
	-- `akkar/init.lua`, and a three-byte HTTP/2 frame header found by
	-- `spec/h2_framing_spec.lua` on its first run. Both were one-line parser
	-- bugs; both were total outages. The next one is a parser bug nobody has
	-- found yet, and this is what decides whether it costs one connection or
	-- the server.
	--
	-- THE BOOKKEEPING IS THE SUBTLE PART. `handle_socket` decrements
	-- `n_connections` and signals `connection_done` on its LAST two lines, so
	-- a raise skips both -- and a connection count that only goes up walls
	-- the server off at `max_concurrent` just as completely, only slower.
	-- Done here exactly when the raise happened, so the normal path still
	-- does it exactly once.
	self.cq:wrap(function()
		local ok, err = xpcall(handle_socket, debug.traceback, self, socket)
		if not ok then
			self.n_connections = self.n_connections - 1
			self.connection_done:signal(1)
			pcall(function() socket:close() end)
			-- Reported as its own operation, never as transport noise: a
			-- connection that raised is a BUG, and `akkar/init.lua` logs it at
			-- error level for the same reason it does `onstream`.
			pcall(self:onerror(), self, socket, "connection", err)
		end
	end)
	return true
end

function server_methods:add_stream(stream)
	self.cq:wrap(handle_stream, self, stream)
	return true
end

return {
	new = new_server;
	listen = listen;
	mt = server_mt;
	-- EXPORTED because akkar builds its own TLS context from `certificate`
	-- and `key` instead of going through `new_ctx` below, and a context that
	-- never gets an ALPN callback never offers h2 -- which is exactly the bug
	-- this export fixes. A browser then negotiates HTTP/1.1 against a server
	-- that speaks HTTP/2 perfectly well, and nothing anywhere reports an
	-- error: the handshake succeeds, the request is answered, and the
	-- multiplexing simply never happens.
	alpn_select = alpn_select;
}
