"""
rtl_mapping_model.py
=============================================================================
Bit-exact Python model of every module that sits BEFORE the shared conv9
array on the Stage-1 pixel path, i.e.:

    - Mapping_Cntrl_Ver2.sv        (module: mapping_controller, WIN_GROUP=4)
    - top_pixel_source_mapper.sv   (Stage-1 branch: pixels_s1[12][32][9])

Given one input frame (a 256x256 grayscale dump -- delimited text OR a raw
binary file, see Section 2), this script reproduces -- cycle for cycle,
index for index -- the same sequence of pixels_mapped[12][32][9] tensors
that `top_pixel_source_mapper` would present to the shared conv9 array
during Stage 1 (src_sel = 2'b00), so the output can be used directly as
conv-array stimulus in simulation/verification.

Out of scope: `top_weight_mapper` (the weight-side counterpart on the same
Stage-1 input) is NOT modeled here, because its `CONV1_W_MAP_OPT` weight ROM
is generated/trained data that isn't part of the RTL source tree -- there is
no RTL logic to mimic beyond a ROM lookup. Only the PIXEL path is covered.

-----------------------------------------------------------------------------
WHAT IS MODELED EXACTLY vs. WHAT IS ABSTRACTED AWAY
-----------------------------------------------------------------------------
Modeled bit-exactly (this is "the mapping"):
    * mode_r / pad_top / pad_bot / pad_left / pad_right / active_rows /
      active_cols / real_buf_row_start / real_buf_col_start /
      conv_slides_row / conv_slides_col      (mapping_controller's
      per-sweep/per-window padding-aware windowing math)
    * The WIN_GROUP=4 parallel-lane grouping, per-lane validity
      (valid_mask_o), and the exact 450-bit-per-lane / slot-24..slot-0
      pixel packing order used to build conv_pixels_o.
    * top_pixel_source_mapper's Stage-1 index arithmetic: WINDOW / BLOCK_G /
      GLOBAL_CH channel-rotation / BLOCK / TAP_OFFSET / IN_IDX, including the
      2-zero-tap padding in BLOCK 2 (the "CONV25 via 3x conv9, 2 MACs
      zeroed" trick).

Intentionally NOT modeled (irrelevant to the resulting data values):
    * The physical 24-row x 3-column-bank circular buffer, bank rotation
      (fetch_order / write_bank), 72-bit-word memory addressing, and the
      LOAD / WAIT_FETCH / FETCH handshake timing inside mapping_controller.
      These exist purely so the real hardware can deliver the needed pixels
      through a small on-chip buffer fed 4-pixels-at-a-time from external
      memory. Because this script has direct random access to the full
      image, it reaches the *same pixel values* by indexing the image
      array directly -- see the "ANCHOR DERIVATION" note in
      MappingControllerModel for the proof that this is equivalent.

If the RTL's mapping logic changes, you should only need to edit the
functions in section 3 (MappingControllerModel) and/or section 4
(TopPixelSourceMapperStage1) -- each mirrors one specific RTL block and is
commented with the exact RTL line(s) it reproduces.
=============================================================================
"""

from __future__ import annotations

import argparse
import os
import struct
from dataclasses import dataclass
from typing import Iterator, List, NamedTuple, Optional

import numpy as np


# =============================================================================
# >>> EDIT THESE LINES <<<
#   IMAGE_PATH: path to your input frame dump. Any extension is fine -- the
#     loader in Section 2 auto-detects whether the file is delimited text
#     (e.g. ".txt") or a raw binary dump (e.g. ".bin"/".raw"/".dat", or any
#     file that simply isn't valid UTF-8 text).
#   IMAGE_DTYPE: the numpy dtype the raw bytes should be interpreted as, for
#     BINARY files only (ignored for text files, where each number is parsed
#     directly). Leave as None to auto-detect from the file size (works only
#     if the file size unambiguously matches rows*cols*itemsize for exactly
#     one common dtype -- see _infer_binary_dtype()). If detection fails or
#     picks the wrong dtype, set this explicitly, e.g. "uint8", "int16",
#     "float32".
#   FIXED_POINT_SCALE: multiply every loaded pixel by this before use. Leave
#     at 1 if your dump already holds raw integer pixel/PIXEL_W-format
#     values (the common case for an 8-bit grayscale dump). If your dump
#     instead holds normalized floats (e.g. 0.0-1.0) that still need to be
#     quantized into the accelerator's Q8.9 fixed-point format (scale 512)
#     before being packed for the RTL, set this to 512 -- see Section 6.
# =============================================================================
IMAGE_PATH: Optional[str] = r"D:\My life\STM Training\MultiStage-DeepSNN\Python_data_handler\input_t0.bin"
IMAGE_DTYPE: Optional[str] = None
FIXED_POINT_SCALE: float = 1


