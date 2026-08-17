"""Flash-attention single-tile golden reference — the independent ORACLE.

The held-out, arm-neutral oracle for adjudicating a `fa_core` DUT (either the
`fa_core` or the retained `fa_core_fsa` variant — they share one black-box
contract; see handoff/brainstorm.md). It produces the trusted attention output the DUT is
measured against — it is NOT the DUT's model: it computes the mathematically
exact attention in high precision and lets the DUT deviate up to the pinned
tolerance (MaxErr < 1e-2, MAE < 1e-3). It deliberately does NOT replicate any
implementation approximation (exp2 PWL, fp16-P rounding, a hardware divider) —
doing so would co-design the golden with an implementation and destroy its
independence.

Engine: pure stdlib (no torch / numpy). fp16 stimulus quantization is IEEE-754
half via `struct` ('e'); the reference arithmetic runs in Python fp64 (strictly
more precise than the pinned "fp32 reference" — the ~1e-7 gap is negligible vs
the 1e-3 gate), with scores/outputs rounded to fp32 at the domain boundaries.
Fully deterministic (stdlib `random`, seeded; no BLAS threading) and auditable.

Contract pinned by handoff/brainstorm.md (the single authoritative spec):
  - dims Br = Bc = d = 4; scale 1/√d = 0.5; safe (max-subtracted) softmax.
  - causal: positions j > i masked (excluded from row-max and softmax).
  - stimulus: N(0,1) clamped to ±4σ, quantized to fp16, seeded.
  - I/O fp16 (E5M10); reference domain boundaries rounded to fp32 (E8M23).

The held-out vector bundle (gen_vectors) is what the fixed adjudication TB plays;
the seeds used at adjudication are held out from any implementation's dev seeds.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import struct
import sys

N_DEFAULT = 4  # Br = Bc
D_DEFAULT = 4  # head dim
CLAMP_SIGMA = 4.0  # stimulus clamp: ±4σ of N(0,1)
MAX_ABS_ERR = 1e-2  # pinned acceptance: per-element |err|
MAE_BOUND = 1e-3  # pinned acceptance: mean |err| over the 16 O elements


# --------------------------------------------------------------------------- #
# precision primitives                                                         #
# --------------------------------------------------------------------------- #
def quantize_fp16(x: float) -> float:
    """Round x to the nearest IEEE-754 half (fp16), returned as a Python float
    holding an exactly-half-representable value — the exact bits the DUT sees."""
    return struct.unpack("<e", struct.pack("<e", float(x)))[0]


def _fp32(x: float) -> float:
    """Round to IEEE-754 single (fp32) — the pinned reference domain boundary."""
    return struct.unpack("<f", struct.pack("<f", float(x)))[0]


def fp16_bits(x: float) -> int:
    """The 16-bit IEEE-754 half pattern of x (as an int) — the exact bits on the
    bus lane the DUT sees."""
    return struct.unpack("<H", struct.pack("<e", float(x)))[0]


def fp32_bits(x: float) -> int:
    """The 32-bit IEEE-754 single pattern of x (as an int). Expected `O` travels
    to the TB as these bits, not as decimal text — a bit pattern round-trips
    exactly, so the comparison floor carries no text-conversion noise."""
    return struct.unpack("<I", struct.pack("<f", float(x)))[0]


def pack_row(row: list[float]) -> int:
    """Pack 4 fp16 elements into one 64-bit beat, LITTLE-ENDIAN per the spec's
    "Beat bit-packing" contract: element j in bits [16·j +: 16] (element 0 in
    [15:0], element 3 in [63:48])."""
    beat = 0
    for j, x in enumerate(row):
        beat |= fp16_bits(x) << (16 * j)
    return beat


# --------------------------------------------------------------------------- #
# attention math                                                              #
# --------------------------------------------------------------------------- #
def qk_scores(Q: list[list[float]], K: list[list[float]]) -> list[list[float]]:
    """S = (Q · Kᵀ) · (1/√d), rounded to fp32. d taken from the K row width."""
    n = len(Q)
    d = len(K[0])
    scale = 1.0 / math.sqrt(d)
    S = [[0.0] * len(K) for _ in range(n)]
    for i in range(n):
        for j in range(len(K)):
            acc = 0.0
            for k in range(d):
                acc += Q[i][k] * K[j][k]
            S[i][j] = _fp32(acc * scale)
    return S


def softmax_row(row: list[float], mask: list[bool] | None = None) -> list[float]:
    """Safe softmax over one row. Masked entries are excluded (treated as -inf):
    they never win the row-max and contribute exactly 0. Assumes ≥1 unmasked
    entry (the causal diagonal j=i is always kept)."""
    vals = [
        (-math.inf if (mask is not None and mask[j]) else row[j])
        for j in range(len(row))
    ]
    m = max(vals)  # max over unmasked (masked are -inf)
    exps = [(math.exp(v - m) if v != -math.inf else 0.0) for v in vals]
    total = sum(exps)
    return [e / total for e in exps]


def attention_reference(
    Q: list[list[float]],
    K: list[list[float]],
    V: list[list[float]],
    causal: bool = False,
) -> list[list[float]]:
    """O = softmax((Q·Kᵀ)/√d) · V, with optional causal masking (j > i). Output
    rounded to fp32. Inputs are assumed already fp16-quantized (cast up to fp64
    here, so DUT and reference see bit-identical inputs)."""
    n = len(Q)
    d = len(V[0])
    S = qk_scores(Q, K)
    out = [[0.0] * d for _ in range(n)]
    for i in range(n):
        mask = [(causal and j > i) for j in range(n)]
        P = softmax_row(S[i], mask)
        for c in range(d):
            acc = 0.0
            for j in range(n):
                acc += P[j] * V[j][c]
            out[i][c] = _fp32(acc)
    return out


# --------------------------------------------------------------------------- #
# stimulus + held-out vector bundle                                           #
# --------------------------------------------------------------------------- #
def _clamp(x: float, bound: float) -> float:
    return max(-bound, min(bound, x))


def gen_stimulus(
    seed: int, causal_en: int, n: int = N_DEFAULT, d: int = D_DEFAULT
) -> dict:
    """Seeded fp16 Q/K/V ~ N(0,1) clamped to ±4σ. Matrices are drawn in the
    fixed order Q, K, V so a given seed is fully reproducible."""
    rng = random.Random(seed)

    def mat() -> list[list[float]]:
        return [
            [quantize_fp16(_clamp(rng.gauss(0.0, 1.0), CLAMP_SIGMA)) for _ in range(d)]
            for _ in range(n)
        ]

    Q, K, V = mat(), mat(), mat()
    return {"seed": seed, "causal_en": causal_en, "Q": Q, "K": K, "V": V}


def gen_vectors(seeds, causal_modes=(0, 1)) -> list[dict]:
    """The held-out bundle the fixed adjudication TB plays: for each (seed, mode)
    a stimulus plus its expected fp32 output."""
    out = []
    for seed in seeds:
        for cz in causal_modes:
            st = gen_stimulus(seed, cz)
            st["expected_O"] = attention_reference(
                st["Q"], st["K"], st["V"], causal=bool(cz)
            )
            out.append(st)
    return out


def emit_tb(vectors: list[dict]) -> str:
    """Serialize vectors to the fixed golden TB's token stream (whitespace/newline
    separated, NO comments so `$fscanf` reads it directly):

        <N>
        <causal_en> <12 beats %016x, order Q,K,V rows 0-3> <16 expected O %08x>
        ...

    Beats are little-endian per pack_row; expected O is flattened row-major
    (O[0][0..3], O[1][0..3], ...) and emitted as **fp32 bit patterns** (%08x)
    which the TB decodes with fp32_to_real — no decimal text in the path, so the
    tolerance floor is unaffected by formatting."""
    lines = [str(len(vectors))]
    for v in vectors:
        beats = [pack_row(r) for r in (v["Q"] + v["K"] + v["V"])]
        eo = v["expected_O"]
        exp = [eo[i][c] for i in range(len(eo)) for c in range(len(eo[0]))]
        toks = [str(v["causal_en"])]
        toks += [f"{b:016x}" for b in beats]
        toks += [f"{fp32_bits(x):08x}" for x in exp]
        lines.append(" ".join(toks))
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- #
# CLI: emit the vector bundle (held-out seeds supplied by the operator)        #
# --------------------------------------------------------------------------- #
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="fa_core golden reference — emit held-out vectors (JSON or TB)"
    )
    ap.add_argument(
        "--seeds",
        default="1,2,3,4,5",
        help="comma-separated held-out seeds (default 1..5)",
    )
    ap.add_argument(
        "--causal",
        default="0,1",
        help="comma-separated causal_en modes (default both)",
    )
    ap.add_argument(
        "--format",
        choices=["json", "tb"],
        default="json",
        help="json bundle (default) or the golden-TB token stream",
    )
    ap.add_argument("--out", default="-", help="output path ('-' = stdout)")
    args = ap.parse_args(argv)

    seeds = [int(s) for s in args.seeds.split(",") if s.strip() != ""]
    modes = tuple(int(m) for m in args.causal.split(",") if m.strip() != "")
    vectors = gen_vectors(seeds, modes)
    if args.format == "tb":
        text = emit_tb(vectors)
    else:
        bundle = {
            "reference": "fa_core",
            "variants": ["fa_core", "fa_core_fsa"],
            "tolerance": {"max_abs_err": MAX_ABS_ERR, "mae": MAE_BOUND},
            "scale": 1.0 / math.sqrt(D_DEFAULT),
            "vectors": vectors,
        }
        text = json.dumps(bundle, indent=2)
    if args.out == "-":
        sys.stdout.write(text + "\n")
    else:
        with open(args.out, "w") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
