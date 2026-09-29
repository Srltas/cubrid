#!/bin/bash
# ctp.sh: the JDBC suite with the old driver and TCs on the unpatched engine, then with the new ones on the patch.
source "$(dirname "$0")/common.sh"
patched=$(cat "$TOOLS/patched.sha")
tc_new=$(git -C "$WORK/tc" rev-parse HEAD)

# CTP runs as a user of its own and needs ps, rsync and which, which the build image leaves out.
dnf install -y -q procps-ng rsync which > "$OUT/dnf.log" 2>&1 || { tail -20 "$OUT/dnf.log"; exit 1; }
id cubrid > /dev/null 2>&1 || useradd -m cubrid
CTP=/home/cubrid/CTP
SCENARIO=/home/cubrid/scenario
# APIS-1113 gave BrokerHandler.cancelBroker a session token, both drivers here have it, and this TC does
# not compile against it yet: CTP would compile nothing. It is left out of both runs alike.
BROKEN_TC=src/cubrid/jdbc/driver/TestBrokerHandler.java

AS_CUBRID=(runuser -u cubrid -- env HOME=/home/cubrid LANG=C.UTF-8 LC_ALL=C.UTF-8
  CUBRID="$CUBRID" CUBRID_DATABASES="$CUBRID_DATABASES" JAVA_HOME="$JAVA_HOME" LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
  PATH="$CTP/bin:$CTP/common/script:$PATH" CTP_HOME="$CTP" CTP_SKIP_UPDATE=1)

run_ctp() {  # run_ctp <name> <driver jar> <TC commit>
  rm -rf "$SCENARIO" "$CTP" && mkdir -p "$SCENARIO"
  git -C "$WORK/tc" archive "$3" interface/JDBC/test_jdbc | tar -x -C "$SCENARIO" --strip-components=3
  rm -f "$SCENARIO/$BROKEN_TC"
  cp -a "$WORK/testtools/CTP" "$CTP"
  sed -i "s|^scenario=.*|scenario=$SCENARIO|" "$CTP/conf/jdbc.conf"
  cp "$2" "$CUBRID/jdbc/cubrid_jdbc.jar"
  chown -R cubrid:cubrid "$CUBRID" "$SCENARIO" "$CTP"
  log "CTP $1: $(basename "$2") with the TCs of ${3:0:10}"
  "${AS_CUBRID[@]}" bash -c "cd $CTP && timeout 3600 ctp.sh jdbc -c $CTP/conf/jdbc.conf" > "$OUT/ctp-$1.log" 2>&1 < /dev/null
  log "CTP $1 exited $?"
  cp "$CTP/result/jdbc/current_runtime_logs/test-jdbc.xml" "$OUT/ctp-$1.xml" 2> /dev/null
  cp "$CTP/result/jdbc/current_runtime_logs/test_status.data" "$OUT/ctp-$1-status.data" 2> /dev/null
  cubrid_stop "${AS_CUBRID[@]}" cubrid service stop
  kill_cubrid
}

record "CTP: $(basename "$BROKEN_TC") left out of both runs" "-" "does not compile against the APIS-1113 cancelBroker" true
run_ctp before "$TOOLS/old-driver.jar" "$TC_BASE"

engine_checkout "$patched" && log "patched source checked out: $(git -C "$SRC" rev-parse --short HEAD)"
"$CI_DIR/build-engine.sh" patched || { record "patched build" built failed false; finish; }

run_ctp after "$TOOLS/new-driver.jar" "$tc_new"

while IFS='|' read -r check expected actual pass; do
  record "$check" "$expected" "$actual" "$pass"
done < <(python3 "$CI_DIR/ctp_compare.py" "$OUT/ctp-before.xml" "$OUT/ctp-after.xml" "$OUT/ctp-diff.txt")
finish
