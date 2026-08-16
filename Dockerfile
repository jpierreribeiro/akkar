# akkar — one application, one static binary, one empty image.
#
# `docs/RUNTIME.md` makes a claim: `akkar build` emits a single ~5 MB binary
# and deployment becomes "copy one file to a server". This file is where that
# claim meets a container registry, and every number in `docs/DEPLOY.md` was
# measured by building it.
#
# ============================================================== the result
#
# It is a `scratch` image. Not distroless, not alpine-slim: nothing at all
# except the binary and a CA bundle. That is possible because the link is
# FULLY STATIC against musl, which `docs/RUNTIME.md` listed twice under "what
# this does NOT prove":
#
#     "Not fully static. OpenSSL is still linked dynamically."
#     "One platform, one libc. Linux, glibc, x86-64. Nothing here says
#      anything about musl."
#
# Both are now answered, and the answer is yes on both counts. `file` reports
# "statically linked", `ldd` reports "not a valid dynamic program", and the
# binary serves requests, resolves DNS and queries Postgres from an image with
# no libc in it. The measurements are in `docs/DEPLOY.md`.
#
# ================================================= what musl actually cost
#
# Exactly one thing, and it is worth writing down because the fear was that
# musl would be a wall:
#
#   * cqueues includes <sys/queue.h>, a BSD header musl does not ship. Alpine
#     packages it in `libbsd-dev`, which installs it at /usr/include/sys/
#     where cqueues already looks. One package, no patch, no flag.
#
# Nothing else needed changing. luaossl, lua-cjson, lpeg and lua-http built
# unmodified. `-DHAVE_DLADDR=0` was already required for a static luaossl on
# glibc (see `akkar/build.lua`'s recipe) and `akkar archive` already passes
# it, so musl added no work there either.
#
# ============================================ what static linking did cost
#
# Also one thing, and it is a size trap rather than a failure. Measured on
# this exact build: 21,759,272 bytes as linked, 6,177,544 after `strip`.
# Seventy-two percent of the artefact is debug tables from the statically
# linked C -- OpenSSL above all. An unstripped static binary is not a 21 MB
# runtime, it is a 6 MB runtime carrying its dependencies' DWARF, and
# forgetting to strip is how the project's "5 MB binary" claim would have
# looked like a lie in a registry listing.
#
# ================================================================= glibc?
#
# Untried here, deliberately. glibc's static `getaddrinfo` needs the NSS
# shared objects at runtime, so a `-static` glibc binary in a `scratch` image
# has no working host resolution -- and Railway hands out database hostnames.
# musl has no such split, and the DNS test in `docs/DEPLOY.md` is what proves
# it rather than this comment. Nothing here says a glibc static build is
# impossible; it says it was not needed and was not attempted.

# ============================================================== the builder
FROM alpine:3.20 AS builder

# Pinned, and pinned to the SAME commit `.github/workflows/ci.yml` pins, so
# the binary that ships and the tree the 486 tests run against are the same
# cqueues. The published rock is from July 2020 and master has six years of
# fixes on top of it; that gap is the rockspec's one stated honest gap.
ARG CQUEUES_COMMIT=c36614982fe07917b2e1ce5a9e7a0e55b81be262
# Pinned by commit rather than tag: these were the exact trees this image was
# built and tested against. Moving one is a decision with a diff.
ARG LUAOSSL_COMMIT=eee669791db8b86a0909d84bdb98116525033ed1
ARG CJSON_COMMIT=5ce46a80b10ef9d380a45c9e6cff9ecffbe71ebb
ARG LUASOCKET_COMMIT=84c2bb905bda5f1fc58195171c75723b5fec6e87
ARG LPEG_VERSION=1.1.0

# The application `akkar build` compiles in. Override to ship your own:
#   docker build --build-arg APP=app.lua -t myapp .
ARG APP=examples/railway.lua

# `libbsd-dev` is the musl fix described above. `openssl-libs-static` is what
# makes `-static -lssl -lcrypto` resolve; without it the link fails looking
# for libssl.a, not for a symbol.
RUN apk add --no-cache \
      build-base m4 git perl curl \
      lua5.4 lua5.4-dev luarocks5.4 \
      openssl-dev openssl-libs-static \
      libbsd-dev

WORKDIR /build
ENV LUA_INC=/usr/include/lua5.4

# ------------------------------------------------------------ native halves
#
# Four C libraries become four static archives, and `akkar archive` knows the
# recipe for each. `akkar/build.lua` explains at length why this is recipes
# and not one algorithm -- cqueues' object basenames collide across
# directories, lua-cjson compiles fpconv OR dtoa but never both, luaossl needs
# -DHAVE_DLADDR=0. A generic "compile every .c" gets three of the four wrong.
RUN mkdir -p /build/ar /build/stage/lua /build/stage/cpath

RUN git clone https://github.com/wahern/cqueues.git /build/src/cqueues \
 && git -C /build/src/cqueues checkout --quiet "$CQUEUES_COMMIT"
