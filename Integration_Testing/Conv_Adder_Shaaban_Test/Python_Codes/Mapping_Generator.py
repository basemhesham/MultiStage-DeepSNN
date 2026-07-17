import random

# ==============================================================================
# Hardware Parameters (Matching top_pixel_source_mapper.sv)
# ==============================================================================
PIXEL_W = 18
GROUPS = 12       # 12 Adder Trees
CHANNELS = 32     # 32 Shaaban Units / Lanes
TAPS = 9          # 9 Taps per conv9

# 18-bit signed limits
MIN_VAL = -131072
MAX_VAL = 131071

def to_hex_18bit(val):
    """Convert a signed integer to an 18-bit 2's complement hex string."""
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

# ==============================================================================
# RTL Equivalent Mapping Functions
# ==============================================================================
def stage1_stream_index(block, lane):
    """Matches the SV function stage1_stream_index"""
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
    """Matches the SV function stage1_patch_index"""
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

    # CONV1 weights are column-major
    kernel_row = kernel_index % 5
    kernel_col = kernel_index // 5
    
    window = conv_output % 4
    window_row = window // 2
    window_col = window % 2

    return ((kernel_row + window_row) * 6) + kernel_col + window_col

# ==============================================================================
# Generate Data and Map
# ==============================================================================
def generate_stimulus():
    # 1. Create a dummy 6x6 patch (36 pixels) in the 384-word input memory
    in_mem = [random.randint(-50, 50) for _ in range(384)]
    
    # 2. Create dummy weights for Stage 1 (12 * 32 * 9 = 3456 weights)
    stage1_weights = [random.randint(-5, 5) for _ in range(3456)]

    print("Generating mapped arrays...")
    
    # Open files for writing
    with open("mapped_pixels.hex", "w") as f_pix, open("mapped_weights.hex", "w") as f_wt:
        
        # Loop exactly as the SV generate block does: [group][channel][tap]
        for gw in range(GROUPS):
            for cw in range(CHANNELS):
                for tw in range(TAPS):
                    
                    # Compute Indices
                    stream_idx = stage1_stream_index(gw, cw)
                    patch_idx  = stage1_patch_index(stream_idx, tw)
                    
                    # Extract Data
                    pix_val = in_mem[patch_idx]
                    wt_val  = stage1_weights[(stream_idx * 9) + tw]
                    
                    # Write as 5-character hex (18-bit)
                    f_pix.write(to_hex_18bit(pix_val) + "\n")
                    f_wt.write(to_hex_18bit(wt_val) + "\n")

    print("Done! Generated 'mapped_pixels.hex' and 'mapped_weights.hex'.")
    print(f"Total entries per file: {GROUPS * CHANNELS * TAPS} (Expected: 3456)")

if __name__ == "__main__":
    generate_stimulus()