// tb_ns.v -- ns_calib vs python model (vectors from 06_hardware_model.py)
// Forces a drift at trial 0, feeds 16 trial covariances, and checks the
// recalibrations at trials 1, 2, 4, 8, 16 of the burst (scale k and all 48 G values).
`timescale 1ns/1ps
module tb_ns;
    localparam integer TRIALS = 16, N_RECAL = 5;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst = 1'b1, start = 1'b0, drift_in = 1'b0;
    reg  [5:0]  g_addr = 6'd0;
    wire [5:0]  r_addr;
    wire signed [23:0] g_data;
    wire [7:0]  k_out;
    wire        done, recal, burst_start, burst_end, busy;

    reg [47:0] rmem [0:TRIALS*64-1];
    reg [7:0]  kexp [0:N_RECAL-1];
    reg [23:0] gexp [0:N_RECAL*48-1];
    integer    t, i, rc, errors, cycles;
    wire signed [47:0] r_data = rmem[t * 64 + r_addr];

    ns_calib dut (.clk(clk), .rst(rst), .start(start), .drift_in(drift_in),
                  .r_addr(r_addr), .r_data(r_data), .g_addr(g_addr), .g_data(g_data),
                  .k_out(k_out), .done(done), .recal(recal), .burst_start(burst_start),
                  .burst_end(burst_end), .busy(busy));

    initial begin
        $readmemh("../vectors/ns_R.hex", rmem);
        $readmemh("../vectors/ns_k.hex", kexp);
        $readmemh("../vectors/ns_g.hex", gexp);
        errors = 0; rc = 0; t = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        for (t = 0; t < TRIALS; t = t + 1) begin
            @(negedge clk);
            start = 1'b1; drift_in = (t == 0);
            @(negedge clk);
            start = 1'b0;
            cycles = 1;
            while (!done) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (recal) begin
                if (rc >= N_RECAL) begin
                    errors = errors + 1;
                    $display("  unexpected recalibration at trial %0d", t);
                end else begin
                    if (k_out !== kexp[rc]) begin
                        errors = errors + 1;
                        $display("  recal %0d: k = %0d, expected %0d", rc, k_out, kexp[rc]);
                    end
                    for (i = 0; i < 48; i = i + 1) begin
                        g_addr = i;
                        #1;
                        if (g_data !== $signed(gexp[rc * 48 + i])) begin
                            errors = errors + 1;
                            if (errors <= 10)
                                $display("  recal %0d G[%0d]: got %0d expected %0d",
                                         rc, i, g_data, $signed(gexp[rc * 48 + i]));
                        end
                    end
                    $display("  trial %0d: recalibrated (k = %0d) in %0d cycles", t, k_out, cycles);
                end
                rc = rc + 1;
            end
        end
        if (rc != N_RECAL) begin
            errors = errors + 1;
            $display("  %0d recalibrations, expected %0d", rc, N_RECAL);
        end
        if (errors == 0) $display("PASS tb_ns: %0d Newton-Schulz recalibrations match exactly", rc);
        else             $display("FAIL tb_ns: %0d errors", errors);
        $finish;
    end
endmodule