# =============================================================================
# SECTION 1 -- Parameters
#   Every field here corresponds 1:1 to a `parameter` in the RTL. Keep the
#   names matched to the RTL so future parameter changes are a one-line edit.
# =============================================================================

@dataclass(frozen=True)
class MappingControllerParams:
    """Mirrors the `parameter` list of `mapping_controller` (Mapping_Cntrl_Ver2.sv)."""

    PIXEL_W: int = 18          # bits per pixel (RTL: PIXEL_W)
    BUF_SIZE: int = 24         # buffer dimension, 24x24               (RTL: BUF_SIZE)
    BANK_COLS: int = 8         # pixel-columns loaded per bank/step     (RTL: BANK_COLS)
    CONV_K: int = 5            # conv kernel size, 5x5                  (RTL: CONV_K)
    WIN_GROUP: int = 4         # parallel windows per FETCH cycle       (RTL: WIN_GROUP)
    NUM_H_WIN: int = 30        # horizontal window count per sweep      (RTL: NUM_H_WIN)
    NUM_SWEEPS: int = 30       # vertical sweep count per frame         (RTL: NUM_SWEEPS)

    # --- Not literal RTL parameters, but the step sizes the RTL hard-codes
    #     into its FSM (`row_origin + 8`, and BANK_COLS itself for columns).
    #     Kept as separate named constants so a future asymmetric change
    #     (e.g. a different row step) is a one-line edit here, not a bug hunt.
    ROW_STEP: int = 8          # sweep-to-sweep row anchor step (RTL: `row_origin + 5'd8`)
    COL_STEP: int = 8          # window-to-window col anchor step (== BANK_COLS today)

    IMG_ROWS_FULL: int = 256   # true (unpadded) image height supplied externally
    IMG_COLS_FULL: int = 256   # true (unpadded) image width supplied externally
    PAD: int = 2               # zero-pad pixels added per border side (256 -> 260)

    def __post_init__(self):
        # Defensive consistency checks -- catch a parameter edit that would
        # silently break the sweep/window tiling math below.
        assert (self.IMG_ROWS_FULL - self.BUF_SIZE) % self.ROW_STEP == 0, \
            "ROW_STEP does not evenly tile IMG_ROWS_FULL with BUF_SIZE"
        assert (self.IMG_ROWS_FULL - self.BUF_SIZE) // self.ROW_STEP + 1 == self.NUM_SWEEPS, \
            "NUM_SWEEPS inconsistent with IMG_ROWS_FULL/BUF_SIZE/ROW_STEP"
        assert (self.IMG_COLS_FULL - self.BUF_SIZE) % self.COL_STEP == 0, \
            "COL_STEP does not evenly tile IMG_COLS_FULL with BUF_SIZE"
        assert (self.IMG_COLS_FULL - self.BUF_SIZE) // self.COL_STEP + 1 == self.NUM_H_WIN, \
            "NUM_H_WIN inconsistent with IMG_COLS_FULL/BUF_SIZE/COL_STEP"


@dataclass(frozen=True)
class TopPixelMapperParams:
    """Mirrors the Stage-1-relevant parameters of `top_pixel_source_mapper`."""

    PIXEL_W: int = 18
    N_GROUPS: int = 12   # gp1 range  -> pixels_mapped[0:11]
    N_CHAN: int = 32     # cp1 range  -> pixels_mapped[.][0:31]
    N_TAPS: int = 9      # tp1 range  -> pixels_mapped[.][.][0:8]
    N_WINDOWS: int = 4   # WINDOW range (must equal MappingControllerParams.WIN_GROUP)


# =============================================================================
# SECTION 2 -- Image I/O
#
#   Two on-disk formats are supported, auto-detected by default:
#     (a) delimited TEXT   -- whitespace-separated numbers, or fixed-width
#                             packed hex/binary-digit rows (the original
#                             format this script supported)
#     (b) raw BINARY       -- a flat dump of `rows*cols` samples of some
#                             numpy dtype, with no text framing at all (the
#                             natural format for a ".bin" file written by
#                             `array.tofile()` from a Python/numpy/PyTorch
#                             preprocessing step)
# =============================================================================

# File extensions that are always treated as raw binary, no sniffing needed.
_BINARY_EXTENSIONS = {".bin", ".raw", ".dat"}

# Candidate dtypes tried by _infer_binary_dtype(), in the order they are
# preferred when more than one would technically fit the file size.
_BINARY_DTYPE_CANDIDATES = ["uint8", "int16", "uint16", "float32", "int32", "float64"]


def _looks_like_text(path: str, sniff_bytes: int = 4096) -> bool:
    """Best-effort sniff: does this file look like delimited text we can parse?"""
    with open(path, "rb") as f:
        chunk = f.read(sniff_bytes)
    if b"\x00" in chunk:
        return False  # NUL bytes never appear in a plain numeric text file
    try:
        chunk.decode("utf-8")
    except UnicodeDecodeError:
        return False
    # Printable/whitespace only (a real text dump of numbers/hex/binary digits)
    return all((32 <= b <= 126) or b in (9, 10, 13) for b in chunk)


