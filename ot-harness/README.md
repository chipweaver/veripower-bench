# ot-harness — shared OpenTitan DV harness

The evaluation harness for the OpenTitan-derived tasks ([i2c](../i2c/),
[usbdev](../usbdev/)). It builds each IP's **upstream UVM verification
environment** and runs it against a submitted RTL implementation.

Unlike the other tasks in this suite, the oracle here is not written for the
benchmark: it is lowRISC's own signoff environment, and it is shared across every
IP in the family. Adding a task means adding a `intent/` and an `eval/` — the
oracle comes for free.

## What you provide

An `OT_ROOT` and a filelist:

```bash
git clone https://github.com/lowRISC/opentitan.git && cd opentitan
git checkout 11478abe1016bffb8a692a6608b29c43a8618371
patch -p1 < <bench>/ot-harness/patches/ot-harness.patch

export OT_ROOT=$PWD OT_WORK=/tmp/ot-work OT_PY=<python-with-regtool-deps>
cd <bench>/ot-harness
./build.sh --ip i2c --rtl /path/to/your.f      # -> $OT_WORK/i2c/simv
./run.sh   --ip i2c --simv $OT_WORK/i2c/simv --list ../i2c/eval/scoreable.txt
```

`--rtl` takes a filelist naming your RTL (nested with `-f`, so its own `+incdir+`
lines survive). It must provide module `<ip>_rtl` with the port list in that
task's `intent/brainstorm.md` §3 — and nothing more.

### What a submission owns

