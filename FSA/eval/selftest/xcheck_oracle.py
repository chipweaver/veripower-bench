#!/usr/bin/env python3
"""Independent cross-check of the golden oracle (`reference.py`).

The oracle is the root of trust for every verdict, so its own self-tests are not
enough: they were written next to it and share its assumptions. This script
recomputes the expected `O` for the same stimulus with a **separately written
numpy implementation** and compares.

Independence, concretely:
  * numpy `float16` / `float64` ops instead of the oracle's `struct`-based
    quantization and Python-float arithmetic;
  * softmax written directly (max-subtract → exp → sum → divide), not reusing any
    oracle helper;
  * causal handled by boolean masking of the score matrix, not by the oracle's
    "exclude j>i from row-max and the sum" control flow.

numpy is used ONLY here. The oracle itself stays pure stdlib so it runs anywhere.

    python3 eval/selftest/xcheck_oracle.py [--seeds 7,11,13,17,19] [--tol 1e-6]

Exit 0 == every tile of every (seed, causal) case agrees within --tol.
"""
from __future__ import annotations

import argparse
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import reference  # noqa: E402  (the oracle under test)


def attention_numpy(q, k, v, causal: bool) -> np.ndarray:
    """Independent fp32-domain attention over the SAME fp16 stimulus."""
    qf = np.asarray(q, dtype=np.float16).astype(np.float64)
    kf = np.asarray(k, dtype=np.float16).astype(np.float64)
    vf = np.asarray(v, dtype=np.float16).astype(np.float64)

    d = qf.shape[1]
    s = (qf @ kf.T) / np.sqrt(np.float64(d))          # scale 1/sqrt(d) = 0.5 at d=4

    if causal:                                        # mask j > i
        n_rows, n_cols = s.shape
        j = np.arange(n_cols)[None, :]
        i = np.arange(n_rows)[:, None]
        s = np.where(j > i, -np.inf, s)

    m = s.max(axis=1, keepdims=True)                  # safe softmax
    p = np.exp(s - m)
    p = np.where(np.isfinite(s), p, 0.0)              # masked lanes contribute 0
    o = (p @ vf) / p.sum(axis=1, keepdims=True)
    return o.astype(np.float32)                       # pinned reference boundary


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="cross-check reference.py with numpy")
    ap.add_argument("--seeds", default="7,11,13,17,19")
    ap.add_argument("--causal", default="0,1")
    ap.add_argument("--tol", type=float, default=1e-6)
    args = ap.parse_args(argv)

    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    modes = [int(m) for m in args.causal.split(",") if m.strip()]

    vectors = reference.gen_vectors(seeds, modes)
    worst = 0.0
    worst_where = ""
    n_elems = 0

    for v in vectors:
        mine = attention_numpy(v["Q"], v["K"], v["V"], bool(v["causal_en"]))
        theirs = np.asarray(v["expected_O"], dtype=np.float64)
        diff = np.abs(mine.astype(np.float64) - theirs)
        n_elems += diff.size
        if diff.max() > worst:
            worst = float(diff.max())
            idx = np.unravel_index(int(diff.argmax()), diff.shape)
            worst_where = f"seed={v['seed']} causal={v['causal_en']} O{list(idx)}"

    print(f"XCHECK: {len(vectors)} tiles / {n_elems} elements")
    print(f"XCHECK: max |numpy - oracle| = {worst:.3e}   ({worst_where})")
    print(f"XCHECK: tolerance            = {args.tol:.0e}")
    if worst <= args.tol:
        print("XCHECK: PASS")
        return 0
    print("XCHECK: FAIL — the oracle and an independent implementation disagree")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
