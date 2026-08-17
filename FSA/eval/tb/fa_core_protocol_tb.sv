// ============================================================================
// fa_core — protocol / scenario testbench (SC-003/4/5/6 robustness gate).
//
// Complements the tolerance/latency gate (fa_core_golden_tb.sv) by exercising
// the handshake & control contract (handoff/brainstorm.md §3 interface + §6 timing
// scenarios), which is variant-neutral. Every scenario replays a
// held-out golden tile under an adverse handshake and asserts BOTH the protocol
// property AND that the output still matches the golden within tolerance.
//
// Scenarios (from the specs' Timing tables):
//   SC-006 input backpressure   — bubbles (qkv_in_valid low) between input beats;
//                                 no beat lost/duplicated; O still within tol.
//   SC-004 output backpressure  — o_out_ready held low during drain; o_out_valid
//                                 and o_out_data stay stable (data held, not
//                                 dropped/overwritten); all 4 beats correct.
//   SC-003 back-to-back         — tile B requested after tile A's 12 beats are in;
//                                 qkv_in_ready stays 0 until A completes (B waits,
//                                 no corruption); both A and B correct.
//   SC-005 reset mid-op         — async rst_n asserted mid-compute; busy clears,
//                                 no partial o_out; clean tile after release passes.
// Also: `done` is a single-cycle pulse at tile completion (spec §3).
//
// NOTE on busy/done phasing: the exact cycle `busy` falls relative to `done`
// differs between variants (fa_core: same cycle as done; fa_core_fsa: cycle
// after). These checks deliberately do NOT gate that phase — only shared invariants.
//
// Inputs:  +VECTORS=<path>       token stream from reference.py (needs ≥1 tile;
//                                 uses tiles 0 and 1 for back-to-back, else reuses 0).
//          +define+DUT_TOP=<nm>  (compile) DUT module name (default fa_core).
// Output:  a single "PROTOCOL: PASS|FAIL ..." marker + nonzero exit ($fatal) on FAIL.
//
// STATUS: compiled and run under VCS L-2016.06 against ref/fa_core_ref.sv
// (PROTOCOL: PASS). All five checks are proven to bite via injected defects —
// see selftest/run_selftest.sh (16/16). Two bench bugs were found doing so: the
// done-monitor enable raced with its own sampling, and the monitor stopped at
// busy-fall so an over-long done pulse went unnoticed. Both fixed here.
// ============================================================================
`timescale 1ns/1ps

`ifndef DUT_TOP
  `define DUT_TOP fa_core
`endif

