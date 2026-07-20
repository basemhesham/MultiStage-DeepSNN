import sys

# ==============================================================================
# Hardware Parameters
# ==============================================================================
PIXEL_W = 18
GROUPS = 12       # 12 Adder Trees
CHANNELS = 32     # 32 Shaaban Units / Lanes
TAPS = 9          # 9 Taps per conv9

def to_hex_18bit(val):
    """Convert a signed integer to an 18-bit 2's complement hex string."""
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

# ==============================================================================
# RTL Equivalent Mapping Functions
# ==============================================================================
def stage1_stream_index(block, lane):
    rem = block % 3
    if rem == 0:
        return (block * 32) + lane
    elif rem == 1:
        if lane < 30:
            offset = lane + 1
        elif lane == 30:
            offset = 0
        else:
            offset = 31
        return (block * 32) + offset
    else:
        if lane < 30:
            offset = lane + 2
        else:
            offset = lane - 30
        return (block * 32) + offset

def stage1_patch_index(stream_index, tap):
    conv_output = stream_index // 3
    chunk = stream_index % 3
    padded_kernel_index = (chunk * 9) + tap

    if padded_kernel_index in [9, 18]:
        kernel_index = 0
    elif padded_kernel_index > 18:
        kernel_index = padded_kernel_index - 2
    elif padded_kernel_index > 9:
        kernel_index = padded_kernel_index - 1
    else:
        kernel_index = padded_kernel_index

    kernel_row = kernel_index % 5
    kernel_col = kernel_index // 5
    
    window = conv_output % 4
    window_row = window // 2
    window_col = window % 2

    return ((kernel_row + window_row) * 6) + kernel_col + window_col

# ==============================================================================
# Read File, Route, and Export
# ==============================================================================
def generate_mapped_files():
    in_mem = []
    stage1_weights = []
    
    # 1. READ REAL MEMORY FILES
    try:
        with open("in_mem_384.hex", "r") as f:
            for line in f:
                line = line.strip()
                if line:
                    val = int(line, 16)
                    if val >= (1 << (PIXEL_W - 1)):
                        val -= (1 << PIXEL_W)
                    in_mem.append(val)
    except FileNotFoundError:
        if len(in_mem) < 384:   
            print(f"Error: in_mem_384.hex only has {len(in_mem)} values. Needs 384.")
            sys.exit(1)

    # 2. READ REAL WEIGHTS FILE (3456 values)
    stage1_weights = []
    try:
        with open("stage1_weights_3456.hex", "r") as f:
            for line in f:
                line = line.strip()
                if line:
                    # Convert hex string back to signed integer
                    val = int(line, 16)
                    if val >= (1 << (PIXEL_W - 1)):
                        val -= (1 << PIXEL_W)
                    stage1_weights.append(val)
    except FileNotFoundError:
        print("Error: Please create 'stage1_weights_3456.hex' with 3456 weight values.")   
        sys.exit(1)

    if len(stage1_weights) < 3456:   
        print(f"Error: stage1_weights_3456.hex only has {len(stage1_weights)} values. Needs 3456.")
        sys.exit(1)

    print("Routing pixels and weights from files...")
    
    # 3. ROUTE AND WRITE TO OUTPUT FILES
    with open("mapped_pixels.hex", "w") as f_pix, open("mapped_weights.hex", "w") as f_wt:
        for gw in range(GROUPS):
            for cw in range(CHANNELS):
                for tw in range(TAPS):
                    
                    stream_idx = stage1_stream_index(gw, cw)
                    patch_idx  = stage1_patch_index(stream_idx, tw)
                    
                    pix_val = in_mem[patch_idx]
                    wt_val  = stage1_weights[(stream_idx * 9) + tw]
                    
                    f_pix.write(to_hex_18bit(pix_val) + "\n")
                    f_wt.write(to_hex_18bit(wt_val) + "\n")

    print("Success! Routed 384 pixels and 3456 weights into multiplier ports.")

if __name__ == "__main__":
    generate_mapped_files()