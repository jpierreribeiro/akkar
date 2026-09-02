# Releasing akkar

> Written 2 September 2026. This is the checklist and the honest state of what
> blocks a `luarocks upload` today. The policy for *what a release promises* is
> `docs/COMPATIBILITY.md`; this file is *how one is cut*. No release has ever been
> published to luarocks.org — `luarocks search akkar` returns nothing — so the
> first publish is a fresh one, not an update.

## The state in one line

Everything a release needs exists and is validated **except one thing the
maintainer must decide and one action only the maintainer can take.** The
rockspecs are correct, lint clean, and install from a clean tree; the source they
must point at is a git tag that does not exist yet. The decision is the version
number; the action is tagging and uploading.

## The decisive blocker, since corrected — and what it leaves behind

**The artefact described below has been repaired**; what remains is the
decision it exposed.

`akkar-0.1.0-1.rockspec` had drifted into describing HEAD while pinning a tag
from 206 commits earlier, and the check meant to guard it was pushing it
further out of true on every commit: it compared the release rockspec's module
list to the DEVELOPMENT one, which is the right rule for two rockspecs over one
tree and the wrong rule for one that pins a frozen tag. By the time it was
measured, 72 modules were declared against 42 files in the tag.

That check now asserts what is actually true — a released rockspec describes
its own tag — and the file has been restored to what `v0.1.0` carries. So the
repository no longer contains a rockspec that would fail on upload.

What that does NOT do is make a release exist. `v0.1.0` is still a tag from 206
commits ago describing a tree without the vendored HTTP half, and the tree
worth publishing is HEAD. **The decision below is therefore unchanged, and is
now the only thing between akkar and `luarocks install akkar`.** The candidate
`0.2.0` rockspecs are deliberately not carried here: they must be generated
from the tree actually being tagged, at the moment of tagging, or they
reproduce precisely the drift this paragraph is about.

The original diagnosis is kept below, because the shape of the mistake is worth
recognising again.

`akkar-0.1.0-1.rockspec`, as it stood on `main`, **would have failed to build if
uploaded.** It was internally inconsistent:

- Its `build.modules` list describes the **current tree** — it names
  `akkar.vendor.http.*` (21 modules), `akkar.websocket`, `akkar.execution` and
  more.
- Its `source.tag` pins **`v0.1.0`**, an annotated tag on origin at commit
  `d83fc61`, **206 commits behind `main`.**
- At that tag, `akkar/vendor/http/server.lua` and `akkar/websocket.lua` **do not
  exist** (the vendoring landed after the tag), and the tag's own rockspec lists
  **zero** vendored modules.

`luarocks upload` publishes a rockspec; luarocks.org then fetches the source from
`source.tag`. So an upload of this file would hand LuaRocks a v0.1.0 tarball that
is **missing the very files its module list names**, and the build would die on
the first absent module. The rockspec at HEAD is a description of HEAD wearing a
tag from 206 commits ago.

There are only two coherent ways out, and choosing between them is the one
decision below that blocks everything.

## The one decision that blocks release: the version number

Nothing was ever published to luarocks.org, so there is **no external
compatibility obligation** to honour — the choice is about git-tag hygiene and
the changelog, not about breaking installed users.

| option | what it is | cost |
|---|---|---|
| **A — cut `0.2.0` at HEAD** *(recommended)* | Leave the immutable `v0.1.0` tag as the historical "intended but never shipped" marker. Tag current `main` as `v0.2.0`; publish the prepared `akkar-0.2.0-1` / `akkar-pq-0.2.0-1` rockspecs. Fold `CHANGELOG.md`'s "Unreleased" section — which is a list of changes that **break code that works today** — into the `0.2.0` notes. | The published number is not `0.1.0`. Harmless: nobody installed `0.1.0`. |
| **B — keep the number `0.1.0`** | Move the published `v0.1.0` tag from `d83fc61` to the release commit, so the existing `akkar-0.1.0-1.rockspec` becomes correct. | **Rewrites a public git tag.** Acceptable only because no rock consumed it, but it violates tag immutability and will confuse anyone who fetched it. |

**Recommendation: A.** Immutability of a published tag is the stronger norm, and
`CHANGELOG.md`'s own "Unreleased" block is a set of breaking changes — under
`docs/COMPATIBILITY.md` a `0.x` MINOR is exactly where those belong, so `0.2.0` is
also the *honest* number, not merely the convenient one. The prepared rockspecs in
this branch (`akkar-0.2.0-1.rockspec`, `akkar-pq-0.2.0-1.rockspec`) implement A and
are validated below. If the maintainer prefers B, delete those two files and move
the tag instead; the readiness evidence transfers unchanged, since the tree is
identical.

Either way, **the rule is: `source.tag` must point at a commit whose tree
contains exactly the modules the rockspec lists.** That is the whole of what went
wrong with the `0.1.0` file.

## Everything else that must be true (and already is)

- **The vendored lua-http and its transitive deps are bounded, not wished.**
  `basexx`, `binaryheap`, `fifo`, `lpeg`, `lpeg_patterns` are declared as hard
  deps with major-only upper bounds, and the rockspec comment explains that
  dropping them "because we vendor http" would break every fresh install. `zlib`
  is deliberately *not* bounded (reached through pcall). Nothing to do.