def _infer_binary_dtype(path: str, rows: int, cols: int) -> np.dtype:
    """
    Infer the pixel dtype of a raw binary dump from its file size, by
    checking which candidate dtype makes `rows*cols*itemsize` equal the
    file's actual byte length. Raises with a clear message (naming the
    --dtype flag / IMAGE_DTYPE variable) if the size is ambiguous or
    matches nothing.
    """
    size = os.path.getsize(path)
    matches = [d for d in _BINARY_DTYPE_CANDIDATES if rows * cols * np.dtype(d).itemsize == size]
    if len(matches) == 1:
        return np.dtype(matches[0])
    if len(matches) > 1:
        raise ValueError(
            f"'{path}' is {size} bytes, which matches more than one dtype for a "
            f"{rows}x{cols} frame ({matches}). Set IMAGE_DTYPE / --dtype explicitly."
        )
    raise ValueError(
        f"'{path}' is {size} bytes, which doesn't match {rows}x{cols} pixels for any "
        f"of {_BINARY_DTYPE_CANDIDATES}. Set IMAGE_DTYPE / --dtype explicitly, or check "
        f"--rows/--cols."
    )


def load_image_binary(path: str, rows: int = 256, cols: int = 256,
                       dtype: Optional[str] = None) -> np.ndarray:
    """Read a flat raw-binary pixel dump into a (rows, cols) array."""
    np_dtype = np.dtype(dtype) if dtype else _infer_binary_dtype(path, rows, cols)
    flat = np.fromfile(path, dtype=np_dtype)
    if flat.size != rows * cols:
        raise ValueError(
            f"Expected {rows * cols} {np_dtype} values in '{path}', got {flat.size}. "
            f"Check --rows/--cols and IMAGE_DTYPE/--dtype."
        )
    return flat.reshape(rows, cols)


def load_image_text(path: str, rows: int = 256, cols: int = 256,
                     dtype=np.float64) -> np.ndarray:
    """
    Read a delimited-text image dump into a (rows, cols) array.

    Accepts either:
      * whitespace/newline separated numeric text, or
      * fixed-width packed rows with no delimiters, such as a hex or binary
        ('0'/'1') dump where each row contains exactly `cols` concatenated
        values.
    """
    with open(path, "r", encoding="utf-8") as f:
        lines = [line.strip() for line in f if line.strip()]

    data_lines = [line for line in lines if not line.startswith("#")]
    if not data_lines:
        raise ValueError(f"No image data found in '{path}'.")

    sample = data_lines[0]

    if any(ch.isspace() for ch in sample):
        flat = np.fromstring(" ".join(data_lines), sep=" ", dtype=dtype)
    else:
        if len(data_lines) != rows:
            raise ValueError(
                f"Expected {rows} data rows in '{path}', got {len(data_lines)}. "
                f"Check the --rows/--cols arguments match the file."
            )

        row_width, remainder = divmod(len(sample), cols)
        if remainder != 0 or row_width == 0:
            raise ValueError(
                f"Cannot infer a fixed pixel width from '{path}': each row has "
                f"{len(sample)} characters for {cols} columns."
            )

        for line in data_lines:
            if len(line) != len(sample):
                raise ValueError(
                    f"Inconsistent row width in '{path}': expected {len(sample)} characters, "
                    f"got {len(line)}."
                )

        base = 2 if set(sample) <= {"0", "1"} else 16 if all(ch in "0123456789abcdefABCDEF" for ch in sample) else None
        if base is None:
            raise ValueError(
                f"Unsupported packed image encoding in '{path}'. Expected binary or hex rows."
            )

        pixels = []
        for line in data_lines:
            row = [int(line[i:i + row_width], base) for i in range(0, len(line), row_width)]
            pixels.extend(row)
        flat = np.asarray(pixels, dtype=dtype)

    if flat.size != rows * cols:
        raise ValueError(
            f"Expected {rows * cols} pixel values in '{path}', got {flat.size}. "
            f"Check the --rows/--cols arguments match the file."
        )
    return flat.reshape(rows, cols)


def load_image(path: str, rows: int = 256, cols: int = 256,
               dtype: Optional[str] = None) -> np.ndarray:
    """
    Load an image dump of either kind, auto-detecting text vs. binary:
      1. If the extension is in _BINARY_EXTENSIONS (.bin/.raw/.dat) -> binary.
      2. Else, sniff the first few KB: printable ASCII/whitespace -> text,
         anything else (including any NUL byte) -> binary.
    `dtype` only affects the binary path (see load_image_binary); it is
    ignored for text files, whose numeric type is inferred by the parser.
    """
    ext = os.path.splitext(path)[1].lower()
    is_binary = (ext in _BINARY_EXTENSIONS) or (not _looks_like_text(path))
    if is_binary:
        return load_image_binary(path, rows=rows, cols=cols, dtype=dtype)
    return load_image_text(path, rows=rows, cols=cols)


