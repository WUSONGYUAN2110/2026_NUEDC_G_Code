// LTC2208 双通道 CMOS 接口驱动。
// LTC2208 的固定采集范围为 2.25 Vpp，输入阻抗为 50 Ω；
// adc_a_data/adc_b_data 连接到 ADC 的并行数据输出。
// 上层提供 adc_drive_clk 和 sample_clk，本模块只负责输出 ADC 采样时钟和
// 采集数据，不改变输入时钟频率。sample_reset 为高电平复位，释放复位后，
// sample_a_data/sample_b_data 在 sample_clk 下更新，对应 valid 信号保持为 1。
// adc_a_clk/adc_b_clk 连接到 LTC2208 对应通道的 ENC+，不是 ADC 返回的
// CLKOUT。sample_clk 必须由上层选择并约束到数据眼中心；50 MHz 下推荐从
// adc_drive_clk 产生约 180 度相移的采样时钟，再通过实测相位扫描确认。
// ENABLE_CHANNEL_A/B 用于选择是否启用对应通道，未启用通道的输出保持为 0。

`timescale 1ns/1ps

module ltc2208_driver #(
    parameter integer DATA_WIDTH        = 16,
    parameter integer ENABLE_CHANNEL_A = 1,
    parameter integer ENABLE_CHANNEL_B = 1
) (
    input  wire                  adc_drive_clk,
    input  wire                  sample_clk,
    input  wire                  sample_reset,

    input  wire [DATA_WIDTH-1:0] adc_a_data,
    output wire                  adc_a_clk,
    output wire [DATA_WIDTH-1:0] sample_a_data,
    output wire                  sample_a_valid,

    input  wire [DATA_WIDTH-1:0] adc_b_data,
    output wire                  adc_b_clk,
    output wire [DATA_WIDTH-1:0] sample_b_data,
    output wire                  sample_b_valid
);

    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync = 2'b11;
    wire sample_reset_active = sample_reset | reset_sync[1];

    always @(posedge sample_clk or posedge sample_reset) begin
        if (sample_reset)
            reset_sync <= 2'b11;
        else
            reset_sync <= {reset_sync[0], 1'b0};
    end

    generate
        if (ENABLE_CHANNEL_A != 0) begin : gen_channel_a
            (* IOB = "TRUE" *) reg [DATA_WIDTH-1:0] sample_a_data_reg = {DATA_WIDTH{1'b0}};
            reg sample_a_valid_reg = 1'b0;

            ODDR #(
                .DDR_CLK_EDGE ("SAME_EDGE")
            ) u_adc_a_clk (
                .Q  (adc_a_clk),
                .C  (adc_drive_clk),
                .CE (1'b1),
                .D1 (1'b1),
                .D2 (1'b0),
                .R  (1'b0),
                .S  (1'b0)
            );

            always @(posedge sample_clk) begin
                if (sample_reset_active) begin
                    sample_a_data_reg  <= {DATA_WIDTH{1'b0}};
                    sample_a_valid_reg <= 1'b0;
                end else begin
                    sample_a_data_reg  <= adc_a_data;
                    sample_a_valid_reg <= 1'b1;
                end
            end

            assign sample_a_data  = sample_a_data_reg;
            assign sample_a_valid = sample_a_valid_reg;
        end else begin : gen_channel_a_disabled
            assign adc_a_clk      = 1'b0;
            assign sample_a_data  = {DATA_WIDTH{1'b0}};
            assign sample_a_valid = 1'b0;
        end

        if (ENABLE_CHANNEL_B != 0) begin : gen_channel_b
            (* IOB = "TRUE" *) reg [DATA_WIDTH-1:0] sample_b_data_reg = {DATA_WIDTH{1'b0}};
            reg sample_b_valid_reg = 1'b0;

            ODDR #(
                .DDR_CLK_EDGE ("SAME_EDGE")
            ) u_adc_b_clk (
                .Q  (adc_b_clk),
                .C  (adc_drive_clk),
                .CE (1'b1),
                .D1 (1'b1),
                .D2 (1'b0),
                .R  (1'b0),
                .S  (1'b0)
            );

            always @(posedge sample_clk) begin
                if (sample_reset_active) begin
                    sample_b_data_reg  <= {DATA_WIDTH{1'b0}};
                    sample_b_valid_reg <= 1'b0;
                end else begin
                    sample_b_data_reg  <= adc_b_data;
                    sample_b_valid_reg <= 1'b1;
                end
            end

            assign sample_b_data  = sample_b_data_reg;
            assign sample_b_valid = sample_b_valid_reg;
        end else begin : gen_channel_b_disabled
            assign adc_b_clk      = 1'b0;
            assign sample_b_data  = {DATA_WIDTH{1'b0}};
            assign sample_b_valid = 1'b0;
        end
    endgenerate

endmodule
