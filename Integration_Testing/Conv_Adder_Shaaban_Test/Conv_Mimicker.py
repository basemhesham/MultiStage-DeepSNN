import numpy as np
import sys

PIXEL_W = 18
FRAC_BITS = 9  # Q9.9 Fixed point shift

def to_signed(val_hex):
    """Convert an 18-bit hex string to a signed integer."""
    val = int(val_hex.strip(), 16)
    if val >= (1 << (PIXEL_W - 1)):
        val -= (1 << PIXEL_W)
    return val

def wrap_18bit_signed(val):
    """Simulates Verilog's natural truncation to 18 bits."""
    val = val & 0x3FFFF
    if val >= 0x20000:
        val -= 0x40000
    return val

def fixed_point_shift(mac_sum):
    """
    Simulates fixed-point truncation/rounding. 
    If your RTL output is slightly higher than Python, 
    your RTL is likely doing (mac_sum + 256) >> 9.
    """
    # OPTION 1: Pure Truncation (Standard RTL >> 9)
    # return mac_sum >> FRAC_BITS 

    # OPTION 2: Round-to-nearest (Adds 0.5 before truncating)
    return (mac_sum + (1 << (FRAC_BITS - 1))) >> FRAC_BITS

def run_100_cycles():
    print("Loading 24x24 Image and ML weights...")
    
    # 1. Load the full 24x24 image (576 pixels)
    pixels = []
    try:
        with open("dummy_image_576.hex", "r") as f:
            for line in f:
                if line.strip():
                    pixels.append(to_signed(line))
    except FileNotFoundError:
        print("❌ Error: 'dummy_image_576.hex' not found. Run generate_image_576.py first.")
        sys.exit(1)
        
    image_24x24 = np.array(pixels, dtype=np.int64).reshape((24, 24))

    # 2. Load the Pure PyTorch Filter Weights (800 values)
    weights = []
    try:
        with open("filter_800.hex", "r") as f:
            for line in f:
                if line.strip():
                    weights.append(to_signed(line))
    except FileNotFoundError:
        print("❌ Error: 'filter_800.hex' not found.")
        sys.exit(1)

    filters = np.array(weights, dtype=np.int64).reshape((32, 5, 5))

    print("Running 100 Cycles of sliding window convolution...")

    output_file = "python_100_cycles_out.txt"
    with open(output_file, "w") as f:
        f.write("--- ML MODEL OUTPUT (100 Cycles) ---\n\n")
        
        cycle_num = 0
        
        # Slide vertically, 2 rows at a time (10 steps)
        for r in range(0, 20, 2):
            # Slide horizontally, 2 columns at a time (10 steps)
            for c in range(0, 20, 2):
                f.write(f"--- Cycle {cycle_num:03d} ---\n")
                
                # Calculate the 4 outputs for all 32 channels (The 2x2 Grid)
                for ch in range(32):
                    # Output 0 (Top-Left: row r, col c)
                    mac0 = int(np.sum(image_24x24[r:r+5, c:c+5] * filters[ch]))
                    # Output 1 (Top-Right: row r, col c+1)
                    mac1 = int(np.sum(image_24x24[r:r+5, c+1:c+6] * filters[ch]))
                    # Output 2 (Bottom-Left: row r+1, col c)
                    mac2 = int(np.sum(image_24x24[r+1:r+6, c:c+5] * filters[ch]))
                    # Output 3 (Bottom-Right: row r+1, col c+1)
                    mac3 = int(np.sum(image_24x24[r+1:r+6, c+1:c+6] * filters[ch]))
                    
                    # Apply Bit-Shift and Wrapping
                    in0 = wrap_18bit_signed(fixed_point_shift(mac0))
                    in1 = wrap_18bit_signed(fixed_point_shift(mac1))
                    in2 = wrap_18bit_signed(fixed_point_shift(mac2))
                    in3 = wrap_18bit_signed(fixed_point_shift(mac3))
                    
                    f.write(f"Shaaban[{ch:02d}] | In3:{in3} In2:{in2} In1:{in1} In0:{in0}\n")
                
                f.write("\n")
                cycle_num += 1
                
    print(f"✅ Success! 100-cycle reference written to '{output_file}'")

if __name__ == "__main__":
    run_100_cycles()