# shellcheck shell=bash
# Shared by the APIS-1116 job scripts. Sourced, not run.
set -uo pipefail

: "${VERSION:?}" "${KIND:?}" "${GITHUB_WORKSPACE:?}"
WORK=$GITHUB_WORKSPACE
CI_DIR=$WORK/ci-src/ci/apis1116
SRC=$WORK/cubrid
BUILD=$SRC/build_x86_64_debug
OUT=$WORK/out
TOOLS=$WORK/tools
DB=cubdb
PORT=33000

export CUBRID=/home/CUBRID
export CUBRID_DATABASES=$CUBRID/databases
export JAVA_HOME=/opt/jdk8
export PATH=$CUBRID/bin:$JAVA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib
export CCACHE_DIR=$WORK/.ccache CCACHE_MAXSIZE=1500M CCACHE_COMPRESS=1
mkdir -p "$OUT" "$TOOLS"

log() { echo "[$(date +%T)] $*"; }

# record <check> <expected> <actual> <true|false>
record() {
  python3 -c 'import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"check": sys.argv[2], "expected": sys.argv[3], "actual": sys.argv[4], "pass": sys.argv[5] == "true"}) + "\n")' \
    "$OUT/results.jsonl" "$@"
  if [ "$4" = true ]; then
    log "PASS  $1: $3"
  else
    log "FAIL  $1: expected [$2], got [$3]"
    echo "::error title=$KIND $VERSION::$1: expected [$2], got [$3]"
  fi
}

is() { [ "$1" = "$2" ] && echo true || echo false; }

finish() {
  python3 "$CI_DIR/summarize.py" "$OUT" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  [ -s "$OUT/results.jsonl" ] || { echo "::error::no check was recorded"; exit 1; }
  local failed
  failed=$(grep -c '"pass": false' "$OUT/results.jsonl")
  if [ "$failed" -ne 0 ]; then
    echo "::error::$failed checks failed"
    exit 1
  fi
}

# The database once, and room for the leak checks: by default a CAS restarts long before 1,000 calls.
server_setup() {
  if ! grep -qs "^${DB}[[:space:]]" "$CUBRID_DATABASES/databases.txt"; then
    rm -rf "${CUBRID_DATABASES:?}/$DB" && mkdir -p "$CUBRID_DATABASES/$DB"
    (cd "$CUBRID_DATABASES/$DB" && cubrid createdb --db-volume-size=64M --log-volume-size=64M "$DB" en_US.utf8) \
      > "$OUT/createdb.log" 2>&1 || return 1
  fi
  local conf=$CUBRID/conf/cubrid_broker.conf
  grep -q '^APPL_SERVER_MAX_SIZE *=900M' "$conf" || sed -i '/^\[%BROKER1\]/a APPL_SERVER_MAX_SIZE    =900M' "$conf"
}

# pid, state and command line of every CUBRID process, for a stop or start that hangs
cubrid_processes() {
  local p cmd
  for p in /proc/[0-9]*; do
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2> /dev/null) || continue
    case $cmd in *cub_* | *cubrid* | *java*) echo "${p#/proc/} $(awk '{print $3}' "$p/stat" 2> /dev/null) $cmd" ;; esac
  done
}

# A stop that hangs is cut off after 180 s and reported; any other failure (nothing to stop) is fine.
cubrid_stop() {  # cubrid_stop <command...>
  timeout 180 "$@" > /dev/null 2>&1 < /dev/null
  [ $? -ne 124 ] && return 0
  log "'${*}' did not finish in 180 s"
  cubrid_processes > "$OUT/processes-$(date +%H%M%S).txt"
  return 1
}

kill_cubrid() {
  local p
  for p in /proc/[0-9]*; do
    case $(cat "$p/comm" 2> /dev/null) in cub_*) kill -9 "${p#/proc/}" 2> /dev/null ;; esac
  done
  return 0
}

# Only after a stop hung: killing a healthy cub_master leaves it unable to start again.
server_stop() {
  local hung=false
  cubrid_stop cubrid broker stop || hung=true
  cubrid_stop cubrid server stop "$DB" || hung=true
  [ "$hung" = false ] || kill_cubrid
}

# Output goes to a file: cub_pl keeps a pipe open and the start never returns.
server_restart() {
  server_stop
  { timeout 300 cubrid server start "$DB" && timeout 120 cubrid broker start; } > "$OUT/server-start.log" 2>&1 < /dev/null ||
    { cubrid_processes >> "$OUT/server-start.log"; return 1; }
}

# The manager server is left out, so its submodule is too.
engine_checkout() {
  git -C "$SRC" checkout -q --detach "$1" && git -C "$SRC" submodule update --init -q cubrid-cci cubrid-jdbc
}

probe() {
  timeout 900 java ${PROBE_JAVA_OPTS:-} -cp "$TOOLS/probe-driver.jar:$TOOLS/probe" SchemaListProbe "$PORT" "$DB" "$@"
}

schema_tcs() {
  (cd "$TOOLS/tc-run" && timeout 1200 java -cp "$TOOLS/tc-classes:$(cat "$TOOLS/tc-libs"):$TOOLS/new-driver.jar" RunSchemaTcs)
}

# The running CAS keeps its binary open, so the broker stops before the copy.
rebuild_cas() {
  cmake --build "$BUILD" --target cub_cas --parallel "$(nproc)" > "$OUT/cub_cas-build.log" 2>&1 ||
    { tail -40 "$OUT/cub_cas-build.log"; return 1; }
  cubrid_stop cubrid broker stop
  cp "$BUILD/bin/cub_cas" "$CUBRID/bin/cub_cas" && timeout 120 cubrid broker start > /dev/null 2>&1 < /dev/null
}
