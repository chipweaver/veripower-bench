#!/usr/bin/env bash
# ============================================================================
# Harness self-test — does the adjudication environment actually work?
#
# A bench that has never failed anything is not evidence of a good DUT; it is
# evidence of nothing. This script measures the harness in BOTH directions
# against ref/fa_core_ref.sv:
#
#   * positive control — the conforming reference DUT must PASS every gate;
#   * negative controls — each injected defect (+MUT_*) must be caught by the
#     gate that owns it, and by that gate only;
#   * plumbing — compile error / no marker / timeout must never read as PASS.
#
# Run it after ANY change to the oracle, the benches, the runner, or the spec:
#
#   eval/selftest/run_selftest.sh              # exit 0 == harness proven
#
# Cases run the real golden_run.sh, so the runner's own path is exercised too.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN="$(cd "$HERE/.." && pwd)"
RUN="$GOLDEN/run/golden_run.sh"
WORK="${WORK:-./selftest_work}"

# VCS resolves paths inside a -f sourcelist against its own cwd, so the lists must
# hold absolute paths. Generate them here instead of committing machine-specific
# files into the repo.
mkdir -p "$WORK"
REF="$WORK/filelist_ref.f";       printf '%s\n' "$GOLDEN/ref/fa_core_ref.sv"        > "$REF"
STUB="$WORK/filelist_stub.f";     printf '%s\n' "$HERE/stub/fa_core_stub.sv"        > "$STUB"
BROKEN="$WORK/filelist_broken.f"; printf '%s\n' "$HERE/stub/fa_core_broken.sv"      > "$BROKEN"

# latency: the reference DUT reports 37 cycles; pad to sit either side of the
# 80-cycle hard gate (37 + 43 = 80 pass, 37 + 44 = 81 fail).
PAD_AT_BOUND=43
PAD_OVER_BOUND=44

pass=0; fail=0
printf '%-26s %-9s %-8s %-8s %s\n' CASE GATE EXPECT ACTUAL NOTE
printf '%s\n' "----------------------------------------------------------------------------"

# case <name> <mode> <expect: pass|fail> <needle|-> <rtl> [sim-args]
case_run() {
	local name="$1" mode="$2" expect="$3" needle="$4" rtl="$5" simargs="${6:-}"
	local log="$WORK/case.$name.log" rc actual note=""

	if [[ -n "$simargs" ]]; then
		"$RUN" --rtl "$rtl" --top "$(top_of "$rtl")" --mode "$mode" \
		       --work "$WORK" --sim-args "$simargs" >"$log" 2>&1
	else
		"$RUN" --rtl "$rtl" --top "$(top_of "$rtl")" --mode "$mode" \
		       --work "$WORK" >"$log" 2>&1
	fi
	rc=$?
	[[ $rc -eq 0 ]] && actual=pass || actual=fail

	local ok=1
	[[ "$actual" == "$expect" ]] || { ok=0; note="exit=$rc"; }
	if [[ "$needle" != "-" ]]; then
		if grep -qF -- "$needle" "$WORK"/run.simv_*.log 2>/dev/null; then
			note="${note:+$note }matched"
		else
			ok=0; note="${note:+$note }MISSING: $needle"
		fi
	fi

	for l in "$WORK"/run.simv_*.log; do
		[[ -f "$l" ]] && cp -f "$l" "$WORK/case.$name.$(basename "$l")" 2>/dev/null
	done

	if [[ $ok -eq 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
	printf '%-26s %-9s %-8s %-8s %s\n' "$name" "$mode" "$expect" "$actual" \
	       "$( [[ $ok -eq 1 ]] && echo "ok ${note}" || echo "MISMATCH ${note}" )"
}

top_of() { case "$1" in *stub*) echo fa_core_stub ;; *broken*) echo fa_core_broken ;; *) echo fa_core_ref ;; esac; }

rm -f "$WORK"/run.simv_*.log

# ---- positive controls ------------------------------------------------------
case_run positive-tolerance    golden   pass "GOLDEN: PASS"   "$REF"
case_run positive-protocol     protocol pass "PROTOCOL: PASS" "$REF"

if [[ $fail -ne 0 ]]; then
	printf '%s\n' "----------------------------------------------------------------------------"
	echo "SELFTEST: ABORT — the positive control failed, so the negative controls"
	echo "  would be meaningless. Check that VCS is available and the EDA environment"
	echo "  is running. Logs: $WORK"
	exit 2
fi

# ---- negative controls: functional gate ------------------------------------
case_run mut-err-one           golden   fail "FAIL tolerance" "$REF" "+MUT_ERR_ONE"
case_run mut-err-all-mae       golden   fail "FAIL tolerance" "$REF" "+MUT_ERR_ALL=1.5e-3"
case_run lat-at-bound-80       golden   pass "GOLDEN: PASS"   "$REF" "+MUT_LAT_PAD=$PAD_AT_BOUND"
case_run lat-over-bound-81     golden   fail "FAIL latency"   "$REF" "+MUT_LAT_PAD=$PAD_OVER_BOUND"

# ---- negative controls: protocol gate -------------------------------------
case_run mut-drop-valid        protocol fail "SC-004 FAIL o_out_valid dropped" "$REF" "+MUT_DROP_VALID"
case_run mut-change-data       protocol fail "SC-004 FAIL o_out_data changed"  "$REF" "+MUT_CHANGE_DATA"
case_run mut-early-ready       protocol fail "SC-003 FAIL qkv_in_ready high"   "$REF" "+MUT_EARLY_READY"
case_run mut-no-clear-busy     protocol fail "SC-005 FAIL busy did not clear"  "$REF" "+MUT_NO_CLEAR_BUSY"
case_run mut-done-2cyc         protocol fail "done FAIL pulsed 2 cycles"       "$REF" "+MUT_DONE2"

# bubble-specific defect: invisible to the golden gate (no bubbles there),
# caught by SC-006. Proves the two gates cover different ground.
case_run mut-drop-beat-sc006   protocol fail "SC-006 FAIL"    "$REF" "+MUT_DROP_BEAT"
case_run mut-drop-beat-golden  golden   pass "GOLDEN: PASS"   "$REF" "+MUT_DROP_BEAT"

# ---- plumbing: infrastructure failure must never read as PASS --------------
case_run plumbing-timeout      golden   fail "GOLDEN: FAIL timeout" "$STUB"
case_run plumbing-compile-err  golden   fail -                      "$BROKEN"

miss_rc=0
"$RUN" --rtl /nonexistent/filelist.f --mode golden --work "$WORK" >/dev/null 2>&1 || miss_rc=$?
if [[ $miss_rc -eq 2 ]]; then pass=$((pass+1)); note="exit=2"; else fail=$((fail+1)); note="exit=$miss_rc want 2"; fi
printf '%-26s %-9s %-8s %-8s %s\n' plumbing-bad-filelist runner fail \
       "$( [[ $miss_rc -ne 0 ]] && echo fail || echo pass )" \
       "$( [[ $miss_rc -eq 2 ]] && echo "ok $note" || echo "MISMATCH $note" )"

printf '%s\n' "----------------------------------------------------------------------------"
printf 'SELFTEST: %d/%d cases as expected\n' "$pass" "$((pass+fail))"
if [[ $fail -eq 0 ]]; then
	echo "SELFTEST: PASS — harness proven in both directions"
	exit 0
fi
echo "SELFTEST: FAIL — $fail case(s) did not behave as expected (logs in $WORK)"
exit 1
