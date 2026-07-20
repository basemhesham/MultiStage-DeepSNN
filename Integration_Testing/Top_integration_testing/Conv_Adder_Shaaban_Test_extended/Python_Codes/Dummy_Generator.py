import random

PIXEL_W = 18

def to_hex_18bit(val):
    """Convert a signed integer to an 18-bit 2's complement hex string."""
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

def generate_raw_inputs():
    print("Generating raw dummy input files...")
    
    # 1. Generate 384 pixels
    with open("in_mem_384.hex", "w") as f_pix:
        for _ in range(384):
            val = random.randint(-50, 50)
            f_pix.write(to_hex_18bit(val) + "\n")
            
    # 2. Generate 3456 weights
    with open("stage1_weights_3456.hex", "w") as f_wt:
        for _ in range(3456):
            val = random.randint(-5, 5)
            f_wt.write(to_hex_18bit(val) + "\n")
            
    print("Success! Created 'in_mem_384.hex' and 'stage1_weights_3456.hex'.")

if __name__ == "__main__":
    generate_raw_inputs()