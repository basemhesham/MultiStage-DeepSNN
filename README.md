# MultiStage-DeepSNN — FPGA Hardware Accelerator

<div align="center">

![Platform](https://img.shields.io/badge/Platform-Xilinx%20Virtex%20UltraScale%2B%20XCVU11P-blue)
![Language](https://img.shields.io/badge/RTL-SystemVerilog%20%2F%20Verilog-orange)
![Fixed‑Point](https://img.shields.io/badge/Fixed--Point-18--bit%20Q7.10-green)
![Clock](https://img.shields.io/badge/Clock-40%20MHz-lightgrey)
![DSP Utilisation](https://img.shields.io/badge/DSP%20Utilisation-87.9%25-yellow)

</div>

---

## Abstract

**MultiStage-DeepSNN** is a fully-pipelined FPGA hardware accelerator for a three-stage **Spiking Neural Network (SNN)** that classifies driving incidents from dashcam video in real time. The network processes 16 temporal frames of 256 × 256 grayscale video and outputs one of four event labels.

The central hardware innovation is a **shared, time-multiplexed circuit** — rather than instantiating separate convolution, accumulation, and neuron units for each of the three network stages, a single pool of DSP48E2 resources is reused across all stages via a 2-bit control signal (`src_sel`). Combined with a **depth-first (z-domain) streaming** strategy derived from backtracking analysis, the design achieves deep pipeline parallelism while minimising on-chip memory for intermediate feature maps.

---

## Table of Contents

1. [SNN Design Overview](#1-snn-design-overview)
2. [Target FPGA — Xilinx Virtex UltraScale+ XCVU11P](#2-target-fpga--xilinx-virtex-ultrascale-xcvu11p)
3. [Backtracking: Input Window Derivation](#3-backtracking-input-window-derivation)
4. [Top-Level Shared Circuit Architecture](#4-top-level-shared-circuit-architecture)
   - [4.1 conv9 — The Universal Building Block](#41-conv9--the-universal-building-block)
   - [4.2 The 12-Block Convolution Array](#42-the-12-block-convolution-array)
   - [4.3 The Adder Tree — Dual-Purpose Accumulation](#43-the-adder-tree--dual-purpose-accumulation)
   - [4.4 CONV25 from the Adder Tree Layer-1 Taps](#44-conv25-from-the-adder-tree-layer-1-taps)
   - [4.5 The Orphan Correction Layer (`ext_sum_correction`)](#45-the-orphan-correction-layer-ext_sum_correction)
   - [4.6 Assembling 128 Inputs for 32 Shaaban Units (`flat_s1`)](#46-assembling-128-inputs-for-32-shaaban-units-flat_s1)
   - [4.7 Stage Routing via `src_sel`](#47-stage-routing-via-src_sel)
   - [4.8 The 32 Shaaban Units](#48-the-32-shaaban-units)
5. [Stage 1 — 5 × 5 Convolution Architecture](#5-stage-1--5--5-convolution-architecture)
6. [Stage 2 — 3 × 3 Convolution, 32 Input Channels](#6-stage-2--3--3-convolution-32-input-channels)
7. [Stage 3 — 3 × 3 Convolution, 64 Input Channels](#7-stage-3--3--3-convolution-64-input-channels)
8. [Memory Control & Frame Mapping](#8-memory-control--frame-mapping)
9. [Classifier Head — GAP, FC1, FC2](#9-classifier-head--gap-fc1-fc2)
10. [Full Resource Summary](#10-full-resource-summary)

---

## 1. SNN Design Overview

### 1.1 Project Goal

**MultiStage-DeepSNN** implements a fully trained Spiking Neural Network on an FPGA and classifies four driving-event categories from a short dashcam clip:

| Label | Class | Description |
|:-----:|-------|-------------|
| `0` | `negative_samples` | No incident detected |
| `1` | `drifting_or_skidding` | Risky manoeuvre, no impact |
| `2` | `other_crash` | Crash detected — ego vehicle not involved |
| `3` | `collision` | Crash — ego vehicle directly involved |

---

### 1.2 Network Architecture

The network is a **three-stage spiking convolutional network** operating over **T = 16 temporal frames**. Each frame is a **256 × 256 grayscale image**.

```
Input (B, T, 256, 256, 1)
        │
        ▼  Permute to (B, T, C, H, W)
  ┌─────────────────────────────────────────────────┐
  │           Temporal Loop  t = 0 → T−1            │
  │                                                 │
  │   Stage 1 ── Conv 5×5 (32 filters)              │
  │              BN + MaxPool 2×2                   │
  │              LIF 1  → spikes                    │
  │                  │                              │
  │   Stage 2 ── Conv 3×3 (64 filters)              │
  │              BN + MaxPool 2×2                   │
  │              LIF 2  → spikes                    │
  │                  │                              │
  │   Stage 3 ── Conv 3×3 (128 filters)             │
  │              BN + MaxPool 2×2                   │
  │              LIF 3  → spikes                    │
  └─────────────────────────────────────────────────┘
        │  Record spikes over all T frames
        ▼
  Global Average Pool (AdaptiveAvgPool 1×1)
        │
  FC1: 128 → 256  +  ReLU  +  Dropout
        │
  FC2: 256 → 4
        │
  Class Logits (0–3)
```

<div align="center">
<img width="2000" height="564" alt="Network Architecture" src="https://github.com/user-attachments/assets/9d2d1e2a-42d9-4687-b119-73937a786371" />
</div>

Each of the three convolutional blocks follows the same pattern:

> **Conv → BatchNorm → MaxPool 2×2 → LIF neuron**

**Leaky Integrate-and-Fire (LIF) neurons** accumulate membrane potential across all T timesteps. At each step the membrane decays by factor β (β = 0.9 in PyTorch training; β = 0.5 in RTL using an arithmetic right-shift). A spike fires when the membrane potential reaches or exceeds the threshold.

---

### 1.3 Stage Specifications

| Stage | Conv Kernel | Input Channels | Output Channels | Input Spatial | After Conv | After MaxPool |
|:-----:|:-----------:|:--------------:|:---------------:|:-------------:|:----------:|:-------------:|
| 1 | 5 × 5 | 1 | 32 | 256 × 256 | 20 × 20 | 10 × 10 |
| 2 | 3 × 3 | 32 | 64 | 10 × 10 | 8 × 8 | 4 × 4 |
| 3 | 3 × 3 | 64 | 128 | 4 × 4 | 2 × 2 | 1 × 1 |

> **Note:** Spatial dimensions correspond to one 24 × 24 crop processed via the backtracking approach (Section 3). The hardware does not process full 256 × 256 feature maps at once.

---

### 1.4 Design Philosophy

Rather than generating full spatial feature maps for every stage and buffering them between stages — which would introduce massive memory requirements and pipeline stalls — this design uses a **z-domain (depth-first) processing** strategy derived from backtracking analysis. The hardware generates only the data that each downstream stage immediately needs, allowing all three stages to operate concurrently on different parts of the same input.

Key benefits of this approach:
- Eliminates the need to fully compute and store each stage's complete output before the next stage begins.
- Enables deep **pipeline parallelism** by exploiting pre-known filter weights (stored as constants) to process in the depth (z) dimension rather than waiting for the full spatial (x) dimension to complete.
- Minimises on-chip memory usage for intermediate feature maps.

---

## 2. Target FPGA — Xilinx Virtex UltraScale+ XCVU11P

The design targets the **Xilinx Virtex UltraScale+ XCVU11P** in the `flga2577-3-e` package — the highest-capacity family of UltraScale+ FPGAs, providing the resources necessary to instantiate hundreds of parallel convolution units and their associated accumulation logic.

### 2.1 Device Resources

| Resource | XCVU11P |
|----------|:-------:|
| DSP48E2 Slices | **9,216 total / 4,638 project budget** |
| Block RAM Tiles (36 Kb each) | **2,016** |
| Block RAM Total Capacity | **70.9 Mb** |
| UltraRAM Blocks (288 Kb each) | **640** |
| UltraRAM Total Capacity | **180 Mb** |
| CLB LUTs | **2,586,240** |
| CLB Registers (Flip-Flops) | **5,172,480** |
| Package | flga2577 (2,577-pin FCBGA) |
| Speed Grade | −3 (fastest commercial) |

---

### 2.2 Why This Device

The **DSP48E2 slice** is the central resource in this design. Virtually all multiply-accumulate and addition operations are mapped onto DSP48E2 primitives using their native capabilities:

| DSP48E2 Feature | Benefit |
|-----------------|---------|
| **Multiplier port** | 27 × 18-bit signed multiply in a single slice |
| **Pre-adder port (D)** | Adds a third input before the multiplier — true 3-input adder in one DSP and one pipeline stage |
| **Cascade bus** | Chains DSP slice outputs directly to adjacent slices without routing fabric, forming efficient cascaded MAC chains |

The device contains 9,216 DSP48E2 slices. The project budget allows the accelerator to use up to 4,638 DSP48E2 slices, providing sufficient headroom for Stage 1 (the most demanding stage), which consumes **4,000 DSPs — 98.1% of the allowed budget**.

<div align="center">
<img width="689" height="443" alt="DSP Resource Usage" src="https://github.com/user-attachments/assets/b76843a0-f010-40c9-b490-559f95578cb0" />
</div>

---

### 2.3 Operating Parameters

| Parameter | Value |
|-----------|:-----:|
| Target clock frequency | **40 MHz** |
| Fixed-point format | **18-bit signed, Q7.10** |
| Scale factor | 2¹⁰ = 1,024 |
| Representable range | −128.000 to +127.999 |

---

## 3. Backtracking: Input Window Derivation

### 3.1 Concept

Standard neural network inference processes the entire input image through each stage in sequence, storing the full feature map of each stage before advancing to the next. This is inefficient in hardware because it requires large memories to hold intermediate results and forces pipeline stages to stall while waiting for predecessors.

The **backtracking approach** solves this by working backwards from the desired output through every layer to determine the *smallest input window* that produces exactly one output element at the final stage. The hardware then tiles this minimum window across the image, enabling all three stages to work simultaneously in a streaming fashion.

<div align="center">
<img width="511" height="362" alt="Backtracking diagram" src="https://github.com/user-attachments/assets/6da5f8c4-45ac-4046-8464-998e2c8c85dc" />
</div>

---

### 3.2 Stage 3 — Final Output Dependency

To produce **one LIF output element** from Stage 3:
- The **LIF and BN/MaxPool block** requires a **2 × 2 spatial window** (MaxPool 2 × 2 with stride 2 reduces 2 × 2 → 1 × 1).
- The **Stage 3 Convolution** (3 × 3 kernel, stride 1, no padding) must therefore generate these **4 elements** arranged in a 2 × 2 grid.

---

### 3.3 Stage 2 — Receptive Field Scaling

Using the relation `output_size = n − f + 1` (where n = input size, f = filter size):

```
Stage 3 output needed:      2 × 2
Stage 3 Conv input needed:  2 + 3 − 1 = 4 × 4
```

Therefore Stage 2 must produce a **4 × 4 × 64** patch:
- **LIF 2** outputs **4 × 4 × 64** spikes.
- **MaxPool 2** receives **8 × 8 × 64** and reduces to 4 × 4 × 64.
- **Stage 2 Convolution** (3 × 3, stride 1, no padding) must produce **8 × 8 × 64**, requiring a **10 × 10 × 32** input from Stage 1.

```
Stage 2 output needed:      8 × 8
Stage 2 Conv input needed:  8 + 3 − 1 = 10 × 10
```

---

### 3.4 Stage 1 — Input Frame Requirements

To provide Stage 2 with its required **10 × 10 × 32** input, Stage 1 must produce:
- **LIF 1** outputs **10 × 10 × 32** spikes.
- **MaxPool 1** receives **20 × 20 × 32** and reduces to 10 × 10 × 32.
- **Stage 1 Convolution** (5 × 5, stride 1, no padding) must produce **20 × 20 × 32**, requiring a **24 × 24 × 1** input.

```
Stage 1 output needed:      20 × 20
Stage 1 Conv input needed:  20 + 5 − 1 = 24 × 24
```

The full 256 × 256 input frame is zero-padded to **260 × 260** (2 pixels on each side). The hardware extracts **24 × 24 crops** from this padded image at the appropriate stride positions to produce the 4 × 4 = 16 LIF3 output positions.

---

### 3.5 Backtracking Summary

| Stage | Operation | Output Size | Required Input Size |
|:-----:|-----------|:-----------:|:-------------------:|
| 3 | LIF3 / MaxPool3 (2 × 2) | **1 × 1 × 128** | 2 × 2 × 128 |
| 3 | CONV3 (3 × 3, no pad) | 2 × 2 × 128 | **4 × 4 × 64** |
| 2 | LIF2 / MaxPool2 (2 × 2) | **4 × 4 × 64** | 8 × 8 × 64 |
| 2 | CONV2 (3 × 3, no pad) | 8 × 8 × 64 | **10 × 10 × 32** |
| 1 | LIF1 / MaxPool1 (2 × 2) | **10 × 10 × 32** | 20 × 20 × 32 |
| 1 | CONV1 (5 × 5, no pad) | 20 × 20 × 32 | **24 × 24 × 1** |
| — | Padded input crop | — | 24 × 24 from 260 × 260 |

> **Key result:** A single **24 × 24 crop** from the padded 260 × 260 input, processed through all three stages, produces exactly **one LIF3 output pixel** (across 128 channels). To fill the complete 4 × 4 × 128 LIF3 output map, 16 such crops are processed sequentially across 6 memory frames.

---

## 4. Top-Level Shared Circuit Architecture

The central hardware innovation is that **all three SNN stages share the same physical circuit**. Rather than instantiating separate convolution, accumulation, and backend units per stage — which would require three times the silicon area — a single pool of resources is time-multiplexed across Stages 1, 2, and 3 via a 2-bit control signal (`src_sel`).

### 4.1 Top-Level Data Flow

The top-level module (`deep_snn_top`) is organised into four sequential functional layers:

```
 pixels[12][32][9]                           ← 24×24 crop input (18-bit each)
 weights[12][32][9]                          ← filter weights (18-bit each)
         │
         ▼  ─────────────────────────────────────────────────────────────────
         │  Layer 1: Convolution Array
         │  12 blocks × 32 conv9 units = 384 parallel MAC units
         │  Each conv9 produces a 40-bit dot product of 9 pixels × 9 weights
         │
         ▼  mac_raw[12][32] (40-bit each) → mac_to_connect[12][32] (18-bit)
         │  ─────────────────────────────────────────────────────────────────
         │  Layer 2: Summation Engine
         │  12 × adder_tree_10_4_1_1 (one per block)
         │  Each tree:
         │    · Taps Layer-1 sums → 10 × conv25 partial results (Stage 1)
         │    · Fully accumulates all 32 inputs → 1 final sum (Stage 2/3)
         │
         ▼  tree_tap[12][10]  (Stage 1 path)
         │  tree_final[12]    (Stage 2/3 path)
         │  ─────────────────────────────────────────────────────────────────
         │  Layer 3: Routing & Connection (adder_tree_shaaban_connect)
         │  · Assembles 128 inputs for Stage 1 (120 taps + 8 corrections)
         │  · Routes 12 tree finals to 3 Shaabans for Stage 2
         │  · Routes 1 accumulated sum to Shaaban 0 for Stage 3
         │  · 3-way MUX controlled by src_sel selects active stage
         │
         ▼  shb_bus[32] — packed 4×18-bit inputs per Shaaban unit
         │  ─────────────────────────────────────────────────────────────────
         │  Layer 4: Shaaban Processing Array
         │  32 × shaban_unit_top (Bias → BN → MaxPool → LIF)
         │  All 32 are always physically present; src_sel controls how many
         │  receive valid data (32 in Stage 1 · 3 in Stage 2 · 1 in Stage 3)
         │
         ▼
  spike_out[32]                              ← 1-bit spike per Shaaban unit
```

---

### 4.1 conv9 — The Universal Building Block

The **conv9** unit (`rtl/convolution_blocks/cov9.sv`) is the fundamental computation primitive used throughout the entire accelerator. It computes the dot product of two 9-element, 18-bit signed vectors — the core operation of a single 3 × 3 convolution position.

**Internal structure:**

<div align="center">
  <img width="1200" alt="conv9 cascaded DSP48E2 MAC chain" src="./Schematics/Convolution/conv9.png" />
</div>

| Port | Width | Description |
|------|:-----:|-------------|
| `P[0:8]` | 18-bit signed | Input pixel vector |
| `Q[0:8]` | 18-bit signed | Filter weight vector |
| `Pixel_Out[39:0]` | 40-bit | Accumulated dot product |

**Structure:** 9 cascaded DSP48E2 MACs → 40-bit sum  
**Critical path:** 9 DSP delays (1 per multiplier in the cascade)

The `conv9` output feeds into the **adder tree's Layer-1 3-input adders**, where the DSP48E2 pre-adder achieves the 3-to-1 grouping efficiently.

---

### 4.2 The 12-Block Convolution Array

The convolution array (`conv9_array`) is structured as **12 blocks, each containing 32 parallel conv9 units** — **384 conv9 units total**. Each unit computes an independent 9-element dot product simultaneously.

```
  Block  0:  conv9[0][0]  …  conv9[0][31]   → mac_raw[0][0..31]
  Block  1:  conv9[1][0]  …  conv9[1][31]   → mac_raw[1][0..31]
       ...
  Block 11:  conv9[11][0] …  conv9[11][31]  → mac_raw[11][0..31]
```

Top-level port declaration:

```systemverilog
pixels  [0:11][0:31][0:8]   // 12 blocks × 32 units × 9 pixels  (18-bit each)
weights [0:11][0:31][0:8]   // 12 blocks × 32 units × 9 weights (18-bit each)
mac_raw [0:11][0:31]        // 384 raw 40-bit dot products
```

After the convolution array, each 40-bit raw output is truncated to **18-bit** (`mac_to_connect[g][c] = mac_raw[g][c][17:0]`) before entering the adder tree.

**Why 12 blocks of 32?**

- **Stage 1** requires 128 CONV25 outputs (32 Shaaban units × 4 inputs each). Each group of 3 conv9 outputs summed together produces one CONV25-equivalent result. With 30 of the 32 per block used for grouping: 12 blocks × 10 groups = 120 direct results. The remaining 8 come from the orphan correction layer (Section 4.5).
- **Stage 2** requires 12 independent channel sums (one per adder tree), each fed to a Shaaban unit as one of its 4 inputs.
- **Stage 3** requires one fully accumulated 64-channel sum (two trees' outputs added externally).

---

### 4.3 The Adder Tree — Dual-Purpose Accumulation

Each of the 12 blocks is followed by one instance of **`adder_tree_10_4_1_1`** — a 32-input reduction tree built entirely from DSP48E2 3-input adders. This tree serves two completely different purposes depending on the active stage, without any multiplexers inside the tree itself.

**Internal layer structure (verified from `adder_tree_10_4_1_1.v`):**

```
  32 inputs (in_1 … in_32)  [18-bit signed each]
        │
        │  Inputs 1–30 (30 inputs)               Inputs 31, 32 (2 "orphan" inputs)
        │                                                   │
        ▼                                                   │
  ┌─────────────────────────────────────┐                  │
  │  LAYER 1 — 10 × adder_layer1        │                  │
  │  Each: add_1 + add_2 + add_3        │                  │
  │  (A+D)+C via DSP48E2 pre-adder      │                  │
  │                                     │                  │
  │  L1_1  = in_1  + in_2  + in_3       │                  │
  │  L1_2  = in_4  + in_5  + in_6       │                  │
  │  L1_3  = in_7  + in_8  + in_9       │                  │
  │  L1_4  = in_10 + in_11 + in_12      │                  │
  │  L1_5  = in_13 + in_14 + in_15      │                  │
  │  L1_6  = in_16 + in_17 + in_18      │                  │
  │  L1_7  = in_19 + in_20 + in_21      │                  │
  │  L1_8  = in_22 + in_23 + in_24      │                  │
  │  L1_9  = in_25 + in_26 + in_27      │                  │
  │  L1_10 = in_28 + in_29 + in_30      │                  │
  │  Output width: 20-bit               │                  │
  └───────────────┬─────────────────────┘                  │
                  │  ◄──────────── STAGE 1 TAP ────────────┘
                  │  conv25_1..10 = L1_1[19:1]..L1_10[19:1]
                  │  (right-shift by 1 = ÷2 for normalisation)
                  │
        ┌─────────┴──────────────────────────────────┐
        │  LAYER 2 — 3 × adder_layer2 + 1 × DSP macro│
        │                                             │
        │  L2_1 = L1_1 + L1_2 + L1_3    (22-bit)     │
        │  L2_2 = L1_4 + L1_5 + L1_6    (22-bit)     │
        │  L2_3 = L1_7 + L1_8 + L1_9    (22-bit)     │
        │  L2_4 = L1_10 + in_31 + in_32  (21-bit)    │
        │  (L2_4 uses xbip_dsp48_macro_0 to add the  │
        │   two orphan inputs with L1_10 in one DSP) │
        └─────────┬───────────────────────────────────┘
                  │
        ┌─────────┴──────────────────────────────────┐
        │  LAYER 3 — 1 × dsp48_layer_3               │
        │  L3 = L2_1 + L2_2 + L2_3      (24-bit)     │
        └─────────┬───────────────────────────────────┘
                  │
        ┌─────────┴──────────────────────────────────┐
        │  LAYER 4 — 1 × dsp48_layer_4               │
        │  L4 = L3 + L2_4                (25-bit)    │
        │                                             │
        │  final_output = L4[24:7]       (18-bit)    │
        └─────────┬───────────────────────────────────┘
                  │  ◄──────── STAGE 2 / STAGE 3 TAP ──
                  │  final_output = full 32-input sum
```

**The two output taps serve different stages:**

| Output | Signal | Source | Used In |
|--------|--------|--------|---------|
| `conv25_1` … `conv25_10` | `L1_x[19:1]` | Layer-1 partial sums | **Stage 1** — each is a sum of 3 conv9 outputs = one conv25 result |
| `final_output` | `L4[24:7]` | Full 4-layer accumulation | **Stage 2 & 3** — sum of all 32 conv9 outputs in the block |

> No internal multiplexers are needed. The Layer-1 taps are always present as wires regardless of which stage is active. The unused tap simply produces values that no downstream unit consumes.

---

### 4.4 CONV25 from the Adder Tree Layer-1 Taps

The key insight connecting the conv9 array to CONV25 (5 × 5 convolution) is the **Layer-1 grouping** in the adder tree.

Each Layer-1 adder sums three consecutive conv9 outputs:

```
  L1_1 = conv9_out[0] + conv9_out[1] + conv9_out[2]
```

Since each `conv9_out[i]` is a 9-MAC dot product, their sum is a **27-MAC dot product**. For a 5 × 5 convolution, exactly **25 MACs** are needed. The solution is to set **2 of the 27 weight–pixel pairs to zero** when loading filter weights for Stage 1, making those 2 MACs contribute nothing:

```
  25 active MACs (P[0]×Q[0] … P[24]×Q[24]) + 2 zero MACs (P[25]×0 + P[26]×0)
                                             = CONV25 result
```

**One Layer-1 adder output = one CONV25 partial sum** for Stage 1, with no additional hardware. The right-shift applied when tapping (`L1_x[19:1]`) normalises the sum back to 18-bit precision.

From 12 blocks, each producing 10 Layer-1 taps:

```
  12 blocks × 10 taps = 120 conv25 results directly from the adder tree
```

---

### 4.5 The Orphan Correction Layer (`ext_sum_correction`)

Each adder tree block has 32 conv9 input slots, but only **slots 0–29** (30 inputs) are used by the 10 Layer-1 adders. **Slots 30 and 31 of every tree are "orphan" inputs** — they enter via the DSP macro in Layer 2 (`L2_4 = L1_10 + in_31 + in_32`) but their path through `final_output` introduces a bit-range issue that prevents them from being used directly as Stage-1 conv25 outputs.

With 12 trees × 2 orphan slots = **24 orphan MAC values** that must be correctly accumulated for Stage 1.

The **`ext_sum_correction`** module handles this entirely in combinational logic. It collects all 24 orphan values into a flat pool and groups them sequentially into **8 three-input adders**:

```
  Flat pool:  pool[i] = mac_in[ i/2 ][ 30 + (i mod 2) ]
  i=0 → tree0[30],  i=1 → tree0[31],  i=2 → tree1[30],  i=3 → tree1[31] ...

  Correction adder groupings (8 adders × 3 inputs each):

  corr[0] = tree0[30]  + tree0[31]  + tree1[30]
  corr[1] = tree1[31]  + tree2[30]  + tree2[31]
  corr[2] = tree3[30]  + tree3[31]  + tree4[30]
  corr[3] = tree4[31]  + tree5[30]  + tree5[31]
  corr[4] = tree6[30]  + tree6[31]  + tree7[30]
  corr[5] = tree7[31]  + tree8[30]  + tree8[31]
  corr[6] = tree9[30]  + tree9[31]  + tree10[30]
  corr[7] = tree10[31] + tree11[30] + tree11[31]
```

Each raw sum uses a 20-bit accumulator (2 extra bits to prevent overflow from three 18-bit signed additions), then right-shifts by 1 to produce an 18-bit result matching the normalisation of the Layer-1 taps:

```
  raw_sum[c]  = sign_extend(pool[3c]) + sign_extend(pool[3c+1]) + sign_extend(pool[3c+2])
  corr_out[c] = raw_sum[c][DATA_WIDTH:1]   // bits [18:1] of 20-bit sum → 18-bit
```

The 8 corrected outputs (`corr_out[0..7]`), together with the 120 Layer-1 taps, provide all **128 conv25 results** needed for Stage 1.

---

### 4.6 Assembling 128 Inputs for 32 Shaaban Units (`flat_s1`)

The `adder_tree_shaaban_connect` module assembles all 128 Stage-1 inputs into the flat array `flat_s1[128]` using the following layout:

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  flat_s1 layout (128 entries, 18-bit each)                           │
  │                                                                      │
  │  Trees 0–7  (stride = 11 per tree):                                  │
  │    flat_s1[t×11 + 0 .. t×11 + 9]  = tree_tap[t][0..9]  (10 taps)   │
  │    flat_s1[t×11 + 10]             = corr_out[t]          (1 correction)│
  │                                                                      │
  │  Trees 8–11 (stride = 10 per tree, no correction needed):            │
  │    flat_s1[88 + (t-8)×10 + 0..9] = tree_tap[t][0..9]   (10 taps)  │
  │                                                                      │
  │  Totals:  8 × (10+1) + 4 × 10 = 88 + 40 = 128 ✓                    │
  └──────────────────────────────────────────────────────────────────────┘
```

Trees 0–7 each contribute 11 entries (10 taps + 1 orphan correction). Trees 8–11 contribute 10 entries each — their orphan values were already consumed in the corrections for Trees 0–7 via the cross-tree grouping in `ext_sum_correction`.

Each Shaaban unit `s` receives 4 consecutive entries:

```
  Shaaban unit s  ←  flat_s1[s×4],  flat_s1[s×4+1],  flat_s1[s×4+2],  flat_s1[s×4+3]
```

These 4 values correspond to 4 spatially adjacent CONV25 outputs — the 2 × 2 neighbourhood required by the max-pooling stage inside the Shaaban unit.

---

### 4.7 Stage Routing via `src_sel`

The 2-bit `src_sel` signal controls which data source drives each of the 32 Shaaban units via a **combinational 3-to-1 MUX** (`unique case` in SystemVerilog):

| `src_sel` | Active Stage | Data Source for Shaaban Unit `s` | Active Shaabans |
|:---------:|:------------:|----------------------------------|:---------------:|
| `2'b00` | Stage 1 | `flat_s1[s×4 .. s×4+3]` (120 L1 taps + 8 orphan corrections) | **All 32** |
| `2'b01` | Stage 2 | `s < 3`: `tree_final[s×4 .. s×4+3]`; `s ≥ 3`: all zeros | **3** (units 0, 1, 2) |
| `2'b10` | Stage 3 | `s==0, slot 0`: `final_s3` (64-ch sum); all other slots/units: zero | **1** (unit 0 only) |

**Stage 2 detail:** Shaaban units 0, 1, and 2 each receive 4 consecutive `tree_final` values:

```
  Shaaban 0  ←  tree_final[0],  tree_final[1],  tree_final[2],  tree_final[3]
  Shaaban 1  ←  tree_final[4],  tree_final[5],  tree_final[6],  tree_final[7]
  Shaaban 2  ←  tree_final[8],  tree_final[9],  tree_final[10], tree_final[11]
```

Each `tree_final` is the full 32-channel accumulated sum from one block. The 4 values feeding one Shaaban unit correspond to 4 spatially adjacent output positions (the 2 × 2 window for max-pooling), producing **3 LIF2 outputs per clock cycle**.

**Stage 3 detail:** Only Shaaban unit 0, input slot 0 receives `final_s3` — the pre-accumulated 64-channel sum (computed outside this module by adding two `tree_final` outputs, one from each of the two blocks representing the 64 input channels). All remaining slots receive zero, producing **1 LIF3 output per clock cycle**.

**Inactive Shaaban units** receive `conv_in = 0` through the MUX. Their internal state is unchanged and they produce no spike while inactive.

---

### 4.8 The 32 Shaaban Units

All **32 Shaaban units** (`shaban_unit_top`) are physically instantiated on the FPGA at all times. Each unit takes **4 packed 18-bit values** as its convolution input and processes them through the complete backend pipeline:

```
  conv_in (4 × 18-bit, packed)
        │
        ├─ in[0] ─► conv_bias_Relu ─► Batch_Norm ─┐
        ├─ in[1] ─► conv_bias_Relu ─► Batch_Norm ─┤─► Max_pooling ─┐
        ├─ in[2] ─► conv_bias_Relu ─► Batch_Norm ─┤─► Max_pooling ─┼─► Max_pooling ─► LIF ─► spike
        └─ in[3] ─► conv_bias_Relu ─► Batch_Norm ─┘
```

**Sub-module breakdown (verified from RTL):**

| Sub-module | File | Operation | DSPs |
|-----------|------|-----------|:----:|
| `conv_bias_Relu` ×4 | `conv_bias_Relu.v` | `out = max(in + bias, 0)`, then truncate LSB | 4 adders |
| `Batch_Norm` ×4 | `Batch_Norm.v` | `out = (in × mult_weight) + add_weight` via `xbip_dsp48_macro_0`; result = bits [36:19] | 4 MACs |
| `Max_pooling` ×2 | `Max_pooling.v` | `out = max(in1, in2)` — reduces 4 values to 2 | 2 comparators |
| `Max_pooling` ×1 | `Max_pooling.v` | Final 2→1 reduction | 1 comparator |
| `LIF` ×1 | `LIF.v` | Leaky integrate-and-fire: decay (>>>1) → integrate → threshold compare → spike | 1 (3-adder DSP) |
| **Total per unit** | | | **13 DSPs** |

**LIF neuron internals (`LIF.v`):**

```
  mem_leak          = mem_reg >>> 1                  // β = 0.5: arithmetic right-shift (decay)
  mem_input         = mem_leak + in_pool             // 19-bit: integrate new input
  mem_input_trunc   = mem_input[DATA_WIDTH:1]        // back to 18-bit
  reset_val         = spike_reg ? threshold : 0      // if previous cycle fired, subtract threshold
  new_mem           = mem_input_trunc − reset_val    // update membrane potential
  spike             = (new_mem ≥ threshold) ? 1 : 0  // fire if above threshold
```

Parameters: `threshold = 18'd5`, `DATA_WIDTH = 18`. The reset is delayed by one cycle (`spike_reg` = previous cycle's spike), implementing **reset-before-spike** (delay = 1) behaviour.

**Shaaban DSP contribution by stage:**

| Stage | Active Shaaban Units | Shaaban DSPs |
|:-----:|:-------------------:|:------------:|
| Stage 1 | 32 (all) | 32 × 13 = **416** |
| Stage 2 | 3 (units 0, 1, 2) | 3 × 13 = **39** |
| Stage 3 | 1 (unit 0 only) | 1 × 13 = **13** |

> The remaining idle units are static hardware overhead counted in the DSP budget regardless of stage. Their physical presence enables zero-latency stage switching — `src_sel` changes the MUX output combinationally.

---

## 5. Stage 1 — 5 × 5 Convolution Architecture

### 5.1 Input and Filter Specification

Stage 1 performs a 5 × 5 convolution over a single input channel (grayscale) to produce 32 output feature channels.

| Parameter | Value |
|-----------|-------|
| Input frame | 256 × 256 grayscale, zero-padded to 260 × 260 |
| Input window per operation | 24 × 24 crop (from backtracking) |
| Conv kernel | 5 × 5 |
| Input channels | 1 |
| Output filters | 32 |
| Stride | 1 |
| Padding | None (zero-padding applied to full frame before crop) |
| Conv output (per crop) | 20 × 20 × 32 |
| After MaxPool 2 × 2 | 10 × 10 × 32 |
| LIF1 output | 10 × 10 × 32 spikes |

---

### 5.2 The CONV25 Unit

The CONV25 unit computes a full 5 × 5 convolution for a single output pixel: it multiplies each of the 25 input elements P[0]…P[24] by the corresponding filter weight Q[0]…Q[24], then sums all 25 products.

**Naïve implementation cost:**
- 25 multipliers (one per P×Q pair)
- 24 adders arranged in a reduction tree: 12 → 6 → 3 → 2 → 1
- Total: **49 DSP units** per CONV25 instance

**DSP cascade optimisation:**

The DSP48E2 slices support **cascaded MAC chains** — each DSP has three inputs (A, B, and an accumulator from the previous DSP's output). By chaining DSPs, each subsequent slice adds a new multiply-accumulate without a separate adder:

```
  DSP_0:  0      + P[0]×Q[0]  → acc_0
  DSP_1:  acc_0  + P[1]×Q[1]  → acc_1
  DSP_2:  acc_1  + P[2]×Q[2]  → acc_2
       ...
  DSP_8:  acc_7  + P[8]×Q[8]  → acc_8   (partial sum for 9 elements)
```

Each DSP performs both multiplication and accumulation in **one pipeline stage (1 delay unit)**. A chain of 9 cascaded DSPs accumulates 9 products in 9 delays — this is the **conv9 primitive**.

**CONV25 built from three conv9 chains:**

To compute 25 products efficiently, three parallel conv9 chains are used, with 2 weight entries set to zero to cover only 25 of the 27 positions:

```
  Chain A (9 DSPs):  P[0]×Q[0]   + … + P[8]×Q[8]               → sum_A
  Chain B (9 DSPs):  P[9]×Q[9]   + … + P[17]×Q[17]             → sum_B
  Chain C (9 DSPs):  P[18]×Q[18] + … + P[24]×Q[24] + 0 + 0     → sum_C
                                                          ↑   ↑
                                             Q[25]=0   Q[26]=0   (2 MACs zeroed)

  Layer-1 adder (1 DSP):  sum_A + sum_B + sum_C → CONV25 output
```

The three chains run in parallel. The Layer-1 3-input adder performs the final summation:

```
  9 (cascade chain) + 1 (Layer-1 adder) = 10 delays total
```

This reduces the naïve 49-DSP cost to **27 DSPs per CONV25 unit** (3 × 9 = 27).

<div align="center">
<img width="1191" height="671" alt="CONV25 Architecture" src="https://github.com/user-attachments/assets/2594e342-6901-4c5e-a79c-4f5537ff692e" />
</div>

---

Based on the updated and much more detailed `README (1).md` you provided, you have a beautifully structured document.

Since the new section specifically explains how the inputs are routed to form the **CONV25** units using the 12 blocks of 32 `conv9` units, the absolute best place to put it is in **Section 5 (Stage 1 — 5 × 5 Convolution Architecture)**, immediately after the hardware explanation of the CONV25 unit.

I recommend inserting it as a new subsection **`5.2.1 Data Routing and Input Mapping for CONV25`**, right between **`5.2 The CONV25 Unit`** and **`5.3 The Shaaban Unit — Backend Processing`**.

Here is exactly how it will look in your markdown file:

```markdown
  Layer-1 adder (1 DSP):  sum_A + sum_B + sum_C → CONV25 output

```

The three chains run in parallel. The Layer-1 3-input adder performs the final summation:

```
  9 (cascade chain) + 1 (Layer-1 adder) = 10 delays total

```

This reduces the naïve 49-DSP cost to **27 DSPs per CONV25 unit** (3 × 9 = 27).

---

### 5.2.1 Data Routing and Input Mapping for CONV25 (The Shift Strategy)

To build the CONV25 units efficiently, the architecture relies on instantiating base `conv9` modules in blocks of 32. Since three `conv9` modules are combined to form one CONV25 unit, a strict block of 32 yields 10 complete CONV25 units, leaving exactly 2 `conv9` modules "hanging" without a third partner (32 ÷ 3 = 10, remainder 2).

To process the entire memory array seamlessly across 12 such blocks (384 `conv9` instances in total) without leaving any unused hardware or breaking the continuous data stream, a **hardware data routing strategy** is employed. Instead of changing the physical hardware instantiations, the continuous memory stream (`in_mem`) is dynamically re-arranged as it feeds into the inputs (`p_imag`) of the `conv9` units.

Because 32 × 3 = 96 (which is perfectly divisible by 3), the required data-shuffling pattern naturally repeats every 3 blocks. The mapping cycles through three distinct states:

* **State 0: The Straight Mapping (Blocks 0, 3, 6, 9)**
* Starts perfectly aligned. The first 30 inputs feed 10 internal adders perfectly. The last 2 inputs become the "hanging" elements waiting for a 3rd partner in the next block.


* **State 1: The 1-Shift Mapping (Blocks 1, 4, 7, 10)**
* The block skips 1 memory element to use as the missing 3rd partner for the previous block's remainder. The next 30 inputs are shifted forward by 1. This leaves 1 hanging element at the end of the block.


* **State 2: The 2-Shift Mapping (Blocks 2, 5, 8, 11)**
* The block skips 2 memory elements to complete the group with the previous block's 1 hanging element. The next 30 inputs are shifted forward by 2. This perfectly consumes all elements, leaving **zero** hanging elements at the end, ready to reset to State 0.



This cyclic mapping is implemented elegantly in SystemVerilog using a parameterized `generate` block with a modulo (`% 3`) operator to assign the correct memory indices at compile time:

```systemverilog
genvar b, j;

generate
    // Loop through all 12 blocks
    for (b = 0; b < 12; b = b + 1) begin : gen_blocks
        
        // State 0: The Reset / Straight Mapping (Blocks 0, 3, 6, 9)
        if (b % 3 == 0) begin : state_0
            for (j = 0; j < 32; j = j + 1) begin : assign_state_0
                assign p_imag[(b * 32) + j] = in_mem[(b * 32) + j];
            end
        end
        
        // State 1: The 1-Shift Mapping (Blocks 1, 4, 7, 10)
        else if (b % 3 == 1) begin : state_1
            // The first 30 inputs take the next 30 memory slots (shifted by 1)
            for (j = 0; j < 30; j = j + 1) begin : assign_state_1
                assign p_imag[(b * 32) + j] = in_mem[(b * 32) + j + 1];
            end
            // Handle the skipped element and the final hanging element
            assign p_imag[(b * 32) + 30] = in_mem[(b * 32)];
            assign p_imag[(b * 32) + 31] = in_mem[(b * 32) + 31];
        end
        
        // State 2: The 2-Shift Mapping (Blocks 2, 5, 8, 11)
        else begin : state_2
            // The first 30 inputs take the next 30 memory slots (shifted by 2)
            for (j = 0; j < 30; j = j + 1) begin : assign_state_2
                assign p_imag[(b * 32) + j] = in_mem[(b * 32) + j + 2];
            end
            // Handle the two skipped elements to complete the group
            assign p_imag[(b * 32) + 30] = in_mem[(b * 32)];
            assign p_imag[(b * 32) + 31] = in_mem[(b * 32) + 1];
        end
        
    end
endgenerate

```

---


### 5.3 The Shaaban Unit — Backend Processing

After each CONV25 computes one dot product, the result passes through Bias & ReLU, Batch Normalisation, Max Pooling, and the LIF neuron via the shared **Shaaban unit** (described in Section 4.8).

The Shaaban unit takes **4 CONV25 outputs** — corresponding to a 2 × 2 spatial neighbourhood — and produces 1 LIF spike output through the 4 → 2 → 1 max-pool reduction tree followed by the LIF neuron.

---

### 5.4 Stage 1 — Full Picture

For Stage 1, `src_sel = 2'b00`. All 32 Shaaban units are active and receive their 4 inputs from `flat_s1`:

```
  32 filters, each needing 4 CONV25 outputs:
  32 × 4 = 128 CONV25 outputs required

  From 12 adder trees × 10 Layer-1 taps  = 120  (directly from adder tree)
  From ext_sum_correction                =   8  (orphan corrections)
  ─────────────────────────────────────────────
  Total                                  = 128  ✓
```

With all 32 filters computing simultaneously, Stage 1 produces **32 output pixels per clock cycle**. Since the backtracking analysis requires a 10 × 10 LIF1 output per crop:

```
  10 × 10 spatial positions = 100 cycles per 24×24 input crop
```

---

### 5.5 Stage 1 Resource Summary

| Resource | Count |
|----------|------:|
| Total conv9 units | 384 (12 blocks × 32 each) |
| CONV25 results produced | 128 (120 L1 taps + 8 corrections) |
| DSPs per conv9 unit | 9 |
| Conv DSPs total | 384 × 9 = **3,456** |
| Adder tree DSPs (Layers 1–4) | 10 × 4 × 3 = **120** |
| Extra ADD (orphan corrections) | **8** |
| Shaaban units active | 32 |
| DSPs per Shaaban unit | 13 |
| Shaaban DSPs total | 32 × 13 = **416** |
| **Total DSPs — Stage 1** | **4,000 (98.1% of the 4,638 allowed budget)** |

---

### 5.6 Stage 1 Critical Path

| Path Segment | Delays |
|-------------|:------:|
| conv9 cascade (9 DSPs) | 9 |
| Layer-1 adder (CONV25 final sum) | 1 |
| Shaaban unit backend (Bias → BN → Pool → LIF) | 6 |
| **Total Stage 1 critical path** | **16** |

---

## 6. Stage 2 — 3 × 3 Convolution, 32 Input Channels

> *This section will be completed in a future update.*

---

## 7. Stage 3 — 3 × 3 Convolution, 64 Input Channels

> *This section will be completed in a future update.*

---

## 8. Memory Control & Frame Mapping

### 8.1 The Architectural Challenge: Virtual Sliding Windows

In Stage 2 of the MultiStage-DeepSNN, the accelerator processes a $3 \times 3$ convolution with 32 input channels. A traditional hardware approach would use one of two methods:

1. **Line Buffers / Shift Registers:** Physically shifting pixel data through registers to create a sliding window.
2. **Standard RAM Access:** Using a CPU-like controller to fetch 9 individual pixels for every clock cycle.

**The Stage 2 Problem:**

* **Power & Area Constraints:** With a 256×256 input resolution, physically shifting thousands of 18-bit fixed-point values every cycle consumes excessive power and utilizes too many LUTs/Registers.
* **Throughput Bottleneck:** Standard RAM fetching is too slow. To keep the 12 shared convolution engines saturated, the system would need to perform 108 memory reads per cycle ($12 \text{ engines} \times 9 \text{ pixels}$), which exceeds the port limit of FPGA BRAMs.

**The Solution: The Virtual Sliding Window**
Instead of moving data to the engines, we move the **engines' focus** across a static data block. We load a wide "strip" of spatial data into a 3200-bit bit-vector (`mem`). We then use a massive combinational multiplexer tree to "point" the input pins of the 12 convolution engines to specific bit-indices within that vector.

By changing a 3-bit control signal (`frame`), the hardware instantly re-routes the connections. This allows the same physical DSP pool to "slide" across different spatial regions of the image in a single clock cycle with **zero data-shuffling overhead**. This is critical for Stage 2, where the 32-channel depth requires the spatial logic to remain extremely efficient to meet the 40MHz timing constraint.

---

This section defines the hardware interface for the `frame_mapping_iterations_flters` module in Stage 2. It details how a massive 3200-bit input bus is reorganized into a structured array that the downstream convolution engines can consume.

---

### 8.2 Hardware Interface & I/O (Stage 2 Specifics)

The `frame_mapping_iterations_flters` module acts as a high-speed "unpacker" and "router." It takes a wide spatial slice from memory and transforms it into a multidimensional array that separates different filter iterations and spatial pixel positions.

#### I/O Signal Specification

The module interface is defined as follows:

| Signal Name | Direction | Data Type / Size | Description |
| --- | --- | --- | --- |
| `clk` | Input | `logic` | System clock (40 MHz). |
| `arst_n` | Input | `logic` | Asynchronous active-low reset. |
| `frame` | Input | `logic [2:0]` | Spatial control (1–6) determining the grid region. |
| `mem` | Input | `logic [3199:0]` | **Input Bit-Vector**: A flattened 1D array of grid activations. |
| `fil_in` | Output | `logic [31:0][39:0]` | **2D Output Buffer**: 32 Filter iterations $\times$ 40 pixels. |

#### The 3200-bit Input Vector (`mem`)

In Stage 2, the memory controller provides a 3200-bit word. This word represents a horizontal "strip" of the 2D spatial grid. Because Stage 2 requires 32-channel depth, the memory is organized so that these 3200 bits contain the necessary spatial data for the current window.

* **Capacity:** Each bit in this vector represents a spike/activation from the previous layer.
* **Organization:** The vector is treated as a linear resource that the `frame` logic "carves" into smaller windows.

#### The 2D Output Array (`fil_in`)

The primary output of this module is the `fil_in[31:0][39:0]` array. This structure is critical for the Stage 2 pipeline:

1. **Filter Dimension `[31:0]`:** This represents the 32 filter channels. Each "row" in this array corresponds to a specific filter's spatial data.
2. **Spatial Dimension `[39:0]`:** Each "column" holds 40 bits of spatial data. This is wider than a single $3 \times 3$ window because it encompasses the full span needed to feed 12 convolution engines simultaneously across the grid.

#### Master Control: The `frame` Signal

The 3-bit `frame` signal is the master selector. It tells the combinational logic which 40 bits of the 3200-bit `mem` vector should be routed to which filter row in the `fil_in` array. Without this signal, the convolution engines would be "blind" to their position on the $256 \times 256$ grid.

---

**In the next section, we will break down the "Frame Strategy"—how these 6 frames actually divide the grid spatially.**

This section details the **6-Frame Spatial Strategy**. It explains how the grid is partitioned to ensure that 12 shared convolution engines can cover the entire $256 \times 256$ spatial area without leaving gaps or requiring redundant hardware.

---

### 8.3 The 6-Frame Spatial Strategy (The Concept)

In Stage 2, the hardware must slide a $3 \times 3$ kernel across the input grid. To optimize throughput, we don't process one pixel at a time; we process **12 windows simultaneously** in a "sliding band." The `frame` signal (1–6) determines where this band is located on the grid.

#### A. Vertical Partitioning: Top vs. Bottom Clusters

To maximize vertical reuse of data, the 12 convolution engines are split into two groups that work in parallel on adjacent rows:

* **Top Orientation (Engines 1, 2, 5, 6, 9, 10):** These process the upper part of the band (e.g., Rows $N, N+1, N+2$).
* **Bottom Orientation (Engines 3, 4, 7, 8, 11, 12):** These process the lower part of the band (e.g., Rows $N+1, N+2, N+3$).

By overlapping these orientations, the hardware calculates two vertical rows of the output feature map in a single horizontal sweep.

#### B. Spatial Frame Definitions

The 6 frames implement four distinct traversal patterns to cover the grid's unique geometry and boundary conditions:

| Frame | Pattern Type | Spatial Behavior |
| --- | --- | --- |
| **1, 4, 5** | **Continuous Sweep** | Standard linear horizontal progression. These frames handle the "meat" of the grid where data is contiguous. |
| **2** | **Maximum Span** | Utilizes the full 40-input width of the buffer. It uses "Top-Top-Bottom-Bottom" clustering to reach the furthest horizontal extent of the memory strip. |
| **3** | **Hybrid / Jump** | Combines high-density overlapping (1-column strides) for the first 8 engines with a large spatial "jump" for the last 4 engines to reach the grid boundary. |
| **6** | **Truncated Edge** | A specialized "cleanup" frame. It only activates the first 4 engines to finish a partial row, while the remaining 8 are tied to zero. |

#### C. Overlap and Continuity

A critical requirement for Stage 2 is maintaining $3 \times 3$ continuity.

* **Horizontal Continuity:** Frames are designed so that the last column of Frame $N$ aligns with the first column of Frame $N+1$.
* **Padding Handling:** Because the indices are hard-coded per frame, the "padding" is implicit. If a frame reaches the edge of the $256 \times 256$ grid, the mapping logic simply routes `0` to those specific engine inputs, satisfying the SNN's zero-padding requirement without extra control logic.

By cycling through these 6 frames, the `frame_mapping_iterations_flters` module ensures that every coordinate of the input feature map is visited exactly once by the convolution pool.

---

**Next, we will look at Section 8.4: Mathematical Backtracking & Addressing—the actual formulas used to calculate these indices.**

This section dives into the mathematical "Backtracking" logic used to generate the bit-indices. It explains how we bridge the gap between a 2D spatial coordinate on the grid and a 1D bit-location in the 3200-bit memory vector.

---

### 8.4 Mathematical Backtracking & Addressing (The "How")

The power of the `frame_mapping_iterations_flters` module comes from its "correct-by-construction" addressing. To generate the RTL, we used a mathematical backtracking approach: starting from the physical pins of the 12 Convolution Engines and working backward to the memory bit-index.

#### A. The Linearization Formula

The 3200-bit `mem` bus represents a flattened version of the spatial grid. To locate any specific pixel $(row, col)$, we apply a linearization formula based on the architecture's grid constants:

* **ROW_STEP (320):** The number of bits to skip to move down one vertical row.
* **COL_STEP (32):** The number of bits to skip to move one horizontal column.

The absolute bit-index for any pixel is:


$$Bit\_Index = (row \times 320) + (col \times 32) + Offset$$

#### B. The Backtracking Methodology

For every Frame (1–6), the following steps were taken to determine the routing:

1. **Pin Identification:** Identify the target engine and its $3 \times 3$ kernel input (e.g., Engine 5, Input 1).
2. **Coordinate Assignment:** Determine the $(row, col)$ coordinate that "Engine 5, Input 1" must process during "Frame 2."
3. **Index Calculation:** Apply the Linearization Formula to find the exact bit-index in the 3200-bit vector.
4. **Offset Expansion:** Repeat the calculation 32 times, adding an increment of `1` for each filter channel ($Offset = 0$ to $31$).

#### C. Grid Mapping Example

Consider a window for **Engine 1 (Top Orientation)** starting at $(0,0)$. Its $3 \times 3$ kernel inputs map to the following bit-indices at $Offset=0$:

| Kernel Position | Coordinate $(r, c)$ | Formula Calculation | Bit-Index |
| --- | --- | --- | --- |
| **Top-Left (In 1)** | $(0, 0)$ | $(0 \times 320) + (0 \times 32)$ | `mem[0]` |
| **Top-Mid (In 2)** | $(0, 1)$ | $(0 \times 320) + (1 \times 32)$ | `mem[32]` |
| **Mid-Left (In 4)** | $(1, 0)$ | $(1 \times 320) + (0 \times 32)$ | `mem[320]` |
| **Bottom-Right (In 9)** | $(2, 2)$ | $(2 \times 320) + (2 \times 32)$ | `mem[704]` |

#### D. Implementation of the "Jump" Logic

When a frame requires a "Spatial Jump" (as seen in Frame 2 or 3), the backtracking logic simply updates the $(row, col)$ anchors. For instance, if Engine 9 needs to jump 16 columns over, the formula automatically scales the `COL_STEP` portion:


$$Index = (row \times 320) + ((col+16) \times 32)$$


This results in the non-contiguous memory indices (e.g., `mem[192]`, `mem[768]`) seen in the final RTL code.

---

**Next, we will conclude with Section 8.5: Automated RTL Generation, which analyzes the final code and the Python-to-Verilog workflow.**

This final section documents the transition from mathematical theory to physical RTL. It explains why a Python-based "Spatial Compiler" was used and how to interpret the resulting Verilog code.

---

### 8.5 Automated RTL Generation (The "Spatial Compiler")

The `frame_mapping_iterations_flters` module is the largest combinational block in the Stage 2 architecture. Because it contains **1,280 unique case statements**, manual entry was rejected in favor of an automated Python-to-Verilog workflow.

#### A. Why Automation was Required

Manual RTL coding at this scale introduces three critical risks:

1. **Index Fatigue:** Calculating 1,280 bit-indices manually (e.g., `mem[192]`, `mem[768]`) inevitably leads to "off-by-one" errors that are nearly impossible to debug in hardware.
2. **Structural Rigidity:** If the grid constants (`COL_STEP` or `ROW_STEP`) changed during hardware-software co-design, a manual module would require a complete rewrite.
3. **Boundary Complexity:** Ensuring that "Frame 6" correctly drives zeros to unused engines while "Frame 2" correctly jumps 16 columns requires consistent logic that only a script can guarantee.

#### B. The Generation Workflow

We developed a script that acts as a **Spatial Compiler**. It takes the high-level grid requirements as input and "compiles" them into hard-wired Verilog assignments:

1. **Input:** Grid Dimensions ($256 \times 256$), Step Constants (32, 320), and Frame Definitions.
2. **Process:** The script iterates through 32 filter offsets and 40 input indices, applying the backtracking formula for each of the 6 frames.
3. **Output:** A fully synthesizable `frame_mapping_iterations_flters.v` file containing the optimized `always_comb` block.

#### C. Snippet Analysis: Interpreting the RTL

The generated code implements the spatial routing as a direct lookup table. This allows the synthesis tool (Vivado) to map the logic directly into the FPGA's routing fabric (MUXes and wires) rather than using computational logic.

```systemverilog
// ========================================
// FILTER OFFSET: 0 (The first channel iteration)
// ========================================

// Mapping logic for Input Index 0
case(frame)
  1: fil_in[0][0] = mem[0];     // (Row 0, Col 0) -> Standard Start
  2: fil_in[0][0] = mem[192];   // (Row 0, Col 6) -> Spatial Jump in Frame 2
  3: fil_in[0][0] = mem[768];   // (Row 2, Col 12) -> Vertical/Horizontal Shift
  4: fil_in[0][0] = mem[1344];  // (Row 4, Col 6)
  5: fil_in[0][0] = mem[1920];  // (Row 6, Col 0)
  6: fil_in[0][0] = mem[2112];  // (Row 6, Col 6) -> Edge Terminal Point
  default: fil_in[0][0] = 0;    // Hardware-level padding
endcase

```

**Key Code Features:**

* **`fil_in[0][0]`**: The first index `[0]` represents the 0th Filter iteration. The second index `[0]` is the first of the 40 spatial pixels.
* **`mem[192]`**: This hard-coded index is the final result of the backtracking formula. By providing the constant directly, the FPGA avoids performing any multiplication or addition at runtime.
* **Default Case**: By explicitly setting the `default` to `0`, we ensure that any undefined frame state results in a "Safe Zero," preventing the SNN from processing "garbage" data and maintaining zero-padding integrity.

This section documents the final stage of the data path: mapping the 40-bit spatial buffer into the physical pins of the 12 convolution engines. While the previous block handled memory-to-buffer routing, this block—the **Engine Input Mapper**—is responsible for carving those 40 bits into twelve overlapping $3 \times 3$ windows.

---

### 8.6 The Engine Pin-Out & Interface (I/O Summary)

The `frame_input_mapping_brackets` module serves as the final "switchboard" before the mathematical operations begin. It is a purely combinational block designed to handle high-fanout routing with zero clock latency.

| Signal Name | Direction | Data Type / Size | Description |
| --- | --- | --- | --- |
| `frame` | Input | `logic [2:0]` | Spatial control (1–6) determining the routing strategy. |
| `in` | Input | `logic [39:0]` | **40-bit Spatial Buffer**: The flattened strip of grid data. |
| `conv` | Output | `logic [11:0][8:0]` | **Engine Port Array**: 12 engines, each with 9 kernel inputs. |

#### Port Breakdown

* **Input `in[40]**`: This is a single-filter slice of the spatial grid. Each bit represents an activation (spike) at a specific coordinate $(x, y)$ relative to the current frame's origin.
* **Output `conv[12][9]**`: This multidimensional array maps directly to the hardware math units.
* The first dimension `[11:0]` corresponds to the **12 shared convolution engines**.
* The second dimension `[8:0]` corresponds to the **9 pins of a $3 \times 3$ kernel** (Top-Left, Top-Mid, ..., Bottom-Right).



---

### 8.7 Kernel-to-Buffer Geometric Mapping (The "Why")

The core challenge in Stage 2 is that 12 engines must process the grid simultaneously to meet the timing requirements, but they share a significant amount of data.

#### The Fan-Out Challenge

Each $3 \times 3$ convolution requires 9 input pixels. For 12 engines, the total "pin requirement" is $12 \times 9 = 108$ pins. However, we only have 40 bits of input data. This means that on average, **every bit in the input buffer is reused by nearly 3 different engines simultaneously.**

#### The Flattened $3 \times 3$ Stride

The input buffer `in[40]` represents a flattened grid section. To extract a $3 \times 3$ window, the mapping logic must "skip" indices to move between rows. For a standard stride, the mapping follows this geometric rule:

* **Row 1:** `in[k]`, `in[k+1]`, `in[k+2]`
* **Row 2:** `in[k+4]`, `in[k+5]`, `in[k+6]`
* **Row 3:** `in[k+8]`, `in[k+9]`, `in[k+10]`

#### Vertical Stacking (Top vs. Bottom)

To optimize the data path, the engines are routed in two horizontal bands:

1. **Top Engines (1, 2, 5, 6, 9, 10):** Anchored to the "Top" rows of the 40-bit buffer.
2. **Bottom Engines (3, 4, 7, 8, 11, 12):** Anchored one row lower, reusing the middle and bottom rows of the Top group.

This specific geometric reuse is what allows 12 engines to operate on only 40 bits of data without stalling.

---

**Next, we will look at Section 8.8: Backtracking to Buffer Indices—showing exactly how we calculated the indices for the `in[0]` to `in[39]` mapping.**

This section details the internal coordinate system of the 40-bit buffer and the rules used to calculate the specific indices for each convolution engine.

---

### 8.8 Backtracking to Buffer Indices (The "How")

To generate the mapping logic for `conv[c][i]`, we treat the 40-bit input buffer (`in[39:0]`) as a local 2D coordinate system. This step is distinct from the global memory mapping; it defines how the 12 engines "look" at the 40-bit slice they have been given.

#### A. Local 2D Coordinate System

The 40-bit buffer is logically organized into a small grid. While the exact width varies by frame strategy, the standard mapping assumes a width of 4 elements. The local index for any coordinate $(x, y)$ within this 40-bit slice is:


$$Local\_Index = (y \times Width) + x$$

#### B. The Engine Stride Rules

Each engine $c$ (from 0 to 11) is assigned a "Top-Left Anchor" within the 40-bit buffer. From that anchor, the 9 kernel inputs are mapped using a consistent relative offset:

| Kernel Input | Relative $(x, y)$ | Index Offset Formula |
| --- | --- | --- |
| `conv[c][0]` (Top-Left) | $(0, 0)$ | `Anchor + 0` |
| `conv[c][1]` (Top-Mid) | $(1, 0)$ | `Anchor + 1` |
| `conv[c][2]` (Top-Right) | $(2, 0)$ | `Anchor + 2` |
| `conv[c][3]` (Mid-Left) | $(0, 1)$ | `Anchor + 4` |
| `conv[c][4]` (Mid-Mid) | $(1, 1)$ | `Anchor + 5` |
| `conv[c][5]` (Mid-Right) | $(2, 1)$ | `Anchor + 6` |
| `conv[c][6]` (Bot-Left) | $(0, 2)$ | `Anchor + 8` |
| `conv[c][7]` (Bot-Mid) | $(1, 2)$ | `Anchor + 9` |
| `conv[c][8]` (Bot-Right) | $(2, 2)$ | `Anchor + 10` |

#### C. Frame-Specific Anchor Shifts

The `frame` signal doesn't just change which memory bits enter the buffer; it changes where each engine "starts" within that buffer.

* **In Frame 1:** Engine 0 is anchored at `in[0]`. Its kernel covers indices based on the table above (0, 1, 2, 4, 5, 6, 8, 9, 10).
* **In Frame 2 (The Jump):** To achieve a wider spatial span, the anchors for engines 4 through 11 are shifted by large constants (e.g., +16 or +20). This allows the hardware to skip columns in the grid without needing more than 40 bits of buffer space.

#### D. Vertical Overlap Calculation

The "Top" and "Bottom" clusters are handled by calculating two sets of anchors simultaneously.

* **Top Engines:** Anchor $y$ starts at 0.
* **Bottom Engines:** Anchor $y$ starts at 1.
This result ensures that the `Mid` row of a Top engine and the `Top` row of a Bottom engine point to the **exact same index** in the 40-bit buffer, maximizing data reuse and reducing power consumption.

---

**Next, we will conclude with Section 8.9: Automation & RTL Verification, showing how the Python script produces the final SystemVerilog case statements.**

This final section details the automated conversion of these geometric rules into synthesizable SystemVerilog.

---

### 8.9 Automation & RTL Verification (The "Engine Compiler")

The mapping from a 40-bit buffer to 108 physical DSP pins is a high-density routing task. To ensure the $3 \times 3$ kernel integrity across all 12 engines and 6 frames, we utilized a Python-based **Engine Compiler**.

#### A. The Generation Workflow

The Python script operates as a nested loop that mimics the hardware's spatial requirements:

1. **Frame Loop (1–6):** Selects the current spatial strategy.
2. **Engine Loop (0–11):** Selects the target convolution engine.
3. **Kernel Loop (0–8):** Iterates through the 9 positions of a $3 \times 3$ window.
4. **Backtracking:** Calculates the index in `in[40]` using the Anchor + Offset formulas described in Section 8.8.
5. **RTL Print:** Generates the explicit assignments seen in the code.

#### B. Snippet Analysis: Proving the Spatial Alignment

By looking at the generated code for **Frame 1**, we can see the geometric rules in action:

```systemverilog
3'd1: begin
    // Engine 0 (Top Cluster) - Anchor: in[0]
    conv[0][0] = in[0];  // Row 1: 0, 1, 2
    conv[0][1] = in[1];
    conv[0][2] = in[2];
    conv[0][3] = in[4];  // Row 2: 4, 5, 6 (Width of 4 skip)
    conv[0][4] = in[5];
    conv[0][5] = in[6];
    conv[0][6] = in[8];  // Row 3: 8, 9, 10
    conv[0][7] = in[9];
    conv[0][8] = in[10];

    // Engine 1 (Top Cluster) - Anchor: in[4] (1-column stride)
    conv[1][0] = in[4];  // Notice how Engine 1 starts where Engine 0's Row 2 began
    conv[1][1] = in[5];
    // ...
end

```

**Why this code is efficient:**

* **Zero Logic Gates:** This module contains no adders or multipliers. It synthesizes entirely into **wires and multiplexers**. On an FPGA, this is "free" logic that consumes virtually no power compared to active switching.
* **Hard-Wired Continuity:** The script ensures that "Engine 1" is shifted exactly by the stride amount relative to "Engine 0." If this were done manually, a single typo in an index (e.g., `in[11]` instead of `in[10]`) would distort the feature map.
* **Implicit Padding:** For frames where an engine's window would fall "off the grid," the script simply doesn't generate an assignment for that engine or sets it to `'0` (as seen in the `always_comb` initialization), providing hardware-level zero-padding.

#### C. Synthesis & Timing

Because the `frame_input_mapping_brackets` is a purely combinational fan-out, it has a very short "Logic Depth." This ensures that the data reaches the Convolution Engines well within the 25ns window of our 40MHz clock, leaving the majority of the clock cycle available for the high-speed DSP multiplication and accumulation.

---

**This concludes the documentation for the Stage 2 Memory and Frame Mapping logic.**

  

## 9. Classifier Head — GAP, FC1, FC2

### Classifier Head — FC Layers

Fully-connected layer hardware for the MultiStage-DeepSNN accelerator.

#### Files
| File | What it does |
|------|-------------|
| `fc1_layer.sv` | FC1: 128 inputs -> 256 outputs + ReLU, 8 parallel MACs |
| `fc2_layer.sv` | FC2: 256 inputs -> 4 class logits, 4 parallel MACs |
| `tb_fc1_layer.sv` | Testbench for FC1 (3 test cases, self-checking) |
| `tb_fc2_layer.sv` | Testbench for FC2 (3 test cases, self-checking) |
| `golden_model.py` | Python golden model — computes expected fixed-point outputs |

#### Dependencies
Weights and biases are pulled from the SNN parameter files in
`../SNN Parameters/Values For LUTS Before Optimization/`. Make sure those
files are present and the build system can resolve the `include paths.

#### How to run testbenches (QuestaSim)
Open a terminal in this directory, then:

```
# FC1 (128->256 + ReLU, 4,096 cycles)
vlog -64 -sv -mfcu -suppress 2184 -work work fc1_layer.sv tb_fc1_layer.sv "+incdir+."
vsim -c tb_fc1_layer -do "run -all; quit"

# FC2 (256->4, 256 cycles)
vlog -64 -sv -mfcu -suppress 2184 -work work fc2_layer.sv tb_fc2_layer.sv "+incdir+."
vsim -c tb_fc2_layer -do "run -all; quit"
```

#### Golden model
```
python golden_model.py --fc1 --random-seed 42 --num-cases 3
```
Prints SystemVerilog-formatted test vectors that can be pasted into the
testbench files.

---

## 10. Full Resource Summary

> *This section will be completed once all stages are fully documented.*

| Stage | Conv DSPs | Adder Tree DSPs | Shaaban DSPs | Total DSPs | Utilisation |
|:-----:|----------:|----------------:|-------------:|-----------:|:-----------:|
| Stage 1 | 3,456 | 120 + 8 | 416 (32 active) | **4,000** | 98.1% |
| Stage 2 | 3,456 | 192 | 39 (3 active) | **3,687** | 90.5% |
| Stage 3 | 2,304 | 132 | 13 (1 active) | **2,449** | 60.1% |
| **Circuit Total** | — | — | — | **4,076** | **87.9%** |

**DSP48E2 budget used for this project: 4,638 allowed slices out of 9,216 total device slices**
