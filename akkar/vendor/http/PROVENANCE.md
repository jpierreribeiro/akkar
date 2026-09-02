# lua-http, vendored — provenance

**This file is the ledger. `spec/vendor_provenance_spec.lua` checks it against
the tree on every CI run**, so it cannot quietly stop being true the way the
one before it did.

## What this tree is

| | |
|---|---|
| upstream | <https://github.com/daurnimator/lua-http>, by Daurnimator, MIT (`LICENSE.md`) |
| base | tag `v0.4`, commit `799adaddd16bf14ac985cfd3c8dab8eed9da9570`, released 2021-02-06 |
| vendored from | `http/*.lua` of that tag |
| verified against upstream | 2026-09-02 |
| files carried | 22 of the tag's 23 `http/*.lua`; `socks.lua` is **not** carried, nor is `compat/` (2 more) |

The only mechanical transformation is the module prefix. Every

    require "http.X"      -->  require "akkar.vendor.http.X"

and nothing else: no reformatting, no reindentation, no reordering. The
ledger below was produced by applying exactly that substitution to a checkout
of the tag and diffing file by file, which is also how to reproduce it.

## Why the last provenance file rotted, and what stops this one

The file this replaces was written on 2026-08-18 and was **wrong within
twenty-four hours**, in the worst possible place: it certified
`h2_connection.lua` as "byte-identical apart from require prefixes" and
`websocket.lua` as unmodified, and on 2026-08-19 five commits put akkar's own
denial-of-service repairs into exactly those two files. It said so in prose,
which nothing executes.

Anyone re-vendoring from stock 0.4 on the strength of that table would have
silently reverted every one of those repairs, and every test in the suite
would still have passed, because the tests exercise akkar and the repairs are
in a dependency.

So the guarantee here is not that this file is well written. It is that
`spec/vendor_provenance_spec.lua`:

1. asserts every patch below is **still present in the file it claims**, by a
   distinctive line from the patch itself — a re-vendor that reverts one turns
   CI red and names the akkar commit that put it there;
2. asserts the two columns agree — a file with a patch must be listed as
   patched, and a file listed as unmodified must have no patch registered —
   which is the exact defect above, made unrepresentable;
3. asserts every `.lua` file in this directory has a row, so a file added
   without a row fails rather than going unrecorded;
4. asserts `version.lua` does not claim to be plain `0.4`.

**Adding a patch to a vendored file therefore means adding its row here.**
That is the point: the ledger is not documentation of the patches, it is part
of them.

**Where it still cannot see.** A NEW patch added to a file that is already
listed as patched has no guard until someone writes one, so the spec will not
notice it going missing. That is the remaining hole, and it closes one row at a
time. (At the time of writing there is uncommitted work in the tree adding
accept-loop backpressure to `server.lua` -- `RETRY_LATER`, EMFILE/ENFILE. It
needs a row here and a needle in the spec when it lands.) The spec also cannot
check the *unmodified* half of the ledger without the upstream tag, which CI
has no network to fetch; that stays a step for whoever re-vendors.

## The ledger

Line counts are against the prefix-normalised upstream tag, measured
2026-09-02; `hunks` is the number of separate places the file differs.

**The numbers are informative and the state column is not.** Only the state is
checked by the spec, deliberately: a line count goes stale the moment anyone
edits a vendored file for any reason, and a check that goes red on correct work
is a check somebody deletes. Re-measure them when you re-vendor; do not chase
them in between.

| file | state | ± | hunks |
|---|---|---:|---:|
| `bit.lua` | unmodified | | |
| `client.lua` | patched | +6 / −0 | 1 |
| `connection_common.lua` | unmodified | | |
| `cookie.lua` | unmodified | | |
| `h1_connection.lua` | patched | +56 / −5 | 3 |
| `h1_reason_phrases.lua` | unmodified | | |
| `h1_stream.lua` | patched | +144 / −24 | 10 |
| `h2_connection.lua` | patched | +80 / −2 | 6 |
| `h2_error.lua` | unmodified | | |
| `h2_stream.lua` | patched | +23 / −0 | 2 |
| `headers.lua` | patched | +144 / −78 | 8 |
| `hpack.lua` | unmodified | | |
| `hsts.lua` | unmodified | | |
| `proxies.lua` | unmodified | | |
| `request.lua` | patched | +14 / −19 | 3 |
| `server.lua` | patched | +282 / −26 | 13 |
| `stream_common.lua` | unmodified | | |
| `tls.lua` | unmodified | | |
| `util.lua` | unmodified | | |
| `version.lua` | patched | +22 / −3 | 1 |
| `websocket.lua` | patched | +42 / −2 | 5 |
| `zlib.lua` | unmodified | | |

