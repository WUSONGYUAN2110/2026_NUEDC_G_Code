#include <string.h>
#include <stdlib.h>
#include "capture.h"
#include "xaxidma.h"
#include "xgpio.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xparameters.h"
#include "xscugic.h"
#include "xstatus.h"

#if defined(XPAR_DMA_TIME_DEVICE_ID)
#define TIME_DMA_DEVICE_ID XPAR_DMA_TIME_DEVICE_ID
#else
#define TIME_DMA_DEVICE_ID XPAR_AXIDMA_1_DEVICE_ID
#endif

#if defined(XPAR_DMA_SPECTRUM_DEVICE_ID)
#define SPECTRUM_DMA_DEVICE_ID XPAR_DMA_SPECTRUM_DEVICE_ID
#else
#define SPECTRUM_DMA_DEVICE_ID XPAR_AXIDMA_0_DEVICE_ID
#endif

#if defined(XPAR_MEASUREMENT_GPIO_DEVICE_ID)
#define MEAS_GPIO_DEVICE_ID XPAR_MEASUREMENT_GPIO_DEVICE_ID
#else
#define MEAS_GPIO_DEVICE_ID XPAR_AXI_GPIO_0_DEVICE_ID
#endif

#if defined(XPAR_FABRIC_DMA_TIME_S2MM_INTROUT_INTR)
#define TIME_DMA_IRQ_ID XPAR_FABRIC_DMA_TIME_S2MM_INTROUT_INTR
#else
#define TIME_DMA_IRQ_ID XPAR_FABRIC_AXIDMA_1_S2MM_INTROUT_VEC_ID
#endif

#if defined(XPAR_FABRIC_DMA_SPECTRUM_S2MM_INTROUT_INTR)
#define SPECTRUM_DMA_IRQ_ID XPAR_FABRIC_DMA_SPECTRUM_S2MM_INTROUT_INTR
#else
#define SPECTRUM_DMA_IRQ_ID XPAR_FABRIC_AXIDMA_0_S2MM_INTROUT_VEC_ID
#endif

#define BD_ALIGNMENT XAXIDMA_BD_MINIMUM_ALIGNMENT
#define TIME_RECORD_WORDS \
    (MEAS_SHORT_SAMPLES + MEAS_TIME_TRAILER_WORDS)
#define SPECTRUM_RECORD_BEATS \
    (MEAS_FFT_BINS + MEAS_SPECTRUM_TRAILER_BEATS)

static XAxiDma time_dma;
static XAxiDma spectrum_dma;
static XAxiDma_Config *time_dma_config;
static XAxiDma_Config *spectrum_dma_config;
static XGpio measurement_gpio;
static XScuGic interrupt_controller;
static volatile u32 dma_error_flags;
static u32 control_shadow;

static u8 time_bd_space[
    CAPTURE_DESCRIPTOR_COUNT * XAXIDMA_BD_MINIMUM_ALIGNMENT]
    __attribute__((aligned(BD_ALIGNMENT)));
static u8 spectrum_bd_space[
    CAPTURE_DESCRIPTOR_COUNT * XAXIDMA_BD_MINIMUM_ALIGNMENT]
    __attribute__((aligned(BD_ALIGNMENT)));

static s32 time_records[CAPTURE_DESCRIPTOR_COUNT][TIME_RECORD_WORDS]
    __attribute__((aligned(64)));
static u64 spectrum_records[CAPTURE_DESCRIPTOR_COUNT][SPECTRUM_RECORD_BEATS]
    __attribute__((aligned(64)));
static s32 time_snapshot[TIME_RECORD_WORDS] __attribute__((aligned(64)));
static u64 spectrum_snapshot[SPECTRUM_RECORD_BEATS]
    __attribute__((aligned(64)));
static void write_control(u32 value)
{
    control_shadow = value;
    XGpio_DiscreteWrite(&measurement_gpio, 1U, control_shadow);
}

u32 capture_status(void)
{
    return XGpio_DiscreteRead(&measurement_gpio, 2U);
}

static u16 status_capture_epoch(u32 status)
{
    return (u16)((status & MEAS_STATUS_EPOCH_MASK) >>
        MEAS_STATUS_EPOCH_SHIFT);
}

