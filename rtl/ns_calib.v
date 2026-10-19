// =============================================================================
// ns_calib.v  --  on-chip, label-free self-calibration
//
// Called once per trial end.  When the drift monitor reports drift (and no
// burst is running) a recalibration burst starts:
//   every trial:     Rsum += R_trial,  n += 1
//   n = 1,2,4,..,64: recalibrate with  Rmean = Rsum >>> log2(n)   (no divider)
//     normalise:     k = (p + 2) >> 1, p = leading one of trace(Rmean)
//                    Y = Rmean / 4^k (fixed point), Z = I
//     Newton-Schulz: NS_ITERS x { P = Z Y ; T = (3I - P) >>> 1 ; Y = Y T ; Z = T Z }
//                    -> Z = (Rmean/4^k)^(-1/2), multiply-adds only
//     new filters:   G = F x Z  (CSP filters with the alignment folded in)
//   n = 64:          burst ends (burst_end tells the drift monitor to re-reference)
// One multiplier does all matrix work (8 x 8 x 8 = 512 MACs per product).
// Bit-exact with python/neuroedge/fixed.py : ns_calibrate(), g_from()
// and the 'drift' policy in python/neuroedge/pipeline.py : run_day2()
// =============================================================================
`timescale 1ns/1ps
module ns_calib (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire               drift_in,
    output wire [5:0]         r_addr,
    input  wire signed [47:0] r_data,
    input  wire [5:0]         g_addr,
    output wire signed [23:0] g_data,
    output reg  [7:0]         k_out,
    output reg                done,
    output reg                recal,         // Newton-Schulz ran this trial
    output reg                burst_start,   // drift started a burst this trial
    output reg                burst_end,     // burst finished this trial
    output wire               busy
);
`include "neuroedge_params.vh"

    localparam [3:0] C_IDLE = 4'd0, C_ACC = 4'd1, C_CHECK = 4'd2, C_TRACE = 4'd3,
                     C_K = 4'd4, C_INIT = 4'd5, C_MM = 4'd6, C_TCALC = 4'd7,
                     C_COPY = 4'd8, C_FIN = 4'd9;
    localparam integer ONE   = 1 << NS_FRAC;
    localparam integer THREE = 3 << NS_FRAC;
    localparam integer HALF  = 1 << (NS_FRAC - 1);

    // ---------------- memories
    reg signed [RSUM_W-1:0] rsum [0:63];
    reg signed [NS_W-1:0]   Y    [0:63];
    reg signed [NS_W-1:0]   Z    [0:63];
    reg signed [NS_W-1:0]   T    [0:63];
    reg signed [NS_W-1:0]   Sm   [0:63];
    reg signed [G_W-1:0]    f_mem [0:47];   // trained CSP filters (constant)
    reg signed [G_W-1:0]    g_mem [0:47];   // current G = F x Z (starts as day-1 G)
    initial begin
