`timescale 1ns/1ps
`include "measurement_defs.svh"

// Consumes a complete natural-order complex FFT, forwards only non-negative
// bins, then appends fixed metadata.  The negative-frequency half is drained
// without applying backpressure to the FFT.
module fft_spectrum_packer (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:s_status:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input  wire         aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    input  wire         aresetn,
    input  wire         soft_reset,

    input  wire         frame_start,
    input  wire [31:0]  frame_id,
    input  wire [15:0]  frame_epoch,
    input  wire signed [23:0] frame_mean_q8,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [47:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire         s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire         s_axis_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_status TDATA" *)
    input  wire [7:0]   s_status_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_status TVALID" *)
    input  wire         s_status_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_status TREADY" *)
    output wire         s_status_tready,
    input  wire [5:0]   fft_events,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output reg  [63:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg          m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire         m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output reg          m_axis_tlast,
    output wire         busy
);

    localparam STATE_DATA    = 1'b0;
    localparam STATE_TRAILER = 1'b1;
    reg state;
    reg [15:0] bin_index;
    reg [3:0] trailer_index;
    reg [7:0] block_exponent;
    reg [5:0] latched_events;

    reg [31:0] id_fifo [0:3];
    reg [15:0] epoch_fifo [0:3];
    reg signed [23:0] mean_fifo [0:3];
    reg [1:0] fifo_wr_ptr;
    reg [1:0] fifo_rd_ptr;
    reg [2:0] fifo_count;
    reg [31:0] active_frame_id;
    reg [15:0] active_epoch;
    reg signed [23:0] active_mean_q8;
    reg output_active;

    wire positive_bin = (bin_index <= 16'd32768);
    wire pop_frame =
        state == STATE_DATA && s_axis_tvalid && s_axis_tready &&
        bin_index == 0 && fifo_count != 0;
    wire push_frame =
        frame_start && (fifo_count < 4 || pop_frame);
    assign s_axis_tready =
        (state == STATE_DATA) ?
            (positive_bin ? m_axis_tready : 1'b1) : 1'b0;
    assign s_status_tready = 1'b1;
    assign busy = (fifo_count != 0) || output_active ||
        (state == STATE_TRAILER);

    function automatic [63:0] trailer_beat;
        input [3:0] index;
        begin
            case (index)
                4'd0: trailer_beat = {`MEAS_FORMAT_VERSION, `MEAS_SPECTRUM_MAGIC};
                4'd1: trailer_beat = {32'd0, active_frame_id};
                4'd2: trailer_beat = {32'd0, 16'd0, 16'd32769};
                4'd3: trailer_beat = {48'd0, latched_events, 2'd0, block_exponent};
                4'd4: trailer_beat = {{40{active_mean_q8[23]}}, active_mean_q8};
                4'd5: trailer_beat = active_frame_id == 0 ? 64'h20 : 64'd0;
                4'd6: trailer_beat = {48'd0, active_epoch};
                4'd7: trailer_beat = {
                    (`MEAS_SPECTRUM_MAGIC ^ active_frame_id), active_frame_id
                };
                default: trailer_beat = 64'd0;
            endcase
        end
    endfunction

    always @(*) begin
        m_axis_tdata  = 64'd0;
        m_axis_tvalid = 1'b0;
        m_axis_tlast  = 1'b0;
        if (state == STATE_DATA && positive_bin) begin
            m_axis_tdata  = {
                {{8{s_axis_tdata[47]}}, s_axis_tdata[47:24]},
                {{8{s_axis_tdata[23]}}, s_axis_tdata[23:0]}
            };
            m_axis_tvalid = s_axis_tvalid;
        end else if (state == STATE_TRAILER) begin
            m_axis_tdata  = trailer_beat(trailer_index);
            m_axis_tvalid = 1'b1;
            m_axis_tlast  =
                (trailer_index == (`MEAS_SPECTRUM_TRAILER_BEATS - 1));
        end
    end

    always @(posedge aclk) begin
        if (!aresetn || soft_reset) begin
            state            <= STATE_DATA;
            bin_index        <= 16'd0;
            trailer_index    <= 4'd0;
            block_exponent   <= 8'd0;
            latched_events   <= 6'd0;
            fifo_wr_ptr      <= 2'd0;
            fifo_rd_ptr      <= 2'd0;
            fifo_count       <= 3'd0;
            active_frame_id  <= 32'd0;
            active_epoch     <= 16'd0;
            active_mean_q8   <= 24'sd0;
            output_active    <= 1'b0;
        end else begin
            if (push_frame) begin
                id_fifo[fifo_wr_ptr]   <= frame_id;
                epoch_fifo[fifo_wr_ptr] <= frame_epoch;
                mean_fifo[fifo_wr_ptr] <= frame_mean_q8;
                fifo_wr_ptr            <= fifo_wr_ptr + 1'b1;
            end

            if (s_status_tvalid)
                block_exponent <= s_status_tdata;
            latched_events <= latched_events | fft_events;

            if (state == STATE_DATA && s_axis_tvalid && s_axis_tready) begin
                if (pop_frame) begin
                    active_frame_id <= id_fifo[fifo_rd_ptr];
                    active_epoch    <= epoch_fifo[fifo_rd_ptr];
                    active_mean_q8  <= mean_fifo[fifo_rd_ptr];
                    fifo_rd_ptr     <= fifo_rd_ptr + 1'b1;
                    latched_events  <= fft_events;
                    output_active   <= 1'b1;
                end
                if (s_axis_tlast) begin
                    state         <= STATE_TRAILER;
                    trailer_index <= 4'd0;
                    bin_index     <= 16'd0;
                end else begin
                    bin_index <= bin_index + 1'b1;
                end
            end else if (state == STATE_TRAILER && m_axis_tready) begin
                if (trailer_index == (`MEAS_SPECTRUM_TRAILER_BEATS - 1)) begin
                    state         <= STATE_DATA;
                    trailer_index <= 4'd0;
                    output_active <= 1'b0;
                end else begin
                    trailer_index <= trailer_index + 1'b1;
                end
            end

            case ({push_frame, pop_frame})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

endmodule