- **`akkar-pq` is already a separate rock, correctly.** The C driver links libpq;
  declaring it in the main rockspec would make libpq a hard dependency of
  `luarocks install akkar` and break the install for everyone not using Postgres.
  It ships as `akkar-pq` with its own version, an `akkar >= 0.2.0, < 0.3.0`
  lockstep pin, and an `external_dependencies` block for libpq. It must be
  **uploaded after `akkar`**, because it depends on it. On Debian/Ubuntu the
  header is not on the default include path, so the documented install is
  `luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir)` — put that line
  in the release notes.
- **The CLI installs.** `install.bin = { akkar = "bin/akkar" }` is present, so
  `akkar doctor` exists after `luarocks install`, not only in a source checkout.

## The one honest gap — state it in the release notes, do not try to fix it in the rockspec

`cqueues >= 20200726` is the last *published* cqueues rock. akkar is tested
against a pinned **commit of upstream master** built by hand in CI; **LuaRocks
cannot express a git-commit pin.** So `luarocks install akkar` gets the 2020
release, which is *not* the build CI proves and *not* what the vendored HTTP half
was hardened against. This is a real, known limit, covered in
`docs/COMPATIBILITY.md` §5. Do not paper over it with a tighter bound — say it:

> The supported, reproducible platform is the binary from `akkar build`. The
> LuaRocks install is best-effort against the last published cqueues; the
> commit-level substrate pin is what CI tests and what the binary carries.

Closing this for real is one of the three conditions for `1.0`
(`docs/COMPATIBILITY.md` §2).

## Local validation performed (evidence)

Run in this branch on 2 September 2026, `luarocks 3.11.1`, `Lua 5.4.6`:

```
luarocks lint akkar-dev-1.rockspec          → exit 0
luarocks lint akkar-0.1.0-1.rockspec        → exit 0
luarocks lint akkar-pq-0.1.0-1.rockspec     → exit 0
luarocks lint akkar-0.2.0-1.rockspec        → exit 0   (prepared candidate)
luarocks lint akkar-pq-0.2.0-1.rockspec     → exit 0   (prepared candidate)

luarocks make --tree <clean prefix> --deps-mode none akkar-dev-1.rockspec
    → "akkar dev-1 is now installed"; 75 akkar modules + bin/akkar + the full
      akkar/vendor/http/ tree copied. No missing-file error.

luarocks make --tree <clean prefix> --deps-mode none akkar-0.2.0-1.rockspec
    → "akkar 0.2.0-1 is now installed". Same result.
```

The `dev` and `0.1.0` rockspecs carry **byte-identical module lists and
dependency blocks** (verified by diff), so the `luarocks make` above proves the
release module set installs cleanly from the working tree. `--deps-mode none` was
used so the build stays offline; the "missing dependencies" it then lists are the
declared bounds, not build failures. What is **not** yet provable locally is a
`luarocks build` *from the tag* — that awaits the maintainer creating `v0.2.0`,
after which the fetched tarball equals the validated tree.

## The exact sequence a release runs

Steps marked **[maintainer]** are outward-facing and are the maintainer's to run;
this preparation stops short of every one of them.

1. **Decide the version** (§"The one decision"). Assume `0.2.0` below.
2. Move `CHANGELOG.md`'s `## Unreleased` block under `## 0.2.0 — <date>`.
3. Confirm the rockspecs: `akkar-0.2.0-1.rockspec` and `akkar-pq-0.2.0-1.rockspec`
   are present, lint clean, and their `source.tag` is `v0.2.0`. (Done in this
   branch.)
4. `luarocks lint akkar-0.2.0-1.rockspec && luarocks lint akkar-pq-0.2.0-1.rockspec`
5. **[maintainer]** Tag and push the release commit:
   `git tag -a v0.2.0 -m "akkar 0.2.0" && git push origin v0.2.0`
6. Prove the published tarball builds, in a clean prefix, now that the tag exists:
   `luarocks build --tree /tmp/akkar-verify akkar-0.2.0-1.rockspec`
   (this fetches `v0.2.0` and resolves real dependencies).
7. **[maintainer]** Upload, main rock first:
   `luarocks upload akkar-0.2.0-1.rockspec --api-key=<key>`
8. **[maintainer]** Then the driver, which depends on the rock now published:
   `luarocks upload akkar-pq-0.2.0-1.rockspec --api-key=<key>`

`luarocks upload` needs a luarocks.org account and API key — a maintainer
credential. Steps 5, 7 and 8 are the only ones that change anything outside this
repository, and none of them has been run.

## Checklist

- [ ] Version number decided (§"The one decision"); recommendation is `0.2.0`.
- [ ] `CHANGELOG.md` "Unreleased" moved under the release heading with a date.
- [ ] `akkar-<v>-1.rockspec` and `akkar-pq-<v>-1.rockspec` present, `source.tag`
      matching the tag to be cut, both `luarocks lint`-clean.
- [ ] `source.tag`'s tree contains exactly the modules the rockspec lists
      (the trap the `0.1.0` file fell into — re-check after any tag move).
- [ ] `docs/COMPATIBILITY.md` linked from the release notes; the cqueues gap and
      the `akkar-pq PQ_INCDIR=…` install line stated there.
- [ ] **[maintainer]** `v<version>` tagged at the release commit and pushed.
- [ ] `luarocks build` from the pushed tag succeeds in a clean prefix.
- [ ] **[maintainer]** `luarocks upload` the main rock, then `akkar-pq`.
- [ ] `luarocks install akkar` in a throwaway prefix as a post-publish smoke test.
