# VeriPower Benchmark Suite

Benchmark suite for [VeriPower](https://github.com/chipweaver/veripower), evaluating
agent-driven chip front-end design.

Five design tasks span an order of magnitude in RTL scale (0.9K to 16K lines of
Verilog, 32K to 3.4M post-synthesis gates) and two design shapes: compute
datapaths with a custom handshake, and bus-attached register-mapped control IP.
Each task provides a self-contained natural-language specification as the sole
input to the agent. The agent receives no reference RTL.

| Task | Module | Lines of Code | Gates | Description |
|------|--------|------------:|------:|-------------|
| [FSA](FSA/) | fa\_core | 0.9K | 32K | Single-tile FlashAttention accelerator with systolic datapath |
| [gateGPT](gateGPT/) | microgpt\_core | 2.6K | 346K | Q5.11 fixed-point inference engine for a character-level GPT |
| [i2c](i2c/) | i2c | 8.9K | 61K | Dual-mode I²C controller/target on a TL-UL bus |
| [usbdev](usbdev/) | usbdev | 15.9K | 144K | USB 2.0 full-speed device controller, two clock domains |
| [Coral-NPU](Coral-NPU/) | CoreMiniAxi | 11.0K | 3,420K | RISC-V RV32IMF scalar-vector-matrix core with AXI4 bus interface |

## Evaluation Protocol

A design is evaluated on four dimensions. All four must be met for a pass verdict.

| Dimension | Criterion |
|-----------|-----------|
| **Functional correctness** | Golden-reference match (gateGPT, FSA) or passing held-out test cases (i2c, usbdev, Coral-NPU) |
| **Synthesis constraints** | Timing closure and, where specified, area and latency budgets |
| **Coverage** | Line, condition, FSM and toggle each above 90%; functional coverage above 90% where the task requires it |
| **Lint-CDC** | Zero SpyGlass errors — lint, CDC, and RDC where the design has more than one reset domain |

Per-task details and thresholds are in each task's README.

## Repository Layout

```
veripower-bench/
├── eda-ref/              # Shared EDA tool wrapper (VCS / DC / PT / SpyGlass)
├── ot-harness/           # Shared OpenTitan DV harness (i2c, usbdev)
│
├── gateGPT/
│   ├── intent/              # Specification + reference algorithm (agent input)
│   └── eval/                # Held-out harness + reference RTL (evaluator only)
│
├── FSA/
│   ├── intent/              # Specification (agent input)
│   └── eval/                # Golden oracle + testbenches (evaluator only)
│
├── i2c/  usbdev/
│   ├── intent/              # Specification + pinned spec documents (agent input)
│   └── eval/                # The graded test set (evaluator only)
│
└── Coral-NPU/
    └── intent/              # Specification + standard references (agent input)
```

- **`intent/`** is the complete input given to the agent. Nothing else is provided.
- **`eval/`** is held out from the agent and used only for independent evaluation.
- Coral-NPU has no local `eval/` — evaluation uses the upstream CoralNPU test suite directly (see its README for environment pin and instructions).
- i2c and usbdev share one oracle: [`ot-harness/`](ot-harness/) builds each IP's
  upstream OpenTitan UVM environment and runs it against the submitted RTL. Their
  `eval/` holds only the graded test list; each task's README says how that list
  was derived and what the reference measures.

## OpenTitan DV Harness

[`ot-harness/`](ot-harness/) builds the upstream OpenTitan UVM verification environment for
an IP and runs it against a submitted RTL implementation. It replaces fusesoc and
dvsim with three small resolvers, carries the patch the pinned commit needs, and
generates the negative-control DUT. Two tasks share it today; adding a third means
adding a `intent/` and an `eval/`, not another oracle.

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
- A **pinned OpenTitan checkout** plus Python packages for i2c and usbdev (see [`ot-harness/README.md`](ot-harness/README.md))
- A standard-cell library (tested: TSMC 90 nm). The suite pins no library: export `LIB_DB`
  and `WIRE_LOAD_MODEL` for whichever one you bring, and use the same pair for both arms.

## Related

- [VeriPower](https://github.com/chipweaver/veripower) — the agent orchestration system
- Paper — forthcoming

## License

[MIT](LICENSE)
