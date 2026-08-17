// ============================================================================
// fa_core_ref — the harness's REFERENCE DUT (adjudicator-side, withheld).
//
// Purpose: prove the adjudication harness works. A bench that has never bound a
// DUT is unproven in both directions — it might pass everything, or fail
// everything, and neither would be visible. This behavioural model is the known-
// good (and, via +MUT_*, known-bad) device the harness is measured against.
//
// It is NOT an example implementation and never ships to candidates:
//   * behavioural `real` arithmetic, not synthesisable;
//   * fp16 decode/encode written HERE, independently of fa_core_golden_pkg —
//     if the package's fp16_to_real were wrong, a shared helper would cancel the
//     error out and the self-test would pass while both sides were broken.
//
// Why hand-written rather than reused: the upstream FSA project is Chisel with an
// instruction/DMA-driven systolic interface, i.e. nothing to do with this 12-beat
// streaming contract; and using a candidate's RTL as the yardstick would compromise
// the independence the whole gate rests on. A reference DUT must be built to the
// spec, not to one of the things being judged.
//
// Conforms to the pinned interface (spec §3): 12 input beats Q→K→V, 4 output
// beats O, blocking valid/ready, `causal_en` latched at the first accepted beat,
// `done` one cycle after the last accepted output beat, `busy` falling on that
// same cycle, async active-low reset.
//
// Mutations (all default OFF; each must be caught by exactly one gate — see
// selftest/run_selftest.sh):
//   +MUT_ERR_ONE          add 2e-2 to O[0][0]                → tolerance MaxErr
//   +MUT_ERR_ALL=<v>      add v to all 16 elements           → tolerance MAE
//   +MUT_LAT_PAD=<n>      pad compute by n cycles            → latency gate
//   +MUT_DROP_VALID       drop o_out_valid while stalled     → SC-004
//   +MUT_CHANGE_DATA      change o_out_data while stalled    → SC-004
//   +MUT_EARLY_READY      keep qkv_in_ready high during drain→ SC-003
//   +MUT_NO_CLEAR_BUSY    keep busy high through reset       → SC-005
//   +MUT_DROP_BEAT        lose a beat only after a bubble    → SC-006
//   +MUT_DONE2            hold done for 2 cycles             → done pulse check
// ============================================================================
`timescale 1ns/1ps

module fa_core_ref #(
  parameter int COMPUTE_CYCLES = 20        // modelled compute time (cycles)
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [63:0] qkv_in_data,
  input  logic        qkv_in_valid,
  output logic        qkv_in_ready,
  input  logic        causal_en,
  output logic [63:0] o_out_data,
  output logic        o_out_valid,
  input  logic        o_out_ready,
  output logic        busy,
  output logic        done
);

  localparam int NR = 4;                   // Br = Bc
  localparam int DK = 4;                   // head dim
  localparam int NIN = 3 * NR;             // 12 input beats
  localparam int NOUT = NR;                // 4 output beats

  // ---- mutation switches ---------------------------------------------------
  bit  mut_err_one, mut_drop_valid, mut_change_data, mut_early_ready;
  bit  mut_no_clear_busy, mut_drop_beat, mut_done2;
  real mut_err_all;
  int  mut_lat_pad;

  initial begin
    mut_err_one      = $test$plusargs("MUT_ERR_ONE");
    mut_drop_valid   = $test$plusargs("MUT_DROP_VALID");
    mut_change_data  = $test$plusargs("MUT_CHANGE_DATA");
    mut_early_ready  = $test$plusargs("MUT_EARLY_READY");
    mut_no_clear_busy= $test$plusargs("MUT_NO_CLEAR_BUSY");
    mut_drop_beat    = $test$plusargs("MUT_DROP_BEAT");
    mut_done2        = $test$plusargs("MUT_DONE2");
    mut_err_all      = 0.0;
    mut_lat_pad      = 0;
    void'($value$plusargs("MUT_ERR_ALL=%f", mut_err_all));
    void'($value$plusargs("MUT_LAT_PAD=%d", mut_lat_pad));
  end

  // ---- fp16 (E5M10) helpers — deliberately local, not from the golden pkg ---
  function automatic real ref_fp16_to_real(input logic [15:0] h);
    logic sgn; int ex, ma; real v;
    begin
      sgn = h[15]; ex = int'(h[14:10]); ma = int'(h[9:0]);
      if (ex == 0)       v = $itor(ma) * (2.0 ** (-24.0));
      else if (ex == 31) v = 1.0e30;
      else               v = (1.0 + $itor(ma) * (2.0 ** (-10.0))) * (2.0 ** ($itor(ex) - 15.0));
      ref_fp16_to_real = sgn ? -v : v;
    end
  endfunction

  // round-to-nearest-even of a real to an integer
  function automatic int ref_rne(input real v);
    real fl, frac; int i;
    begin
      fl = $floor(v); i = int'(fl); frac = v - fl;
      if (frac > 0.5)                       i = i + 1;
      else if (frac == 0.5 && (i % 2 != 0)) i = i + 1;
      ref_rne = i;
    end
  endfunction

  function automatic logic [15:0] ref_real_to_fp16(input real x);
    logic sgn; real ax; int e, mant; logic [4:0] ef;
    begin
      sgn = (x < 0.0);
      ax  = sgn ? -x : x;
      if (ax == 0.0) begin
        ref_real_to_fp16 = {sgn, 15'b0};
      end else begin
        e = 0;
        while (ax >= 2.0) begin ax = ax / 2.0; e = e + 1; end
        while (ax <  1.0) begin ax = ax * 2.0; e = e - 1; end
        if (e < -14) begin                              // subnormal
          mant = ref_rne((sgn ? -x : x) * (2.0 ** 24.0));
          ref_real_to_fp16 = (mant >= 1024) ? {sgn, 5'd1, 10'd0} : {sgn, 5'd0, mant[9:0]};
        end else begin
          mant = ref_rne((ax - 1.0) * 1024.0);
          if (mant == 1024) begin mant = 0; e = e + 1; end
          if (e > 15) ref_real_to_fp16 = {sgn, 5'd31, 10'd0};   // guard (spec: cannot happen)
          else begin
            ef = 5'(e + 15);
            ref_real_to_fp16 = {sgn, ef, mant[9:0]};
          end
        end
      end
    end
  endfunction

  // ---- state ---------------------------------------------------------------
  typedef enum logic [2:0] {S_IDLE, S_LOAD, S_COMP, S_DRAIN, S_DONE} state_e;
  state_e      st;
  logic [63:0] beats [0:NIN-1];
  logic [15:0] obits [0:NR*DK-1];
  int          beat_idx, comp_cnt, out_idx, stall_cnt, done_cnt;
  logic        cz_l, saw_bubble;

  // ---- the attention math (ideal, `real`) ----------------------------------
  task automatic compute_tile;
    real q[0:NR-1][0:DK-1], k[0:NR-1][0:DK-1], v[0:NR-1][0:DK-1];
    real s[0:NR-1][0:NR-1], p[0:NR-1][0:NR-1];
    real acc, m, l, o;
    int  i, j, c;
    begin
      for (i = 0; i < NR; i++) for (c = 0; c < DK; c++) begin
        q[i][c] = ref_fp16_to_real(beats[i][16*c +: 16]);
        k[i][c] = ref_fp16_to_real(beats[NR + i][16*c +: 16]);
        v[i][c] = ref_fp16_to_real(beats[2*NR + i][16*c +: 16]);
      end

      for (i = 0; i < NR; i++) begin
        for (j = 0; j < NR; j++) begin                  // S = (Q·Kᵀ)/√d, d=4 → 0.5
          acc = 0.0;
          for (c = 0; c < DK; c++) acc = acc + q[i][c] * k[j][c];
          s[i][j] = acc * 0.5;
        end

        m = -1.0e300;                                   // row max over unmasked lanes
        for (j = 0; j < NR; j++)
          if (!(cz_l && j > i) && s[i][j] > m) m = s[i][j];

        l = 0.0;
        for (j = 0; j < NR; j++) begin
          p[i][j] = (cz_l && j > i) ? 0.0 : $exp(s[i][j] - m);
          l = l + p[i][j];
        end

        for (c = 0; c < DK; c++) begin
          acc = 0.0;
          for (j = 0; j < NR; j++) acc = acc + p[i][j] * v[j][c];
          o = acc / l;
          if (mut_err_all != 0.0) o = o + mut_err_all;
          if (mut_err_one && i == 0 && c == 0) o = o + 2.0e-2;
          obits[i*DK + c] = ref_real_to_fp16(o);
        end
      end
    end
  endtask

  function automatic logic [63:0] pack_o_row(input int r);
    logic [63:0] w; int c;
    begin
      w = '0;
      for (c = 0; c < DK; c++) w[16*c +: 16] = obits[r*DK + c];
      pack_o_row = w;
    end
  endfunction

  // ---- sequencer -----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st           <= S_IDLE;
      qkv_in_ready <= 1'b1;                 // ready in idle so beat 0 can land
      o_out_valid  <= 1'b0;
      o_out_data   <= '0;
      busy         <= mut_no_clear_busy;    // MUT: reset does not clear busy
      done         <= 1'b0;
      beat_idx     <= 0;
      comp_cnt     <= 0;
      out_idx      <= 0;
      stall_cnt    <= 0;
      done_cnt     <= 0;
      cz_l         <= 1'b0;
      saw_bubble   <= 1'b0;
    end else begin
      done <= 1'b0;

      case (st)
        S_IDLE: begin
          qkv_in_ready <= 1'b1;
          if (qkv_in_valid && qkv_in_ready) begin       // first beat accepted
            beats[0] <= qkv_in_data;
            cz_l     <= causal_en;                      // latched here (spec §2.3)
            busy     <= 1'b1;
            beat_idx <= 1;
            st       <= S_LOAD;
          end
        end

        S_LOAD: begin
          if (!qkv_in_valid) saw_bubble <= 1'b1;         // bubble seen (SC-006)
          if (qkv_in_valid && qkv_in_ready) begin
            // MUT_DROP_BEAT: after a bubble, accept the beat but do not store it
            if (!(mut_drop_beat && saw_bubble)) beats[beat_idx] <= qkv_in_data;
            saw_bubble <= 1'b0;
            if (beat_idx == NIN-1) begin
              qkv_in_ready <= 1'b0;                     // low until done (spec §3)
              comp_cnt     <= 0;
              st           <= S_COMP;
            end else begin
              beat_idx <= beat_idx + 1;
            end
          end
        end

        S_COMP: begin
          if (comp_cnt == 0) compute_tile();            // beats[] complete here
          if (comp_cnt >= COMPUTE_CYCLES + mut_lat_pad) begin
            o_out_data  <= pack_o_row(0);
            o_out_valid <= 1'b1;
            out_idx     <= 0;
            stall_cnt   <= 0;
            st          <= S_DRAIN;
          end else begin
            comp_cnt <= comp_cnt + 1;
          end
        end

        S_DRAIN: begin
          if (mut_early_ready) qkv_in_ready <= 1'b1;    // MUT: breaks serialization
          if (o_out_valid && o_out_ready) begin
            stall_cnt <= 0;
            if (out_idx == NOUT-1) begin
              o_out_valid  <= 1'b0;
              busy         <= 1'b0;                     // falls with the done pulse
              done         <= 1'b1;                     // one cycle after last accept
              done_cnt     <= 1;
              st           <= S_DONE;
              // NB: ready stays LOW through the done cycle and is raised on the
              // way to IDLE. Raising it here would advertise "a beat presented
              // now is consumed now" while S_DONE consumes nothing — ready high
              // without an accept desynchronises any conforming producer.
            end else begin
              out_idx    <= out_idx + 1;
              o_out_data <= pack_o_row(out_idx + 1);
            end
          end else begin                                // back-pressured
            stall_cnt <= stall_cnt + 1;
            if (mut_drop_valid  && stall_cnt == 1) o_out_valid <= 1'b0;
            if (mut_change_data && stall_cnt == 1) o_out_data  <= o_out_data ^ 64'h1;
          end
        end

        S_DONE: begin
          if (mut_done2 && done_cnt == 1) begin         // MUT: 2-cycle done pulse
            done     <= 1'b1;
            done_cnt <= 2;
          end else begin
            beat_idx     <= 0;
            qkv_in_ready <= 1'b1;                       // accepting again from IDLE
            st           <= S_IDLE;
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
