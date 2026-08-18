#ifndef MEASUREMENT_FORMAT_H
#define MEASUREMENT_FORMAT_H

#include "xil_types.h"

#define MEAS_FORMAT_VERSION          0x00010001U
#define MEAS_TIME_MAGIC              0x54494D45U
#define MEAS_SPECTRUM_MAGIC          0x53504543U

#define MEAS_SHORT_SAMPLES           65536U
#define MEAS_FFT_BINS                32769U
#define MEAS_TIME_TRAILER_WORDS      16U
#define MEAS_SPECTRUM_TRAILER_BEATS  8U

#define MEAS_TIME_RECORD_BYTES \
    ((MEAS_SHORT_SAMPLES + MEAS_TIME_TRAILER_WORDS) * sizeof(s32))
#define MEAS_SPECTRUM_RECORD_BYTES \
    ((MEAS_FFT_BINS + MEAS_SPECTRUM_TRAILER_BEATS) * sizeof(u64))

#define MEAS_CTRL_RUN                (1U << 0)
#define MEAS_CTRL_SOFT_RESET         (1U << 1)
#define MEAS_CTRL_FFT_ENABLE         (1U << 2)

#define MEAS_STATUS_MMCM_LOCKED      (1U << 0)
#define MEAS_STATUS_FRAME_ACTIVE     (1U << 1)
#define MEAS_STATUS_INPUT_STALL      (1U << 2)
#define MEAS_STATUS_FFT_ACTIVE       (1U << 3)
#define MEAS_STATUS_SPECTRUM_BUSY    (1U << 4)
#define MEAS_STATUS_DMA_ERROR        (1U << 8) /* PS-composed status */
#define MEAS_STATUS_FFT_EVENT_MASK   (0x3FU << 9)
#define MEAS_STATUS_EPOCH_SHIFT      16U
#define MEAS_STATUS_EPOCH_MASK       (0xFFFFU << MEAS_STATUS_EPOCH_SHIFT)
#define MEAS_STATUS_FFT_WARMUP       (1U << 5)

typedef struct {
    u32 magic;
    u32 format_version;
    u32 frame_id;
    u32 sample_count;
    u32 status;
    u32 clip_count;
    u32 jump_count;
    u32 saturation_run_max;
    u32 raw_extrema;
    s32 mean_q8;
    u32 reserved[5];
    u32 check;
} measurement_time_trailer_t;

typedef struct {
    u64 magic_version;
    u64 frame_id;
    u64 bin_count;
    u64 fft_status;
    s64 mean_q8;
    u64 reserved[2];
    u64 check;
} measurement_spectrum_trailer_t;

static inline u16 measurement_time_epoch(
    const measurement_time_trailer_t *meta)
{
    return (u16)(meta->reserved[0] & 0xFFFFU);
}

static inline u16 measurement_spectrum_epoch(
    const measurement_spectrum_trailer_t *meta)
{
    return (u16)(meta->reserved[1] & 0xFFFFULL);
}

typedef char measurement_time_trailer_size_check[
    sizeof(measurement_time_trailer_t) == 64U ? 1 : -1];
typedef char measurement_spectrum_trailer_size_check[
    sizeof(measurement_spectrum_trailer_t) == 64U ? 1 : -1];

#endif
