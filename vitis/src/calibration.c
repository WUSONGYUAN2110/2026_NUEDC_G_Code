#include <math.h>
#include <string.h>
#include "measurement.h"

#define MEAS_CAL_VERSION 0x00020001U

u32 measurement_crc32(const void *data, size_t length)
{
    const u8 *bytes = (const u8 *)data;
    u32 crc = 0xFFFFFFFFU;
    size_t i;
    unsigned bit;

    for (i = 0U; i < length; ++i) {
        crc ^= bytes[i];
        for (bit = 0U; bit < 8U; ++bit)
            crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
    }
    return ~crc;
}

static u32 calibration_crc(const measurement_calibration_t *cal)
{
    measurement_calibration_t copy = *cal;
    copy.crc32 = 0U;
    return measurement_crc32(&copy, sizeof(copy));
}

void measurement_calibration_identity(measurement_calibration_t *cal)
{
    unsigned i;

    memset(cal, 0, sizeof(*cal));
    cal->version = MEAS_CAL_VERSION;
    cal->size = (u32)sizeof(*cal);
    cal->flags = MEAS_CAL_FLAG_VALID | MEAS_CAL_FLAG_UNCALIBRATED;
    /*
     * Channel-B identity calibration only.  No channel-A gain/phase table is
     * accepted or copied into this version.  LTC2208 full scale is 2.25 Vpp
     * with PGA=0, so one signed ADC code represents 1.125 / 32768 volts.
     * MEAS_CAL_FLAG_UNCALIBRATED remains set until channel B is calibrated.
     */
    cal->adc_volts_per_code = 1.125 / 32768.0;
    cal->sample_rate_hz = MEAS_SAMPLE_RATE_HZ;
    for (i = 0U; i < MEAS_MAX_COMPONENTS; ++i)
        cal->gain[i] = 1.0;
    cal->crc32 = calibration_crc(cal);
}

void measurement_calibration_channel_b(measurement_calibration_t *cal)
{
    unsigned i;

    measurement_calibration_identity(cal);
    /*
     * AX7020 channel-B calibration, measured with a 50-ohm source over
     * 20 kHz..500 kHz.  Eleven amplitude points were fitted to the existing
     * affine response model around 100 kHz.  The same physical channel
     * response applies to every sorted component slot.
     */
    cal->sample_rate_hz = 1999995.86097129;
    for (i = 0U; i < MEAS_MAX_COMPONENTS; ++i) {
        cal->gain[i] = 0.970707822690173;
        cal->gain_slope_per_hz[i] = 2.5925391619112e-9;
    }
    cal->dc_offset_v = 0.00169616304888889;
    cal->flags &= ~MEAS_CAL_FLAG_UNCALIBRATED;
    cal->crc32 = calibration_crc(cal);
}

void measurement_calibration_reseal(measurement_calibration_t *cal)
{
    if (cal != NULL) {
        cal->flags |= MEAS_CAL_FLAG_VALID;
        cal->crc32 = calibration_crc(cal);
    }
}

int measurement_calibration_validate(const measurement_calibration_t *cal)
{
    unsigned i;

    if (cal == NULL || cal->version != MEAS_CAL_VERSION ||
        cal->size != sizeof(*cal) ||
        (cal->flags & MEAS_CAL_FLAG_VALID) == 0U ||
        !isfinite(cal->adc_volts_per_code) ||
        cal->adc_volts_per_code <= 0.0 ||
        !isfinite(cal->sample_rate_hz) ||
        cal->sample_rate_hz < 1000000.0 ||
        cal->sample_rate_hz > 3000000.0 ||
        !isfinite(cal->dc_offset_v))
        return 0;
    for (i = 0U; i < MEAS_MAX_COMPONENTS; ++i) {
        if (!isfinite(cal->gain[i]) ||
            !isfinite(cal->gain_slope_per_hz[i]) ||
            !isfinite(cal->phase_rad[i]) ||
            !isfinite(cal->phase_delay_s[i]) ||
            cal->gain[i] +
                cal->gain_slope_per_hz[i] *
                (MEAS_MIN_FREQUENCY_HZ - 100000.0) <= 0.0 ||
            cal->gain[i] +
                cal->gain_slope_per_hz[i] *
                (MEAS_MAX_FREQUENCY_HZ - 100000.0) <= 0.0)
            return 0;
    }
    return cal->crc32 == calibration_crc(cal);
}
