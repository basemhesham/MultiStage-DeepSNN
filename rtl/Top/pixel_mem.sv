//===========================================================
// File        : pixel_mem.sv
// Purpose     : Simple dual-port, word-addressed memory for
//               storing packed pixel words. Each memory word
//               contains WORD_PIXELS pixels packed into a
//               single flattened bus. Supports synchronous
//               write, registered read (one-cycle latency),
//               and an asynchronous active-low reset.
// Used in     : top_pixel_source_mapper (supplies pixel_mem_data)
//===========================================================
// Written by  : Basem Hesham
// revised by  : Yousef Gamal
// Last edit   : 2026-07-07
// Version     : 1.0
// Edits       : memory will reset to all zeros on reset 
//===========================================================

module pixel_mem #(
    parameter int DATA_WIDTH  = 18,
    parameter int WORD_PIXELS = 384,
    parameter int ADDR_WIDTH  = 6
)
(
    input  logic                                clk     , // Clock signal
    input  logic                                rst     , // Asynchronous, active-low reset
    input  logic                                wr_en   , // Write enable
    input  logic [ADDR_WIDTH-1:0]               wr_addr , // Write address
    input  logic [(WORD_PIXELS*DATA_WIDTH)-1:0] wr_data , // Flattened write data word
    input  logic [ADDR_WIDTH-1:0]               rd_addr , // Read address
    output logic [(WORD_PIXELS*DATA_WIDTH)-1:0] rd_data   // Flattened registered read data word
);

    //-------------------------------------------------------------------------
    // internal signals
    //-------------------------------------------------------------------------
    localparam int WORD_WIDTH = WORD_PIXELS * DATA_WIDTH;  /* Total bit width of one packed memory word */
    localparam int DEPTH      = 1 << ADDR_WIDTH;           /* Number of addressable words in mem        */

    (* ram_style = "block" *)
    logic [WORD_WIDTH-1:0] mem [0:DEPTH-1]; /* Block-RAM-inferred storage array */

    //-------------------------------------------------------------------------
    // Sequential Logic - Registered Read
    //-------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst)
        begin
            if (!rst)
                begin
                    rd_data <= '0;
                end
            else
                begin
                    rd_data <= mem[rd_addr];
                end
        end
    //-------------------------------------------------------------------------
    // Sequential Logic - write operation 
    //-------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst)
        begin
            if(!rst)
                begin
                    mem <= '{default:'0};
                end
            else if (wr_en)
                begin
                    mem[wr_addr] <= wr_data;
                end
        end

endmodule
