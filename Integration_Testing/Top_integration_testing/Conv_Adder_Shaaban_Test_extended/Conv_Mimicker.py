import numpy as np
import sys

PIXEL_W = 18


def to_signed(val_hex):
    val = int(val_hex.strip(), 16)
    if val >= (1 << (PIXEL_W - 1)):
        val -= (1 << PIXEL_W)
    return val


def run_256_conv():
    print("Loading 256x256 Image and 800 Weights...")

    try:
        with open("dummy_image_256x256.hex", "r") as f:
            pixels = [to_signed(line) for line in f if line.strip()]
    except FileNotFoundError:
        print("❌ Error: 'dummy_image_256x256.hex' not found.")
        sys.exit(1)

    try:
        with open("filter_800.hex", "r") as f:
            weights = [to_signed(line) for line in f if line.strip()]
    except FileNotFoundError:
        print("❌ Error: 'filter_800.hex' not found.")
        sys.exit(1)

    # Reshape to 256x256
    image_256 = np.array(pixels, dtype=np.int64).reshape((256, 256))

    # Pad with 2 rows/cols of zeros on all sides -> (260, 260)
    image_padded = np.pad(image_256, pad_width=2,
                          mode='constant', constant_values=0)

    filters = np.array(weights, dtype=np.int64).reshape((32, 5, 5))

    print("Running Pure ML Convolution on 260x260 padded image...")
    out = np.zeros((32, 256, 256), dtype=np.int64)

    for co in range(32):
        for h in range(256):
            for w in range(256):
                # Standard MAC accumulation (No Q9.9 shift here, raw math)
                out[co, h, w] = np.sum(
                    image_padded[h:h+5, w:w+5] * filters[co])

    output_file = "ml_conv_stg_1.txt"
    with open(output_file, "w") as f:
        for c in range(32):
            f.write(f"--- Channel {c:02d} ---\n")
            for h in range(256):
                row_str = " ".join([str(val) for val in out[c, h, :]])
                f.write(row_str + "\n")

    print(f"✅ Success! Pure Numpy reference written to '{output_file}'")


if __name__ == "__main__":
    run_256_conv()