`websocket.lua` was not in the first vendoring at all; it arrived whole from
the same v0.4 tag in `01df758` and was patched in `b3f5577`.

## The patches, and why each one must survive a re-vendor

Ordered by what it costs to lose. The first six are the ones that end a
process or exhaust a machine; losing any of them is a live denial of service
against every application built on akkar.

### Security — losing these reopens a denial of service

**`h2_connection.lua` — a short frame header no longer kills the process.**
`d577d10`. `xread(9)` returns what it has when the peer hangs up, so three
bytes produce a three-byte string that is not `nil`, and `sunpack(">I3 B B
I4", ...)` raises "data string too short". The raise travels out of the
connection, out of the server loop and out of `app:run`: the process stays up,
the listening socket stays open, and **nothing is ever accepted again** — over
HTTP/1.1 as well, because what died is the accept loop. Found by the h2 fuzzer
on its first run. Guard: `if #frame_header < 9 then`.

**`h2_connection.lua` — MAX_CONCURRENT_STREAMS is enforced, not advertised.**
`10f74b0`. Upstream leaves a `TODO: check MAX_CONCURRENT_STREAMS` and
advertises `math.huge`; measured, 500 concurrent streams went through on one
connection at ~10 KB each, and the connection limiter never saw them because
it counts connections and that was one. Refused with `REFUSED_STREAM` *after*
the handler, so HPACK still decodes the block — skipping it desynchronises
every later stream on the connection (RFC 7540 §6.8). Guard:
`max_peer_streams`.

**`h2_stream.lua` — a header block is bounded by frame count, not only bytes.**
`89c7bd0`. A CONTINUATION frame with a zero-length payload adds nothing to the
byte total, so the 400 KB cap can never fire on a stream of them while each
one still appends to the buffer. Measured: two million empty frames accepted,
byte total still zero, 32 MB of Lua heap, nothing refused — 18 MB of traffic
for 32 MB that is never freed, on one unauthenticated connection. Guard:
`MAX_HEADER_BUFFER_ITEMS`.

**`websocket.lua` — a message is bounded before it is buffered.**
`b3f5577`. `sock:fill()` commits the whole payload to the socket buffer, so a
check placed after it has already paid for the attack. Measured before this
existed: one 64 MB message cost 192 MB of RSS while the application's
`body_limit` said one megabyte. Two bounds, because one is not enough — the
declared frame length, and the running sum of the fragments, since a thousand
legal 1 MB fragments are one illegal message. Refused as `EFBIG` and turned
into an RFC 6455 close code 1009. Guards: `max_payload`, `databuffer_size`.

**`server.lua` — one connection can no longer kill the server.**
`0c1d20d`. `handle_socket` was wrapped bare; an error out of it escaped
`cq:loop()` and ended the process, and the connection accounting was never
decremented on that path, so the connection limit leaked toward zero. Now
`xpcall` with a traceback, the accounting released, the socket closed and the
error handed to `onerror`. Guard: `xpcall(handle_socket, debug.traceback`.

**`h1_stream.lua` — the shutdown spin and the negative Content-Length.**
`0b3750e`, folded in from monkey-patches that lived in `akkar/substrate.lua`.
(1) `step(0)` can return true while `stats_recv` never advances, so the drain
loop burns a core for ever; one header is enough to trigger it, and the fix is
eight idle steps and out. (2) `Content-Length: -5` reaches `read_next_chunk` as
`error("invalid length")`, and `handle_stream` calls `shutdown` with no pcall
— one malformed header ended the process. Guards: `if idle > 8 then`, and the
protected `step` call above it.

### Backports — fixes upstream made after v0.4 and never released

Upstream's last release is v0.4 (2021) and its last commit is 2024-09-08.
Three post-v0.4 commits touch shipped code; two of them matter here and both
were absent until 2026-09-01.

