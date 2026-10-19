// =============================================================================
// iir_bandpass.v  --  8-30 Hz band-pass, 8 channels time-multiplexed
//
// Two Direct Form I biquads in a 2-stage pipeline. Samples arrive one channel
// per cycle (in_ch = 0..7); each channel keeps its own filter state.
// Bit-exact with python/neuroedge/fixed.py : iir_stream()
//
//   s     = in_data <<< GUARD                         (24-bit, 8 guard bits)
//   acc   = b0*s + b1*x1 + b2*x2 - a1*y1 - a2*y2       (48-bit)
//   y     = sat24((acc + 2^(FRAC-1)) >>> FRAC)
//   out   = sat16((y_last + 2^(GUARD-1)) >>> GUARD)
//
// Latency 2 cycles. The same channel must not arrive in two consecutive cycles.
// =============================================================================
`timescale 1ns/1ps
module iir_bandpass (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire [2:0]         in_ch,
    input  wire signed [15:0] in_data,
    output reg                out_valid,
    output reg  [2:0]         out_ch,
    output reg  signed [15:0] out_data
);
`include "iir_coeffs.vh"
    localparam integer GUARD = IIR_INT_W - 16;
    localparam integer HALF  = 1 << (IIR_FRAC - 1);
    localparam integer GHALF = 1 << (GUARD - 1);

    // saturate an accumulator-width value to IIR_INT_W bits
    function signed [IIR_INT_W-1:0] sat_int;
        input signed [IIR_ACC_W-1:0] v;
        begin
            if (&v[IIR_ACC_W-1:IIR_INT_W-1] || ~|v[IIR_ACC_W-1:IIR_INT_W-1])
                sat_int = v[IIR_INT_W-1:0];
            else
                sat_int = v[IIR_ACC_W-1] ? {1'b1, {(IIR_INT_W-1){1'b0}}}
                                          : {1'b0, {(IIR_INT_W-1){1'b1}}};
        end
    endfunction

    // saturate a (IIR_INT_W+1)-bit value to 16 bits
    function signed [15:0] sat_out;
        input signed [IIR_INT_W:0] v;
        begin
            if (&v[IIR_INT_W:15] || ~|v[IIR_INT_W:15])
                sat_out = v[15:0];
            else
                sat_out = v[IIR_INT_W] ? 16'sh8000 : 16'sh7FFF;
        end
    endfunction

    // ---------------- per-channel state
    reg signed [IIR_INT_W-1:0] a_x1 [0:7];   // section 0
    reg signed [IIR_INT_W-1:0] a_x2 [0:7];
    reg signed [IIR_INT_W-1:0] a_y1 [0:7];
    reg signed [IIR_INT_W-1:0] a_y2 [0:7];
    reg signed [IIR_INT_W-1:0] b_x1 [0:7];   // section 1
    reg signed [IIR_INT_W-1:0] b_x2 [0:7];
    reg signed [IIR_INT_W-1:0] b_y1 [0:7];
    reg signed [IIR_INT_W-1:0] b_y2 [0:7];

    // ---------------- stage 1: section 0
    wire signed [IIR_INT_W-1:0] s_in = {in_data, {GUARD{1'b0}}};
    wire signed [IIR_ACC_W-1:0] acc0 = S0_B0 * s_in
                                     + S0_B1 * a_x1[in_ch]
                                     + S0_B2 * a_x2[in_ch]
                                     - S0_A1 * a_y1[in_ch]
                                     - S0_A2 * a_y2[in_ch];
    wire signed [IIR_ACC_W-1:0] rnd0 = (acc0 + HALF) >>> IIR_FRAC;
    wire signed [IIR_INT_W-1:0] y0   = sat_int(rnd0);

    reg                         p_valid;
    reg  [2:0]                  p_ch;
    reg  signed [IIR_INT_W-1:0] p_y;

    // ---------------- stage 2: section 1
    wire signed [IIR_ACC_W-1:0] acc1 = S1_B0 * p_y
                                     + S1_B1 * b_x1[p_ch]
                                     + S1_B2 * b_x2[p_ch]
                                     - S1_A1 * b_y1[p_ch]
                                     - S1_A2 * b_y2[p_ch];
    wire signed [IIR_ACC_W-1:0] rnd1 = (acc1 + HALF) >>> IIR_FRAC;
    wire signed [IIR_INT_W-1:0] y1   = sat_int(rnd1);
    wire signed [IIR_INT_W:0]   y1e  = $signed({y1[IIR_INT_W-1], y1}) + GHALF;
    wire signed [IIR_INT_W:0]   y1s  = y1e >>> GUARD;

    integer q;
    always @(posedge clk) begin
        if (rst) begin
            p_valid   <= 1'b0;
            out_valid <= 1'b0;
            p_ch      <= 3'd0;
            p_y       <= 0;
            out_ch    <= 3'd0;
            out_data  <= 16'sd0;
            for (q = 0; q < 8; q = q + 1) begin
                a_x1[q] <= 0; a_x2[q] <= 0; a_y1[q] <= 0; a_y2[q] <= 0;
                b_x1[q] <= 0; b_x2[q] <= 0; b_y1[q] <= 0; b_y2[q] <= 0;
            end
        end else begin
            // stage 1
            p_valid <= in_valid;
            p_ch    <= in_ch;
            p_y     <= y0;
            if (in_valid) begin
                a_x2[in_ch] <= a_x1[in_ch];
                a_x1[in_ch] <= s_in;
                a_y2[in_ch] <= a_y1[in_ch];
                a_y1[in_ch] <= y0;
            end
            // stage 2
            out_valid <= p_valid;
            out_ch    <= p_ch;
            out_data  <= sat_out(y1s);
            if (p_valid) begin
                b_x2[p_ch] <= b_x1[p_ch];
                b_x1[p_ch] <= p_y;
                b_y2[p_ch] <= b_y1[p_ch];
                b_y1[p_ch] <= y1;
            end
        end
    end
endmodule