`<ip>` itself, `<ip>_reg_pkg`, and the register file. In a comportable flow the
last two are generated from a register description the designer authors, so the
description is the deliverable and the RTL is downstream of it — the tasks say so,
and `build.sh` drops the reference's `<ip>_reg_pkg` from the compilation unit
whenever a DUT is supplied (it arrives twice, via the package closure and via the
IP's own CAPI2 fileset, so both paths are filtered).

`<ip>_pkg` stays on the harness side: it is hand-written, not register-derived,
and the DV env imports it.

### What a submission is and is not handed

The DV env is built for a comportable IP, so its own CAPI2 dependency closure
(`lowrisc:prim:all`, `lowrisc:ip:tlul`) puts **159 prim/tlul implementation files**
into the same compilation unit — `prim_subreg`, `prim_intr_hw`, `prim_fifo_sync`,
`tlul_adapter_reg`, the SECDED encoders and decoders, and the rest — along with
the IP's own `<ip>_pkg` and `<ip>_reg_pkg`. A submission can use all of it, and
there is no way to hide any of it while still building the testbench: with those
files dropped, the reference build itself fails on `prim_buf` and `prim_flop`.
That is 4,052 lines for i2c and 7,089 for usbdev that a submission does not have
to write, and both `intent/brainstorm.md` §3 say so.

What a submission must **not** reach is the IP's own `rtl/` directory. `-y` on it
would hand over `i2c_core`, `i2c_controller_fsm`, `i2c_target_fsm` — the design
itself — to anything that instantiates those names, and VCS would resolve them
silently. `build.sh` therefore puts that one library path on the command line only
for the reference build, which is the build that legitimately needs its own
submodules. Verified by probe: a module instantiating `i2c_core` builds with the
path and fails to elaborate without it.

Each mode writes its own product, so a failed submission build cannot leave a
previously-good reference build unusable.

`--stub` replaces the DUT with a generated port-compatible do-nothing module —
the negative control, which must fail every test in `scoreable.txt`. `--renamed`
builds the reference top with its register-file instance renamed and nothing else
changed — the substitution filter, which must pass exactly what the reference
passes. Each mode writes its own product: `simv.ref`, `simv`, `simv.stub`,
`simv.renamed`.

`OT_PY` needs regtool's dependencies: `hjson mako semantic_version tabulate
mistletoe systemrdl-compiler peakrdl_systemrdl pycryptodome pyyaml`.

## What is in here

| File | Purpose |
|---|---|
| `patches/ot-harness.patch` | 11 files, 215 lines. See "The patch" below. |
| `flist.py` | Resolves one CAPI2 core's fileset closure. Replaces fusesoc. |
| `pkgclosure.py` | Transitive SV package closure for an IP, topologically ordered. |
| `testlist.py` | Expands `<ip>_sim_cfg.hjson` + imported cfgs + `run_modes` into `name/seq/run_opts`. Replaces dvsim. |
| `otports.py` | Parses an IP top's module header (imports + ports). |
| `mkstub.py` | Generates the negative control: `<ip>` with the reference port list, implementing nothing. |
| `mkrenamed.py` | Generates the substitution-filter DUT: the reference top with its register-file instance renamed, nothing else changed. |
| `mkbind.py` | Generates the submission-safe subset of the IP's DV binds — see "Assertions" below. |
| `scoreable.py` | Derives `eval/scoreable.txt` from the reference / renamed / stub sweeps. |
| `build.sh` / `run.sh` | The two entry points. |

No fusesoc, dvsim, bazel or verilator. `regtool.py` is used, from `OT_ROOT`, for
the RAL model only.

## The patch

Eleven files. Six work around gaps in the simulator this suite is calibrated for
(VCS L-2016.06); two are upstream defects; two adapt the harness to the task; two
move i2c's one avoidable backdoor CSR read to the frontdoor. (`i2c_base_vseq.sv`
appears in two of those groups.)

**Simulator gaps** — constructs a 2016 front end rejects:

| File | Construct |
|---|---|
| `dv_base_reg/dv_base_shadowed_field_cov.sv` | default argument on a covergroup `sample()` |
| `cip_lib/seq_lib/cip_base_vseq__tl_errors.svh` | `define` formal list spanning lines without `\` |
| `cip_lib/cip_base_env_cfg.sv` | `string arr[] = {}` initializer |
| `i2c/dv/env/seq_lib/i2c_base_vseq.sv` | `array.sum()` in a constraint |
| `usbdev/dv/env/seq_lib/usbdev_spray_packets_vseq.sv` | hierarchical struct-array member bound to a `ref` port |
| `prim/rtl/prim_util_pkg.sv` | `$clog2(non-constant)` — rejected by Design Compiler, not by VCS |

**Upstream defects:**

- `csr_utils/csr_aliasing_seq.sv` — the chunk-size comparison is inverted, so a
  register queue *smaller* than `m_reads_per_chunk` gets sliced past its end. Line
  52's own doc comment states the intended behaviour. Simulators that bounds-check
  queue slices abort; newer VCS clamps, which is why it has gone unnoticed.
- `dv/sv/i2c_agent/i2c_driver.sv` — on an on-the-fly reset the sequence item is
  dropped without `item_done()`, so the next `get_next_item()` errors. The driver
  is finished with the item either way; the call is now unconditional.

**Harness adaptations:**

- `csr_utils/csr_utils_pkg.sv` — `csr_peek` compares `uvm_hdl_read`'s return
  against 1 instead of testing it for truth. **VCS L-2016.06 returns 51, not 0,
  when the HDL path does not exist** (measured: real path → 1, missing path → 51).
  Every truthiness test therefore accepts it, the read yields 0, and a checker
  reports it as a functional mismatch. On a substituted DUT — whose register file
  has different internal names — that turns into a silent wrong verdict. With this
  one line it becomes a fatal that names the register it could not read.
- `usbdev/dv/env/usbdev_scoreboard.sv` — the loosely-timed register checker is
  gated behind `OT_NO_TIMED_REG_CHK` (which `build.sh` defines for usbdev). It is
  the only RAL-backdoor user in usbdev's DV, it polls fifteen registers through
  hdl paths naming the reference `reg_top`'s internals, and it does so
  unconditionally on every check cycle. It is forked as a sibling of the protocol
  checkers, so gating it leaves the comparison against `usbdev_bfm` untouched.
  What it costs and how much it was worth — both measured with injected bugs —
  are under "Evidence for the usbdev gate" below.

**i2c backdoor CSR reads → frontdoor** (2 files, 2 sites). A backdoor read reaches
through an hdl path naming the reference register file, so it is what makes a test
depend on the reference's internal structure. Only `INTR_STATE` can be moved to
the frontdoor; the rule, arrived at by measurement, is:

> a backdoor read is avoidable only if the register has no frontdoor read side
> effect **and** its value is not timing-sensitive at bus-read granularity.

Two narrower rules were tried and both are wrong, each disproved by the reference
RTL's own results:

| Attempted rule | What broke on the reference |
|---|---|
| convert everything | `i2c_target_nack_acqfull`, `i2c_target_nack_txstretch` — `TARGET_NACK_COUNT` is `rc`, so a frontdoor read destroys what it measures |
| convert every `ro` / `rw1c` register | 45 PASS → 42. FIFO levels are `ro` yet move during the cycles a bus read takes; a `csr_spinwait` perturbs the stretch it is waiting on |

Which i2c tests this leaves outside the graded set, and the register each one
reads, is in [`../i2c/README.md`](../i2c/README.md).

## Evidence for the usbdev gate

Renaming one instance in functionally identical RTL
moved **86 of 98** tests from PASS to FAIL:

| usbdev | reference | renamed |
|---|---:|---:|
| without the gate | 97 PASS | 11 PASS |
| with the gate | 98 PASS | 98 PASS |

The 11 survivors were exactly the tests that run with `+en_scb=0`. Every
scoreboard-enabled test failed at `timed_reg.sv:151` with the same message,
because `usbdev_timed_regs` polls fifteen registers through RAL backdoor paths
that name the reference `reg_top`'s internals, unconditionally, on every check
cycle.

Note what this was *not*: `usbdev`'s `tb.sv` instantiates the DUT purely at port
level and contains **zero** hierarchical references into it — by that measure it
is the cleanest IP in the tree. The proxy predicted the opposite of the truth.

### What gating it costs, measured

Two functional bugs were injected into the reference and run with the checker off:

| Injection | Result |
|---|---|
| `usb_fs_nb_out_pe.sv`: `assign bad_data_toggle = 1'b0;` (device stops detecting a mismatched DATA0/DATA1 toggle) | `usbdev_invalid_data1_data0_toggle_test` **FAIL**, `usbdev_data_toggle_restore` **FAIL**, `usbdev_data_toggle_clear` / `usbdev_out_trans_nak` / `usbdev_smoke` PASS — caught, and caught specifically |
| `usbdev.sv`: `in_sent` never recorded for any endpoint — deliberately one of the fifteen registers the checker watches | FAIL with the checker **on and off**, same signature both ways (`usbdev_pkt_sent_vseq.sv:53`): the sequence's own frontdoor check catches it |

A first attempt scoped the second injection to endpoint 1 alone and was caught by
neither configuration — the suite does not drive IN transactions on that endpoint.
That is a coverage gap in the suite, unrelated to the gate, and it is why the
injection was widened: an uncaught injection proves nothing until you have shown
it is reachable.

## Assertions

`build.sh` generates two things from the IP's register description: the RAL model
the DV env drives the bus through, and `<ip>_csr_assert_fpv` — the CSR assertion
module. It then generates `<ip>_bind_portlevel` and elaborates it as an extra
`-top`, because a SystemVerilog `bind` only takes effect if the module containing
it is elaborated.

Upstream's `<ip>_bind` cannot be used as-is. It mixes three kinds of bind and only
one of them can attach to a submission:

| Bind | Attaches to | Submission-safe |
|---|---|---|
| `tlul_assert` (`EndpointType("Device")`) | the IP top's `clk_i`/`rst_ni`/`tl_i`/`tl_o` | yes |
| `<ip>_csr_assert_fpv` | the same four ports | yes |
| `i2c_protocol_cov` | `$root.tb.dut.i2c_core.reg2hw...` | no — names the reference's internals |
| `sec_cm_*_bind` | OpenTitan's countermeasure primitives | no — VCS refuses a bind whose target is not elaborated, and using those primitives is a micro-architecture choice the task leaves free |

`mkbind.py` emits the first two, and they are used for the reference build as well
as for submissions, so the graded set is derived and applied under identical
assertions.

Under `EndpointType("Device")` the request-channel properties are assumptions on
the testbench; nine are assertions on the design — five on the response channel
and four requiring an eventual `d_error` for an illegal request. Verified live: a
submission that raises `d_valid` with no outstanding request trips
`respMustHaveReq_A`.

One consequence for the graded set: `<ip>_sec_cm` injects faults into the
countermeasure primitives it finds through the sec_cm binds. With those binds out,
it has nothing to inject, so it cannot grade a submission.

## Build flags

Every flag in `build.sh` is load-bearing; the non-obvious ones:

| Flag | Why |
|---|---|
| `-ntb_opts uvm-1.2` | the DV code is UVM-1.2; VCS ships it |
| `-debug_access+f` | without it any `uvm_hdl_*` access aborts the run |
| `-CFLAGS --std=c99` | usbdev's `usbdpi` DPI-C uses C99 loop declarations |
| `+define+INC_ASSERT` | `prim_util_pkg`'s `end_of_simulation` is behind it, and `dv_test_status_pkg` writes it |
| `+define+DUT_HIER=tb.dut` | the RAL's hdl-path root |
| `-top <ip>_bind_portlevel` | a `bind` is inert unless its module is elaborated |
| `+define+UVM_REG_*_WIDTH` | TL-UL geometry the RAL is generated for |

## Adding another IP

1. Confirm the IP is reachable: `pkgclosure.py <ip>` resolves, and
   `build.sh --ip <ip>` compiles.
2. Baseline it: `build.sh --ip <ip>` then `run.sh --simv $OT_WORK/<ip>/simv.ref`,
   N seeds.
3. **Run the substitution filter**: `build.sh --ip <ip> --renamed`, then `run.sh`
   against `simv.renamed`. Any test whose verdict changes depends on the
   reference's internal structure and cannot be a gate. This is cheap and
   decisive, and no cheaper proxy predicts it — usbdev's `tb.sv` has zero
   hierarchical references into the DUT and was still the worst IP measured.
4. Negative control: `build.sh --stub` must fail every surviving test.
5. `scoreable.py --ref … --renamed … --stub … --out <ip>/eval/scoreable.txt`
   applies the three criteria and prints what it excluded and why.
