// ---------------------------------------------------------------------------
// BRAM_LIF_Mem_0 - plain behavioral Verilog replacement for the Xilinx
// blk_mem_gen_v8_4_1 IP instance (BRAM_LIF_Mem_0.vhd).
//
// True dual-port RAM, 18-bit wide, 16384 deep (14-bit address).
//   Port A : read + write (NO_CHANGE mode -> douta not modeled/needed here,
//            since the original wrapper never used douta downstream)
//   Port B : read only (web is tied to 0 in the original wrapper), but
//            modeled here as WRITE_FIRST to match C_WRITE_MODE_B exactly,
//            in case a write is ever driven on port B.
//
// No Vivado IP, no instantiation, no simulation library dependency -
// synthesizable and QuestaSim-simulatable as-is.
// ---------------------------------------------------------------------------

module BRAM_LIF_Mem_0 #(
    parameter DATA_WIDTH = 18,
    parameter ADDR_WIDTH = 14,
    parameter DEPTH      = 16384
)(
    // Port A - write/read
    input  wire                    clka,
    input  wire                    ena,
    input  wire                    wea,
    input  wire [ADDR_WIDTH-1:0]   addra,
    input  wire [DATA_WIDTH-1:0]   dina,

    // Port B - read (write-capable, WRITE_FIRST, for parity with the IP)
    input  wire                    clkb,
    input  wire                    enb,
    input  wire                    web,
    input  wire [ADDR_WIDTH-1:0]   addrb,
    input  wire [DATA_WIDTH-1:0]   dinb,
    output reg  [DATA_WIDTH-1:0]   doutb
);

    // Shared memory array
    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    // Optional init (uncomment / point at a .mem file if you need to
    // preload it, mirroring C_INIT_FILE from the original IP config)
    // initial begin
    //     $readmemh("BRAM_LIF_Mem_0.mem", ram);
    // end

    // -----------------------------------------------------------------
    // Port A : NO_CHANGE write mode -> output register (not exposed on
    // this port in the original wrapper) simply holds; only the memory
    // array is updated on a write.
    // -----------------------------------------------------------------
    always @(posedge clka) begin
        if (ena) begin
            if (wea) begin
                ram[addra] <= dina;
            end
        end
    end

    // -----------------------------------------------------------------
    // Port B : WRITE_FIRST -> if a write happens this cycle, doutb sees
    // the new data immediately; otherwise doutb reflects the current
    // contents at addrb.
    // -----------------------------------------------------------------
    always @(posedge clkb) begin
        if (enb) begin
            if (web) begin
                ram[addrb] <= dinb;
                doutb      <= dinb;
            end else begin
                doutb <= ram[addrb];
            end
        end
    end

endmodule
