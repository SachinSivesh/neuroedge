// =============================================================================
// backend.v  --  CSP features, log2 and LDA decision for one trial
//
// G = F x W is the CSP filter bank with the self-calibration alignment folded
// in (rows i = 0..5), so alignment costs nothing per trial.
//   C'[j][k] = sat25(R[j][k] >>> CS)
//   t_j      = sum_k C'[j][k] * G[i][k]
//   u_i      = sum_j G[i][j] * t_j               (= variance of CSP output i)
//   f_i      = log2(u_i) - 2k                    (k = alignment scale, from NS)
//   score    = LDA_B + sum_i LDA_W[i] * f_i ;  decision = score > 0 (RIGHT)
// log2: leading-one position + 256-entry LUT on the next 8 bits.
// Bit-exact with python/neuroedge/fixed.py : backend_features(), lda_score()
// About 440 cycles per trial.
// =============================================================================
`timescale 1ns/1ps
module backend (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     start,
    input  wire        [7:0]        k_in,
    output wire        [5:0]        r_addr,
    input  wire signed [47:0]       r_data,
    output wire        [5:0]        g_addr,
    input  wire signed [23:0]       g_data,
    output reg                      done,
    output reg                      decision,
    output reg  signed [47:0]       score
);
`include "neuroedge_params.vh"

    localparam [2:0] B_IDLE = 3'd0, B_T = 3'd1, B_U = 3'd2, B_LOG = 3'd3, B_DONE = 3'd4;

    reg [LOG_FRAC+1:0] lut [0:255];
    initial begin
`include "lut_init.vh"
    end

    reg [2:0] st;
    reg [2:0] i, j, kk;
    reg signed [55:0] t_acc;
    reg signed [79:0] u_acc;

    // ---------------- C' = sat25(R >>> CS)
    wire signed [47:0] r_sh = r_data >>> CS;
    wire signed [CPRIME_W-1:0] cp =
        (&r_sh[47:CPRIME_W-1] || ~|r_sh[47:CPRIME_W-1]) ? r_sh[CPRIME_W-1:0] :
        (r_sh[47] ? {1'b1, {(CPRIME_W-1){1'b0}}} : {1'b0, {(CPRIME_W-1){1'b1}}});

    assign r_addr = {j, kk};
    assign g_addr = (st == B_U) ? {i, j} : {i, kk};

    wire signed [55:0] t_base = (kk == 3'd0) ? 56'sd0 : t_acc;
    wire signed [55:0] t_next = t_base + cp * g_data;
    wire signed [79:0] u_next = u_acc + g_data * t_acc;

    // ---------------- log2(u_acc)
    reg  [6:0]  p;
    reg  [7:0]  mant;
    reg  [79:0] uu;
    integer b;
    always @* begin
        p  = 7'd0;
        uu = u_acc;
        for (b = 0; b < 79; b = b + 1)
            if (uu[b]) p = b;
        if (p >= LOG_MANT) mant = uu >> (p - LOG_MANT);
        else               mant = uu << (LOG_MANT - p);
    end
    wire               u_pos = ~u_acc[79] && (u_acc != 80'sd0);
    wire signed [23:0] lg    = u_pos ? $signed({7'd0, p, {LOG_FRAC{1'b0}}}) + $signed({12'd0, lut[mant]})
                                     : 24'sd0;
    wire signed [23:0] f     = lg - $signed({5'd0, k_in, {(LOG_FRAC+1){1'b0}}});

    reg signed [LDA_W_W-1:0] w_i;
    always @* begin
        case (i)
            3'd0: w_i = LDA_W0;
            3'd1: w_i = LDA_W1;
            3'd2: w_i = LDA_W2;
            3'd3: w_i = LDA_W3;
            3'd4: w_i = LDA_W4;
            default: w_i = LDA_W5;
        endcase
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= B_IDLE; i <= 0; j <= 0; kk <= 0;
            t_acc <= 0; u_acc <= 0; score <= 0; decision <= 1'b0;
        end else begin
            case (st)
            B_IDLE: if (start) begin
                st <= B_T; i <= 0; j <= 0; kk <= 0;
                t_acc <= 0; u_acc <= 0; score <= LDA_B;
            end
            B_T: begin                       // t_j = sum_k C'[j][k] G[i][k]
                t_acc <= t_next;
                if (kk == 3'd7) st <= B_U;
                kk <= kk + 3'd1;
            end
            B_U: begin                       // u += G[i][j] * t_j
                u_acc <= u_next;
                if (j == 3'd7) st <= B_LOG;
                else           st <= B_T;
                j <= j + 3'd1;
            end
            B_LOG: begin                     // score += W_i * f_i
                score <= score + w_i * f;
                u_acc <= 0;
                if (i == N_FILT - 1) st <= B_DONE;
                else begin
                    i <= i + 3'd1;
                    st <= B_T;
                end
            end
            B_DONE: begin
                decision <= (score > 0);
                done     <= 1'b1;
                st       <= B_IDLE;
            end
            default: st <= B_IDLE;
            endcase
        end
    end
endmodule
