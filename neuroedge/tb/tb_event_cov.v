// tb_event_cov.v -- event_cov vs python model (vectors from 06_hardware_model.py)
// Feeds the encoder's (fire, value) stream for 2 trials, checks the 64
// covariance sums, the MAC count and the event count after each trial.
`timescale 1ns/1ps
module tb_event_cov;
    localparam integer TRIALS = 2, LEN = 625, WARMUP = 125;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg               rst = 1'b1;
    reg               ev_valid = 1'b0, ev_fire = 1'b0, active = 1'b0;
    reg               flush = 1'b0, clear = 1'b0;
    reg  [2:0]        ev_ch = 3'd0;
    reg  signed [15:0] ev_value = 16'sd0;
    reg  [5:0]        rd_addr = 6'd0;
    wire              busy, frame_done, flush_done;
    wire signed [47:0] rd_data;
    wire [31:0]       mac_count, event_count;

    event_cov dut (.clk(clk), .rst(rst), .ev_valid(ev_valid), .ev_ch(ev_ch),
                   .ev_fire(ev_fire), .ev_value(ev_value), .active(active),
                   .flush(flush), .clear(clear), .busy(busy), .frame_done(frame_done),
                   .flush_done(flush_done), .rd_addr(rd_addr), .rd_data(rd_data),
                   .mac_count(mac_count), .event_count(event_count));

    reg [16:0] din   [0:TRIALS*LEN*8-1];
    reg [47:0] rexp  [0:TRIALS*64-1];
    reg [31:0] mexp  [0:TRIALS-1];
    reg [31:0] eexp  [0:TRIALS-1];
    integer t, f, c, i, errors;

    initial begin
        $readmemh("../vectors/cov_in.hex", din);
        $readmemh("../vectors/cov_R.hex", rexp);
        $readmemh("../vectors/cov_macs.hex", mexp);
        $readmemh("../vectors/cov_events.hex", eexp);
        errors = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        for (t = 0; t < TRIALS; t = t + 1) begin
            for (f = 0; f < LEN; f = f + 1) begin
                while (busy) @(negedge clk);
                active = (f >= WARMUP);
                for (c = 0; c < 8; c = c + 1) begin
                    @(negedge clk);
                    ev_valid = 1'b1; ev_ch = c;
                    ev_fire  = din[(t * LEN + f) * 8 + c][16];
                    ev_value = din[(t * LEN + f) * 8 + c][15:0];
                end
                @(negedge clk);
                ev_valid = 1'b0;
            end
            while (busy) @(negedge clk);
            flush = 1'b1;
            @(negedge clk);
            flush = 1'b0;
            while (!flush_done) @(negedge clk);
            for (i = 0; i < 64; i = i + 1) begin
                rd_addr = i;
                #1;
                if (rd_data !== $signed(rexp[t * 64 + i])) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("  trial %0d R[%0d][%0d]: got %0d expected %0d",
                                 t, i / 8, i % 8, rd_data, $signed(rexp[t * 64 + i]));
                end
            end
            if (mac_count !== mexp[t] || event_count !== eexp[t]) begin
                errors = errors + 1;
                $display("  trial %0d counts: MACs %0d (exp %0d), events %0d (exp %0d)",
                         t, mac_count, mexp[t], event_count, eexp[t]);
            end
            $display("  trial %0d: %0d events, %0d MACs so far (every-sample unit: %0d)",
                     t, event_count, mac_count, (t + 1) * (LEN - WARMUP) * 36);
            @(negedge clk);
            clear = 1'b1;
            @(negedge clk);
            clear = 1'b0;
        end
        if (errors == 0) $display("PASS tb_event_cov: covariance and counters match exactly");
        else             $display("FAIL tb_event_cov: %0d errors", errors);
        $finish;
    end
endmodule