# Kept for backward compatibility with earlier versions of this script,
# which only supported the text path under this name.
def load_image_txt(path: str, rows: int = 256, cols: int = 256,
                    dtype=np.int32) -> np.ndarray:
    return load_image_text(path, rows=rows, cols=cols, dtype=dtype)


def zero_pad_image(img: np.ndarray, pad: int = 2) -> np.ndarray:
    """
    Zero-pad a (rows, cols) image to (rows + 2*pad, cols + 2*pad).

    This mirrors the accelerator's documented "260x260 zero-padded from
    256x256" front-end input convention. Note that `MappingControllerModel`
    below does NOT need this padded array for its own indexing (it derives
    the equivalent zero-fill directly from the RTL's pad_top/bot/left/right
    flags -- see the class docstring), but building it explicitly here (a)
    matches what was asked for, (b) is handy for visual sanity-checking, and
    (c) is used as the actual pixel source so the two approaches can never
    silently disagree.
    """
    padded = np.zeros((img.shape[0] + 2 * pad, img.shape[1] + 2 * pad), dtype=img.dtype)
    padded[pad:pad + img.shape[0], pad:pad + img.shape[1]] = img
    return padded


# =============================================================================
# SECTION 3 -- mapping_controller (Mapping_Cntrl_Ver2.sv) faithful model
# =============================================================================

class FetchCycle(NamedTuple):
    """One FETCH-state cycle's worth of output from mapping_controller."""
    sweep_idx: int
    win_idx: int
    conv_row: int
    conv_col: int                       # group start column (steps by WIN_GROUP)
    windows: np.ndarray                 # shape (WIN_GROUP, CONV_K, CONV_K), pixel values
    valid_mask: np.ndarray               # shape (WIN_GROUP,), bool
    conv_done: bool                      # True on the last group of the last row of this tile
    frame_done: bool                     # True on the very last cycle of the whole frame


