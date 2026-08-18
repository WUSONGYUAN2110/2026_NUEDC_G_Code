`timescale 1ns/1ps

module tb_ltc2208_b_frontend;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [15:0] adc_data = 16'h8000;
    reg ready = 1'b1;
    wire adc_clk;
    wire [23:0] data;
    wire valid;
    wire [31:0] clip_count;
    wire [31:0] jump_count;
    wire [31:0] saturation_max;
    wire [15:0] raw_min;
    wire [15:0] raw_max;
    wire stall;

    always #10 clk = ~clk;

    ltc2208_b_frontend dut (
        .adc_drive_clk(clk),
        .sample_clk(clk),
        .sample_reset(reset),
        .adc_b_data(adc_data),
        .adc_b_clk(adc_clk),
        .m_axis_tdata(data),
        .m_axis_tvalid(valid),
        .m_axis_tready(ready),
        .clip_count_total(clip_count),
        .jump_count_total(jump_count),
        .saturation_run_max(saturation_max),
        .raw_min_code(raw_min),
        .raw_max_code(raw_max),
        .input_stall_sticky(stall)
    );

    task drive_and_expect(
        input [15:0] raw,
        input signed [23:0] expected
    );
        begin
            @(negedge clk);
            adc_data = raw;
            @(posedge clk);
            #1;
            if (!valid || $signed(data) !== expected) begin
                $fatal(1,
                    "front-end data mismatch: got=%0d expected=%0d valid=%0b",
                    $signed(data), expected, valid);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset <= 1'b0;
        repeat (3) @(posedge clk);

        drive_and_expect(16'h8000, 24'sd0);
        drive_and_expect(16'h8001, 24'sd256);
        drive_and_expect(16'h7FFF, -24'sd256);

        @(negedge clk);
        adc_data = 16'hFFFF;
        repeat (5) @(posedge clk);
        if (clip_count == 0 || saturation_max < 2) begin
            $fatal(1, "clip monitoring failed count=%0d run=%0d",
                   clip_count, saturation_max);
        end

        ready <= 1'b0;
        repeat (2) @(posedge clk);
        ready <= 1'b1;
        @(posedge clk);
        if (!stall) begin
            $fatal(1, "input stall flag was not latched");
        end

        $display("TEST_PASS");
        $finish;
    end
endmodule
