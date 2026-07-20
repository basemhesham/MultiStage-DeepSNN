module mem_maping_1_2 (
    input  logic         stage_sel,
    input  logic /*[0:31]*/  shaaban_out [0:31],
    output logic /*[0:31]*/  mem_mapped [0:3199]
);

    logic [11:0] i, j, n, k;
    logic [11:0] idx;   // 12 bits covers 0..3199

    always_comb begin
        mem_mapped = '{default: 0};

        case (stage_sel)
            // ==============================================================
            // STAGE 1
            // ==============================================================
            1'b0: begin
                // Loops 100 times to map blocks of 32 words
                for (i = 0; i < 100; i = i + 1) begin
                    for (j = 0; j < 32; j = j + 1) begin
                        idx = (i * 32) + j;
                        mem_mapped[idx] = shaaban_out[j];
                    end
                end
            end

            // ==============================================================
            // STAGE 2: Implements the 16-location pattern, repeated 64 times
            //          Total elements affected: 16 * 64 = 1024 memory cells.
            // ==============================================================
            1'b1: begin
                for (n = 0; n < 64; n = n + 1) begin
                    // 1. Loop 5 times to handle the 3-element sequences (Yellow, Green, Purple, Red, Blue)
                    // Each iteration of k handles a group of 3 memory cells.
                    for (k = 0; k < 5; k = k + 1) begin
                        mem_mapped[(n * 16) + (k * 3) + 0] = shaaban_out[0]; // Location 1, 4, 7, 10, 13
                        mem_mapped[(n * 16) + (k * 3) + 1] = shaaban_out[1]; // Location 2, 5, 8, 11, 14
                        mem_mapped[(n * 16) + (k * 3) + 2] = shaaban_out[2]; // Location 3, 6, 9, 12, 15
                    end

                    // 2. Map the 16th memory location (Grey) using the 6th word from input array
                    mem_mapped[(n * 16) + 15] = shaaban_out[0];
                end
            end

        endcase
    end

endmodule
