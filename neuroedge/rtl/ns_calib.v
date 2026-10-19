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
    reg signed [71:0] acc;
    reg [55:0]        trace;
    reg [7:0]         k_new;
    reg signed [7:0]  sh;

    assign busy   = (st != C_IDLE);
    assign r_addr = a;

    // ---------------- saturation helpers
    function signed [NS_W-1:0] sat_ns;
        input signed [71:0] v;
        begin
            if (&v[71:NS_W-1] || ~|v[71:NS_W-1]) sat_ns = v[NS_W-1:0];
            else sat_ns = v[71] ? {1'b1, {(NS_W-1){1'b0}}} : {1'b0, {(NS_W-1){1'b1}}};
        end
    endfunction
    function signed [G_W-1:0] sat_g;
        input signed [71:0] v;
        begin
            if (&v[71:G_W-1] || ~|v[71:G_W-1]) sat_g = v[G_W-1:0];
            else sat_g = v[71] ? {1'b1, {(G_W-1){1'b0}}} : {1'b0, {(G_W-1){1'b1}}};
        end
    endfunction

    // ---------------- trace of Rsum >>> lg, and its leading one
    reg signed [55:0] tr_c;
    reg [6:0]         p_c;
    integer qc, b, q;
    always @* begin
        tr_c = 0;
        for (qc = 0; qc < 8; qc = qc + 1) tr_c = tr_c + (rsum[qc * 9] >>> lg);
        p_c = 7'd0;
        for (b = 0; b < 56; b = b + 1) if (trace[b]) p_c = b;
    end
    wire [7:0]        k_c  = (p_c + 7'd2) >> 1;
    wire signed [7:0] sh_c = $signed({k_c[6:0], 1'b0}) - NS_FRAC;

    // ---------------- normalise one element: sat32((Rsum >>> lg) shifted by sh)
    wire signed [RSUM_W-1:0] rm   = rsum[a] >>> lg;
    wire signed [79:0]       rm_x = rm;
    wire [7:0]               nsh  = -sh;
    wire signed [79:0]       rn_v = sh[7] ? (rm_x <<< nsh) : (rm_x >>> sh);
    wire signed [NS_W-1:0]   rn_s = (&rn_v[79:NS_W-1] || ~|rn_v[79:NS_W-1]) ? rn_v[NS_W-1:0] :
                                    (rn_v[79] ? {1'b1, {(NS_W-1){1'b0}}} : {1'b0, {(NS_W-1){1'b1}}});

    // ---------------- matrix-multiply datapath (one MAC per cycle)
    reg signed [NS_W-1:0] a_val, b_val;
    always @* begin
        case (op)
            2'd0:    a_val = Z[{mi, mk}];
            2'd1:    a_val = Y[{mi, mk}];
            2'd2:    a_val = T[{mi, mk}];
            default: a_val = f_mem[{mi, mk}];      // sign-extended to NS_W
        endcase
        case (op)
            2'd0:    b_val = Y[{mk, mj}];
            2'd1:    b_val = T[{mk, mj}];
            default: b_val = Z[{mk, mj}];
        endcase
    end
    wire signed [71:0] acc_base = (mk == 3'd0) ? 72'sd0 : acc;
    wire signed [71:0] acc_next = acc_base + a_val * b_val;
    wire signed [71:0] mm_res   = (acc_next + HALF) >>> NS_FRAC;
    wire [2:0]         last_row = (op == 2'd3) ? (N_FILT - 1) : 3'd7;

    // ---------------- T = (3I - Sm) >>> 1
    wire               diag_a = (a[5:3] == a[2:0]);
    wire signed [NS_W+1:0] tdiff = (diag_a ? THREE : 0) - Sm[a];

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
