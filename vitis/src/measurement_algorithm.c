#include <float.h>
#include <math.h>
#include <string.h>
#include "measurement.h"

#if defined(__arm__) || defined(__ARM_ARCH)
#include "xtime_l.h"
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/*
 * Fast sparse-harmonic analyzer
 * --------------------------------
 * The PL already supplies a 65536-point Blackman-Harris-windowed FFT.  Use
 * that spectrum to determine the harmonic structure, validate each possible
 * fundamental with a short Hann-windowed time-domain projection, and perform
 * one small linear least-squares fit for the winning model.  This keeps the
 * nonlinear search out of the O(N) fit loop.
 */
#define FAST_MAX_SEEDS                (MEAS_MAX_CANDIDATES * 50U)
#define FAST_PROJECTION_SAMPLES       4096U
#define FAST_FIT_SAMPLES              8192U
#define FAST_PP_POINTS                4096U
#define FAST_INITIAL_SNR_DB           6.0
#define FAST_MATCH_TOLERANCE_BINS     1.0
#define FAST_MIN_FUNDAMENTAL_CODES    0.5
#define FAST_MIN_COMPONENT_CODES      0.5
#define FAST_MAX_RESIDUAL_RATIO       0.20
#define FAST_HUBER_TRIGGER            8.0
#define FAST_HUBER_KAPPA              1.8
#define FAST_DEADLINE_US              2000000U
#define FAST_INVALID_CANDIDATE        0xFFFFFFFFU

typedef struct {
    double seed_hz;
    double frequency_hz;
    double score;
    double direct_peak_v;
    u32 count;
    u32 harmonic[MEAS_MAX_COMPONENTS];
    u32 candidate_index[MEAS_MAX_COMPONENTS];
} fast_model_t;

typedef struct {
    fast_model_t model;
    double coefficient[MEAS_MAX_BASIS];
    double residual_rms_v;
    double residual_peak_v;
    double residual_ratio;
    double condition;
    double bic;
    int reliable;
} fast_fit_t;

typedef struct {
    u32 candidate_index;
    double score;
} harmonic_match_t;

static double fast_spectrum_magnitude[MEAS_FFT_BINS];
static double fast_projection_window[FAST_PROJECTION_SAMPLES];
static double fast_seed_hz[FAST_MAX_SEEDS];
static fast_model_t fast_ranked_model[MEAS_MAX_RANKED_MODELS];
static int fast_window_initialized;

static u64 timer_now(void)
{
#if defined(__arm__) || defined(__ARM_ARCH)
    XTime now;
    XTime_GetTime(&now);
    return (u64)now;
#else
    return 0U;
#endif
}

static u32 elapsed_us(u64 start, u64 end)
{
#if defined(__arm__) || defined(__ARM_ARCH)
    u64 ticks = end - start;
    u64 microseconds =
        (ticks * 1000000ULL) / (u64)COUNTS_PER_SECOND;
    return microseconds > 0xFFFFFFFFULL ?
        0xFFFFFFFFU : (u32)microseconds;
#else
    (void)start;
    (void)end;
    return 0U;
#endif
}

static u32 capture_duration_us(u32 sample_count, double sample_rate_hz)
{
    double duration;

    if (!(sample_rate_hz > 0.0))
        return 0U;
    duration = 1000000.0 * (double)sample_count / sample_rate_hz;
    return duration >= 4294967295.0 ? 0xFFFFFFFFU :
        (u32)floor(duration + 0.5);
}

static void finish_total_time(
    measurement_quality_t *quality,
    u64 total_start)
{
    u64 total = (u64)quality->capture_time_us +
        (u64)elapsed_us(total_start, timer_now());

    quality->total_time_us =
        total > 0xFFFFFFFFULL ? 0xFFFFFFFFU : (u32)total;
    quality->deadline_miss =
        quality->total_time_us > FAST_DEADLINE_US;
    if (quality->deadline_miss)
        quality->flags |= MEAS_QUALITY_DEADLINE_MISS;
}

static s32 sign_extend24(u32 value)
{
    value &= 0x00FFFFFFU;
    return (value & 0x00800000U) ?
        (s32)(value | 0xFF000000U) : (s32)value;
}

static double raw_spectrum_magnitude(u64 value)
{
    double re = (double)sign_extend24((u32)(value & 0xFFFFFFFFULL));
    double im = (double)sign_extend24((u32)(value >> 32));
    return hypot(re, im);
}

static void sort_candidates(
    measurement_candidate_t *candidate,
    u32 count)
{
    u32 i;
    u32 j;

    for (i = 0U; i < count; ++i) {
        for (j = i + 1U; j < count; ++j) {
            if (candidate[j].magnitude > candidate[i].magnitude) {
                measurement_candidate_t temporary = candidate[i];
                candidate[i] = candidate[j];
                candidate[j] = temporary;
            }
        }
    }
}

