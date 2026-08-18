#include <math.h>
#include <stdio.h>
#include <string.h>
#include "hmi_protocol.h"
#include "xtime_l.h"
#include "xuartps_hw.h"

#define HMI_COMMAND_MAX 96U
#define HMI_TRANSFER_TIMEOUT_MS 500U
#define HMI_RENDER_TIMEOUT_MS 500U
#define HMI_RENDER_ACK_COMMAND 0x20U
#define HMI_COLOR_NORMAL 50712U
#define HMI_COLOR_DISABLED 33840U
#define HMI_COLOR_READY 2047U
#define HMI_COLOR_VALID 2016U
#define HMI_COLOR_WARNING 65504U
#define HMI_COLOR_ERROR 63488U
#define HMI_PLOT_CENTER 128.0
#define HMI_PLOT_HALF_RANGE 107.0
#define HMI_SPECTRUM_HEIGHT 230.0
#define TWO_PI 6.28318530717958647692
#define HMI_TEXT_MEASURE_GB2312 "\xB2\xE2\xC1\xBF"

typedef struct {
    int valid;
    measurement_result_t result;
    u8 time_one[HMI_WAVE_POINTS];
    u8 time_three[HMI_WAVE_POINTS];
    u8 spectrum[HMI_WAVE_POINTS];
} hmi_cache_t;

static XUartPs *hmi_uart;
static u8 parser_state;
static u8 parser_command;
static u8 parser_page;
static u64 parser_started_ticks;
static hmi_cache_t cache;
static hmi_frequency_mode_t frequency_mode = HMI_FREQUENCY_ROUNDED;

static void send_byte(u8 value)
{
    XUartPs_SendByte(hmi_uart->Config.BaseAddress, value);
}

static void send_bytes(const u8 *data, u32 length)
{
    u32 index;

    for (index = 0U; index < length; ++index)
        send_byte(data[index]);
}

static void send_command(const char *command)
{
    static const u8 terminator[3] = {0xFFU, 0xFFU, 0xFFU};

    send_bytes((const u8 *)command, (u32)strlen(command));
    send_bytes(terminator, sizeof(terminator));
}

static int receive_byte(u8 *value)
{
    if (!XUartPs_IsReceiveData(hmi_uart->Config.BaseAddress))
        return 0;
    *value = XUartPs_RecvByte(hmi_uart->Config.BaseAddress);
    return 1;
}

static int wait_marker(u8 marker, u32 timeout_ms)
{
    XTime start;
    XTime now;
    u8 state = 0U;
    u8 value;
    u64 elapsed_ms;

    XTime_GetTime(&start);
    for (;;) {
        while (receive_byte(&value)) {
            if (state == 0U) {
                state = value == marker ? 1U : 0U;
            } else if (value == 0xFFU) {
                ++state;
                if (state == 4U)
                    return 1;
            } else {
                state = value == marker ? 1U : 0U;
            }
        }
        XTime_GetTime(&now);
        elapsed_ms = ((u64)(now - start) * 1000ULL) /
            (u64)COUNTS_PER_SECOND;
        if (elapsed_ms >= timeout_ms)
            return 0;
    }
}

static int wait_sequence(
    const u8 *sequence, u32 length, u32 timeout_ms)
{
    XTime start;
    XTime now;
    u32 matched = 0U;
    u8 value;
    u64 elapsed_ms;

    if (sequence == NULL || length == 0U)
        return 0;
    XTime_GetTime(&start);
    for (;;) {
        while (receive_byte(&value)) {
            if (value == sequence[matched]) {
                ++matched;
                if (matched == length)
                    return 1;
            } else {
                matched = value == sequence[0] ? 1U : 0U;
            }
        }
        XTime_GetTime(&now);
        elapsed_ms = ((u64)(now - start) * 1000ULL) /
            (u64)COUNTS_PER_SECOND;
        if (elapsed_ms >= timeout_ms)
            return 0;
    }
}

static void begin_request_frame(void)
{
    XTime now;

    XTime_GetTime(&now);
    parser_started_ticks = (u64)now;
    parser_state = 1U;
}

