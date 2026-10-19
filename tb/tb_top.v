// tb_top.v -- the whole NeuroEdge core vs the python model
// Streams the demo subject's first 32 day-2 trials (raw samples) through the
// core and checks every trial's decision, LDA score, drift / recalibration
// flags, event count and MAC count. (Vectors from 06_hardware_model.py.)
`timescale 1ns/1ps
// Vector folder: ../vectors/ when run from sim/*.bat; an absolute path
// (written by vivado/create_project.tcl) when run inside the Vivado GUI.
`ifdef NEUROEDGE_GUI
`include "vec_path.vh"
`else
`define VEC "../vectors/"
`endif
module tb_top;
    localparam integer TRIALS = 32, LEN = 625, WARMUP = 125;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg               rst = 1'b1, in_valid = 1'b0, win_active = 1'b0, trial_end = 1'b0;
    reg  [2:0]        in_ch = 3'd0;
    reg  signed [15:0] in_data = 16'sd0;
    wire              ready, out_valid, out_decision, out_drift, out_recal;
    wire signed [47:0] out_score;
    wire [7:0]        out_k;
    wire [31:0]       event_count, mac_count;

    neuroedge_top dut (.clk(clk), .rst(rst), .in_valid(in_valid), .in_ch(in_ch),
                       .in_data(in_data), .win_active(win_active), .trial_end(trial_end),
                       .ready(ready), .out_valid(out_valid), .out_decision(out_decision),
                       .out_score(out_score), .out_drift(out_drift), .out_recal(out_recal),
                       .out_k(out_k), .event_count(event_count), .mac_count(mac_count));

    reg [15:0] xin    [0:TRIALS*LEN*8-1];
    reg [0:0]  dexp   [0:TRIALS-1];
    reg [47:0] sexp   [0:TRIALS-1];
    reg [1:0]  fexp   [0:TRIALS-1];
    reg [31:0] eexp   [0:TRIALS-1];
    reg [31:0] mexp   [0:TRIALS-1];
    reg [0:0]  label  [0:TRIALS-1];
    integer t, f, c, errors, correct, bad;
    time t0;

    initial begin
        $readmemh({`VEC, "top_in.hex"}, xin);
        $readmemh({`VEC, "top_dec.hex"}, dexp);
        $readmemh({`VEC, "top_score.hex"}, sexp);
        $readmemh({`VEC, "top_flags.hex"}, fexp);
        $readmemh({`VEC, "top_events.hex"}, eexp);
        $readmemh({`VEC, "top_macs.hex"}, mexp);
        $readmemh({`VEC, "top_labels.hex"}, label);
        errors = 0; correct = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        $display("trial | decision (exp) | truth | drift recal | k  | events | MACs     | check");
        for (t = 0; t < TRIALS; t = t + 1) begin
            t0 = $time;
            for (f = 0; f < LEN; f = f + 1) begin
                while (!ready) @(negedge clk);
                for (c = 0; c < 8; c = c + 1) begin
                    @(negedge clk);
                    in_valid = 1'b1; in_ch = c; in_data = xin[(t * LEN + f) * 8 + c];
                    win_active = (f >= WARMUP);
                end
                @(negedge clk);
                in_valid = 1'b0;
            end
            while (!ready) @(negedge clk);
            trial_end = 1'b1;
            @(negedge clk);
            trial_end = 1'b0;
            while (!out_valid) @(negedge clk);
            bad = 0;
            if (out_decision !== dexp[t][0])            bad = bad + 1;
            if (out_score    !== $signed(sexp[t]))       bad = bad + 1;
            if ({out_drift, out_recal} !== fexp[t])      bad = bad + 1;
            if (event_count  !== eexp[t])                bad = bad + 1;
            if (mac_count    !== mexp[t])                bad = bad + 1;
            errors  = errors + bad;
            correct = correct + (out_decision == label[t][0]);
            $display("%5d |   %s  (%s)   | %s |   %0d     %0d   | %2d | %6d | %8d | %s",
                     t, out_decision ? "RIGHT" : "LEFT ", dexp[t][0] ? "RIGHT" : "LEFT ",
                     label[t][0] ? "RIGHT" : "LEFT ", out_drift, out_recal, out_k,
                     event_count, mac_count, bad == 0 ? "ok" : "MISMATCH");
            if (out_score !== $signed(sexp[t]))
                $display("      score %0d, expected %0d", out_score, $signed(sexp[t]));
            if (event_count !== eexp[t] || mac_count !== mexp[t])
                $display("      expected events %0d, MACs %0d", eexp[t], mexp[t]);
        end
        $display("Accuracy on these %0d trials: %0d/%0d", TRIALS, correct, TRIALS);
        if (errors == 0) $display("PASS tb_top: every trial matches the Python model exactly");
        else             $display("FAIL tb_top: %0d mismatches", errors);
        $finish;
    end
endmodule