module fa_core_protocol_tb;
  import fa_core_golden_pkg::*;

  localparam int MAXV = 128;

  // ---- fixed interface -----------------------------------------------------
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
    .clk (clk), .rst_n (rst_n),
    .qkv_in_data (qkv_in_data), .qkv_in_valid (qkv_in_valid), .qkv_in_ready (qkv_in_ready),
    .causal_en (causal_en),
    .o_out_data (o_out_data), .o_out_valid (o_out_valid), .o_out_ready (o_out_ready),
    .busy (busy), .done (done)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    #2_000_000;
    $display("PROTOCOL: FAIL timeout");
    $fatal(1, "protocol timeout");
  end

  // ---- vector storage ------------------------------------------------------
  logic [63:0] beats_all [0:MAXV-1][0:N_IN_BEATS-1];
  logic        cz_all    [0:MAXV-1];
  real         exp_all   [0:MAXV-1][0:N_O_ELEMS-1];
  int          nvec;

  int n_fail;

  // ---- track `done` pulses to verify single-cycle behaviour ----------------
  // The enable is armed/disarmed on the NEGEDGE on purpose: clearing it in the
  // same time step this posedge monitor samples `done` is a race, and it silently
  // loses the pulse (observed: "done pulsed 0 cycles" against a DUT that pulses
  // correctly for exactly one cycle).
  int  done_cycles_this_tile;
  bit  monitor_done;
  always @(posedge clk) if (rst_n && monitor_done && done) done_cycles_this_tile++;

  task automatic arm_done_monitor(input bit on);
    begin
      // Disarming keeps watching for a few more cycles on purpose: `busy` falls
      // on the first done cycle, so a monitor that stops when busy falls only
      // ever sees cycle 1 and a DUT holding `done` for 2+ cycles passes. (Caught
      // by the +MUT_DONE2 negative control, which used to slip through.)
      if (!on) repeat (3) @(posedge clk);
      @(negedge clk);
      if (on) done_cycles_this_tile = 0;
      monitor_done = on;
    end
  endtask

  // ---- reset (async, active-low) -------------------------------------------
  task automatic do_reset;
    begin
      @(negedge clk); rst_n = 1'b0;                 // assert off-edge (async)
      repeat (3) @(posedge clk);
      @(negedge clk); rst_n = 1'b1;
      @(posedge clk);
    end
  endtask

  // ---- send one input beat, optionally after `bubbles` idle cycles ---------
  task automatic send_beat(input logic [63:0] d, input int bubbles);
    int i;
    begin
      for (i = 0; i < bubbles; i++) begin                 // valid low = bubble
        qkv_in_valid <= 1'b0;
        @(posedge clk);
      end
      qkv_in_data  <= d;
      qkv_in_valid <= 1'b1;
      do @(posedge clk); while (!qkv_in_ready);           // accepted this edge
    end
  endtask

  // ---- load a tile's 12 beats (bubbles between them if requested) ----------
  task automatic load_tile(input int v, input int bubbles);
    int b;
    begin
      causal_en <= cz_all[v];
      for (b = 0; b < N_IN_BEATS; b++) send_beat(beats_all[v][b], bubbles);
      qkv_in_valid <= 1'b0;
    end
  endtask

  // ---- drain, continuous ready; capture O ----------------------------------
  task automatic drain_tile(output real got [0:N_O_ELEMS-1]);
    int r, c;
    begin
      o_out_ready <= 1'b1;
      for (r = 0; r < N_OUT_BEATS; r++) begin
        do @(posedge clk); while (!o_out_valid);
        for (c = 0; c < D; c++) got[r*D + c] = fp16_to_real(o_out_data[16*c +: 16]);
      end
      while (busy) @(posedge clk);
    end
  endtask

  // ---- drain under output backpressure (SC-004) ----------------------------
  task automatic drain_backpressured(input int stall, output real got [0:N_O_ELEMS-1],
                                      output bit ok);
    int r, c, s;
    logic [63:0] held;
    begin
      ok = 1'b1;
      o_out_ready <= 1'b0;
      for (r = 0; r < N_OUT_BEATS; r++) begin
        do @(posedge clk); while (!o_out_valid);          // valid up, ready still low
        held = o_out_data;
        for (s = 0; s < stall; s++) begin                 // hold ready low: must not drop
          @(posedge clk);
          if (!o_out_valid) begin
            ok = 1'b0;
            $display("PROTOCOL: SC-004 FAIL o_out_valid dropped under backpressure (beat %0d)", r);
          end
          if (o_out_data !== held) begin
            ok = 1'b0;
            $display("PROTOCOL: SC-004 FAIL o_out_data changed under backpressure (beat %0d)", r);
          end
        end
        o_out_ready <= 1'b1;                              // accept this beat
        @(posedge clk);
        for (c = 0; c < D; c++) got[r*D + c] = fp16_to_real(held[16*c +: 16]);
        o_out_ready <= 1'b0;
      end
      o_out_ready <= 1'b1;
      while (busy) @(posedge clk);
    end
  endtask

  task automatic check_tol(input string tag, input int v, input real got [0:N_O_ELEMS-1]);
    real maxerr, mae;
    begin
      if (!tile_within_tol(got, exp_all[v], maxerr, mae)) begin
        n_fail++;
        $display("PROTOCOL: %s FAIL result off golden  maxerr=%g mae=%g", tag, maxerr, mae);
      end
    end
  endtask

  // ---- scenarios -----------------------------------------------------------
  real gotA [0:N_O_ELEMS-1];
  real gotB [0:N_O_ELEMS-1];

  // SC-006: input bubbles + a clean single-cycle `done` pulse check (spec §3).
  task automatic sc006_input_backpressure(input int v);
    bit ok;
    begin
      do_reset();
      arm_done_monitor(1'b1);
      load_tile(v, 2);                                    // 2-cycle bubble per beat
      drain_tile(gotA);
      arm_done_monitor(1'b0);
      check_tol("SC-006", v, gotA);
      if (done_cycles_this_tile != 1) begin
        n_fail++;
        $display("PROTOCOL: done FAIL pulsed %0d cycles (expected exactly 1)",
                 done_cycles_this_tile);
      end
    end
  endtask

  // SC-004: output backpressure.
  task automatic sc004_output_backpressure(input int v);
    bit ok;
    begin
      do_reset();
      load_tile(v, 0);
      drain_backpressured(3, gotA, ok);
      if (!ok) n_fail++;
      check_tol("SC-004", v, gotA);
    end
  endtask

  // SC-003: back-to-back — B requested while A is in flight; the core must
  // serialize (not accept B until A has fully drained), corrupt neither tile.
  //
  // The exact cycle a conforming DUT latches B[0] at the A→B boundary is not
  // pinned by the spec (busy asserts on B's first accept), so this check is built
  // to be timing-robust: (1) while A is still draining (r < N_OUT_BEATS), assert
  // qkv_in_ready stays 0 — B may NOT jump the queue; (2) once A has drained, load
  // B by WATCHING accepts (advance the beat index on each valid&&ready edge)
  // rather than assuming which cycle B[0] latches.
  task automatic sc003_back_to_back(input int va, input int vb);
    int  r, idx, c;
    bit  ready_leaked;
    begin
      do_reset();
      load_tile(va, 0);                                  // A's 12 beats in
      causal_en    <= cz_all[vb];                        // B knocking at the door
      qkv_in_data  <= beats_all[vb][0];
      qkv_in_valid <= 1'b1;
      o_out_ready  <= 1'b1;

      // (1) serialization: no accept while A has not finished draining.
      ready_leaked = 1'b0; r = 0;
      while (r < N_OUT_BEATS) begin
        @(posedge clk);
        if (qkv_in_ready) ready_leaked = 1'b1;           // B accepted mid-A -> violation
        if (o_out_valid) begin
          for (c = 0; c < D; c++) gotA[r*D + c] = fp16_to_real(o_out_data[16*c +: 16]);
          r++;
        end
      end
      if (ready_leaked) begin
        n_fail++;
        $display("PROTOCOL: SC-003 FAIL qkv_in_ready high before tile A drained (no serialization)");
      end
      check_tol("SC-003(A)", va, gotA);

      // (2) A done → stream B in, advancing the index only on accepted beats.
      idx = 0;
      while (idx < N_IN_BEATS) begin
        @(posedge clk);
        if (qkv_in_ready) begin
          idx++;
          if (idx < N_IN_BEATS) qkv_in_data <= beats_all[vb][idx];
        end
      end
      qkv_in_valid <= 1'b0;
      drain_tile(gotB);
      check_tol("SC-003(B)", vb, gotB);
    end
  endtask

  // SC-005: async reset mid-compute — busy clears, no partial output; restart clean.
  task automatic sc005_reset_mid_op(input int v);
    int  b, k;
    bit  out_leaked, busy_stuck;
    begin
      do_reset();
      load_tile(v, 0);                                    // 12 beats in → compute
      repeat (4) @(posedge clk);                          // a few compute cycles

      @(negedge clk); rst_n = 1'b0;                       // async assert mid-op
      out_leaked = 1'b0; busy_stuck = 1'b0;
      for (k = 0; k < 6; k++) begin
        @(posedge clk);
        if (o_out_valid) out_leaked = 1'b1;               // no partial output allowed
        if (k >= 2 && busy) busy_stuck = 1'b1;            // busy must clear (async)
      end
      @(negedge clk); rst_n = 1'b1;
      @(posedge clk);
      if (out_leaked) begin
        n_fail++;
        $display("PROTOCOL: SC-005 FAIL o_out_valid asserted during reset (partial output)");
      end
      if (busy_stuck) begin
        n_fail++;
        $display("PROTOCOL: SC-005 FAIL busy did not clear under async reset");
      end

      // clean restart: a full tile must now pass.
      load_tile(v, 0);
      drain_tile(gotA);
      check_tol("SC-005(restart)", v, gotA);
    end
  endtask

  // ---- vector load + run ---------------------------------------------------
  string vecfile;
  int    fd, code, t, b, k, vb;
  logic [31:0] ebits;

  initial begin
    n_fail = 0; monitor_done = 1'b0; done_cycles_this_tile = 0;
    qkv_in_data = '0; qkv_in_valid = 1'b0; causal_en = 1'b0; o_out_ready = 1'b1;
    rst_n = 1'b1;

    if (!$value$plusargs("VECTORS=%s", vecfile)) begin
      $display("PROTOCOL: FAIL no +VECTORS=<file>");
      $fatal(1, "no vectors");
    end
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin
      $display("PROTOCOL: FAIL cannot open %s", vecfile);
      $fatal(1, "fopen");
    end
    code = $fscanf(fd, "%d", nvec);
    if (code != 1 || nvec < 1) begin
      $display("PROTOCOL: FAIL bad/empty vector header");
      $fatal(1, "header");
    end
    if (nvec > MAXV) nvec = MAXV;
    for (t = 0; t < nvec; t++) begin
      code = $fscanf(fd, "%d", cz_all[t]);
      for (b = 0; b < N_IN_BEATS; b++) code = $fscanf(fd, "%h", beats_all[t][b]);
      for (k = 0; k < N_O_ELEMS; k++) begin
        code = $fscanf(fd, "%h", ebits);
        exp_all[t][k] = fp32_to_real(ebits);
      end
    end
    $fclose(fd);

    vb = (nvec > 1) ? 1 : 0;                              // second tile for back-to-back

    sc006_input_backpressure(0);
    sc004_output_backpressure(0);
    sc003_back_to_back(0, vb);
    sc005_reset_mid_op(0);

    if (n_fail == 0) begin
      $display("PROTOCOL: PASS (SC-003/004/005/006)");
      $finish;
    end else begin
      $display("PROTOCOL: FAIL (%0d checks failed)", n_fail);
      $fatal(1, "protocol gate");
    end
  end

endmodule