class MappingControllerModel:
    """
    Bit-exact reproduction of `mapping_controller`'s FETCH-state combinational
    output (`conv_pixels_o` / `valid_mask_o`), for one full 256x256 frame.

    -------------------------------------------------------------------------
    ANCHOR DERIVATION (why direct image indexing is equivalent to the RTL's
    circular-buffer bookkeeping)
    -------------------------------------------------------------------------
    Define, for sweep `s` and window `w`:
        row_anchor = s * ROW_STEP
        col_anchor = w * COL_STEP

    The RTL's per-axis mode decode (verbatim, row axis shown; col axis is
    symmetric with s->w, ROW_STEP->COL_STEP):

        row_border   = (s == 0) or (s == NUM_SWEEPS - 1)
        pad_top      = PAD if (row_border and s == 0)               else 0
        pad_bot      = PAD if (row_border and s == NUM_SWEEPS - 1)  else 0
        active_rows  = (BUF_SIZE - ROW_STEP + PAD) if row_border else BUF_SIZE   # 18 or 24
        real_buf_row_start = ROW_STEP if pad_bot == PAD else 0
        conv_slides_row    = active_rows - CONV_K + 1                            # 14 or 20

    For an output row position `output_row` in [0, active_rows):
        in_pad  = output_row < pad_top or output_row >= active_rows - pad_bot
        buf_row = real_buf_row_start + output_row - pad_top          (only if not in_pad)
        real_image_row = row_anchor + buf_row                        (only if not in_pad)

    Working this out at the three cases confirms `real_image_row` always
    lands in [0, IMG_ROWS_FULL-1], i.e. it is a direct, valid index into the
    ORIGINAL (unpadded) image:
        s == 0            -> real_image_row in [0 .. BUF_SIZE-ROW_STEP-1]   (image rows 0..15)
        s == NUM_SWEEPS-1  -> real_image_row in [row_anchor+ROW_STEP ..
                                                  row_anchor+BUF_SIZE-1]     (image rows 240..255)
        interior s         -> real_image_row in [row_anchor ..
                                                  row_anchor+BUF_SIZE-1]     (fully inside [0,255])

    So instead of reproducing the physical 24-row circular buffer, bank
    rotation, and word-address generation, this class computes
    `real_image_row`/`real_image_col` directly from (s, w, output_row,
    output_col) with the formulas above, and looks the pixel up straight out
    of the (padded, for convenience) image array. Zero-padding is applied by
    literally returning 0 for any position flagged `in_pad`, exactly as the
    RTL does (`conv_pixels_o[...] = '0`), and never reads outside the
    original image bounds -- both facts are checked with assertions below so
    a future parameter change that breaks this equivalence fails loudly
    instead of silently producing wrong pixels.
    -------------------------------------------------------------------------
    """

    def __init__(self, padded_image: np.ndarray, params: MappingControllerParams):
        p = params
        expected_shape = (p.IMG_ROWS_FULL + 2 * p.PAD, p.IMG_COLS_FULL + 2 * p.PAD)
        if padded_image.shape != expected_shape:
            raise ValueError(f"padded_image shape {padded_image.shape} != expected {expected_shape}")
        self.padded_image = padded_image
        self.p = p

    # ---- per-axis mode decode (RTL: the `always_comb` block around line 310) ----

    def _axis_mode(self, idx: int, num: int, step: int):
        """Returns (pad_near, pad_far, active_len, real_buf_start) for one axis.

        `pad_near` corresponds to pad_top/pad_left (border at idx==0),
        `pad_far`  corresponds to pad_bot/pad_right (border at idx==num-1).
        """
        p = self.p
        is_border = (idx == 0) or (idx == num - 1)
        pad_near = p.PAD if (is_border and idx == 0) else 0
        pad_far = p.PAD if (is_border and idx == num - 1) else 0
        active_len = (p.BUF_SIZE - step + p.PAD) if is_border else p.BUF_SIZE
        real_buf_start = step if pad_far == p.PAD else 0
        return pad_near, pad_far, active_len, real_buf_start

    def _real_image_index(self, anchor: int, output_pos: int,
                           pad_near: int, real_buf_start: int) -> int:
        """RTL: buf_row/col = real_buf_start + output_pos - pad_near;
        real_image_index = anchor + buf_row/col. Only meaningful when not in_pad."""
        buf_pos = real_buf_start + output_pos - pad_near
        return anchor + buf_pos

    def _pixel_at(self, real_row: int, real_col: int) -> int:
        """Look the real (unpadded-image-space) coordinate up in the padded array."""
        p = self.p
        assert 0 <= real_row < p.IMG_ROWS_FULL, f"real_row {real_row} out of bounds"
        assert 0 <= real_col < p.IMG_COLS_FULL, f"real_col {real_col} out of bounds"
        return int(self.padded_image[real_row + p.PAD, real_col + p.PAD])

    # ---- one (sweep, win) tile: all its FETCH cycles ----

    def _tile_cycles(self, sweep_idx: int, win_idx: int) -> Iterator[FetchCycle]:
        p = self.p

        pad_top, pad_bot, active_rows, real_buf_row_start = self._axis_mode(
            sweep_idx, p.NUM_SWEEPS, p.ROW_STEP)
        pad_left, pad_right, active_cols, real_buf_col_start = self._axis_mode(
            win_idx, p.NUM_H_WIN, p.COL_STEP)

        conv_slides_row = active_rows - p.CONV_K + 1
        conv_slides_col = active_cols - p.CONV_K + 1

        row_anchor = sweep_idx * p.ROW_STEP
        col_anchor = win_idx * p.COL_STEP

        is_last_tile = (sweep_idx == p.NUM_SWEEPS - 1) and (win_idx == p.NUM_H_WIN - 1)

        for conv_row in range(conv_slides_row):
            conv_col = 0
            while True:
                windows = np.zeros((p.WIN_GROUP, p.CONV_K, p.CONV_K), dtype=self.padded_image.dtype)
                valid_mask = np.zeros(p.WIN_GROUP, dtype=bool)

                for g in range(p.WIN_GROUP):
                    out_col_lane = conv_col + g
                    lane_valid = out_col_lane < conv_slides_col
                    valid_mask[g] = lane_valid

                    for kr in range(p.CONV_K):
                        out_row = conv_row + kr
                        in_pad_row = (out_row < pad_top) or (out_row >= active_rows - pad_bot)

                        for kc in range(p.CONV_K):
                            out_col = out_col_lane + kc
                            in_pad_col = (out_col < pad_left) or (out_col >= active_cols - pad_right)
                            in_pad = in_pad_row or in_pad_col

                            if in_pad or not lane_valid:
                                windows[g, kr, kc] = 0
                            else:
                                real_row = self._real_image_index(
                                    row_anchor, out_row, pad_top, real_buf_row_start)
                                real_col = self._real_image_index(
                                    col_anchor, out_col, pad_left, real_buf_col_start)
                                windows[g, kr, kc] = self._pixel_at(real_row, real_col)

                last_group_of_row = (conv_col + p.WIN_GROUP >= conv_slides_col)
                last_row = (conv_row == conv_slides_row - 1)
                conv_done = last_group_of_row and last_row
                frame_done = conv_done and is_last_tile

                yield FetchCycle(sweep_idx, win_idx, conv_row, conv_col,
                                  windows, valid_mask, conv_done, frame_done)

                if last_group_of_row:
                    break
                conv_col += p.WIN_GROUP

    def cycles(self) -> Iterator[FetchCycle]:
        """Full-frame iterator, in exact RTL FSM order: sweep_idx outer, win_idx inner."""
        p = self.p
        for sweep_idx in range(p.NUM_SWEEPS):
            for win_idx in range(p.NUM_H_WIN):
                yield from self._tile_cycles(sweep_idx, win_idx)