static u32 detect_candidates(
    const u64 *spectrum,
    u32 fft_bins,
    double sample_rate_hz,
    measurement_candidate_t candidate[MEAS_MAX_CANDIDATES],
    double *best_snr_db)
{
    const double bin_hz =
        sample_rate_hz / (double)MEAS_SHORT_SAMPLES;
    u32 first = (u32)ceil(MEAS_MIN_FREQUENCY_HZ / bin_hz);
    u32 last = (u32)floor(MEAS_MAX_FREQUENCY_HZ / bin_hz);
    u32 count = 0U;
    u32 k;

    *best_snr_db = -DBL_MAX;
    if (last + 1U >= fft_bins)
        last = fft_bins - 2U;
    for (k = first - 1U; k <= last + 1U; ++k)
        fast_spectrum_magnitude[k] =
            raw_spectrum_magnitude(spectrum[k]);

    for (k = first; k <= last; ++k) {
        double magnitude = fast_spectrum_magnitude[k];
        double left = fast_spectrum_magnitude[k - 1U];
        double right = fast_spectrum_magnitude[k + 1U];
        double noise = 0.0;
        double snr_db;
        double delta;
        double log_left;
        double log_center;
        double log_right;
        u32 noise_first = k > first + 24U ? k - 24U : first;
        u32 noise_last = k + 24U < last ? k + 24U : last;
        u32 noise_count = 0U;
        u32 n;
        u32 i;
        int merged = 0;

        if (magnitude <= left || magnitude < right)
            continue;
        for (n = noise_first; n <= noise_last; ++n) {
            if (n + 5U < k || n > k + 5U) {
                noise += fast_spectrum_magnitude[n];
                ++noise_count;
            }
        }
        if (noise_count == 0U)
            continue;
        noise /= (double)noise_count;
        if (noise < 1.0)
            noise = 1.0;
        snr_db = 20.0 * log10(magnitude / noise);
        if (snr_db < FAST_INITIAL_SNR_DB)
            continue;

        /*
         * Log-parabolic interpolation is well matched to the smooth main
         * lobe produced by the PL Blackman-Harris window.  Even when the
         * interpolation is inconclusive, the bin-center error is only
         * half of 30.5 Hz at the configured sample rate.
         */
        log_left = log(fmax(left, 1.0));
        log_center = log(fmax(magnitude, 1.0));
        log_right = log(fmax(right, 1.0));
        {
            double denominator =
                log_left - 2.0 * log_center + log_right;
            delta = fabs(denominator) > 1.0e-20 ?
                0.5 * (log_left - log_right) / denominator : 0.0;
        }
        if (delta < -0.5 || delta > 0.5)
            delta = 0.0;

        for (i = 0U; i < count; ++i) {
            u32 distance = candidate[i].bin > k ?
                candidate[i].bin - k : k - candidate[i].bin;
            if (distance <= 8U) {
                merged = 1;
                if (magnitude > candidate[i].magnitude) {
                    candidate[i].bin = k;
                    candidate[i].frequency_hz =
                        ((double)k + delta) * bin_hz;
                    candidate[i].magnitude = magnitude;
                    candidate[i].noise = noise;
                }
                break;
            }
        }
        if (!merged) {
            if (count < MEAS_MAX_CANDIDATES) {
                candidate[count].bin = k;
                candidate[count].frequency_hz =
                    ((double)k + delta) * bin_hz;
                candidate[count].magnitude = magnitude;
                candidate[count].noise = noise;
                ++count;
            } else {
                sort_candidates(candidate, count);
                if (magnitude > candidate[count - 1U].magnitude) {
                    candidate[count - 1U].bin = k;
                    candidate[count - 1U].frequency_hz =
                        ((double)k + delta) * bin_hz;
                    candidate[count - 1U].magnitude = magnitude;
                    candidate[count - 1U].noise = noise;
                }
            }
        }
        if (snr_db > *best_snr_db)
            *best_snr_db = snr_db;
    }
    sort_candidates(candidate, count);
    return count;
}

static void initialize_projection_window(void)
{
    u32 n;

    if (fast_window_initialized)
        return;
    for (n = 0U; n < FAST_PROJECTION_SAMPLES; ++n) {
        fast_projection_window[n] =
            0.5 - 0.5 * cos(
                2.0 * M_PI * (double)n /
                (double)(FAST_PROJECTION_SAMPLES - 1U));
    }
    fast_window_initialized = 1;
}

static double direct_peak(
    const s32 *samples_q8,
    u32 sample_count,
    double volts_per_code,
    double sample_rate_hz,
    double frequency_hz)
{
    u32 use_count = sample_count < FAST_PROJECTION_SAMPLES ?
        sample_count : FAST_PROJECTION_SAMPLES;
    double mean = 0.0;
    double weighted_sum = 0.0;
    double real_sum = 0.0;
    double imaginary_sum = 0.0;
    double omega = 2.0 * M_PI * frequency_hz / sample_rate_hz;
    double step_cosine = cos(omega);
    double step_sine = sin(omega);
    double cosine = 1.0;
    double sine = 0.0;
    u32 n;

    initialize_projection_window();
    for (n = 0U; n < use_count; ++n)
        mean += (double)samples_q8[n] / 256.0;
    mean /= (double)use_count;
    for (n = 0U; n < use_count; ++n) {
        double weight = fast_projection_window[n];
        double sample = (double)samples_q8[n] / 256.0 - mean;
        double next_cosine;

        real_sum += weight * sample * cosine;
        imaginary_sum -= weight * sample * sine;
        weighted_sum += weight;
        next_cosine =
            cosine * step_cosine - sine * step_sine;
        sine = sine * step_cosine + cosine * step_sine;
        cosine = next_cosine;
        if ((n & 1023U) == 1023U) {
            double phase = omega * (double)(n + 1U);
            cosine = cos(phase);
            sine = sin(phase);
        }
    }
    return 2.0 * hypot(real_sum, imaginary_sum) /
        fmax(weighted_sum, 1.0) * volts_per_code;
}

static u32 build_seed_list(
    const measurement_candidate_t *candidate,
    u32 candidate_count,
    double sample_rate_hz)
{
    const double bin_hz =
        sample_rate_hz / (double)MEAS_SHORT_SAMPLES;
    const double boundary_tolerance = 0.5 * bin_hz;
    u32 seed_count = 0U;
    u32 c;
    u32 divisor;

    for (c = 0U; c < candidate_count; ++c) {
        for (divisor = 1U; divisor <= 50U; ++divisor) {
            double seed =
                candidate[c].frequency_hz / (double)divisor;
            u32 existing;
            int duplicate = 0;

            if (fabs(seed - MEAS_MIN_FREQUENCY_HZ) <=
                    boundary_tolerance)
                seed = MEAS_MIN_FREQUENCY_HZ;
            if (fabs(seed - MEAS_MAX_FREQUENCY_HZ) <=
                    boundary_tolerance)
                seed = MEAS_MAX_FREQUENCY_HZ;
            if (seed < MEAS_MIN_FREQUENCY_HZ ||
                seed > MEAS_MAX_FREQUENCY_HZ)
                continue;
            for (existing = 0U; existing < seed_count; ++existing) {
                if (fabs(fast_seed_hz[existing] - seed) <= 0.05) {
                    duplicate = 1;
                    break;
                }
            }
            if (!duplicate && seed_count < FAST_MAX_SEEDS)
                fast_seed_hz[seed_count++] = seed;
        }
    }
    return seed_count;
}

