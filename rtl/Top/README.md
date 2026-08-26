# deep_snn_top Integration Notes

`top.sv` instantiates the shared datapath for the MultiStage-DeepSNN FPGA
accelerator targeting the Xilinx Virtex UltraScale+ XCVU11P
`xcvu11p-flga2577-3-e`.

The RTL keeps one physical convolution/Shaaban datapath and reuses it across the
three SNN stages. The controller drives `src_sel`:

| `src_sel` | Active Stage | Datapath Use |
|---|---|---|
| `2'b00` | Stage 1 | 5x5 convolution path, all 32 Shaaban units active |
| `2'b01` | Stage 2 | 3x3 convolution path, Shaaban units 0..2 active |
| `2'b10` | Stage 3 | 3x3 convolution path, Shaaban unit 0 active |

## Input Paths

Stage 1 uses the internal `pixel_mem` block. The top-level load ports
`pixel_mem_wr_en`, `pixel_mem_wr_addr`, and `pixel_mem_wr_data` write a
6912-bit word into this memory. The selected word is unpacked into 384 signed
18-bit pixels. The Stage 1 mapping reorders these pixels so groups crossing
the 32-unit block boundary are aligned for the shared `conv9` array.

Stage 2 uses the internal `spike_mem` block, which stores Stage 1 spike
writeback data. `mem_mapping` and `frame_input_mapping` select the correct 3x3
windows for the current `frame` value.

Stage 3 also reads from internal `spike_mem`, but only the first 1024 bits are
used for the Stage 2 output layout: 64 channels x 16 positions.
`bin_muxing_stage2` converts the compact 4x4x64 map into four 3x3 windows. The
windows are mapped into adjacent row pairs of the shared 12x32 convolution
array.

## Local Memory And Parameters

`top.sv` now instantiates three local support blocks:

| Block | File | Purpose |
|---|---|---|
| `pixel_mem` | `pixel_mem.sv` | Stores one or more 6912-bit Stage 1 pixel words |
| `spike_mem` | `spike_mem.sv` | Stores packed spike words for Stage 1-to-2 and Stage 2-to-3 reuse |
| `bias_bn_params` | `bias_bn_params.sv` | Selects per-stage BN scale/bias parameters for the active Shaaban units |

`spike_mem` consumes the controller outputs `mem_enable`, `wr_mem_adderss`,
`rd_mem_adderss`, and `zero_sel`. During the padding-clear states, selected
bits are cleared to zero. During active stage writes, selected bits are written
from `mem_maping_1_2`.

`pixel_mem` and `spike_mem` are written in a BRAM inference style for Vivado:
both use synchronous reads and `(* ram_style = "block" *)`. `spike_mem` does
not write individual RAM bits directly. It merges the controller mask into a
3200-bit shadow word, then writes one full BRAM word, so Vivado does not need
to build a per-bit write-enable memory in LUTRAM. Because the memories are
BRAM-style, read data is available one clock after the read address is applied.
The `mem_maping_1_2` output is still 32 bits per location, but `spike_mem`
stores only bit 0 from each location because the writeback path already
replicates each spike bit across that 32-bit word.

`bias_bn_params` uses the final BN parameter files under
`rtl/SNN Parameters/Final Parameters (RTL)`. The current final-parameter folder
does not contain optimized convolution-bias files, so `conv_bias` is driven as
zero for now and the BN shift parameter drives `add_wight`.

## Why There Is A Mux In Top

The `case (src_sel)` statements in `top.sv` synthesize to multiplexers. That is
intentional for the current shared-hardware architecture. The mux chooses which
stage input and which stage weight table feed the single physical `conv9`
array.

Removing this mux would require another routing mechanism. The alternatives are:

- Duplicate the convolution hardware per stage, which would greatly increase
  DSP usage.
- Move the stage selection into a memory/BRAM read path, which still creates a
  mux or equivalent select logic somewhere else.

The mux does not stop DSP mapping. It is LUT routing in front of the explicit
`DSP48E2` instances.

## Shared Hardware

The shared compute path is:

```text
stage input mux
  -> active pixel array
stage weight mux
  -> active weight array
conv9 array, 12 x 32 units
  -> adder_tree_shaaban_connect
  -> 32 shaban_unit_top instances
  -> mem_maping_1_2 writeback
  -> global_average_pool
  -> FC1/FC2 classifier head
```

The weight ROM modules are distributed LUT logic. This is used because the
`conv9` array needs 3456 weights visible in parallel.

## Classifier Head

`top.sv` instantiates the classifier layers from `rtl/classifier_head`:

| Block | File | Purpose |
|---|---|---|
| `global_average_pool` | `global_average_pool.sv` | Averages Stage 3 spikes per channel before FC1 |
| `fc1_layer` | `fc1_layer.sv` | 128 Stage 3 features to 256 hidden values with ReLU |
| `fc2_layer` | `fc2_layer.sv` | 256 hidden values to 4 class logits |

During Stage 3, the top sends the active Shaaban spike from unit 0 into
`global_average_pool` using `conv3_filter` as the channel index. The controller
asserts `gap_valid` only on the final temporal pass, matching the Python
reference where GAP is applied to the final `spk3` map after the temporal loop.
The GAP block accumulates one spatial sample per channel per fragment, then
divides by `CTRL_FRAGMENTS_MAX` to produce the 128 fixed-point FC1 inputs.

When the SNN controller asserts `snn_done`, GAP finalization starts. `fc1_layer`
starts from `gap_done`, `fc2_layer` starts from `fc1_done`, and `done` is now
driven by the final `fc2_done` pulse. The intermediate SNN completion flag is
still available as the top-level `snn_done` output.

`class_logits` packs the four FC2 outputs as 18-bit words:

```text
class_logits[17:0]   = class 0
class_logits[35:18]  = class 1
class_logits[53:36]  = class 2
class_logits[71:54]  = class 3
```

## DSP48E2 Mapping

The arithmetic blocks instantiate `DSP48E2` manually. Vivado maps these
instances directly to physical DSP48E2 slices from the built-in UNISIM library.
The `dsp48_macro_dspe2` IP created by the Vivado Tcl script is only for IP
Catalog visibility; it is not used by `deep_snn_top`.

Current synthesized DSP count from
`build/vivado/deep_snn_top/deep_snn_top.runs/synth_1/deep_snn_top_utilization_synth.rpt`:

| Block | DSP48E2 Count |
|---|---:|
| 384 `conv9` units x 9 DSPs | 3456 |
| 12 adder trees x 16 DSPs | 192 |
| 8 external correction adders | 8 |
| 32 Shaaban units x 4 Batch_Norm DSPs | 128 |
| FC1/FC2 inferred MAC DSPs | 24 |
| **Total** | **3808** |

The utilization report shows:

```text
DSPs           3808
DSP48E2 only   3808
Primitive DSP48E2 3808 Arithmetic
```

The synthesis log also shows Vivado synthesizing `DSP48E2` from:

```text
C:/Xilinx/Vivado/2018.2/scripts/rt/data/unisim_comp.v
```

## Current TODO

- Replace the simple local memories with board-level BRAM/URAM interfaces when
  the external input/write path is finalized.
- Finish the full temporal frame loop around the LIF state behavior.
