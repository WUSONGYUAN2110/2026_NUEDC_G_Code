`timescale 1ns/1ps

// XFFT fixed forward-transform configuration.  The packet is resent after
// every reset and held until accepted.
module fft_config_source (
    input  wire        aclk,
    input  wire        aresetn,
    output wire [7:0]  m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready
);
    // Bit 0 FWD_INV=1. Transform length and BFP mode are fixed in the IP.
    assign m_axis_tdata = 8'h01;

    always @(posedge aclk) begin
        if (!aresetn)
            m_axis_tvalid <= 1'b1;
        else if (m_axis_tvalid && m_axis_tready)
            m_axis_tvalid <= 1'b0;
    end
endmodule
