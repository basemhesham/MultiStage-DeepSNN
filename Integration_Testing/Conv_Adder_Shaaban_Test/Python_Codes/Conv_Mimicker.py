import numpy as np
import random
import sys
import os

PIXEL_W = 18

def to_hex_18bit(val):
    """Convert a signed integer to an 18-bit 2's complement hex string."""
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

def generate_dummy_files_if_missing():
    """Generates dummy files if they don't exist, so the script works instantly."""
    if not os.path.exists("dummy_image.hex"):
        print("Generating dummy_image.hex (24x24 = 576 pixels)...")
        with open("dummy_image.hex", "w") as f:
            for _ in range(576):
                f.write(to_hex_18bit(random.randint(-50, 50)) + "\n")
                
    if not os.path.exists("dummy_filter.hex"):
        print("Generating dummy_filter.hex (5x5 = 25 weights)...")
        with open("dummy_filter.hex", "w") as f:
            for _ in range(25):
                f.write(to_hex_18bit(random.randint(-5, 5)) + "\n")

# ==============================================================================
# 1. Extracted Standard Convolution (From your SNN Framework)
# ==============================================================================
def standard_conv2d(x, weight, bias, stride=1, padding=0):
    """
    Standard 2D convolution matching the PyTorch/Numba logic.
    x: Input feature map (H, W, C_in)
    weight: Filters (kH, kW, C_in, C_out)
    bias: Biases (C_out,)
    """
    H, W, C_in = x.shape
    kH, kW, _, C_out = weight.shape

    # Apply padding if necessary
    if padding > 0:
        x_pad = np.zeros((H + 2*padding, W + 2*padding, C_in), dtype=np.int64)
        x_pad[padding:H+padding, padding:W+padding, :] = x
    else:
        x_pad = x

    Hp, Wp = x_pad.shape[0], x_pad.shape[1]
    H_out = (Hp - kH) // stride + 1
    W_out = (Wp - kW) // stride + 1
    
    # Use int64 to perfectly match hardware 40-bit/18-bit integer accumulation 
    out = np.zeros((H_out, W_out, C_out), dtype=np.int64)

    # Standard ML Sliding Window Loops
    for co in range(C_out):
        for ci in range(C_in):
            for kh in range(kH):
                for kw in range(kW):
                    w_val = weight[kh, kw, ci, co]
                    for h in range(H_out):
                        h_in = h * stride + kh
                        for w in range(W_out):
                            w_in = w * stride + kw
                            
                            # Multiply and accumulate
                            prod = x_pad[h_in, w_in, ci] * w_val
                            out[h, w, co] += prod

    # Add bias
    for co in range(C_out):
        for h in range(H_out):
            for w in range(W_out):
                out[h, w, co] += bias[co]

    return out

# ==============================================================================
# 2. Testbench Wrapper
# ==============================================================================
def run_verification():
    generate_dummy_files_if_missing()
    
    # 1. Load Data
    image_list = []
    with open("dummy_image.hex", "r") as f:
        for line in f:
            val = int(line.strip(), 16)
            if val >= (1 << (PIXEL_W - 1)):
                val -= (1 << PIXEL_W)
            image_list.append(val)
            
    filter_list = []
    with open("dummy_filter.hex", "r") as f:
        for line in f:
            val = int(line.strip(), 16)
            if val >= (1 << (PIXEL_W - 1)):
                val -= (1 << PIXEL_W)
            filter_list.append(val)

    # 2. Reshape into Standard ML Tensors (H, W, C)
    # Image is 24x24, 1 input channel
    image_tensor = np.array(image_list, dtype=np.int64).reshape((24, 24, 1))
    
    # Filter is 5x5, 1 input channel, 1 output channel 
    # (Testing a single channel here just like the SV testbench does)
    filter_tensor = np.array(filter_list, dtype=np.int64).reshape((5, 5, 1, 1))
    
    # No bias for the raw MAC test
    bias_tensor = np.zeros((1,), dtype=np.int64)

    print("Running Standard ML Convolution (24x24 image, 5x5 filter)...")
    
    # 3. Run the pure convolution
    output_feature_map = standard_conv2d(image_tensor, filter_tensor, bias_tensor, stride=1, padding=0)
    
    # Output should be 20x20
    print(f"Convolution Output Shape: {output_feature_map.shape} (Expected: 20x20x1)")

    # 4. Save to file matching RTL Testbench exact format
    output_file = "python_standard_conv_out.txt"
    with open(output_file, "w") as f:
        for r in range(20):
            # Step by 4 columns to match the 4 parallel units in hardware
            for c in range(0, 20, 4):
                out0 = output_feature_map[r, c, 0]
                out1 = output_feature_map[r, c+1, 0]
                out2 = output_feature_map[r, c+2, 0]
                out3 = output_feature_map[r, c+3, 0]
                
                cycle = (r * 5) + (c // 4)
                
                # Exact same string format as $fwrite in Verilog
                f.write(f"Cycle {cycle:03d} | Out3:{out3} Out2:{out2} Out1:{out1} Out0:{out0}\n")
                
    print(f"Success! Output written to '{output_file}'")
    print("Compare this file against 'shb_bus_output.txt' from your SystemVerilog simulation.")

if __name__ == "__main__":
    run_verification()