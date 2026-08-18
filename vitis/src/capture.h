#ifndef CAPTURE_H
#define CAPTURE_H

#include "measurement.h"

#define CAPTURE_DESCRIPTOR_COUNT 128U

typedef struct {
    const s32 *samples_q8;
    const u64 *spectrum;
    const measurement_time_trailer_t *time_meta;
    const measurement_spectrum_trailer_t *spectrum_meta;
    u32 frame_id;
    u16 capture_epoch;
    u32 sample_count;
} capture_record_t;

int capture_initialize(void);
int capture_start(u16 *capture_epoch);
void capture_stop(void);
u32 capture_status(void);
int capture_latest_matched(capture_record_t *record);
u32 capture_dma_errors(void);

#endif