static int setup_receive_ring(
    XAxiDma *dma,
    u8 *bd_space,
    UINTPTR buffer_base,
    u32 stride,
    u32 descriptor_count,
    int cyclic)
{
    XAxiDma_BdRing *ring = XAxiDma_GetRxRing(dma);
    XAxiDma_Bd template_bd;
    XAxiDma_Bd *first_bd;
    XAxiDma_Bd *bd;
    u32 index;
    int status;

    XAxiDma_BdRingIntDisable(ring, XAXIDMA_IRQ_ALL_MASK);
    status = XAxiDma_BdRingCreate(
        ring, (UINTPTR)bd_space, (UINTPTR)bd_space,
        BD_ALIGNMENT, descriptor_count);
    if (status != XST_SUCCESS)
        return status;

    XAxiDma_BdClear(&template_bd);
    status = XAxiDma_BdRingClone(ring, &template_bd);
    if (status != XST_SUCCESS)
        return status;
    status = XAxiDma_BdRingAlloc(ring, descriptor_count, &first_bd);
    if (status != XST_SUCCESS)
        return status;

    bd = first_bd;
    for (index = 0U; index < descriptor_count; ++index) {
        UINTPTR address = buffer_base + (UINTPTR)stride * index;
        status = XAxiDma_BdSetBufAddr(bd, address);
        if (status != XST_SUCCESS)
            return status;
        status = XAxiDma_BdSetLength(bd, stride, ring->MaxTransferLen);
        if (status != XST_SUCCESS)
            return status;
        XAxiDma_BdSetCtrl(bd, 0U);
        XAxiDma_BdSetId(bd, address);
        bd = (XAxiDma_Bd *)XAxiDma_BdRingNext(ring, bd);
    }
    status = XAxiDma_BdRingSetCoalesce(ring, 1U, 0U);
    if (status != XST_SUCCESS)
        return status;
    status = XAxiDma_BdRingToHw(ring, descriptor_count, first_bd);
    if (status != XST_SUCCESS)
        return status;

    if (cyclic) {
        XAxiDma_BdRingEnableCyclicDMA(ring);
        status = XAxiDma_SelectCyclicMode(
            dma, XAXIDMA_DEVICE_TO_DMA, 1);
        if (status != XST_SUCCESS)
            return status;
    }
    XAxiDma_BdRingIntEnable(ring, XAXIDMA_IRQ_ALL_MASK);
    return XAxiDma_BdRingStart(ring);
}

static void dma_interrupt(void *callback)
{
    XAxiDma *dma = (XAxiDma *)callback;
    XAxiDma_BdRing *ring = XAxiDma_GetRxRing(dma);
    u32 irq = XAxiDma_BdRingGetIrq(ring);
    XAxiDma_Bd *completed;

    XAxiDma_BdRingAckIrq(ring, irq);
    if ((irq & XAXIDMA_IRQ_ERROR_MASK) != 0U) {
        if (dma == &time_dma)
            dma_error_flags |= 1U;
        else
            dma_error_flags |= 2U;
        return;
    }
    if ((irq & (XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_DELAY_MASK)) != 0U)
        (void)XAxiDma_BdRingFromHw(ring, XAXIDMA_ALL_BDS, &completed);
}

static int setup_interrupts(void)
{
    XScuGic_Config *config =
        XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    int status;
    if (config == NULL)
        return XST_FAILURE;
    status = XScuGic_CfgInitialize(
        &interrupt_controller, config, config->CpuBaseAddress);
    if (status != XST_SUCCESS)
        return status;

    XScuGic_SetPriorityTriggerType(
        &interrupt_controller, TIME_DMA_IRQ_ID, 0xA0U, 0x3U);
    XScuGic_SetPriorityTriggerType(
        &interrupt_controller, SPECTRUM_DMA_IRQ_ID, 0xA0U, 0x3U);
    status = XScuGic_Connect(
        &interrupt_controller, TIME_DMA_IRQ_ID,
        (Xil_InterruptHandler)dma_interrupt, &time_dma);
    if (status != XST_SUCCESS)
        return status;
    status = XScuGic_Connect(
        &interrupt_controller, SPECTRUM_DMA_IRQ_ID,
        (Xil_InterruptHandler)dma_interrupt, &spectrum_dma);
    if (status != XST_SUCCESS)
        return status;
    XScuGic_Enable(&interrupt_controller, TIME_DMA_IRQ_ID);
    XScuGic_Enable(&interrupt_controller, SPECTRUM_DMA_IRQ_ID);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(
        XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler,
        &interrupt_controller);
    Xil_ExceptionEnable();
    return XST_SUCCESS;
}

static int setup_short_rings(void)
{
    int status;
    memset(time_records, 0, sizeof(time_records));
    memset(spectrum_records, 0, sizeof(spectrum_records));
    Xil_DCacheFlushRange((UINTPTR)time_records, sizeof(time_records));
    Xil_DCacheFlushRange((UINTPTR)spectrum_records, sizeof(spectrum_records));

    status = setup_receive_ring(
        &time_dma, time_bd_space, (UINTPTR)time_records,
        MEAS_TIME_RECORD_BYTES, CAPTURE_DESCRIPTOR_COUNT, 1);
    if (status != XST_SUCCESS)
        return status;
    return setup_receive_ring(
        &spectrum_dma, spectrum_bd_space, (UINTPTR)spectrum_records,
        MEAS_SPECTRUM_RECORD_BYTES, CAPTURE_DESCRIPTOR_COUNT, 1);
}

