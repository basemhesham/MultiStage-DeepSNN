"""
Stage 1 Quantized Model (Conv -> BatchNorm -> LIF)
====================================================

Extracted from `kd_quant.py` -> CustomQuantizedG11.forward(), "Block 1"
(lines: conv1 -> bn1 -> pool1 -> lif1). This module isolates exactly that
slice of the pipeline -- from the raw conv inputs (pixels + weights) through
to the LIF spike/membrane output -- so it can be run standalone as a golden
reference against the RTL implementation (top_conv9_array / pixel_mem).

INPUT FILE FORMAT
------------------
A plain text file with four labeled sections (one per line, followed by a
whitespace-separated list of integers), matching `inputs.txt`:

    BN_WEIGHTS
    <32 integers>
    BN_BIAS
    <32 integers>
    PIXELS
    <TREES * UNITS_PER_TREE * TAPS integers>
    CONV_WEIGHTS
    <TREES * UNITS_PER_TREE * TAPS integers>

All integers are Q9.9 fixed-point (18-bit total, 9 fractional bits) unless
overridden with --frac-bits/--total-bits.

DATA LAYOUT ASSUMPTIONS (confirmed with user, see conversation)
------------------------------------------------------------------
  - TREES            = 12   (independent pixel "trees")
  - UNITS_PER_TREE    = 32   (conv units per tree == BN/LIF channels)
  - TAPS per unit     = 9    (each conv9 unit does a 9-tap MAC:
                               9 pixel inputs x 9 matching weights)
  - PIXELS and CONV_WEIGHTS are therefore each pre-extracted per-unit
    patches (im2col-style), NOT a raw (H, W, C) feature map. Because of
    this, myConv2D_numba's sliding-window convolution does NOT apply here;
    each conv unit's output is a direct 9-tap dot product + bias.
  - BN_WEIGHTS / BN_BIAS have one entry per "unit" (32 channels), shared
    across all 12 trees, matching the model's bn1 (32 features).
  - No 2x2 max-pool step is applied: the pre-extracted per-unit layout
    (12 trees x 32 units) has no well-defined 2D spatial neighborhood to
    pool over at this stage. If your RTL performs pooling before LIF,
    re-enable/adjust `apply_pool` accordingly -- see NOTE at bottom.

If any of these assumptions are wrong for your data, adjust the constants
in `parse_input_file()` / the CLI flags below.
"""

import argparse
import os
import numpy as np
from numba import njit, prange


# ----------------------------------------------------------------------
#  Quantizer (copied verbatim from kd_quant.py)
# ----------------------------------------------------------------------
@njit
def quantize_scalar(v, scale, min_val, max_val):
    """Quantize a scalar value using fixed-point rounding and clamping."""
    q = np.round(v * scale)
    int_min = min_val * scale
    int_max = max_val * scale
    if q < int_min:
        q = int_min
    if q > int_max:
        q = int_max
    return q / scale


@njit(parallel=True)
def quantize_array(arr, scale, min_val, max_val):
    """Quantize every element of an array elementwise."""
    out = np.zeros_like(arr)
    int_min = min_val * scale
    int_max = max_val * scale
    for idx in np.ndindex(arr.shape):
        q = np.round(arr[idx] * scale)
        if q < int_min:
            q = int_min
        if q > int_max:
            q = int_max
        out[idx] = q / scale
    return out


# ----------------------------------------------------------------------
#  Conv9 unit: 9-tap MAC per (tree, unit), replaces myConv2D_numba
#  since PIXELS/CONV_WEIGHTS arrive pre-extracted (im2col-style).
# ----------------------------------------------------------------------
@njit(parallel=True)
def myConv9Unit_numba(pixels, weights, bias, quant, scale, min_val, max_val):
    """9-tap MAC convolution unit (channel-last: trees x units).

    Args:
        pixels: Pixel patches (TREES, UNITS, 9).
        weights: Matching kernel weights (TREES, UNITS, 9).
        bias: Bias per unit/channel (UNITS,).
        quant, scale, min_val, max_val: Quantization parameters.

    Returns:
        Output array (TREES, UNITS) -- one accumulated value per conv unit.
    """
    TREES, UNITS, TAPS = pixels.shape
    out = np.zeros((TREES, UNITS), dtype=pixels.dtype)

    for t in prange(TREES):
        for u in range(UNITS):
            acc = 0.0
            for k in range(TAPS):
                prod = pixels[t, u, k] * weights[t, u, k]
                if quant:
                    prod = quantize_scalar(prod, scale, min_val, max_val)
                acc += prod
                if quant:
                    acc = quantize_scalar(acc, scale, min_val, max_val)
            val = acc + bias[u]
            if quant:
                val = quantize_scalar(val, scale, min_val, max_val)
            out[t, u] = val
    return out


