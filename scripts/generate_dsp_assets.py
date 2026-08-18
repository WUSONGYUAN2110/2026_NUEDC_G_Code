#!/usr/bin/env python3
"""Generate deterministic fixed-point FIR and Blackman-Harris assets.

The generated files are persistent design inputs.  The script also verifies
the response after 24-bit quantization so a coefficient update cannot silently
relax the measurement-channel specification.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import numpy as np
from scipy.signal import freqz, remez


ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"

FS_HZ = 50_000_000.0
PASS_HZ = 500_000.0
STOP_HZ = 1_000_000.0
FIR_TAPS = 625
COEFF_BITS = 24
FFT_LENGTH = 65_536
WINDOW_BITS = 24

SHARED_CONSTANTS = {
    "MEAS_FORMAT_VERSION": "MEAS_FORMAT_VERSION",
    "MEAS_TIME_MAGIC": "MEAS_TIME_MAGIC",
    "MEAS_SPECTRUM_MAGIC": "MEAS_SPECTRUM_MAGIC",
    "MEAS_TRAILER_WORDS": "MEAS_TIME_TRAILER_WORDS",
    "MEAS_SPECTRUM_TRAILER_BEATS": "MEAS_SPECTRUM_TRAILER_BEATS",
    "MEAS_SHORT_SAMPLES": "MEAS_SHORT_SAMPLES",
    "MEAS_POSITIVE_BINS": "MEAS_FFT_BINS",
}


def quantize_signed(values: np.ndarray, bits: int) -> np.ndarray:
    scale = 1 << (bits - 1)
    result = np.rint(values * scale).astype(np.int64)
    return np.clip(result, -scale, scale - 1)


def design_fir() -> np.ndarray:
    coeff = remez(
        FIR_TAPS,
        [0.0, PASS_HZ, STOP_HZ, FS_HZ / 2.0],
        [1.0, 0.0],
        weight=[1.0, 1.0],
        fs=FS_HZ,
        maxiter=1000,
        grid_density=32,
    )
    quantized = quantize_signed(coeff, COEFF_BITS)
    # Preserve exact DC gain without breaking symmetry.
    quantized[FIR_TAPS // 2] += (1 << (COEFF_BITS - 1)) - int(quantized.sum())
    return quantized


def verify_fir(coeff_int: np.ndarray) -> dict[str, float]:
    coeff = coeff_int.astype(np.float64) / float(1 << (COEFF_BITS - 1))
    freq, response = freqz(coeff, worN=1_048_576, fs=FS_HZ)
    pass_mag = np.abs(response[freq <= PASS_HZ])
    stop_mag = np.abs(response[freq >= STOP_HZ])
    ripple_db = float(20.0 * np.log10(pass_mag.max() / pass_mag.min()))
    stop_db = float(-20.0 * np.log10(stop_mag.max()))
    if ripple_db > 0.001:
        raise RuntimeError(f"quantized FIR passband ripple failed: {ripple_db:.9f} dB")
    if stop_db < 90.0:
        raise RuntimeError(f"quantized FIR stopband failed: {stop_db:.6f} dB")
    return {
        "passband_ripple_db": ripple_db,
        "stopband_attenuation_db": stop_db,
        "dc_integer_sum": int(coeff_int.sum()),
    }


def blackman_harris_half() -> np.ndarray:
    n = np.arange(FFT_LENGTH // 2, dtype=np.float64)
    phase = 2.0 * np.pi * n / (FFT_LENGTH - 1)
    window = (
        0.35875
        - 0.48829 * np.cos(phase)
        + 0.14128 * np.cos(2.0 * phase)
        - 0.01168 * np.cos(3.0 * phase)
    )
    return quantize_signed(window, WINDOW_BITS)


def twos_hex(value: int, bits: int) -> str:
    return f"{value & ((1 << bits) - 1):0{(bits + 3) // 4}X}"


def write_coe(path: Path, values: np.ndarray, bits: int, radix: int = 16) -> None:
    if radix != 16:
        raise ValueError("only radix 16 is supported")
    body = ",\n".join(twos_hex(int(value), bits) for value in values)
    path.write_text(
        "memory_initialization_radix=16;\n"
        "memory_initialization_vector=\n"
        f"{body};\n",
        encoding="ascii",
        newline="\n",
    )


def write_fir_coe(path: Path, values: np.ndarray) -> None:
    # FIR Compiler accepts a radix line followed by the coefficient vector.
    body = ",\n".join(str(int(value)) for value in values)
    path.write_text(
        "radix=10;\n"
        "coefdata=\n"
        f"{body};\n",
        encoding="ascii",
        newline="\n",
    )


def parse_integer(text: str) -> int:
    text = text.replace("_", "").rstrip("UuLl")
    match = re.fullmatch(r"\d+'h([0-9a-fA-F]+)", text)
    if match:
        return int(match.group(1), 16)
    return int(text, 0)


def verify_shared_constants() -> None:
    sv_path = RTL / "measurement_defs.svh"
    c_path = ROOT / "vitis" / "src" / "measurement_format.h"
    if not c_path.is_file():
        return
    sv_defs = dict(re.findall(
        r"^`define[ \t]+(\w+)[ \t]+([^ \t\r\n]+)",
        sv_path.read_text(), re.MULTILINE))
    c_defs = dict(re.findall(
        r"^#define[ \t]+(\w+)[ \t]+([^ \t\r\n(]+)",
        c_path.read_text(), re.MULTILINE))
    for sv_name, c_name in SHARED_CONSTANTS.items():
        if sv_name not in sv_defs or c_name not in c_defs:
            raise RuntimeError(f"missing shared constant: RTL={sv_name}, C={c_name}")
        sv_value = parse_integer(sv_defs[sv_name])
        c_value = parse_integer(c_defs[c_name])
        if sv_value != c_value:
            raise RuntimeError(
                f"shared format drift: RTL {sv_name}={sv_value}, "
                f"C {c_name}={c_value}"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify existing assets")
    args = parser.parse_args()

    fir = design_fir()
    metrics = verify_fir(fir)
    window = blackman_harris_half()

    expected = {
        RTL / "fir_decimate_25.coe": (
            "radix=10;\ncoefdata=\n"
            + ",\n".join(str(int(value)) for value in fir)
            + ";\n"
        ),
        RTL / "fir_decimate_25.mem": (
            "\n".join(twos_hex(int(value), COEFF_BITS) for value in fir)
            + "\n"
        ),
        RTL / "blackman_harris_half.coe": (
            "memory_initialization_radix=16;\n"
            "memory_initialization_vector=\n"
            # The Block Memory Generator port is 32 bits.  Vivado 2022.2 can
            # reject a large COE whose tokens are narrower than the configured
            # port even though it accepts short test vectors, so zero-extend
            # every positive Q1.23 coefficient explicitly to eight hex digits.
            + ",\n".join(twos_hex(int(value), 32) for value in window)
            + ";\n"
        ),
        RTL / "blackman_harris_half.mem": (
            "\n".join(twos_hex(int(value), WINDOW_BITS) for value in window)
            + "\n"
        ),
    }

    if args.check:
        for path, content in expected.items():
            if not path.is_file() or path.read_text(encoding="ascii") != content:
                raise SystemExit(f"stale DSP asset: {path}")
    else:
        RTL.mkdir(parents=True, exist_ok=True)
        for path, content in expected.items():
            path.write_text(content, encoding="ascii", newline="\n")

    metrics.update(
        {
            "fir_taps": FIR_TAPS,
            "coefficient_bits": COEFF_BITS,
            "fft_length": FFT_LENGTH,
            "window_half_length": int(window.size),
        }
    )
    verify_shared_constants()
    print(json.dumps(metrics, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