**`h1_stream.lua` — EOF on a `length` body is EPIPE, not a clean end.**
Upstream `ddab283` (2023-08-22). A peer that announces `content-length: 100`
and hangs up after forty bytes produced `nil, nil` from `read_next_chunk`,
which every caller reads as *the body ended*. Two consequences, and the second
is the reason this is filed under security in spirit: `shutdown` drains until
the body is done, so it drains for ever; and `akkar.http`'s `read_bounded`
treats `err == nil` as a clean end, so **a truncated response was handed to
the caller as a complete short one** — the precise outcome that function's own
comment says must never happen. Guard: the `elseif err == nil` in the
`body_read_type == "length"` branch. Proved by
`spec/vendor_backport_spec.lua`.

**`request.lua` — 304 is not a redirect.**
Upstream `059ae00` (2024-09-06). `304 Not Modified` begins with a 3 and
carries no `location`, so `request:go()` called `handle_redirect`, found no
`location`, and returned `nil, "missing location header for redirect",
EINVAL`. A correct conditional-request answer surfaced as a failed request.
Note the blast radius honestly: `akkar.http` does **not** call `go()` — it
drives a pooled connection directly — so this reaches users of the vendored
`akkar.vendor.http.request` module rather than `akkar.http`'s own client.
Guard: `~= "304"`. Proved by `spec/vendor_backport_spec.lua`.

The third, upstream `1c691a1`, renames a local in `headers.lua` to please
luacheck. It is not carried because that function no longer exists here; see
the `headers.lua` entry below.

### Allocation and boot — losing these is a measured regression, not an outage

