#!/usr/bin/env bash
# ot-harness/build.sh — build one OpenTitan IP's UVM DV bench against a chosen DUT.
#
#   build.sh --ip i2c                      # reference RTL   -> $OT_WORK/i2c/simv.ref
#   build.sh --ip i2c    --rtl my.f        # your RTL         -> $OT_WORK/i2c/simv
#   build.sh --ip usbdev --stub            # do-nothing DUT   -> $OT_WORK/usbdev/simv.stub
#   build.sh --ip i2c    --renamed         # substitution filter -> $OT_WORK/i2c/simv.renamed
#
# --rtl and --stub supply module `<ip>` with the port list in
# `intent/brainstorm.md` §3, plus `<ip>_reg_pkg` and its register file: in a
# comportable flow those are generated from a register description the designer
# authors, so the description is part of the deliverable.
#
# --rtl takes a filelist naming YOUR SystemVerilog. It must provide the IP's top
# module with the reference port list, plus the packages the DV env reads from it
# (see the per-task README's "integration contract"). Everything else — tlul,
# prim, the DV libraries, the RAL — comes from here.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/env.sh"

IP=""; RTL=""; STUB=0; REN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ip)      IP="$2"; shift 2 ;;
    --rtl)     RTL="$2"; shift 2 ;;
    --stub)    STUB=1; shift ;;
    --renamed) REN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$IP" ] || { echo "--ip is required" >&2; exit 2; }
n=$STUB; n=$((n + REN)); [ -n "$RTL" ] && n=$((n + 1))
[ "$n" -le 1 ] || { echo "--rtl, --stub and --renamed are mutually exclusive" >&2; exit 2; }
W="$OT_WORK/$IP"; mkdir -p "$W"
# Each kind of DUT gets its own product, so none can overwrite another -- not
# even when a build fails partway and leaves the output path unusable.
if   [ "$STUB" = 1 ]; then OUT="$W/simv.stub"
elif [ "$REN"  = 1 ]; then OUT="$W/simv.renamed"
elif [ -n "$RTL" ];   then OUT="$W/simv"
else                       OUT="$W/simv.ref"
fi

# 1. Generated from the IP's register description: the RAL model the DV env
#    drives the bus through, and the CSR assertion module that <ip>_bind binds
#    onto the DUT.
for fmt in -s -f; do
  PYTHONPATH="$OT_ROOT/util" "$OT_PY" "$OT_ROOT/util/regtool.py" $fmt -t "$W" \
      "$OT_ROOT/hw/ip/$IP/data/$IP.hjson" >/dev/null
done

# 2. The DV fileset closure, and 3. the package closure.
"$OT_PY" "$here/flist.py" "lowrisc:dv:${IP}_sim" sim > "$W/dv.f"
OT_ROOT="$OT_ROOT" "$OT_PY" "$here/pkgclosure.py" "$IP" \
    "$OT_ROOT/hw/ip/prim/rtl" "$OT_ROOT/hw/ip/prim_generic/rtl" \
    "$OT_ROOT/hw/ip/tlul/rtl" > "$W/pkgs.f"

# 4. The DUT.
if [ "$STUB" = 1 ]; then
  "$OT_PY" "$here/mkstub.py" "$IP" > "$W/${IP}_stub.sv"
  DUT="$W/${IP}_stub.sv"                     # one generated source file
  DUT_KIND=file
elif [ "$REN" = 1 ]; then
  "$OT_PY" "$here/mkrenamed.py" "$OT_ROOT/hw/ip/$IP/rtl/$IP.sv" > "$W/renamed.sv"
  DUT="$W/renamed.sv"                        # the reference top, one name changed
  DUT_KIND=top                               # its own submodules stay reachable
elif [ -n "$RTL" ]; then
  DUT="$RTL"                                 # the submitter's own filelist
  DUT_KIND=flist
else
  DUT=""; DUT_KIND=none                      # the reference RTL, already in dv.f
fi

# 5. Assemble. Packages lead (VCS resolves modules through -y, never packages);
#    the RAL sits immediately before the env package that consumes it; when a DUT
#    is supplied, the IP's own non-package RTL is dropped in favour of it.
"$OT_PY" - "$W" "$IP" "$DUT" "$DUT_KIND" <<'PY' > "$W/build.f"
import glob, os, re, sys
W, IP, DUT, KIND = sys.argv[1:5]
OT = os.environ["OT_ROOT"]
pkgs = [l.strip() for l in open(f"{W}/pkgs.f") if l.strip()]
# A submission generates <ip>_reg_pkg and its register file from its own register
# description, so the reference's must not also be in the compilation unit.
# <ip>_pkg stays: it is hand-written, the DV env imports it, and it is not
# register-derived. Note the reg_pkg arrives twice -- via the package closure and
# via the IP's own CAPI2 fileset -- so both paths need it dropped.
submitted = KIND in ("file", "flist")
if submitted:
    pkgs = [p for p in pkgs if os.path.basename(p) != f"{IP}_reg_pkg.sv"]
