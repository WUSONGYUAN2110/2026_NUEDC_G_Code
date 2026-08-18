#include <math.h>
#include <string.h>
#include "capture.h"
#include "hmi_protocol.h"
#include "measurement.h"
#include "xil_cache.h"
#include "xgpiops.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xtime_l.h"
#include "xuartps.h"

#if defined(XPAR_XUARTPS_0_DEVICE_ID)
#define HMI_UART_DEVICE_ID XPAR_XUARTPS_0_DEVICE_ID
#else
#define HMI_UART_DEVICE_ID XPAR_PS7_UART_1_DEVICE_ID
#endif

#define HMI_DISPLAY_BUDGET_MS 350U
#define MEASUREMENT_TIMEOUT_MS \
    (HMI_RESULT_DEADLINE_MS - HMI_DISPLAY_BUDGET_MS)
#define NO_SIGNAL_CONFIRM_FRAMES 5U
#define PS_KEY1_MIO 50U
#define PS_KEY_DEBOUNCE_MS 25U

#if defined(XPAR_XGPIOPS_0_DEVICE_ID)
#define PS_GPIO_DEVICE_ID XPAR_XGPIOPS_0_DEVICE_ID
#else
#define PS_GPIO_DEVICE_ID XPAR_PS7_GPIO_0_DEVICE_ID
#endif

typedef enum {
    MEASURE_OUTCOME_VALID = 0U,
    MEASURE_OUTCOME_ABORTED,
    MEASURE_OUTCOME_NO_SIGNAL,
    MEASURE_OUTCOME_UNSTABLE,
    MEASURE_OUTCOME_CLIPPED,
    MEASURE_OUTCOME_FFT_ERROR,
    MEASURE_OUTCOME_DATA_INVALID,
    MEASURE_OUTCOME_TIMEOUT
} measure_outcome_t;

static XUartPs hmi_uart;
static XGpioPs ps_gpio;
static measurement_calibration_t calibration;
static hmi_page_t active_page = HMI_PAGE_NONE;
static hmi_frequency_mode_t frequency_mode = HMI_FREQUENCY_ROUNDED;

typedef struct {
    u32 candidate_level;
    u32 stable_level;
    int armed;
    XTime candidate_since;
} key_debounce_t;

static key_debounce_t frequency_key;

static int uart_initialize(void)
{
    XUartPs_Config *config = XUartPs_LookupConfig(HMI_UART_DEVICE_ID);
    int status;

    if (config == NULL)
        return XST_FAILURE;
    status = XUartPs_CfgInitialize(
        &hmi_uart, config, config->BaseAddress);
    if (status != XST_SUCCESS)
        return status;
    return XUartPs_SetBaudRate(&hmi_uart, 115200U);
}

static u32 elapsed_ms(u64 start_ticks)
{
    XTime now;

    XTime_GetTime(&now);
    return (u32)((((u64)now - start_ticks) * 1000ULL) /
        (u64)COUNTS_PER_SECOND);
}

static int frequency_key_initialize(void)
{
    XGpioPs_Config *config =
        XGpioPs_LookupConfig(PS_GPIO_DEVICE_ID);
    u32 level;
    int status;

    if (config == NULL)
        return XST_FAILURE;
    status = XGpioPs_CfgInitialize(
        &ps_gpio, config, config->BaseAddr);
    if (status != XST_SUCCESS)
        return status;
    XGpioPs_SetDirectionPin(&ps_gpio, PS_KEY1_MIO, 0U);
    level = XGpioPs_ReadPin(&ps_gpio, PS_KEY1_MIO) != 0U;
    frequency_key.candidate_level = level;
    frequency_key.stable_level = level;
    frequency_key.armed = level != 0U;
    XTime_GetTime(&frequency_key.candidate_since);
    frequency_mode = HMI_FREQUENCY_ROUNDED;
    hmi_set_frequency_mode(frequency_mode);
    return XST_SUCCESS;
}

static int frequency_key_pressed(void)
{
    const u64 debounce_ticks =
        ((u64)COUNTS_PER_SECOND * PS_KEY_DEBOUNCE_MS) / 1000ULL;
    u32 level = XGpioPs_ReadPin(&ps_gpio, PS_KEY1_MIO) != 0U;
    XTime now;

    XTime_GetTime(&now);
    if (level != frequency_key.candidate_level) {
        frequency_key.candidate_level = level;
        frequency_key.candidate_since = now;
        return 0;
    }
    if (level == frequency_key.stable_level ||
        (u64)(now - frequency_key.candidate_since) < debounce_ticks)
        return 0;

    frequency_key.stable_level = level;
    if (level != 0U) {
        frequency_key.armed = 1;
        return 0;
    }
    if (!frequency_key.armed)
        return 0;
    frequency_key.armed = 0;
    return 1;
}

