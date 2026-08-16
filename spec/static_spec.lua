--[[
akkar.static — the traversal table is the spec.

Everything else in this file is comfort. `M.resolve` is pure -- no io, no lfs,
no os -- precisely so the cases that matter can be a list of strings run
against a function, with no directory tree to get wrong and nothing to clean
up. If one assertion in this file is worth keeping it is the loop in
"paths that must never escape".

The tree under `spec/.static-fixture` is built and torn down per describe
block, and it exists for the half that a pure function cannot answer: does a
real request for a real file come back, is the second one a 304, and does a
symlink pointing at `/etc` get refused.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local static = require "akkar.static"

local lfs_ok, lfs = pcall(require, "lfs")
if not lfs_ok then lfs = nil end

-- =============================================================== the fixture
local ROOT = "spec/.static-fixture"

local function write_file(path, contents)
  local handle = assert(io.open(path, "wb"))
  handle:write(contents)
  handle:close()
end

local function mkdir(path)
  -- `lfs.mkdir` when it is there, `mkdir -p` when it is not. Shelling out is
  -- unacceptable on a request path and perfectly fine in a fixture, which is
  -- the whole distinction `akkar/compress.lua` draws about `io.popen`.
  if lfs then lfs.mkdir(path)
  else assert(os.execute("mkdir -p " .. string.format("%q", path))) end
end

local function build_fixture()
  os.execute("rm -rf " .. string.format("%q", ROOT))
  mkdir(ROOT)
  mkdir(ROOT .. "/nested")
  write_file(ROOT .. "/hello.txt", "hello, world\n")
  write_file(ROOT .. "/app.css", "body{color:red}")
  write_file(ROOT .. "/pixel.png", "\137PNG\r\n\26\n" .. string.rep("\0", 40))
  write_file(ROOT .. "/index.html", "<h1>root index</h1>")
  write_file(ROOT .. "/nested/index.html", "<h1>nested index</h1>")
  write_file(ROOT .. "/nested/deep.txt", "deep\n")
  write_file(ROOT .. "/.env", "DATABASE_URL=postgres://real:secret@db/prod")
  write_file(ROOT .. "/big.bin", string.rep("0123456789", 1000))   -- 10,000 bytes
  write_file(ROOT .. "/ranged.txt", "0123456789")
end

local function destroy_fixture()
  os.execute("rm -rf " .. string.format("%q", ROOT))
end

--- Metadata that does not depend on `lfs` being installed.
---
--- THIS SEAM IS THE REASON THE CONDITIONAL TESTS CAN EXIST AT ALL.
--- `.github/workflows/ci.yml` installs `luaossl http lua-cjson pgmoon
--- luasocket busted` and nothing else, so `lfs` is absent in CI and the
--- default stat there cannot produce an mtime. Injecting one makes every
--- assertion about ETags, Last-Modified and 304 mean the same thing on both
--- machines.
local FIXED_MTIME = 1700000000

local function fake_stat(sizes)
  return function(path)
    local entry = sizes[path]
    if not entry then return nil end
    return { kind = entry.kind or "file", size = entry.size,
             mtime = entry.mtime or FIXED_MTIME }
  end
end

local function serve(options)
  options = options or {}
  if options.root == nil then options.root = ROOT end
  local app = akkar.new()
  app:use(static.new(options))
  app:get("/fallback", function() return { reached = "the route" } end)
  return app:test()
end

-- ============================================================ path traversal
describe("paths that must never escape", function()
  -- ONE LOOP, AND IT IS THE POINT OF THE MODULE.
  --
  -- Each of these has been a real vulnerability in a real server. They are
  -- grouped by the trick rather than by the encoding, because the encoding is
  -- the part that varies and the trick is the part that does not.
  local ESCAPES = {
    -- The plain form.
    "/../etc/passwd",
    "/../../etc/passwd",
    "/../../../../../../../../etc/passwd",
    "/a/../../etc/passwd",
    "/nested/../../etc/passwd",

    -- Percent-encoded, which is the form a filter that inspects the raw path
    -- never sees.
    "/..%2fetc/passwd",
    "/%2e%2e/etc/passwd",
    "/%2e%2e%2fetc%2fpasswd",
    "/%2E%2E%2Fetc%2Fpasswd",              -- uppercase hex, same bytes
    "/nested/%2e%2e/%2e%2e/etc/passwd",

    -- Mixed, because a filter that handles one form rarely handles both.
    "/%2e./etc/passwd",
    "/.%2e/etc/passwd",
    "/..%2F..%2Fetc/passwd",

    -- A NUL byte, which truncates a string for anything holding a C string
    -- underneath and would make the extension check inspect `.txt` while the
    -- filesystem opened something else.
    "/hello.txt%00.png",
    "/%00/etc/passwd",

    -- Backslashes. A separator on Windows and not on Linux, so refusing the
    -- byte means this module needs no opinion about which it is running on.
    "/..\\..\\etc\\passwd",
    "/%2e%2e%5cetc%5cpasswd",

    -- Header injection through the path, which would end up in a log line or,
    -- worse, in a response header.
    "/hello%0d%0aX-Injected:%20yes",
  }

  it("refuses every one of them", function()
    for _, attempt in ipairs(ESCAPES) do
      local absolute, reason = static.resolve(ROOT, attempt)
      assert.is_nil(absolute,
        ("%q resolved to %s"):format(attempt, tostring(absolute)))
      assert.is_string(reason)
    end
  end)

  it("refuses them through a live request, with 404 and no detail", function()
    build_fixture()
    finally(destroy_fixture)
    local client = serve { prefix = "/assets" }

    for _, attempt in ipairs(ESCAPES) do
      local res = client:get("/assets" .. attempt)
      assert.equal(404, res.status, ("%q was not refused"):format(attempt))
      -- One status for every refusal. A 403 for a traversal and a 404 for a
      -- missing file is an oracle: it tells a prober which of its guesses
      -- touched a real directory, one request at a time.
      assert.equal("not found", res.body.error)
    end
  end)

  it("does NOT double-decode, because double-decoding is the vulnerability", function()
    -- One decode turns `%252e%252e%252f` into the literal `%2e%2e%2f`, which
    -- is a strange but harmless filename. A server that decodes, checks and
    -- decodes again turns it into `../` on the second pass -- so the defence
    -- against traversal becomes the traversal.
    local absolute, relative = static.resolve(ROOT, "/%252e%252e%252fetc")
    assert.is_truthy(absolute, "one decode leaves a literal filename, not a parent")
    assert.equal("%2e%2e%2fetc", relative)
    assert.is_truthy(absolute:find(ROOT, 1, true) == 1)
  end)

  it("is not fooled by `....//`, and does not need to recognise it", function()
    -- This string defeats every filter that works by DELETING `../` from the
    -- path: delete the inner `../` from `....//` and `../` is what is left.
    -- Nothing here deletes anything. `....` is one whole segment, it is an
    -- ordinary directory name, and it gets a 404 for not existing rather than
    -- for being an attack.
    --
    -- `dotfiles = true` here to isolate what is under test. With the default
    -- policy this same path is refused a second time, one rule earlier, for
    -- starting with a dot -- which is belt and braces rather than the thing
    -- being proved, and is asserted separately below.
    local allow = { dotfiles = true }
    local absolute, relative = static.resolve(ROOT, "/....//etc/passwd", allow)
    assert.equal(ROOT .. "/..../etc/passwd", absolute)
    assert.equal("..../etc/passwd", relative)

    local deeper = select(2, static.resolve(ROOT, "/....//....//etc", allow))
    assert.equal("..../..../etc", deeper)

    -- Belt and braces: under the default policy it never even reaches the
    -- segment walker's verdict.
    local refused, why = static.resolve(ROOT, "/....//etc/passwd")
    assert.is_nil(refused)
    assert.equal("dotfile", why)
  end)

  it("is not fooled by overlong UTF-8, and does not decode it to be safe", function()
    -- `%c0%af` is an OVERLONG UTF-8 encoding of `/` and `%c0%ae` of `.`. This
    -- is the IIS Unicode traversal of 2001, and the reason it does not work
    -- here is worth stating precisely, because it is not vigilance: NOTHING in
    -- this chain decodes UTF-8. A path is bytes to `M.decode`, bytes to the
    -- segment splitter, and bytes to `open(2)` on Linux. `\xC0\xAF` is
    -- therefore two ordinary bytes in a filename and never a separator.
    --
    -- The lesson is the opposite of "add a UTF-8 check": adding one would
    -- introduce a second decoding pass, and a second decoding pass is the
    -- vulnerability. What makes this safe is doing LESS.
    local absolute, relative = static.resolve(ROOT, "/%c0%ae%c0%ae/etc/passwd")
    assert.is_truthy(absolute)
    assert.equal("\xc0\xae\xc0\xae/etc/passwd", relative)
    assert.equal(ROOT .. "/\xc0\xae\xc0\xae/etc/passwd", absolute)
    assert.is_true(absolute:sub(1, #ROOT + 1) == ROOT .. "/")

    -- And the same trick in front of a real `..` is refused, by the dotfile
    -- rule rather than by any awareness of what `%c0%af` was meant to be.
    assert.is_nil(static.resolve(ROOT, "/..%c0%afetc/passwd"))
  end)

  it("refuses the semicolon and mixed-case variants too", function()
    -- `..;/` is a path-parameter trick that splits some parsers and not
    -- others; `%25%32%66` is `%2f` written for a server that decodes twice.
    for _, attempt in ipairs { "/..;/etc/passwd", "/..%25%32%66etc",
                               "/.%2E/etc", "/%2e%2e%2f%2e%2e%2fetc",
                               "/a/./../../etc" } do
      assert.is_nil(static.resolve(ROOT, attempt), attempt .. " was allowed")
    end
  end)

  it("treats an absolute-looking path as root-relative, never as absolute", function()
    -- `/assets//etc/passwd` and `/assets/etc/passwd` mean the same thing here:
    -- a file called `passwd` in a directory called `etc` INSIDE the root. The
    -- leading empty segments are discarded, not honoured.
    local absolute = static.resolve(ROOT, "//etc/passwd")
    assert.equal(ROOT .. "/etc/passwd", absolute)
    assert.is_truthy(absolute:sub(1, #ROOT + 1) == ROOT .. "/")

    assert.equal(ROOT .. "/etc/passwd", static.resolve(ROOT, "///////etc/passwd"))
  end)

  it("keeps `%2f` inside a segment as a separator, which is correct HERE", function()
    -- The opposite of what `akkar/init.lua` does for route parameters, and
    -- deliberately: a route parameter is one segment by definition, so
    -- decoding `%2f` early would smuggle a segment break into a `:id`. A file
    -- path has no such rule, and the decoded separator lands inside the root.
    local absolute, relative = static.resolve(ROOT, "/nested%2fdeep.txt")
    assert.equal("nested/deep.txt", relative)
    assert.equal(ROOT .. "/nested/deep.txt", absolute)
  end)

  it("normalises a root that is not in normal form", function()
    -- Not an attack -- a configuration mistake. It matters because the
    -- containment check compares strings, and a root carrying `./` or a
    -- doubled slash makes that comparison meaningless.
    assert.equal("public/a.txt", select(1, static.resolve("./public/", "/a.txt")))
    assert.equal("public/a.txt", select(1, static.resolve("public//", "/a.txt")))
    assert.equal("/srv/www/a.txt", select(1, static.resolve("/srv/www", "/a.txt")))
    assert.equal("/srv/a.txt", select(1, static.resolve("/srv/www/..", "/a.txt")))
  end)

  it("never resolves anything outside the root, over a fuzz of segments", function()
    -- A property rather than a case list: whatever comes out, if it came out
    -- at all, starts with the root followed by a separator.
    local pieces = { "..", ".", "%2e", "%2e%2e", "a", "", "....", "%2f", "%5c",
                     "..%2f", "x.txt", "%00", "nested" }
    local rng = math.randomseed and math.random or math.random
    math.randomseed(20260816)
    for _ = 1, 3000 do
      local parts = {}
      for _ = 1, rng(1, 6) do parts[#parts + 1] = pieces[rng(1, #pieces)] end
      local attempt = "/" .. table.concat(parts, "/")
      local absolute = static.resolve(ROOT, attempt)
      if absolute then
        assert.is_true(absolute == ROOT or absolute:sub(1, #ROOT + 1) == ROOT .. "/",
          ("%q resolved to %q, which is outside %q"):format(attempt, absolute, ROOT))
        assert.is_nil(absolute:find("/../", 1, true),
          ("%q resolved to %q, which still contains a parent"):format(attempt, absolute))
      end
    end
  end)
end)

-- ================================================================= dotfiles
describe("dotfiles", function()
  before_each(build_fixture)
  after_each(destroy_fixture)

  it("refuses to serve .env", function()
    -- The two most valuable files in a deployed application directory are
    -- `.env` and `.git/config`, and the way they get served is that somebody
    -- points a static root at a directory that has them in it.
    local res = serve { prefix = "/assets" }:get "/assets/.env"
    assert.equal(404, res.status)
    assert.is_nil(res.raw)
  end)

  it("refuses a dotfile reached through a subdirectory", function()
    assert.is_nil(static.resolve(ROOT, "/nested/.git/config"))
    assert.is_nil(static.resolve(ROOT, "/.git/config"))
  end)

  it("serves them when the operator asks, which is what .well-known is for", function()
    local res = serve { prefix = "/assets", dotfiles = true }:get "/assets/.env"
    assert.equal(200, res.status)
    assert.is_truthy(res.raw:find("DATABASE_URL", 1, true))
  end)
end)

-- ============================================================= serving files
describe("serving a file", function()
  before_each(build_fixture)
  after_each(destroy_fixture)

  it("returns the bytes, not a JSON encoding of them", function()
    -- A response `body` is a value the writer runs through `cjson.encode`, so
    -- handing it a PNG produces a JSON string of the PNG's bytes. `raw` is the
    -- field that goes on the wire untouched.
    local res = serve { prefix = "/assets" }:get "/assets/hello.txt"
    assert.equal(200, res.status)
    assert.equal("hello, world\n", res.raw)
    assert.is_nil(res.body)
  end)

  it("types by extension and never by content", function()
    assert.equal("text/css; charset=utf-8", static.content_type "app.css")
    assert.equal("text/css; charset=utf-8", static.content_type "/x/y/app.css")
    assert.equal("image/png", static.content_type "pixel.png")
    assert.equal("text/html; charset=utf-8", static.content_type "index.html")

    -- A `.txt` whose first bytes are `<html>` stays a `.txt`. Sniffing the
    -- content is how an uploaded file becomes a script executing on your
    -- origin: the extension is a fact the operator controls and the content is
    -- a fact the uploader controls.
    write_file(ROOT .. "/decoy.txt", "<html><script>alert(1)</script></html>")
    assert.equal("text/plain; charset=utf-8", static.content_type "decoy.txt")
    assert.equal(200, serve { prefix = "/assets" }:get("/assets/decoy.txt").status)
  end)

  it("cannot assert the type on the wire, and that is a gap in the TEST CLIENT", function()
    -- Stated rather than faked. `akkar/init.lua`'s writer puts the type on the
    -- wire from `res.content_type`, which is a FIELD and not a header, and
    -- `App:test` returns `{ status, body, raw, headers }` -- it never copies
    -- `content_type` across. So no spec in this repository can assert the
    -- Content-Type a response was actually served with.
    --
    -- Writing the type into `res.headers` instead would make it assertable and
    -- would emit the header TWICE on a real connection, since the writer
    -- appends its own. So the assertion below is the honest one: the type is
    -- proved on the pure function above, and the seam is reported rather than
    -- worked around.
    local res = serve { prefix = "/assets" }:get "/assets/app.css"
    assert.equal(200, res.status)
    assert.is_nil(res.headers["content-type"],
      "if this ever becomes non-nil, App:test grew the field and these tests can be stronger")
  end)

  it("serves an empty file as an empty 200, not as a 404", function()
    write_file(ROOT .. "/empty.txt", "")
    local res = serve { prefix = "/assets" }:get "/assets/empty.txt"
    assert.equal(200, res.status)
    assert.equal("", res.raw)
  end)

  it("falls back to octet-stream for an unknown extension, and to nosniff", function()
    assert.equal("application/octet-stream", static.content_type "thing.qqq")
    assert.equal("application/octet-stream", static.content_type "no-extension")
    -- Without `nosniff` a browser sniffs an octet-stream and may decide it is
    -- HTML, which reintroduces exactly what serving by-extension removes.
    local res = serve { prefix = "/assets" }:get "/assets/hello.txt"
    assert.equal("nosniff", res.headers["x-content-type-options"])
  end)

  it("takes the extension from the last segment, not from the whole path", function()
    -- A directory named `assets.js` must not decide the type of every file
    -- beneath it.
    assert.equal("application/octet-stream", static.content_type "assets.js/data")
    assert.equal("text/css; charset=utf-8", static.content_type "assets.js/app.css")
  end)

  it("serves an index for a directory, and never a listing", function()
    local client = serve { prefix = "/assets" }
    assert.equal("<h1>nested index</h1>", client:get("/assets/nested").raw)
    -- A listing is an information-disclosure default nobody consciously chose.
    -- With no index configured there is nothing to serve.
    local bare = serve { prefix = "/assets", index = false }:get "/assets/nested"
    assert.equal(404, bare.status)
  end)

  it("refuses an index that would escape the root", function()
    -- The configured index is a segment like any other and goes through the
    -- same resolution.
    local res = serve { prefix = "/assets", index = "../../../etc/passwd" }
      :get "/assets/nested"
    assert.equal(404, res.status)
  end)

  it("answers 404 for a missing file", function()
    assert.equal(404, serve { prefix = "/assets" }:get("/assets/nope.txt").status)
  end)

  it("does not answer 200 with an empty body for a directory", function()
    -- MEASURED, not assumed: `io.open("/tmp","rb")` SUCCEEDS on Linux and
    -- `seek("end")` reports 9223372036854775807. A static server built on
    -- io.open alone therefore answers 200 with an empty body for every
    -- directory under its root and believes each is 8 EiB. The stat fallback
    -- probes with a zero-length read to tell them apart.
    local res = serve { prefix = "/assets", index = false }:get "/assets/nested"
    assert.equal(404, res.status)
    assert.not_equal(200, res.status)
  end)

  it("hands unrelated paths to the rest of the chain", function()
    local res = serve { prefix = "/assets" }:get "/fallback"
    assert.equal(200, res.status)
    assert.equal("the route", res.body.reached)
  end)

  it("does not claim a path that merely starts with the prefix string", function()
    -- `/assetsomething` is not under `/assets`, and a naive `sub(1, #prefix)`
    -- comparison says it is.
    local app = akkar.new()
    app:use(static.new { root = ROOT, prefix = "/assets" })
    app:get("/assetsomething", function() return { mine = true } end)
    local res = app:test():get "/assetsomething"
    assert.equal(200, res.status)
    assert.is_true(res.body.mine)
  end)

  it("answers 405 with Allow for a write", function()
    local app = akkar.new()
    app:use(static.new { root = ROOT, prefix = "/assets" })
    app:put("/assets/hello.txt", function() return { wrote = true } end)
    local res = app:test():put("/assets/hello.txt", { body = {} })
    assert.equal(405, res.status)
    assert.equal("GET, HEAD", res.headers["allow"])
  end)

  it("can fall through instead of answering 404", function()
    local app = akkar.new()
    app:use(static.new { root = ROOT, prefix = "", fallthrough = true })
    app:get("/fallback", function() return { reached = "the route" } end)
    local res = app:test():get "/fallback"
    assert.equal(200, res.status)
    assert.equal("the route", res.body.reached)
  end)
end)

-- ======================================================= the stat fallback
describe("the metadata source CI actually runs", function()
  -- `.github/workflows/ci.yml` installs `luaossl http lua-cjson pgmoon
  -- luasocket busted` and nothing else, so `lfs` is absent there and
  -- `M.stat_io` is the implementation that ships. On a developer machine --
  -- which does have `lfs` -- not one line of it would otherwise ever run.
  before_each(build_fixture)
  after_each(destroy_fixture)

  it("reports a regular file with its size and no mtime", function()
    local info = static.stat_io(ROOT .. "/hello.txt")
    assert.equal("file", info.kind)
    assert.equal(13, info.size)
    -- No mtime is available at all, and inventing one with `os.time()` would
    -- produce a Last-Modified of "now" on every request. That is not a weaker
    -- validator; it is a wrong one.
    assert.is_nil(info.mtime)
  end)

  it("does not mistake a directory for an 8 EiB file", function()
    -- MEASURED: io.open on a directory succeeds and seek("end") answers
    -- 9223372036854775807.
    local info = static.stat_io(ROOT .. "/nested")
    assert.equal("directory", info.kind)
  end)

  it("does not mistake an EMPTY FILE for a directory", function()
    -- THE DEFECT THIS BLOCK EXISTS FOR. Both are at end of file and both
    -- answer nil to a zero-length read, so probing on the nil alone made
    -- every zero-byte file a directory -- and this module answered 404 for a
    -- `.gitkeep` that plainly exists. The error message separates them:
    -- a bare nil is EOF, `nil, "Is a directory", 21` is not.
    write_file(ROOT .. "/nothing.txt", "")
    local info = static.stat_io(ROOT .. "/nothing.txt")
    assert.equal("file", info.kind)
    assert.equal(0, info.size)
  end)

  it("returns nil for a path that is not there", function()
    assert.is_nil(static.stat_io(ROOT .. "/absent.txt"))
  end)

  it("serves correctly end to end through the fallback", function()
    local client = serve { prefix = "/assets", stat = static.stat_io }
    assert.equal("hello, world\n", client:get("/assets/hello.txt").raw)

    write_file(ROOT .. "/nothing.txt", "")
    local empty = client:get "/assets/nothing.txt"
    assert.equal(200, empty.status)
    assert.equal("", empty.raw)

    -- No metadata means no validators, and a full 200 every time. Stated, not
    -- worked around.
    local res = client:get "/assets/hello.txt"
    assert.is_nil(res.headers["etag"])
    assert.is_nil(res.headers["last-modified"])
  end)

  it("agrees with lfs about size and kind, where lfs exists to ask", function()
    if not static.stat_lfs then return end
    for _, name in ipairs { "/hello.txt", "/app.css", "/nested", "/big.bin" } do
      local a, b = static.stat_io(ROOT .. name), static.stat_lfs(ROOT .. name)
      assert.equal(b.kind, a.kind, name .. ": kind disagrees")
      if b.kind == "file" then
        assert.equal(b.size, a.size, name .. ": size disagrees")
      end
    end
  end)
end)

-- ================================================================== symlinks
describe("symlinks", function()
  before_each(build_fixture)
  after_each(destroy_fixture)

  it("refuses a file reached through a symlink pointing outside the root", function()
    -- The one escape no lexical check can catch: lexically the path never
    -- leaves the root, because the filesystem does the leaving.
    local made = os.execute("ln -s /etc " .. string.format("%q", ROOT .. "/escape"))
    assert.is_truthy(made, "could not create the symlink this test is about")

    local client = serve { prefix = "/assets" }
    local res = client:get "/assets/escape/passwd"

    if static.symlink_check then
      assert.equal(404, res.status, "a symlink out of the root was followed")
    else
      -- HONEST FAILURE MODE, ASSERTED RATHER THAN HIDDEN. Without `lfs` there
      -- is no way to ask whether a component is a link, so the protection
      -- does not exist and the module says so through this field. The test
      -- records what actually happens instead of pretending otherwise.
      assert.is_false(static.lfs_available)
      assert.is_true(res.status == 200 or res.status == 404,
        "with no lfs the symlink is simply followed or missing")
    end
  end)

  it("serves through a symlink when the operator asks for it", function()
    os.execute("ln -s hello.txt " .. string.format("%q", ROOT .. "/link.txt"))
    local res = serve { prefix = "/assets", follow_symlinks = true }
      :get "/assets/link.txt"
    assert.equal(200, res.status)
    assert.equal("hello, world\n", res.raw)
  end)

  it("reports truthfully whether the check is active", function()
    assert.equal(lfs ~= nil, static.symlink_check)
    assert.equal(lfs ~= nil, static.lfs_available)
  end)
end)

-- ======================================================= conditional requests
describe("a second request is a 304", function()
  before_each(build_fixture)
  after_each(destroy_fixture)

  -- The injected stat is what makes these run identically with and without
  -- `lfs`; see the note on `fake_stat`.
  local function client_with_metadata()
    return serve {
      prefix = "/assets",
      stat = fake_stat {
        [ROOT .. "/hello.txt"] = { size = 13, mtime = FIXED_MTIME },
      },
    }
  end

  it("tags with mtime-size, in hex, quoted", function()
    -- nginx's exact scheme, so a fleet running nginx for some paths and akkar
    -- for others does not produce two tag formats for one asset.
    local res = client_with_metadata():get "/assets/hello.txt"
    assert.equal(200, res.status)
    assert.equal(string.format('"%x-%x"', FIXED_MTIME, 13), res.headers["etag"])
    assert.equal(static.http_date(FIXED_MTIME), res.headers["last-modified"])
  end)

  it("answers 304 with no body to a matching If-None-Match", function()
    local client = client_with_metadata()
    local first = client:get "/assets/hello.txt"
    local again = client:get("/assets/hello.txt",
      { headers = { ["if-none-match"] = first.headers["etag"] } })

    assert.equal(304, again.status)
    assert.is_nil(again.body)
    assert.is_nil(again.raw)
    assert.equal(first.headers["etag"], again.headers["etag"],
      "a 304 must carry the validator, or the next request cannot be conditional")
  end)

  it("returns a real 304 response, not a bare table dressed as one", function()
    -- A bare table is NOT a response: akkar marks real ones with `__response`
    -- and turns anything else into a 200 whose body is that table. The client
    -- would then receive 200 with `{"status":304}`.
    local client = client_with_metadata()
    local tag = client:get("/assets/hello.txt").headers["etag"]
    local res = client:get("/assets/hello.txt", { headers = { ["if-none-match"] = tag } })
    assert.equal(304, res.status)
    assert.is_nil(res.body)
  end)

  it("accepts a weak validator on If-None-Match, unlike If-Match", function()
    -- RFC 9110: If-None-Match compares with the WEAK comparison function.
    local client = client_with_metadata()
    local tag = client:get("/assets/hello.txt").headers["etag"]
    local res = client:get("/assets/hello.txt",
      { headers = { ["if-none-match"] = "W/" .. tag } })
    assert.equal(304, res.status)
  end)

  it("sends the body when the tag is stale", function()
    local res = client_with_metadata():get("/assets/hello.txt",
      { headers = { ["if-none-match"] = '"deadbeef-1"' } })
    assert.equal(200, res.status)
    assert.equal("hello, world\n", res.raw)
  end)

  it("honours If-Modified-Since when there is no tag to compare", function()
    local client = client_with_metadata()
    local res = client:get("/assets/hello.txt",
      { headers = { ["if-modified-since"] = static.http_date(FIXED_MTIME) } })
    assert.equal(304, res.status)

    local older = client:get("/assets/hello.txt",
      { headers = { ["if-modified-since"] = static.http_date(FIXED_MTIME - 60) } })
    assert.equal(200, older.status)
  end)

  it("prefers the tag over the date when both arrive", function()
    -- The tag is exact and the date has one-second granularity, so honouring
    -- the date first would discard the better validator the client also sent.
    local res = client_with_metadata():get("/assets/hello.txt", { headers = {
      ["if-none-match"]     = '"stale-tag"',
      ["if-modified-since"] = static.http_date(FIXED_MTIME),
    } })
    assert.equal(200, res.status, "the exact validator said stale; the date must not override it")
  end)

  it("sends a full 200 for an If-Modified-Since it cannot parse", function()
    -- Only the IMF-fixdate form is accepted. An unparseable date means a full
    -- body, which is always correct and merely not optimal; mis-parsing one
    -- into the wrong epoch would not be.
    local res = client_with_metadata():get("/assets/hello.txt",
      { headers = { ["if-modified-since"] = "Sunday, 06-Nov-94 08:49:37 GMT" } })
    assert.equal(200, res.status)
  end)

  it("says nothing it cannot know when there is no mtime", function()
    -- The `lfs`-less shape, forced. A tag derived from size alone would call
    -- two different files of equal length the same representation, so there is
    -- no tag at all rather than a wrong one.
    local client = serve {
      prefix = "/assets",
      stat = function() return { kind = "file", size = 13, mtime = nil } end,
    }
    local res = client:get "/assets/hello.txt"
    assert.equal(200, res.status)
    assert.is_nil(res.headers["etag"])
    assert.is_nil(res.headers["last-modified"])
    assert.is_nil(static.etag_for { size = 13 })
  end)
end)

describe("HTTP dates, with no timezone anywhere", function()
  it("formats the RFC's own example", function()
    -- `os.time{...}` reads its table as LOCAL time, so the obvious parser is
    -- off by the machine's UTC offset -- zero on most servers, which is
    -- exactly why it survives review and then misbehaves on one laptop.
    assert.equal("Sun, 06 Nov 1994 08:49:37 GMT", static.http_date(784111777))
    assert.equal(784111777, static.parse_http_date "Sun, 06 Nov 1994 08:49:37 GMT")
  end)

  it("round-trips across leap years, century rules and the epoch", function()
    for _, epoch in ipairs { 0, 951782400, 4107542400, 1709164800, 1700000000,
                             2147483647, 253402300799 } do
      assert.equal(epoch, static.parse_http_date(static.http_date(epoch)),
        "failed to round-trip epoch " .. epoch)
    end
  end)

  it("refuses the obsolete formats rather than mis-parsing them", function()
    assert.is_nil(static.parse_http_date "Sunday, 06-Nov-94 08:49:37 GMT")
    assert.is_nil(static.parse_http_date "Sun Nov  6 08:49:37 1994")
    assert.is_nil(static.parse_http_date "not a date")
    assert.is_nil(static.parse_http_date(nil))
  end)
end)

-- ==================================================================== ranges
describe("range requests, single only and deliberately", function()
  before_each(build_fixture)
  after_each(destroy_fixture)

  local function ranged()
    return serve {
      prefix = "/assets",
      stat = fake_stat { [ROOT .. "/ranged.txt"] = { size = 10, mtime = FIXED_MTIME } },
    }
  end

  it("advertises that it accepts them", function()
    -- A client that does not see this header will not try, so a video would
    -- download whole before it played.
    assert.equal("bytes", ranged():get("/assets/ranged.txt").headers["accept-ranges"])
  end)

  it("answers 206 with Content-Range", function()
    local res = ranged():get("/assets/ranged.txt",
      { headers = { ["range"] = "bytes=2-5" } })
    assert.equal(206, res.status)
    assert.equal("2345", res.raw)
    assert.equal("bytes 2-5/10", res.headers["content-range"])
  end)

  it("reads an open-ended range to the end", function()
    local res = ranged():get("/assets/ranged.txt",
      { headers = { ["range"] = "bytes=7-" } })
    assert.equal(206, res.status)
    assert.equal("789", res.raw)
    assert.equal("bytes 7-9/10", res.headers["content-range"])
  end)

  it("reads a suffix range from the END, not from the start", function()
    -- `bytes=-3` is the LAST three bytes. Reading it as the first three is a
    -- one-character mistake that returns a plausible body and corrupts every
    -- resumed download.
    local res = ranged():get("/assets/ranged.txt",
      { headers = { ["range"] = "bytes=-3" } })
    assert.equal(206, res.status)
    assert.equal("789", res.raw)
    assert.equal("bytes 7-9/10", res.headers["content-range"])
  end)

  it("clamps a range that runs past the end", function()
    local first, last = static.parse_range("bytes=5-999", 10)
    assert.equal(5, first)
    assert.equal(9, last)
  end)

  it("answers 416 with the total size for an unsatisfiable range", function()
    -- Answering 200 to `bytes=5000-` on a 10-byte file lets the client believe
    -- it received the tail it asked for.
    local res = ranged():get("/assets/ranged.txt",
      { headers = { ["range"] = "bytes=50-60" } })
    assert.equal(416, res.status)
    assert.equal("bytes */10", res.headers["content-range"])
  end)

  it("answers a normal 200 to a multi-range request", function()
    -- NOT IMPLEMENTED, AND LEGAL. RFC 9110 permits a server to ignore a Range
    -- it will not honour. Doing it properly means a multipart/byteranges body
    -- -- a second body format inside a response -- and the honest position is
    -- that it is not written rather than written approximately.
    local res = ranged():get("/assets/ranged.txt",
      { headers = { ["range"] = "bytes=0-1,4-5" } })
    assert.equal(200, res.status)
    assert.equal("0123456789", res.raw)
    assert.is_nil(res.headers["content-range"])
  end)

  it("ignores a Range unit it does not speak", function()
    local res = ranged():get("/assets/ranged.txt",
      { headers = { ["range"] = "items=0-1" } })
    assert.equal(200, res.status)
    assert.equal("0123456789", res.raw)
  end)

  it("sends the whole file when If-Range does not match", function()
    -- The client is saying "send me the rest ONLY if this is the file I
    -- started". A mismatch means the file changed under a resumed download,
    -- and splicing two different files together is the failure this prevents.
    local res = ranged():get("/assets/ranged.txt", { headers = {
      ["range"]    = "bytes=2-5",
      ["if-range"] = '"a-different-file"',
    } })
    assert.equal(200, res.status)
    assert.equal("0123456789", res.raw)
  end)

  it("honours the range when If-Range matches", function()
    local client = ranged()
    local tag = client:get("/assets/ranged.txt").headers["etag"]
    local res = client:get("/assets/ranged.txt", { headers = {
      ["range"] = "bytes=2-5", ["if-range"] = tag,
    } })
    assert.equal(206, res.status)
    assert.equal("2345", res.raw)
  end)

  it("parses the shapes it accepts and declines the rest", function()
    assert.same({ 0, 499 }, { static.parse_range("bytes=0-499", 1000) })
    assert.same({ 500, 999 }, { static.parse_range("bytes=500-", 1000) })
    assert.same({ 500, 999 }, { static.parse_range("bytes=-500", 1000) })
    assert.same({ 0, 999 }, { static.parse_range("bytes=-5000", 1000) })

    assert.same({ nil, "ignore" }, { static.parse_range("bytes=abc", 1000) })
    assert.same({ nil, "ignore" }, { static.parse_range("bytes=1-2,3-4", 1000) })
    assert.same({ nil, "ignore" }, { static.parse_range(nil, 1000) })
    assert.same({ nil, "unsatisfiable" }, { static.parse_range("bytes=1000-", 1000) })
    assert.same({ nil, "unsatisfiable" }, { static.parse_range("bytes=5-3", 1000) })
    assert.same({ nil, "unsatisfiable" }, { static.parse_range("bytes=-0", 1000) })
  end)
end)

-- ================================================================= streaming
describe("a file too big to hold in memory", function()
  before_each(build_fixture)
  after_each(destroy_fixture)

  it("streams above the threshold instead of buffering", function()
    -- One request for a 400 MB asset holding 400 MB of RSS, and ten concurrent
    -- ones holding four gigabytes, is the failure this avoids.
    -- `akkar/multipart.lua` states the same limit for uploads.
    local client = serve { prefix = "/assets", max_bytes = 1024, chunk_size = 256 }
    local res = client:get "/assets/big.bin"

    assert.equal(200, res.status)
    assert.equal(10000, #res.raw)
    assert.equal(string.rep("0123456789", 1000), res.raw)
  end)

  it("streams a partial range too", function()
    local client = serve {
      prefix = "/assets", max_bytes = 100, chunk_size = 64,
      stat = fake_stat { [ROOT .. "/big.bin"] = { size = 10000, mtime = FIXED_MTIME } },
    }
    local res = client:get("/assets/big.bin", { headers = { ["range"] = "bytes=10-1009" } })

    assert.equal(206, res.status)
    assert.equal(1000, #res.raw)
    assert.equal(("0123456789"):rep(1000):sub(11, 1010), res.raw)
    assert.equal("bytes 10-1009/10000", res.headers["content-range"])
  end)

  it("buffers below the threshold", function()
    local res = serve { prefix = "/assets", max_bytes = 1024 * 1024 }
      :get "/assets/hello.txt"
    assert.equal("hello, world\n", res.raw)
  end)
end)

-- =============================================================== the headers
describe("caching headers", function()
  before_each(build_fixture)
  after_each(destroy_fixture)

  it("omits cache-control unless one was configured", function()
    assert.is_nil(serve { prefix = "/assets" }:get("/assets/hello.txt")
                    .headers["cache-control"])
  end)

  it("sends the configured max-age", function()
    local res = serve { prefix = "/assets", max_age = 31536000 }
      :get "/assets/hello.txt"
    assert.equal("public, max-age=31536000", res.headers["cache-control"])
  end)

  it("gives every response its own header table", function()
    -- The base headers are built once at registration. Handing that table out
    -- would make every response from this middleware alias one table -- the
    -- same defect `akkar/etag.lua` and `akkar/init.lua` document, reached by
    -- sharing rather than by mutation.
    local client = serve {
      prefix = "/assets",
      stat = fake_stat { [ROOT .. "/hello.txt"] = { size = 13, mtime = FIXED_MTIME },
                         [ROOT .. "/app.css"]   = { size = 15, mtime = FIXED_MTIME + 5 } },
    }
    local a = client:get "/assets/hello.txt"
    local b = client:get "/assets/app.css"

    assert.not_equal(a.headers["etag"], b.headers["etag"])
    assert.not_equal(a.headers["last-modified"], b.headers["last-modified"])

    -- And the FIRST response must still hold its own values after the second.
    local again = client:get "/assets/hello.txt"
    assert.equal(a.headers["etag"], again.headers["etag"])
  end)
end)

describe("registration", function()
  it("refuses to install without a root", function()
    local ok, err = pcall(static.new, {})
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("root", 1, true))
  end)
end)