own_rtl = {p for p in glob.glob(f"{OT}/hw/ip/{IP}/rtl/*.sv") if not p.endswith("_pkg.sv")}
# Some of the IP's own modules are instantiated by the TESTBENCH, not by the DUT
# -- usbdev's tb.sv builds a companion `usbdev_aon_wake` because that module is
# outside the design's scope. Those must survive even when the DUT is replaced.
tb_sv = f"{OT}/hw/ip/{IP}/dv/tb/tb.sv"
if not os.path.exists(tb_sv):
    tb_sv = f"{OT}/hw/ip/{IP}/dv/tb.sv"
tb_text = open(tb_sv).read() if os.path.exists(tb_sv) else ""
tb_needs = {p for p in own_rtl
            if os.path.basename(p) != f"{IP}.sv"          # the top IS the DUT
            and re.search(r"\b%s\s+\w+\s*\(" % re.escape(os.path.basename(p)[:-3]), tb_text)}
own_rtl -= tb_needs
inc, files = [], []
for l in open(f"{W}/dv.f"):
    s = l.strip()
    if not s:
        continue
    (inc if s.startswith("+incdir+") else files).append(s)
out = []
for f in files:
    if f in pkgs:
        continue                                  # already led
    if submitted and os.path.basename(f) == f"{IP}_reg_pkg.sv":
        continue
    if KIND == "top":
        if f == f"{OT}/hw/ip/{IP}/rtl/{IP}.sv":
            continue                              # only the top is substituted
    elif DUT and f in own_rtl:
        continue                                  # replaced by the supplied DUT
    if f.endswith(f"/{IP}_env_pkg.sv"):
        out.append(f"{W}/{IP}_ral_pkg.sv")
    out.append(f)
# A submitted filelist is nested with -f so its own +incdir+ lines survive.
dut_lines = {"file": [DUT], "top": [DUT], "flist": ["-f " + DUT], "none": []}[KIND]
lead = pkgs + dut_lines
# Library paths resolve modules the explicit list does not name. The prim/tlul
# ones are unavoidable: the DV's own dependency closure instantiates the
# technology-abstracted primitives (prim_buf, prim_flop, prim_ram_1p, ...).
# The IP's OWN rtl directory is a different matter -- with it on the path a
# submission could instantiate `i2c_core` and be handed the reference
# implementation. It goes on the path only for the reference build, which is the
# one that legitimately needs its own submodules.
libs = [f"-y {OT}/hw/ip/prim/rtl", f"-y {OT}/hw/ip/prim_generic/rtl",
        f"-y {OT}/hw/ip/tlul/rtl"]
if KIND in ("none", "top"):
    libs.append(f"-y {OT}/hw/ip/{IP}/rtl")
libs.append("+libext+.sv")
out.append(f"{W}/{IP}_csr_assert_fpv.sv")            # bound below
out.append(f"{W}/{IP}_bind_portlevel.sv")           # the submission-safe binds
incs = inc + [f"+incdir+{d}" for d in sorted({os.path.dirname(p) for p in pkgs})]
seen, final = set(), []
for x in incs + lead + out + libs:
    if x in seen:
        continue
    seen.add(x)
    final.append(x)
print("\n".join(final))
PY

# 6. The sim_cfg's sim_tops are the bind modules (protocol checkers, CSR
#    assertions, sec_cm probes). A `bind` takes effect only if its enclosing
#    module is elaborated, so each needs its own -top alongside tb.
#    Only the port-level subset can attach to a submission, and it is used for
#    the reference too so that both are graded under identical assertions.
#    See mkbind.py for what is dropped and why.
"$OT_PY" "$here/mkbind.py" "$IP" > "$W/${IP}_bind_portlevel.sv"
SIM_TOPS="-top ${IP}_bind_portlevel"

# 7. Compile. Every flag here is load-bearing; see README "Build flags".
defines=(
  +define+UVM +define+UVM_NO_DEPRECATED +define+UVM_REGEX_NO_DPI
  # TL-UL is 32-bit throughout OpenTitan: hw/dv/tools/dvsim/common_sim_cfg.hjson
  # sets tl_aw/tl_dw to 32 and no IP's sim_cfg overrides them.
  +define+UVM_REG_ADDR_WIDTH=32 +define+UVM_REG_DATA_WIDTH=32
  +define+UVM_REG_BYTENABLE_WIDTH=4
  +define+SIMULATION +define+INC_ASSERT +define+DUT_HIER=tb.dut
)
[ "$IP" = usbdev ] && defines+=( +define+OT_NO_TIMED_REG_CHK )

# VCS writes csrc/, ucli.key and friends into the working directory: keep that in
# $OT_WORK, never in the source tree.
( cd "$W" && vcs -full64 -sverilog -ntb_opts uvm-1.2 -assert svaext -timescale=1ns/1ps \
    -debug_access+f -CFLAGS --std=c99 \
    "${defines[@]}" -top tb $SIM_TOPS -f "$W/build.f" -o "$OUT" > "$W/compile.log" 2>&1 )
rc=$?
echo "[ot-harness] $IP $( [ -n "$DUT" ] && echo "dut=$DUT" || echo "dut=reference") -> $OUT (rc=$rc)"
[ $rc -eq 0 ] || { grep -A8 'Error-\[' "$W/compile.log" | head -40; exit $rc; }
