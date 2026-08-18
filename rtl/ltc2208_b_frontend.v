`timescale 1ns/1ps

// Fixed hardware front end for channel B of the competition ADC board:
// full-rate CMOS, offset binary, RAND disabled, PGA=0, DITH enabled.
module ltc2208_b_frontend #(
    parameter integer CLIP_MARGIN_CODES = 32,
    parameter integer JUMP_THRESHOLD_CODES = 8192
) (
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 50000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 adc_drive_clk CLK" *)
    input  wire         adc_drive_clk,
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, FREQ_HZ 50000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 sample_clk CLK" *)
    input  wire         sample_clk,
    input  wire         sample_reset,
    input  wire [15:0]  adc_b_data,
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 50000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 adc_b_clk CLK" *)
    output wire         adc_b_clk,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [23:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire         m_axis_tready,

    output reg  [31:0]  clip_count_total,
    output reg  [31:0]  jump_count_total,
    output reg  [31:0]  saturation_run_max,
    output reg  [15:0]  raw_min_code,
    output reg  [15:0]  raw_max_code,
    output reg          input_stall_sticky
);

    wire [15:0] sample_data;
    wire        sample_valid;
    wire        unused_a_clk;
    wire [15:0] unused_a_data;
    wire        unused_a_valid;

    ltc2208_driver #(
        .DATA_WIDTH(16),
        .ENABLE_CHANNEL_A(0),
        .ENABLE_CHANNEL_B(1)
    ) u_driver (
        .adc_drive_clk(adc_drive_clk),
        .sample_clk(sample_clk),
        .sample_reset(sample_reset),
        .adc_a_data(16'd0),
        .adc_a_clk(unused_a_clk),
        .sample_a_data(unused_a_data),
        .sample_a_valid(unused_a_valid),
        .adc_b_data(adc_b_data),
        .adc_b_clk(adc_b_clk),
        .sample_b_data(sample_data),
        .sample_b_valid(sample_valid)
    );

    // Offset binary to two's complement, followed by exact Q8 scaling.
    wire signed [15:0] signed_code =
        $signed({~sample_data[15], sample_data[14:0]});
    assign m_axis_tdata  = {signed_code, 8'b0};
    assign m_axis_tvalid = sample_valid;

    reg signed [15:0] previous_code;
    reg               previous_valid;
    reg [31:0]        saturation_run;

    wire signed [16:0] delta =
        $signed({signed_code[15], signed_code}) -
        $signed({previous_code[15], previous_code});
    wire [16:0] abs_delta = delta[16] ? $unsigned(-delta) : $unsigned(delta);
    wire clipped =
        (signed_code >= (32767 - CLIP_MARGIN_CODES)) ||
        (signed_code <= (-32768 + CLIP_MARGIN_CODES));

    always @(posedge sample_clk) begin
        if (sample_reset) begin
            clip_count_total  <= 32'd0;
            jump_count_total  <= 32'd0;
            saturation_run    <= 32'd0;
            saturation_run_max <= 32'd0;
            raw_min_code      <= 16'h7FFF;
            raw_max_code      <= 16'h8000;
            input_stall_sticky <= 1'b0;
            previous_code     <= 16'sd0;
            previous_valid    <= 1'b0;
        end else if (sample_valid) begin
            if (!m_axis_tready)
                input_stall_sticky <= 1'b1;

            if ($signed(signed_code) < $signed(raw_min_code))
                raw_min_code <= signed_code;
            if ($signed(signed_code) > $signed(raw_max_code))
                raw_max_code <= signed_code;

            if (clipped) begin
                if (clip_count_total != 32'hFFFF_FFFF)
                    clip_count_total <= clip_count_total + 1'b1;
                if (saturation_run != 32'hFFFF_FFFF)
                    saturation_run <= saturation_run + 1'b1;
                if ((saturation_run + 1'b1) > saturation_run_max)
                    saturation_run_max <= saturation_run + 1'b1;
            end else begin
                saturation_run <= 32'd0;
            end

            if (previous_valid && abs_delta > JUMP_THRESHOLD_CODES) begin
                if (jump_count_total != 32'hFFFF_FFFF)
                    jump_count_total <= jump_count_total + 1'b1;
            end
            previous_code  <= signed_code;
            previous_valid <= 1'b1;
        end
    end

endmodule
