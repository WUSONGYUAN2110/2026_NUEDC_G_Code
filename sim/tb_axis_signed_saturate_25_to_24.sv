`timescale 1ns/1ps

module tb_axis_signed_saturate_25_to_24;
    reg         clock;
    reg  [31:0] input_data;
    reg         input_valid;
    wire [23:0] output_data;
    wire        output_valid;

    axis_signed_saturate_25_to_24 dut (
        .aclk(clock),
        .s_axis_tdata(input_data),
        .s_axis_tvalid(input_valid),
        .m_axis_tdata(output_data),
        .m_axis_tvalid(output_valid)
    );

    task automatic check(
        input signed [24:0] sample,
        input [23:0] expected
    );
        begin
            input_data = sample;
            #1;
            if (output_data !== expected) begin
                $error(
                    "saturation mismatch input=%0d output=%0d expected=%0d",
                    sample, $signed(output_data), $signed(expected));
                $fatal(1);
            end
        end
    endtask

    initial begin
        clock = 1'b0;
        input_valid = 1'b1;
        input_data = 25'sd0;
        #1;
        if (output_valid !== 1'b1) begin
            $error("TVALID was not propagated");
            $fatal(1);
        end

        check(25'sd0, 24'sd0);
        check(25'sd100000, 24'sd100000);
        check(-25'sd100000, -24'sd100000);
        check(25'sd8388607, 24'h7F_FFFF);
        check(-25'sd8388608, 24'h80_0000);
        check(25'sd8388608, 24'h7F_FFFF);
        check(25'sd16777215, 24'h7F_FFFF);
        check(-25'sd8388609, 24'h80_0000);
        check(-25'sd16777216, 24'h80_0000);

        input_valid = 1'b0;
        #1;
        if (output_valid !== 1'b0) begin
            $error("TVALID deassertion was not propagated");
            $fatal(1);
        end

        $display("TEST_PASS");
        $finish;
    end

    always #5 clock = ~clock;
endmodule