# =============================================================================
# SECTION 4 -- top_pixel_source_mapper.sv, Stage-1 branch
# =============================================================================

class TopPixelSourceMapperStage1:
    """
    Bit-exact reproduction of the Stage-1 `pixels_s1[12][32][9]` generate
    block in `top_pixel_source_mapper.sv`.

    Input: the flat 100-pixel `in_mem[0:99]` array that the RTL unpacks from
    `pixel_mem_data` (`in_mem[m] = pixel_mem_data[m*PIXEL_W +: PIXEL_W]`).

    IMPORTANT bit-packing note (this is what makes `in_mem` index `m` land on
    a particular (window, kernel-row, kernel-col)):
      mapping_controller packs each lane's 5x5 window into 450 bits with
      "top-left pixel at MSB (slot 24), bottom-right at LSB (slot 0)", i.e.
      slot(r, c) = 24 - (r*5 + c) for kernel row r, col c in [0,5). Lane g
      occupies global bits [g*450 +: 450]. Since top_pixel_source_mapper
      re-slices the whole bus in 18-bit steps starting at bit 0
      (`in_mem[m] = pixel_mem_data[m*18 +: 18]`), and 450/18 == 25 exactly,
      we get an exact, non-overlapping correspondence:
          m == g*25 + s   where s = slot(r, c) = 24 - (5r + c)
      `windows_to_in_mem()` below performs exactly that repacking.
    """

    def __init__(self, params: TopPixelMapperParams):
        self.p = params

    @staticmethod
    def windows_to_in_mem(windows: np.ndarray, conv_k: int = 5) -> np.ndarray:
        """
        windows: shape (N_WINDOWS, CONV_K, CONV_K) -- one FETCH cycle's pixel
                 data, in natural (window, row, col) order.
        returns: shape (N_WINDOWS * CONV_K * CONV_K,) flat in_mem[] order,
                 matching the RTL's slot packing exactly.
        """
        n_windows = windows.shape[0]
        in_mem = np.zeros(n_windows * conv_k * conv_k, dtype=windows.dtype)
        for g in range(n_windows):
            for r in range(conv_k):
                for c in range(conv_k):
                    slot = (conv_k * conv_k - 1) - (r * conv_k + c)  # RTL: 24 - (r*5+c)
                    in_mem[g * (conv_k * conv_k) + slot] = windows[g, r, c]
        return in_mem

    def map(self, in_mem: np.ndarray) -> np.ndarray:
        """
        in_mem: shape (100,) flat pixel array (see windows_to_in_mem).
        returns: pixels_mapped, shape (12, 32, 9), matching
                 pixels_s1[gp1][cp1][tp1] in the RTL exactly.
        """
        p = self.p
        out = np.zeros((p.N_GROUPS, p.N_CHAN, p.N_TAPS), dtype=in_mem.dtype)

        for gp1 in range(p.N_GROUPS):
            window = gp1 // 3          # RTL: WINDOW = gp1 / 3
            block_g = gp1 % 3          # RTL: BLOCK_G = gp1 % 3
            win_offset = window * 25   # RTL: WIN_OFFSET = WINDOW * 25

            for cp1 in range(p.N_CHAN):
                # RTL: GLOBAL_CH channel-rotation (identical to stage1_stream_index
                # used elsewhere in the design, applied here per BLOCK_G triplet slot)
                if block_g == 0:
                    global_ch = (block_g * 32) + cp1
                elif block_g == 1:
                    if cp1 < 30:
                        global_ch = (block_g * 32) + (cp1 + 1)
                    elif cp1 == 30:
                        global_ch = (block_g * 32) + 0
                    else:  # cp1 == 31
                        global_ch = (block_g * 32) + 31
                else:  # block_g == 2
                    if cp1 < 30:
                        global_ch = (block_g * 32) + (cp1 + 2)
                    else:
                        global_ch = (block_g * 32) + (cp1 - 30)

                block = global_ch % 3         # RTL: BLOCK = GLOBAL_CH % 3
                tap_offset = block * 9        # RTL: TAP_OFFSET = BLOCK * 9

                for tp1 in range(p.N_TAPS):
                    if block == 2 and tp1 >= 7:
                        out[gp1, cp1, tp1] = 0   # RTL: 2 zero-padded MACs (27->25 CONV25 trick)
                    else:
                        in_idx = win_offset + tap_offset + tp1  # RTL: IN_IDX
                        out[gp1, cp1, tp1] = in_mem[in_idx]

        return out


# =============================================================================
# SECTION 5 -- Top-level driver: full pipeline, one cycle at a time
# =============================================================================

class Stage1CycleResult(NamedTuple):
    sweep_idx: int
    win_idx: int
    conv_row: int
    conv_col: int
    valid_mask: np.ndarray          # (WIN_GROUP,) bool -- which of the 4 windows are real
    pixels_mapped: np.ndarray       # (12, 32, 9) -- ready to drive top_conv9_array
    conv_done: bool
    frame_done: bool


