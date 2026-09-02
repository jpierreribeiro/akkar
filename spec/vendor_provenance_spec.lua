--[[
The vendored lua-http ledger, checked against the tree.

## The failure this file exists to make impossible

`akkar/vendor/http/README.md` was written on 2026-08-18 and was wrong
twenty-four hours later, in the two worst places available: it certified
`h2_connection.lua` as "byte-identical apart from require prefixes" and
`websocket.lua` as unmodified, and on 2026-08-19 five commits put akkar's own
denial-of-service repairs into exactly those two files.

Nothing caught it, and nothing could have. A re-vendor from stock 0.4 on the
strength of that table reverts a fix for a three-byte frame header that kills
the accept loop, an enforced MAX_CONCURRENT_STREAMS, a bounded WebSocket
message and a bounded h2 header block -- and **the whole suite still passes**,
because every test exercises akkar and every repair is in a dependency. The
regression is invisible until someone points a fuzzer at it again.

So the ledger is executable now. `akkar/vendor/http/PROVENANCE.md` is the
document; this file is the part that runs.

## What is asserted, and what deliberately is not

**Asserted: each patch is still where the ledger says it is.** Not by
checksum -- a checksum goes red on every legitimate edit to a vendored file,
and a check that cries wolf gets deleted. By a distinctive line from the patch
itself, so the assertion fails exactly when the patch is gone.

**Asserted: the two columns agree.** A file carrying a registered patch must be
listed as patched, and a file listed as unmodified must carry none. That is
the 2026-08-18 defect, stated as an invariant: the table cannot say
"unmodified" about a file this spec knows is patched.

**Asserted: the ledger is complete.** Every `.lua` in the directory has a row.
A file added without a row fails here rather than going unrecorded, which is
how `websocket.lua` spent a day being undocumented.

**NOT asserted: that the unmodified files really are byte-identical to
upstream.** That needs the upstream tag, and CI has no network. It is a
`PROVENANCE.md` step for a human re-vendoring, and the ledger says how.

**NOT asserted: that the patches WORK.** Each has its own spec --
`spec/h2_framing_spec.lua`, `spec/websocket_limits_spec.lua`,
`spec/connection_containment_spec.lua`, `spec/vendor_headers_spec.lua`,
`spec/vendor_backport_spec.lua`. This file only asserts they are still here,
which is the property those specs cannot check, because a reverted file makes
them pass or vanish rather than fail.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local DIR       = "akkar/vendor/http/"
local LEDGER    = DIR .. "PROVENANCE.md"
local UPSTREAM  = "799adaddd16bf14ac985cfd3c8dab8eed9da9570"

--- Every akkar patch to a vendored file, and the line that proves it is there.
---
--- `needle` is a PLAIN substring, matched with `find(..., 1, true)`: a Lua
--- pattern here would turn every `%` and `-` in vendored source into a silent
--- non-match, which is the way this kind of check fails without telling you.
---
--- Adding a patch to a vendored file means adding a row here AND a row in
--- PROVENANCE.md. The two are cross-checked below, so doing one is caught.
local PATCHES = {
  -- ------------------------------------------------ ends a process, or a machine
  { file = "h2_connection.lua", commit = "d577d10",
    needle = "if #frame_header < 9 then",
    why = "a 3-byte frame header raises out of app:run and the accept loop dies" },
  { file = "h2_connection.lua", commit = "10f74b0",
    needle = "max_peer_streams",
    why = "MAX_CONCURRENT_STREAMS enforced; upstream advertises math.huge and TODOs the check" },
  { file = "h2_connection.lua", commit = "3dc168f",
    needle = "self.socket:xread(-4096, 0)",
    why = "drain before shutdown, or the kernel sends RST and discards the peer's frames" },
  { file = "h2_stream.lua", commit = "89c7bd0",
    needle = "MAX_HEADER_BUFFER_ITEMS",
    why = "empty CONTINUATION frames never reach the byte cap; 32 MB of heap for 18 MB of traffic" },
  { file = "websocket.lua", commit = "b3f5577",
    needle = "max_payload",
    why = "a frame is refused on its declared length, before fill() buffers it" },
  { file = "websocket.lua", commit = "b3f5577",
    needle = "databuffer_size",
    why = "and the sum of the fragments, which the per-frame bound cannot see" },
  { file = "server.lua", commit = "0c1d20d",
    needle = "xpcall(handle_socket, debug.traceback",
    why = "an error out of one connection ended the process and leaked the connection slot" },
  { file = "h1_stream.lua", commit = "0b3750e",
    needle = "if idle > 8 then",
    why = "step(0) can answer true for ever without advancing; one header spun a core" },
  { file = "h1_stream.lua", commit = "0b3750e",
    needle = "pcall(self.step, self, 0)",
    why = "Content-Length: -5 raised out of shutdown, which handle_stream does not protect" },

  -- ------------------------------------------------------- upstream, post-v0.4
  { file = "h1_stream.lua", commit = "ddab283 (upstream)",
    needle = "BACKPORT of upstream ddab283",
    why = "EOF on a length body was a clean end, so a truncated response looked complete" },
  { file = "request.lua", commit = "059ae00 (upstream)",
    needle = '~= "304"',
    why = "304 begins with a 3 and has no location, so go() failed a valid conditional answer" },

  -- ------------------------------------------------------- measured, not fatal
  { file = "headers.lua", commit = "4363754",
    needle = "self._names",
    why = "parallel name/value arrays: 125.0 B -> 41.9 B a header" },
  { file = "h1_connection.lua", commit = "e414be9",
    -- The byte-wise trim that replaced `(.-)[ \\t]*$`, chosen over the
    -- `match` line itself because that one is all pattern escapes and a
    -- needle full of them is a needle that silently stops matching.
    needle = "if c ~= 32 and c ~= 9 then break end",
    why = "the trailing-space strip backtracked across the whole value" },
  { file = "h1_stream.lua", commit = "e84eca6",
    needle = "function stream_methods:queue_chunk",
    why = "the read-ahead fifo is built only when something is read ahead" },
  { file = "server.lua", commit = "d5a4025",
    needle = "if conn.version and conn.version < 2 then",
    why = "HTTP/1.1 runs its stream inline; the condition is what let h2 come back" },
  { file = "server.lua", commit = "de1a6a3",
    needle = "local function h2_module()",
    why = "h2 deferred out of the boot path: 19 ms of 47.6 and 5 modules of 69" },
  { file = "server.lua", commit = "20e539e",
    needle = "if self.h2c then",
    why = "cleartext h2 is opt-in; upstream sniffs every h1 connection for the preface" },
  { file = "server.lua", commit = "20e539e",
    needle = "alpn_select = alpn_select;",
    why = "alpn_select is exported, and no longer demands TLS 1.2 for h2" },

  -- ------------------------------------------------------ removals and identity
  { file = "request.lua", commit = "0b3750e",
    needle = "this build does not support SOCKS proxies",
    why = "socks.lua is not carried; it was the other module pulling in compat53" },
  { file = "client.lua", commit = "20e539e",
    needle = "A dead branch that",
    why = "records why upstream's ALPN body was restored rather than left empty" },
  { file = "version.lua", commit = "provenance",
    needle = "0.4+akkar",
    why = "this tree must not answer '0.4' to anyone deciding whether to re-vendor" },
}

local function slurp(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local text = fh:read "a"
  fh:close()
  return text
end

--- The `.lua` files actually sitting in the vendored directory.
---
--- `ls` rather than `lfs`: the same call `spec/000_strict_first_spec.lua`
--- makes, and lfs is not a declared dependency of this rock.
local function vendored_files()
  local pipe = io.popen("ls -1 " .. DIR .. "*.lua 2>/dev/null")
  if not pipe then return nil end
  local out = {}
  for line in pipe:lines() do
    local base = line:match "([^/]+)$"
    if base then out[#out + 1] = base end
  end
  pipe:close()
  if #out == 0 then return nil end
  return out
end

--- The ledger's own table, as {file = "patched"|"unmodified"}.
local function ledger_rows(text)
  local rows = {}
  for file, state in text:gmatch "|%s*`([%w_]+%.lua)`%s*|%s*(%a+)%s*|" do
    assert(rows[file] == nil, file .. " has two rows in " .. LEDGER)
    rows[file] = state
  end
  return rows
end

describe("the vendored lua-http ledger", function()
  local ledger = slurp(LEDGER)
  local rows = ledger and ledger_rows(ledger) or {}

  it("has a ledger at all", function()
    assert.is_string(ledger, LEDGER .. " is missing; the vendored tree is undocumented")
    assert.is_truthy(ledger:find(UPSTREAM, 1, true),
                     LEDGER .. " must name the upstream commit it was taken from")
  end)

  -- ================================================ the patches are still there

  for _, patch in ipairs(PATCHES) do
    it(("keeps %s's patch from %s"):format(patch.file, patch.commit), function()
      local src = slurp(DIR .. patch.file)
      assert.is_string(src, DIR .. patch.file .. " is missing")
      assert.is_truthy(src:find(patch.needle, 1, true), ([[

%s no longer contains the patch added by %s.

  looked for: %s
  why it matters: %s

If this is a re-vendor from upstream, the patch was reverted and must be
re-applied -- see %s. If the patch was deliberately removed or rewritten,
remove or update its row in spec/vendor_provenance_spec.lua AND in the ledger.
]]):format(patch.file, patch.commit, patch.needle, patch.why, LEDGER))
    end)
  end

  -- ==================================================== the two columns agree

  it("lists every patched file as patched", function()
    -- THE 2026-08-18 DEFECT, AS AN INVARIANT. The old table said
    -- `h2_connection.lua` and `websocket.lua` were untouched while both
    -- carried DoS repairs. A ledger cannot say that here and stay green.
    local seen = {}
    for _, patch in ipairs(PATCHES) do seen[patch.file] = true end
    for file in pairs(seen) do
      assert.equal("patched", rows[file],
        ("%s carries a registered patch but %s calls it '%s'")
        :format(file, LEDGER, tostring(rows[file])))
    end
  end)

  it("registers a patch for every file the ledger calls patched", function()
    -- The other direction, and the one that catches a patch landing with no
    -- guard: if the ledger says a file diverges, this spec must know why.
    local seen = {}
    for _, patch in ipairs(PATCHES) do seen[patch.file] = true end
    for file, state in pairs(rows) do
      if state == "patched" then
        assert.is_true(seen[file] or false,
          ("%s calls %s patched, but no patch is registered for it here")
          :format(LEDGER, file))
      end
    end
  end)

  it("accounts for every file in the directory", function()
    local files = vendored_files()
    if not files then return end -- no `ls`; the rest of the file still holds
    for _, file in ipairs(files) do
      assert.is_truthy(rows[file],
        ("%s is vendored but has no row in %s"):format(file, LEDGER))
    end
    for file in pairs(rows) do
      assert.is_truthy(slurp(DIR .. file),
        ("%s has a row in %s but is not in the tree"):format(file, LEDGER))
    end
  end)

  -- ======================================================== identity, and drift

  it("does not let version.lua claim to be stock upstream", function()
    local version = require "akkar.vendor.http.version"
    assert.not_equal("0.4", version.version,
      "version.lua answers plain '0.4' while the tree carries thousands of "
      .. "patched lines; that string is what talks a re-vendor into itself")
    assert.equal(UPSTREAM, version.akkar_upstream_commit,
      "version.lua and this spec disagree about which upstream commit this is")
    assert.is_truthy(slurp(version.akkar_provenance),
      "version.lua points at a ledger that is not there")
  end)

  -- ============================ the two backports, checked where they must be

  it("puts the ddab283 EPIPE in the `length` branch and nowhere else", function()
    -- The needle above only proves the comment survived. This proves the
    -- CODE is in the branch it belongs to: upstream's own EPIPE lives in the
    -- `chunked` branch, so a naive re-apply can satisfy a grep while leaving
    -- the length branch answering `nil, nil` exactly as before.
    local src = assert(slurp(DIR .. "h1_stream.lua"))
    local branch = src:match 'body_read_type == "length".-elseif self%.body_read_type == "close"'
    assert.is_string(branch, "the `length` branch of read_next_chunk moved; re-anchor this check")
    assert.is_truthy(branch:find("ce.EPIPE", 1, true),
      "a peer that hangs up mid-body is being reported as a clean end of body")
  end)

  it("excludes 304 in the redirect condition itself", function()
    local src = assert(slurp(DIR .. "request.lua"))
    local cond = src:match "if self%.follow_redirects and.-then"
    assert.is_string(cond, "the redirect condition moved; re-anchor this check")
    assert.is_truthy(cond:find('~= "304"', 1, true),
      "304 is being handled as a redirect, which fails every conditional request")
  end)
end)
