// Auto-generated ROM (combinational case constants). Do not edit by hand.
function signed [15:0] exp_tab_rom;
    input [4:0] idx;
    case (idx)
        5'd0: exp_tab_rom = 16'h0800;
        5'd1: exp_tab_rom = 16'h02f1;
        5'd2: exp_tab_rom = 16'h0115;
        5'd3: exp_tab_rom = 16'h0066;
        5'd4: exp_tab_rom = 16'h0026;
        5'd5: exp_tab_rom = 16'h000e;
        5'd6: exp_tab_rom = 16'h0005;
        5'd7: exp_tab_rom = 16'h0002;
        5'd8: exp_tab_rom = 16'h0001;
        5'd9: exp_tab_rom = 16'h0000;
        5'd10: exp_tab_rom = 16'h0000;
        5'd11: exp_tab_rom = 16'h0000;
        5'd12: exp_tab_rom = 16'h0000;
        5'd13: exp_tab_rom = 16'h0000;
        5'd14: exp_tab_rom = 16'h0000;
        5'd15: exp_tab_rom = 16'h0000;
        5'd16: exp_tab_rom = 16'h0000;
        default: exp_tab_rom = 16'd0;
    endcase
endfunction