def generate_stage1_pixels_mapped(
    padded_image: np.ndarray,
    mc_params: MappingControllerParams = MappingControllerParams(),
    mapper_params: TopPixelMapperParams = TopPixelMapperParams(),
) -> Iterator[Stage1CycleResult]:
    """
    Full Stage-1 pipeline: mapping_controller -> top_pixel_source_mapper,
    yielded one FETCH cycle (i.e. one `pixels_mapped` tensor) at a time.

    This is a generator (not a list) because a full 256x256 frame produces
    tens of thousands of cycles; consume it lazily (e.g. feed one cycle per
    clock to a cocotb/UVM testbench) rather than materializing all of them.
    """
    assert mc_params.WIN_GROUP == mapper_params.N_WINDOWS, \
        "MappingControllerParams.WIN_GROUP must equal TopPixelMapperParams.N_WINDOWS"

    mc = MappingControllerModel(padded_image, mc_params)
    mapper = TopPixelSourceMapperStage1(mapper_params)

    for fc in mc.cycles():
        in_mem = TopPixelSourceMapperStage1.windows_to_in_mem(fc.windows, mc_params.CONV_K)
        pixels_mapped = mapper.map(in_mem)
        yield Stage1CycleResult(
            sweep_idx=fc.sweep_idx,
            win_idx=fc.win_idx,
            conv_row=fc.conv_row,
            conv_col=fc.conv_col,
            valid_mask=fc.valid_mask,
            pixels_mapped=pixels_mapped,
            conv_done=fc.conv_done,
            frame_done=fc.frame_done,
        )


# =============================================================================
# SECTION 6 -- Output helpers (for driving RTL simulation)
# =============================================================================

def dump_cycle_hex(pixels_mapped: np.ndarray, path: str, pixel_w: int = 18) -> None:
    """
    Write one cycle's pixels_mapped[12][32][9] tensor as one hex value per
    line, in [gp1][cp1][tp1] nesting order (gp1 outermost, tp1 innermost) --
    the same order the RTL's generate-block indices iterate in. Negative
    values are written as PIXEL_W-bit two's-complement hex, suitable for
    `$readmemh`.
    """
    mask = (1 << pixel_w) - 1
    hex_width = (pixel_w + 3) // 4
    with open(path, "w") as f:
        for gp1 in range(pixels_mapped.shape[0]):
            for cp1 in range(pixels_mapped.shape[1]):
                for tp1 in range(pixels_mapped.shape[2]):
                    val = int(pixels_mapped[gp1, cp1, tp1]) & mask
                    f.write(f"{val:0{hex_width}x}\n")


def dump_cycle_npy(pixels_mapped: np.ndarray, path: str) -> None:
    """Write one cycle's pixels_mapped tensor as a .npy file (shape (12,32,9))."""
    np.save(path, pixels_mapped)


def _flatten_pixels_mapped(pixels_mapped: np.ndarray) -> np.ndarray:
    return np.asarray(pixels_mapped, dtype=np.int32).ravel()


def dump_cycles_txt(cycles: Iterator[Stage1CycleResult], path: str, pixel_w: int = 18) -> int:
    """
    Write every generated cycle into one human-readable text file.

    Each cycle is emitted as a small header line followed by one flat data line
    containing all mapped pixel values in [gp1][cp1][tp1] order.
    """
    mask = (1 << pixel_w) - 1
    hex_width = (pixel_w + 3) // 4
    count = 0
    with open(path, "w", encoding="utf-8") as f:
        for cyc in cycles:
            valid_mask = "".join("1" if flag else "0" for flag in cyc.valid_mask)
            f.write(
                f"# cycle={count} sweep={cyc.sweep_idx} win={cyc.win_idx} "
                f"row={cyc.conv_row} col={cyc.conv_col} valid={valid_mask} "
                f"conv_done={int(cyc.conv_done)} frame_done={int(cyc.frame_done)}\n"
            )
            flat = _flatten_pixels_mapped(cyc.pixels_mapped)
            f.write(" ".join(f"{int(val) & mask:0{hex_width}x}" for val in flat))
            f.write("\n")
            count += 1
    return count


