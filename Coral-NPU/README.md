# Coral-NPU — CoreMiniAxi

Scalar-vector-matrix core of a RISC-V RV32IMF machine-learning accelerator with
an AXI4 bus interface, from the CoralNPU project. The agent implements the full
core from a natural-language specification, without access to the upstream Chisel
implementation.

| Property | Value |
|----------|-------|
| Module | `CoreMiniAxi` |
| Scale | 11.0K LoC, 3,420K gates |
| ISA | RV32IMF + Zicsr + Zifencei + Zbb + Zfbfmin, Machine mode only |
| Bus | AXI4 (IHI 0022 Issue L) |
| Source | [CoralNPU](https://github.com/google-coral/coralnpu) |

## Agent Input

Everything in [`handoff/`](handoff/) is given to the agent:

- `brainstorm.md` — complete specification (ISA, CSR, exception model, AXI interface, memory map)
- `refs/` — pinned external standards: RISC-V spec (HTML + machine-readable opcode encodings, open-source, vendored), OpenTitan TL-UL spec. AXI spec (ARM, restricted license) must be obtained separately per `refs/sources.lock`

The agent receives no reference RTL or test cases.

### Prompt

Bare Claude Code:

```text
自主实现 CoreMiniAxi（CoralNPU 标量+浮点子系统） 硬件模块，工具链可参考eda-ref/目录，要求：
（1）RTL使用verilog-2001语法；
（2）架构和功能符合handoff/brainstorm.md；
（3）搭建UVM testbench，测试所有功能特性，并收集覆盖率，行、条件、状态机以及翻转覆盖率 > 90%；
（4）lint/cdc clean；
（5）syntheis timing WNS≥0 @ 100MHz；
（6）禁读任何既有实现、参考模型或同题产物，自建目录独立进行纯净开发；
（7）规格涉及的协议/标准内容以handoff/refs/下提供的原文为唯一真源，不得基于已有/训练知识补全或推断。
```

Claude Code + VeriPower:

```text
/veripower:design-flow 自主实现 CoreMiniAxi（CoralNPU 标量+浮点子系统） 硬件模块，要求：
（1）RTL使用verilog-2001语法；
（2）架构和功能符合handoff/brainstorm.md；
（3）搭建UVM testbench，测试所有功能特性，并收集覆盖率，行、条件、状态机以及翻转覆盖率 > 90%；
（4）lint/cdc clean；
（5）syntheis timing WNS≥0 @ 100MHz；
（6）禁读任何既有实现、参考模型或同题产物，自建目录独立进行纯净开发；
（7）规格涉及的协议/标准内容以handoff/refs/下提供的原文为唯一真源，不得基于已有/训练知识补全或推断。
本任务授权你自主决策，凡遇人工审批节点一律以你的推荐选项自动通过，无需等我回复。
```

## Evaluation

Evaluation uses the upstream CoralNPU golden test suite — 22 cocotb test cases
under Verilator, of which **19 are scoreable** for this configuration.
The remaining 3 are N/A: 2 RVV-specific tests (`rvv_exceptions_test`,
`rvv_frm_hazard_test`) auto-skip on a non-RVV core; `backdoor_load_test`
exercises a Chisel-SRAM DPI hook absent from agent RTL.
The agent's RTL is substituted into the upstream harness and tested under Verilator.

### Environment

| Item | Value |
|------|-------|
| Upstream repo | `https://github.com/google-coral/coralnpu.git` |
| Commit | `b28f749a6dff41ebd19141409e92698fc721e625` |
| Bazel | 8.6.0 (via bazelisk) |
| Verilator | v5.048 (built by Bazel) |
| Test target | `//tests/cocotb:core_mini_axi_sim_cocotb` |
| AXI data width | 128-bit (`core_mini_axi_cc_library` gen_flags `--lsuDataBits=128`) |

### Running

```bash
# 1. Clone and pin upstream
git clone https://github.com/google-coral/coralnpu.git
cd coralnpu && git checkout b28f749a

# 2. Verify baseline (upstream Chisel RTL must pass — proves the harness is trustworthy)
bazel test //tests/cocotb:core_mini_axi_sim_cocotb \
    --test_env=COCOTB_USE_FRONTDOOR=1 --test_output=errors --nocache_test_results

# 3. Substitute agent RTL and test
#    Add a BUILD target that compiles the agent's Verilog instead of the Chisel output,
#    then run the same cocotb suite against it.
```

### Evaluation dimensions

#### Functional correctness

22 test cases in the suite, 19 scoreable for this configuration, organized in three layers:

| Layer | Scope | Tests |
|-------|-------|-------|
| L1 | Interface | Port names, widths, directions; Verilator elaboration |
| L2 | AXI protocol | ID echo, outstanding transactions, burst types, backpressure, frontdoor TCM load |
| L3 | Core function | ISA (riscv\_tests, riscv\_dv), CSRs, exceptions, traps, counters, master-port memory access |

Each layer gates the next: L1 failure means L2/L3 are untestable (not counted as functional failures).

#### Synthesis constraints

Using [`../eda-ref/`](../eda-ref/):

| Metric | Target |
|--------|--------|
| Timing WNS | ≥ 0 @ 10 ns (100 MHz) |

#### Structural coverage

Line, condition, FSM, and toggle each > 90%, scoped to the DUT.

#### Lint-CDC

SpyGlass 0 errors, 0 warnings.

#### Additional gates

- RTL must use Verilog-2001 syntax
- UVM functional verification with actual execution (non-zero simulation time)
