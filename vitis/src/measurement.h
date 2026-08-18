#ifndef MEASUREMENT_H
#define MEASUREMENT_H

#include <stddef.h>
#include "xil_types.h"
#include "measurement_format.h"

#define MEAS_MAX_COMPONENTS       3U
#define MEAS_MAX_CANDIDATES       10U
#define MEAS_MAX_BASIS            8U
#define MEAS_MAX_RANKED_MODELS    8U
#define MEAS_SAMPLE_RATE_HZ       2000000.0
#define MEAS_MIN_FREQUENCY_HZ     10000.0
#define MEAS_MAX_FREQUENCY_HZ     500000.0
#define MEAS_INITIAL_SNR_DB       8.0
#define MEAS_HUBER_KAPPA          1.8

#define MEAS_CAL_FLAG_VALID       (1U << 0)
#define MEAS_CAL_FLAG_UNCALIBRATED (1U << 1)

#define MEAS_QUALITY_VALID        (1U << 0)
#define MEAS_QUALITY_HUBER_USED   (1U << 2)
#define MEAS_QUALITY_AMBIGUOUS    (1U << 3)
#define MEAS_QUALITY_CLIPPED      (1U << 5)
#define MEAS_QUALITY_UNCALIBRATED (1U << 6)
#define MEAS_QUALITY_FFT_ERROR    (1U << 7)
#define MEAS_QUALITY_DATA_INVALID (1U << 8)
#define MEAS_QUALITY_DEADLINE_MISS (1U << 10)

#define MEAS_FFT_EVENT_FRAME_STARTED    (1U << 0)
#define MEAS_FFT_EVENT_TLAST_UNEXPECTED (1U << 1)
#define MEAS_FFT_EVENT_TLAST_MISSING    (1U << 2)
#define MEAS_FFT_EVENT_DATA_IN_HALT     (1U << 3)
#define MEAS_FFT_EVENT_DATA_OUT_HALT    (1U << 4)
#define MEAS_FFT_EVENT_STATUS_HALT      (1U << 5)
#define MEAS_FFT_EVENT_FATAL_MASK       \
    (MEAS_FFT_EVENT_TLAST_UNEXPECTED | MEAS_FFT_EVENT_TLAST_MISSING)

typedef enum {
    MEAS_REJECT_NONE = 0U,
    MEAS_REJECT_ARGUMENT,
    MEAS_REJECT_METADATA,
    MEAS_REJECT_CANDIDATES,
    MEAS_REJECT_ENUMERATION,
    MEAS_REJECT_FIT
} measurement_reject_stage_t;

typedef struct {
    u32 version;
    u32 size;
    u32 flags;
    u32 crc32;
    double adc_volts_per_code;
    double sample_rate_hz;
    double gain[MEAS_MAX_COMPONENTS];
    double gain_slope_per_hz[MEAS_MAX_COMPONENTS];
    double phase_rad[MEAS_MAX_COMPONENTS];
    double phase_delay_s[MEAS_MAX_COMPONENTS];
    double dc_offset_v;
} measurement_calibration_t;

typedef struct {
    u32 flags;
    u32 frame_id;
    u32 sample_count;
    u32 clip_count;
    u32 saturation_run_max;
    u32 jump_count;
    u32 fft_events;
    u32 time_status;
    u32 spectrum_frame_id;
    u32 reject_stage;
    u32 candidate_count;
    u32 hypothesis_count;
    u32 enumerated_count;
    u32 prefiltered_count;
    u32 ranked_count;
    double snr_db;
    double residual_rms_v;
    double residual_ratio;
    double condition_estimate;
    double bic;
    double drift_v_per_record;
    u32 capture_time_us;
    u32 candidate_time_us;
    u32 enumeration_time_us;
    u32 fit_time_us;
    u32 robust_time_us;
    u32 total_time_us;
    u32 deadline_miss;
} measurement_quality_t;

typedef struct {
    u32 harmonic;
    double frequency_hz;
    double display_frequency_hz;
    double amplitude_peak_v;
    double amplitude_pp_v;
    double amplitude_rms_v;
    double phase_rad;
} measurement_component_t;

typedef struct {
    measurement_quality_t quality;
    u32 component_count;
    measurement_component_t component[MEAS_MAX_COMPONENTS];
    double dc_v;
    double ac_rms_v;
    double total_rms_v;
    double reconstructed_pp_v;
    double fundamental_hz;
} measurement_result_t;

typedef struct {
    double frequency_hz;
    double magnitude;
    double noise;
    u32 bin;
} measurement_candidate_t;

void measurement_calibration_identity(measurement_calibration_t *cal);
void measurement_calibration_channel_b(measurement_calibration_t *cal);
void measurement_calibration_reseal(measurement_calibration_t *cal);
int measurement_calibration_validate(const measurement_calibration_t *cal);
u32 measurement_crc32(const void *data, size_t length);

int measurement_analyze(
    const s32 *samples_q8,
    u32 sample_count,
    const u64 *spectrum,
    u32 fft_bins,
    const measurement_time_trailer_t *time_meta,
    const measurement_spectrum_trailer_t *spectrum_meta,
    const measurement_calibration_t *cal,
    measurement_result_t *result);

int measurement_selftest(void);

#endif
