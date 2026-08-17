# FSA — fa_core

Single-tile FlashAttention accelerator. The agent implements `O = softmax((Q·K^T)/sqrt(d))·V`
with optional causal masking, fp16 I/O and fp32 internal arithmetic, as a single
synthesizable RTL module with a shared datapath.

| Property | Value |
|----------|-------|
| Module | `fa_core` |
| Scale | 0.9K LoC, 32K gates |
| Dimensions | Q, K, V: 4×4, fp16 in/out, fp32 internal |
| Source | [FSA](https://github.com/VCA-EPFL/FSA) |

## Agent Input

Everything in [`handoff/`](handoff/) is given to the agent:

- `brainstorm.md` — complete specification (algorithm, interface, numerical parameters, PPA targets)

The agent receives no reference RTL or oracle. Micro-architecture is unconstrained.

### Prompt

Bare Claude Code:

```text
自主实现 fa_core 硬件模块。brainstorm.md 为唯一规格（含验收判据），
微架构自定。EDA 工具用法参考 ../../eda-ref/。
```

Claude Code + VeriPower:

```text
/veripower:design-flow 自主实现 fa_core 硬件模块。brainstorm.md 为唯一规格
（含验收判据），微架构自定。
本任务授权你自主决策，凡遇人工审批节点一律以你的推荐选项自动通过，无需等我回复。
```

## Evaluation

Evaluation uses the held-out environment in [`eval/`](eval/). The agent
does not see this directory.

### Functional correctness

An independent oracle (`eval/reference.py`, pure Python, no numpy/torch)
computes mathematically exact attention in high precision. Two testbenches score
the agent's RTL against this oracle:

- **`eval/tb/fa_core_golden_tb.sv`** — tolerance gate: every output element within `MaxErr < 1e-2` and `MAE < 1e-3`, plus latency gate (≤ 80 cycles)
- **`eval/tb/fa_core_protocol_tb.sv`** — protocol gate: SC-003/004/005/006 handshake robustness and single-cycle `done` pulse

```bash
# Run all gates (tolerance + latency + protocol)
eval/run/golden_run.sh --rtl <filelist.rtl.f> --mode all

# Oracle self-check
cd eval && python3 -m pytest test_reference.py -q            # 27 tests
python3 eval/selftest/xcheck_oracle.py                       # independent numpy cross-check
eval/selftest/run_selftest.sh                                # harness positive/negative matrix (16 cases)
```

### Synthesis constraints

Using [`../eda-ref/`](../eda-ref/):

| Metric | Target |
|--------|--------|
| Timing WNS | ≥ 0 @ 10 ns (100 MHz) |
| End-to-end latency | ≤ 80 cycles |

### Structural coverage

Line, condition, FSM, and toggle each > 90%, scoped to the DUT.

### Lint-CDC

SpyGlass 0 errors, 0 warnings.

### Additional gates

- RTL must use Verilog-2001 syntax (Design Compiler reads with `-format verilog`, no errors)