static int model_is_same(
    const fast_model_t *left,
    const fast_model_t *right,
    double frequency_tolerance)
{
    u32 c;

    if (left->count != right->count ||
        fabs(left->seed_hz - right->seed_hz) > frequency_tolerance)
        return 0;
    for (c = 0U; c < left->count; ++c) {
        if (left->harmonic[c] != right->harmonic[c])
            return 0;
    }
    return 1;
}

static int construct_model(
    double seed_hz,
    const measurement_candidate_t *candidate,
    u32 candidate_count,
    const s32 *samples_q8,
    u32 sample_count,
    const measurement_calibration_t *cal,
    fast_model_t *model)
{
    harmonic_match_t best_for_harmonic[51];
    harmonic_match_t selected[MEAS_MAX_COMPONENTS - 1U];
    const double bin_hz =
        cal->sample_rate_hz / (double)MEAS_SHORT_SAMPLES;
    const double tolerance =
        FAST_MATCH_TOLERANCE_BINS * bin_hz;
    double direct;
    double score = 0.0;
    u32 selected_count = 0U;
    u32 fundamental_candidate = FAST_INVALID_CANDIDATE;
    u32 h;
    u32 c;

    memset(best_for_harmonic, 0, sizeof(best_for_harmonic));
    memset(model, 0, sizeof(*model));
    model->seed_hz = seed_hz;
    model->frequency_hz = seed_hz;
    model->count = 1U;
    model->harmonic[0] = 1U;
    model->candidate_index[0] = FAST_INVALID_CANDIDATE;

    for (c = 0U; c < candidate_count; ++c) {
        double ratio = candidate[c].frequency_hz / seed_hz;
        u32 harmonic = (u32)floor(ratio + 0.5);
        double inferred_fundamental;
        double line_score;

        if (harmonic < 1U || harmonic > 50U)
            continue;
        inferred_fundamental =
            candidate[c].frequency_hz / (double)harmonic;
        if (fabs(inferred_fundamental - seed_hz) > tolerance)
            continue;
        line_score = log1p(
            candidate[c].magnitude /
            fmax(candidate[c].noise, 1.0));
        if (harmonic == 1U) {
            if (fundamental_candidate == FAST_INVALID_CANDIDATE ||
                line_score > score) {
                fundamental_candidate = c;
                score = line_score;
            }
        } else if (
            best_for_harmonic[harmonic].candidate_index == 0U ||
            line_score > best_for_harmonic[harmonic].score) {
            /*
             * Store index+1 because zero is a valid candidate index and the
             * zero-initialized table uses zero as "not present".
             */
            best_for_harmonic[harmonic].candidate_index = c + 1U;
            best_for_harmonic[harmonic].score = line_score;
        }
    }
    model->candidate_index[0] = fundamental_candidate;

    for (h = 2U; h <= 50U; ++h) {
        harmonic_match_t match = best_for_harmonic[h];
        u32 position;

        if (match.candidate_index == 0U)
            continue;
        for (position = 0U; position < selected_count; ++position) {
            if (match.score > selected[position].score)
                break;
        }
        if (position >= MEAS_MAX_COMPONENTS - 1U)
            continue;
        if (selected_count < MEAS_MAX_COMPONENTS - 1U)
            ++selected_count;
        for (c = selected_count - 1U; c > position; --c)
            selected[c] = selected[c - 1U];
        selected[position] = match;
    }

    /*
     * Put selected components in ascending harmonic order for a stable API
     * and deterministic HMI ordering.
     */
    for (h = 2U; h <= 50U; ++h) {
        for (c = 0U; c < selected_count; ++c) {
            u32 index = selected[c].candidate_index - 1U;
            u32 harmonic = (u32)floor(
                candidate[index].frequency_hz / seed_hz + 0.5);
            if (harmonic == h) {
                u32 position = model->count;
                model->harmonic[position] = harmonic;
                model->candidate_index[position] = index;
                model->score += selected[c].score;
                ++model->count;
                break;
            }
        }
    }
    if (fundamental_candidate != FAST_INVALID_CANDIDATE) {
        model->score += log1p(
            candidate[fundamental_candidate].magnitude /
            fmax(candidate[fundamental_candidate].noise, 1.0));
    }

    direct = direct_peak(
        samples_q8, sample_count,
        cal->adc_volts_per_code,
        cal->sample_rate_hz, seed_hz);
    model->direct_peak_v = direct;
    if (direct <
        FAST_MIN_FUNDAMENTAL_CODES * cal->adc_volts_per_code)
        return 0;

    /*
     * Component count is the primary discriminator.  It prevents a strong
     * harmonic from being relabeled as a new fundamental.  Direct
     * time-domain support then eliminates missing-fundamental subharmonics.
     */
    model->score += 1000.0 * (double)model->count +
        log1p(direct / cal->adc_volts_per_code);
    return 1;
}

static void insert_ranked_model(
    const fast_model_t *model,
    u32 *ranked_count,
    double duplicate_tolerance)
{
    u32 position;
    u32 i;

    for (position = 0U; position < *ranked_count; ++position) {
        if (model_is_same(
                model, &fast_ranked_model[position],
                duplicate_tolerance))
            return;
        if (model->score > fast_ranked_model[position].score)
            break;
    }
    if (position >= MEAS_MAX_RANKED_MODELS)
        return;
    if (*ranked_count < MEAS_MAX_RANKED_MODELS)
        ++*ranked_count;
    for (i = *ranked_count - 1U; i > position; --i)
        fast_ranked_model[i] = fast_ranked_model[i - 1U];
    fast_ranked_model[position] = *model;
}

