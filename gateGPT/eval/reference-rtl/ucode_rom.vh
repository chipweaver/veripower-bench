// Auto-generated microcode ROM (combinational). Do not edit by hand.
function [71:0] ucode_rom;
    input [7:0] pc;
    case (pc)
        8'd0: ucode_rom = 72'h000000000000000001;
        8'd1: ucode_rom = 72'h000c00000000000002;
        8'd2: ucode_rom = 72'h048000003002cc1813;
        8'd3: ucode_rom = 72'h054000003002cc1823;
        8'd4: ucode_rom = 72'h001800003002cc1803;
        8'd5: ucode_rom = 72'h000000000000000004;
        8'd6: ucode_rom = 72'h003000009002cc1833;
        8'd7: ucode_rom = 72'h003c060000000c0005;
        8'd8: ucode_rom = 72'h00480000f008000002;
        8'd9: ucode_rom = 72'h000000012002f01843;
        8'd10: ucode_rom = 72'h000000000000300006;
        8'd11: ucode_rom = 72'h003000000002cc6053;
        8'd12: ucode_rom = 72'h00480600f0000c0005;
        8'd13: ucode_rom = 72'h000000012010000002;
        8'd14: ucode_rom = 72'h000c00000002cd9863;
        8'd15: ucode_rom = 72'h000000000000000007;
        8'd16: ucode_rom = 72'h000000000000000008;
        default: ucode_rom = 72'h000000000000000008;  // OP_HALT (safe stop)
    endcase
endfunction
