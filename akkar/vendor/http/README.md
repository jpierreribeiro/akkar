# lua-http, vendored

Everything in this directory is **lua-http**, by Daurnimator, under the MIT
licence in `LICENSE.md` beside it. Upstream is
<https://github.com/daurnimator/lua-http>. akkar redistributes ~14,000 lines
of it inside its own rock, and MIT requires the copyright notice to travel
with the code, which is what that file is doing here.

## It is not stock, and this file will not tell you how

**The ledger is [`PROVENANCE.md`](PROVENANCE.md).** Which release this came
from, the exact `require` prefix transformation, every file that diverges,
by how much, which akkar commit changed it and why it must not be lost.

This file used to carry that table itself, in prose, and it was **wrong within
twenty-four hours of being written** -- it certified the two files that
carry akkar's HTTP/2 and WebSocket denial-of-service repairs as untouched.
A re-vendor on the strength of it would have reverted all of them silently,
with the whole suite still green.

So the ledger moved somewhere a test can read it.
`spec/vendor_provenance_spec.lua` checks every patch is still in the file
`PROVENANCE.md` claims, and fails CI naming the commit if one is gone. Prose
that nothing executes is how this went wrong once already; there is
deliberately no second copy of it here.

## Why vendored at all

akkar changed the shape of the hot path in ways upstream has no reason to
want, and added bounds upstream does not have. Carrying a patched copy is
honest where a monkey-patch at load time would not be -- and the h1 repairs
below were exactly that until this directory existed. Upstream's last release
is v0.4 (2021) and its last commit is 2024-09-08, so there is no version to
wait for: two fixes it made after the release are backported here by hand.

`socks.lua` and `compat/` are not carried. See `PROVENANCE.md`.
