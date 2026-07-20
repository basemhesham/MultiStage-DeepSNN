# CNN Hardware Weight Files — SystemVerilog Parameters

This repository contains pre-trained weights and biases for a **3-layer Convolutional Neural Network (CNN)** implemented in hardware (FPGA/ASIC), expressed as synthesizable SystemVerilog (`.sv`) parameter files. The network follows a standard CNN architecture: three convolutional layers with batch normalization, followed by two fully connected layers.

All weights are stored as **18-bit signed fixed-point** binary values (`logic signed [17:0]`).

---

## Network Architecture Overview

```
Input
  └─► CONV1 (32 filters)  ──► BN1 ──► CONV2 (64 filters)  ──► BN2 ──► CONV3 (128 filters)  ──► BN3
                                                                                                     │
                                                                                              FC1 (256 neurons)
                                                                                                     │
                                                                                              FC2 (4 outputs)
```

---

## File Descriptions

### Convolutional Layer Weights

Each convolutional layer uses a **weight-sharing / LUT optimization** strategy to reduce hardware resource usage. Weights are split into two components: a unique values table and an optimized mapping module.

#### CONV1

| File | Description |
|------|-------------|
| `UNIQUE_CONV1_WEIGHTS.sv` | SystemVerilog package (`conv1_pkg`) containing **264 unique 18-bit signed weight values** used across all CONV1 filters. Acts as a lookup table (LUT) to avoid storing duplicate weights. |
| `CONV1_W_MAP_OPT.sv` | Optimized mapping module that instantiates the `conv1_pkg` package. Maps **3,456 weight slots** (`conv9_in[3456]`) to entries in `UNIQUE_CONV1_WEIGHTS` by index. Some slots are tied to zero (`18'b000000000000000000`). This module has no filter-select input — it outputs the full static weight array for the layer. |

#### CONV2

| File | Description |
|------|-------------|
| `UNIQUE_CONV2_WEIGHTS.sv` | SystemVerilog package (`conv2_pkg`) containing **362 unique 18-bit signed weight values** for CONV2. |
| `CONV2_W_MAP_OPT.sv` | Mapping module with a **6-bit `filter` input** (selects among 64 filters) and a **3,456-entry output array**. Dynamically routes unique weights to the correct positions based on the selected filter index. |

#### CONV3

| File | Description |
|------|-------------|
| `UNIQUE_CONV3_WEIGHTS.sv` | SystemVerilog package (`conv3_pkg`) containing **318 unique 18-bit signed weight values** for CONV3. |
| `CONV3_W_MAP_OPT.sv` | Mapping module with a **7-bit `filter` input** (selects among 128 filters) and a **3,456-entry output array**. Uses the `conv3_pkg` package for weight lookups. |

---

### Batch Normalization Parameters

Each convolutional layer is followed by a batch normalization (BN) layer. Each BN layer stores two arrays: learned scale weights (γ) and bias offsets (β), one entry per filter channel.

| File | Parameters | Num Entries | Description |
|------|-----------|-------------|-------------|
| `BN1_WEIGHTS.sv` | `BN1_WEIGHTS` | 32 | Scale (γ) parameters for Batch Norm after CONV1. All values are positive (near-zero scale factors). |
| `BN1_BIAS.sv` | `BN1_BIAS` | 32 | Bias (β) parameters for Batch Norm after CONV1. Mix of positive and negative (two's complement) values. |
| `BN2_WEIGHTS.sv` | `BN2_WEIGHTS` | 64 | Scale (γ) parameters for Batch Norm after CONV2. |
| `BN2_BIAS.sv` | `BN2_BIAS` (named `BN2_WEIGHTS` internally) | 64 | Bias (β) parameters for Batch Norm after CONV2. |
| `BN3_WEIGHTS.sv` | `BN3_WEIGHTS` | 128 | Scale (γ) parameters for Batch Norm after CONV3. |
| `BN3_BIAS.sv` | `BN3_BIAS` | 128 | Bias (β) parameters for Batch Norm after CONV3. |

---

### Fully Connected Layer Weights

| File | Array Dimensions | Description |
|------|-----------------|-------------|
| `FC1_WEIGHTS.sv` | `[256][128]` | Weight matrix for the first fully connected layer. Maps 128 input features to 256 neurons. Total: 32,768 weight values. |
| `FC1_BIAS.sv` | `[256]` | Bias vector for FC1. One bias per neuron (256 values). |
| `FC2_WEIGHTS.sv` | `[4][256]` | Weight matrix for the second (output) fully connected layer. Maps 256 neurons to 4 output classes. Total: 1,024 weight values. |
| `FC2_BIAS.sv` | `[4]` | Bias vector for FC2. One bias per output class (4 values), indicating a **4-class classification** network. |

---

## Data Format

All parameters use **18-bit signed fixed-point** representation in two's complement:

```systemverilog
localparam logic signed [17:0] PARAM_NAME [SIZE] = '{ ... };
```

- The MSB (`bit[17]`) is the sign bit.
- Values starting with `18'b000000...` are positive.
- Values starting with `18'b111111...` are negative (two's complement).
- The exact fixed-point scaling (Q-format) depends on the training quantization scheme used.

---

## File Size Summary

| File | Size | Notes |
|------|------|-------|
| `CONV3_W_MAP_OPT.sv` | ~18 MB | Largest file; 128 filters × 3,456 assignments |
| `CONV2_W_MAP_OPT.sv` | ~11 MB | 64 filters × 3,456 assignments |
| `FC1_WEIGHTS.sv` | ~932 KB | 256 × 128 weight matrix |
| `CONV1_W_MAP_OPT.sv` | ~172 KB | Static (no filter select input) |
| `FC2_WEIGHTS.sv` | ~32 KB | 4 × 256 weight matrix |
| `UNIQUE_CONV2_WEIGHTS.sv` | ~12 KB | 362 unique values |
| `UNIQUE_CONV1_WEIGHTS.sv` | ~8 KB | 264 unique values |
| `UNIQUE_CONV3_WEIGHTS.sv` | ~8 KB | 318 unique values |
| `FC1_BIAS.sv` | ~8 KB | 256 bias values |
| `FC2_WEIGHTS.sv` | ~32 KB | — |
| BN + FC2_BIAS files | ~4 KB each | Small parameter arrays |

---

## Usage

1. Include the package files before instantiating the mapping modules:
   ```systemverilog
   `include "UNIQUE_CONV1_WEIGHTS.sv"  // or use package import
   import conv1_pkg::*;
   ```

2. Instantiate the weight mapping modules in your datapath:
   ```systemverilog
   CONV1_W_MAP_OPT u_conv1_weights (
       .conv9_in(conv1_weight_bus)
   );

   CONV2_W_MAP_OPT u_conv2_weights (
       .filter(current_filter_idx),  // 6-bit filter select
       .conv9_in(conv2_weight_bus)
   );
   ```

3. Reference BN and FC parameters directly as `localparam` constants in your compute modules.

---

## Notes

- The network outputs **4 classes**, as evidenced by `FC2_BIAS` and `FC2_WEIGHTS` having 4 entries/rows.
- The LUT-based weight optimization (UNIQUE + MAP pattern) reduces FPGA/ASIC area by storing only distinct weight values and using multiplexers for selection, rather than storing all weights redundantly.
- `BN2_BIAS.sv` internally names its array `BN2_WEIGHTS` — this appears to be a copy-paste artifact in the source; the file contains bias (β) values based on its mixed positive/negative distribution.