static double refine_frequency_from_spectrum(
    fast_model_t *model,
    const measurement_candidate_t *candidate,
    double sample_rate_hz)
{
    const double boundary_tolerance =
        0.5 * sample_rate_hz / (double)MEAS_SHORT_SAMPLES;
    double numerator = 0.0;
    double denominator = 0.0;
    u32 c;

    for (c = 0U; c < model->count; ++c) {
        u32 index = model->candidate_index[c];
        double harmonic = (double)model->harmonic[c];
        double weight;

        if (index == FAST_INVALID_CANDIDATE)
            continue;
        weight = log1p(
            candidate[index].magnitude /
            fmax(candidate[index].noise, 1.0));
        numerator +=
            weight * harmonic * candidate[index].frequency_hz;
        denominator += weight * harmonic * harmonic;
    }
    if (denominator > DBL_EPSILON)
        model->frequency_hz = numerator / denominator;
    if (fabs(model->frequency_hz - MEAS_MIN_FREQUENCY_HZ) <=
            boundary_tolerance)
        model->frequency_hz = MEAS_MIN_FREQUENCY_HZ;
    if (fabs(model->frequency_hz - MEAS_MAX_FREQUENCY_HZ) <=
            boundary_tolerance)
        model->frequency_hz = MEAS_MAX_FREQUENCY_HZ;
    if (model->frequency_hz < MEAS_MIN_FREQUENCY_HZ)
        model->frequency_hz = MEAS_MIN_FREQUENCY_HZ;
    if (model->frequency_hz > MEAS_MAX_FREQUENCY_HZ)
        model->frequency_hz = MEAS_MAX_FREQUENCY_HZ;
    return model->frequency_hz;
}

static void segment_phasor(
    const s32 *samples_q8,
    u32 start,
    u32 count,
    double sample_rate_hz,
    double frequency_hz,
    double *real_part,
    double *imaginary_part)
{
    double mean = 0.0;
    double omega =
        2.0 * M_PI * frequency_hz / sample_rate_hz;
    double step_cosine = cos(omega);
    double step_sine = sin(omega);
    double cosine = cos(omega * (double)start);
    double sine = sin(omega * (double)start);
    u32 n;

    *real_part = 0.0;
    *imaginary_part = 0.0;
    for (n = 0U; n < count; ++n)
        mean += (double)samples_q8[start + n] / 256.0;
    mean /= (double)count;
    for (n = 0U; n < count; ++n) {
        double sample =
            (double)samples_q8[start + n] / 256.0 - mean;
        double weight = fast_projection_window[n];
        double next_cosine;

        *real_part += weight * sample * cosine;
        *imaginary_part -= weight * sample * sine;
        next_cosine =
            cosine * step_cosine - sine * step_sine;
        sine = sine * step_cosine + cosine * step_sine;
        cosine = next_cosine;
        if ((n & 1023U) == 1023U) {
            double phase =
                omega * (double)(start + n + 1U);
            cosine = cos(phase);
            sine = sin(phase);
        }
    }
}

/*
 * The windowed FFT confines every selected component to roughly half a bin.
 * Measure the phase advance between two 4096-sample records to remove that
 * remaining fractional-bin error.  Dividing each component's phase advance
 * by its harmonic number produces an independent f0 correction; amplitude
 * squared and h^2 provide the inverse-variance weighting.
 */
static double refine_frequency_from_phase(
    const s32 *samples_q8,
    u32 sample_count,
    const measurement_calibration_t *cal,
    fast_model_t *model)
{
    const u32 segment_count = FAST_PROJECTION_SAMPLES;
    const u32 second_start = FAST_PROJECTION_SAMPLES;
    const double separation_s =
        (double)FAST_PROJECTION_SAMPLES / cal->sample_rate_hz;
    const double maximum_correction =
        0.5 * cal->sample_rate_hz /
        (double)MEAS_SHORT_SAMPLES;
    double weighted_correction = 0.0;
    double total_weight = 0.0;
    u32 c;

    if (sample_count < second_start + segment_count)
        return model->frequency_hz;
    initialize_projection_window();
    for (c = 0U; c < model->count; ++c) {
        double harmonic = (double)model->harmonic[c];
        double component_frequency =
            model->frequency_hz * harmonic;
        double first_real;
        double first_imaginary;
        double second_real;
        double second_imaginary;
        double cross_real;
        double cross_imaginary;
        double phase_advance;
        double correction;
        double weight;

        segment_phasor(
            samples_q8, 0U, segment_count,
            cal->sample_rate_hz, component_frequency,
            &first_real, &first_imaginary);
        segment_phasor(
            samples_q8, second_start, segment_count,
            cal->sample_rate_hz, component_frequency,
            &second_real, &second_imaginary);
        cross_real =
            second_real * first_real +
            second_imaginary * first_imaginary;
        cross_imaginary =
            second_imaginary * first_real -
            second_real * first_imaginary;
        phase_advance = atan2(cross_imaginary, cross_real);
        correction =
            phase_advance /
            (2.0 * M_PI * harmonic * separation_s);
        weight =
            hypot(first_real, first_imaginary) *
            hypot(second_real, second_imaginary) *
            harmonic * harmonic;
        weighted_correction += weight * correction;
        total_weight += weight;
    }
    if (total_weight > DBL_EPSILON) {
        double correction =
            weighted_correction / total_weight;
        if (correction < -maximum_correction)
            correction = -maximum_correction;
        if (correction > maximum_correction)
            correction = maximum_correction;
        model->frequency_hz += correction;
    }
    if (model->frequency_hz < MEAS_MIN_FREQUENCY_HZ)
        model->frequency_hz = MEAS_MIN_FREQUENCY_HZ;
    if (model->frequency_hz > MEAS_MAX_FREQUENCY_HZ)
        model->frequency_hz = MEAS_MAX_FREQUENCY_HZ;
    return model->frequency_hz;
}

