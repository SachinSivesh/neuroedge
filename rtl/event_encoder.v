// =============================================================================
// event_encoder.v  --  send-on-delta encoder with a noise-tracking threshold
//
// Per channel c (one sample per cycle):
//   th    = max(1, (m[c] * K_INT) >> (M_FRAC + K_FRAC))      threshold
//   fire  = |x - last[c]| >= th                               event?
//   m[c] += ((|x| << M_FRAC) - m[c]) >>> M_SHIFT              track mean |x|
//   if fire: last[c] = x
// Bit-exact with python/neuroedge/fixed.py : frontend_session() (encoder part)
//
// m[] doubles as the drift monitor's input (read port m_addr / m_data).
// Latency 1 cycle.
// =============================================================================
`timescale 1ns/1ps
module event_encoder (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire [2:0]         in_ch,
    input  wire signed [15:0] in_data,
    output reg                out_valid,
    output reg  [2:0]         out_ch,
    output reg                out_fire,
    output reg  signed [15:0] out_value,
    input  wire [2:0]         m_addr,
    output wire [23:0]        m_data
);
`include "neuroedge_params.vh"

    reg signed [15:0]  last [0:7];
    reg        [M_W-1:0] m  [0:7];

    wire [M_W-1:0] m_c  = m[in_ch];
    wire [31:0]    mk   = m_c * K_INT;
    wire [31:0]    th_r = mk >> (M_FRAC + K_FRAC);
    wire [31:0]    th   = (th_r == 32'd0) ? 32'd1 : th_r;

    wire signed [16:0] d    = in_data - last[in_ch];
    wire        [16:0] ad   = d[16] ? (~d + 17'd1) : d;
    wire               fire = ({15'd0, ad} >= th);

    wire        [15:0]    ax   = in_data[15] ? (~in_data + 16'd1) : in_data;
    wire signed [M_W+1:0] diff = $signed({2'b00, ax, {M_FRAC{1'b0}}}) - $signed({2'b00, m_c});
    wire signed [M_W+1:0] m_nx = $signed({2'b00, m_c}) + (diff >>> M_SHIFT);

    assign m_data = m[m_addr];

    integer q;
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_ch    <= 3'd0;
            out_fire  <= 1'b0;
            out_value <= 16'sd0;
            for (q = 0; q < 8; q = q + 1) last[q] <= 16'sd0;
            m[0] <= M_REF0; m[1] <= M_REF1; m[2] <= M_REF2; m[3] <= M_REF3;
            m[4] <= M_REF4; m[5] <= M_REF5; m[6] <= M_REF6; m[7] <= M_REF7;
        end else begin
            out_valid <= in_valid;
            out_ch    <= in_ch;
            out_fire  <= in_valid & fire;
            out_value <= in_data;
            if (in_valid) begin
                m[in_ch] <= m_nx[M_W-1:0];
                if (fire) last[in_ch] <= in_data;
            end
        end
    end
endmodule
