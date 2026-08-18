`timescale 1ns/1ps

module tb_fir_decimate_25;
    localparam integer TAPS = 625;
    localparam real PI = 3.14159265358979323846;
    reg signed [23:0] coefficient [0:TAPS-1];
    integer signed_value;
    integer dc_sum;
    integer k;
    real pass_re;
    real pass_im;
    real stop_re;
    real stop_im;
    real pass_magnitude;
    real stop_magnitude;
    real attenuation_db;

    initial begin
        // Vivado exports registered memory initialization files into the
        // simulator run directory, so use the exported basename here.
        $readmemh("fir_decimate_25.mem", coefficient);
        dc_sum = 0;
        pass_re = 0.0;
        pass_im = 0.0;
        stop_re = 0.0;
        stop_im = 0.0;
        for (k = 0; k < TAPS; k = k + 1) begin
            signed_value = $signed(coefficient[k]);
            dc_sum = dc_sum + signed_value;
            if (coefficient[k] !== coefficient[TAPS-1-k]) begin
                $error("FIR impulse response is not symmetric at tap %0d", k);
                $fatal(1);
            end
            pass_re = pass_re + signed_value *
                $cos(2.0 * PI * 500000.0 * k / 50000000.0);
            pass_im = pass_im - signed_value *
                $sin(2.0 * PI * 500000.0 * k / 50000000.0);
            stop_re = stop_re + signed_value *
                $cos(2.0 * PI * 1000000.0 * k / 50000000.0);
            stop_im = stop_im - signed_value *
                $sin(2.0 * PI * 1000000.0 * k / 50000000.0);
        end
        pass_magnitude = $sqrt(pass_re * pass_re + pass_im * pass_im);
        stop_magnitude = $sqrt(stop_re * stop_re + stop_im * stop_im);
        attenuation_db = -20.0 * $ln(stop_magnitude / pass_magnitude) / $ln(10.0);
        if (dc_sum != 8388608) begin
            $error("FIR DC gain mismatch: %0d", dc_sum);
            $fatal(1);
        end
        if (!(attenuation_db >= 90.0)) begin
            $error("1 MHz rejection only %0.3f dB", attenuation_db);
            $fatal(1);
        end
        $display("attenuation=%0.3f dB", attenuation_db);
        $display("TEST_PASS");
        $finish;
    end
endmodule
