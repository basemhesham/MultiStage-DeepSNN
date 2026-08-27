//===========================================================
// File        : fc1_layer.sv
// Purpose     : Fully-connected layer 1: 128 inputs -> 256 outputs + ReLU.
//               8 parallel MAC lanes, time-multiplexed dot-product across
//               32 batches. Q_.9 fixed-point. Weight deduplication: 9-bit
//               MAP indices in 8 BRAM36 (4Kx9 each) point into a 375-value
//               combinational LUT ROM. 1-cycle BRAM pipeline: 129 cycles
//               per batch, 4,128 cycles total per full layer pass.
// Used in     : top-level inference pipeline (feeds fc2_layer / next stage)
//===========================================================
// Written by  : Ahmad Khattab
// Revised by  : Eman Yasser
// Last edit   : 2026-07-31
//===========================================================

`ifndef FC1_LAYER_SV
`define FC1_LAYER_SV

module fc1_layer
#(
    parameter int DATA_WIDTH     = 18,   // activation / weight / bias width, Q_.FRAC_BITS
    parameter int FRAC_BITS      = 9,    // number of fractional bits in the fixed-point format
    parameter int N_INPUTS       = 128,  // number of input activations to this layer
    parameter int N_OUTPUTS      = 256,  // number of output neurons in this layer
    parameter int ACCUM_WIDTH    = 48,   // MAC accumulator width
    parameter int PARALLEL_MACS  = 8     // number of physical MAC lanes built in hardware
)
(
    //=======================================================
    // Controls
    //=======================================================
    input  wire logic                      clk,
    input  wire logic                      arst_n,      
    input  wire logic                      start,    
    //=======================================================
    // Inputs
    //=======================================================
    input  wire signed [DATA_WIDTH-1:0]    fc_in  [0:N_INPUTS-1],
    //=======================================================
    // Outputs
    //=======================================================
    output reg   signed [DATA_WIDTH-1:0]   fc_out [0:N_OUTPUTS-1],  
    output reg                             done,                    
    output reg                             busy                     
);

    //=======================================================
    // Weight Codebook
    //=======================================================
    // 375 distinct weight values used across the whole layer
    `include "UNIQUE_FC1_W.svh"

    //=======================================================
    // Local Parameters
    //=======================================================
    localparam int EXT_BITS = ACCUM_WIDTH - (2 * DATA_WIDTH); // 48 - 36 = 12 bits

    // Biases - one per OUTPUT NEURON (256 total)
    localparam logic signed [DATA_WIDTH-1:0] FC1_BIAS [N_OUTPUTS] = '{
        18'h3FFE7, 18'h00000, 18'h0001F, 18'h0001B, 18'h00007, 18'h3FFFF, 18'h0001F,
        18'h00000, 18'h00000, 18'h00019, 18'h0001F, 18'h3FFFF, 18'h00013, 18'h3FFDB,
        18'h00040, 18'h00000, 18'h0002D, 18'h00000, 18'h00005, 18'h00002, 18'h3FFF6,
        18'h3FFF5, 18'h00000, 18'h00026, 18'h00016, 18'h3FFE8, 18'h00000, 18'h00000,
        18'h00000, 18'h0000C, 18'h00011, 18'h00002, 18'h3FFED, 18'h00000, 18'h3FFF7,
        18'h00000, 18'h3FFED, 18'h3FFEC, 18'h00018, 18'h3FFFE, 18'h0000F, 18'h00000,
        18'h0002A, 18'h00000, 18'h3FFFB, 18'h3FFFF, 18'h3FFE9, 18'h00024, 18'h3FFE8,
        18'h00000, 18'h00014, 18'h3FFE9, 18'h3FFE9, 18'h3FFDC, 18'h00002, 18'h00000,
        18'h3FFF0, 18'h00018, 18'h3FFFA, 18'h00000, 18'h3FFFA, 18'h00009, 18'h00000,
        18'h00000, 18'h00010, 18'h00018, 18'h00000, 18'h3FFE8, 18'h00001, 18'h00000,
        18'h3FFE0, 18'h00022, 18'h3FFF7, 18'h00035, 18'h00000, 18'h00000, 18'h3FFEE,
        18'h00000, 18'h00000, 18'h0002F, 18'h3FFEB, 18'h3FFFA, 18'h00000, 18'h00012,
        18'h3FFDF, 18'h3FFFF, 18'h00000, 18'h3FFE2, 18'h00004, 18'h00000, 18'h0002B,
        18'h0000F, 18'h00019, 18'h0001A, 18'h00013, 18'h00000, 18'h00016, 18'h00000,
        18'h00041, 18'h3FFED, 18'h3FFFC, 18'h00000, 18'h00000, 18'h3FFFB, 18'h3FFE6,
        18'h0001B, 18'h3FFFD, 18'h0001A, 18'h3FFFC, 18'h00000, 18'h3FFD5, 18'h3FFEA,
        18'h00000, 18'h3FFE1, 18'h00006, 18'h00000, 18'h3FFEB, 18'h3FFED, 18'h00022,
        18'h0000D, 18'h00009, 18'h3FFEA, 18'h3FFE7, 18'h3FFE9, 18'h00002, 18'h00000,
        18'h0000C, 18'h3FFF6, 18'h3FFFF, 18'h3FFE9, 18'h3FFFD, 18'h00006, 18'h00018,
        18'h00000, 18'h3FFF4, 18'h0000A, 18'h3FFF3, 18'h00007, 18'h3FFFF, 18'h00000,
        18'h00000, 18'h3FFE3, 18'h3FFF6, 18'h3FFFC, 18'h3FFF6, 18'h00000, 18'h00027,
        18'h00003, 18'h0000A, 18'h0000B, 18'h00001, 18'h00000, 18'h00000, 18'h00008,
        18'h3FFDC, 18'h3FFF6, 18'h00000, 18'h00022, 18'h00000, 18'h00023, 18'h3FFEA,
        18'h3FFE0, 18'h3FFE1, 18'h00012, 18'h3FFF7, 18'h0001B, 18'h3FFE7, 18'h00017,
        18'h00000, 18'h00000, 18'h00007, 18'h00014, 18'h3FFE0, 18'h0000B, 18'h3FFFA,
        18'h3FFFE, 18'h3FFF4, 18'h00000, 18'h0000C, 18'h0000C, 18'h0001E, 18'h00014,
        18'h0001C, 18'h3FFF4, 18'h00000, 18'h3FFE5, 18'h3FFFC, 18'h00031, 18'h3FFE2,
        18'h3FFDC, 18'h00034, 18'h3FFE5, 18'h0000A, 18'h3FFFF, 18'h00000, 18'h3FFFD,
        18'h3FFF6, 18'h00027, 18'h00000, 18'h00010, 18'h00017, 18'h0000C, 18'h00000,
        18'h3FFF1, 18'h00000, 18'h3FFF1, 18'h3FFFD, 18'h00000, 18'h3FFFE, 18'h3FFDB,
        18'h0001E, 18'h00005, 18'h3FFFC, 18'h3FFFC, 18'h3FFFD, 18'h00000, 18'h00010,
        18'h3FFCC, 18'h0001A, 18'h3FFDF, 18'h00016, 18'h00006, 18'h3FFED, 18'h00000,
        18'h3FFCD, 18'h00000, 18'h00028, 18'h3FFFF, 18'h0001C, 18'h00017, 18'h3FFEE,
        18'h0000A, 18'h0000B, 18'h0000A, 18'h0000D, 18'h3FFE5, 18'h0001B, 18'h00035,
        18'h00003, 18'h00007, 18'h0002C, 18'h00000, 18'h0001F, 18'h0000D, 18'h0000A,
        18'h3FFE1, 18'h00015, 18'h00000, 18'h0000F, 18'h0002A, 18'h3FFFF, 18'h00002,
        18'h00006, 18'h00005, 18'h00000, 18'h3FFF6
    };

    // BRAM / batching sizing.
    localparam int MAP_BITS      = 9;
    localparam int BRAM_DEPTH    = N_INPUTS * (N_OUTPUTS / PARALLEL_MACS);  // 4096
    localparam int NUM_BATCHES   = N_OUTPUTS / PARALLEL_MACS;               // 32
    localparam int BATCH_BITS    = $clog2(NUM_BATCHES);                     // bits to count 0..31
    localparam int BATCH_CYCLES  = N_INPUTS + 1;                            // 129
    localparam int CYCLE_BITS    = $clog2(BATCH_CYCLES);                    // bits to count 0..128
    localparam int INPUT_BITS    = $clog2(N_INPUTS);                        // bits to index 0..127

    //=======================================================
    // Internals
    //=======================================================
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_0 [0:BRAM_DEPTH-1];
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_1 [0:BRAM_DEPTH-1];
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_2 [0:BRAM_DEPTH-1];
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_3 [0:BRAM_DEPTH-1];
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_4 [0:BRAM_DEPTH-1];
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_5 [0:BRAM_DEPTH-1];
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_6 [0:BRAM_DEPTH-1];
    (* ram_style = "block" *) logic [MAP_BITS-1:0] fc1_map_bram_7 [0:BRAM_DEPTH-1];

    //=======================================================
    // FSM
    //=======================================================
    typedef enum logic [1:0] {
        ST_IDLE, ST_COMPUTE, ST_DONE
    } state_t;
    state_t state, next_state;

    // Counters / control bits.
    logic [BATCH_BITS-1:0]          batch_idx;             
    logic [CYCLE_BITS-1:0]          input_idx;             
    logic                           batch_done;            
    logic                           compute_active;        
    logic [$clog2(N_OUTPUTS)-1:0]   completed_batch_base;  

    // Pipeline registers.
    logic signed [DATA_WIDTH-1:0]   in_val_d1;                     
    logic [MAP_BITS-1:0]            map_idx  [0:PARALLEL_MACS-1];  
    logic signed [ACCUM_WIDTH-1:0]  acc_mac  [0:PARALLEL_MACS-1];  

    // Continuous nets.
    wire logic [11:0]                      bram_addr;     
    wire logic [$clog2(N_OUTPUTS)-1:0]     neuron_base;   
    wire logic signed [DATA_WIDTH-1:0]     in_val;        
    wire logic signed [DATA_WIDTH-1:0]     weight   [0:PARALLEL_MACS-1];  
    wire logic signed [2*DATA_WIDTH-1:0]   product  [0:PARALLEL_MACS-1];  

    assign neuron_base = batch_idx * PARALLEL_MACS;                 
    assign bram_addr   = {batch_idx, input_idx[INPUT_BITS-1:0]};    
    assign in_val      = fc_in[input_idx[INPUT_BITS-1:0]];          

    //=======================================================
    // weight_lookup
    //=======================================================
    generate
        for (genvar m = 0; m < PARALLEL_MACS; m++) begin : gen_weight_lookup
            assign weight[m] = UNIQUE_FC1_W[map_idx[m]];
        end
    endgenerate

    //=======================================================
    // product_compute
    //=======================================================
    generate
        for (genvar m = 0; m < PARALLEL_MACS; m++) begin : gen_product
            assign product[m] = in_val_d1 * weight[m];
        end
    endgenerate

    //=======================================================
    // fsm_state_register
    //=======================================================
    always_ff @(posedge clk or negedge arst_n)
    begin
        if (~arst_n)
            state <= ST_IDLE;
        else
            state <= next_state;
    end

    //=======================================================
    // fsm_next_state
    //=======================================================
    always_comb
    begin
        next_state = state;   

        case (state)
            ST_IDLE:
                if (start)
                    next_state = ST_COMPUTE;

            ST_COMPUTE:
                if (batch_done && !compute_active)
                    next_state = ST_DONE;

            ST_DONE:
                next_state = ST_IDLE;

            default:
                next_state = ST_IDLE;
        endcase
    end

    //=======================================================
    // datapath_control
    //=======================================================
    always_ff @(posedge clk or negedge arst_n)
    begin
        if (~arst_n)
        begin
            batch_idx             <= '0;
            input_idx             <= '0;
            batch_done            <= 1'b0;
            compute_active        <= 1'b0;
            completed_batch_base  <= '0;
            busy                  <= 1'b0;
            done                  <= 1'b0;
            in_val_d1             <= '0;
        end
        else
        begin
            done       <= 1'b0;
            batch_done <= 1'b0;

            case (state)
                ST_IDLE:
                begin
                    busy <= 1'b0;
                    if (start)
                    begin
                        batch_idx      <= '0;
                        input_idx      <= '0;
                        compute_active <= 1'b1;
                        busy           <= 1'b1;
                        in_val_d1      <= '0;
                    end
                end

                ST_COMPUTE:
                begin
                    busy <= 1'b1;

                    if (compute_active && input_idx < N_INPUTS)
                        in_val_d1 <= fc_in[input_idx[INPUT_BITS-1:0]];

                    if (compute_active)
                    begin
                        if (input_idx == BATCH_CYCLES - 1)
                        begin
                            completed_batch_base <= batch_idx * PARALLEL_MACS;
                            input_idx            <= '0;   
                            in_val_d1            <= '0;

                            if (batch_idx == NUM_BATCHES - 1)
                            begin
                                compute_active <= 1'b0;
                                batch_done     <= 1'b1;
                            end
                            else
                            begin
                                batch_idx  <= batch_idx + 1'b1;
                                batch_done <= 1'b1; // Fixed syntax error
                            end
                        end
                        else
                        begin
                            input_idx <= input_idx + 1'b1;
                        end
                    end
                end

                ST_DONE:
                begin
                    done <= 1'b1;   
                    busy <= 1'b0;
                end

                default: ;
            endcase
        end
    end

    //=======================================================
    // bram_read_stage
    //=======================================================
    always_ff @(posedge clk or negedge arst_n)
    begin
        if (~arst_n)
        begin
            map_idx[0] <= '0;
            map_idx[1] <= '0;
            map_idx[2] <= '0;
            map_idx[3] <= '0;
            map_idx[4] <= '0;
            map_idx[5] <= '0;
            map_idx[6] <= '0;
            map_idx[7] <= '0;
        end
        else if (state == ST_IDLE && start)
        begin
            map_idx[0] <= '0;
            map_idx[1] <= '0;
            map_idx[2] <= '0;
            map_idx[3] <= '0;
            map_idx[4] <= '0;
            map_idx[5] <= '0;
            map_idx[6] <= '0;
            map_idx[7] <= '0;
        end
        else if (state == ST_COMPUTE && compute_active && input_idx < N_INPUTS)
        begin
            map_idx[0] <= fc1_map_bram_0[bram_addr];
            map_idx[1] <= fc1_map_bram_1[bram_addr];
            map_idx[2] <= fc1_map_bram_2[bram_addr];
            map_idx[3] <= fc1_map_bram_3[bram_addr];
            map_idx[4] <= fc1_map_bram_4[bram_addr];
            map_idx[5] <= fc1_map_bram_5[bram_addr];
            map_idx[6] <= fc1_map_bram_6[bram_addr];
            map_idx[7] <= fc1_map_bram_7[bram_addr];
        end
    end

    //=======================================================
    // mac_accumulate_stage (Explicit Signed Extension)
    //=======================================================
    generate
        for (genvar lane = 0; lane < PARALLEL_MACS; lane++) begin : gen_mac_acc
            // Explicitly sign-extend 36-bit product to 48-bit to eliminate operand mismatch warnings
            wire logic signed [ACCUM_WIDTH-1:0] product_ext;
            assign product_ext = $signed({{EXT_BITS{product[lane][2*DATA_WIDTH-1]}}, product[lane]});

            always_ff @(posedge clk or negedge arst_n) begin
                if (~arst_n) begin
                    acc_mac[lane] <= '0;
                end
                else if (state == ST_IDLE && start) begin
                    acc_mac[lane] <= '0;
                end
                else if (state == ST_COMPUTE && compute_active && input_idx >= 1) begin
                    if (input_idx == 1)
                        acc_mac[lane] <= product_ext;
                    else
                        acc_mac[lane] <= acc_mac[lane] + product_ext;
                end
            end
        end
    endgenerate

    //=======================================================
    // batch_complete_stage (Lint-Clean Bit Alignment)
    //=======================================================
    logic signed [ACCUM_WIDTH-1:0] bias_wide    [0:PARALLEL_MACS-1];
    logic signed [ACCUM_WIDTH-1:0] bias_aligned [0:PARALLEL_MACS-1];
    logic signed [ACCUM_WIDTH-1:0] total_val    [0:PARALLEL_MACS-1];
    logic signed [DATA_WIDTH-1:0]  res_val      [0:PARALLEL_MACS-1];

    generate
        for (genvar lane = 0; lane < PARALLEL_MACS; lane++) begin : gen_lane_calc
            wire [$clog2(N_OUTPUTS)-1:0] neuron_idx = completed_batch_base + lane;

            // 1. Explicit type width cast (18-bit signed -> 48-bit signed)
            assign bias_wide[lane]    = ACCUM_WIDTH'($signed(FC1_BIAS[neuron_idx]));
            
            // 2. Pure static bit-concatenation instead of shift operator <<< FRAC_BITS
            assign bias_aligned[lane] = $signed({bias_wide[lane][ACCUM_WIDTH-1-FRAC_BITS:0], {FRAC_BITS{1'b0}}});
            
            // 3. 48-bit accumulator addition
            assign total_val[lane]    = acc_mac[lane] + bias_aligned[lane];
            
            // 4. Exact bit-slicing (extracts exact 18-bit signed result window)
            assign res_val[lane]      = $signed(total_val[lane][FRAC_BITS + DATA_WIDTH - 1 : FRAC_BITS]);
        end
    endgenerate

    //=======================================================
    // fc_out writeback with ReLU activation
    //=======================================================
    generate
        for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_fc_out
            localparam int LANE = o % PARALLEL_MACS;

            always_ff @(posedge clk or negedge arst_n) begin
                if (~arst_n) begin
                    fc_out[o] <= '0;
                end
                else if ((state == ST_COMPUTE || state == ST_DONE) && batch_done && (completed_batch_base + LANE == o)) begin
                    if (res_val[LANE] < 0)
                        fc_out[o] <= '0;  // ReLU clamp
                    else
                        fc_out[o] <= res_val[LANE];
                end
            end
        end
    endgenerate

    //=======================================================
    // weight_bram_init
    //=======================================================
    initial begin
        $readmemh("fc1_map_bram_0.mem", fc1_map_bram_0);
        $readmemh("fc1_map_bram_1.mem", fc1_map_bram_1);
        $readmemh("fc1_map_bram_2.mem", fc1_map_bram_2);
        $readmemh("fc1_map_bram_3.mem", fc1_map_bram_3);
        $readmemh("fc1_map_bram_4.mem", fc1_map_bram_4);
        $readmemh("fc1_map_bram_5.mem", fc1_map_bram_5);
        $readmemh("fc1_map_bram_6.mem", fc1_map_bram_6);
        $readmemh("fc1_map_bram_7.mem", fc1_map_bram_7);
    end

endmodule

`endif // FC1_LAYER_SV