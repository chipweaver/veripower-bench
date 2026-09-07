# usbdev — usbdev

USB 2.0 full-speed **device** controller on a TL-UL bus: the full device-side
protocol on D+/D− (bit stuffing, CRC5/CRC16, SETUP/IN/OUT transactions, data
toggles, STALL/NAK, link reset / suspend / resume / wake), 12 IN + 12 OUT
endpoints, an on-chip packet buffer handed between software and hardware through
three buffer FIFOs, 44 registers, 18 interrupts, and a second always-on clock
domain. The agent implements it from a natural-language specification, without
access to the upstream RTL, its testbench, or the register-description source.

| Property | Value |
|----------|-------|
| Module | `usbdev` |
| Scale | 15.9K LoC (5.3K hand-written + 10.6K register file), 144K gates |
| Bus | TL-UL device (OpenTitan comportable) |
| Clocks | 2 — `clk_i` (48 MHz USB) and `clk_aon_i`, asynchronous |
| Source | [OpenTitan](https://github.com/lowRISC/opentitan) `hw/ip/usbdev` |

## Agent Input

Everything in [`intent/`](intent/) is given to the agent — copy the whole directory to
`<module>/intent/` in the working tree you point it at:

- `brainstorm.md` — the design request: functional scope, the exact port list and
  package contract, environment constraints, PPA targets, acceptance criteria
- `refs/opentitan-usbdev/` — the pinned OpenTitan documentation for this IP
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
`hw/ip/usbdev/data/usbdev.hjson` — `regtool` turns that hjson into
`usbdev_reg_pkg` + `usbdev_reg_top`, 10,645 of the module's 15,942 lines.
`registers.md` is the same truth in human-readable form; the register file is the
agent's to write.

The USB 2.0 specification itself (USB-IF) is not redistributable and must be
obtained separately. `theory_of_operation.md` covers every clause this module
implements.

### Prompt

Bare Claude Code:

```text
自主实现 usbdev 硬件模块。要求：
（1）intent/brainstorm.md 为唯一规格（含接口契约与验收判据），微架构自定；
（2）规格涉及的协议/标准内容以 intent/refs/ 下提供的原文为唯一真源，
     不得基于已有/训练知识补全或推断；
（3）禁读任何既有实现、参考模型或同题产物，自建目录独立进行纯净开发；
（4）RTL 用 SystemVerilog，顶层模块名 usbdev，端口逐字符符合 §3 端口表；
     寄存器文件不手写——按 §3 先写机读的寄存器描述，再由它生成。
EDA 工具用法参考 ../../eda-ref/。
```

Claude Code + VeriPower:

```text
/veripower:design-flow 自主实现 usbdev 硬件模块。要求：
（1）intent/brainstorm.md 为唯一规格（含接口契约与验收判据），微架构自定；
（2）规格涉及的协议/标准内容以 intent/refs/ 下提供的原文为唯一真源，
     不得基于已有/训练知识补全或推断；
（3）禁读任何既有实现、参考模型或同题产物，自建目录独立进行纯净开发；
（4）RTL 用 SystemVerilog，顶层模块名 usbdev，端口逐字符符合 §3 端口表；
     寄存器文件不手写——按 §3 先写机读的寄存器描述，再由它生成。
本任务授权你自主决策，凡遇人工审批节点一律以你的推荐选项自动通过，无需等我回复。
```

## Evaluation

The oracle is OpenTitan's own UVM verification environment for this IP — 99 tests,
the largest per-IP suite in the tree — driven through
[`../ot-harness/`](../ot-harness/), which also documents how the graded set is
derived and how to regenerate it.

```bash
cd ../ot-harness
export OT_ROOT=<patched opentitan> OT_WORK=/tmp/ot-work OT_PY=<python>
./build.sh --ip usbdev --rtl <submission.f>
./run.sh   --ip usbdev --simv $OT_WORK/usbdev/simv --list ../usbdev/eval/scoreable.txt
```

### Functional correctness

Every test in [`eval/scoreable.txt`](eval/scoreable.txt) must PASS — **95 of the
IP's 99 upstream tests**. `NOVERDICT` is a harness problem, never a design
verdict.

`ot-harness/scoreable.py` derived that set: seeds 1 and 2 of the reference agree
test-for-test at 98 of 99; the rename filter removes nothing; the generated stub
removes three more.

#### Not graded, and why

| Test | Why |
|---|---|
| `usbdev_stress_all_with_rand_reset` | its sequence does not exist upstream — inherited from the shared `stress_tests.hjson`, which assumes every IP provides a `<ip>_stress_all_vseq`; usbdev has 71 sequences and none is that one |
| `usbdev_aon_wake_reset` | passes against the do-nothing control |
| `usbdev_data_toggle_clear` | passes against the do-nothing control |
| `usbdev_data_toggle_restore` | passes against the do-nothing control |

The last three delegate all their checking to the scoreboard, which compares the
DUT's USB traffic against `usbdev_bfm`. A design that emits no traffic at all is
never contradicted, so absence of activity reads as absence of errors and the test
ends clean. They cannot distinguish a correct design from one that does nothing,
which is exactly what criterion 3 exists to find.

### Synthesis constraints

Using [`../eda-ref/`](../eda-ref/):

| Metric | Target |
|--------|--------|
| Timing (setup/hold WNS) | ≥ 0 @ 10 ns (100 MHz, `clk_i`) |
| Area | ≤ 200,000 NAND2-equivalent (packet buffer included) |

Timing is evaluated with no interconnect estimate: `WIRE_LOAD_MODEL=none`, which is what
`eda-ref/env.sh` sets and what the VeriPower arm must be given. A library declares neither a
default wire load model nor a selection group, and the choice is not free — measured across
every bucket of a TSMC 90 library on five real designs, three close at exactly 0.00 ns setup
with no model at all, so any bucket puts them negative. Both arms of one evaluation must use
the same value or their timing and power are not comparable.

`clk_aon_i` is declared asynchronous to `clk_i`.

### Coverage

Structural — line, condition, FSM and toggle each > 90 %, scoped to the DUT — and
**functional coverage > 90 %** from covergroups you write against your own
testplan. Real signoff gates both: this IP's own checklist lists
`SIM_CODE_COVERAGE_V2` and `SIM_FUNCTIONAL_COVERAGE_V2` as separate items,
alongside `FUNCTIONAL_COVERAGE_IMPLEMENTED` and `TESTPLAN_REVIEWED`. Structural
coverage alone is reachable with stimulus and no checking.

### Lint-CDC

SpyGlass 0 errors, 0 warnings on lint, CDC **and RDC**. Reset-domain crossing is a
separate signoff gate from CDC in real practice — this IP's checklist carries
`RDC_COMPLETE` and `RDC_SETUP` — and it is a live gate here because the design has
two independent reset domains, `rst_ni` and `rst_aon_ni`. Goal:
`rdc/rdc_verify_struct` under `GuideWare/2016.06/block/rtl_handoff`; measured on
the reference, it identifies both resets and finds zero crossings.

This is also the one task in the suite with a genuine second clock domain: on the reference RTL the `cdc/cdc_verify_struct` goal reports
`Clock_sync06`, `Convergence` and `Ar_unsync01` on the `clk_i` ↔ `clk_aon_i`
crossings in the wake-control and wake-event registers, so the CDC gate is
load-bearing rather than vacuous.

### Additional gates

- SystemVerilog. A comportable peripheral's interface is built on `tlul_pkg`'s
  packed structs and its register file is generated from a description, so this is
  the IP's real flow
- The register file is not hand-written. You author a machine-readable register
  description and generate the RTL from it; how you generate it is your choice.
  The evaluator's register model is generated independently from the
  specification side, so a wrong offset, access type or reset value shows up on
  the CSR tests
- No stubs, blackboxes, or `initial`-loaded storage arrays. The packet buffer is
  built from standard cells — the target library has no memory macros

## Reference baseline

Numbers from the reference RTL on this toolchain, for calibration. They are not
targets — the targets are in `../intent/brainstorm.md` §6.

| | Reference |
|---|---|
| RTL | 15,942 lines (5,297 hand-written + 10,645 generated by `regtool`) |
| Synthesis @ 10 ns | WNS **+1.68 ns** on `clk`, +4998.81 ns on `clk_aon` (5 µs, declared asynchronous to `clk`); 52,643 cells, 407,652 µm² = **144,435** NAND2 |
| Registers | 44, plus the packet-buffer memory window |
| Interrupts | 18 |
| Endpoints | 12 IN + 12 OUT |
| Clock domains | 2 — `clk_i` (USB) and `clk_aon_i`, asynchronous to each other |

Library: TSMC 90 nm `slow.db`, NAND2X1 = 2.8224 µm². Synthesis is
`compile_ultra -no_autoungroup` with input/output delays at 20 % of the period.
The packet buffer synthesises to standard cells — there are no memory macros in
the target library.

SpyGlass on the reference RTL with a hand-written SGDC (two clocks declared, the
USB pins declared off-chip) and none of OpenTitan's own waivers:
`cdc/cdc_verify_struct` reports 13 errors and 5 warnings, among them
`Clock_sync06` ×2, `Convergence` ×2 and `Ar_unsync01` ×2, all naming the
`clk_i` ↔ `clk_aon_i` crossings in `u_reg.u_wake_control_cdc` and
`u_wake_events_cdc`. This is what makes the CDC gate load-bearing here rather than
vacuous. Seven of the errors are `ErrorAnalyzeBBox` on the behavioural
`prim_ram_1p` model and on `prim_subreg_arb`; a submission built from standard
cells does not hit them. The counts are a calibration point, not a target — the
gate is 0 errors and 0 warnings on your own RTL and your own SGDC.

