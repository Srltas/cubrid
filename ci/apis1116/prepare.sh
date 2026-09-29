#!/bin/bash
# prepare.sh: checks the pinned bases, builds the drivers and the probe, and checks out the unpatched engine.
source "$(dirname "$0")/common.sh"
set -e
: "${ENGINE_BRANCH:?}" "${ENGINE_BASE:?}" "${DRIVER_BASE:?}" "${TC_BASE:?}"
git config --global --add safe.directory '*'

# A base that is no longer an ancestor would make every comparison below meaningless.
for spec in "$SRC $ENGINE_BASE" "$WORK/jdbc $DRIVER_BASE" "$WORK/tc $TC_BASE"; do
  set -- $spec
  git -C "$1" merge-base --is-ancestor "$2" HEAD ||
    { echo "::error::$2 is not an ancestor of $(git -C "$1" rev-parse --short HEAD) in $(basename "$1")"; exit 1; }
done
git -C "$SRC" diff --quiet "$ENGINE_BASE" HEAD -- cubrid-jdbc cubrid-cci cubridmanager ||
  { echo "::error::the patch moves a submodule"; exit 1; }

patched=$(git -C "$SRC" rev-parse HEAD)
echo "$patched" > "$TOOLS/patched.sha"
python3 - "$OUT/meta.json" <<EOF
import json, sys
json.dump({"version": "$VERSION", "kind": "$KIND", "engine_branch": "$ENGINE_BRANCH", "engine": "$patched",
           "engine_base": "$ENGINE_BASE", "driver": "$(git -C "$WORK/jdbc" rev-parse HEAD)", "driver_base": "$DRIVER_BASE",
           "tc": "$(git -C "$WORK/tc" rev-parse HEAD)", "tc_base": "$TC_BASE"}, open(sys.argv[1], "w"), indent=1)
EOF

build_driver() {  # build_driver <source> <jar>
  (cd "$1" && ./build.sh) > "$OUT/driver-$(basename "$2" .jar).log" 2>&1
  local jar
  jar=$(ls "$1"/cubrid-jdbc-*.jar 2> /dev/null | grep -v -e '-sources' -e '-javadoc' | head -1 || true)
  [ -n "$jar" ] || { tail -30 "$OUT/driver-$(basename "$2" .jar).log"; exit 1; }
  cp "$jar" "$2"
  log "driver $(basename "$2"): $(basename "$jar")"
}
build_driver "$WORK/jdbc" "$TOOLS/new-driver.jar"

if [ "$KIND" = ctp ]; then
  git -C "$WORK/jdbc" worktree add -q --detach "$WORK/jdbc-old" "$DRIVER_BASE"
  build_driver "$WORK/jdbc-old" "$TOOLS/old-driver.jar"
fi

if [ "$KIND" = verify ]; then
  # The probe asks for 22 too, to check that an unknown sub-type is still refused.
  p=$TOOLS/probe-driver-src
  rm -rf "$p" && mkdir -p "$p/classes" && cp -R "$WORK/jdbc/src/jdbc" "$p/src"
  sed -i 's/SCH_MAX = 21;/SCH_MAX = 22;/' "$p/src/cubrid/jdbc/jci/USchType.java"
  grep -q 'SCH_MAX = 22;' "$p/src/cubrid/jdbc/jci/USchType.java" || { echo "::error::USchType.SCH_MAX is not 21"; exit 1; }
  version=$(sed -n 's/^version=//p' "$WORK/jdbc/output/build.properties")
  { grep -rl '@JDBC_DRIVER_VERSION_STRING@' "$p/src" || true; } | xargs -r sed -i "s/@JDBC_DRIVER_VERSION_STRING@/$version/g"
  find "$p/src" -name '*.java' > "$p/sources.txt"
  javac -nowarn -encoding UTF-8 -source 1.8 -target 1.8 -d "$p/classes" @"$p/sources.txt" > "$OUT/probe-driver-compile.log" 2>&1 ||
    { cat "$OUT/probe-driver-compile.log"; exit 1; }
  (cd "$p/classes" && jar cf "$TOOLS/probe-driver.jar" .)
  mkdir -p "$TOOLS/probe"
  javac -encoding UTF-8 -cp "$TOOLS/probe-driver.jar" -d "$TOOLS/probe" "$CI_DIR/java/SchemaListProbe.java"

  tc=$WORK/tc/interface/JDBC/test_jdbc
  ls "$tc"/lib/*.jar | grep -v 'cubrid_jdbc.jar' | paste -sd: - > "$TOOLS/tc-libs"
  mkdir -p "$TOOLS/tc-classes" "$TOOLS/tc-run"
  javac -nowarn -encoding UTF-8 -cp "$(cat "$TOOLS/tc-libs"):$TOOLS/new-driver.jar" -sourcepath "$tc/src" -d "$TOOLS/tc-classes" \
    "$tc/src/cubrid/jdbc/driver/TestSchemaMetaDataMatchesServer.java" "$tc/src/cubrid/jdbc/driver/TestCUBRIDDatabaseMetaData.java" \
    "$tc/src/cubrid/jdbc/driver/TestCUBRIDDatabaseMetaData2.java" "$tc/src/cubrid/jdbc/jci/TestUSchType.java" \
    "$CI_DIR/java/RunSchemaTcs.java" > "$OUT/tc-compile.log" 2>&1 || { cat "$OUT/tc-compile.log"; exit 1; }
  cat > "$TOOLS/tc-run/jdbc.properties" <<EOF
jdbc.driverClassName=cubrid.jdbc.driver.CUBRIDDriver
jdbc.url=jdbc:cubrid:localhost:$PORT:$DB:::
jdbc.username=dba
jdbc.password=
jdbc.ip=localhost
jdbc.port=$PORT
jdbc.dbname=$DB
EOF
fi

engine_checkout "$ENGINE_BASE"
log "engine at the unpatched $(git -C "$SRC" rev-parse --short HEAD), patch $(git -C "$SRC" rev-parse --short "$patched")"
