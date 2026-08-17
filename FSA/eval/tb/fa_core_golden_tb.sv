// ============================================================================
// fa_core — FIXED golden testbench (the functional adjudication gate).
//
// The independent, arm-neutral, variant-neutral adjudication TB. It is NOT any
// implementation's own TB (no self-eval): ONE fixed bench binds ANY DUT that
// conforms to the pinned top interface (handoff/brainstorm.md §3) and scores its
// top-level `o_out` against the held-out golden vectors from reference.py —
// black-box, no internal probes. It serves both fa_core and fa_core_fsa.
//
// Gates:
//   (1) TOLERANCE (both variants, always): for EVERY tile (all held-out seeds ×
//       both causal modes), per-element |err| < 1e-2 AND mean|err| over the 16
//       O elements < 1e-3   (err = decoded fp16 DUT output vs the fp32 reference).
//   (2) LATENCY (opt-in via +MAX_LATENCY=<n>): single_tile_latency = first
//       qkv_in beat accepted → last o_out beat presented (valid), endpoints
//       inclusive, under continuous ready/valid. Measured & reported for EVERY
//       tile. Gated only when +MAX_LATENCY is given:
//         - both variants: pass +MAX_LATENCY=80 (spec hard gate ≤ 80 cyc)
//       (golden_run.sh arms it by default for either variant.)
//   Any tile failing an active gate → FAIL.
//
// Inputs:  +VECTORS=<path>       token stream from `reference.py --format tb`:
//            <N>
//            <causal_en> <12 beats %016x, Q,K,V rows 0-3> <16 expected O %08x fp32 bits>
//            ...
//          +MAX_LATENCY=<n>      (optional) hard latency bound in cycles.
//          +define+DUT_TOP=<nm>  (compile) DUT module name (default fa_core).
// Output:  a single "GOLDEN: PASS|FAIL ..." marker line, plus a nonzero exit
//          ($fatal) on FAIL — so a --golden-cmd wrapper reads exit 0 == pass.
//
// STATUS: compiled and run under VCS L-2016.06 against ref/fa_core_ref.sv
// (GOLDEN: PASS, 10 tiles, worst maxerr 9.56e-4 / mae 1.64e-4, latency 37 cyc).
// fp16 decode is cross-checked by the reference DUT decoding independently, and
// the latency gate is proven to bite at 81 and pass at 80 — see
// selftest/run_selftest.sh (16/16).
// ============================================================================
`timescale 1ns/1ps

// The pinned interface name is `fa_core`; the retained variant's top is
// fa_core_fsa (a full build may suffix a repeat index, e.g. fa_core_fsa_0).
// Override at compile with +define+DUT_TOP=<name>.
`ifndef DUT_TOP
  `define DUT_TOP fa_core
`endif