static void service_frequency_key(void)
{
    if (!frequency_key_pressed())
        return;
    frequency_mode =
        frequency_mode == HMI_FREQUENCY_ROUNDED ?
        HMI_FREQUENCY_PRECISE : HMI_FREQUENCY_ROUNDED;
    hmi_set_frequency_mode(frequency_mode);
    if (active_page != HMI_PAGE_NONE && hmi_cache_valid())
        (void)hmi_refresh_cached_frequency(active_page);
}

static int stable_model(
    const measurement_result_t *previous,
    const measurement_result_t *current)
{
    u32 component;

    if (previous->component_count != current->component_count ||
        fabs(previous->fundamental_hz - current->fundamental_hz) > 1000.0)
        return 0;
    for (component = 0U; component < current->component_count; ++component) {
        if (previous->component[component].harmonic !=
                current->component[component].harmonic)
            return 0;
    }
    return 1;
}

static measure_outcome_t rejected_outcome(
    const measurement_result_t *trial)
{
    u32 flags = trial->quality.flags;

    if ((flags & MEAS_QUALITY_CLIPPED) != 0U)
        return MEASURE_OUTCOME_CLIPPED;
    if ((flags & MEAS_QUALITY_FFT_ERROR) != 0U)
        return MEASURE_OUTCOME_FFT_ERROR;
    if (trial->quality.reject_stage == MEAS_REJECT_CANDIDATES ||
        trial->quality.reject_stage == MEAS_REJECT_ENUMERATION)
        return MEASURE_OUTCOME_NO_SIGNAL;
    if ((flags & MEAS_QUALITY_DATA_INVALID) != 0U)
        return MEASURE_OUTCOME_DATA_INVALID;
    return MEASURE_OUTCOME_UNSTABLE;
}

static int request_aborts_measurement(hmi_page_t page)
{
    hmi_request_t request;

    while (hmi_poll_request(&request)) {
        if (request.code == HMI_REQUEST_ABORT && request.page == page)
            return 1;
    }
    return 0;
}

static measure_outcome_t perform_measurement(
    hmi_page_t page,
    u64 request_started_ticks,
    measurement_result_t *accepted)
{
    capture_record_t baseline_record;
    measurement_result_t previous;
    measurement_result_t last_trial;
    u32 baseline_frame = 0U;
    u32 analyzed_frame = 0U;
    u32 epoch_frame_count = 0U;
    u32 stable_count = 0U;
    u32 no_signal_count = 0U;
    int have_previous = 0;
    int have_last_trial = 0;
    u16 expected_epoch = 0U;

    memset(&baseline_record, 0, sizeof(baseline_record));
    memset(&previous, 0, sizeof(previous));
    if (capture_latest_matched(&baseline_record))
        baseline_frame = baseline_record.frame_id;
    analyzed_frame = baseline_frame;
    if (capture_start(&expected_epoch) != XST_SUCCESS)
        return MEASURE_OUTCOME_DATA_INVALID;

    while (elapsed_ms(request_started_ticks) <
            MEASUREMENT_TIMEOUT_MS) {
        capture_record_t record;
        measurement_result_t trial;
        int analyzed;
        int same_as_previous = 0;

        service_frequency_key();
        if (request_aborts_measurement(page)) {
            capture_stop();
            return MEASURE_OUTCOME_ABORTED;
        }
        if (!capture_latest_matched(&record) ||
            record.capture_epoch != expected_epoch ||
            record.frame_id == analyzed_frame ||
            (s32)(record.frame_id - baseline_frame) <= 0)
            continue;
        analyzed_frame = record.frame_id;
        ++epoch_frame_count;
        // The first complete record establishes a clean post-start boundary.
        // Only subsequent records participate in model validation.
        if (epoch_frame_count == 1U)
            continue;
        analyzed = measurement_analyze(
                record.samples_q8, record.sample_count,
                record.spectrum, MEAS_FFT_BINS,
                record.time_meta, record.spectrum_meta,
                &calibration, &trial);
        if (elapsed_ms(request_started_ticks) >=
                MEASUREMENT_TIMEOUT_MS) {
            capture_stop();
            return analyzed ? MEASURE_OUTCOME_TIMEOUT :
                rejected_outcome(&trial);
        }
        if (!analyzed) {
            last_trial = trial;
            have_last_trial = 1;
            if (trial.quality.reject_stage ==
                    MEAS_REJECT_CANDIDATES ||
                trial.quality.reject_stage ==
                    MEAS_REJECT_ENUMERATION) {
                ++no_signal_count;
                if (no_signal_count >=
                        NO_SIGNAL_CONFIRM_FRAMES) {
                    capture_stop();
                    return MEASURE_OUTCOME_NO_SIGNAL;
                }
            } else {
                no_signal_count = 0U;
            }
            continue;
        }
        no_signal_count = 0U;
        last_trial = trial;
        have_last_trial = 1;
        if ((trial.quality.flags & MEAS_QUALITY_VALID) == 0U) {
            continue;
        }
        same_as_previous = have_previous &&
            stable_model(&previous, &trial);
        if (same_as_previous)
            ++stable_count;
        else
            stable_count = 1U;
        previous = trial;
        have_previous = 1;
        if (stable_count >= 2U) {
            *accepted = trial;
            capture_stop();
            return MEASURE_OUTCOME_VALID;
        }
    }
    capture_stop();
    if (have_last_trial)
        return rejected_outcome(&last_trial);
    return MEASURE_OUTCOME_TIMEOUT;
}

