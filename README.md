# VeriPower Benchmark Suite

Benchmark suite for [VeriPower](https://github.com/chipweaver/veripower), evaluating
agent-driven chip front-end design.

Three design tasks span an order of magnitude in RTL scale (0.9K to 11K lines of
Verilog, 32K to 3.4M post-synthesis gates). Each task provides a self-contained
natural-language specification as the sole input to the agent. The agent receives
no reference RTL.

| Task | Module | Lines of Code | Gates | Description |
|------|--------|------------:|------:|-------------|
| [gateGPT](gateGPT/) | microgpt\_core | 2.6K | 346K | Q5.11 fixed-point inference engine for a character-level GPT |
| [FSA](FSA/) | fa\_core | 0.9K | 32K | Single-tile FlashAttention accelerator with systolic datapath |
| [Coral-NPU](Coral-NPU/) | CoreMiniAxi | 11.0K | 3,420K | RISC-V RV32IMF scalar-vector-matrix core with AXI4 bus interface |

## Evaluation Protocol

A design is evaluated on four dimensions. All four must be met for a pass verdict.

| Dimension | Criterion |
|-----------|-----------|
| **Functional correctness** | Golden-reference match (gateGPT, FSA) or passing held-out test cases (Coral-NPU) |
| **Synthesis constraints** | Timing closure and, where specified, area and latency budgets |
| **Structural coverage** | Line, condition, FSM, and toggle each above 90% |
| **Lint-CDC** | Zero SpyGlass errors |

Per-task details and thresholds are in each task's README.

## Repository Layout

```
veripower-bench/
├── eda-ref/              # Shared EDA tool wrapper (VCS / DC / PT / SpyGlass)
│
├── gateGPT/
│   ├── handoff/             # Specification + reference algorithm (agent input)
│   └── eval/                # Held-out harness + reference RTL (evaluator only)
│
├── FSA/
│   ├── handoff/             # Specification (agent input)
│   └── eval/                # Golden oracle + testbenches (evaluator only)
│
└── Coral-NPU/
    └── handoff/             # Specification + standard references (agent input)
```

- **`handoff/`** is the complete input given to the agent. Nothing else is provided.
- **`eval/`** (gateGPT, FSA) is held out from the agent and used only for independent evaluation.
- Coral-NPU has no local `eval/` — evaluation uses the upstream CoralNPU test suite directly (see its README for environment pin and instructions).

## EDA Tool Wrapper

[`eda-ref/`](eda-ref/) provides bare wrappers for VCS, Design Compiler,
PrimeTime, and SpyGlass. It is referenced by the task prompts and used for
synthesis, timing analysis, coverage collection, and lint-CDC signoff. It contains
a self-contained demo (`eda-ref/demo/`) for verifying the tool installation.

## Requirements

- **VCS** (tested: L-2016.06) for simulation and coverage
- **Design Compiler** + **PrimeTime** for synthesis and timing analysis
- **SpyGlass** for lint and CDC
- **Python 3** for oracle scripts (gateGPT, FSA)
- **Bazel** + **Verilator** for Coral-NPU (upstream golden test suite)
- A standard-cell library (tested: TSMC 90 nm)

## Related

- [VeriPower](https://github.com/chipweaver/veripower) — the agent orchestration system
- Paper — forthcoming

## License

[MIT](LICENSE)