static int send_wave(const char *name, const u8 *points)
{
    char command[HMI_COMMAND_MAX];

    (void)snprintf(
        command, sizeof(command), "addt %s.id,0,%lu",
        name, (unsigned long)HMI_WAVE_POINTS);
    send_command(command);
    if (!wait_marker(0xFEU, HMI_TRANSFER_TIMEOUT_MS))
        return 0;
    send_bytes(points, HMI_WAVE_POINTS);
    return wait_marker(0xFDU, HMI_TRANSFER_TIMEOUT_MS);
}

static u8 plot_value(double value)
{
    long rounded = (long)floor(value + 0.5);

    if (rounded < 20L)
        rounded = 20L;
    if (rounded > 235L)
        rounded = 235L;
    return (u8)rounded;
}

static void build_time_wave(
    const measurement_result_t *result,
    double periods,
    u8 points[HMI_WAVE_POINTS])
{
    double peak_sum = 0.0;
    double scale;
    u32 component;
    u32 index;

    for (component = 0U; component < result->component_count; ++component)
        peak_sum += fabs(result->component[component].amplitude_peak_v);
    scale = peak_sum > 0.0 ? HMI_PLOT_HALF_RANGE / peak_sum : 0.0;
    for (index = 0U; index < HMI_WAVE_POINTS; ++index) {
        double phase_cycles = periods * (double)index /
            (double)(HMI_WAVE_POINTS - 1U);
        double time = phase_cycles / result->fundamental_hz;
        double voltage = 0.0;
        for (component = 0U;
             component < result->component_count;
             ++component) {
            const measurement_component_t *line = &result->component[component];
            voltage += line->amplitude_peak_v * cos(
                TWO_PI * line->frequency_hz * time + line->phase_rad);
        }
        points[index] = plot_value(HMI_PLOT_CENTER + scale * voltage);
    }
}

static void build_spectrum(
    const measurement_result_t *result,
    u8 points[HMI_WAVE_POINTS])
{
    double maximum = 0.0;
    u32 component;

    memset(points, 0, HMI_WAVE_POINTS);
    for (component = 0U; component < result->component_count; ++component) {
        if (result->component[component].amplitude_peak_v > maximum)
            maximum = result->component[component].amplitude_peak_v;
    }
    if (maximum <= 0.0)
        return;
    for (component = 0U; component < result->component_count; ++component) {
        const measurement_component_t *line = &result->component[component];
        long frequency_position = (long)floor(
            line->display_frequency_hz *
            (double)(HMI_WAVE_POINTS - 1U) /
            MEAS_MAX_FREQUENCY_HZ + 0.5);
        /*
         * The display's waveform component consumes addt data from the
         * right-hand side.  Reverse the transfer index so increasing
         * frequency is shown from left to right on the positive axis.
         */
        long position = (long)(HMI_WAVE_POINTS - 1U) -
            frequency_position;
        long height = (long)floor(
            HMI_SPECTRUM_HEIGHT * line->amplitude_peak_v / maximum + 0.5);
        if (position < 1L)
            position = 1L;
        if (position >= (long)HMI_WAVE_POINTS - 1L)
            position = (long)HMI_WAVE_POINTS - 2L;
        if (height < 1L)
            height = 1L;
        if (height > 255L)
            height = 255L;
        points[position] = (u8)height;
    }
}

static void send_text(const char *name, const char *value)
{
    char command[HMI_COMMAND_MAX];

    (void)snprintf(command, sizeof(command), "%s.txt=\"%s\"", name, value);
    send_command(command);
}

static void send_number(const char *name, const char *property, u32 value)
{
    char command[HMI_COMMAND_MAX];

    (void)snprintf(
        command, sizeof(command), "%s.%s=%lu",
        name, property, (unsigned long)value);
    send_command(command);
}

static void send_touch(const char *name, int enabled)
{
    char command[HMI_COMMAND_MAX];

    (void)snprintf(
        command, sizeof(command), "tsw %s,%u", name, enabled ? 1U : 0U);
    send_command(command);
}

static void format_voltage(char *text, size_t size, double volts)
{
    (void)snprintf(text, size, "%.3f mV", 1000.0 * volts);
}

