# Hardware Weight Implementation Guide

> A complete pipeline for extracting, optimizing, and formatting neural network weights for hardware implementation in SystemVerilog.

---

## Table of Contents

- [Overview](#overview)
- [1. Data Extraction & Formatting](#1-data-extraction--formatting)
- [2. Hardware Optimization (LUT Mapping)](#2-hardware-optimization-lut-mapping)
- [3. File Inventory](#3-file-inventory)
- [4. Usage](#4-usage)

---

## Overview

This guide documents the end-to-end process for preparing trained neural network weights for FPGA/ASIC deployment. The pipeline handles bit-level data extraction, deduplication via Look-Up Tables (LUTs), and generates ready-to-use SystemVerilog parameter files.

---

## 1. Data Extraction & Formatting

| Property | Detail |
|---|---|
| **Source** | Binary files with packed 18-bit signed elements (non-byte-aligned) |
| **Parsing** | Custom Python streams for bit-level extraction — no padding artifacts |
| **SV Format** | `localparam logic signed [17:0]` arrays using 18-bit binary literals |

Weights are stored as 18-bit signed fixed-point values and formatted as `localparam logic signed [17:0]` arrays using binary literals, ready to be consumed directly by SystemVerilog toolchains.

---

## 2. Hardware Optimization (LUT Mapping)

To minimize hardware area, unique weight values are extracted per layer and addressed through Look-Up Tables instead of storing redundant copies. A deduplication script scans each generated `.sv` file, counts total versus unique 18-bit weight literals, and reports the reduction percentage achieved per layer.

| Layer  | Total  | Unique | Reduction |
|--------|--------|--------|-----------|
| CONV1  | 800    | 264    | 67%       |
| CONV2  | 18432  | 362    | 98.0%     |
| CONV3  | 73728  | 318    | 99.6%     |
| BN1_W  | 32     | 32     | 0.0%      |
| BN1_B  | 32     | 32     | 0.0%      |
| BN2_W  | 64     | 61     | 4.7%      |
| BN2_B  | 64     | 58     | 9.375%    |
| BN3_W  | 128    | 89     | 30.5%     |
| BN3_B  | 128    | 96     | 25.0%     |
| FC1_W  | 32768  | 375    | 98.9%     |
| FC1_B  | 256    | 79     | 69.1%     |
| FC2_W  | 1024   | 387    | 62.2%     |
| FC2_B  | 4      | 4      | 0.0%      |

> The reduction percentage indicates how much ROM/LUT area is saved compared to storing weights naively.

---

## 3. File Inventory

For each layer, three files are generated:

| File | Description |
|---|---|
| `UNIQUE_[LAYER].sv` | SystemVerilog LUT array of sorted unique weight values |
| `INDEX_MAP_FLAT_[LAYER].txt` | Maps flat weight indices → LUT indices |
| `INDEX_MAP_COORDS_[LAYER].txt` | Maps coordinates (e.g., `[Filter][Depth][Element]`) → LUT indices |

### Supported Layers

| Group | Weights File | Bias File |
|---|---|---|
| CONV1 | `CONV1_WEIGHTS.sv` | — |
| CONV2 | `CONV2_WEIGHTS.sv` | — |
| CONV3 | `CONV3_WEIGHTS.sv` | — |
| BN1 | `BN1_WEIGHTS.sv` | `BN1_BIAS.sv` |
| BN2 | `BN2_WEIGHTS.sv` | `BN2_BIAS.sv` |
| BN3 | `BN3_WEIGHTS.sv` | `BN3_BIAS.sv` |
| FC1 | `FC1_WEIGHTS.sv` | `FC1_BIAS.sv` |
| FC2 | `FC2_WEIGHTS.sv` | `FC2_BIAS.sv` |

---

## 4. Usage

**Step 1 — Instantiate the LUT**

Use the `UNIQUE_[LAYER].sv` file to declare a read-only parameter array in your module. Your hardware address generator then indexes into this array to retrieve the correct weight value at runtime.

**Step 2 — Verify the Address Generator**

Cross-reference your hardware address generator against the index map files to confirm correctness before synthesis:

- **`INDEX_MAP_FLAT_[LAYER].txt`** — use for linear or sequential address schemes.
- **`INDEX_MAP_COORDS_[LAYER].txt`** — use when addressing by `[Filter][Depth][Element]` coordinates, which is typical in convolution control logic.

Ensure that for every weight access, the generated LUT index matches the mapping file entry exactly before taping out or loading to FPGA.

---

## Notes

- All weights are 18-bit signed fixed-point values (`signed [17:0]`).
- The coordinate format in `INDEX_MAP_COORDS` files follows `[Filter][Depth][Element]` ordering — adjust your address decoder accordingly if your layer uses a different memory layout.
- LUT-based addressing is particularly effective for convolutional layers where filter weights repeat across spatial positions.
