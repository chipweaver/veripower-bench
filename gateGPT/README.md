# gateGPT — microgpt_core

Q5.11 fixed-point inference engine for a character-level GPT. The agent implements
a single-layer transformer decoding step with persistent KV cache, producing
synthesizable RTL from a bit-exact fixed-point reference algorithm.

| Property | Value |
|----------|-------|
| Module | `microgpt_core` |
| Scale | 2.6K LoC, 346K gates |
| Source | [gateGPT](https://github.com/fguzman82/gateGPT) |

## Agent Input

Everything in [`handoff/`](handoff/) is given to the agent:

- `brainstorm.md` — complete specification (architecture, interface, constraints, PPA targets)
- `reference/` — bit-exact fixed-point reference algorithm (`fixedpoint.py`, `model.py`) and trained weights (`weights.npz`)

The agent receives no reference RTL. Micro-architecture is unconstrained.

### Prompt

Bare Claude Code:

```text
自主实现 microgpt_core 硬件模块。brainstorm.md 为唯一规格（含验收判据），
reference/ 为数值行为唯一权威，微架构自定。EDA 工具用法参考 ../../eda-ref/。
```

Claude Code + VeriPower:

```text
/veripower:design-flow 自主实现 microgpt_core 硬件模块。brainstorm.md 为唯一规格
（含验收判据），reference/ 为数值行为唯一权威，微架构自定。
本任务授权你自主决策，凡遇人工审批节点一律以你的推荐选项自动通过，无需等我回复。
```

## Evaluation

Evaluation uses held-out harnesses in [`eval/`](eval/). The agent does not see this directory.

### Functional correctness

Black-box verification against the reference algorithm:

- **`eval/harness/tb_core.v`** — two named sequences (greedy "alaya", sampled "rosphod"), bit-exact match
- **`eval/harness/tb_core_vec.v`** — 258 golden vectors across temperature {0.5, 0.7, 1.0, 1.3} × 64 seeds, bit-exact match. Pre-generated vectors in `golden_vectors.txt`; regenerate with `gen_vectors.py`

```bash
# Quick check (two named sequences)
vcs -full64 -sverilog -timescale=1ns/1ps +incdir+<rtl> <rtl>/*.v eval/harness/tb_core.v -o simv
./simv    # -> CORE PASS / CORE FAIL

# Full acceptance (258 vectors)
python3 eval/harness/gen_vectors.py     # regenerate golden_vectors.txt (optional)
vcs -full64 -sverilog -timescale=1ns/1ps +incdir+<rtl> <rtl>/*.v eval/harness/tb_core_vec.v -o simv_vec
./simv_vec +VEC=$(pwd)/eval/harness/golden_vectors.txt    # -> VEC PASS / VEC FAIL
```

### Protocol compliance

**`eval/harness/tb_l2.v`** checks busy/done handshake, start-while-busy ignored,
reset-to-idle, per-position latency, and KV persistence across reset.

```bash
vcs -full64 -sverilog -timescale=1ns/1ps +incdir+<rtl> <rtl>/*.v eval/harness/tb_l2.v -o simv_l2
./simv_l2    # -> LAT/PROTO PASS / FAIL
```

### Synthesis constraints

Using [`../eda-ref/`](../eda-ref/):

| Metric | Target |
|--------|--------|
| Timing (setup WNS) | ≥ 0 @ 12.5 ns (80 MHz) |
| Timing (hold WNS) | ≥ 0, 0 violations |
| Area | ≤ 0.45M NAND2-equivalent |
| Latency (best case) | ≤ 1,156 cycles |
| Latency (worst case, pos=15) | ≤ 1,500 cycles |
| Throughput | ≥ 60,600 tokens/s @ 80 MHz |

Latency is measured by `tb_core.v` (`CYCLES_PER_TOKEN` and `AVG_CYCLES` printouts).

### Structural coverage

Line, condition, FSM, and toggle each > 90%, scoped to the DUT (not testbench).

### Lint-CDC

SpyGlass 0 errors, 0 warnings. Lint goal: `lint/lint_rtl`. CDC goals: `cdc/cdc_setup`, `cdc_setup_check`, `cdc_verify_struct`.

### Additional gates

- RTL must compile with `vcs +v2k` (Verilog-2001, no SystemVerilog)
- No stubs, blackboxes, or `initial`-loaded storage arrays
- UVM functional verification must actually execute (non-zero simulation time, non-zero transaction count)

## Reference RTL

[`eval/reference-rtl/`](eval/reference-rtl/) contains a reference implementation
used to validate the harness (feeding it through `tb_core.v` produces `CORE PASS`).
It is FPGA-oriented and does **not** meet synthesis, lint, or throughput criteria
on standard cells — it is not a valid submission.
