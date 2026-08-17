// ============================================================================
// fa_core_golden_pkg — shared helpers for the fa_core adjudication benches.
//
// Arm-neutral, variant-neutral: everything here is fixed by the black-box contract
// in handoff/brainstorm.md (§3 interface, §7 gates, §8 acceptance).
// ============================================================================
package fa_core_golden_pkg;

  // ---- pinned dimensions & acceptance gate ---------------------------------
  localparam int  N           = 4;        // Br = Bc  (tile rows / key rows)
  localparam int  D           = 4;        // head dim
  localparam int  N_IN_BEATS  = 3 * N;    // 12 input beats: Q,K,V rows 0..3
  localparam int  N_OUT_BEATS = N;        // 4 output beats: O rows 0..3
  localparam int  N_O_ELEMS   = N * D;    // 16 output elements
  localparam real MAX_ABS_ERR = 1.0e-2;   // per-element |err| bound
  localparam real MAE_BOUND   = 1.0e-3;   // mean |err| over the 16 O elements

  // ---- fp16 (E5M10) → real, for decoding the DUT's o_out lanes -------------
  // Matches reference.py's IEEE-754 half. Subnormals handled; exp==31
  // (inf/nan) is unexpected on a well-formed output and mapped to a huge value
  // so it fails the tolerance gate loudly rather than aliasing to a real number.
  function automatic real fp16_to_real(input logic [15:0] h);
    logic sign;
    int   ex;
    int   ma;
    real  val;
    begin
      sign = h[15];
      ex   = int'(h[14:10]);
      ma   = int'(h[9:0]);
      if (ex == 0)
        val = $itor(ma) * (2.0 ** (-24.0));                 // zero / subnormal
      else if (ex == 31)
        val = 1.0e30;                                       // inf/nan (unexpected)
      else
        val = (1.0 + $itor(ma) * (2.0 ** (-10.0)))
              * (2.0 ** ($itor(ex) - 15.0));
      fp16_to_real = sign ? -val : val;
    end
  endfunction

  // ---- fp32 (E8M23) → real, for decoding the expected O from the vector file -
  // The vector stream carries expected O as fp32 bit patterns (reference.py's
  // fp32_bits), so no decimal text sits between the oracle and the comparison.
  function automatic real fp32_to_real(input logic [31:0] w);
    logic sign;
    int   ex;
    int   ma;
    real  val;
    begin
      sign = w[31];
      ex   = int'(w[30:23]);
      ma   = int'(w[22:0]);
      if (ex == 0)
        val = $itor(ma) * (2.0 ** (-149.0));                // zero / subnormal
      else if (ex == 255)
        val = 1.0e30;                                       // inf/nan (unexpected)
      else
        val = (1.0 + $itor(ma) * (2.0 ** (-23.0)))
              * (2.0 ** ($itor(ex) - 127.0));
      fp32_to_real = sign ? -val : val;
    end
  endfunction

  function automatic real abs_r(input real x);
    abs_r = (x < 0.0) ? -x : x;
  endfunction

  // ---- tolerance verdict over one tile's 16-element O ----------------------
  // got[0:15] / want[0:15] are row-major (O[0][0..3], O[1][0..3], ...).
  // Returns 1 == within tolerance; writes back the measured maxerr / mae.
  function automatic bit tile_within_tol(input real got  [0:N_O_ELEMS-1],
                                         input real want [0:N_O_ELEMS-1],
                                         output real maxerr,
                                         output real mae);
    int  k;
    real e, sum;
    begin
      maxerr = 0.0; sum = 0.0;
      for (k = 0; k < N_O_ELEMS; k++) begin
        e = abs_r(got[k] - want[k]);
        if (e > maxerr) maxerr = e;
        sum += e;
      end
      mae = sum / real'(N_O_ELEMS);
      tile_within_tol = (maxerr < MAX_ABS_ERR) && (mae < MAE_BOUND);
    end
  endfunction

endpackage