module fa_core_golden_tb;
  import fa_core_golden_pkg::*;

  // ---- fixed interface (pinned in the spec) --------------------------------
  logic        clk;
  logic        rst_n;
  logic [63:0] qkv_in_data;
  logic        qkv_in_valid;
  logic        qkv_in_ready;
  logic        causal_en;
  logic [63:0] o_out_data;
  logic        o_out_valid;
  logic        o_out_ready;
  logic        busy;
  logic        done;

  `DUT_TOP dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .qkv_in_data  (qkv_in_data),
    .qkv_in_valid (qkv_in_valid),
    .qkv_in_ready (qkv_in_ready),
    .causal_en    (causal_en),
    .o_out_data   (o_out_data),
    .o_out_valid  (o_out_valid),
    .o_out_ready  (o_out_ready),
    .busy         (busy),
    .done         (done)
  );

  // ---- clock (10 ns) -------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---- global watchdog: no response ⇒ FAIL (never a false pass) -------------
  initial begin
    #1_000_000;                       // 100k cycles ≫ any tile budget
    $display("GOLDEN: FAIL timeout");
    $fatal(1, "golden timeout");
  end

  // ---- monotonic cycle counter, advanced ONLY by the stimulus thread -------
  // Every clock edge the single stimulus thread consumes goes through tick(),
  // so `cyc` is an exact, race-free cycle index for latency measurement.
  int cyc;
  task automatic tick;
    begin
      @(posedge clk);
      cyc = cyc + 1;
    end
  endtask

  // ---- drive one input beat under valid/ready (blocking, continuous) -------
  task automatic send_beat(input logic [63:0] d);
    begin
      qkv_in_data  <= d;
      qkv_in_valid <= 1'b1;
      do tick(); while (!qkv_in_ready);                   // accepted this edge
    end
  endtask

  // ---- gate config ---------------------------------------------------------
  int  max_latency;                    // 0 == latency not gated (report-only)
  bit  gate_latency;

  int  n_fail;
  int  n_tiles;

  // ---- run one tile: 12 in beats → 4 out beats → tolerance + latency --------
  task automatic run_tile(input int          t,
                          input logic        cz,
                          input logic [63:0] beats [0:N_IN_BEATS-1],
                          input real         exp_o [0:N_O_ELEMS-1]);
    real got [0:N_O_ELEMS-1];
    real maxerr, mae;
    int  r, c, b, t0, t_last, latency;
    bit  ok_tol, ok_lat;
    begin
      // causal_en is latched at the first accepted beat — present it first.
      causal_en <= cz;
      t0 = 0; t_last = 0;
      for (b = 0; b < N_IN_BEATS; b++) begin
        send_beat(beats[b]);
        if (b == 0) t0 = cyc;                             // first accept instant
      end
      qkv_in_valid <= 1'b0;

      // drain N output rows (continuous ready; no backpressure in the golden).
      o_out_ready <= 1'b1;
      for (r = 0; r < N_OUT_BEATS; r++) begin
        do tick(); while (!o_out_valid);
        for (c = 0; c < D; c++)
          got[r*D + c] = fp16_to_real(o_out_data[16*c +: 16]);
        if (r == N_OUT_BEATS-1) t_last = cyc;             // last-o_out-valid instant
      end

      // let the tile finish (done pulse / busy fall) before the next one.
      while (busy) tick();

      latency = t_last - t0 + 1;                          // endpoints inclusive
      ok_tol  = tile_within_tol(got, exp_o, maxerr, mae);
      ok_lat  = (!gate_latency) || (latency <= max_latency);

      n_tiles++;
      if (!ok_tol) begin
        n_fail++;
        $display("GOLDEN: tile %0d (causal=%0b) FAIL tolerance  maxerr=%g mae=%g  latency=%0d",
                 t, cz, maxerr, mae, latency);
      end else if (!ok_lat) begin
        n_fail++;
        $display("GOLDEN: tile %0d (causal=%0b) FAIL latency=%0d > %0d  (maxerr=%g mae=%g ok)",
                 t, cz, latency, max_latency, maxerr, mae);
      end else begin
        $display("GOLDEN: tile %0d (causal=%0b) ok  maxerr=%g mae=%g  latency=%0d%s",
                 t, cz, maxerr, mae, latency,
                 gate_latency ? $sformatf(" (<=%0d)", max_latency) : " (report-only)");
      end
    end
  endtask

  // ---- vector load + sequencing --------------------------------------------
  string       vecfile;
  int          fd, code, nvec, t, b, k;
  logic [31:0] ebits;
  logic        cz;
  logic [63:0] beats [0:N_IN_BEATS-1];
  real         exp_o [0:N_O_ELEMS-1];

  initial begin
    n_fail = 0; n_tiles = 0; cyc = 0;
    qkv_in_data = '0; qkv_in_valid = 1'b0; causal_en = 1'b0; o_out_ready = 1'b1;

    // latency gate: golden_run.sh arms +MAX_LATENCY=80 by default (spec §7 hard gate).
    gate_latency = $value$plusargs("MAX_LATENCY=%d", max_latency);
    if (!gate_latency) max_latency = 0;

    // async active-low reset for a few cycles (not counted in `cyc`).
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    cyc = 0;

    if (!$value$plusargs("VECTORS=%s", vecfile)) begin
      $display("GOLDEN: FAIL no +VECTORS=<file>");
      $fatal(1, "no vectors");
    end
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin
      $display("GOLDEN: FAIL cannot open %s", vecfile);
      $fatal(1, "fopen");
    end

    code = $fscanf(fd, "%d", nvec);
    if (code != 1) begin
      $display("GOLDEN: FAIL bad vector header");
      $fatal(1, "header");
    end

    for (t = 0; t < nvec; t++) begin
      code = $fscanf(fd, "%d", cz);
      for (b = 0; b < N_IN_BEATS; b++) code = $fscanf(fd, "%h", beats[b]);
      for (k = 0; k < N_O_ELEMS; k++) begin
        code = $fscanf(fd, "%h", ebits);
        exp_o[k] = fp32_to_real(ebits);
      end
      run_tile(t, cz, beats, exp_o);
    end
    $fclose(fd);

    if (n_fail == 0) begin
      $display("GOLDEN: PASS (%0d tiles%s)", n_tiles,
               gate_latency ? $sformatf(", latency<=%0d", max_latency) : "");
      $finish;
    end else begin
      $display("GOLDEN: FAIL (%0d/%0d tiles)", n_fail, n_tiles);
      $fatal(1, "golden gate");
    end
  end

endmodule
