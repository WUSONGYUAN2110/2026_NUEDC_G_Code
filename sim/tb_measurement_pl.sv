`timescale 1ns/1ps
`include "measurement_defs.svh"

module tb_measurement_pl;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg run = 1'b0;
    reg soft_reset = 1'b0;
    reg fft_enable = 1'b1;

    reg [23:0] sample_data = 24'd0;
    reg sample_valid = 1'b0;
    wire sample_ready;

    wire [31:0] time_data;
    wire time_valid;
    reg time_ready = 1'b1;
    wire time_last;
    wire [23:0] fft_input_data;
    wire fft_input_valid;
    reg fft_input_ready = 1'b1;
    wire fft_input_last;
    wire signed [23:0] fft_mean;
    wire fft_start;
    wire [31:0] fft_frame_id;
    wire [15:0] fft_frame_epoch;
    wire frame_active;
    wire [31:0] current_frame_id;
    wire control_run;
    wire control_soft_reset;
    wire control_fft_enable;
    wire [15:0] capture_epoch;
    wire [31:0] control_status;

    integer input_count = 0;
    integer time_count = 0;
    integer fft_count = 0;
    integer time_last_count = 0;
    integer cycle_count = 0;
    reg [31:0] trailer_magic = 0;
    reg [31:0] trailer_frame = 0;
    reg [31:0] trailer_samples = 0;
    reg [15:0] trailer_epoch = 0;

    always #5 clk = ~clk;

    measurement_control_status control (
        .aclk(clk),
        .aresetn(resetn),
        .control_word({29'd0, fft_enable, soft_reset, run}),
        .mmcm_locked(1'b1),
        .frame_active(frame_active),
        .fft_frame_active(frame_active),
        .spectrum_busy(1'b0),
        .frontend_stall(1'b0),
        .fft_events(6'd0),
        .run(control_run),
        .soft_reset(control_soft_reset),
        .fft_enable(control_fft_enable),
        .capture_epoch(capture_epoch),
        .status_word(control_status)
    );

    measurement_frame_router router (
        .aclk(clk),
        .aresetn(resetn),
        .run(control_run),
        .soft_reset(control_soft_reset),
        .fft_enable(control_fft_enable),
        .capture_epoch(capture_epoch),
        .mmcm_locked(1'b1),
        .frontend_stall(1'b0),
        .clip_count_total(32'd7),
        .jump_count_total(32'd3),
        .saturation_run_max(32'd2),
        .raw_min_code(16'hF000),
        .raw_max_code(16'h1000),
        .s_axis_tdata(sample_data),
        .s_axis_tvalid(sample_valid),
        .s_axis_tready(sample_ready),
        .m_time_tdata(time_data),
        .m_time_tvalid(time_valid),
        .m_time_tready(time_ready),
        .m_time_tlast(time_last),
        .m_fft_tdata(fft_input_data),
        .m_fft_tvalid(fft_input_valid),
        .m_fft_tready(fft_input_ready),
        .m_fft_tlast(fft_input_last),
        .fft_mean_q8(fft_mean),
        .fft_frame_start(fft_start),
        .fft_frame_id(fft_frame_id),
        .fft_frame_epoch(fft_frame_epoch),
        .frame_active(frame_active),
        .current_frame_id(current_frame_id)
    );

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (resetn && sample_valid && sample_ready) begin
            input_count <= input_count + 1;
            sample_data <= sample_data + 24'd256;
        end
        if (time_valid && time_ready) begin
            if (time_count == `MEAS_SHORT_SAMPLES)
                trailer_magic <= time_data;
            if (time_count == (`MEAS_SHORT_SAMPLES + 2))
                trailer_frame <= time_data;
            if (time_count == (`MEAS_SHORT_SAMPLES + 3))
                trailer_samples <= time_data;
            if (time_count == (`MEAS_SHORT_SAMPLES + 10))
                trailer_epoch <= time_data[15:0];
            time_count <= time_count + 1;
            if (time_last)
                time_last_count <= time_last_count + 1;
        end
        if (fft_input_valid && fft_input_ready)
            fft_count <= fft_count + 1;

        // Stop and disable FFT in the middle of a frame.  Per-frame latching
        // must still deliver one complete time/FFT record.
        if (input_count == 1024) begin
            run <= 1'b0;
            fft_enable <= 1'b0;
        end

        // Periodic independent stalls verify that neither branch duplicates.
        time_ready <= ((cycle_count % 19) != 5);
        fft_input_ready <= ((cycle_count % 23) != 7);
    end

    // Exercise the positive-bin filter and spectrum trailer independently.
    reg pack_frame_start = 1'b0;
    reg [47:0] pack_input_data = 48'd0;
    reg pack_input_valid = 1'b0;
    wire pack_input_ready;
    reg pack_input_last = 1'b0;
    wire [63:0] pack_output_data;
    wire pack_output_valid;
    reg pack_output_ready = 1'b1;
    wire pack_output_last;
    integer pack_input_count = 0;
    integer pack_output_count = 0;
    integer pack_last_count = 0;
    reg [15:0] pack_trailer_epoch = 0;
    wire pack_busy;
    reg pack_busy_seen = 1'b0;

    fft_spectrum_packer packer (
        .aclk(clk),
        .aresetn(resetn),
        .soft_reset(soft_reset),
        .frame_start(pack_frame_start),
        .frame_id(32'd99),
        .frame_epoch(16'd9),
        .frame_mean_q8(24'sd123),
        .s_axis_tdata(pack_input_data),
        .s_axis_tvalid(pack_input_valid),
        .s_axis_tready(pack_input_ready),
        .s_axis_tlast(pack_input_last),
        .s_status_tdata(8'd12),
        .s_status_tvalid(pack_frame_start),
        .s_status_tready(),
        .fft_events(6'd0),
        .m_axis_tdata(pack_output_data),
        .m_axis_tvalid(pack_output_valid),
        .m_axis_tready(pack_output_ready),
        .m_axis_tlast(pack_output_last),
        .busy(pack_busy)
    );

    always @(posedge clk) begin
        if (pack_busy)
            pack_busy_seen <= 1'b1;
        if (pack_input_valid && pack_input_ready) begin
            pack_input_count <= pack_input_count + 1;
            pack_input_data <= pack_input_data + 1'b1;
            pack_input_last <= (pack_input_count == (`MEAS_SHORT_SAMPLES - 2));
            if (pack_input_count == (`MEAS_SHORT_SAMPLES - 1)) begin
                pack_input_valid <= 1'b0;
                pack_input_last <= 1'b0;
            end
        end
        if (pack_output_valid && pack_output_ready) begin
            if (pack_output_count ==
                (`MEAS_POSITIVE_BINS + 6))
                pack_trailer_epoch <= pack_output_data[15:0];
            pack_output_count <= pack_output_count + 1;
            if (pack_output_last)
                pack_last_count <= pack_last_count + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        resetn <= 1'b1;
        run <= 1'b1;
        wait (frame_active);
        @(posedge clk);
        sample_valid <= 1'b1;

        pack_frame_start <= 1'b1;
        @(posedge clk);
        pack_frame_start <= 1'b0;
        pack_input_valid <= 1'b1;

        wait (time_last_count == 1 && pack_last_count == 1);
        sample_valid = 1'b0;
        repeat (10) @(posedge clk);

        if (input_count != `MEAS_SHORT_SAMPLES) begin
            $error("router input count mismatch %0d", input_count);
            $fatal(1);
        end
        if (fft_count != `MEAS_SHORT_SAMPLES) begin
            $error("FFT branch count mismatch %0d", fft_count);
            $fatal(1);
        end
        if (time_count != (`MEAS_SHORT_SAMPLES + `MEAS_TRAILER_WORDS)) begin
            $error("time record count mismatch %0d", time_count);
            $fatal(1);
        end
        if (trailer_magic != `MEAS_TIME_MAGIC ||
            trailer_frame != 0 ||
            trailer_samples != `MEAS_SHORT_SAMPLES ||
            trailer_epoch != 16'd1) begin
            $error("time trailer mismatch magic=%h frame=%0d samples=%0d epoch=%0d",
                   trailer_magic, trailer_frame, trailer_samples,
                   trailer_epoch);
            $fatal(1);
        end
        if (pack_output_count !=
            (`MEAS_POSITIVE_BINS + `MEAS_SPECTRUM_TRAILER_BEATS)) begin
            $error("spectrum record count mismatch %0d", pack_output_count);
            $fatal(1);
        end
        if (pack_trailer_epoch != 16'd9 || pack_busy ||
            !pack_busy_seen) begin
            $error("spectrum epoch/busy mismatch epoch=%0d busy=%0d seen=%0d",
                   pack_trailer_epoch, pack_busy, pack_busy_seen);
            $fatal(1);
        end
        run = 1'b1;
        repeat (3) @(posedge clk);
        if (capture_epoch != 16'd2 ||
            control_status[31:16] != 16'd2) begin
            $error("capture epoch did not advance on restart epoch=%0d status=%h",
                   capture_epoch, control_status);
            $fatal(1);
        end
        $display("TEST_PASS");
        $finish;
    end

    initial begin
        #5000000;
        $error("simulation timeout");
        $fatal(1);
    end
endmodule
