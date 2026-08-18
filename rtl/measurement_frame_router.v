`timescale 1ns/1ps
`include "measurement_defs.svh"

// Builds independently DMA-able records.  Samples precede a fixed trailer so
// the DMA payload remains directly usable as a signed sample array.
module measurement_frame_router (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_time:m_fft, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input  wire         aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    input  wire         aresetn,
    input  wire         run,
    input  wire         soft_reset,
    input  wire         fft_enable,
    input  wire [15:0]  capture_epoch,
    input  wire         mmcm_locked,
    input  wire         frontend_stall,
    input  wire [31:0]  clip_count_total,
    input  wire [31:0]  jump_count_total,
    input  wire [31:0]  saturation_run_max,
    input  wire [15:0]  raw_min_code,
    input  wire [15:0]  raw_max_code,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [23:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire         s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_time TDATA" *)
    output reg  [31:0]  m_time_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_time TVALID" *)
    output reg          m_time_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_time TREADY" *)
    input  wire         m_time_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_time TLAST" *)
    output reg          m_time_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_fft TDATA" *)
    output wire [23:0]  m_fft_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_fft TVALID" *)
    output wire         m_fft_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_fft TREADY" *)
    input  wire         m_fft_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_fft TLAST" *)
    output wire         m_fft_tlast,
    output reg  signed [23:0] fft_mean_q8,
    output reg          fft_frame_start,
    output reg  [31:0]  fft_frame_id,
    output reg  [15:0]  fft_frame_epoch,
    output reg          frame_active,
    output reg  [31:0]  current_frame_id
);

    localparam STATE_IDLE    = 2'd0;
    localparam STATE_SAMPLES = 2'd1;
    localparam STATE_TRAILER = 2'd2;

    reg [1:0]  state;
    reg [18:0] sample_index;
    reg [4:0]  trailer_index;
    reg signed [55:0] sample_sum;
    reg [31:0] clip_start;
    reg [31:0] jump_start;
    reg [31:0] clip_delta;
    reg [31:0] jump_delta;
    reg [31:0] latched_status;
    reg [31:0] latched_sample_count;
    reg signed [23:0] latched_mean_q8;
    reg signed [15:0] frame_raw_min;
    reg signed [15:0] frame_raw_max;
    reg signed [15:0] latched_raw_min;
    reg signed [15:0] latched_raw_max;
    reg               frame_use_fft;
    reg [15:0]        latched_epoch;

    wire sample_outputs_ready =
        m_time_tready && (!frame_use_fft || m_fft_tready);
    wire sample_transfer =
        (state == STATE_SAMPLES) && s_axis_tvalid && sample_outputs_ready;
    wire signed [23:0] signed_sample = $signed(s_axis_tdata);
    wire signed [15:0] raw_sample = $signed(s_axis_tdata[23:8]);
    wire signed [15:0] min_with_sample =
        raw_sample < frame_raw_min ? raw_sample : frame_raw_min;
    wire signed [15:0] max_with_sample =
        raw_sample > frame_raw_max ? raw_sample : frame_raw_max;
    wire signed [55:0] sum_with_sample =
        sample_sum + {{32{signed_sample[23]}}, signed_sample};

    assign s_axis_tready =
        (state == STATE_IDLE) ? 1'b1 :
        (state == STATE_SAMPLES) ? sample_outputs_ready : 1'b0;

    assign m_fft_tdata  = s_axis_tdata;
    assign m_fft_tvalid = (state == STATE_SAMPLES) && frame_use_fft &&
                          s_axis_tvalid && m_time_tready;
    assign m_fft_tlast  = m_fft_tvalid &&
                          (sample_index == (`MEAS_SHORT_SAMPLES - 1));

    function automatic [31:0] trailer_word;
        input [4:0] index;
        begin
            case (index)
                5'd0: trailer_word = `MEAS_TIME_MAGIC;
                5'd1: trailer_word = `MEAS_FORMAT_VERSION;
                5'd2: trailer_word = current_frame_id;
                5'd3: trailer_word = latched_sample_count;
                5'd4: trailer_word = latched_status;
                5'd5: trailer_word = clip_delta;
                5'd6: trailer_word = jump_delta;
                5'd7: trailer_word = saturation_run_max;
                5'd8: trailer_word = {latched_raw_max, latched_raw_min};
                5'd9: trailer_word = {{8{latched_mean_q8[23]}}, latched_mean_q8};
                5'd10: trailer_word = {16'd0, latched_epoch};
                5'd15: trailer_word = (`MEAS_TIME_MAGIC ^ current_frame_id);
                default: trailer_word = 32'd0;
            endcase
        end
    endfunction

    always @(*) begin
        m_time_tdata  = 32'd0;
        m_time_tvalid = 1'b0;
        m_time_tlast  = 1'b0;
        if (state == STATE_SAMPLES) begin
            m_time_tdata  = {{8{s_axis_tdata[23]}}, s_axis_tdata};
            m_time_tvalid =
                s_axis_tvalid && (!frame_use_fft || m_fft_tready);
        end else if (state == STATE_TRAILER) begin
            m_time_tdata  = trailer_word(trailer_index);
            m_time_tvalid = 1'b1;
            m_time_tlast  = (trailer_index == (`MEAS_TRAILER_WORDS - 1));
        end
    end

    always @(posedge aclk) begin
        if (!aresetn || soft_reset) begin
            state                <= STATE_IDLE;
            sample_index         <= 19'd0;
            trailer_index        <= 5'd0;
            sample_sum           <= 56'sd0;
            clip_start           <= 32'd0;
            jump_start           <= 32'd0;
            clip_delta           <= 32'd0;
            jump_delta           <= 32'd0;
            latched_status       <= 32'd0;
            latched_sample_count <= 32'd0;
            latched_mean_q8      <= 24'sd0;
            frame_raw_min        <= 16'sh7FFF;
            frame_raw_max        <= 16'sh8000;
            latched_raw_min      <= 16'sd0;
            latched_raw_max      <= 16'sd0;
            fft_mean_q8          <= 24'sd0;
            fft_frame_start      <= 1'b0;
            fft_frame_id         <= 32'd0;
            fft_frame_epoch      <= 16'd0;
            frame_active         <= 1'b0;
            current_frame_id     <= 32'd0;
            frame_use_fft        <= 1'b0;
            latched_epoch        <= 16'd0;
        end else begin
            fft_frame_start <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    frame_active <= 1'b0;
                    if (run) begin
                        state        <= STATE_SAMPLES;
                        sample_index <= 19'd0;
                        sample_sum   <= 56'sd0;
                        clip_start   <= clip_count_total;
                        jump_start   <= jump_count_total;
                        frame_raw_min <= 16'sh7FFF;
                        frame_raw_max <= 16'sh8000;
                        frame_active <= 1'b1;
                        frame_use_fft <= fft_enable;
                        latched_epoch <= capture_epoch;
                    end
                end

                STATE_SAMPLES: begin
                    if (sample_transfer) begin
                        if (sample_index == 0 && frame_use_fft) begin
                            fft_frame_start <= 1'b1;
                            fft_frame_id    <= current_frame_id;
                            fft_frame_epoch <= latched_epoch;
                        end
                        sample_sum <= sum_with_sample;
                        frame_raw_min <= min_with_sample;
                        frame_raw_max <= max_with_sample;
                        if (sample_index == (`MEAS_SHORT_SAMPLES - 1)) begin
                            latched_sample_count <= `MEAS_SHORT_SAMPLES;
                            latched_status <= {
                                28'd0,
                                1'b0,
                                frontend_stall,
                                frame_active,
                                mmcm_locked
                            };
                            clip_delta <= clip_count_total - clip_start;
                            jump_delta <= jump_count_total - jump_start;
                            latched_raw_min <= min_with_sample;
                            latched_raw_max <= max_with_sample;
                            latched_mean_q8 <= sum_with_sample >>> 16;
                            fft_mean_q8     <= sum_with_sample >>> 16;
                            state         <= STATE_TRAILER;
                            trailer_index <= 5'd0;
                        end else begin
                            sample_index <= sample_index + 1'b1;
                        end
                    end
                end

                STATE_TRAILER: begin
                    if (m_time_tready) begin
                        if (trailer_index == (`MEAS_TRAILER_WORDS - 1)) begin
                            current_frame_id <= current_frame_id + 1'b1;
                            if (run) begin
                                state        <= STATE_SAMPLES;
                                sample_index <= 19'd0;
                                sample_sum   <= 56'sd0;
                                clip_start   <= clip_count_total;
                                jump_start   <= jump_count_total;
                                frame_raw_min <= 16'sh7FFF;
                                frame_raw_max <= 16'sh8000;
                                frame_active <= 1'b1;
                                frame_use_fft <= fft_enable;
                                latched_epoch <= capture_epoch;
                            end else begin
                                state        <= STATE_IDLE;
                                frame_active <= 1'b0;
                            end
                        end else begin
                            trailer_index <= trailer_index + 1'b1;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
