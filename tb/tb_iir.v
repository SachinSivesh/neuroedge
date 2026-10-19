// tb_iir.v -- iir_bandpass vs python bit-exact model (vectors from 02_iir_design.py)
`timescale 1ns/1ps
// Vector folder: ../vectors/ when run from sim/*.bat; an absolute path
// (written by vivado/create_project.tcl) when run inside the Vivado GUI.
`ifdef NEUROEDGE_GUI
`include "vec_path.vh"
`else
`define VEC "../vectors/"
`endif
module tb_iir;
    localparam integer FRAMES = 1000;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg               rst = 1'b1;
    reg               in_valid = 1'b0;
    reg  [2:0]        in_ch = 3'd0;
    reg  signed [15:0] in_data = 16'sd0;
    wire              out_valid;
    wire [2:0]        out_ch;
    wire signed [15:0] out_data;

    iir_bandpass dut (.clk(clk), .rst(rst), .in_valid(in_valid), .in_ch(in_ch),
                      .in_data(in_data), .out_valid(out_valid), .out_ch(out_ch),
                      .out_data(out_data));

    reg [15:0] xin  [0:FRAMES*8-1];
    reg [15:0] yexp [0:FRAMES*8-1];
    integer f, c, n_out, errors;

    initial begin
        $readmemh({`VEC, "iir_in.hex"}, xin);
        $readmemh({`VEC, "iir_out.hex"}, yexp);
        n_out = 0; errors = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        for (f = 0; f < FRAMES; f = f + 1) begin
            for (c = 0; c < 8; c = c + 1) begin
                @(negedge clk);
                in_valid = 1'b1; in_ch = c; in_data = xin[f * 8 + c];
            end
            @(negedge clk);
            in_valid = 1'b0;
            repeat (3) @(negedge clk);
        end
        repeat (10) @(negedge clk);
        if (n_out != FRAMES * 8) begin
            $display("FAIL tb_iir: got %0d outputs, expected %0d", n_out, FRAMES * 8);
        end else if (errors == 0)
            $display("PASS tb_iir: %0d samples match the Python model exactly", n_out);
        else
            $display("FAIL tb_iir: %0d mismatches out of %0d", errors, n_out);
        $finish;
    end

    always @(negedge clk) begin
        if (!rst && out_valid) begin
            if (out_data !== $signed(yexp[n_out])) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  mismatch sample %0d (ch %0d): got %0d expected %0d",
                             n_out, out_ch, out_data, $signed(yexp[n_out]));
            end
            n_out = n_out + 1;
        end
    end
endmodule
