#include <math.h>
#include <string.h>
#include "measurement.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define SELFTEST_CHECK(expression, name) \
    do { \
        (void)(name); \
        if (!(expression)) \
            passed = 0; \
    } while (0)

static s32 test_samples[MEAS_SHORT_SAMPLES] __attribute__((aligned(64)));
static u64 test_spectrum[MEAS_FFT_BINS] __attribute__((aligned(64)));

static u64 pack_fft_real(s32 value)
{
    return (u64)((u32)value & 0x00FFFFFFU);
}

static void fill_signal(
    s32 *samples,
    u32 sample_count,
    double sample_rate_hz,
    double volts_per_code,
    double fundamental,
    const u32 *harmonic,
    const double *peak,
    const double *phase,
    u32 component_count,
    u32 impulse_period)
{
    u32 n;
    u32 c;
    for (n = 0U; n < sample_count; ++n) {
        double t = (double)n / sample_rate_hz;
        double value = 0.004 *
            ((double)n / (double)(sample_count - 1U) - 0.5);
        for (c = 0U; c < component_count; ++c)
            value += peak[c] * cos(
                2.0 * M_PI * fundamental * (double)harmonic[c] * t +
                phase[c]);
        if (impulse_period != 0U && n % impulse_period == 17U)
            value += (n & 1U) != 0U ? 0.8 : -0.8;
        samples[n] = (s32)floor(value / volts_per_code + 0.5) * 256;
    }
}

static void fill_spectrum(
    double sample_rate_hz,
    double fundamental,
    const u32 *harmonic,
    const s32 *magnitude,
    u32 component_count)
{
    u32 n;
    u32 c;
    for (n = 0U; n < MEAS_FFT_BINS; ++n)
        test_spectrum[n] = pack_fft_real(n == 0U ? 0 : 100);
    for (c = 0U; c < component_count; ++c) {
        u32 bin = (u32)(
            fundamental * (double)harmonic[c] *
            (double)MEAS_SHORT_SAMPLES / sample_rate_hz + 0.5);
        if (bin < MEAS_FFT_BINS)
            test_spectrum[bin] = pack_fft_real(magnitude[c]);
    }
}

static void initialize_metadata(
    u32 frame_id,
    u32 sample_count,
    measurement_time_trailer_t *time_meta,
    measurement_spectrum_trailer_t *spectrum_meta)
{
    memset(time_meta, 0, sizeof(*time_meta));
    memset(spectrum_meta, 0, sizeof(*spectrum_meta));
    time_meta->frame_id = frame_id;
    time_meta->sample_count = sample_count;
    spectrum_meta->frame_id = frame_id;
}

static int analyze_vector(
    double fundamental,
    const u32 *harmonic,
    const double *peak,
    const double *phase,
    const s32 *magnitude,
    u32 component_count,
    u32 impulse_period,
    measurement_calibration_t *calibration,
    measurement_time_trailer_t *time_meta,
    measurement_spectrum_trailer_t *spectrum_meta,
    measurement_result_t *result)
{
    fill_signal(
        test_samples, MEAS_SHORT_SAMPLES,
        calibration->sample_rate_hz,
        calibration->adc_volts_per_code,
        fundamental, harmonic, peak, phase,
        component_count, impulse_period);
    fill_spectrum(
        calibration->sample_rate_hz, fundamental,
        harmonic, magnitude, component_count);
    return measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        time_meta, spectrum_meta, calibration, result);
}

