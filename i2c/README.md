# i2c — i2c

Dual-mode I²C peripheral on a TL-UL bus: controller and target, Standard /
Fast / Fast-mode Plus, four byte-formatted queues, 32 registers, 16 interrupts.
The agent implements it from a natural-language specification, without access to
the upstream RTL, its testbench, or the register-description source.

| Property | Value |
|----------|-------|
| Module | `i2c` |
| Scale | 8.9K LoC (4.1K hand-written + 4.9K register file), 61K gates |
| Bus | TL-UL device (OpenTitan comportable) |
| Source | [OpenTitan](https://github.com/lowRISC/opentitan) `hw/ip/i2c` |

## Agent Input

Everything in [`intent/`](intent/) is given to the agent — copy the whole directory to
`<module>/intent/` in the working tree you point it at:

- `brainstorm.md` — the design request: functional scope, the exact port list and
  package contract, environment constraints, PPA targets, acceptance criteria
- `refs/opentitan-i2c/` — the pinned OpenTitan documentation for this IP
  (`theory_of_operation.md`, `registers.md`, `interfaces.md`,
  `programmers_guide.md`, `README.md`), Apache-2.0, vendored
- `refs/opentitan-comportability/comportability.md` — the comportable-IP
  specification: register, interrupt, alert and bus conventions
- `refs/opentitan-tlul/` — the TL-UL bus protocol, including SECDED integrity.
  `TlulProtocolChecker.md` lists the per-signal properties; the harness binds the
  checker onto the submitted top as `EndpointType("Device")`, under which the
  request-channel properties are assumptions on the testbench and nine are
  assertions on the design — five on the response channel and four requiring an
  eventual `d_error` for an illegal request
- `refs/tlul-flattened-layout.md` — where each TL-UL field sits when `tl_i`/`tl_o`
  are plain vectors, derived mechanically from the pinned `tlul_pkg`

Withheld: the upstream RTL, the DV environment, and
`hw/ip/i2c/data/i2c.hjson` — `regtool` turns that hjson into `i2c_reg_pkg` +
`i2c_reg_top`, 4,877 of the module's 8,949 lines. `registers.md` is the same truth
in human-readable form; the register file is the agent's to write.

The I²C specification itself (NXP UM10204 rev. 6) is not redistributable and must
be obtained separately. `theory_of_operation.md` covers every clause this module
implements.

### Prompt

Bare Claude Code:

```text
自主实现 i2c 硬件模块。要求：
（1）intent/brainstorm.md 为唯一规格（含接口契约与验收判据），微架构自定；
（2）规格涉及的协议/标准内容以 intent/refs/ 下提供的原文为唯一真源，
     不得基于已有/训练知识补全或推断；
（3）禁读任何既有实现、参考模型或同题产物，自建目录独立进行纯净开发；
（4）RTL 用 SystemVerilog，顶层模块名 i2c，端口逐字符符合 §3 端口表；
     寄存器文件不手写——按 §3 先写机读的寄存器描述，再由它生成。
EDA 工具用法参考 ../../eda-ref/。
```

Claude Code + VeriPower:

```text
/veripower:design-flow 自主实现 i2c 硬件模块。要求：
（1）intent/brainstorm.md 为唯一规格（含接口契约与验收判据），微架构自定；
（2）规格涉及的协议/标准内容以 intent/refs/ 下提供的原文为唯一真源，
     不得基于已有/训练知识补全或推断；
（3）禁读任何既有实现、参考模型或同题产物，自建目录独立进行纯净开发；
（4）RTL 用 SystemVerilog，顶层模块名 i2c，端口逐字符符合 §3 端口表；
     寄存器文件不手写——按 §3 先写机读的寄存器描述，再由它生成。
本任务授权你自主决策，凡遇人工审批节点一律以你的推荐选项自动通过，无需等我回复。
```

## Evaluation

The oracle is OpenTitan's own UVM verification environment for this IP, driven
through [`../ot-harness/`](../ot-harness/) — which also documents how the graded
set is derived and how to regenerate it.

```bash
cd ../ot-harness
export OT_ROOT=<patched opentitan> OT_WORK=/tmp/ot-work OT_PY=<python>
./build.sh --ip i2c --rtl <submission.f>
./run.sh   --ip i2c --simv $OT_WORK/i2c/simv --list ../i2c/eval/scoreable.txt
```

### Functional correctness

Every test in [`eval/scoreable.txt`](eval/scoreable.txt) must PASS — **39 of the
IP's 50 upstream tests**. `NOVERDICT` is a harness problem, never a design
verdict.

`ot-harness/scoreable.py` derived that set: seeds 1 and 2 of the reference agree
at 45 of 50; the rename filter takes it to 39; the generated stub fails all 50.

#### Not graded, and why

Five tests fail on the reference RTL itself under this toolchain:

| Test | Cause |
|---|---|
| `i2c_host_stress_all` | scoreboard reports an uncompared item at drain (`i2c_scoreboard.sv:714`) |
| `i2c_target_unexp_stop` | data mismatch `0xff` vs `0x4c` (`i2c_scoreboard.sv:680`), reproduces on seeds 1, 2 and 7 |
| `i2c_target_hrst` | wait timeout — **seed-dependent**: fails on seeds 1 and 2, passes on seed 7 |
| `i2c_host_stress_all_with_rand_reset` | a TL access is still outstanding after 10,000 cycles |
| `i2c_target_stress_all_with_rand_reset` | same |

`i2c_target_hrst` is the reason criterion 1 is an N-seed sweep rather than a
single run: a test that is flaky on the reference would otherwise fail a correct
submission at random.

Six further tests are excluded by criterion 2 — each reads a register through the
RAL backdoor, i.e. through an hdl path naming the reference's register file:

| Test | Register read through the backdoor | Why it has to be |
|---|---|---|
| `i2c_target_nack_acqfull` | `TARGET_NACK_COUNT` | `rc`: a frontdoor read destroys the value |
| `i2c_target_nack_acqfull_addr` | same | same |
| `i2c_target_nack_txstretch` | same | same |
| `i2c_host_fifo_full` | `HOST_FIFO_STATUS`, `STATUS` | `ro`, but a FIFO level moves during a bus read |
| `i2c_host_fifo_reset_rx` | same | same |
| `i2c_target_tx_stretch_ctrl` | `TARGET_EVENTS.tx_pending` | a `csr_spinwait` whose polling perturbs the stretch it waits on |

`INTR_STATE` was the one register where the backdoor was avoidable, and moving its
two read sites to the frontdoor is what keeps `i2c_host_fifo_overflow` and the
target-mode suite in the scoreable set. `ot-harness/README.md` records the two wrong
hypotheses that preceded that conclusion and the reference runs that killed them.


### Synthesis constraints

Using [`../eda-ref/`](../eda-ref/):

| Metric | Target |
|--------|--------|
| Timing (setup/hold WNS) | ≥ 0 @ 12.5 ns (80 MHz) |
| Area | ≤ 90,000 NAND2-equivalent |

Timing is evaluated with no interconnect estimate: `WIRE_LOAD_MODEL=none`, which is what
`eda-ref/env.sh` sets and what the VeriPower arm must be given. A library declares neither a
default wire load model nor a selection group, and the choice is not free — measured across
every bucket of a TSMC 90 library on five real designs, three close at exactly 0.00 ns setup
with no model at all, so any bucket puts them negative. Both arms of one evaluation must use
the same value or their timing and power are not comparable.

### Coverage

Structural — line, condition, FSM and toggle each > 90 %, scoped to the DUT — and
**functional coverage > 90 %** from covergroups you write against your own
testplan. Real signoff gates both: this IP's own checklist lists
`SIM_CODE_COVERAGE_V2` and `SIM_FUNCTIONAL_COVERAGE_V2` as separate items,
alongside `FUNCTIONAL_COVERAGE_IMPLEMENTED` and `TESTPLAN_REVIEWED`. Structural
coverage alone is reachable with stimulus and no checking.

### Lint-CDC

SpyGlass 0 errors, 0 warnings. The off-chip SCL/SDA inputs are asynchronous to
`clk_i`, so the CDC goals engage on the input synchronisers.

### Additional gates

- SystemVerilog. A comportable peripheral's interface is built on `tlul_pkg`'s
  packed structs and its register file is generated from a description, so this is
  the IP's real flow
- The register file is not hand-written. You author a machine-readable register
  description and generate the RTL from it; how you generate it is your choice.
  The evaluator's register model is generated independently from the
  specification side, so a wrong offset, access type or reset value shows up on
  the CSR tests
- No stubs, blackboxes, or `initial`-loaded storage arrays

## Reference baseline

Numbers from the reference RTL on this toolchain, for calibration. They are not
targets — the targets are in `../intent/brainstorm.md` §6.

| | Reference |
|---|---|
| RTL | 8,949 lines (4,072 hand-written + 4,877 generated by `regtool`) |
| Synthesis @ 12.5 ns | WNS **+2.47 ns**, 23,391 cells, 172,789 µm² = **61,221** NAND2 |
| Synthesis @ 10 ns | WNS +0.46 ns, 23,407 cells, 172,864 µm² = 61,247 NAND2 |
| Registers | 32 |
| Interrupts | 16 |
| Clock domains | 1 (`clk_i`); SCL/SDA are off-chip and asynchronous |

Library: TSMC 90 nm `slow.db`, NAND2X1 = 2.8224 µm². Synthesis is
`compile_ultra -no_autoungroup` with input/output delays at 20 % of the period.

SpyGlass on the reference RTL with a two-line SGDC (one clock, SCL/SDA declared
off-chip) and none of OpenTitan's own waivers: `cdc/cdc_verify_struct` reports one
`Ar_unsync01` and one `Ac_clockperiod01`. Fifteen of the errors are
`ErrorAnalyzeBBox` on the behavioural `prim_ram_1p` model and on `prim_subreg_arb`
(a `$error` in an assertion); a submission built from standard cells per the
brainstorm does not hit them. The counts are a calibration point, not a target —
the gate is 0 errors and 0 warnings on your own RTL and your own SGDC.