static int cholesky_solve(
    double matrix[MEAS_MAX_BASIS][MEAS_MAX_BASIS],
    double rhs[MEAS_MAX_BASIS],
    u32 order,
    double solution[MEAS_MAX_BASIS],
    double *condition)
{
    double lower[MEAS_MAX_BASIS][MEAS_MAX_BASIS];
    double intermediate[MEAS_MAX_BASIS];
    double minimum_diagonal = DBL_MAX;
    double maximum_diagonal = 0.0;
    u32 i;
    u32 j;
    u32 k;

    memset(lower, 0, sizeof(lower));
    for (i = 0U; i < order; ++i) {
        for (j = 0U; j <= i; ++j) {
            double sum = matrix[i][j];
            for (k = 0U; k < j; ++k)
                sum -= lower[i][k] * lower[j][k];
            if (i == j) {
                if (!(sum > DBL_EPSILON * matrix[0][0]))
                    return 0;
                lower[i][j] = sqrt(sum);
                if (lower[i][j] < minimum_diagonal)
                    minimum_diagonal = lower[i][j];
                if (lower[i][j] > maximum_diagonal)
                    maximum_diagonal = lower[i][j];
            } else {
                lower[i][j] = sum / lower[j][j];
            }
        }
    }
    *condition =
        (maximum_diagonal / minimum_diagonal) *
        (maximum_diagonal / minimum_diagonal);
    if (*condition > 1.0e12)
        return 0;

    for (i = 0U; i < order; ++i) {
        double sum = rhs[i];
        for (j = 0U; j < i; ++j)
            sum -= lower[i][j] * intermediate[j];
        intermediate[i] = sum / lower[i][i];
    }
    for (i = order; i-- > 0U;) {
        double sum = intermediate[i];
        for (j = i + 1U; j < order; ++j)
            sum -= lower[j][i] * solution[j];
        solution[i] = sum / lower[i][i];
    }
    return 1;
}

static void oscillator_initialize(
    const fast_model_t *model,
    double sample_rate_hz,
    double cosine[MEAS_MAX_COMPONENTS],
    double sine[MEAS_MAX_COMPONENTS],
    double step_cosine[MEAS_MAX_COMPONENTS],
    double step_sine[MEAS_MAX_COMPONENTS])
{
    u32 c;

    for (c = 0U; c < model->count; ++c) {
        double omega =
            2.0 * M_PI * model->frequency_hz *
            (double)model->harmonic[c] / sample_rate_hz;
        cosine[c] = 1.0;
        sine[c] = 0.0;
        step_cosine[c] = cos(omega);
        step_sine[c] = sin(omega);
    }
}

static void oscillator_advance(
    const fast_model_t *model,
    double sample_rate_hz,
    u32 n,
    double cosine[MEAS_MAX_COMPONENTS],
    double sine[MEAS_MAX_COMPONENTS],
    const double step_cosine[MEAS_MAX_COMPONENTS],
    const double step_sine[MEAS_MAX_COMPONENTS])
{
    u32 c;

    for (c = 0U; c < model->count; ++c) {
        double next_cosine =
            cosine[c] * step_cosine[c] -
            sine[c] * step_sine[c];
        sine[c] =
            sine[c] * step_cosine[c] +
            cosine[c] * step_sine[c];
        cosine[c] = next_cosine;
        if ((n & 1023U) == 1023U) {
            double phase =
                2.0 * M_PI * model->frequency_hz *
                (double)model->harmonic[c] * (double)(n + 1U) /
                sample_rate_hz;
            cosine[c] = cos(phase);
            sine[c] = sin(phase);
        }
    }
}

static void fill_basis(
    const fast_model_t *model,
    u32 sample_index,
    u32 sample_count,
    const double cosine[MEAS_MAX_COMPONENTS],
    const double sine[MEAS_MAX_COMPONENTS],
    double basis[MEAS_MAX_BASIS])
{
    u32 c;

    basis[0] = 1.0;
    basis[1] = sample_count > 1U ?
        (double)sample_index / (double)(sample_count - 1U) - 0.5 :
        0.0;
    for (c = 0U; c < model->count; ++c) {
        basis[2U + 2U * c] = cosine[c];
        basis[3U + 2U * c] = sine[c];
    }
}

static int solve_fit(
    const s32 *samples_q8,
    u32 sample_count,
    const measurement_calibration_t *cal,
    const fast_model_t *model,
    const double *initial,
    double huber_scale,
    fast_fit_t *fit)
{
    double matrix[MEAS_MAX_BASIS][MEAS_MAX_BASIS];
    double rhs[MEAS_MAX_BASIS];
    double basis[MEAS_MAX_BASIS];
    double cosine[MEAS_MAX_COMPONENTS];
    double sine[MEAS_MAX_COMPONENTS];
    double step_cosine[MEAS_MAX_COMPONENTS];
    double step_sine[MEAS_MAX_COMPONENTS];
    double residual_energy = 0.0;
    double residual_peak = 0.0;
    u32 order = 2U + 2U * model->count;
    u32 n;
    u32 i;
    u32 j;

    memset(fit, 0, sizeof(*fit));
    fit->model = *model;
    memset(matrix, 0, sizeof(matrix));
    memset(rhs, 0, sizeof(rhs));
    oscillator_initialize(
        model, cal->sample_rate_hz,
        cosine, sine, step_cosine, step_sine);
    for (n = 0U; n < sample_count; ++n) {
        double y =
            ((double)samples_q8[n] / 256.0) *
            cal->adc_volts_per_code;
        double weight = 1.0;

        fill_basis(
            model, n, sample_count, cosine, sine, basis);
        if (initial != NULL) {
            double prediction = 0.0;
            double residual;
            double limit =
                FAST_HUBER_KAPPA * fmax(huber_scale, 1.0e-12);
            for (i = 0U; i < order; ++i)
                prediction += basis[i] * initial[i];
            residual = fabs(y - prediction);
            if (residual > limit)
                weight = limit / residual;
        }
        for (i = 0U; i < order; ++i) {
            rhs[i] += weight * basis[i] * y;
            for (j = 0U; j <= i; ++j)
                matrix[i][j] += weight * basis[i] * basis[j];
        }
        oscillator_advance(
            model, cal->sample_rate_hz, n,
            cosine, sine, step_cosine, step_sine);
    }
    for (i = 0U; i < order; ++i) {
        for (j = i + 1U; j < order; ++j)
            matrix[i][j] = matrix[j][i];
    }
    memset(fit->coefficient, 0, sizeof(fit->coefficient));
    if (!cholesky_solve(
            matrix, rhs, order,
            fit->coefficient, &fit->condition))
        return 0;

    oscillator_initialize(
        model, cal->sample_rate_hz,
        cosine, sine, step_cosine, step_sine);
    for (n = 0U; n < sample_count; ++n) {
        double y =
            ((double)samples_q8[n] / 256.0) *
            cal->adc_volts_per_code;
        double prediction = 0.0;
        double residual;

        fill_basis(
            model, n, sample_count, cosine, sine, basis);
        for (i = 0U; i < order; ++i)
            prediction += basis[i] * fit->coefficient[i];
        residual = y - prediction;
        residual_energy += residual * residual;
        if (fabs(residual) > residual_peak)
            residual_peak = fabs(residual);
        oscillator_advance(
            model, cal->sample_rate_hz, n,
            cosine, sine, step_cosine, step_sine);
    }
    fit->residual_rms_v =
        sqrt(residual_energy / (double)sample_count);
    fit->residual_peak_v = residual_peak;
    return 1;
}