# ----------------------------------------------------------------------
#  Batch Normalization (affine: A*x + B) -- copied/adapted from kd_quant.py
#  Works on any 2D (rows, channels) array, here (TREES, UNITS).
# ----------------------------------------------------------------------
@njit(parallel=True)
def myBatchNorm2D_numba(x, A, B, quant=False, scale=1.0, min_val=0, max_val=255):
    """Apply batch normalization over (TREES, UNITS) with UNITS as channel dim."""
    TREES, UNITS = x.shape
    out = np.zeros_like(x)
    for u in prange(UNITS):
        for t in range(TREES):
            v = A[u] * x[t, u]
            if quant:
                v = quantize_scalar(v, scale, min_val, max_val)
            v += B[u]
            if quant:
                v = quantize_scalar(v, scale, min_val, max_val)
            out[t, u] = v
    return out


# ----------------------------------------------------------------------
#  LIF Neuron (one timestep, hard reset) -- copied verbatim from
#  kd_quant.py, generalized here to (TREES, UNITS) instead of (H, W, C).
# ----------------------------------------------------------------------
@njit(parallel=True)
def myLIF_numba_quant(spk_in, x, mem, beta, threshold,
                       quant, scale, min_val, max_val):
    """Leaky Integrate-and-Fire neuron for one timestep (TREES, UNITS)."""
    TREES, UNITS = x.shape
    spk_out = np.zeros_like(mem)
    new_mem = np.zeros_like(mem)

    beta = np.float32(beta)
    threshold = np.float32(threshold)
    scale = np.float32(scale)
    min_val = np.float32(min_val)
    max_val = np.float32(max_val)

    for t in prange(TREES):
        for u in range(UNITS):
            prod = beta * mem[t, u]
            if quant:
                prod = quantize_scalar(prod, scale, min_val, max_val)

            sum1 = prod + x[t, u]
            if quant:
                sum1 = quantize_scalar(sum1, scale, min_val, max_val)

            reset_term = spk_in[t, u] * threshold
            if quant:
                reset_term = quantize_scalar(reset_term, scale, min_val, max_val)

            m = sum1 - reset_term
            if quant:
                m = quantize_scalar(m, scale, min_val, max_val)

            s = 1.0 if m >= threshold else 0.0
            if quant:
                s = quantize_scalar(s, scale, min_val, max_val)

            spk_out[t, u] = s
            new_mem[t, u] = m
    return spk_out, new_mem


# ----------------------------------------------------------------------
#  Stage 1 pipeline: conv9 -> bn -> lif
# ----------------------------------------------------------------------
def run_stage1(pixels, weights, bias, bn_A, bn_B, beta, threshold,
                quant, scale, min_val, max_val,
                spk_in=None, mem_in=None):
    """Run Stage 1: conv input -> conv9 -> bn -> LIF output.

    Args:
        pixels: (TREES, UNITS, TAPS) pixel patches.
        weights: (TREES, UNITS, TAPS) conv weights.
        bias: (UNITS,) conv bias.
        bn_A, bn_B: (UNITS,) fused batch-norm scale/shift.
        beta, threshold: LIF parameters.
        quant, scale, min_val, max_val: Quantization parameters.
        spk_in, mem_in: Previous timestep spike/membrane state,
            (TREES, UNITS). Defaults to zeros (first timestep).

    Returns:
        dict with keys: conv, bn, lif_spk, lif_mem
    """
    TREES, UNITS, _ = pixels.shape
    if spk_in is None:
        spk_in = np.zeros((TREES, UNITS), dtype=np.float32)
    if mem_in is None:
        mem_in = np.zeros((TREES, UNITS), dtype=np.float32)

    conv_out = myConv9Unit_numba(pixels, weights, bias, quant, scale, min_val, max_val)
    bn_out = myBatchNorm2D_numba(conv_out, bn_A, bn_B, quant, scale, min_val, max_val)

    # NOTE: no max-pool step here -- see module docstring for why.

    spk_out, mem_out = myLIF_numba_quant(
        spk_in, bn_out, mem_in, beta, threshold, quant, scale, min_val, max_val
    )

    return {
        "conv": conv_out,
        "bn": bn_out,
        "lif_spk": spk_out,
        "lif_mem": mem_out,
    }


