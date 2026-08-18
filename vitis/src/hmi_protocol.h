#ifndef HMI_PROTOCOL_H
#define HMI_PROTOCOL_H

#include "measurement.h"
#include "xuartps.h"

#define HMI_WAVE_POINTS 464U
#define HMI_RESULT_DEADLINE_MS 2000U

typedef enum {
    HMI_PAGE_NONE = 0U,
    HMI_PAGE_TIME = 1U,
    HMI_PAGE_FREQ = 2U
} hmi_page_t;

typedef enum {
    HMI_REQUEST_NONE = 0U,
    HMI_REQUEST_MEASURE = 0x10U,
    HMI_REQUEST_CACHE = 0x12U,
    HMI_REQUEST_ABORT = 0x13U
} hmi_request_code_t;

typedef struct {
    hmi_request_code_t code;
    hmi_page_t page;
    u64 started_ticks;
} hmi_request_t;

typedef enum {
    HMI_STATUS_READY = 0U,
    HMI_STATUS_VALID,
    HMI_STATUS_UNSTABLE,
    HMI_STATUS_UNCALIBRATED,
    HMI_STATUS_CLIPPED,
    HMI_STATUS_FFT_ERROR,
    HMI_STATUS_DATA_INVALID,
    HMI_STATUS_NO_SIGNAL,
    HMI_STATUS_TIMEOUT
} hmi_status_t;

typedef enum {
    HMI_FREQUENCY_ROUNDED = 0U,
    HMI_FREQUENCY_PRECISE
} hmi_frequency_mode_t;

int hmi_initialize(XUartPs *uart);
int hmi_poll_request(hmi_request_t *request);
void hmi_cache_invalidate(void);
int hmi_cache_valid(void);
void hmi_cache_store(const measurement_result_t *result);
int hmi_send_cached(hmi_page_t page);
int hmi_refresh_cached_frequency(hmi_page_t page);
void hmi_set_frequency_mode(hmi_frequency_mode_t mode);
int hmi_wait_render_complete(hmi_page_t page);
void hmi_send_elapsed(
    hmi_page_t page, u32 elapsed_ms, int render_confirmed);
void hmi_send_ready(hmi_page_t page);
void hmi_send_error(hmi_page_t page, hmi_status_t status);

#endif
