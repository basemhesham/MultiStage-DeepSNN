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

def standard_conv2d_trace():
    print("Loading Ascending Pixels and ML weights...")
    
    # 1. Load ONLY the first 36 pixels (The 6x6 Patch)
    pixels = []
    try:
        with open("in_mem_384.hex", "r") as f:
            for line in f:
                if line.strip():
                    pixels.append(to_signed(line))
    except FileNotFoundError:
        print("❌ Error: 'in_mem_384.hex' not found.")
        sys.exit(1)
        
    image_6x6 = np.array(pixels[:36], dtype=np.int64).reshape((6, 6))

    # 2. Load the Pure PyTorch Filter Weights (800 values)
    weights = []
    try:
        with open("filter_800.hex", "r") as f:
            for line in f:
                if line.strip():
                    weights.append(to_signed(line))
    except FileNotFoundError:
        print("❌ Error: 'filter_800.hex' not found. Run extract_all_weights.py first.")
        sys.exit(1)

    filters = np.array(weights, dtype=np.int64).reshape((32, 5, 5))

    print("Running Pure ML Convolution on Ascending 6x6 Patch...")

    out = np.zeros((2, 2, 32), dtype=np.int64)

    for co in range(32):             
        for h in range(2):           
            for w in range(2):       
                # Extract 5x5 window from the 6x6 patch
                patch = image_6x6[h:h+5, w:w+5]
                
                # Standard MAC accumulation
                mac_sum = int(np.sum(patch * filters[co]))
                
                # Apply Q9.9 Fixed-Point Right Shift
                mac_shifted = mac_sum >> FRAC_BITS
                
                # Wrap to 18-bit signed limits
                out[h, w, co] = wrap_18bit_signed(mac_shifted)

    # 3. Format exactly like the RTL Testbench log
    output_file = "python_standard_conv_out.txt"
    with open(output_file, "w") as f:
        f.write("--- ML MODEL OUTPUT (Formatted for RTL Comparison) ---\n\n")
        f.write("--- Cycle 000 ---\n")
        
        for ch in range(32):
            in0 = out[0, 0, ch]
            in1 = out[0, 1, ch]
            in2 = out[1, 0, ch]
            in3 = out[1, 1, ch]
            
            f.write(f"Shaaban[{ch:02d}] | In3:{in3} In2:{in2} In1:{in1} In0:{in0}\n")
                    
    print(f"✅ Success! Golden reference written to '{output_file}'")

if __name__ == "__main__":
    standard_conv2d_trace()