static void format_frequency(char *text, size_t size, double frequency_hz)
{
    double display_hz = frequency_hz;

    if (frequency_mode == HMI_FREQUENCY_ROUNDED) {
        display_hz = 500.0 * floor(frequency_hz / 500.0 + 0.5);
        (void)snprintf(text, size, "%.3f kHz", display_hz / 1000.0);
    } else {
        (void)snprintf(text, size, "%.5f kHz", display_hz / 1000.0);
    }
}

static const char *status_text(hmi_status_t status)
{
    switch (status) {
    case HMI_STATUS_VALID:
        return "VALID";
    case HMI_STATUS_UNSTABLE:
        return "UNSTABLE";
    case HMI_STATUS_UNCALIBRATED:
        return "UNCALIBRATED";
    case HMI_STATUS_CLIPPED:
        return "CLIPPED";
    case HMI_STATUS_FFT_ERROR:
        return "FFT ERROR";
    case HMI_STATUS_DATA_INVALID:
        return "DATA INVALID";
    case HMI_STATUS_NO_SIGNAL:
        return "NO SIGNAL";
    case HMI_STATUS_TIMEOUT:
        return "TIMEOUT";
    default:
        return "READY";
    }
}

static u32 status_color(hmi_status_t status)
{
    switch (status) {
    case HMI_STATUS_VALID:
        return HMI_COLOR_VALID;
    case HMI_STATUS_CLIPPED:
    case HMI_STATUS_FFT_ERROR:
    case HMI_STATUS_DATA_INVALID:
    case HMI_STATUS_TIMEOUT:
        return HMI_COLOR_ERROR;
    case HMI_STATUS_UNSTABLE:
    case HMI_STATUS_UNCALIBRATED:
    case HMI_STATUS_NO_SIGNAL:
        return HMI_COLOR_WARNING;
    default:
        return HMI_COLOR_READY;
    }
}

static hmi_status_t result_status(const measurement_result_t *result)
{
    u32 flags = result->quality.flags;

    if ((flags & MEAS_QUALITY_CLIPPED) != 0U)
        return HMI_STATUS_CLIPPED;
    if ((flags & MEAS_QUALITY_FFT_ERROR) != 0U)
        return HMI_STATUS_FFT_ERROR;
    if ((flags & MEAS_QUALITY_DATA_INVALID) != 0U)
        return HMI_STATUS_DATA_INVALID;
    if ((flags & MEAS_QUALITY_AMBIGUOUS) != 0U)
        return HMI_STATUS_UNSTABLE;
    if ((flags & MEAS_QUALITY_UNCALIBRATED) != 0U)
        return HMI_STATUS_UNCALIBRATED;
    return HMI_STATUS_VALID;
}

static void restore_time_buttons(void)
{
    send_text("btnRefresh", HMI_TEXT_MEASURE_GB2312);
    send_number("btnCycles", "bco", HMI_COLOR_NORMAL);
    send_number("btnRefresh", "bco", HMI_COLOR_NORMAL);
    send_number("btnFreq", "bco", HMI_COLOR_NORMAL);
    send_touch("btnCycles", 1);
    send_touch("btnRefresh", 1);
    send_touch("btnFreq", 1);
}

static void restore_freq_buttons(void)
{
    send_text("btnRefresh", HMI_TEXT_MEASURE_GB2312);
    send_number("btnRefresh", "bco", HMI_COLOR_NORMAL);
    send_number("btnTime", "bco", HMI_COLOR_NORMAL);
    send_touch("btnRefresh", 1);
    send_touch("btnTime", 1);
}

static void clear_time_values(void)
{
    send_text("txtVpp", "---.--- mV");
    send_text("txtUrms", "---.--- mV");
    send_text("txtF1", "---.--- kHz");
}

static void clear_freq_values(void)
{
    send_text("txtF1", "---.--- kHz");
    send_text("txtA1", "---.--- mV");
    send_text("txtF2", "---.--- kHz");
    send_text("txtA2", "---.--- mV");
    send_text("txtF3", "---.--- kHz");
    send_text("txtA3", "---.--- mV");
}

static void send_state(hmi_status_t status)
{
    send_text("txtState", status_text(status));
    send_number("txtState", "pco", status_color(status));
}

