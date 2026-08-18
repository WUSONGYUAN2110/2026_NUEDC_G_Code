`timescale 1ns/1ps

// FIR Compiler produces a unity-gain signed Q8 result at 25 bits for the
// integer Q1.23 coefficient vector.  Preserve the existing 24-bit stream
// format with explicit saturation instead of truncation or wraparound.
module axis_signed_saturate_25_to_24 (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, FREQ_HZ 50000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input  wire        aclk,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [31:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire        s_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [23:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire        m_axis_tvalid
);

    localparam signed [24:0] OUTPUT_MAX = 25'sd8388607;
    localparam signed [24:0] OUTPUT_MIN = -25'sd8388608;

    wire signed [24:0] signed_input = $signed(s_axis_tdata[24:0]);
    wire [23:0] saturated_data =
        signed_input > OUTPUT_MAX ? 24'h7F_FFFF :
        signed_input < OUTPUT_MIN ? 24'h80_0000 :
        signed_input[23:0];

    assign m_axis_tdata = saturated_data;
    assign m_axis_tvalid = s_axis_tvalid;

    wire unused_aclk = aclk;

endmodule