RUN git clone https://github.com/wahern/luaossl.git /build/src/luaossl \
 && git -C /build/src/luaossl checkout --quiet "$LUAOSSL_COMMIT"
RUN git clone https://github.com/openresty/lua-cjson.git /build/src/lua-cjson \
 && git -C /build/src/lua-cjson checkout --quiet "$CJSON_COMMIT"
RUN git clone https://github.com/lunarmodules/luasocket.git /build/src/luasocket \
 && git -C /build/src/luasocket checkout --quiet "$LUASOCKET_COMMIT"
RUN curl -sSLo /tmp/lpeg.tar.gz \
      "http://www.inf.puc-rio.br/~roberto/lpeg/lpeg-${LPEG_VERSION}.tar.gz" \
 && tar xzf /tmp/lpeg.tar.gz -C /build/src

# akkar's own source, needed before `akkar archive` can run: the CLI is Lua
# and `akkar.build` is the module doing the work.
#
# IT GOES IN A DIRECTORY OF ITS OWN, and that is not tidiness. `akkar build`
# adds akkar's own root WITHOUT being told to, by asking `package.searchpath`
# where `akkar` is and taking the parent -- and then it collects every `.lua`
# under that parent, recursively. Put `akkar/` directly in /build and the
# parent is /build, so the staging tree, the LuaRocks tree and the whole
# application checkout get collected a second time under mangled names
# (`app.akkar.init`, `rocks.share.lua.5.4.http.server`). They link, they are
# never required, and they are dead weight in the binary.
#
# With akkar alone under /build/lua, the implicit root is exactly akkar.
COPY akkar /build/lua/akkar
COPY bin /build/bin
ENV LUA_PATH="/build/lua/?.lua;/build/lua/?/init.lua;;"

RUN lua5.4 bin/akkar archive cqueues \
      --source /build/src/cqueues  --lua-inc "$LUA_INC" -o /build/ar/cqueues.a \
 && lua5.4 bin/akkar archive luaossl \
      --source /build/src/luaossl  --lua-inc "$LUA_INC" -o /build/ar/luaossl.a \
 && lua5.4 bin/akkar archive lua-cjson \
      --source /build/src/lua-cjson --lua-inc "$LUA_INC" -o /build/ar/lua-cjson.a \
 && lua5.4 bin/akkar archive lpeg \
      --source "/build/src/lpeg-${LPEG_VERSION}" --lua-inc "$LUA_INC" -o /build/ar/lpeg.a

# `mime` is the one archive `akkar archive` has no recipe for, and it is here
# for a reason found by running the binary rather than by reading:
#
#     akkar: [string "pgmoon.util"]:32: module 'mime' not found
#
# The rockspec already predicted it -- "pgmoon requires the `mime` module
# (from luasocket) without declaring it in its own rockspec" -- but the shape
# of the failure is worth recording. pgmoon's CRYPTO backends are all
# pcall-guarded, so pgmoon happily selects luaossl and never touches
# luasocket; `pgmoon.util` then requires `mime` UNCONDITIONALLY for base64.
# The binary therefore links, boots, serves HTTP, and dies on the first
# database call. Two objects and one `ar` is the whole fix.
RUN cc -O2 -c -I"$LUA_INC" -o /build/mime.o    /build/src/luasocket/src/mime.c \
 && cc -O2 -c -I"$LUA_INC" -o /build/compat.o  /build/src/luasocket/src/compat.c \
 && ar cr /build/ar/mime.a /build/mime.o /build/compat.o \
 && ranlib /build/ar/mime.a

# -------------------------------------------------------------- Lua halves
#
# cqueues and luaossl ship Lua wrappers whose INSTALLED layout differs from
# their source layout: cqueues' `src/socket.lua` is the module `cqueues.socket`,
# and a flat directory would make `akkar build` name it `socket`. So each
# library's own `make install` does the placing, into a staging tree that is
# then one `--root`. Nothing here guesses where a module goes.
RUN make -C /build/src/cqueues install5.4 \
      lua54path=/build/stage/lua lua54cpath=/build/stage/cpath \
 && make -C /build/src/luaossl install5.4 \
      lua54path=/build/stage/lua lua54cpath=/build/stage/cpath

# The pure-Lua dependencies. `--deps-mode=none` because their C dependencies
# are the archives above and letting LuaRocks resolve them would build the
# 2020 cqueues rock as a shared object nobody would load. Versions are the
# ones this image was tested with.
RUN luarocks-5.4 install --tree=/build/rocks --deps-mode=none http 0.4-0 \
 && luarocks-5.4 install --tree=/build/rocks --deps-mode=none basexx 0.4.1-1 \
 && luarocks-5.4 install --tree=/build/rocks --deps-mode=none lpeg_patterns 0.5-0 \
 && luarocks-5.4 install --tree=/build/rocks --deps-mode=none fifo 0.2-0 \
 && luarocks-5.4 install --tree=/build/rocks --deps-mode=none binaryheap 0.4-1 \
 && luarocks-5.4 install --tree=/build/rocks --deps-mode=none pgmoon 1.18.0-1 \
 && luarocks-5.4 install --tree=/build/rocks --deps-mode=none luasocket 3.1.0-1