static int send_time_cache(void)
{
    char text[32];

    send_command("tmTimeOut.en=0");
    send_command("cle wavTime1.id,255");
    send_command("cle wavTime3.id,255");
    if (!send_wave("wavTime1", cache.time_one) ||
        !send_wave("wavTime3", cache.time_three))
        return 0;
    format_voltage(text, sizeof(text), cache.result.reconstructed_pp_v);
    send_text("txtVpp", text);
    format_voltage(text, sizeof(text), cache.result.total_rms_v);
    send_text("txtUrms", text);
    format_frequency(text, sizeof(text), cache.result.fundamental_hz);
    send_text("txtF1", text);
    send_state(result_status(&cache.result));
    send_command("pgTime.varHasData.val=1");
    restore_time_buttons();
    return 1;
}

static int send_freq_cache(void)
{
    char text[32];
    u32 component;

    send_command("tmFreqOut.en=0");
    send_command("cle wavFreq.id,255");
    if (!send_wave("wavFreq", cache.spectrum))
        return 0;
    clear_freq_values();
    for (component = 0U;
         component < cache.result.component_count &&
         component < MEAS_MAX_COMPONENTS;
         ++component) {
        char frequency_name[8];
        char amplitude_name[8];
        const measurement_component_t *line = &cache.result.component[component];
        (void)snprintf(
            frequency_name, sizeof(frequency_name),
            "txtF%lu", (unsigned long)(component + 1U));
        (void)snprintf(
            amplitude_name, sizeof(amplitude_name),
            "txtA%lu", (unsigned long)(component + 1U));
        format_frequency(text, sizeof(text), line->frequency_hz);
        send_text(frequency_name, text);
        format_voltage(text, sizeof(text), line->amplitude_peak_v);
        send_text(amplitude_name, text);
    }
    send_state(result_status(&cache.result));
    send_command("pgTime.varHasData.val=1");
    restore_freq_buttons();
    return 1;
}

int hmi_initialize(XUartPs *uart)
{
    if (uart == NULL)
        return 0;
    hmi_uart = uart;
    parser_state = 0U;
    parser_command = 0U;
    parser_page = 0U;
    parser_started_ticks = 0U;
    frequency_mode = HMI_FREQUENCY_ROUNDED;
    memset(&cache, 0, sizeof(cache));
    return 1;
}

int hmi_poll_request(hmi_request_t *request)
{
    u8 value;

    if (request == NULL)
        return 0;
    while (receive_byte(&value)) {
        switch (parser_state) {
        case 0U:
            if (value == 0x55U)
                begin_request_frame();
            break;
        case 1U:
            if (value == 0xAAU)
                parser_state = 2U;
            else if (value == 0x55U)
                begin_request_frame();
            else
                parser_state = 0U;
            break;
        case 2U:
            parser_command = value;
            parser_state = 3U;
            break;
        case 3U:
            parser_page = value;
            parser_state = 4U;
            break;
        case 4U:
            if (value == 0x0DU)
                parser_state = 5U;
            else if (value == 0x55U)
                begin_request_frame();
            else
                parser_state = 0U;
            break;
        default:
            parser_state = 0U;
            if (value == 0x0AU &&
                (parser_command == HMI_REQUEST_MEASURE ||
                 parser_command == HMI_REQUEST_CACHE ||
                 parser_command == HMI_REQUEST_ABORT) &&
                (parser_page == HMI_PAGE_TIME ||
                 parser_page == HMI_PAGE_FREQ)) {
                request->code = (hmi_request_code_t)parser_command;
                request->page = (hmi_page_t)parser_page;
                request->started_ticks = parser_started_ticks;
                return 1;
            }
            if (value == 0x55U)
                begin_request_frame();
            break;
        }
    }
    return 0;
}

void hmi_cache_invalidate(void)
{
    cache.valid = 0;
}

int hmi_cache_valid(void)
{
    return cache.valid;
}

void hmi_cache_store(const measurement_result_t *result)
{
    if (result == NULL)
        return;
    cache.result = *result;
    build_time_wave(result, 1.0, cache.time_one);
    build_time_wave(result, 3.0, cache.time_three);
    build_spectrum(result, cache.spectrum);
    cache.valid = 1;
}

int hmi_send_cached(hmi_page_t page)
{
    if (!cache.valid)
        return 0;
    if (page == HMI_PAGE_TIME)
        return send_time_cache();
    if (page == HMI_PAGE_FREQ)
        return send_freq_cache();
    return 0;
}