int capture_initialize(void)
{
    int status;
    time_dma_config = XAxiDma_LookupConfig(TIME_DMA_DEVICE_ID);
    spectrum_dma_config = XAxiDma_LookupConfig(SPECTRUM_DMA_DEVICE_ID);
    if (time_dma_config == NULL || spectrum_dma_config == NULL)
        return XST_FAILURE;
    status = XAxiDma_CfgInitialize(&time_dma, time_dma_config);
    if (status != XST_SUCCESS || !XAxiDma_HasSg(&time_dma))
        return XST_FAILURE;
    status = XAxiDma_CfgInitialize(&spectrum_dma, spectrum_dma_config);
    if (status != XST_SUCCESS || !XAxiDma_HasSg(&spectrum_dma))
        return XST_FAILURE;
    status = XGpio_Initialize(&measurement_gpio, MEAS_GPIO_DEVICE_ID);
    if (status != XST_SUCCESS)
        return status;
    XGpio_SetDataDirection(&measurement_gpio, 1U, 0x00000000U);
    XGpio_SetDataDirection(&measurement_gpio, 2U, 0xFFFFFFFFU);
    write_control(0U);
    dma_error_flags = 0U;

    status = setup_interrupts();
    if (status != XST_SUCCESS)
        return status;
    write_control(MEAS_CTRL_SOFT_RESET);
    write_control(0U);
    return setup_short_rings();
}

int capture_start(u16 *capture_epoch)
{
    u32 status = capture_status();
    u16 previous_epoch = status_capture_epoch(status);
    u32 timeout = 1000000U;

    if ((status & MEAS_STATUS_MMCM_LOCKED) == 0U)
        return XST_FAILURE;
    write_control(MEAS_CTRL_RUN | MEAS_CTRL_FFT_ENABLE);
    do {
        status = capture_status();
        if (status_capture_epoch(status) != previous_epoch) {
            if (capture_epoch != NULL)
                *capture_epoch = status_capture_epoch(status);
            return XST_SUCCESS;
        }
    } while (timeout-- != 0U);
    capture_stop();
    return XST_FAILURE;
}

void capture_stop(void)
{
    u32 timeout = 10000000U;
    u32 drain_control = control_shadow & ~MEAS_CTRL_RUN;
    u32 busy_mask = MEAS_STATUS_FRAME_ACTIVE |
        MEAS_STATUS_FFT_ACTIVE | MEAS_STATUS_SPECTRUM_BUSY;

    // Keep the FFT enabled until the active time/FFT records and spectrum
    // trailer have drained.  Clearing it together with RUN truncates the FFT
    // input frame and leaves stale work for the next measurement session.
    write_control(drain_control);
    while ((capture_status() & busy_mask) != 0U &&
           timeout-- != 0U) {
        /* All active records retain their latched per-frame controls. */
    }
    write_control(drain_control & ~MEAS_CTRL_FFT_ENABLE);
}

u32 capture_dma_errors(void)
{
    return dma_error_flags;
}

static int time_trailer_valid(const measurement_time_trailer_t *meta)
{
    return meta->magic == MEAS_TIME_MAGIC &&
        meta->format_version == MEAS_FORMAT_VERSION &&
        meta->sample_count == MEAS_SHORT_SAMPLES &&
        meta->check == (MEAS_TIME_MAGIC ^ meta->frame_id);
}

static int spectrum_trailer_valid(
    const measurement_spectrum_trailer_t *meta)
{
    u32 magic = (u32)(meta->magic_version & 0xFFFFFFFFULL);
    u32 version = (u32)(meta->magic_version >> 32);
    u32 frame = (u32)(meta->frame_id & 0xFFFFFFFFULL);
    u32 check_frame = (u32)(meta->check & 0xFFFFFFFFULL);
    u32 check_magic = (u32)(meta->check >> 32);
    return magic == MEAS_SPECTRUM_MAGIC &&
        version == MEAS_FORMAT_VERSION &&
        frame != 0U &&
        (meta->reserved[0] & MEAS_STATUS_FFT_WARMUP) == 0U &&
        (u32)(meta->bin_count & 0xFFFFULL) == MEAS_FFT_BINS &&
        check_frame == frame &&
        check_magic == (MEAS_SPECTRUM_MAGIC ^ frame);
}

