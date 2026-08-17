// Embedding lookup: emb[i] = sat16( tok_embed[token][i] + pos_embed[pos][i] ),
// i = 0..N_EMBED-1, written to vmem[dst_base+i]. Token/pos embedding ROMs (Q5.11).
module embed #(
    parameter integer N_EMBED = 24
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire [4:0]  token,
    input  wire [3:0]  pos,
    input  wire [9:0]  dst_base,
    output reg         v_we,
    output reg  [9:0]  v_waddr,
    output reg  signed [15:0] v_wdata,
    output reg         busy,
    output reg         done
);
    // Embedding ROMs as combinational case functions (NOT $readmemh: XST 14.7 zeroes
    // small $readmemh distributed ROMs). tok = 27x24, pos = 16x24, row-major.
`include "tok_emb.vh"
`include "pos_emb.vh"

    reg [6:0]  i;
    reg [9:0]  tbase, pbase;
    reg        st;

    wire signed [16:0] sum = $signed(tok_emb(tbase + {3'd0, i})) + $signed(pos_emb(pbase + {3'd0, i}));
    wire signed [15:0] esat =
        (sum >  17'sd32767) ? 16'sd32767 : (sum < -17'sd32768) ? -16'sd32768 : sum[15:0];

    always @(posedge clk) begin
        if (!resetn) begin st <= 0; busy <= 0; done <= 0; v_we <= 0; end
        else begin
            done <= 0; v_we <= 0;
            if (!st) begin
                if (start) begin
                    busy <= 1; i <= 0;
                    tbase <= token * N_EMBED;   // <= 26*24 = 624
                    pbase <= pos * N_EMBED;      // <= 15*24 = 360
                    st <= 1;
                end
            end else begin
                v_we <= 1; v_waddr <= dst_base + i; v_wdata <= esat;
                if (i == N_EMBED - 1) begin busy <= 0; done <= 1; st <= 0; end
                else i <= i + 1;
            end
        end
    end
endmodule
