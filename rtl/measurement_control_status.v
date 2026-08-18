`timescale 1ns/1ps

module measurement_control_status (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [31:0] control_word,
    input  wire        mmcm_locked,
    input  wire        frame_active,
    input  wire        fft_frame_active,
    input  wire        spectrum_busy,
    input  wire        frontend_stall,
    input  wire [5:0]  fft_events,
    output wire        run,
    output wire        soft_reset,
    output wire        fft_enable,
    output wire [15:0] capture_epoch,
    output wire [31:0] status_word
);
    reg [15:0] capture_epoch_reg;
    reg        run_d;

    assign run          = control_word[0];
    assign soft_reset   = control_word[1];
    assign fft_enable   = control_word[2];
    // Present the next epoch during the RUN rising-edge cycle so both frame
    // routers latch the same new session identifier on their first sample.
    assign capture_epoch = capture_epoch_reg +
        ((run && !run_d) ? 16'd1 : 16'd0);
    assign status_word  = {
        capture_epoch,
        1'b0,
        fft_events,
        4'd0,
        spectrum_busy,
        fft_frame_active,
        frontend_stall,
        frame_active,
        mmcm_locked
    };

    always @(posedge aclk) begin
        if (!aresetn) begin
            capture_epoch_reg <= 16'd0;
            run_d             <= 1'b0;
        end else begin
            if (run && !run_d)
                capture_epoch_reg <= capture_epoch_reg + 1'b1;
            run_d <= run;
        end
    end
endmodule