int hmi_refresh_cached_frequency(hmi_page_t page)
{
    char text[32];
    u32 component;

    if (!cache.valid)
        return 0;
    if (page == HMI_PAGE_TIME) {
        format_frequency(
            text, sizeof(text), cache.result.fundamental_hz);
        send_text("txtF1", text);
        return 1;
    }
    if (page != HMI_PAGE_FREQ)
        return 0;
    for (component = 0U;
         component < cache.result.component_count &&
         component < MEAS_MAX_COMPONENTS;
         ++component) {
        char frequency_name[8];
        const measurement_component_t *line =
            &cache.result.component[component];

        (void)snprintf(
            frequency_name, sizeof(frequency_name),
            "txtF%lu", (unsigned long)(component + 1U));
        format_frequency(text, sizeof(text), line->frequency_hz);
        send_text(frequency_name, text);
    }
    return 1;
}

void hmi_set_frequency_mode(hmi_frequency_mode_t mode)
{
    frequency_mode = mode == HMI_FREQUENCY_PRECISE ?
        HMI_FREQUENCY_PRECISE : HMI_FREQUENCY_ROUNDED;
}

int hmi_wait_render_complete(hmi_page_t page)
{
    char command[HMI_COMMAND_MAX];
    u8 acknowledgement[6];

    if (page != HMI_PAGE_TIME && page != HMI_PAGE_FREQ)
        return 0;
    acknowledgement[0] = 0x55U;
    acknowledgement[1] = 0xAAU;
    acknowledgement[2] = HMI_RENDER_ACK_COMMAND;
    acknowledgement[3] = (u8)page;
    acknowledgement[4] = 0x0DU;
    acknowledgement[5] = 0x0AU;

    send_command("doevents");
    (void)snprintf(
        command, sizeof(command),
        "printh 55 AA %02X %02X 0D 0A",
        (unsigned int)HMI_RENDER_ACK_COMMAND,
        (unsigned int)page);
    send_command(command);
    return wait_sequence(
        acknowledgement, sizeof(acknowledgement),
        HMI_RENDER_TIMEOUT_MS);
}

void hmi_send_elapsed(
    hmi_page_t page, u32 elapsed_ms, int render_confirmed)
{
    char text[32];
    u32 color;

    if (page != HMI_PAGE_TIME && page != HMI_PAGE_FREQ)
        return;
    if (!render_confirmed) {
        send_text("txtElapsed", "ACK TIMEOUT");
        send_number("txtElapsed", "pco", HMI_COLOR_ERROR);
        send_command("doevents");
        return;
    }
    (void)snprintf(
        text, sizeof(text), "%lu ms", (unsigned long)elapsed_ms);
    color = elapsed_ms <= HMI_RESULT_DEADLINE_MS ?
        HMI_COLOR_VALID : HMI_COLOR_ERROR;
    send_text("txtElapsed", text);
    send_number("txtElapsed", "pco", color);
    send_command("doevents");
}

void hmi_send_ready(hmi_page_t page)
{
    send_command("pgTime.varHasData.val=0");
    if (page == HMI_PAGE_TIME) {
        send_command("tmTimeOut.en=0");
        send_command("cle wavTime1.id,255");
        send_command("cle wavTime3.id,255");
        clear_time_values();
        send_state(HMI_STATUS_READY);
        restore_time_buttons();
    } else if (page == HMI_PAGE_FREQ) {
        send_command("tmFreqOut.en=0");
        send_command("cle wavFreq.id,255");
        clear_freq_values();
        send_state(HMI_STATUS_READY);
        restore_freq_buttons();
    }
}

void hmi_send_error(hmi_page_t page, hmi_status_t status)
{
    hmi_cache_invalidate();
    send_command("pgTime.varHasData.val=0");
    if (page == HMI_PAGE_TIME) {
        send_command("tmTimeOut.en=0");
        send_command("cle wavTime1.id,255");
        send_command("cle wavTime3.id,255");
        clear_time_values();
        send_state(status);
        restore_time_buttons();
    } else if (page == HMI_PAGE_FREQ) {
        send_command("tmFreqOut.en=0");
        send_command("cle wavFreq.id,255");
        clear_freq_values();
        send_state(status);
        restore_freq_buttons();
    }
}