`include "f_init.vh"
`include "g_init.vh"
    end

    assign g_data = g_mem[g_addr];

    // ---------------- state
    reg [3:0] st;
    reg       burst;
    reg [7:0] n;
    reg [2:0] lg;
    reg [5:0] a;
    reg [2:0] mi, mj, mk;
    reg [1:0] op;            // 0: Sm=Z*Y  1: Sm=Y*T  2: Sm=T*Z  3: G=F*Z
    reg [4:0] it;
    reg       copy_z;
    reg signed [63:0] acc;
    reg [55:0]        trace;
    reg [7:0]         k_new;
    reg signed [7:0]  sh;

    assign busy   = (st != C_IDLE);
    assign r_addr = a;

    // ---------------- saturation helpers
    // 64-bit datapath (same as the Python int64 model). Vivado 2016's simulator
    // gave wrong results for >>> on the earlier 72-bit sums, so wide values are
    // kept at 64 bits and the rounding shift is an explicit bit slice.
    function signed [NS_W-1:0] sat_ns;
        input signed [63:0] v;
        begin
            if (&v[63:NS_W-1] || ~|v[63:NS_W-1]) sat_ns = v[NS_W-1:0];
            else sat_ns = v[63] ? {1'b1, {(NS_W-1){1'b0}}} : {1'b0, {(NS_W-1){1'b1}}};
        end
    endfunction
    function signed [G_W-1:0] sat_g;
        input signed [63:0] v;
        begin
            if (&v[63:G_W-1] || ~|v[63:G_W-1]) sat_g = v[G_W-1:0];
            else sat_g = v[63] ? {1'b1, {(G_W-1){1'b0}}} : {1'b0, {(G_W-1){1'b1}}};
        end
    endfunction

    // ---------------- trace of Rsum >>> lg, and its leading one
    // Written as continuous assignments: Vivado 2016's simulator does not
    // re-run an always @* block when a memory read with a computed index
    // changes, which left stale X values here.
    function [6:0] lead1;
        input [55:0] v;
        integer b;
        begin
            lead1 = 7'd0;
            for (b = 0; b < 56; b = b + 1) if (v[b]) lead1 = b;
        end
    endfunction
    wire signed [RSUM_W-1:0] d0 = rsum[0]  >>> lg, d1 = rsum[9]  >>> lg,
                             d2 = rsum[18] >>> lg, d3 = rsum[27] >>> lg,
                             d4 = rsum[36] >>> lg, d5 = rsum[45] >>> lg,
                             d6 = rsum[54] >>> lg, d7 = rsum[63] >>> lg;
    wire signed [55:0] tr_c = d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7;
    wire [6:0]         p_c  = lead1(trace);
    integer q;
    wire [7:0]        k_c  = (p_c + 7'd2) >> 1;
    wire signed [7:0] sh_c = $signed({k_c[6:0], 1'b0}) - NS_FRAC;

    // ---------------- normalise one element: sat32((Rsum >>> lg) shifted by sh)
    wire signed [RSUM_W-1:0] rm   = rsum[a] >>> lg;
    wire signed [63:0]       rm_x = rm;
    wire [7:0]               nsh  = -sh;
    wire signed [63:0]       rn_v = sh[7] ? (rm_x <<< nsh) : (rm_x >>> sh);
    wire signed [NS_W-1:0]   rn_s = (&rn_v[63:NS_W-1] || ~|rn_v[63:NS_W-1]) ? rn_v[NS_W-1:0] :
                                    (rn_v[63] ? {1'b1, {(NS_W-1){1'b0}}} : {1'b0, {(NS_W-1){1'b1}}});

    // ---------------- matrix-multiply datapath (one MAC per cycle)
    // operands as continuous assignments (see the note above)
    wire signed [NS_W-1:0] z_a = Z[{mi, mk}], y_a = Y[{mi, mk}], t_a = T[{mi, mk}];
    wire signed [G_W-1:0]  f_a = f_mem[{mi, mk}];
    wire signed [NS_W-1:0] y_b = Y[{mk, mj}], t_b = T[{mk, mj}], z_b = Z[{mk, mj}];
    wire signed [NS_W-1:0] f_ax = f_a;                      // sign-extended to NS_W
    wire signed [NS_W-1:0] a_val = (op == 2'd0) ? z_a : (op == 2'd1) ? y_a :
                                   (op == 2'd2) ? t_a : f_ax;
    wire signed [NS_W-1:0] b_val = (op == 2'd0) ? y_b : (op == 2'd1) ? t_b : z_b;
    wire signed [63:0] acc_base = (mk == 3'd0) ? 64'sd0 : acc;
    wire signed [63:0] prod     = a_val * b_val;             // 32 x 32 -> 64
    wire signed [63:0] acc_next = acc_base + prod;
    wire signed [63:0] rnd      = acc_next + HALF;
    wire signed [63:0] mm_res   = {{NS_FRAC{rnd[63]}}, rnd[63:NS_FRAC]};  // (acc + half) >>> NS_FRAC
    wire [2:0]         last_row = (op == 2'd3) ? (N_FILT - 1) : 3'd7;

    // ---------------- T = (3I - Sm) >>> 1
    wire               diag_a = (a[5:3] == a[2:0]);
    wire signed [NS_W+1:0] tdiff = (diag_a ? THREE : 0) - Sm[a];

    // ---------------- optional debug prints: run xsim with  -testplusarg nsdebug
    reg dbg_en; reg [3:0] dbg_cnt;
    initial begin dbg_en = $test$plusargs("nsdebug"); dbg_cnt = 0; end
    always @(posedge clk) if (dbg_en && !rst && dbg_cnt < 12) begin
        if (st == C_K)
            $display("DBG K: lg=%0d trace=%0d p_c=%0d k_c=%0d sh_c=%0d d0=%0d tr_c=%0d", lg, trace, p_c, k_c, sh_c, d0, tr_c);
        if (st == C_INIT && a == 6'd1)
            $display("DBG INIT: sh=%0d rsum0=%0d rm(a=1)=%0d rn_s(a=1)=%0d Y0=%0d Z0=%0d", sh, rsum[0], rm, rn_s, Y[0], Z[0]);
        if (st == C_MM && mk == 3'd1 && mi == 0 && mj == 0) begin
            $display("DBG MM op=%0d it=%0d: a_val=%0d b_val=%0d acc=%0d | Y0=%0d Y1=%0d Z0=%0d Z1=%0d T0=%0d T1=%0d", op, it, a_val, b_val, acc, Y[0], Y[1], Z[0], Z[1], T[0], T[1]);
            dbg_cnt = dbg_cnt + 1;
        end
        if (st == C_TCALC && a == 6'd2)
            $display("DBG TCALC: Sm0=%0d Sm1=%0d T0=%0d T1=%0d tdiff(a=2)=%0d", Sm[0], Sm[1], T[0], T[1], tdiff);
        if (st == C_COPY)
            $display("DBG COPY copy_z=%0d it=%0d: Sm0=%0d Sm1=%0d Sm9=%0d", copy_z, it, Sm[0], Sm[1], Sm[9]);
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= C_IDLE; burst <= 1'b0; n <= 8'd0; lg <= 3'd0; a <= 6'd0;
            mi <= 0; mj <= 0; mk <= 0; op <= 0; it <= 0; copy_z <= 1'b0;
            acc <= 0; trace <= 0; k_new <= 0; sh <= 0;
            k_out <= K_INIT;
            recal <= 1'b0; burst_start <= 1'b0; burst_end <= 1'b0;
        end else begin
            case (st)
            C_IDLE: if (start) begin
                recal <= 1'b0; burst_start <= 1'b0; burst_end <= 1'b0;
                a <= 6'd0;
                if (!burst && drift_in) begin
                    burst <= 1'b1; n <= 8'd0; burst_start <= 1'b1;
                    for (q = 0; q < 64; q = q + 1) rsum[q] <= 0;
                    st <= C_ACC;
                end else if (burst) st <= C_ACC;
                else                st <= C_FIN;
            end
            C_ACC: begin                                   // Rsum += R_trial
                rsum[a] <= rsum[a] + r_data;
                a <= a + 6'd1;
                if (a == 6'd63) begin
                    n  <= n + 8'd1;
                    st <= C_CHECK;
                end
            end
            C_CHECK: begin                                 // n a power of two?
                case (n)
                    8'd1:  lg <= 3'd0;
                    8'd2:  lg <= 3'd1;
                    8'd4:  lg <= 3'd2;
                    8'd8:  lg <= 3'd3;
                    8'd16: lg <= 3'd4;
                    8'd32: lg <= 3'd5;
                    default: lg <= 3'd6;
                endcase
                st <= ((n & (n - 8'd1)) == 8'd0) ? C_TRACE : C_FIN;
            end
            C_TRACE: begin
                trace <= tr_c;
                st <= C_K;
            end
            C_K: begin
                k_new <= k_c;
                sh    <= sh_c;
                a     <= 6'd0;
                st    <= C_INIT;
            end
            C_INIT: begin                                  // Y = Rn, Z = I
                Y[a] <= rn_s;
                Z[a] <= diag_a ? ONE : 0;
                a <= a + 6'd1;
                if (a == 6'd63) begin
                    it <= 0; op <= 2'd0; mi <= 0; mj <= 0; mk <= 0;
                    st <= C_MM;
                end
            end
            C_MM: begin
                acc <= acc_next;
                mk  <= mk + 3'd1;
                if (mk == 3'd7) begin
                    if (op == 2'd3) g_mem[{mi, mj}] <= sat_g(mm_res);
                    else            Sm[{mi, mj}]    <= sat_ns(mm_res);
                    mj <= mj + 3'd1;
                    if (mj == 3'd7) begin
                        mi <= mi + 3'd1;
                        if (mi == last_row) begin          // product finished
                            mi <= 0;
                            case (op)
                                2'd0: begin a <= 6'd0; st <= C_TCALC; end
                                2'd1: begin copy_z <= 1'b0; st <= C_COPY; end
                                2'd2: begin copy_z <= 1'b1; st <= C_COPY; end
                                default: begin
                                    k_out <= k_new;
                                    recal <= 1'b1;
                                    st    <= C_FIN;
                                end
                            endcase
                        end
                    end
                end
            end
            C_TCALC: begin                                 // T = (3I - P) >>> 1
                T[a] <= tdiff >>> 1;
                a <= a + 6'd1;
                if (a == 6'd63) begin
                    op <= 2'd1; mi <= 0; mj <= 0; mk <= 0;
                    st <= C_MM;
                end
            end
            C_COPY: begin
                for (q = 0; q < 64; q = q + 1)
                    if (copy_z) Z[q] <= Sm[q];
                    else        Y[q] <= Sm[q];
                mi <= 0; mj <= 0; mk <= 0;
                st <= C_MM;
                if (!copy_z) op <= 2'd2;                   // next: Z = T Z
                else begin
                    it <= it + 5'd1;
                    op <= (it + 5'd1 == NS_ITERS) ? 2'd3 : 2'd0;
                end
            end
            C_FIN: begin
                if (burst && n == BURST_MAX) begin
                    burst     <= 1'b0;
                    burst_end <= 1'b1;
                end
                done <= 1'b1;
                st   <= C_IDLE;
            end
            default: st <= C_IDLE;
            endcase
        end
    end
endmodule
