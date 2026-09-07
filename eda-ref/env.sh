# shellcheck shell=sh
# ==============================================================================
# env.sh — generic EDA tool environment for the bare-tool wrapper.
# Sourced by the Makefile before invoking each tool. Fill in / export the
# design-specific values (TOP, NETLIST, ...) for YOUR design before running.
# This file contains only generic tool-level variables — no orchestration.
# ==============================================================================

# Top module name of the design under test (set to yours).
export TOP="${TOP:-accum}"

# Standard-cell library (.db for DC/PT, .v models for gate-level sim).
# Optional here: only synth/sta actually read it, and each fails on its own
# (dc_run.tcl / run_sta.tcl) if left unset — not every target needs it.
export LIB_DB="${LIB_DB:-}"
export LIB_V="${LIB_V:-}"

# Interconnect estimate for synthesis: a wire load model the library carries, or `none`.
# `none` is this benchmark's definition. A library declares neither a default model nor a
# selection group, so nothing picks one unless this does, and the choice is not free: measured
# across every bucket of a TSMC 90 library on five real designs, three of them close at exactly
# 0.00 ns setup with no model at all, so any bucket puts them negative, and the largest raises
# total cell area by a fifth to 140%. Both arms of one evaluation must use the same value, or
# their timing and power are not comparable.
export WIRE_LOAD_MODEL="${WIRE_LOAD_MODEL:-none}"

# UVM install (for vcs UVM DPI compile).
# Optional here: only sim-compile actually needs it (vcs fails on the bad
# $UVM_HOME/src/dpi/uvm_dpi.cc path if left unset) — not every target does.
export UVM_HOME="${UVM_HOME:-}"

# Post-synthesis products consumed by STA (produced by `make synth` into ./out/).
export NETLIST="${NETLIST:-out/${TOP}_syn.v}"
export SDC="${SDC:-out/${TOP}_syn.sdc}"

# VCS coverage flags (generic; tune as you like).
export VCS_COV="${VCS_COV:--cm line+cond+branch+tgl+fsm}"
