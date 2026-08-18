#!/usr/bin/env python3
"""Deterministic golden checks for the measurement math and fixed-point assets."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from scipy.signal import freqz


ROOT = Path(__file__).resolve().parents[1]
FS = 2_000_000.0
N = 65_536


def load_fir() -> np.ndarray:
    lines = (ROOT / "rtl" / "fir_decimate_25.coe").read_text().splitlines()[2:]
    return np.array([int(line.rstrip(",;")) for line in lines], dtype=np.float64)


def load_window() -> np.ndarray:
    half = np.array(
        [
            int(line, 16)
            for line in (ROOT / "rtl" / "blackman_harris_half.mem")
            .read_text()
            .splitlines()
        ],
        dtype=np.float64,
    )
    return np.concatenate((half, half[::-1])) / (1 << 23)


def harmonic_fit(samples: np.ndarray, fundamental: float, harmonics: tuple[int, ...]):
    index = np.arange(samples.size, dtype=np.float64)
    columns = [np.ones(samples.size)]
    for harmonic in harmonics:
        phase = 2 * np.pi * fundamental * harmonic * index / FS
        columns.extend((np.cos(phase), np.sin(phase)))
    design = np.column_stack(columns)
    normal = design.T @ design
    rhs = design.T @ samples
    lower = np.linalg.cholesky(normal)
    coefficients = np.linalg.solve(lower.T, np.linalg.solve(lower, rhs))
    residual = samples - design @ coefficients
    return coefficients, np.sqrt(np.mean(residual * residual))


def main() -> int:
    fir = load_fir() / (1 << 23)
    frequency, response = freqz(fir, worN=1_048_576, fs=50_000_000.0)
    passband = np.abs(response[frequency <= 500_000.0])
    stopband = np.abs(response[frequency >= 1_000_000.0])
    ripple = 20 * np.log10(passband.max() / passband.min())
    attenuation = -20 * np.log10(stopband.max())
    assert ripple <= 0.001
    assert attenuation >= 90.0

    window = load_window()
    assert window.size == N
    assert np.array_equal(window, window[::-1])
    assert np.max(window) <= 1.0

    f0 = 37_123.456
    harmonics = (1, 2, 3)
    peaks = np.array([0.42, 0.11, 0.035])
    phases = np.array([0.37, -0.61, 1.11])
    index = np.arange(N, dtype=np.float64)
    signal = np.full(N, 0.017)
    for harmonic, peak, phase in zip(harmonics, peaks, phases):
        signal += peak * np.cos(2 * np.pi * f0 * harmonic * index / FS + phase)

    # A five-point local comb search must select a frequency within 1 kHz.
    coarse = round(f0 * N / FS) * FS / N
    trials = coarse + np.arange(-2, 3) * FS / N / 2
    scores = []
    for trial in trials:
        score = 0.0
        for harmonic in harmonics:
            phasor = np.exp(-2j * np.pi * trial * harmonic * index[:32768] / FS)
            score += abs(np.dot(signal[:32768], phasor)) / np.sqrt(harmonic)
        scores.append(score)
    refined = trials[int(np.argmax(scores))]
    assert abs(refined - f0) <= 1_000.0

    coefficients, residual_rms = harmonic_fit(signal, f0, harmonics)
    fitted_peaks = np.hypot(coefficients[1::2], coefficients[2::2])
    assert np.max(np.abs(fitted_peaks - peaks)) < 5e-6
    assert residual_rms < 1e-10
    ac_rms = np.sqrt(np.sum(fitted_peaks * fitted_peaks) / 2)
    expected_rms = np.sqrt(np.sum(peaks * peaks) / 2)
    assert abs(ac_rms - expected_rms) < 5e-6

    phase_grid = np.arange(16384) * 2 * np.pi / 16384
    reconstructed = np.full(phase_grid.size, coefficients[0])
    for harmonic, peak, phase in zip(harmonics, peaks, phases):
        reconstructed += peak * np.cos(harmonic * phase_grid + phase)
    pp = reconstructed.max() - reconstructed.min()
    dense_phase = np.arange(1_048_576) * 2 * np.pi / 1_048_576
    dense = np.full(dense_phase.size, 0.017)
    for harmonic, peak, phase in zip(harmonics, peaks, phases):
        dense += peak * np.cos(harmonic * dense_phase + phase)
    assert abs(pp - (dense.max() - dense.min())) <= 5e-6

    print(
        f"FIR ripple={ripple:.9f}dB stop={attenuation:.3f}dB "
        f"refined={refined:.6f}Hz residual={residual_rms:.3e}"
    )
    print("TEST_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
