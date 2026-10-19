// =============================================================================
// event_cov.v  --  event-driven covariance (exact for the held signal)
//
// Each channel's last event value H[c] is held between events. The trial
// covariance R[k][j] = sum_t H_k(t) H_j(t) is built WITHOUT multiplying every
// sample:
//   A[j]     running sum of H_j over the frames so far (8 adders per frame)
//   S[k][j]  value of A[j] when channel k's current hold interval started
//   event on channel k:  R[k][j] += H_k(old) * (A[j] - S[k][j]);  S[k][j] = A[j]
//   trial end (flush):   the same for all 64 entries
// So the work is 8 MACs per event (+64 per trial) instead of 36 per sample.
// Bit-exact with python/neuroedge/fixed.py : frontend_session() (covariance part)
//
// Protocol: samples arrive as frames of 8 (channel 0..7). The frame is buffered,
// then processed after channel 7 (busy = 1). 'active' marks the decoding
// window and must be stable from channel 7 until frame_done.
// flush: close all intervals at trial end (-> flush_done). clear: zero R, A, S.
// =============================================================================
`timescale 1ns/1ps
module event_cov (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     ev_valid,
    input  wire [2:0]               ev_ch,
    input  wire                     ev_fire,
    input  wire signed [15:0]       ev_value,
    input  wire                     active,
    input  wire                     flush,
    input  wire                     clear,
    output wire                     busy,
    output reg                      frame_done,
    output reg                      flush_done,
    input  wire [5:0]               rd_addr,
    output wire signed [47:0]       rd_data,
    output reg  [31:0]              mac_count,
    output reg  [31:0]              event_count
);
`include "neuroedge_params.vh"

    localparam [1:0] ST_IDLE = 2'd0, ST_FRAME = 2'd1, ST_ENDF = 2'd2, ST_FLUSH = 2'd3;

    reg               fb_fire [0:7];          // frame buffer
    reg signed [15:0] fb_val  [0:7];
    reg signed [15:0]        H [0:7];         // held values
    reg signed [ACC_SUM_W-1:0] A [0:7];       // running sums
    reg signed [ACC_SUM_W-1:0] S [0:63];      // interval start snapshots
    reg signed [COV_W-1:0]     R [0:63];      // covariance sums

    reg [1:0] st;
    reg [2:0] c, j;
    reg       act;

    wire [5:0]                   idx  = {c, j};
    wire signed [ACC_SUM_W:0]    dA   = A[j] - S[idx];
    wire signed [COV_W-1:0]      prod = H[c] * dA;

    assign busy    = (st != ST_IDLE);
    assign rd_data = R[rd_addr];

    integer q;
    always @(posedge clk) begin
        frame_done <= 1'b0;
        flush_done <= 1'b0;
        if (rst) begin
            st <= ST_IDLE; c <= 3'd0; j <= 3'd0; act <= 1'b0;
            mac_count <= 32'd0; event_count <= 32'd0;
            for (q = 0; q < 8; q = q + 1) begin
                fb_fire[q] <= 1'b0; fb_val[q] <= 16'sd0; H[q] <= 16'sd0; A[q] <= 0;
            end
            for (q = 0; q < 64; q = q + 1) begin
                S[q] <= 0; R[q] <= 0;
            end
        end else begin
            // capture the incoming frame (only arrives while idle)
            if (ev_valid) begin
                fb_fire[ev_ch] <= ev_fire;
                fb_val[ev_ch]  <= ev_value;
            end
            case (st)
            ST_IDLE: begin
                if (ev_valid && ev_ch == 3'd7) begin
                    st <= ST_FRAME; c <= 3'd0; j <= 3'd0; act <= active;
                end else if (flush) begin
                    st <= ST_FLUSH; c <= 3'd0; j <= 3'd0;
                end else if (clear) begin
                    for (q = 0; q < 8; q = q + 1) A[q] <= 0;
                    for (q = 0; q < 64; q = q + 1) begin
                        S[q] <= 0; R[q] <= 0;
                    end
                end
            end
            ST_FRAME: begin
                if (fb_fire[c] && act) begin
                    // one MAC per cycle along row c
                    R[idx]    <= R[idx] + prod;
                    S[idx]    <= A[j];
                    mac_count <= mac_count + 32'd1;
                    if (j == 3'd7) begin
                        H[c]        <= fb_val[c];
                        event_count <= event_count + 32'd1;
                        j           <= 3'd0;
                        if (c == 3'd7) st <= ST_ENDF; else c <= c + 3'd1;
                    end else begin
                        j <= j + 3'd1;
                    end
                end else begin
                    if (fb_fire[c]) H[c] <= fb_val[c];
                    if (c == 3'd7) st <= ST_ENDF; else c <= c + 3'd1;
                end
            end
            ST_ENDF: begin
                if (act)
                    for (q = 0; q < 8; q = q + 1) A[q] <= A[q] + H[q];
                frame_done <= 1'b1;
                st <= ST_IDLE;
            end
            ST_FLUSH: begin
                R[idx]    <= R[idx] + prod;
                mac_count <= mac_count + 32'd1;
                if (j == 3'd7) begin
                    j <= 3'd0;
                    if (c == 3'd7) begin
                        flush_done <= 1'b1;
                        st <= ST_IDLE;
                    end else begin
                        c <= c + 3'd1;
                    end
                end else begin
                    j <= j + 3'd1;
                end
            end
            endcase
        end
    end
endmodule