static void finish_fit_quality(
    fast_fit_t *fit,
    u32 sample_count,
    const measurement_calibration_t *cal)
{
    double signal_energy = 0.0;
    double minimum_peak =
        FAST_MIN_COMPONENT_CODES * cal->adc_volts_per_code;
    u32 c;

    fit->reliable =
        fit->model.count >= 1U &&
        fit->model.count <= MEAS_MAX_COMPONENTS &&
        fit->model.harmonic[0] == 1U &&
        fit->condition <= 1.0e9;
    for (c = 0U; c < fit->model.count; ++c) {
        double peak = hypot(
            fit->coefficient[2U + 2U * c],
            fit->coefficient[3U + 2U * c]);
        signal_energy += 0.5 * peak * peak;
        if (peak < minimum_peak)
            fit->reliable = 0;
    }
    fit->residual_ratio =
        fit->residual_rms_v /
        fmax(sqrt(signal_energy), minimum_peak);
    if (fit->residual_ratio > FAST_MAX_RESIDUAL_RATIO)
        fit->reliable = 0;
    fit->bic =
        (double)sample_count *
        log(fmax(
            fit->residual_rms_v * fit->residual_rms_v,
            DBL_MIN)) +
        (double)(2U + 2U * fit->model.count) *
        log((double)sample_count);
}

static int fit_model(
    const s32 *samples_q8,
    u32 sample_count,
    const measurement_calibration_t *cal,
    fast_model_t *model,
    fast_fit_t *fit,
    int *huber_used)
{
    fast_fit_t first;
    fast_fit_t robust;
    u32 use_count =
        sample_count < FAST_FIT_SAMPLES ?
        sample_count : FAST_FIT_SAMPLES;

    *huber_used = 0;
    if (!solve_fit(
            samples_q8, use_count, cal, model,
            NULL, 1.0, &first))
        return 0;
    if (first.residual_rms_v > 0.0 &&
        first.residual_peak_v >
            FAST_HUBER_TRIGGER * first.residual_rms_v &&
        solve_fit(
            samples_q8, use_count, cal, model,
            first.coefficient,
            first.residual_rms_v, &robust)) {
        *fit = robust;
        *huber_used = 1;
    } else {
        *fit = first;
    }
    finish_fit_quality(fit, use_count, cal);
    return 1;
}

/*
 * A stop-band tone can leave a narrow FFT spur whose frequency happens to
 * align with an in-band harmonic.  Spectrum ranking intentionally favors
 * models with more supported components, but the subsequent time-domain fit
 * may show that such a component has effectively zero amplitude.  Remove
 * only those unsupported non-fundamental terms and let the caller refit the
 * reduced model.  The fundamental is never pruned here.
 */
static int prune_weak_fitted_components(
    const fast_fit_t *fit,
    const measurement_calibration_t *cal,
    fast_model_t *pruned)
{
    const double minimum_peak =
        FAST_MIN_COMPONENT_CODES * cal->adc_volts_per_code;
    u32 source;
    u32 destination = 0U;

    *pruned = fit->model;
    for (source = 0U; source < fit->model.count; ++source) {
        double peak = hypot(
            fit->coefficient[2U + 2U * source],
            fit->coefficient[3U + 2U * source]);

        if (source != 0U && peak < minimum_peak)
            continue;
        pruned->harmonic[destination] =
            fit->model.harmonic[source];
        pruned->candidate_index[destination] =
            fit->model.candidate_index[source];
        ++destination;
    }
    while (destination < MEAS_MAX_COMPONENTS) {
        pruned->harmonic[destination] = 0U;
        pruned->candidate_index[destination] =
            FAST_INVALID_CANDIDATE;
        ++destination;
    }
    pruned->count = 0U;
    for (source = 0U; source < fit->model.count; ++source) {
        double peak = hypot(
            fit->coefficient[2U + 2U * source],
            fit->coefficient[3U + 2U * source]);

        if (source == 0U || peak >= minimum_peak)
            ++pruned->count;
    }
    return pruned->count < fit->model.count;
}

static double reconstructed_value(
    double dc,
    const measurement_component_t *component,
    u32 count,
    double phase)
{
    double value = dc;
    u32 c;

    for (c = 0U; c < count; ++c) {
        value += component[c].amplitude_peak_v *
            cos((double)component[c].harmonic * phase +
                component[c].phase_rad);
    }
    return value;
}

static double refine_extremum(
    double dc,
    const measurement_component_t *component,
    u32 count,
    u32 index)
{
    const double step =
        2.0 * M_PI / (double)FAST_PP_POINTS;
    double center_phase = step * (double)index;
    double left = reconstructed_value(
        dc, component, count, center_phase - step);
    double center = reconstructed_value(
        dc, component, count, center_phase);
    double right = reconstructed_value(
        dc, component, count, center_phase + step);
    double denominator = left - 2.0 * center + right;
    double offset = fabs(denominator) > DBL_EPSILON ?
        0.5 * (left - right) / denominator : 0.0;

    if (offset < -0.5)
        offset = -0.5;
    if (offset > 0.5)
        offset = 0.5;
    return reconstructed_value(
        dc, component, count,
        center_phase + offset * step);
}

