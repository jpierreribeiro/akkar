--[[
The identity of this tree, which used to be a lie.

Upstream ships this file to name its own release, and it said `0.4` here while
the directory around it carried thousands of patched lines -- an enforced
MAX_CONCURRENT_STREAMS, a bounded WebSocket message, a bounded h2 header
block, and a frame-header check without which three bytes end the accept loop.

That mattered because of what the string is FOR. Someone deciding whether it
is safe to refresh this directory from upstream reads it, sees the release they
were about to fetch, and refreshes -- reverting every one of those repairs into
a suite that stays green, because the tests exercise akkar and the repairs are
in a dependency. The provenance file that was supposed to stop that had itself
gone stale within a day.

So the version says what this is. `akkar/vendor/http/PROVENANCE.md` is the
ledger, checked against the tree by `spec/vendor_provenance_spec.lua`.

ONE VISIBLE CONSEQUENCE, and it is the honest one: `request.lua` builds the
default `user-agent` from these two fields, so an outbound request made through
the vendored request module now announces `lua-http/0.4+akkar` rather than
`lua-http/0.4`. The old string named code that is not here.
]]

return {
	name = "lua-http";
	version = "0.4+akkar";

	-- The tag this tree was taken from, and where the divergence is written
	-- down. Read by the provenance spec, so the two cannot drift.
	akkar_upstream_commit = "799adaddd16bf14ac985cfd3c8dab8eed9da9570";
	akkar_provenance = "akkar/vendor/http/PROVENANCE.md";
}
