`timescale 1ns / 1ps

module pixel_mem #(
    parameter int DATA_WIDTH  = 18,
    parameter int WORD_PIXELS = 384,
    parameter int ADDR_WIDTH  = 6
)(
    input  logic                                clk,
    input  logic                                rst,
    input  logic                                wr_en,
    input  logic [ADDR_WIDTH-1:0]               wr_addr,
    input  logic [(WORD_PIXELS*DATA_WIDTH)-1:0] wr_data,
    input  logic [ADDR_WIDTH-1:0]               rd_addr,
    output logic [(WORD_PIXELS*DATA_WIDTH)-1:0] rd_data
);

    localparam int WORD_WIDTH = WORD_PIXELS * DATA_WIDTH;
    localparam int DEPTH      = 1 << ADDR_WIDTH;

    (* ram_style = "block" *)
    logic [WORD_WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_data <= '0;
        end else begin
            if (wr_en) begin
                mem[wr_addr] <= wr_data;
            end

            rd_data <= mem[rd_addr];
        end
    end

endmodule
