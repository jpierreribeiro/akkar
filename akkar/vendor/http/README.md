# lua-http, vendored — provenance and modifications

Everything in this directory is **lua-http 0.4**, by Daurnimator, under the MIT
licence in `LICENSE.md` beside it. Upstream is
<https://github.com/daurnimator/lua-http>.

**The licence was missing from this repository until 2026-08-18**, which was a
defect and not a subtlety: MIT requires the copyright notice to travel with the
code, and akkar redistributes ~14,000 lines of it inside its own rock. It is
here now, unmodified, fetched from the `v0.4` tag.

## Why vendored at all

akkar changed the shape of the hot path in ways upstream has no reason to want
— see the per-file notes below — and carrying a patched copy is honest where a
monkey-patch at load time would not be. The published `http` rock is still a
declared dependency for other reasons; this directory is what akkar's own
server and client actually load.

## What was modified, and where the reasoning lives

Every change is commented in place, at the line it affects, with the
measurement that justified it. This table is an index, not the argument.

| file | lines changed | what changed |
|---|---:|---|
| `headers.lua` | 239 | storage shape: entry tables replaced, `never_index` dropped from every entry (−432 B/request) |
| `h1_stream.lua` | 156 | allocation on the request path |
| `server.lua` | 83 | HTTP/1.1 runs its stream inline instead of in a per-request coroutine (−3,900 B/request); h2 negotiation reinstated; `alpn_select` exported |
| `h1_connection.lua` | 65 | allocation on the request path |
| `request.lua` | 37 | |
| `client.lua` | 22 | |
| `cookie.lua`, `hsts.lua`, `stream_common.lua` | 2 each | require paths |
| everything else | 0 | byte-identical to upstream 0.4 |

`bit.lua`, `h2_connection.lua`, `h2_error.lua`, `h2_stream.lua` and `hpack.lua`
are byte-identical to upstream apart from their `require` prefixes.

## The h2 half left, and came back

Only the `h1_*` files were vendored originally, so akkar spoke HTTP/1.1 and
nothing else. HTTP/2 was reintroduced on 2026-08-18 by vendoring the same
release's h2 files — this is reintegration, not a reimplementation of HPACK.

Two things made that cheap, both of them deliberate rather than lucky:

1. `connection_common.lua`, `stream_common.lua`, `tls.lua` and `util.lua` were
   never modified, so the h2 half found the interfaces it expected.
2. When the per-request coroutine was removed from `handle_socket`, the inline
   call went **behind `conn.version < 2`** and `add_stream` stayed exported as
   the concurrent path — specifically so that h2 could return without anyone
   having to rediscover which line mattered. `spec/http2_spec.lua` asserts the
   concurrency that condition protects, and goes red in 0.4 s of wall clock if
   it is ever dropped.

## Updating

Diff against the upstream tag before touching anything here. The modified files
carry their reasoning in comments; a refresh that drops those comments drops
the reasons, and the measurements will be re-litigated by whoever notices the
code looks unusual.
