module mem_maping_1_2 (
    input  logic              stage_sel,
    input  logic /*[0:31]*/  shaaban_out [0:31],
    output logic /*[0:31]*/   mem_mapped  [0:3199]
);

    genvar idx;

    generate
        for (idx = 0; idx < 3200; idx = idx + 1) begin : g_idx

            // Precompute, at elaboration time, what Stage-1 source is for this idx
            localparam int S1_SRC = idx % 32;

            // Precompute whether idx falls in Stage-2's range, and what it maps to
            localparam bit S2_VALID = (idx < 1024);
            localparam int S2_MOD16 = idx % 16;
            localparam int S2_SRC   = (S2_MOD16 == 15) ? 0 :
                                       (S2_MOD16 % 3);   // 0,1,2 pattern

            always_comb begin
                if (stage_sel == 1'b0) begin
                    mem_mapped[idx] = shaaban_out[S1_SRC];
                end else begin
                    if (S2_VALID)
                        mem_mapped[idx] = shaaban_out[S2_SRC];
                    else
                        mem_mapped[idx] = '0;
                end
            end
        end
    endgenerate

endmodule