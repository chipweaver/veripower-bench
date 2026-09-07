#!/usr/bin/env bash
# ot-harness/run.sh — run a test list against a built simv and print one verdict per test.
#
#   run.sh --ip i2c --simv $OT_WORK/i2c/simv                        # every test
#   run.sh --ip i2c --simv ... --list ../i2c/eval/scoreable.txt     # the graded set
#   run.sh --ip i2c --simv ... --seed 7
#
# Verdicts: PASS / FAIL / TIMEOUT / NOVERDICT. NOVERDICT means the simulation
# neither passed nor failed — a harness problem, never a design verdict.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/env.sh"

IP=""; SIMV=""; LIST=""; SEED=1
# Every test in both suites finishes well inside this; a hang is a harness fault.
TIMEOUT=1500
while [ $# -gt 0 ]; do
  case "$1" in
    --ip)      IP="$2"; shift 2 ;;
    --simv)    SIMV="$2"; shift 2 ;;
    --list)    LIST="$2"; shift 2 ;;
    --seed)    SEED="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$IP" ] && [ -n "$SIMV" ] || { echo "--ip and --simv are required" >&2; exit 2; }

W="$OT_WORK/$IP"; mkdir -p "$W/logs"
TSV="$W/tests.tsv"
"$OT_PY" "$here/testlist.py" "$OT_ROOT/hw/ip/$IP/dv/${IP}_sim_cfg.hjson" > "$TSV"
TEST=$(head -1 "$TSV" | tr -d '#')

keep=""
[ -n "$LIST" ] && keep=$(grep -vE '^\s*(#|$)' "$LIST" | tr '\n' '|' | sed 's/|$//')

tail -n +2 "$TSV" | while IFS=$'\t' read -r name seq opts; do
  [ -n "$keep" ] && ! echo "$name" | grep -qxE "$keep" && continue
  log="$W/logs/${name}.s${SEED}.log"
  ( cd "$W" && timeout "$TIMEOUT" "$SIMV" +UVM_TESTNAME="$TEST" +UVM_TEST_SEQ="$seq" \
      +UVM_VERBOSITY=UVM_LOW "+ntb_random_seed=$SEED" $opts > "$log" 2>&1 )
  rc=$?
  if   grep -q '^TEST PASSED CHECKS' "$log"; then v=PASS
  elif grep -q '^TEST FAILED CHECKS' "$log"; then v=FAIL
  elif [ $rc -eq 124 ];                     then v=TIMEOUT
  else v="NOVERDICT(rc=$rc)"; fi
  printf '%-44s %s\n' "$name" "$v"
done
