//===========================================================
// File        : top_spike_writeback.sv
// Purpose     : provide the mapped data to the spike memory
// Used in     : <parent module / top level that instantiates this>
//===========================================================
// Written by  : <name>
// Editor      : <Hany>
// Last edit   : <2026-07-07>
//===========================================================

`timescale 1ns / 1ps

module top_spike_writeback (
    //=======================================================
    // Controls
    //=======================================================
    input  logic [1:0]  stage,
    //=======================================================
    // Inputs
    //=======================================================
    input  wire logic /*[0:31]*/ shaaban_spike_bus [0:31],
    //=======================================================
    // Outputs
    //=======================================================
    output logic [3199:0] spike_mem_wr_data
);
    //=======================================================
    // Internals
    //=======================================================
    logic /*[0:31]*/ mem_mapped_internal [0:3199];

    mem_maping_1_2 u_writeback (
        .stage_sel   (stage[0]),
        .shaaban_out (shaaban_spike_bus),
        .mem_mapped  (mem_mapped_internal)
    );

    genvar wb;
    generate
        for (wb = 0; wb < 3200; wb++) begin : gen_spike_mem_wr_data
            always_comb begin
                if (stage == 2'b10)
                    // ==============================================================
                    // STAGE 3: take the output of Shaaban unit (Bus0) for that stage
                    // ==============================================================
                    spike_mem_wr_data[wb] = shaaban_spike_bus[0];
                else
                    // ==============================================================
                    // STAGE 1/2: take the mapped data from mem_mapping_1_2
                    // ==============================================================
                    spike_mem_wr_data[wb] = mem_mapped_internal[wb];
            end
        end
    endgenerate

endmodule
