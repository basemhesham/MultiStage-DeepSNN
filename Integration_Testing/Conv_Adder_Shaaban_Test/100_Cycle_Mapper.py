import sys
import numpy as np

PIXEL_W = 18
GROUPS = 12       
CHANNELS = 32     
TAPS = 9          

def to_hex_18bit(val):
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

def to_signed(val_hex):
    val = int(val_hex.strip(), 16)
    if val >= (1 << (PIXEL_W - 1)):
        val -= (1 << PIXEL_W)
    return val

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

def generate_100_cycle_maps():
    print("Loading 24x24 Image and 3456 Weights...")
    
    pixels = []
    try:
        with open("dummy_image_576.hex", "r") as f:
            for line in f:
                if line.strip():
                    pixels.append(to_signed(line))
    except FileNotFoundError:
        print("Error: 'dummy_image_576.hex' not found.")
        sys.exit(1)
        
    image_24x24 = np.array(pixels, dtype=np.int64).reshape((24, 24))

    stage1_weights = []
    try:
        with open("stage1_weights_3456.hex", "r") as f:
            for line in f:
                if line.strip():
                    stage1_weights.append(to_signed(line))
    except FileNotFoundError:
        print("Error: 'stage1_weights_3456.hex' not found.")
        sys.exit(1)

    print("Simulating Mapping Controller (100 Cycles)...")
    
    with open("mapped_weights.hex", "w") as f_wt:
        for gw in range(GROUPS):
            for cw in range(CHANNELS):
                for tw in range(TAPS):
                    stream_idx = stage1_stream_index(gw, cw)
                    wt_val = stage1_weights[(stream_idx * 9) + tw]
                    f_wt.write(to_hex_18bit(wt_val) + "\n")

    with open("mapped_pixels_100_cycles.hex", "w") as f_pix:
        # Slide vertically, 2 rows at a time
        for r in range(0, 20, 2):
            # Slide horizontally, 2 columns at a time
            for c in range(0, 20, 2):
                
                # Extract the 6x6 patch from the main image
                patch_6x6 = image_24x24[r:r+6, c:c+6].flatten()
                
                # Route the 36 pixels into the 3456 multiplier lanes
                for gw in range(GROUPS):
                    for cw in range(CHANNELS):
                        for tw in range(TAPS):
                            stream_idx = stage1_stream_index(gw, cw)
                            patch_idx  = stage1_patch_index(stream_idx, tw)
                            
                            pix_val = patch_6x6[patch_idx]
                            f_pix.write(to_hex_18bit(pix_val) + "\n")

    print("✅ Success! Wrote 3456 mapped weights and 345,600 mapped pixels.")

if __name__ == "__main__":
    generate_100_cycle_maps()