def dump_cycles_bin(cycles: Iterator[Stage1CycleResult], path: str, pixel_w: int = 18) -> int:
    """
    Write every generated cycle into one compact binary file.

    File layout:
      - ASCII magic: b'STAGE1PX\n'
      - uint32 header: rows, cols, groups, channels, taps, pixel_w
      - repeated cycle records:
          uint32 sweep_idx, win_idx, conv_row, conv_col
          uint8  valid_mask_bits
          uint8  conv_done
          uint8  frame_done
          uint8  reserved
          int32  flattened pixels_mapped values
    """
    count = 0
    with open(path, "wb") as f:
        f.write(b"STAGE1PX\n")
        f.write(struct.pack("<6I", 12, 32, 9, 12, 32, pixel_w))
        for cyc in cycles:
            valid_mask_bits = 0
            for idx, flag in enumerate(cyc.valid_mask):
                if flag:
                    valid_mask_bits |= (1 << idx)

            f.write(struct.pack(
                "<4IBBBx",
                cyc.sweep_idx,
                cyc.win_idx,
                cyc.conv_row,
                cyc.conv_col,
                valid_mask_bits,
                int(cyc.conv_done),
                int(cyc.frame_done),
            ))
            _flatten_pixels_mapped(cyc.pixels_mapped).astype(np.int32).tofile(f)
            count += 1
    return count


# =============================================================================
# SECTION 7 -- CLI
# =============================================================================

def _build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="Reproduce the MultiStage-DeepSNN Stage-1 pixel mapping "
                    "(mapping_controller + top_pixel_source_mapper) in Python."
    )
    ap.add_argument("image_txt", nargs="?", default=None,
                     help="Path to the input frame dump (text or raw binary; "
                          "auto-detected). If omitted, you will be prompted "
                          "for it interactively.")
    ap.add_argument("--rows", type=int, default=256)
    ap.add_argument("--cols", type=int, default=256)
    ap.add_argument("--dtype", default=None,
                     help="numpy dtype to interpret a raw BINARY dump as "
                          "(e.g. uint8, int16, float32). Ignored for text "
                          "files. Default: auto-detect from file size.")
    ap.add_argument("--fixed-point-scale", type=float, default=None,
                     help="Multiply every loaded pixel by this before "
                          "mapping (e.g. 512 to quantize normalized floats "
                          "into the accelerator's Q8.9 format). Default: "
                          "use the FIXED_POINT_SCALE variable at the top of "
                          "this file (1 = no scaling).")
    ap.add_argument("--pad", type=int, default=2, help="Zero-pad width per border side.")
    ap.add_argument("--output-file", default="stage1_cycles.txt",
                     help="Single file to write all mapped cycles into.")
    ap.add_argument("--output-format", choices=["txt", "bin"], default="txt",
                     help="Output file format for the single aggregated output file.")
    ap.add_argument("--max-cycles", type=int, default=10,
                     help="Number of FETCH cycles to dump (a full frame is "
                          "tens of thousands of cycles -- default only dumps "
                          "the first few for a quick sanity check; pass -1 "
                          "for the entire frame).")
    return ap


def _resolve_image_path(args) -> str:
    """
    Resolve the image file path, in priority order:
      1. Command-line argument   (python rtl_mapping_model.py my_file.txt)
      2. The IMAGE_PATH variable set at the top of this file
      3. An interactive prompt, if neither of the above was given
    """
    path = args.image_txt or IMAGE_PATH
    if path is None:
        path = input("Path to the grayscale text image: ").strip().strip('"').strip("'")
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"No such file: '{path}'")
    return path


def main():
    args = _build_arg_parser().parse_args()
    image_path = _resolve_image_path(args)

    dtype = args.dtype or IMAGE_DTYPE
    scale = args.fixed_point_scale if args.fixed_point_scale is not None else FIXED_POINT_SCALE

    img = load_image(image_path, rows=args.rows, cols=args.cols, dtype=dtype)

    # Apply the fixed-point scale (no-op when scale == 1), then round and
    # cast to a signed integer type -- everything downstream (padding,
    # windowing, the RTL index arithmetic) is written assuming integer
    # pixel/PIXEL_W-format values, exactly like the RTL's 18-bit signed bus.
    if scale != 1:
        img = np.round(img.astype(np.float64) * scale)
    img = img.astype(np.int32)

    padded = zero_pad_image(img, pad=args.pad)

    mc_params = MappingControllerParams(
        IMG_ROWS_FULL=args.rows, IMG_COLS_FULL=args.cols, PAD=args.pad
    )
    mapper_params = TopPixelMapperParams()

    count = 0
    source_cycles = generate_stage1_pixels_mapped(padded, mc_params, mapper_params)
    if args.max_cycles >= 0:
        def limited_cycles() -> Iterator[Stage1CycleResult]:
            nonlocal count
            for cyc in source_cycles:
                if count >= args.max_cycles:
                    break
                count += 1
                yield cyc

        cycles = limited_cycles()
    else:
        cycles = source_cycles
    if args.output_format == "txt":
        count = dump_cycles_txt(cycles, args.output_file)
    else:
        count = dump_cycles_bin(cycles, args.output_file)

    print(f"Wrote {count} cycle(s) to '{args.output_file}' (format={args.output_format}). "
          f"Use --max-cycles -1 for the full frame.")


if __name__ == "__main__":
    try:
        main()
    except (FileNotFoundError, ValueError) as e:
        raise SystemExit(f"Error: {e}")
