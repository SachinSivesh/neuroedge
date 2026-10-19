// tb_encoder.v -- event_encoder vs python model (vectors from 06_hardware_model.py)
// Input: filtered samples of the demo subject's first 2 day-2 trials.
`timescale 1ns/1ps
module tb_encoder;
    localparam integer FRAMES = 2 * 625;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg               rst = 1'b1;
    reg               in_valid = 1'b0;
    reg  [2:0]        in_ch = 3'd0;
    reg  signed [15:0] in_data = 16'sd0;
    wire              out_valid, out_fire;
    wire [2:0]        out_ch;
    wire signed [15:0] out_value;
    wire [23:0]       m_data;

    event_encoder dut (.clk(clk), .rst(rst), .in_valid(in_valid), .in_ch(in_ch),
                       .in_data(in_data), .out_valid(out_valid), .out_ch(out_ch),
                       .out_fire(out_fire), .out_value(out_value),
                       .m_addr(3'd0), .m_data(m_data));

    reg [15:0] xin   [0:FRAMES*8-1];
    reg [0:0]  fexp  [0:FRAMES*8-1];
    integer f, c, n_out, errors, n_fire;

    initial begin
        $readmemh("../vectors/enc_in.hex", xin);
        $readmemh("../vectors/enc_fire.hex", fexp);
        n_out = 0; errors = 0; n_fire = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        for (f = 0; f < FRAMES; f = f + 1) begin
            for (c = 0; c < 8; c = c + 1) begin
                @(negedge clk);
                in_valid = 1'b1; in_ch = c; in_data = xin[f * 8 + c];
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
        repeat (5) @(negedge clk);
        if (n_out != FRAMES * 8)
            $display("FAIL tb_encoder: got %0d outputs, expected %0d", n_out, FRAMES * 8);
        else if (errors == 0)
            $display("PASS tb_encoder: %0d samples, %0d events (%0d%%), all match",
                     n_out, n_fire, n_fire * 100 / n_out);
        else
            $display("FAIL tb_encoder: %0d mismatches out of %0d", errors, n_out);
        $finish;
    end

    always @(negedge clk) begin
        if (!rst && out_valid) begin
            if (out_fire !== fexp[n_out][0]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  mismatch sample %0d (ch %0d): fire %0d expected %0d",
                             n_out, out_ch, out_fire, fexp[n_out][0]);
            end
            n_fire = n_fire + out_fire;
            n_out  = n_out + 1;
        end
    end
endmodule