static double reconstructed_pp(
    double dc,
    const measurement_component_t *component,
    u32 count)
{
    double cosine[MEAS_MAX_COMPONENTS];
    double sine[MEAS_MAX_COMPONENTS];
    double step_cosine[MEAS_MAX_COMPONENTS];
    double step_sine[MEAS_MAX_COMPONENTS];
    double minimum = DBL_MAX;
    double maximum = -DBL_MAX;
    u32 minimum_index = 0U;
    u32 maximum_index = 0U;
    u32 index;
    u32 c;

    for (c = 0U; c < count; ++c) {
        double phase = component[c].phase_rad;
        double step =
            2.0 * M_PI * (double)component[c].harmonic /
            (double)FAST_PP_POINTS;
        cosine[c] = cos(phase);
        sine[c] = sin(phase);
        step_cosine[c] = cos(step);
        step_sine[c] = sin(step);
    }
    for (index = 0U; index < FAST_PP_POINTS; ++index) {
        double value = dc;

        for (c = 0U; c < count; ++c) {
            double next_cosine;
            value +=
                component[c].amplitude_peak_v * cosine[c];
            next_cosine =
                cosine[c] * step_cosine[c] -
                sine[c] * step_sine[c];
            sine[c] =
                sine[c] * step_cosine[c] +
                cosine[c] * step_sine[c];
            cosine[c] = next_cosine;
            if ((index & 511U) == 511U) {
                double phase =
                    component[c].phase_rad +
                    2.0 * M_PI *
                    (double)component[c].harmonic *
                    (double)(index + 1U) /
                    (double)FAST_PP_POINTS;
                cosine[c] = cos(phase);
                sine[c] = sin(phase);
            }
        }
        if (value < minimum) {
            minimum = value;
            minimum_index = index;
        }
        if (value > maximum) {
            maximum = value;
            maximum_index = index;
        }
    }
    minimum = refine_extremum(
        dc, component, count, minimum_index);
    maximum = refine_extremum(
        dc, component, count, maximum_index);
    return maximum - minimum;
}

static int metadata_valid(
    const measurement_time_trailer_t *time_meta,
    const measurement_spectrum_trailer_t *spectrum_meta,
    measurement_quality_t *quality)
{
    int valid = 1;

    if (time_meta != NULL) {
        quality->frame_id = time_meta->frame_id;
        quality->sample_count = time_meta->sample_count;
        quality->clip_count = time_meta->clip_count;
        quality->saturation_run_max =
            time_meta->saturation_run_max;
        quality->jump_count = time_meta->jump_count;
        quality->time_status = time_meta->status;
        if (time_meta->clip_count != 0U) {
            quality->flags |=
                MEAS_QUALITY_CLIPPED |
                MEAS_QUALITY_DATA_INVALID;
            valid = 0;
        }
        if (time_meta->saturation_run_max > 1U ||
            time_meta->jump_count != 0U ||
            (time_meta->status &
                (MEAS_STATUS_INPUT_STALL |
                 MEAS_STATUS_DMA_ERROR)) != 0U) {
            quality->flags |= MEAS_QUALITY_DATA_INVALID;
            valid = 0;
        }
    }
    if (spectrum_meta != NULL) {
        quality->fft_events =
            (u32)((spectrum_meta->fft_status >> 10) & 0x3FU);
        quality->spectrum_frame_id =
            (u32)spectrum_meta->frame_id;
        if ((quality->fft_events &
                MEAS_FFT_EVENT_FATAL_MASK) != 0U) {
            quality->flags |=
                MEAS_QUALITY_FFT_ERROR |
                MEAS_QUALITY_DATA_INVALID;
            valid = 0;
        }
    }
    if (time_meta != NULL && spectrum_meta != NULL &&
        time_meta->frame_id != (u32)spectrum_meta->frame_id) {
        quality->flags |= MEAS_QUALITY_DATA_INVALID;
        valid = 0;
    }
    return valid;
}

static void populate_result(
    const fast_fit_t *fit,
    const measurement_time_trailer_t *time_meta,
    const measurement_spectrum_trailer_t *spectrum_meta,
    const measurement_calibration_t *cal,
    double snr_db,
    u32 ranked_count,
    measurement_result_t *result)
{
    double ac_energy = 0.0;
    u32 c;

    result->quality.flags |= MEAS_QUALITY_VALID;
    if ((cal->flags & MEAS_CAL_FLAG_UNCALIBRATED) != 0U)
        result->quality.flags |= MEAS_QUALITY_UNCALIBRATED;
    result->quality.frame_id =
        time_meta != NULL ? time_meta->frame_id : 0U;
    result->quality.sample_count =
        time_meta != NULL ? time_meta->sample_count : 0U;
    result->quality.clip_count =
        time_meta != NULL ? time_meta->clip_count : 0U;
    result->quality.saturation_run_max =
        time_meta != NULL ? time_meta->saturation_run_max : 0U;
    result->quality.jump_count =
        time_meta != NULL ? time_meta->jump_count : 0U;
    result->quality.fft_events =
        spectrum_meta != NULL ?
        (u32)((spectrum_meta->fft_status >> 10) & 0x3FU) : 0U;
    result->quality.snr_db = snr_db;
    result->quality.residual_rms_v = fit->residual_rms_v;
    result->quality.residual_ratio = fit->residual_ratio;
    result->quality.condition_estimate = fit->condition;
    result->quality.bic = fit->bic;
    result->quality.drift_v_per_record = fit->coefficient[1];

    result->component_count = fit->model.count;
    result->fundamental_hz = fit->model.frequency_hz;
    result->dc_v = fit->coefficient[0] + cal->dc_offset_v;
    for (c = 0U; c < fit->model.count; ++c) {
        double cosine = fit->coefficient[2U + 2U * c];
        double sine = fit->coefficient[3U + 2U * c];
        double component_frequency =
            fit->model.frequency_hz *
            (double)fit->model.harmonic[c];
        double calibrated_gain =
            cal->gain[c] +
            cal->gain_slope_per_hz[c] *
            (component_frequency - 100000.0);
        double peak = hypot(cosine, sine) * calibrated_gain;
        measurement_component_t *component =
            &result->component[c];

        component->harmonic = fit->model.harmonic[c];
        component->frequency_hz = component_frequency;
        component->display_frequency_hz =
            500.0 * floor(
                component_frequency / 500.0 + 0.5);
        component->amplitude_peak_v = peak;
        component->amplitude_pp_v = 2.0 * peak;
        component->amplitude_rms_v = peak / sqrt(2.0);
        component->phase_rad =
            atan2(-sine, cosine) +
            cal->phase_rad[c] +
            2.0 * M_PI * component_frequency *
            cal->phase_delay_s[c];
        ac_energy += 0.5 * peak * peak;
    }
    result->ac_rms_v = sqrt(ac_energy);
    result->total_rms_v =
        sqrt(ac_energy + result->dc_v * result->dc_v);
    result->reconstructed_pp_v =
        reconstructed_pp(
            result->dc_v, result->component,
            result->component_count);
}

