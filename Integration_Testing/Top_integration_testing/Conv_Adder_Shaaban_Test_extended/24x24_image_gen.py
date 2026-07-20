PIXEL_W = 18

def to_hex_18bit(val):
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

def generate_full_image():
    print("Generating full 24x24 dummy image...")
    
    # Generate 576 pixels in perfect ascending order (0 to 575)
    with open("dummy_image_576.hex", "w") as f_pix:
        for i in range(576):
            f_pix.write(to_hex_18bit(i) + "\n")
            
    print("✅ Success! Created 'dummy_image_576.hex' (24x24 grid, values 0-575).")

if __name__ == "__main__":
    generate_full_image()