int measurement_selftest(void)
{
    const u32 harmonic_1[1] = {1U};
    const u32 harmonic_12[2] = {1U, 2U};
    const u32 harmonic_13[2] = {1U, 3U};
    const u32 harmonic_15[2] = {1U, 5U};
    const u32 harmonic_17[2] = {1U, 7U};
    const u32 harmonic_134[3] = {1U, 3U, 4U};
    const u32 harmonic_124[3] = {1U, 2U, 4U};
    const u32 harmonic_1510[3] = {1U, 5U, 10U};
    const u32 harmonic_12448[3] = {1U, 24U, 48U};
    const u32 harmonic_12550[3] = {1U, 25U, 50U};
    const double phase_2[2] = {0.31, -0.47};
    const double phase_1[1] = {0.31};
    const double phase_3[3] = {0.31, -0.47, 0.83};
    const double peak_2[2] = {0.400, 0.100};
    const double peak_1[1] = {0.400};
    const double peak_strong_harmonic[3] = {0.035, 0.300, 0.120};
    const double peak_1510[3] = {0.062, 0.026, 0.026};
    const double peak_stopband_target[2] = {0.100, 0.020};
    const double peak_zero_fundamental[3] = {0.0, 0.400, 0.100};
    const double peak_010mv_fundamental[3] = {0.00010, 0.400, 0.100};
    const double peak_024mv_fundamental[3] = {0.00024, 0.400, 0.100};
    const s32 magnitude_2[2] = {7000000, 1800000};
    const s32 magnitude_1[1] = {7000000};
    const s32 magnitude_3[3] = {700000, 7000000, 2500000};
    const s32 magnitude_1510[3] = {7000000, 3000000, 3000000};
    const s32 magnitude_without_fundamental[3] = {100, 7000000, 1800000};
    const double weak_peak_matrix[4] = {
        0.00010, 0.00024, 0.00100, 0.00500
    };
    measurement_calibration_t calibration;
    measurement_result_t result;
    measurement_time_trailer_t time_meta;
    measurement_spectrum_trailer_t spectrum_meta;
    u32 matrix_case;
    int passed = 1;

    measurement_calibration_identity(&calibration);

    initialize_metadata(1U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        40000.0, harmonic_12, peak_2, phase_2, magnitude_2, 2U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result), "base_analyze");
    SELFTEST_CHECK(result.component_count == 2U &&
        result.component[0].harmonic == 1U &&
        fabs(result.fundamental_hz - 40000.0) <= 1000.0 &&
        fabs(result.component[0].amplitude_peak_v - 0.400) <= 0.005 &&
        fabs(result.component[1].amplitude_peak_v - 0.100) <= 0.005,
        "base_result");
    SELFTEST_CHECK(
        (result.quality.flags & MEAS_QUALITY_UNCALIBRATED) != 0U &&
        result.quality.capture_time_us == 32768U &&
        result.quality.deadline_miss == 0U,
        "identity_channel_timing_flags");

    initialize_metadata(106U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        50000.0, harmonic_1, peak_1, phase_1, magnitude_1, 1U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "single_tone_analyze");
    SELFTEST_CHECK(result.component_count == 1U &&
        result.component[0].harmonic == 1U &&
        fabs(result.fundamental_hz - 50000.0) <= 1000.0 &&
        fabs(result.component[0].amplitude_peak_v - 0.400) <= 0.005 &&
        fabs(result.ac_rms_v - 0.400 / sqrt(2.0)) <= 0.005 &&
        fabs(result.reconstructed_pp_v - 0.800) <= 0.010 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "single_tone_result");
    initialize_metadata(113U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        10000.0, harmonic_1, peak_1, phase_1, magnitude_1, 1U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "single_tone_lower_edge_analyze");
    SELFTEST_CHECK(result.component_count == 1U &&
        result.component[0].harmonic == 1U &&
        fabs(result.fundamental_hz - 10000.0) <= 1.0 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "single_tone_lower_edge_result");

    initialize_metadata(114U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        500000.0, harmonic_1, peak_1, phase_1, magnitude_1, 1U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "single_tone_upper_edge_analyze");
    SELFTEST_CHECK(result.component_count == 1U &&
        result.component[0].harmonic == 1U &&
        fabs(result.fundamental_hz - 500000.0) <= 1.0 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "single_tone_upper_edge_result");

    initialize_metadata(108U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        50000.0, harmonic_13, peak_2, phase_2, magnitude_2, 2U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "third_harmonic_analyze");
    SELFTEST_CHECK(result.component[1].harmonic == 3U &&
        fabs(result.fundamental_hz - 50000.0) <= 1000.0,
        "third_harmonic_result");
    initialize_metadata(109U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        40000.0, harmonic_15, peak_2, phase_2, magnitude_2, 2U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "fifth_harmonic_analyze");
    SELFTEST_CHECK(result.component[1].harmonic == 5U &&
        fabs(result.fundamental_hz - 40000.0) <= 1000.0,
        "fifth_harmonic_result");
    initialize_metadata(110U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        25000.0, harmonic_17, peak_2, phase_2, magnitude_2, 2U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "seventh_harmonic_analyze");
    SELFTEST_CHECK(result.component[1].harmonic == 7U &&
        fabs(result.fundamental_hz - 25000.0) <= 1000.0,
        "seventh_harmonic_result");

    initialize_metadata(111U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    fill_signal(
        test_samples, MEAS_SHORT_SAMPLES,
        calibration.sample_rate_hz, calibration.adc_volts_per_code,
        40000.0, harmonic_15, peak_2, phase_2, 2U, 0U);
    fill_spectrum(
        calibration.sample_rate_hz, 40000.0,
        harmonic_15, magnitude_2, 2U);
    SELFTEST_CHECK(measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result) &&
        result.component[1].harmonic == 5U,
        "signal_change_uses_current_frame");

    initialize_metadata(101U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    spectrum_meta.fft_status = 1U << 10;
    SELFTEST_CHECK(measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result) &&
        (result.quality.flags & MEAS_QUALITY_FFT_ERROR) == 0U,
        "fft_frame_started_is_normal");

    initialize_metadata(2U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        37123.0, harmonic_134, peak_strong_harmonic, phase_3,
        magnitude_3, 3U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result), "noncontiguous_analyze");
    SELFTEST_CHECK(result.component_count == 3U &&
        result.component[0].harmonic == 1U &&
        result.component[1].harmonic == 3U &&
        result.component[2].harmonic == 4U &&
        fabs(result.component[0].amplitude_peak_v - 0.035) <= 0.005 &&
        fabs(result.component[1].amplitude_peak_v - 0.300) <= 0.005,
        "noncontiguous_result");
    /*
     * A strong spurious subharmonic FFT candidate must not prevent the
     * retained true 1/5/10 model from reaching the time-domain fit.
     */
    initialize_metadata(115U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    fill_signal(
        test_samples, MEAS_SHORT_SAMPLES,
        calibration.sample_rate_hz, calibration.adc_volts_per_code,
        40000.0, harmonic_1510, peak_1510, phase_3, 3U, 0U);
    fill_spectrum(
        calibration.sample_rate_hz, 40000.0,
        harmonic_1510, magnitude_1510, 3U);
    test_spectrum[(u32)(13333.333 *
        (double)MEAS_SHORT_SAMPLES / calibration.sample_rate_hz + 0.5)] =
        pack_fft_real(8000000);
    SELFTEST_CHECK(measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "subharmonic_fallback_analyze");
    SELFTEST_CHECK(result.component_count == 3U &&
        result.component[0].harmonic == 1U &&
        result.component[1].harmonic == 5U &&
        result.component[2].harmonic == 10U &&
        fabs(result.fundamental_hz - 40000.0) <= 1000.0 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U &&
        (result.quality.flags & MEAS_QUALITY_AMBIGUOUS) == 0U,
        "subharmonic_fallback_result");

    /*
     * A stop-band interferer may create a spectrum-only spur at an apparent
     * in-band harmonic.  The fitted zero-amplitude term must be pruned rather
     * than causing the valid 1/5 target model to be rejected.
     */
    initialize_metadata(116U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    fill_signal(
        test_samples, MEAS_SHORT_SAMPLES,
        calibration.sample_rate_hz, calibration.adc_volts_per_code,
        62500.0, harmonic_15, peak_stopband_target, phase_2, 2U, 0U);
    fill_spectrum(
        calibration.sample_rate_hz, 62500.0,
        harmonic_15, magnitude_2, 2U);
    test_spectrum[(u32)(125000.0 *
        (double)MEAS_SHORT_SAMPLES / calibration.sample_rate_hz + 0.5)] =
        pack_fft_real(6000000);
    SELFTEST_CHECK(measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "stopband_spur_prune_analyze");
    SELFTEST_CHECK(result.component_count == 2U &&
        result.component[0].harmonic == 1U &&
        result.component[1].harmonic == 5U &&
        fabs(result.component[0].amplitude_peak_v - 0.100) <= 0.005 &&
        fabs(result.component[1].amplitude_peak_v - 0.020) <= 0.005 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "stopband_spur_prune_result");

    initialize_metadata(102U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    fill_signal(
        test_samples, MEAS_SHORT_SAMPLES,
        calibration.sample_rate_hz, calibration.adc_volts_per_code,
        40000.0, harmonic_12, peak_2, phase_2, 2U, 0U);
    fill_spectrum(
        calibration.sample_rate_hz, 40000.0,
        harmonic_12, magnitude_2, 2U);
    SELFTEST_CHECK(measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result) &&
        result.component_count == 2U &&
        result.component[1].harmonic == 2U &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "current_frame_is_independent");

    initialize_metadata(3U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        10000.0, harmonic_12, peak_2, phase_2, magnitude_2, 2U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result), "lower_edge_analyze");
    SELFTEST_CHECK(
        fabs(result.fundamental_hz - 10000.0) <= 1000.0,
        "lower_edge_result");

    initialize_metadata(4U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        250000.0, harmonic_12, peak_2, phase_2, magnitude_2, 2U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result), "upper_edge_analyze");
    SELFTEST_CHECK(
        result.component[1].frequency_hz >= 499000.0,
        "upper_edge_result");

    initialize_metadata(5U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        20000.0, harmonic_124, peak_zero_fundamental, phase_3,
        magnitude_without_fundamental, 3U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "zero_fundamental_analyze");
    SELFTEST_CHECK(result.component_count == 2U &&
        fabs(result.fundamental_hz - 40000.0) <= 1000.0 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "zero_fundamental_is_higher_f0");

    initialize_metadata(51U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        20000.0, harmonic_124, peak_010mv_fundamental, phase_3,
        magnitude_without_fundamental, 3U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "weak_010mv_analyze");
    SELFTEST_CHECK(result.component_count == 3U &&
        fabs(result.fundamental_hz - 20000.0) <= 1000.0 &&
        result.component[0].amplitude_peak_v >= 0.00005 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "weak_010mv_result");

    initialize_metadata(52U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        20000.0, harmonic_124, peak_024mv_fundamental, phase_3,
        magnitude_without_fundamental, 3U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "weak_024mv_analyze");
    SELFTEST_CHECK(result.component_count == 3U &&
        fabs(result.fundamental_hz - 20000.0) <= 1000.0 &&
        result.component[0].amplitude_peak_v >= 0.00015 &&
        (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
        "weak_024mv_result");

    for (matrix_case = 0U; matrix_case < 4U; ++matrix_case) {
        double high_order_peak[3] = {
            weak_peak_matrix[matrix_case], 0.400, 0.100
        };
        initialize_metadata(
            60U + matrix_case, MEAS_SHORT_SAMPLES,
            &time_meta, &spectrum_meta);
        SELFTEST_CHECK(analyze_vector(
            10000.0, harmonic_12448, high_order_peak, phase_3,
            magnitude_without_fundamental, 3U, 0U,
            &calibration, &time_meta, &spectrum_meta, &result),
            "high_order_24_48_analyze");
        SELFTEST_CHECK(result.component_count == 3U &&
            result.component[1].harmonic == 24U &&
            result.component[2].harmonic == 48U &&
            fabs(result.fundamental_hz - 10000.0) <= 1.0 &&
            fabs(result.component[0].amplitude_peak_v -
                weak_peak_matrix[matrix_case]) <= 0.00005 &&
            fabs(result.component[1].amplitude_peak_v - 0.400) <= 0.005 &&
            fabs(result.component[2].amplitude_peak_v - 0.100) <= 0.005 &&
            result.quality.residual_ratio <= 0.10 &&
            (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
            "high_order_24_48_result");

        initialize_metadata(
            70U + matrix_case, MEAS_SHORT_SAMPLES,
            &time_meta, &spectrum_meta);
        SELFTEST_CHECK(analyze_vector(
            10000.0, harmonic_12550, high_order_peak, phase_3,
            magnitude_without_fundamental, 3U, 0U,
            &calibration, &time_meta, &spectrum_meta, &result),
            "high_order_25_50_analyze");
        SELFTEST_CHECK(result.component_count == 3U &&
            result.component[1].harmonic == 25U &&
            result.component[2].harmonic == 50U &&
            fabs(result.fundamental_hz - 10000.0) <= 1.0 &&
            fabs(result.component[0].amplitude_peak_v -
                weak_peak_matrix[matrix_case]) <= 0.00005 &&
            fabs(result.component[1].amplitude_peak_v - 0.400) <= 0.005 &&
            fabs(result.component[2].amplitude_peak_v - 0.100) <= 0.005 &&
            result.quality.residual_ratio <= 0.10 &&
            (result.quality.flags & MEAS_QUALITY_VALID) != 0U,
            "high_order_25_50_result");
    }

    initialize_metadata(6U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(analyze_vector(
        40000.0, harmonic_12, peak_2, phase_2, magnitude_2, 2U, 997U,
        &calibration, &time_meta, &spectrum_meta, &result), "huber_analyze");
    SELFTEST_CHECK(
        (result.quality.flags & MEAS_QUALITY_HUBER_USED) != 0U,
        "huber_flag");

    initialize_metadata(106U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    spectrum_meta.fft_status =
        (u64)(MEAS_FFT_EVENT_FRAME_STARTED |
              MEAS_FFT_EVENT_DATA_IN_HALT) << 10;
    SELFTEST_CHECK(analyze_vector(
        40000.0, harmonic_12, peak_2, phase_2, magnitude_2, 2U, 0U,
        &calibration, &time_meta, &spectrum_meta, &result),
        "fft_input_halt_accepted");
    SELFTEST_CHECK(
        result.quality.fft_events ==
            (MEAS_FFT_EVENT_FRAME_STARTED | MEAS_FFT_EVENT_DATA_IN_HALT) &&
        (result.quality.flags &
            (MEAS_QUALITY_FFT_ERROR | MEAS_QUALITY_DATA_INVALID)) == 0U,
        "fft_input_halt_diagnostic_only");

    initialize_metadata(7U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    time_meta.clip_count = 1U;
    SELFTEST_CHECK(!measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "clip_reject");
    SELFTEST_CHECK(
        (result.quality.flags & MEAS_QUALITY_DATA_INVALID) != 0U,
        "clip_flag");
    SELFTEST_CHECK(
        result.quality.reject_stage == MEAS_REJECT_METADATA &&
        result.quality.clip_count == 1U,
        "clip_diagnostic");

    initialize_metadata(8U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    time_meta.status = MEAS_STATUS_INPUT_STALL;
    SELFTEST_CHECK(!measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "stall_reject");
    SELFTEST_CHECK(
        result.quality.reject_stage == MEAS_REJECT_METADATA &&
        result.quality.time_status == MEAS_STATUS_INPUT_STALL,
        "stall_diagnostic");

    initialize_metadata(112U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    time_meta.status = MEAS_STATUS_DMA_ERROR;
    SELFTEST_CHECK(!measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "dma_error_reject");
    SELFTEST_CHECK(
        result.quality.reject_stage == MEAS_REJECT_METADATA &&
        result.quality.time_status == MEAS_STATUS_DMA_ERROR,
        "dma_error_diagnostic");

    initialize_metadata(103U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    time_meta.saturation_run_max = 2U;
    SELFTEST_CHECK(!measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "saturation_reject");
    SELFTEST_CHECK(
        result.quality.reject_stage == MEAS_REJECT_METADATA &&
        result.quality.saturation_run_max == 2U,
        "saturation_diagnostic");

    initialize_metadata(104U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    time_meta.jump_count = 1U;
    SELFTEST_CHECK(!measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "jump_reject");
    SELFTEST_CHECK(
        result.quality.reject_stage == MEAS_REJECT_METADATA &&
        result.quality.jump_count == 1U,
        "jump_diagnostic");

    initialize_metadata(105U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    spectrum_meta.fft_status =
        (u64)MEAS_FFT_EVENT_TLAST_UNEXPECTED << 10;
    SELFTEST_CHECK(!measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "fft_error_reject");
    SELFTEST_CHECK(
        result.quality.reject_stage == MEAS_REJECT_METADATA &&
        result.quality.fft_events != 0U,
        "fft_error_diagnostic");

    memset(test_spectrum, 0, sizeof(test_spectrum));
    initialize_metadata(10U, MEAS_SHORT_SAMPLES, &time_meta, &spectrum_meta);
    SELFTEST_CHECK(!measurement_analyze(
        test_samples, MEAS_SHORT_SAMPLES,
        test_spectrum, MEAS_FFT_BINS,
        &time_meta, &spectrum_meta, &calibration, &result),
        "empty_spectrum_reject");
    SELFTEST_CHECK(
        result.quality.reject_stage == MEAS_REJECT_CANDIDATES &&
        result.quality.candidate_count == 0U,
        "empty_spectrum_diagnostic");

    return passed;
}