static hmi_status_t outcome_status(measure_outcome_t outcome)
{
    switch (outcome) {
    case MEASURE_OUTCOME_NO_SIGNAL:
        return HMI_STATUS_NO_SIGNAL;
    case MEASURE_OUTCOME_UNSTABLE:
        return HMI_STATUS_UNSTABLE;
    case MEASURE_OUTCOME_CLIPPED:
        return HMI_STATUS_CLIPPED;
    case MEASURE_OUTCOME_FFT_ERROR:
        return HMI_STATUS_FFT_ERROR;
    case MEASURE_OUTCOME_TIMEOUT:
        return HMI_STATUS_TIMEOUT;
    default:
        return HMI_STATUS_DATA_INVALID;
    }
}

static void finish_page_update(
    hmi_page_t page, u64 request_started_ticks)
{
    int render_confirmed = hmi_wait_render_complete(page);
    u32 total_elapsed_ms = elapsed_ms(request_started_ticks);

    hmi_send_elapsed(page, total_elapsed_ms, render_confirmed);
}

static void handle_request(const hmi_request_t *request)
{
    active_page = request->page;
    if (request->code == HMI_REQUEST_CACHE) {
        if (!hmi_send_cached(request->page))
            hmi_send_ready(request->page);
        finish_page_update(request->page, request->started_ticks);
        return;
    }
    if (request->code == HMI_REQUEST_ABORT) {
        capture_stop();
        return;
    }
    if (request->code == HMI_REQUEST_MEASURE) {
        measurement_result_t result;
        measure_outcome_t outcome;

        hmi_cache_invalidate();
        outcome = perform_measurement(
            request->page, request->started_ticks, &result);
        if (outcome == MEASURE_OUTCOME_ABORTED)
            return;
        if (outcome != MEASURE_OUTCOME_VALID) {
            hmi_send_error(request->page, outcome_status(outcome));
            finish_page_update(
                request->page, request->started_ticks);
            return;
        }
        hmi_cache_store(&result);
        if (!hmi_send_cached(request->page))
            hmi_send_error(request->page, HMI_STATUS_DATA_INVALID);
        finish_page_update(request->page, request->started_ticks);
    }
}

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    if (uart_initialize() != XST_SUCCESS)
        return XST_FAILURE;
    if (!hmi_initialize(&hmi_uart))
        return XST_FAILURE;
    if (frequency_key_initialize() != XST_SUCCESS) {
        hmi_send_error(HMI_PAGE_TIME, HMI_STATUS_DATA_INVALID);
        return XST_FAILURE;
    }
    measurement_calibration_channel_b(&calibration);
    if (!measurement_selftest()) {
        hmi_send_error(HMI_PAGE_TIME, HMI_STATUS_DATA_INVALID);
        return XST_FAILURE;
    }
    if (capture_initialize() != XST_SUCCESS) {
        hmi_send_error(HMI_PAGE_TIME, HMI_STATUS_DATA_INVALID);
        return XST_FAILURE;
    }
    capture_stop();
    hmi_cache_invalidate();

    for (;;) {
        hmi_request_t request;

        service_frequency_key();
        if (hmi_poll_request(&request))
            handle_request(&request);
    }
}
