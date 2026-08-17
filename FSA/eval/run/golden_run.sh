#!/usr/bin/env bash
# ============================================================================
# fa_core golden runner — the RTL adjudication gate as an exit code.
#
# Turns "does this RTL match the held-out golden and close the latency bound?"
# into an exit code:
#   exit 0   == every tile within tolerance (+ latency bound if gated), and every
#               selected protocol scenario passed  → GOLDEN/PROTOCOL: PASS
#   exit !=0 == any tile/scenario failed / compile failed / timeout / no marker
# Fail-loud: PASS only on positive evidence of the PASS marker(s).
#
# It (1) generates held-out golden vectors (reference.py), (2) compiles the arm's
# RTL + the fixed golden package + the selected TB(s) (VCS, plain SV — no UVM),
# (3) runs, and (4) greps the marker. The held-out --seeds are the adjudicator's;
# they are NOT any implementation's dev seeds.
#
# Usage:
#   golden_run.sh --rtl <rtl_filelist> [--variant fa_core|fa_core_fsa]
#                 [--mode golden|protocol|all] [--top NAME] [--seeds 7,11,13,17,19]
#                 [--causal 0,1] [--max-latency N] [--work DIR]
#                 [--sim-args "+PLUSARG ..."]
#
#   --variant NAME  : DUT top defaults to the variant name (fa_core is the default);
#                     the latency hard gate ≤ 80 cyc is armed for both variants.
#   --top NAME      : override the DUT module name (a full build may suffix a
#                     repeat index, e.g. fa_core_fsa_0).
#   --max-latency N : override/force the latency bound (0 = report-only).
#   --mode          : golden (tolerance/latency), protocol (SC-003/4/5/6), or all.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN_DIR="$(cd "$HERE/.." && pwd)"
TB_DIR="$GOLDEN_DIR/tb"
PKG="$TB_DIR/fa_core_golden_pkg.sv"
GOLDEN_TB="$TB_DIR/fa_core_golden_tb.sv"
PROTOCOL_TB="$TB_DIR/fa_core_protocol_tb.sv"
PYTHON="${PYTHON:-python3}"

RTL=""
VARIANT="fa_core"
MODE="golden"
SEEDS="7,11,13,17,19"     # held-out adjudication seeds (NOT dev seeds)
CAUSAL="0,1"
WORK="./golden_work"
TOP=""                    # default derived from --variant
MAX_LATENCY=""            # default derived from --variant
SIM_ARGS=""               # extra simv plusargs (adjudicator-side; used by selftest)

die() { echo "golden_run: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	--rtl)          RTL="$2"; shift 2 ;;
	--variant)      VARIANT="$2"; shift 2 ;;
	--mode)         MODE="$2"; shift 2 ;;
	--seeds)        SEEDS="$2"; shift 2 ;;
	--causal)       CAUSAL="$2"; shift 2 ;;
	--work)         WORK="$2"; shift 2 ;;
	--top)          TOP="$2"; shift 2 ;;
	--max-latency)  MAX_LATENCY="$2"; shift 2 ;;
	--sim-args)     SIM_ARGS="$2"; shift 2 ;;
	*)              die "unknown arg $1" ;;
	esac
done

# variant-derived defaults --------------------------------------------------
case "$VARIANT" in
fa_core|fa_core_fsa)
	[[ -n "$TOP" ]] || TOP="$VARIANT"
	[[ -n "$MAX_LATENCY" ]] || MAX_LATENCY="80"     # spec hard gate ≤ 80 cyc (both)
	;;
*)
	die "--variant must be 'fa_core' or 'fa_core_fsa' (got '$VARIANT')" ;;
esac
case "$MODE" in golden|protocol|all) ;; *) die "--mode must be golden|protocol|all" ;; esac

[[ -n "$RTL" ]] || die "--rtl <rtl_filelist> required"
[[ -f "$RTL" ]] || die "rtl filelist not found: $RTL"
RTL="$(cd "$(dirname "$RTL")" && pwd)/$(basename "$RTL")"   # absolute (vcs -f)

LAT_ARG=""
[[ "$MAX_LATENCY" != "0" ]] && LAT_ARG="+MAX_LATENCY=$MAX_LATENCY"

echo "golden_run: variant=$VARIANT top=$TOP mode=$MODE seeds=$SEEDS causal=$CAUSAL max_latency=$MAX_LATENCY"

mkdir -p "$WORK"
cd "$WORK"

# 1) held-out golden vectors (TB token stream). ------------------------------
"$PYTHON" "$GOLDEN_DIR/reference.py" --seeds "$SEEDS" --causal "$CAUSAL" \
	--format tb --out vectors.tb

VCS_COMMON=(-full64 -sverilog -timescale=1ns/1ps +define+DUT_TOP="$TOP" -f "$RTL")

run_bench() { # <tb_file> <simv_name> <marker> <extra_plusargs...>
	local tb="$1" simv="$2" marker="$3"; shift 3
	echo "golden_run: compiling $(basename "$tb") -> $simv"
	vcs "${VCS_COMMON[@]}" "$PKG" "$tb" -o "$simv" 2>&1 | tee "compile.$simv.log"
	set +e
	# shellcheck disable=SC2086  (SIM_ARGS is a deliberate word-split list)
	"./$simv" +VECTORS=vectors.tb "$@" $SIM_ARGS -l "run.$simv.log"
	set -e
	if grep -q "$marker" "run.$simv.log"; then
		echo "golden_run: $marker  ($simv)"
		return 0
	fi
	echo "golden_run: no '$marker' marker — see $WORK/run.$simv.log" >&2
	return 1
}

rc=0
case "$MODE" in
golden)
	run_bench "$GOLDEN_TB" simv_golden "GOLDEN: PASS" ${LAT_ARG:+$LAT_ARG} || rc=1
	;;
protocol)
	run_bench "$PROTOCOL_TB" simv_protocol "PROTOCOL: PASS" || rc=1
	;;
all)
	run_bench "$GOLDEN_TB"   simv_golden   "GOLDEN: PASS"   ${LAT_ARG:+$LAT_ARG} || rc=1
	run_bench "$PROTOCOL_TB" simv_protocol "PROTOCOL: PASS"                      || rc=1
	;;
esac

exit "$rc"
