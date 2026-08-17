#!/usr/bin/env python3
"""Generate an expanded black-box golden stimulus set from the Q5.11 reference.

Each case is one full incremental generation run. The host can only vary
(sample_mode, seed, inv_temp) — token_in/pos_in are driven by the autoregressive
loop (always start token 0 at pos 0) — so coverage comes from a temperature x
seed sweep of the sampled path (greedy is deterministic: one sequence).

Output `golden_vectors.txt` streams plain integers (no comments), one case/line:
    mode seed inv_temp ntok tok0 tok1 ... tok{ntok-1}
consumed by tb_core_vec.v via $fscanf. Cases 0-1 are the named acceptance
sequences (alaya / rosphod)."""
import os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "..", "..", "handoff", "reference")
sys.path.insert(0, REF)
from model import ModelConfig
from fixedpoint import QModel, generate

cfg = ModelConfig()
sd = dict(np.load(os.path.join(REF, "weights.npz")))
m = QModel(sd, cfg)

def inv_temp(T):                      # inv_temp in Q5.11 = round(2048 / T)
    return int(round(2048.0 / T))

cases = [(0, 0, 0),                   # greedy  -> alaya
         (1, 2, inv_temp(0.7))]       # sampled seed=2 T=0.7 -> rosphod
for T in (0.5, 0.7, 1.0, 1.3):        # temperature x seed sweep of the sampled path
    for seed in range(1, 65):
        cases.append((1, seed, inv_temp(T)))

out = os.path.join(HERE, "golden_vectors.txt")
with open(out, "w") as f:
    for mode, seed, it in cases:
        toks, _ = generate(m, seed, it, greedy=(mode == 0))
        f.write(f"{mode} {seed} {it} {len(toks)} " + " ".join(map(str, toks)) + "\n")

g, gs = generate(m, 0, 0, greedy=True)
s, ss = generate(m, 2, inv_temp(0.7), greedy=False)
assert g == [1, 12, 1, 25, 1] and s == [18, 15, 19, 16, 8, 15, 4], "named golden mismatch"
print(f"wrote {len(cases)} cases to {out}; named OK: {gs} {ss}")