# ----------------------------------------------------------------------
#  Input file parsing
# ----------------------------------------------------------------------
def parse_input_file(path, trees=12, units=32, taps=9):
    """Parse the labeled-section input file into raw integer arrays.

    Expects sections: BN_WEIGHTS, BN_BIAS, PIXELS, CONV_WEIGHTS.
    """
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    text = text.replace("\r\n", "\n").replace("\r", "\n")

    sections = {}
    current = None
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        if line in ("BN_WEIGHTS", "BN_BIAS", "PIXELS", "CONV_WEIGHTS"):
            current = line
            sections[current] = []
        elif current is not None:
            sections[current].extend(line.split())

    required = ["BN_WEIGHTS", "BN_BIAS", "PIXELS", "CONV_WEIGHTS"]
    missing = [s for s in required if s not in sections]
    if missing:
        raise ValueError(f"Input file missing section(s): {missing}")

    bn_w = np.array([int(v) for v in sections["BN_WEIGHTS"]], dtype=np.float64)
    bn_b = np.array([int(v) for v in sections["BN_BIAS"]], dtype=np.float64)
    pixels = np.array([int(v) for v in sections["PIXELS"]], dtype=np.float64)
    weights = np.array([int(v) for v in sections["CONV_WEIGHTS"]], dtype=np.float64)

    expected_bn = units
    expected_conv = trees * units * taps
    if bn_w.size != expected_bn or bn_b.size != expected_bn:
        raise ValueError(
            f"BN_WEIGHTS/BN_BIAS length {bn_w.size}/{bn_b.size} != expected {expected_bn} "
            f"(units={units}). Check --units."
        )
    if pixels.size != expected_conv or weights.size != expected_conv:
        raise ValueError(
            f"PIXELS/CONV_WEIGHTS length {pixels.size}/{weights.size} != expected "
            f"{expected_conv} (trees={trees} x units={units} x taps={taps}). "
            f"Check --trees/--units/--taps."
        )

    pixels = pixels.reshape(trees, units, taps)
    weights = weights.reshape(trees, units, taps)

    return bn_w, bn_b, pixels, weights


def dequantize(int_array, scale):
    """Convert raw fixed-point integers (as read from file) to real values."""
    return int_array / scale


def write_output_file(out_path, results, scale):
    """Write stage-1 results to a labeled-section text file (same style as input)."""
    def fmt_2d(arr):
        # arr: (TREES, UNITS) -> flatten row-major, space separated
        return " ".join(f"{v:.6f}" for v in arr.flatten())

    with open(out_path, "w") as f:
        f.write("CONV_OUT\n")
        f.write(fmt_2d(results["conv"]) + "\n")
        f.write("BN_OUT\n")
        f.write(fmt_2d(results["bn"]) + "\n")
        f.write("LIF_SPK\n")
        f.write(fmt_2d(results["lif_spk"]) + "\n")
        f.write("LIF_MEM\n")
        f.write(fmt_2d(results["lif_mem"]) + "\n")


# ----------------------------------------------------------------------
#  CLI
# ----------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Run Stage 1 (conv -> BN -> LIF) golden model on an input file."
    )
    parser.add_argument("input_file", type=str,
                         help="Path to input file (BN_WEIGHTS/BN_BIAS/PIXELS/CONV_WEIGHTS).")
    parser.add_argument("--output-file", type=str, default=None,
                         help="Path to write results. Defaults to "
                              "'<input_dir>/<input_stem>_stage1_output.txt'.")
    parser.add_argument("--trees", type=int, default=12)
    parser.add_argument("--units", type=int, default=32)
    parser.add_argument("--taps", type=int, default=9)
    parser.add_argument("--frac-bits", type=int, default=9,
                         help="Fractional bits (Q9.9 default -> scale=2^9=512).")
    parser.add_argument("--total-bits", type=int, default=18)
    parser.add_argument("--beta", type=float, default=0.9, help="LIF leak factor.")
    parser.add_argument("--threshold", type=float, default=1.0, help="LIF firing threshold.")
    parser.add_argument("--no-quant", action="store_true",
                         help="Disable fixed-point quantization (use float math).")
    args = parser.parse_args()

    scale = 2 ** args.frac_bits
    min_val = -(2 ** (args.total_bits - 1)) / scale
    max_val = (2 ** (args.total_bits - 1) - 1) / scale
    quant = not args.no_quant

    # --- Parse & dequantize inputs ---
    bn_w_raw, bn_b_raw, pixels_raw, weights_raw = parse_input_file(
        args.input_file, trees=args.trees, units=args.units, taps=args.taps
    )
    bn_A = dequantize(bn_w_raw, scale)
    bn_B = dequantize(bn_b_raw, scale)
    pixels = dequantize(pixels_raw, scale)
    weights = dequantize(weights_raw, scale)
    bias = np.zeros(args.units, dtype=np.float64)  # no separate conv bias section in file

    # --- Run Stage 1 ---
    results = run_stage1(
        pixels, weights, bias, bn_A, bn_B,
        beta=args.beta, threshold=args.threshold,
        quant=quant, scale=scale, min_val=min_val, max_val=max_val,
    )

    # --- Output path derived from input file's path ---
    if args.output_file:
        out_path = args.output_file
    else:
        in_dir = os.path.dirname(os.path.abspath(args.input_file))
        in_stem = os.path.splitext(os.path.basename(args.input_file))[0]
        out_path = os.path.join(in_dir, f"{in_stem}_stage1_output.txt")

    write_output_file(out_path, results, scale)
    print(f"Stage 1 complete. Results written to: {out_path}")
    print(f"  conv    shape={results['conv'].shape}")
    print(f"  bn      shape={results['bn'].shape}")
    print(f"  lif_spk shape={results['lif_spk'].shape}, spikes fired={int(results['lif_spk'].sum())}")
    print(f"  lif_mem shape={results['lif_mem'].shape}")


if __name__ == "__main__":
    main()
