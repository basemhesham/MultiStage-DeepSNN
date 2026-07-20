import os

def format_binary_to_spaced(input_filename, output_filename, chunk_size=18):
    """
    Reads a file containing concatenated binary strings and outputs a new file
    where the binary strings are separated by spaces every `chunk_size` bits.
    """
    if not os.path.exists(input_filename):
        print(f"[-] Error: '{input_filename}' not found in the current directory.")
        return

    print(f"[*] Processing '{input_filename}'...")
    
    with open(input_filename, 'r') as f_in, open(output_filename, 'w') as f_out:
        lines_processed = 0
        for line in f_in:
            line = line.strip()
            
            # Skip comments and empty lines
            if not line or line.startswith('#'):
                continue
            
            # Split the continuous binary string into chunks of 18 bits
            chunks = [line[i:i+chunk_size] for i in range(0, len(line), chunk_size)]
            
            # Join the chunks with a single space and write to the output file
            f_out.write(" ".join(chunks) + "\n")
            lines_processed += 1
            
    print(f"[+] Success! Formatted {lines_processed} lines into '{output_filename}'.\n")

if __name__ == "__main__":
    print("==================================================")
    print(" Deep-SNN Testbench Binary Formatter ")
    print("==================================================\n")
    
    # 1. Process the 256x256 Image File
    # input_t0.bin has 256 lines, each with 256 * 18 = 4608 characters
    format_binary_to_spaced(
        input_filename="input_t0.bin", 
        output_filename="image_spaced.txt"
    )
    
    # 2. Process the Stage 1 Convolution Weights
    # w_conv1_weight.bin has 160 lines, each with 5 * 18 = 90 characters
    format_binary_to_spaced(
        input_filename="w_conv1_weight.bin", 
        output_filename="w_conv1_weight_spaced.txt"
    )
    
    print("All files are ready for SystemVerilog $readmemb!")