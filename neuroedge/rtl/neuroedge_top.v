// =============================================================================
// neuroedge_top.v  --  NeuroEdge: event-driven, self-calibrating EEG decoder
//
//   raw EEG (8 ch) -> iir_bandpass -> event_encoder -> event_cov --+
//                                         | m[]                    | R
//                                   drift_monitor             backend -> decision
//                                         | drift                  ^ G, k
//                                         +---------> ns_calib ----+
//
// Streaming input: frames of 8 samples (in_ch 0..7, one per cycle), sent only
// when ready = 1.  win_active = 1 for frames inside the decoding window.
// After a trial's last frame, pulse trial_end (when ready); the core then
// runs flush -> backend -> drift check -> calibration -> clear, and pulses
// out_valid with the decision.
// =============================================================================
`timescale 1ns/1ps
module neuroedge_top (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,
    input  wire [2:0]         in_ch,
    input  wire signed [15:0] in_data,
    input  wire               win_active,
    input  wire               trial_end,
    output wire               ready,
    output reg                out_valid,
    output reg                out_decision,     // 1 = right hand, 0 = left hand
    output reg  signed [47:0] out_score,
    output reg                out_drift,        // drift detected, burst started
    output reg                out_recal,        // on-chip recalibration ran
    output wire [7:0]         out_k,
    output wire [31:0]        event_count,
    output wire [31:0]        mac_count
);
    localparam [2:0] T_IDLE = 3'd0, T_FLUSH = 3'd1, T_BACK = 3'd2, T_DRIFT = 3'd3,
                     T_CAL = 3'd4, T_REF = 3'd5, T_CLR = 3'd6;

    // ---------------- front end
    wire               f_valid;
    wire [2:0]         f_ch;
    wire signed [15:0] f_data;
    iir_bandpass u_iir (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ch(in_ch), .in_data(in_data),
        .out_valid(f_valid), .out_ch(f_ch), .out_data(f_data));

    wire               e_valid, e_fire;
    wire [2:0]         e_ch;
    wire signed [15:0] e_value;
    wire [2:0]         m_addr;
    wire [23:0]        m_data;
    event_encoder u_enc (
        .clk(clk), .rst(rst),
        .in_valid(f_valid), .in_ch(f_ch), .in_data(f_data),
        .out_valid(e_valid), .out_ch(e_ch), .out_fire(e_fire), .out_value(e_value),
        .m_addr(m_addr), .m_data(m_data));

    reg  frame_active, inflight;
    reg  cov_flush, cov_clear;
    wire cov_busy, frame_done, flush_done;
    wire [5:0]         r_addr_be, r_addr_ns;
    reg  [2:0]         tst;
    wire [5:0]         r_addr = (tst == T_CAL) ? r_addr_ns : r_addr_be;
    wire signed [47:0] r_data;
    event_cov u_cov (
        .clk(clk), .rst(rst),
        .ev_valid(e_valid), .ev_ch(e_ch), .ev_fire(e_fire), .ev_value(e_value),
        .active(frame_active), .flush(cov_flush), .clear(cov_clear),
        .busy(cov_busy), .frame_done(frame_done), .flush_done(flush_done),
        .rd_addr(r_addr), .rd_data(r_data),
        .mac_count(mac_count), .event_count(event_count));

    // ---------------- back end and calibration
    reg  be_start, dm_start, dm_update, ns_start;
    wire be_done, be_decision, dm_done, dm_drift;
    wire ns_done, ns_recal, ns_bstart, ns_bend, ns_busy;
    wire signed [47:0] be_score;
    wire [5:0]         g_addr;
    wire signed [23:0] g_data;

    backend u_be (
        .clk(clk), .rst(rst), .start(be_start), .k_in(out_k),
        .r_addr(r_addr_be), .r_data(r_data), .g_addr(g_addr), .g_data(g_data),
        .done(be_done), .decision(be_decision), .score(be_score));

    drift_monitor u_dm (
        .clk(clk), .rst(rst), .start(dm_start), .update_ref(dm_update),
        .m_addr(m_addr), .m_data(m_data), .done(dm_done), .drift(dm_drift));

    ns_calib u_ns (
        .clk(clk), .rst(rst), .start(ns_start), .drift_in(dm_drift),
        .r_addr(r_addr_ns), .r_data(r_data), .g_addr(g_addr), .g_data(g_data),
        .k_out(out_k), .done(ns_done), .recal(ns_recal),
        .burst_start(ns_bstart), .burst_end(ns_bend), .busy(ns_busy));

    assign ready = (tst == T_IDLE) && !inflight && !cov_busy;

    reg dec_r;
    reg signed [47:0] score_r;

    always @(posedge clk) begin
        cov_flush <= 1'b0; cov_clear <= 1'b0;
        be_start <= 1'b0; dm_start <= 1'b0; dm_update <= 1'b0; ns_start <= 1'b0;
        out_valid <= 1'b0;
        if (rst) begin
            tst <= T_IDLE; frame_active <= 1'b0; inflight <= 1'b0;
            dec_r <= 1'b0; score_r <= 0;
            out_decision <= 1'b0; out_score <= 0; out_drift <= 1'b0; out_recal <= 1'b0;
        end else begin
            // a frame is in flight from its channel-7 sample until event_cov finishes it
            if (in_valid && in_ch == 3'd7) begin
                frame_active <= win_active;
                inflight     <= 1'b1;
            end else if (frame_done) begin
                inflight <= 1'b0;
            end

            case (tst)
            T_IDLE:  if (trial_end && !inflight && !cov_busy) begin
                         cov_flush <= 1'b1; tst <= T_FLUSH;
                     end
            T_FLUSH: if (flush_done) begin be_start <= 1'b1; tst <= T_BACK; end
            T_BACK:  if (be_done) begin
                         dec_r <= be_decision; score_r <= be_score;
                         dm_start <= 1'b1; tst <= T_DRIFT;
                     end
            T_DRIFT: if (dm_done) begin ns_start <= 1'b1; tst <= T_CAL; end
            T_CAL:   if (ns_done) begin
                         if (ns_bend) begin dm_update <= 1'b1; tst <= T_REF; end
                         else tst <= T_CLR;
                     end
            T_REF:   if (dm_done) tst <= T_CLR;
            T_CLR: begin
                cov_clear    <= 1'b1;
                out_valid    <= 1'b1;
                out_decision <= dec_r;
                out_score    <= score_r;
                out_drift    <= ns_bstart;
                out_recal    <= ns_recal;
                tst          <= T_IDLE;
            end
            default: tst <= T_IDLE;
            endcase
        end
    end
endmodule
