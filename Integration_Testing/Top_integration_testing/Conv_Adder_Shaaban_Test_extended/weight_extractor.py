import re
import os

PIXEL_W = 18

def to_hex_18bit(val):
    if val < 0:
        val = (1 << PIXEL_W) + val
    return f"{val:05x}"

def to_signed(val, bits=18):
    if val >= (1 << (bits - 1)):
        val -= (1 << bits)
    return val

def extract_weights():
    print("Extracting weights from raw files...")

    # =========================================================================
    # 1. Extract the 800 PyTorch Weights for the ML Model
    # =========================================================================
    weights_800 = []
    try:
        with open("pytorch_weights.txt", "r") as f:
            for line in f:
                line = line.strip()
                # Skip comments and empty lines
                if not line or line.startswith("#"):
                    continue
                
                # Each line has 5 chunks of 18-bit binary strings (90 chars total)
                if len(line) == 90:
                    for i in range(5):
                        chunk = line[i*18 : (i+1)*18]
                        val = int(chunk, 2)
                        weights_800.append(to_signed(val))
                        
        with open("filter_800.hex", "w") as f:
            for w in weights_800:
                f.write(to_hex_18bit(w) + "\n")
        print(f"✅ Extracted {len(weights_800)} ML weights to 'filter_800.hex'")
        
    except FileNotFoundError:
        print("❌ Error: 'pytorch_weights.txt' not found.")

    # =========================================================================
    # 2. Extract the 3456 RTL Mapped Weights for the Testbench
    # =========================================================================
    try:
        # Parse UNIQUE weights array
        unique_weights = {}
        with open("UNIQUE_CONV1_WEIGHTS.sv", "r") as f:
            content = f.read()
            # Find all 18'b... binary strings
            matches = re.findall(r"18'b([01]{18})", content)
            for idx, m in enumerate(matches):
                unique_weights[idx] = to_signed(int(m, 2))

        # Parse assignments mapping
        stage1_weights_3456 = [0] * 3456
        with open("CONV1_W_MAP_OPT.sv", "r") as f:
            for line in f:
                line = line.strip()
                if not line.startswith("assign conv9_in"):
                    continue
                
                # Extract the array index: conv9_in[15] -> 15
                idx_match = re.search(r"conv9_in\[(\d+)\]", line)
                if not idx_match: continue
                dest_idx = int(idx_match.group(1))

                # Check if it maps to a UNIQUE index or is explicitly 0
                u_match = re.search(r"UNIQUE_CONV1_WEIGHTS\[(\d+)\]", line)
                if u_match:
                    u_idx = int(u_match.group(1))
                    stage1_weights_3456[dest_idx] = unique_weights[u_idx]
                else:
                    stage1_weights_3456[dest_idx] = 0
                    
        with open("stage1_weights_3456.hex", "w") as f:
            for w in stage1_weights_3456:
                f.write(to_hex_18bit(w) + "\n")
                
        print(f"✅ Extracted {len(stage1_weights_3456)} RTL weights to 'stage1_weights_3456.hex'")
        
    except FileNotFoundError:
        print("❌ Error: Make sure 'UNIQUE_CONV1_WEIGHTS.sv' and 'CONV1_W_MAP_OPT.sv' exist.")

if __name__ == "__main__":
    extract_weights()