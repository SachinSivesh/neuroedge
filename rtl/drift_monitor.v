// =============================================================================
// drift_monitor.v  --  detects signal drift from the encoder's own state
//
// The encoder already tracks each channel's mean |x| (its noise floor m[c]).
// At every trial end this block compares m[c] with a reference m_ref[c]:
//   drift = any c:  m*RD > m_ref*RN   or   m*RN < m_ref*RD     (ratio RN/RD)
// No extra signal processing: drift detection is almost free.
// update_ref copies the current m[] into m_ref[] (after a recalibration burst).
// Bit-exact with python/neuroedge/fixed.py : drift()
// =============================================================================
`timescale 1ns/1ps
module drift_monitor (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,        // check now
    input  wire        update_ref,   // take m[] as the new reference
    output wire [2:0]  m_addr,
    input  wire [23:0] m_data,
    output reg         done,
    output reg         drift
);
`include "neuroedge_params.vh"

    localparam [1:0] D_IDLE = 2'd0, D_CHECK = 2'd1, D_UPD = 2'd2;

    reg [M_W-1:0] mref [0:7];
    reg [1:0] st;
    reg [2:0] c;
    reg       acc;

    assign m_addr = c;

    wire [31:0] m_rd   = m_data    * DRIFT_RD;
    wire [31:0] m_rn   = m_data    * DRIFT_RN;
    wire [31:0] ref_rn = mref[c]   * DRIFT_RN;
    wire [31:0] ref_rd = mref[c]   * DRIFT_RD;
    wire        hit    = (m_rd > ref_rn) || (m_rn < ref_rd);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= D_IDLE; c <= 3'd0; acc <= 1'b0; drift <= 1'b0;
            mref[0] <= M_REF0; mref[1] <= M_REF1; mref[2] <= M_REF2; mref[3] <= M_REF3;
            mref[4] <= M_REF4; mref[5] <= M_REF5; mref[6] <= M_REF6; mref[7] <= M_REF7;
        end else begin
            case (st)
            D_IDLE: begin
                c <= 3'd0;
                acc <= 1'b0;
                if (start)           st <= D_CHECK;
                else if (update_ref) st <= D_UPD;
            end
            D_CHECK: begin
                acc <= acc | hit;
                if (c == 3'd7) begin
                    drift <= acc | hit;
                    done  <= 1'b1;
                    st    <= D_IDLE;
                end else c <= c + 3'd1;
            end
            D_UPD: begin
                mref[c] <= m_data;
                if (c == 3'd7) begin
                    done <= 1'b1;
                    st   <= D_IDLE;
                end else c <= c + 3'd1;
            end
            default: st <= D_IDLE;
            endcase
        end
    end
endmodule
