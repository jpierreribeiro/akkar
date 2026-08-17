#!/usr/bin/env bash
#
# Installs the four neighbours on the study box.
#
# Versioned rather than typed into a terminal, because "what was installed"
# is part of the measurement. `bench/runtime/METHOD.md` lists four setup
# prerequisites that can invalidate a whole run, and three of them are
# decided here: which substrate Lapis ends up on, whether each candidate is
# single-process by default, and which Lua each one carries.
#
# Nothing here touches the existing akkar, driver-e2e or study trees. Every
# candidate installs under ~/rt/ so a bad install is `rm -rf ~/rt/<name>`.
#
# Idempotent: every step checks before doing. Re-running is how you repair a
# partial install, so re-running must be safe.
set -uo pipefail

RT="$HOME/rt"
mkdir -p "$RT"
LOG="$RT/provision.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== provision $(date -Is) ==="

step() { printf '\n--- %s ---\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- base

step "base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  build-essential git curl ca-certificates cmake \
  libssl-dev libreadline-dev zlib1g-dev libpq-dev pkg-config \
  lua5.4 liblua5.4-dev luarocks unzip >/dev/null

# --------------------------------------------------------------- postgres

# `sudo docker` throughout: this box's ubuntu user is not in the docker group,
# and `docker ps` fails there by printing a permission error to stderr and
# exiting 0-ish enough to look like "no containers". That misread cost one
# provisioning run.
step "postgres (docker, the fixture the other benches already use)"
if ! sudo docker ps --format '{{.Names}}' | grep -q '^akkar-pg$'; then
  sudo docker rm -f akkar-pg >/dev/null 2>&1
  sudo docker run -d --name akkar-pg \
    -e POSTGRES_PASSWORD=akkar -e POSTGRES_DB=akkar \
    -p 55432:5432 postgres:16-alpine >/dev/null
  echo "waiting for postgres"
  for _ in $(seq 1 60); do
    sudo docker exec akkar-pg pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
fi
# The same 10,000 rows every other bench in this repository uses, so
# `/users/:id` means the same thing here as it does there.
sudo docker exec -i akkar-pg psql -q -U postgres -d akkar <<'SQL' >/dev/null
create table if not exists users (
  id serial primary key, name text not null, email text, password_hash text);
insert into users (name, email)
  select 'user' || i, 'u' || i || '@example.com' from generate_series(1, 10000) i
  on conflict do nothing;
SQL
echo "postgres rows: $(sudo docker exec akkar-pg psql -tAqU postgres -d akkar -c 'select count(*) from users')"

# --------------------------------------------------------------- luvit

# FIRST, because it is the candidate that would break akkar's claim if the
# claim is breakable, and because it prices `akkar-substrate-luv`.
step "luvit (libuv)"
# raw.githubusercontent.com, NOT github.com/.../raw/... -- the latter answers
# 404 to `curl -f` through its redirect, which is how the first run of this
# script reported LUVIT FAILED for a file that is present on master.
if [ ! -x "$RT/luvit/luvit" ]; then
  mkdir -p "$RT/luvit"
  cd "$RT/luvit"
  curl -fsSL https://raw.githubusercontent.com/luvit/lit/master/get-lit.sh | sh
  # `lit` builds itself and then installs luvit next to it.
  [ -x ./lit ] && ./lit make lit://luvit/luvit
fi
"$RT/luvit/luvit" -v 2>&1 | head -3 || echo "LUVIT FAILED"

# --------------------------------------------------------------- openresty

step "openresty (nginx + luajit)"
if ! have openresty; then
  curl -fsSL https://openresty.org/package/pubkey.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/openresty.gpg
  echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] \
http://openresty.org/package/ubuntu $(lsb_release -sc) main" \
    | sudo tee /etc/apt/sources.list.d/openresty.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq openresty >/dev/null
fi
openresty -v 2>&1 | head -1 || echo "OPENRESTY FAILED"

# --------------------------------------------------------------- lapis

# THE PREREQUISITE THAT CAN INVALIDATE THE COMPARISON.
#
# Lapis is a candidate because it runs on lua-http/cqueues -- the same
# substrate as akkar -- which is what makes the delta between them mean
# "akkar" rather than "a different stack". Lapis can also run under
# OpenResty. If the cqueues backend is not actually available, Lapis stops
# answering its question and becomes a second OpenResty data point, and that
# is a finding to record rather than a detail to paper over.
step "lapis"
sudo luarocks install --lua-version 5.4 lapis 2>&1 | tail -3
# THE ANSWER, from the first run: `lapis.cqueues` is NOT absent. It is
# present and it loads -- it just needs `cqueues` and `lua-http`, which on
# this box live in ~/.luarocks (where akkar's own runs read them from) and
# not in the system tree. The first version of this check wrapped the require
# in a bare pcall and printed ABSENT, hiding the reason: the error said
# `module 'http.headers' not found`.
#
# So the error is printed now. A probe that cannot say WHY is how you conclude
# a backend does not exist when it does, and the whole comparison rests on
# Lapis running the same substrate akkar does.
echo "-- which backends does this lapis have? --"
for mod in lapis.cqueues lapis.nginx lapis.bin.annotate; do
  printf '%-24s ' "$mod"
  eval "$(luarocks --local path)" 2>/dev/null
  lua5.4 -e "local ok, err = pcall(require, '$mod')
             print(ok and 'present' or ('ABSENT: ' .. tostring(err):match('[^\n]*')))" \
    2>&1 | head -1
done
find /usr/local/share/lua/5.4/lapis -maxdepth 1 -name '*.lua' 2>/dev/null \
  | sed 's|.*/||' | tr '\n' ' '; echo

# --------------------------------------------------------------- tarantool

# Via Docker, and the reason is a measurement decision rather than
# convenience. The apt route resolves to Tarantool 2.6.0 on this box -- the
# release/3 repository has no Release file for noble -- and 2.6.0 shipped in
# 2020. Benchmarking today's akkar against a six-year-old Tarantool would
# produce a number that flatters us and slanders it.
#
# `--network host` so the container is not measured through Docker's
# userland proxy, which would put a hop in front of one candidate and not the
# others. That the process is containerised at all is a caveat for RESULTS.md;
# an extra network hop would have been a defect.
step "tarantool (docker, --network host)"
if ! sudo docker ps --format '{{.Names}}' | grep -q '^rt-tarantool$'; then
  sudo docker rm -f rt-tarantool >/dev/null 2>&1
  sudo docker pull -q tarantool/tarantool:3 >/dev/null
fi
sudo docker run --rm tarantool/tarantool:3 tarantool --version 2>&1 | head -2 \
  || echo "TARANTOOL FAILED"

# --------------------------------------------------------------- report

step "what this box now has"
printf '%-14s %s\n' \
  wrk       "$(wrk --version 2>&1 | head -1)" \
  go        "$(go version 2>/dev/null)" \
  lua       "$(lua5.4 -v 2>&1)" \
  luvit     "$("$RT/luvit/luvit" -v 2>/dev/null | head -1 || echo MISSING)" \
  openresty "$(openresty -v 2>&1 | head -1 || echo MISSING)" \
  tarantool "$(sudo docker run --rm tarantool/tarantool:3 tarantool --version 2>/dev/null | head -1 || echo MISSING)"
echo
echo "=== done $(date -Is) ==="
