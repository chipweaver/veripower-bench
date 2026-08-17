// Verifier-written L2 TB: protocol (busy/done handshake, start-while-busy ignored,
// resetn -> idle), per-position latency, and KV-survives-resetn (§4) black-box check.
`timescale 1ns/1ps
module tb_l2;
    reg clk = 0, resetn = 0, start = 0;
    always #5 clk = ~clk;

    reg [4:0]   token_in = 0, pos_in = 0;
    reg         smode = 0;
    reg signed [15:0] inv_temp = 0;
    reg [31:0]  rng_in = 0;
    wire        busy, done;
    wire [4:0]  next_token;
    wire [31:0] rng_out;

    integer errors = 0;

    microgpt_core u_core (.clk(clk), .resetn(resetn), .start(start),
        .token_in(token_in), .pos_in(pos_in),
        .sample_mode(smode), .inv_temp(inv_temp), .rng_in(rng_in),
        .busy(busy), .done(done), .next_token(next_token), .rng_out(rng_out));

    // ---- global done-pulse counter + latency counter -----------------------
    integer donecnt = 0, cyc = 0; reg counting = 0; integer lastlat = 0;
    always @(posedge clk) begin
        if (done) donecnt = donecnt + 1;
        if (start && !counting && !busy) begin counting <= 1; cyc <= 0; end
        else if (counting) cyc <= cyc + 1;
        if (done && counting) begin lastlat = cyc; counting <= 0; end
    end

    // one step, single-cycle start, wait for done
    task step1(input [4:0] tk, input [4:0] ps);
        begin
            token_in = tk; pos_in = ps;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            wait (done); @(posedge clk); #1;
        end
    endtask

    integer p, d0, w;
    reg [4:0] seq [0:15]; integer slen, k, stp;
    reg [4:0] exp_greedy [0:4];

    initial begin
        exp_greedy[0]=1; exp_greedy[1]=12; exp_greedy[2]=1; exp_greedy[3]=25; exp_greedy[4]=1;
        repeat (6) @(posedge clk); resetn = 1; @(posedge clk);

        // ---- (a) latency vs position (data-independent) --------------------
        for (p = 0; p <= 15; p = p + 1) begin
            step1(5'd1, p[4:0]);
            if (p==0 || p==7 || p==15) $display("pos=%0d  cycles=%0d", p, lastlat);
        end

        // ---- (b) start held high across a whole step: exactly one done -----
        @(posedge clk); resetn = 0; repeat (4) @(posedge clk); resetn = 1; @(posedge clk);
        d0 = donecnt;
        token_in = 5'd1; pos_in = 5'd0;
        @(negedge clk); start = 1;                 // hold start high the whole time
        wait (done); @(posedge clk);
        repeat (200) @(posedge clk);               // keep hammering start after done
        start = 0;
        w = donecnt - d0;
        if (w == 1) $display("L2 OK: start held high -> exactly 1 done pulse");
        else begin $display("L2 FAIL: %0d done pulses while start held high", w); errors=errors+1; end

        // ---- (c) resetn during RUN returns core to idle --------------------
        wait (!busy); @(posedge clk);
        token_in = 5'd1; pos_in = 5'd0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        repeat (100) @(posedge clk);
        if (!busy) begin $display("L2 FAIL: core not busy mid-step"); errors=errors+1; end
        d0 = donecnt;
        resetn = 0; repeat (3) @(posedge clk); #1;
        if (busy !== 1'b0 || done !== 1'b0) begin
            $display("L2 FAIL: busy=%b done=%b under resetn", busy, done); errors=errors+1; end
        resetn = 1; repeat (20) @(posedge clk);
        if (donecnt != d0) begin $display("L2 FAIL: done fired after abort"); errors=errors+1; end
        step1(5'd1, 5'd0);                          // core still usable
        if (donecnt == d0 + 1) $display("L2 OK: resetn aborts step, core returns to idle and re-runs");
        else begin $display("L2 FAIL: core unusable after resetn"); errors=errors+1; end

        // ---- (d) §4 KV must survive resetn: greedy gen with a reset pulse ---
        //      inserted between decode steps; sequence must still be "alaya".
        resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (2) @(posedge clk);
        token_in = 0; pos_in = 0; rng_in = 0; smode = 0; inv_temp = 0; slen = 0;
        for (stp = 0; stp < 16; stp = stp + 1) begin
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            wait (done); @(posedge clk); #1;
            if (next_token == 0) stp = 100;
            else begin
                seq[slen] = next_token; slen = slen + 1;
                token_in = next_token; pos_in = pos_in + 1; rng_in = rng_out;
                // pulse resetn between steps 2 and 3 (KV holds pos 0..1)
                if (slen == 2) begin
                    resetn = 0; repeat (5) @(posedge clk); resetn = 1; repeat (2) @(posedge clk);
                    $display("(resetn pulsed between step 2 and 3)");
                end
            end
        end
        $write("greedy-with-reset tokens:"); for (k=0;k<slen;k=k+1) $write(" %0d", seq[k]); $write("\n");
        if (slen != 5) begin $display("KV FAIL: len %0d", slen); errors=errors+1; end
        else begin
            for (k=0;k<5;k=k+1) if (seq[k]!==exp_greedy[k]) begin
                $display("KV MISMATCH %0d got %0d exp %0d", k, seq[k], exp_greedy[k]); errors=errors+1; end
            if (errors == 0) $display("L2 OK: KV cache survives resetn (sequence still alaya)");
        end

        if (errors == 0) $display("LAT/PROTO PASS");
        else             $display("LAT/PROTO FAIL: %0d errors", errors);
        $finish;
    end
endmodule