int measurement_analyze(
    const s32 *samples_q8,
    u32 sample_count,
    const u64 *spectrum,
    u32 fft_bins,
    const measurement_time_trailer_t *time_meta,
    const measurement_spectrum_trailer_t *spectrum_meta,
    const measurement_calibration_t *cal,
    measurement_result_t *result)
{
    measurement_candidate_t candidate[MEAS_MAX_CANDIDATES];
    fast_fit_t selected_fit;
    u32 candidate_count;
    u32 seed_count;
    u32 ranked_count = 0U;
    u32 enumerated_count = 0U;
    u32 seed;
    u32 rank;
    u64 total_start;
    u64 stage_start;
    double snr_db;
    int selected = 0;
    int selected_huber = 0;

    if (result == NULL)
        return 0;
    memset(result, 0, sizeof(*result));
    if (samples_q8 == NULL || spectrum == NULL || cal == NULL ||
        !measurement_calibration_validate(cal) ||
        sample_count != MEAS_SHORT_SAMPLES ||
        fft_bins < MEAS_FFT_BINS) {
        result->quality.reject_stage = MEAS_REJECT_ARGUMENT;
        return 0;
    }

    total_start = timer_now();
    result->quality.capture_time_us =
        capture_duration_us(sample_count, cal->sample_rate_hz);
    if (!metadata_valid(
            time_meta, spectrum_meta, &result->quality)) {
        result->quality.reject_stage = MEAS_REJECT_METADATA;
        finish_total_time(&result->quality, total_start);
        return 0;
    }

    stage_start = timer_now();
    candidate_count = detect_candidates(
        spectrum, fft_bins, cal->sample_rate_hz,
        candidate, &snr_db);
    result->quality.candidate_count = candidate_count;
    result->quality.snr_db = snr_db;
    result->quality.candidate_time_us =
        elapsed_us(stage_start, timer_now());
    if (candidate_count == 0U) {
        result->quality.reject_stage = MEAS_REJECT_CANDIDATES;
        result->quality.flags |= MEAS_QUALITY_AMBIGUOUS;
        finish_total_time(&result->quality, total_start);
        return 0;
    }

    stage_start = timer_now();
    seed_count = build_seed_list(
        candidate, candidate_count, cal->sample_rate_hz);
    result->quality.hypothesis_count = seed_count;
    for (seed = 0U; seed < seed_count; ++seed) {
        fast_model_t model;

        if (construct_model(
                fast_seed_hz[seed],
                candidate, candidate_count,
                samples_q8, sample_count, cal, &model)) {
            ++enumerated_count;
            insert_ranked_model(
                &model, &ranked_count,
                0.25 * cal->sample_rate_hz /
                    (double)MEAS_SHORT_SAMPLES);
        }
    }
    result->quality.enumerated_count = enumerated_count;
    result->quality.prefiltered_count = ranked_count;
    result->quality.ranked_count = ranked_count;
    result->quality.enumeration_time_us =
        elapsed_us(stage_start, timer_now());
    if (ranked_count == 0U) {
        result->quality.reject_stage = MEAS_REJECT_ENUMERATION;
        result->quality.flags |= MEAS_QUALITY_AMBIGUOUS;
        finish_total_time(&result->quality, total_start);
        return 0;
    }

    stage_start = timer_now();
    /*
     * The first model is normally sufficient.  At most three fits are
     * attempted so a spectrum-only spur cannot turn into an UNSTABLE result;
     * the common path still performs exactly one 8192-point fit.
     */
    for (rank = 0U; rank < ranked_count && rank < 3U; ++rank) {
        fast_fit_t trial;
        int huber_used;
        int fitted;

        refine_frequency_from_spectrum(
            &fast_ranked_model[rank], candidate,
            cal->sample_rate_hz);
        refine_frequency_from_phase(
            samples_q8, sample_count, cal,
            &fast_ranked_model[rank]);
        fitted = fit_model(
            samples_q8, sample_count, cal,
            &fast_ranked_model[rank],
            &trial, &huber_used);
        if (fitted && !trial.reliable) {
            fast_model_t pruned;

            if (prune_weak_fitted_components(
                    &trial, cal, &pruned)) {
                fast_fit_t pruned_fit;
                int pruned_huber_used;

                if (fit_model(
                        samples_q8, sample_count, cal,
                        &pruned, &pruned_fit,
                        &pruned_huber_used)) {
                    trial = pruned_fit;
                    huber_used = pruned_huber_used;
                }
            }
        }
        if (fitted && trial.reliable) {
            selected_fit = trial;
            selected = 1;
            selected_huber = huber_used;
            break;
        }
    }
    result->quality.fit_time_us =
        elapsed_us(stage_start, timer_now());
    if (!selected) {
        result->quality.reject_stage = MEAS_REJECT_FIT;
        result->quality.flags |= MEAS_QUALITY_AMBIGUOUS;
        finish_total_time(&result->quality, total_start);
        return 0;
    }
    if (selected_huber)
        result->quality.flags |= MEAS_QUALITY_HUBER_USED;
    populate_result(
        &selected_fit, time_meta, spectrum_meta, cal,
        snr_db, ranked_count, result);
    finish_total_time(&result->quality, total_start);
    return 1;
}