# ------------------------------------------------------------- the binary
#
# The application checkout, last, so that editing an application file
# re-runs only this layer and not the twelve minutes above it.
#
# Deliberately NOT a `--root`: the entry file is embedded whichever roots
# exist, so a single-file application needs nothing here. An application with
# its OWN modules adds one root for the directory holding them --
# `--root /build/app/src` -- and not for the checkout, which would sweep up
# every stray `.lua` in the repository.
COPY . /build/app

# `-static` is the whole point, and `-ldl` stays in the list even though musl
# has no separate libdl: musl provides the symbols in libc and an empty
# libdl.a for exactly this, so leaving it keeps one flag list working on both
# libcs rather than two that differ by a detail.
#
# `strip` is not cosmetic -- see the header. 21,759,272 bytes to 6,177,544.
RUN cd /build/app \
 && lua5.4 /build/bin/akkar build "$APP" -o /build/akkar-app \
      --root /build/stage/lua \
      --root /build/rocks/share/lua/5.4 \
      --archive /build/ar/cqueues.a \
      --archive /build/ar/luaossl.a \
      --archive /build/ar/lua-cjson.a \
      --archive /build/ar/lpeg.a \
      --archive /build/ar/mime.a \
      --lua-lib /usr/lib/lua5.4/liblua.a \
      --lua-inc "$LUA_INC" \
      --libs "-static -lm -ldl -lpthread -lssl -lcrypto" \
 && strip /build/akkar-app

# PROVE IT IN THE BUILDER, not in the final image, because a `scratch` image
# has no shell to test with. A build that produces a binary which cannot start
# should fail here rather than in the platform's crash loop.
RUN /build/akkar-app --akkar-version \
 && ! ldd /build/akkar-app 2>/dev/null \
 && echo "static, and it starts"

# ================================================ the alternative artefact
#
#   docker build --target slim -t myapp:slim .
#
# NOT the default, and it exists for one measured reason rather than as a
# hedge. `akkar/migrate.lua` lists its directory with `find`, through
# `io.popen`, and says why:
#
#     "Lua has no directory listing and LuaFileSystem is a C dependency this
#      project has spent real effort not needing."
#
# `io.popen` runs `/bin/sh`. A `scratch` image has none, so MIGRATIONS CANNOT
# RUN FROM THE SCRATCH IMAGE. Verified, not deduced -- running the scratch
# image against a live Postgres with the directory mounted gives:
#
#     akkar.migrate: could not list /migrations:
#     find "/migrations" -maxdepth 1 -type f -name '*.sql': No such file or
#     directory
#
# and the "No such file or directory" is `/bin/sh`, not the directory, which
# was mounted and readable. The same run under this stage applies both files.
#
# So: serve from `scratch`, migrate from `slim`. Both stages contain the same
# binary, which is what makes that split safe -- there is no second build and
# no chance of the migrating binary being a different one from the serving
# binary. `docs/DEPLOY.md` has the Railway wiring for it.
#
# This stage is also the one to reach for when something needs debugging
# inside a container, since it has a shell and `scratch` does not.
FROM alpine:3.20 AS slim

# busybox already supplies `find` and `sh`; ca-certificates is the only
# addition, for the same outbound-TLS reason as below.
RUN apk add --no-cache ca-certificates
COPY --from=builder /build/akkar-app /akkar-app
USER 65532:65532
EXPOSE 8080
ENV PORT=8080 HOST=0.0.0.0
ENTRYPOINT ["/akkar-app"]

# ============================================================ the artefact
#
# `scratch`. Two files, and both earn their place:
#
#   ca-certificates.crt   outbound TLS -- to Stripe, to an S3, to any HTTPS
#                         API -- verifies against a trust store, and an empty
#                         image has none. Without it every outbound HTTPS call
#                         fails certificate verification while inbound HTTP
#                         works perfectly, which is a confusing afternoon.
#   akkar-app             everything else.
#
# NOT copied, and each absence is deliberate:
#   /etc/resolv.conf   the container runtime writes it at start; a baked one
#                      would override the platform's DNS.
#   /etc/passwd        USER is numeric below, which needs no passwd entry.
#                      A name would need one, and would buy nothing.
#   a shell            there is nothing to debug with inside this image. That
#                      is the trade: `docs/DEPLOY.md` names the slim fallback
#                      for anyone who would rather have `sh`.
FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /build/akkar-app /akkar-app

# Not root. `scratch` has no /etc/passwd, so this is a bare UID -- which the
# kernel is perfectly happy with and which means a container escape starts
# from nobody rather than from root. 65532 is the conventional "nonroot" UID.
USER 65532:65532

# Documentation only, and honest about it: Docker's EXPOSE publishes nothing
# and Railway ignores it. The port the app actually binds is whatever `PORT`
# says at runtime, read by the application -- see `examples/railway.lua`.
# 8080 is both akkar's default and the value Railway injects.
EXPOSE 8080
ENV PORT=8080 HOST=0.0.0.0

ENTRYPOINT ["/akkar-app"]