**`headers.lua` — the storage shape.** `6addb0e`, `ed23e89`, `4363754`. Three
changes, each priced: `never_index` dropped from every entry (−432 B/request,
and HTTP/2's never-index flag was never read by anything here); `_index[name]`
holds an integer until a name repeats and only then promotes to the old table
(−1,780 B); and the per-header entry table is gone in favour of parallel
`_names`/`_values` arrays (125.0 B → 41.9 B per header, measured over 50,000
of each). This is an internal shape, not an API.
`spec/vendor_headers_spec.lua` tests the structure directly, because the way
these fail is quiet — a reader that knows one shape drops a `set-cookie`.
Guard: `self._names`.

**`h1_stream.lua` — the lazy chunk queue and the constructor's nil fields.**
`e84eca6`, `ed23e89`. `chunk_fifo` is built by `queue_chunk` on the first
chunk actually read ahead; a GET with no body never queues one, and a fifo is
265 bytes of a 962-byte stream. Separately, ten `k = nil` documentation fields
were removed from the constructor: Lua sizes the hash part from the *syntactic*
key count, so they reserved ten empty slots and pushed the table from 16 to 32
(850 B → 466 B; end to end 14,450 → 14,070 bytes per request, byte-identical
across three runs). The field documentation moved into a comment block, which
is why it must not be "tidied up" back into the constructor. Guards:
`function stream_methods:queue_chunk`, `local queued = self.chunk_fifo`.

**`h1_connection.lua` — the header parse was O(value length).**
`e414be9`. The trailing-whitespace strip used `(.-)[ \t]*$`, whose non-greedy
match backtracks across the whole value; the benchmark could not see it
because benchmark headers are short. Now a `.*` capture and an explicit
byte-wise trim from the right. The same hunk replaces `string.match` with
`string.find` in three assertions that discard the capture. Guard:
`line:match("^([^%s:]+):[ \t]*(.*)$")`.

**`server.lua` — HTTP/1.1 runs its stream inline.** `d5a4025`, `20e539e`. The
per-request coroutine cost a measured 3,900 bytes a request. The inline call
sits **behind `conn.version < 2`** and `add_stream` remains exported as the
concurrent path, specifically so HTTP/2 could return later without anyone
having to rediscover which line mattered; `spec/http2_spec.lua` asserts the
concurrency that condition protects and goes red in 0.4 s if it is dropped.
Guard: `if conn.version and conn.version < 2 then`.

**`server.lua` — h2 is deferred out of the boot path.** `de1a6a3`.
`h2_connection` has two uses here, both per-connection and both already
guarded, so deferring one `require` also defers `h2_stream`, `hpack`,
`h2_error` and `bit`: **~19 ms of 47.6 and 5 modules of 69**, on every boot of
every application. It is forced eagerly in `new_server` wherever throwing
later would be wrong. `alpn_select` is a pure function over strings and never
touches the module, so TLS still offers h2 unchanged. Guard:
`local function h2_module()`.

**`server.lua` — cleartext h2 is opt-in (`h2c`).** `20e539e`. Upstream sniffs
every connection for the `PRI * HTTP/2.0` preface, which is a read on every
HTTP/1.1 connection before a byte is parsed. Browsers never speak cleartext
h2; what wants it is a proxy or a gRPC client. With it off the HTTP/1.1 path is
byte for byte what it was, and a client that sends the preface anyway has it
parsed as an unknown HTTP/1.1 method and cleanly rejected. Guard: `if self.h2c
then`.

**`server.lua` — `alpn_select` is exported, and no longer requires TLS 1.2 for
h2.** `20e539e`. Upstream refuses `h2` below TLS 1.2 inside the selector;
akkar's TLS context floor is already above that, and the check made the
function depend on a live SSL object it does not otherwise need. Guard:
`alpn_select = alpn_select;`.

**`h2_connection.lua` — the socket is drained before the read side is shut
down.** `3dc168f`. Closing a socket that still holds unread inbound data makes
the kernel send RST instead of FIN, and an RST discards what the peer already
put on the wire. h2spec 3.8 sends GOAWAY then PING and saw "connection reset
by peer" two runs in five. Bounded at sixty-four reads of up to 4 KB with **no
timeout**, so it takes what has already arrived and never waits — a peer that
keeps sending cannot hold the shutdown open. Guard: `self.socket:xread(-4096,
0)`.

### Removals and identity

**`request.lua` — SOCKS is not carried.** `0b3750e`. `http/socks.lua` was the
other module pulling in the `compat53` rock, which is the shim that blocks
Lua 5.5, and an outbound API client does not need it. The `require` is gone and
the branch raises. The HTTP proxy branch is untouched. Guard: `this build does
not support SOCKS proxies`. **If SOCKS is ever wanted back, `socks.lua` must be
re-vendored from the same tag and `compat53` reconsidered — it is not a
deletion to undo by hand.**

**`client.lua` — upstream's ALPN body, restored.** `20e539e`. While the h2 half
was absent this `if` had no body, which left `version` nil for a `version < 2`
comparison to raise on. It never fired, because `checktls` answers nil at that
point and every TLS connection took the `else`. The code here is now upstream's
again; the divergence is the comment recording that a dead branch which would
have crashed if it ever woke up is worse than either outcome.

**`version.lua` — this tree does not claim to be stock 0.4.** It used to, while
carrying every patch above, which is how a re-vendor gets talked into itself.
`version` now carries an `+akkar` suffix and the file names the upstream commit
and this ledger. Note the one visible consequence: `request.lua` builds the
default `user-agent` from it, so outbound requests made through the vendored
request module announce `lua-http/0.4+akkar`. That is the honest string; the
old one was a claim about code that is not here.

## Load-bearing outside this directory

- `akkar-dev-1.rockspec` declares what this tree needs (`fifo`, `binaryheap`,
  `basexx`, `compat53`, `lpeg_patterns`, ...) rather than inheriting it from
  the `http` rock akkar no longer depends on. A re-vendor that pulls in a new
  upstream dependency has to add it there or the rock installs and then fails
  on first `require`.
- `docs/substrate/lua-http-wedge.md` is the full account of the two h1
  denial-of-service repairs -- reproduction, measurements off a running
  process, the two obvious fixes that do not work -- and
  `spec/substrate_repair_spec.lua` proves them by swapping this module for the
  upstream rock's and requiring that server to die.
- **`LICENSE.md` does not currently ship in the rock.** The rockspec's
  `build.modules` lists `.lua` files and `copy_directories` covers
  `docs`, `examples` and `types`, so the MIT notice sitting beside this file
  travels with the *repository* and not with the artefact akkar publishes.
  That is the same class of defect as the missing licence was before
  2026-08-18, one packaging step further out, and it is not fixed here.

## Re-vendoring

1. Fetch the upstream tag named above — not `master`, which has no release.
2. Apply the prefix substitution, and only that.
3. Diff every file against this tree and re-apply the patches above; the
   reasoning for each lives in a comment at the line it affects, and a refresh
   that drops the comments drops the reasons.
4. Update this ledger in the same commit. `spec/vendor_provenance_spec.lua`
   will tell you if you did not.
