// A DUT that answers nothing: correct ports, no behaviour. Used to prove the
// harness times out and reports FAIL instead of hanging silently or passing.
`timescale 1ns/1ps
module fa_core_stub (
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
  assign qkv_in_ready = 1'b1;   // swallows beats, never produces output
  assign o_out_data   = '0;
  assign o_out_valid  = 1'b0;
  assign busy         = 1'b0;
  assign done         = 1'b0;
endmodule
