`timescale 1ns/1ps

// AXI-stream Blackman-Harris multiplier.  Vivado infers the 24 x 32768
// single-port coefficient ROM as block RAM from the deterministic MEM file.
module blackman_harris_window (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input  wire         aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    input  wire         aresetn,
    input  wire signed [23:0] frame_mean_q8,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [23:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire         s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire         s_axis_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output reg  [47:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg          m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire         m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output reg          m_axis_tlast
);

    reg [15:0] sample_index;
    (* rom_style = "block" *) reg [23:0] coefficient_rom [0:32767];
    reg signed [23:0] coefficient_data;
    reg signed [23:0] pending_sample;
    reg               pending_valid;
    reg               pending_last;

    wire advance = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = advance;
    initial $readmemh("blackman_harris_half.mem", coefficient_rom);

    wire [15:0] symmetric_index =
        sample_index[15] ? (16'hFFFF - sample_index) : sample_index;

    wire signed [47:0] product =
        $signed(pending_sample) * $signed(coefficient_data);
    wire signed [48:0] rounded_product =
        $signed({product[47], product}) +
        49'sd4194304;
    wire signed [25:0] scaled_product = rounded_product >>> 23;
    reg  signed [23:0] saturated_product;

    always @(*) begin
        if (scaled_product > 26'sd8388607)
            saturated_product = 24'sh7FFFFF;
        else if (scaled_product < -26'sd8388608)
            saturated_product = 24'sh800000;
        else
            saturated_product = scaled_product[23:0];
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            sample_index    <= 16'd0;
            pending_sample  <= 24'sd0;
            pending_valid   <= 1'b0;
            pending_last    <= 1'b0;
            coefficient_data <= 24'sd0;
            m_axis_tdata    <= 48'd0;
            m_axis_tvalid   <= 1'b0;
            m_axis_tlast    <= 1'b0;
        end else if (advance) begin
            m_axis_tvalid <= pending_valid;
            m_axis_tlast  <= pending_last;
            if (pending_valid) begin
                m_axis_tdata <= {24'd0, saturated_product};
            end

            pending_valid <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                pending_sample <=
                    $signed(s_axis_tdata) - $signed(frame_mean_q8);
                pending_last <= s_axis_tlast;
                coefficient_data <= coefficient_rom[symmetric_index[14:0]];
                if (s_axis_tlast)
                    sample_index <= 16'd0;
                else
                    sample_index <= sample_index + 1'b1;
            end else begin
                pending_last <= 1'b0;
            end
        end
    end

endmodule
