#!/bin/bash
# verify.sh: the checks done by hand before, on the unpatched engine first and then on the patch.
source "$(dirname "$0")/common.sh"
patched=$(cat "$TOOLS/patched.sha")

# 11.3 and 11.4 print (null) for sub-type 20 until the patch completes their name array; 11.2 has no 20.
case $VERSION in
  develop) name20_before=ATTR_WITH_SYNONYM name20_after=ATTR_WITH_SYNONYM ;;
  11.4 | 11.3) name20_before='(null)' name20_after=ATTR_WITH_SYNONYM ;;
  11.2) name20_before='' name20_after='' ;;
esac

log_name() {  # log_name <sub-type> <tag>: the name the SQL log gives one request of that sub-type
  local mark=zz_log_$2_$1 line
  probe send "$1" "$mark" > /dev/null 2>&1
  line=$(grep -ah "schema_info.* $mark " "$CUBRID"/log/broker/sql_log/*.sql.log | tail -1)
  [ -n "$line" ] || { echo "<no log line>"; return; }
  sed -E "s/.*schema_info (\S*) $mark .*/\1/" <<< "$line"
}

grew_kb() { sed -nE "s/^sub-type $1:.*grew (-?[0-9]+) KB.*/\1/p"; }

tcs_ok() { grep -q 'failed=0$' <<< "$1" && echo true || echo false; }

log "== the unpatched engine"
server_setup && server_restart || { cat "$OUT/server-start.log"; record "server starts (unpatched)" started failed false; finish; }

out=$(probe 2>&1); echo "$out" > "$OUT/probe-unpatched.txt"
fails=$(grep -c '^FAIL' <<< "$out"); refused=$(grep -c 'server=-10015' <<< "$out")
record "RED: the unpatched engine refuses sub-type 21" "9 checks fail with -10015" "$fails fail, $refused with -10015" \
  "$([ "$fails" = 9 ] && [ "$refused" = 9 ] && echo true || echo false)"

probe dump > "$OUT/dump-unpatched.txt" 2>&1
name=$(log_name 20 before)
record "log name of sub-type 20, unpatched" "$name20_before" "$name" "$(is "$name" "$name20_before")"

out=$(schema_tcs 2>&1); echo "$out" > "$OUT/tcs-unpatched.txt"
record "schema TCs, new driver on the unpatched engine" "all pass" "$(tail -1 <<< "$out")" "$(tcs_ok "$out")"

log "== the patch"
engine_checkout "$patched" && log "patched source checked out: $(git -C "$SRC" rev-parse --short HEAD)"
"$CI_DIR/build-engine.sh" patched || { record "patched build" built failed false; finish; }
clean=$(git -C "$SRC" diff --quiet HEAD -- src/broker && echo clean || echo modified)
record "patched build is the branch commit" "$(git -C "$SRC" rev-parse --short "$patched"), src/broker clean" \
  "$(git -C "$SRC" rev-parse --short HEAD), src/broker $clean" \
  "$([ "$(git -C "$SRC" rev-parse HEAD)" = "$patched" ] && [ "$clean" = clean ] && echo true || echo false)"
server_setup && server_restart || { cat "$OUT/server-start.log"; record "server starts (patched)" started failed false; finish; }

out=$(probe 2>&1); echo "$out" > "$OUT/probe-patched.txt"
record "probe checks" "all 10 pass" "$(grep -c '^PASS' <<< "$out") pass, $(grep -c '^FAIL' <<< "$out") fail" \
  "$(grep -q '^ALL PASS' <<< "$out" && echo true || echo false)"
if [ "$VERSION" = 11.2 ]; then
  out=$(PROBE_JAVA_OPTS=-Dreject=20 probe 2>&1); echo "$out" > "$OUT/probe-reject-20.txt"
  record "sub-type 20 is still refused and the connection stays" "all pass" "$(grep -c '^FAIL' <<< "$out") fail" \
    "$(grep -q '^ALL PASS' <<< "$out" && echo true || echo false)"
fi

probe dump > "$OUT/dump-patched.txt" 2>&1
lines=$(diff "$OUT/dump-unpatched.txt" "$OUT/dump-patched.txt" | grep -c '^[<>]')
record "sub-types 1-20 answer as before" "identical" "$([ "$lines" = 0 ] && echo identical || echo "$lines lines differ")" "$(is "$lines" 0)"

name=$(log_name 20 after)
record "log name of sub-type 20" "$name20_after" "$name" "$(is "$name" "$name20_after")"
name=$(log_name 21 after)
record "log name of sub-type 21" SCHEMAS "$name" "$(is "$name" SCHEMAS)"
echo "sub-type 22 is logged as [$(log_name 22 after)]" > "$OUT/log-name-22.txt"

out=$( { probe loop 1 1000; probe loop 21 1000; } 2>&1); echo "$out" > "$OUT/leak.txt"
grew=$(grew_kb 21 <<< "$out")
record "no leak over 1,000 calls on one CAS" "< 10240 KB" "${grew:-?} KB (sub-type 1: $(grew_kb 1 <<< "$out") KB)" \
  "$([ -n "$grew" ] && [ "$grew" -lt 10240 ] && echo true || echo false)"

out=$(schema_tcs 2>&1); echo "$out" > "$OUT/tcs-patched.txt"
record "schema TCs" "all pass" "$(tail -1 <<< "$out")" "$(tcs_ok "$out")"

log "== mutants: each is the patch plus one change, and must be caught"
mutant() {
  git -C "$SRC" checkout -q -- src/broker &&
    python3 "$CI_DIR/mutate.py" "$SRC" "$1" > "$OUT/mutant-$1.txt" 2>&1 &&
    git -C "$SRC" diff >> "$OUT/mutant-$1.txt" &&
    rebuild_cas
}
run_mutant() {  # run_mutant <mutant> <what it breaks> <how it shows> <check>
  local actual rc
  if mutant "$1"; then
    actual=$("$4" "$1"); rc=$?
    record "mutant: $2" "$3" "$actual" "$([ $rc -eq 0 ] && echo true || echo false)"
  else
    record "mutant: $2" "$3" "the mutant did not apply or build: $(tail -1 "$OUT/mutant-$1.txt")" false
  fi
}
probe_fails() {
  local out n; out=$(probe 2>&1); echo "$out" >> "$OUT/mutant-$1.txt"
  n=$(grep -c '^FAIL' <<< "$out"); echo "$n checks fail"; [ "$n" -gt 0 ]
}
commit_check_fails() {
  local out; out=$(probe 2>&1); echo "$out" >> "$OUT/mutant-$1.txt"
  if grep -q '^FAIL  a commit ends the result' <<< "$out"; then echo "the commit check fails"; else echo "the commit check passes"; return 1; fi
}
cas_leaks() {
  local out g; out=$(probe loop 21 500 2>&1); echo "$out" >> "$OUT/mutant-$1.txt"
  g=$(grew_kb 21 <<< "$out"); echo "${g:-?} KB over 500 calls"; [ -n "$g" ] && [ "$g" -gt 30720 ]
}
tcs_fail() {  # tcs_fail <mutant> <test that must fail>...
  local out t missed=(); out=$(schema_tcs 2>&1); echo "$out" >> "$OUT/mutant-$1.txt"
  for t in "${@:2}"; do grep -q "^FAIL $t:" <<< "$out" || missed+=("$t"); done
  echo "$(grep -c '^FAIL' <<< "$out") TCs fail${missed[*]:+, but not ${missed[*]}}"; [ ${#missed[@]} -eq 0 ]
}
lower_case_tc_fails() { tcs_fail "$1" testLowerCasePatternFindsTheSameSchemas; }
pattern_tcs_fail() { tcs_fail "$1" testUnderscoreInThePatternMatchesAnyOneCharacter testPercentPatternListsEverySchema; }
granted_table_tc_fails() { tcs_fail "$1" testUserOutsideDbaFindsTheOwnerOfATableGrantedToIt; }

run_mutant cursor-list "cursor list without 21" "probe fails" probe_fails
run_mutant commit-list "commit list without 21" "the commit check fails" commit_check_fails
run_mutant close-list "close list without 21" "> 30720 KB over 500 calls" cas_leaks
run_mutant no-upper "pattern without UPPER" "the lower-case TC fails" lower_case_tc_fails
run_mutant like-to-equal "LIKE turned into =" "the pattern TCs fail" pattern_tcs_fail
[ "$VERSION" = develop ] && run_mutant db-user "db_user instead of schemata" "the granted-table TC fails" granted_table_tc_fails

git -C "$SRC" checkout -q -- src/broker && rebuild_cas
out=$(probe 2>&1)
clean=$(git -C "$SRC" diff --quiet HEAD -- src/broker && echo clean || echo modified)
record "back to the patch after the mutants" "src/broker clean, probe passes" \
  "src/broker $clean, probe $(grep -q '^ALL PASS' <<< "$out" && echo passes || echo fails)" \
  "$([ "$clean" = clean ] && grep -q '^ALL PASS' <<< "$out" && echo true || echo false)"

log "== 1,000 more schemas, so one result takes several FETCHes"
python3 - "$TOOLS" <<'EOF'
import sys
names = ["fp_%04d_%s" % (i, "x" * 22) for i in range(1, 1001)]
open(sys.argv[1] + "/fp_create.sql", "w").write("".join("create user %s;\n" % n for n in names))
open(sys.argv[1] + "/fp_drop.sql", "w").write("".join("drop user %s;\n" % n for n in names))
EOF
csql -u dba "$DB" -i "$TOOLS/fp_create.sql" > "$OUT/fp-create.log" 2>&1
python3 "$CI_DIR/fetch_count.py" mark "$TOOLS/fp.mark"
out=$(probe 2>&1); echo "$out" > "$OUT/probe-many.txt"
record "probe checks with 1,000 more schemas" "all 10 pass" "$(grep -c '^FAIL' <<< "$out") fail" \
  "$(grep -q '^ALL PASS' <<< "$out" && echo true || echo false)"
out=$(schema_tcs 2>&1); echo "$out" > "$OUT/tcs-many.txt"
record "schema TCs with 1,000 more schemas" "all pass" "$(tail -1 <<< "$out")" "$(tcs_ok "$out")"
read -r results multi shapes <<< "$(python3 "$CI_DIR/fetch_count.py" count "$TOOLS/fp.mark")"
record "sub-type 21 results that took 3+ FETCHes" ">= 1" "$multi of $results, cursor positions $shapes" \
  "$([ "${multi:-0}" -ge 1 ] && echo true || echo false)"
csql -u dba "$DB" -i "$TOOLS/fp_drop.sql" > "$OUT/fp-drop.log" 2>&1

grep -ah 'schema_info' "$CUBRID"/log/broker/sql_log/*.sql.log | tail -20000 > "$OUT/sql-log-schema-info.txt"
finish
