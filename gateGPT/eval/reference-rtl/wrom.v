// Wide weight ROMs for the 24-lane, 2-columns/cycle parallel matvec engine. Each word
// holds LANES=24 Q5.11 weights for TWO consecutive input columns (low half = col 2j, high
// half = col 2j+1), addressed by tile*(in_dim/2) + j; wdata[lane*16 +:16] is the lane's
// weight for col 2j and wdata[LANES*16 + lane*16 +:16] for col 2j+1.
// The contents come from a combinational case function (core/wrom_data.vh), NOT $readmemh:
// XST 14.7 ties small $readmemh distributed ROMs to zero (it zeroed the weights on the
// board -> garbage names). Explicit case constants synthesize into LUTs reliably.
module wrom #(
    parameter integer LANES = 24
) (
    input  wire [2:0]            sel,    // WQ WK WV WO FC1 FC2 LM
    input  wire [11:0]           addr,   // tile-word address: tile*(in_dim/2) + j
    output wire [2*LANES*16-1:0] wdata
);
`include "wrom_data.vh"
    assign wdata = wrom_data(sel, addr);
endmodule
