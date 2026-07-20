PIXEL_W = 18


def to_hex_18bit(val):
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"


def generate_full_image():
    print("Generating full 256x256 dummy image...")

    # Generate 65,536 pixels (256x256) in ascending order (0 to 65535)
    # 65535 fits perfectly inside an 18-bit signed integer.
    with open("dummy_image_256x256.hex", "w") as f_pix:
        for i in range(65536):
            f_pix.write(to_hex_18bit(i) + "\n")

    print("✅ Success! Created 'dummy_image_256x256.hex'.")


if __name__ == "__main__":
    generate_full_image()
