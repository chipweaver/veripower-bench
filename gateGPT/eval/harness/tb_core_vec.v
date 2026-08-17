// Expanded black-box acceptance: read many (mode, seed, inv_temp -> token seq)
// golden cases from a vector file (gen_vectors.py) and check the core reproduces
// each bit-exact via the incremental generation loop. Pass the file with
//   +VEC=<abs path to golden_vectors.txt>
// Cases run back-to-back with no reset between them: each restarts pos_in=0 and
// overwrites its KV slots before attending, so prior-case KV never contaminates.
`timescale 1ns/1ps
module tb_core_vec;
    reg clk = 0, resetn = 0, start = 0;
    always #5 clk = ~clk;

    reg [4:0]   token_in, pos_in;
    reg         smode;
    reg signed [15:0] inv_temp;
    reg [31:0]  rng_in;
    wire        busy, done;
    wire [4:0]  next_token;
    wire [31:0] rng_out;

    microgpt_core u_core (.clk(clk), .resetn(resetn), .start(start),
        .token_in(token_in), .pos_in(pos_in),
        .sample_mode(smode), .inv_temp(inv_temp), .rng_in(rng_in),
        .busy(busy), .done(done), .next_token(next_token), .rng_out(rng_out));

    integer fd, r, k, step;
    integer mode, seed, itemp, ntok;
    reg [4:0] expt [0:15];
    reg [4:0] got  [0:15];
    integer   glen, ncase, npass, nfail, mism;
    reg [1023:0] vecfile;

    task run_gen(input mode_i, input [31:0] seed_i, input signed [15:0] itemp_i);
        begin
            token_in = 0; pos_in = 0; rng_in = seed_i; smode = mode_i; inv_temp = itemp_i; glen = 0;
            for (step = 0; step < 16; step = step + 1) begin
                @(negedge clk); start = 1; @(negedge clk); start = 0;
                wait (done); @(posedge clk); #1;
                if (next_token == 0) step = 100;
                else begin
                    got[glen] = next_token; glen = glen + 1;
                    token_in = next_token; pos_in = pos_in + 1; rng_in = rng_out;
                end
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", vecfile)) vecfile = "golden_vectors.txt";
        fd = $fopen(vecfile, "r");
        if (fd == 0) begin $display("VEC OPEN FAIL: %0s", vecfile); $finish; end
        ncase = 0; npass = 0; nfail = 0;
        repeat (6) @(posedge clk); resetn = 1; @(posedge clk);

        while ($fscanf(fd, "%d %d %d %d", mode, seed, itemp, ntok) == 4) begin
            for (k = 0; k < ntok; k = k + 1) r = $fscanf(fd, "%d", expt[k]);
            run_gen(mode != 0, seed, itemp[15:0]);
            mism = (glen != ntok);
            for (k = 0; k < ntok && !mism; k = k + 1) if (got[k] !== expt[k]) mism = 1;
            if (mism) begin
                nfail = nfail + 1;
                $write("FAIL case %0d (mode=%0d seed=%0d itemp=%0d): got", ncase, mode, seed, itemp);
                for (k = 0; k < glen; k = k + 1) $write(" %0d", got[k]);
                $write(" | exp");
                for (k = 0; k < ntok; k = k + 1) $write(" %0d", expt[k]);
                $write("\n");
            end else npass = npass + 1;
            ncase = ncase + 1;
        end
        $fclose(fd);
        $display("VEC DONE: %0d cases, %0d pass, %0d fail", ncase, npass, nfail);
        if (nfail == 0) $display("VEC PASS"); else $display("VEC FAIL");
        $finish;
    end
endmodule
