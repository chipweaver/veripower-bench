// Deliberately un-compilable: proves a compile failure reaches the runner's exit
// code instead of being mistaken for a pass.
module fa_core_broken (input logic clk);
  this is not systemverilog
endmodule
