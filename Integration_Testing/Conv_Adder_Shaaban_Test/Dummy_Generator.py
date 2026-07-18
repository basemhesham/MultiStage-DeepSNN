PIXEL_W = 18

def to_hex_18bit(val):
    """Convert a signed integer to an 18-bit 2's complement hex string."""
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

def generate_raw_inputs():
    print("Generating raw ascending pixel file...")
    
    # Generate 384 pixels in ascending order (0 to 383)
    with open("in_mem_384.hex", "w") as f_pix:
        for i in range(384):
            f_pix.write(to_hex_18bit(i) + "\n")
            
    print("Success! Created 'in_mem_384.hex' with values 0 to 383.")

if __name__ == "__main__":
    generate_raw_inputs()