int capture_latest_matched(capture_record_t *record)
{
    u32 time_frame[CAPTURE_DESCRIPTOR_COUNT];
    u32 spectrum_frame[CAPTURE_DESCRIPTOR_COUNT];
    u16 time_epoch[CAPTURE_DESCRIPTOR_COUNT];
    u16 spectrum_epoch[CAPTURE_DESCRIPTOR_COUNT];
    u8 time_valid[CAPTURE_DESCRIPTOR_COUNT];
    u8 spectrum_valid[CAPTURE_DESCRIPTOR_COUNT];
    u32 ti;
    u32 si;
    int found = 0;
    u32 best_frame = 0U;

    if (record == NULL)
        return 0;
    memset(time_valid, 0, sizeof(time_valid));
    memset(spectrum_valid, 0, sizeof(spectrum_valid));
    for (ti = 0U; ti < CAPTURE_DESCRIPTOR_COUNT; ++ti) {
        measurement_time_trailer_t *tm =
            (measurement_time_trailer_t *)&time_records[ti][MEAS_SHORT_SAMPLES];
        Xil_DCacheInvalidateRange((UINTPTR)tm, sizeof(*tm));
        if (time_trailer_valid(tm)) {
            time_valid[ti] = 1U;
            time_frame[ti] = tm->frame_id;
            time_epoch[ti] = measurement_time_epoch(tm);
        }
    }
    for (si = 0U; si < CAPTURE_DESCRIPTOR_COUNT; ++si) {
        measurement_spectrum_trailer_t *sm =
            (measurement_spectrum_trailer_t *)
            &spectrum_records[si][MEAS_FFT_BINS];
        Xil_DCacheInvalidateRange((UINTPTR)sm, sizeof(*sm));
        if (spectrum_trailer_valid(sm)) {
            spectrum_valid[si] = 1U;
            spectrum_frame[si] = (u32)sm->frame_id;
            spectrum_epoch[si] = measurement_spectrum_epoch(sm);
        }
    }
    for (ti = 0U; ti < CAPTURE_DESCRIPTOR_COUNT; ++ti) {
        if (!time_valid[ti])
            continue;
        for (si = 0U; si < CAPTURE_DESCRIPTOR_COUNT; ++si) {
            if (spectrum_valid[si] &&
                spectrum_frame[si] == time_frame[ti] &&
                spectrum_epoch[si] == time_epoch[ti] &&
                (!found || (s32)(time_frame[ti] - best_frame) > 0)) {
                found = 1;
                best_frame = time_frame[ti];
                record->samples_q8 = time_records[ti];
                record->spectrum = spectrum_records[si];
                record->time_meta = (measurement_time_trailer_t *)
                    &time_records[ti][MEAS_SHORT_SAMPLES];
                record->spectrum_meta = (measurement_spectrum_trailer_t *)
                    &spectrum_records[si][MEAS_FFT_BINS];
                record->frame_id = best_frame;
                record->capture_epoch = time_epoch[ti];
                record->sample_count = MEAS_SHORT_SAMPLES;
            }
        }
    }
    if (found) {
        const s32 *source_time = record->samples_q8;
        const u64 *source_spectrum = record->spectrum;
        measurement_time_trailer_t *snapshot_time;
        measurement_spectrum_trailer_t *snapshot_spectrum;
        Xil_DCacheInvalidateRange(
            (UINTPTR)source_time, MEAS_TIME_RECORD_BYTES);
        Xil_DCacheInvalidateRange(
            (UINTPTR)source_spectrum, MEAS_SPECTRUM_RECORD_BYTES);
        memcpy(time_snapshot, source_time, MEAS_TIME_RECORD_BYTES);
        memcpy(spectrum_snapshot, source_spectrum, MEAS_SPECTRUM_RECORD_BYTES);
        snapshot_time = (measurement_time_trailer_t *)
            &time_snapshot[MEAS_SHORT_SAMPLES];
        snapshot_spectrum = (measurement_spectrum_trailer_t *)
            &spectrum_snapshot[MEAS_FFT_BINS];
        if (!time_trailer_valid(snapshot_time) ||
            !spectrum_trailer_valid(snapshot_spectrum) ||
            snapshot_time->frame_id != best_frame ||
            (u32)snapshot_spectrum->frame_id != best_frame ||
            measurement_time_epoch(snapshot_time) !=
                record->capture_epoch ||
            measurement_spectrum_epoch(snapshot_spectrum) !=
                record->capture_epoch)
            return 0;
        record->samples_q8 = time_snapshot;
        record->spectrum = spectrum_snapshot;
        record->time_meta = snapshot_time;
        record->spectrum_meta = snapshot_spectrum;
    }
    return found;
}
