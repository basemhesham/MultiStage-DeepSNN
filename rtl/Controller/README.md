# Top Controller

`top_controller.sv` is the sequencing controller for the shared MultiStage-DeepSNN datapath. It owns the stage select, frame select, writeback layout select, convolution filter selectors, memory enables, padding clear control, and completion flag.

The controller is instantiated inside `rtl/Top/top.sv`, so these control signals are no longer external `deep_snn_top` inputs:

| Signal | Drives | Purpose |
|---|---|---|
| `stage` | `src_sel` inside `deep_snn_top` | Selects Stage 1, Stage 2, or Stage 3 datapath routing |
| `frame` | `mem_mapping` and `frame_input_mapping` | Cycles Stage 2 spatial frames `1..6` |
| `stage_sel` | `mem_maping_1_2` | Selects Stage 1-to-2 or Stage 2-to-3 writeback layout |
| `conv2_filter` | `CONV2_W_MAP_OPT` | Selects Stage 2 output filter `0..63` |
| `conv3_filter` | `CONV3_W_MAP_OPT` | Selects Stage 3 output filter `0..127` |
| `mem_enable` | spike memory write/reset enables | Selects which memory bits are written or reset |
| `rd_enable` | spike memory read enable | Enables readback for Stage 2/3 |
| `rd_mem_adderss` | spike memory read address | Selects source memory bank |
| `wr_mem_adderss` | spike memory write address | Selects destination memory bank |
| `zero_sel` | padding/reset path | Indicates padding clear operation |
| `padding_flag` | memory-bit reset control | Asserted while clearing padded destination memory |
| `gap_valid` | global average pooling | Enables Stage 3 samples on the final temporal pass only |
| `done` | top-level status | Asserted after all configured fragments and temporal frames complete |

## FSM

The controller uses this state sequence:

```text
IDLE
  -> CLEAR_STAGE2_WORD
  -> STAGE1
  -> CLEAR_STAGE3_WORD
  -> STAGE2
  -> STAGE3
  -> DONE
```

`IDLE` waits for `enable`.

`CLEAR_STAGE2_WORD` prepares the 3200-bit Stage 2 input word before Stage 1 writes real data. It asserts `padding_flag`, `zero_sel`, and all `mem_enable` bits for the Stage 2 destination bank.

`STAGE1` writes one 10x10x32 Stage 1 output fragment into the Stage 2
destination word. The destination word is 3200 bits:

```text
10 rows x 10 columns x 32 filters = 3200 bits
```

The 32 filters are stored contiguously for each spatial cell. The local cell base
addresses are:

```text
row 0: 0,    32,   64,   ... 288
row 1: 320,  352,  384,  ... 608
row 2: 640,  672,  704,  ... 928
...
row 9: 2880, 2912, 2944, ... 3168
```

For each 10x10 fragment, the controller enables only real cells. Padding cells
remain zero because `CLEAR_STAGE2_WORD` clears the destination word before Stage 1
writes into it.

The full padded Stage 1 output is treated as a 130x130x32 map, split into a
13x13 grid of 10x10 fragments. Therefore:

| Fragment position | Valid cells | Example enabled groups |
|---|---:|---|
| top-left corner | 9x9 = 81 | starts at `352`, then `384`, ... skips top row and left column |
| top edge | 9x10 = 90 | skips local row 0 |
| left edge | 10x9 = 90 | skips local column 0 |
| middle | 10x10 = 100 | enables all groups `0..3168` |
| right edge | 10x9 = 90 | skips local column 9 |
| bottom edge | 9x10 = 90 | skips local row 9 |
| bottom-right corner | 9x9 = 81 | skips local row 9 and local column 9 |

`CLEAR_STAGE3_WORD` prepares the Stage 3 input word before Stage 2 writes real data. It also asserts `padding_flag`, `zero_sel`, and all `mem_enable` bits, but targets the Stage 3 destination bank.

`STAGE2` cycles `frame = 1..6` for each `conv2_filter = 0..63`. This matches
the Stage 2 writeback layout used by `mem_maping_1_2`: each filter owns 16
spatial locations arranged as a local 4x4 block.

The Stage 2 global output is treated as a 64x64x64 map padded to 66x66x64 for
Stage 3. The controller applies the same location-based padding rule used by
Stage 1, but on the local 4x4 Stage 2 output block:

| Fragment position | Valid local Stage 2 cells | Padding behavior |
|---|---:|---|
| top-left corner | 3x3 = 9 | skip local row 0 and local column 0 |
| top edge | 3x4 = 12 | skip local row 0 |
| left edge | 4x3 = 12 | skip local column 0 |
| middle | 4x4 = 16 | enable all 16 local positions |
| right edge | 4x3 = 12 | skip local column 3 |
| bottom edge | 3x4 = 12 | skip local row 3 |
| bottom-right corner | 3x3 = 9 | skip local row 3 and local column 3 |

The controller still walks through the existing six frame groups:

```text
frame 1 -> positions 0, 1, 2
frame 2 -> positions 3, 4, 5
frame 3 -> positions 6, 7, 8
frame 4 -> positions 9, 10, 11
frame 5 -> positions 12, 13, 14
frame 6 -> position 15
```

For each group it enables only the non-padding positions. Padding positions stay
zero because `CLEAR_STAGE3_WORD` clears the Stage 3 destination word before
Stage 2 writes real data.

On the final Stage 2 cycle, `rd_mem_adderss` switches from bank 0 to bank 1.
This prefetches the Stage 2 writeback word for the first Stage 3 cycle because
the local `spike_mem` block is implemented as synchronous BRAM.

`STAGE3` cycles `conv3_filter = 0..127`. Each cycle enables one final output-filter location.

`DONE` holds `done = 1` until `enable` is deasserted.

## Padding

Padding is handled by clearing the destination memory word before writing real outputs. Because the memory bits have their own reset, the padding states should drive the memory-bit reset path, not the global reset.

Recommended memory connection:

```systemverilog
bit_reset = padding_flag && mem_enable[i];
```

Do not use `rst` or `arst_n` for padding. Those are global controller/datapath resets. Padding clear only resets the selected destination memory bank so that lanes not written by Stage 1 or Stage 2 remain zero.

This matches the required layouts:

| Stage write | Destination layout | Padding behavior |
|---|---|---|
| Stage 1 output | 10x10x32 fragment = 3200 bits | Clear all 3200 bits first, then write only the real non-padding 32-bit groups |
| Stage 2 output | 64 filters x 16 positions = 1024 used bits | Clear destination first, then write only real non-padding positions from the 4x4x64 Stage 3 input block |
| Stage 3 output | 128 final filter bits | No padded intermediate word is currently needed after Stage 3 |

## Top Integration

`deep_snn_top` instantiates the controller as `u_top_controller`. The controller output `stage` is connected internally as `src_sel`, which drives:

- the pixel source MUX,
- the weight ROM MUX,
- the adder-tree-to-Shaaban routing.

The controller output `stage_sel` drives `mem_maping_1_2`, so Stage 1 and Stage 2 writebacks use the correct packed memory layout.

`top.sv` now instantiates local BRAM-style memory wrappers. The controller
provides their write/read enables, addresses, and padding reset controls.
