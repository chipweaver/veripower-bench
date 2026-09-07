# shellcheck shell=sh
# ot-harness/env.sh — the only deployment-specific values. Source before build/run.

# Pinned OpenTitan checkout, with ot-harness/patches/ot-harness.patch applied (see README).
export OT_ROOT="${OT_ROOT:?set OT_ROOT to the patched OpenTitan checkout}"

# Where generated RAL packages and simv builds land.
export OT_WORK="${OT_WORK:-$PWD/ot-work}"

# Python with regtool's dependencies (see README for the list).
export OT_PY="${OT_PY:-python3}"
