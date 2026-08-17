#!/usr/bin/env python3
"""Oracle self-check: the Q5.11 reference reproduces the acceptance token
sequences (alaya / rosphod). Run this to confirm the golden oracle is intact
before trusting it against an implementation under test."""
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

g_toks, g_str = generate(m, 0, 0, greedy=True)
s_toks, s_str = generate(m, 2, 2926, greedy=False)   # seed=2, T=0.7 -> inv_temp=round(2048/0.7)=2926
print("greedy :", g_toks, g_str)
print("sampled:", s_toks, s_str)
assert g_toks == [1, 12, 1, 25, 1] and g_str == "alaya",   "greedy golden mismatch"
assert s_toks == [18, 15, 19, 16, 8, 15, 4] and s_str == "rosphod", "sampled golden mismatch"
print("GOLDEN OK")
