# Module Specification: Adder Tree to Shaaban Bus Connection

**Project:** MultiStage-DeepSNN CNN-SNN Hybrid FPGA Accelerator  
**File:** `adder_tree_shaaban_connect.sv`  
**Status:** RTL connected, pending stage-level simulation sign-off

## 1. Purpose

`adder_tree_shaaban_connect` is the datapath bridge between the shared convolution
array outputs and the 32 Shaaban units instantiated in `top.sv`.

It receives `12 x 32` MAC outputs, runs the 12 adder-tree instances, and packs the
correct four 18-bit inputs for each Shaaban unit onto `shb_conv_bus`.

The same hardware is reused for all three convolution stages through `src_sel`.

## 2. File List

| File | Role |
|---|---|
| `adder_tree_shaaban_connect.sv` | Top-level adder-tree to Shaaban bus mux |
| `adder_tree_10_4_1_1.v` | 32-input adder tree, produces 10 taps and one final sum |
| `adder_layer1.v` | Three-input correction adder used for Stage 1 orphan MACs |
| `shaban_unit_top.v` | Shaaban unit connected by `top.sv` |
| `tb_adder_tree_shaaban_connect.sv` | Existing directed testbench |

## 3. Interface

| Port | Direction | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock passed to child adder-tree modules |
| `rst` | in | 1 | Reset passed to child adder-tree modules |
| `src_sel` | in | 2 | Stage selector |
| `mac_in` | in | `12 x 32 x DATA_WIDTH` | MAC results from the shared `conv9` array |
| `shb_conv_bus` | out | `32 x 4 x DATA_WIDTH` | Packed Shaaban convolution inputs |

This module does not instantiate the Shaaban units and does not drive `spike_out`
directly. `top.sv` connects `shb_conv_bus` to `shaban_unit_top`.

## 4. Parameters

| Parameter | Default | Description |
|---|---|---|
| `N_TREES` | 12 | Number of adder tree instances |
| `TAPS_PER_TREE` | 10 | Stage 1 tap outputs per tree |
| `N_SHAABAN` | 32 | Number of Shaaban units in the shared pool |
| `INPUTS_PER_SHB` | 4 | Inputs per Shaaban unit |
| `DATA_WIDTH` | 18 | Signed fixed-point width |
| `TOTAL_S1_INPUTS` | 128 | Derived: `N_SHAABAN * INPUTS_PER_SHB` |
| `TOTAL_TAPS` | 120 | Derived: `N_TREES * TAPS_PER_TREE` |
| `N_CORRECTION` | 8 | Derived Stage 1 orphan correction count |

## 5. Stage Routing

| `src_sel` | Stage | Active Shaaban bus entries | Input source |
|---|---|---|---|
| `2'b00` | Stage 1 | all 32 | `flat_s1[s*4 .. s*4+3]` |
| `2'b01` | Stage 2 | 0, 1, 2 | `tree_final[s*4 .. s*4+3]` |
| `2'b10` | Stage 3 | 0 only | `s3_results[0..3]` |

Inactive Shaaban bus entries are driven to zero.

## 6. Stage 1 Assembly

Each adder tree receives 32 MAC outputs. Ports `0..29` form ten 3-input tap sums.
Ports `30` and `31` from all trees are the orphan MACs.

Stage 1 needs:

```text
32 Shaabans x 4 inputs = 128 inputs
12 trees x 10 taps     = 120 direct tap outputs
8 correction sums      = 128 total inputs
```

The 24 orphan MACs are grouped into eight three-input correction adders using
`adder_layer1`, then truncated from 20 bits back to `DATA_WIDTH`.

`flat_s1` layout:

```text
trees 0..7:  10 taps + 1 correction each
trees 8..11: 10 taps each
```

Each Shaaban bus entry `s` receives four values from `flat_s1`.

## 7. Stage 2 Routing

Stage 2 uses the final output of each of the 12 trees. The 12 values are packed
four at a time into Shaaban bus entries `0`, `1`, and `2`.

## 8. Stage 3 Routing

Stage 3 receives four 3x3 windows from `bin_muxing_stage2` through `top.sv`.
Each window has 64 input channels, so `top.sv` maps one window into two adjacent
32-channel conv rows.

This module then pairwise-adds those adjacent rows:

```text
s3_results[0] = tree_final[0] + tree_final[1]
s3_results[1] = tree_final[2] + tree_final[3]
s3_results[2] = tree_final[4] + tree_final[5]
s3_results[3] = tree_final[6] + tree_final[7]
```

The four results feed Shaaban unit 0 slots `0..3`, giving its 2x2 max-pool input.
All other Shaaban bus entries are zero in Stage 3.

## 9. Synthesis Notes

- The stage mux is combinational and adds no pipeline delay.
- `unique case` on `src_sel` lets Vivado infer priority-free muxing.
- Stage 3 depends on `top.sv` tying unused rows `8..11` of `pixels_s3` to zero.
- Current target is Xilinx UltraScale+ with Vivado 2018.2.

## 10. Open Items

1. Run a focused simulation for the Stage 3 `bin_muxing_stage2 -> conv9 -> adder_tree_shaaban_connect -> Shaaban 0` path.
2. Decide whether inactive Shaaban units should also be reset or explicitly masked at `spike_out` when changing stages.
