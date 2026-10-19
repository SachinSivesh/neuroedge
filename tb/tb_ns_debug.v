// tb_ns_debug.v -- prints ns_calib's internal matrices during the first
// recalibration so they can be compared with the Python model.
// Expected first rows (subject 3, day-2 trial 0):
//   rsum row0 3133824 2246354 2622894 2686255 2230846 2205180 2450096 2202450
//   Y0 (after INIT) 48966 35099 40982 41972 34856 34455 38282 34413
//   P0 (Sm, op0)    48966 35099 40982 41972 34856 34455 38282 34413
//   T0              1548381 -17550 -20491 -20986 -17428 -17228 -19141 -17207
//   Y1              67668 47304 55709 56937 46718 46084 51817 46110
//   Z1              1548381 -17550 -20491 -20986 -17428 -17228 -19141 -17207
`timescale 1ns/1ps
`ifdef NEUROEDGE_GUI
`include "vec_path.vh"
`else
`define VEC "../vectors/"
`endif
module tb_ns_debug;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg         rst = 1'b1, start = 1'b0, drift_in = 1'b0;
    wire [5:0]  r_addr;
    wire signed [23:0] g_data;
    wire [7:0]  k_out;
    wire        done, recal, burst_start, burst_end, busy;
    reg [47:0] rmem [0:16*64-1];
    wire signed [47:0] r_data = rmem[r_addr];

    ns_calib dut (.clk(clk), .rst(rst), .start(start), .drift_in(drift_in),
                  .r_addr(r_addr), .r_data(r_data), .g_addr(6'd0), .g_data(g_data),
                  .k_out(k_out), .done(done), .recal(recal), .burst_start(burst_start),
                  .burst_end(burst_end), .busy(busy));

    task show; input [8*6-1:0] name; input integer which; integer j; begin
        $write("%s", name);
        for (j = 0; j < 8; j = j + 1) begin
            case (which)
                0: $write(" %0d", dut.rsum[j]);
                1: $write(" %0d", dut.Y[j]);
                2: $write(" %0d", dut.Sm[j]);
                3: $write(" %0d", dut.T[j]);
                default: $write(" %0d", dut.Z[j]);
            endcase
        end
        $write("\n");
    end endtask

    reg [3:0] st_prev;
    integer n_mm, n_copy;
    initial begin
        $readmemh({`VEC, "ns_R.hex"}, rmem);
        n_mm = 0; n_copy = 0; st_prev = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk); start = 1'b1; drift_in = 1'b1;
        @(negedge clk); start = 1'b0;
        $display("k_after_trace (shown at INIT): watch below");
    end

    // print at state changes (sampled on the falling edge, after updates settle)
    always @(negedge clk) if (!rst) begin
        if (dut.st != st_prev) begin
            if (dut.st == 4'd5)
                $display("C_INIT: lg=%0d trace=%0d k_new=%0d sh=%0d", dut.lg, dut.trace, dut.k_new, dut.sh);
            if (st_prev == 4'd5 && dut.st == 4'd6) begin show("rsum  ", 0); show("Y0    ", 1); show("Z0    ", 4); end
            if (st_prev == 4'd6 && dut.st == 4'd7) show("P0    ", 2);
            if (st_prev == 4'd7 && dut.st == 4'd6) show("T0    ", 3);
            if (st_prev == 4'd8 && dut.st == 4'd6) begin
                n_copy = n_copy + 1;
                if (n_copy == 1) show("Y1    ", 1);
                if (n_copy == 2) begin show("Z1    ", 4); $display("debug done"); $finish; end
            end
        end
        st_prev = dut.st;
    end
    initial begin #50000000; $display("timeout"); $finish; end
endmodule
