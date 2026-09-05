# Controlled Linux installation

`bash bin/bootstrap-runtime /absolute/new-prefix` builds an isolated Lua 5.4
and installs the runtime there, without replacing the system Lua or user rocks.
The prefix must not exist. Prerequisites: Linux, C compiler/make, git, curl,
LuaRocks, OpenSSL development headers, m4 and unzip.

Use `/absolute/new-prefix/bin/runtime-exec akkar doctor --no-probe`, or pass
`akkar run app.lua` through the same launcher. The launcher excludes global
Lua search paths, sets the controlled manifest and runs the prefix's VM.

The source identity is `runtime/substrate.env`; runtime rock source archives
are versioned and SHA-256 checked against `runtime/rocks.lock`. The Lua archive
checksum comes from [Lua's official archive](https://www.lua.org/ftp/).
Lua 5.4.6 deliberately preserves this consolidation's local baseline; it is
not represented as the latest patched release. Advancing the VM is a separate
manifest change with repeated compatibility and security review.

cqueues is built from the same commit as the platform CI. The ordinary
LuaRocks installer still uses published dependency versions, and must not be
confused with this distribution. Its warning that manually built cqueues is
not registered as a rock does not mean the module is absent; the bootstrap
asserts the identity actually loaded before it succeeds.

OpenSSL is dynamically linked from the build host, not vendored or pinned by
this recipe. Its runtime identity is recorded in the installed manifest and
doctor rejects subsequent drift. Compiler, libc, OpenSSL headers and LuaRocks
are host tools: this is controlled source/dependency installation, not a
hermetic toolchain, bit-identical build or portable static executable.

The optional `akkar-pq` native driver is not installed; pgmoon remains the
default. Existing `akkar build` support and its archive requirements are
unchanged. No historical tagged rockspec is rewritten for the new modules.

CI has a dedicated controlled-install job, while existing jobs exercise the
broader platform matrix. Release preparation includes both manifests; it does
not publish them by itself. For a failed build, inspect the new prefix and use
another empty prefix for a fresh attempt; the script never deletes user data.
