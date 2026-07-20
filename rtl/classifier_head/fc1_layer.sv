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
// Last edit   : 2026-07-06
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

    //   BRAM / batching sizing.
    //   MAP_BITS      : width of one map index (pointer into the 375-entry
    //                   weight codebook). 9 bits because 2^9 = 512 >= 375.
    //   BRAM_DEPTH    : map indices ONE lane's BRAM must hold = inputs x
    //                   batches = 128 x 32 = 4096. Unrelated to the "375
    //                   unique weights" figure - this is an access-pattern
    //                   count, split evenly across all 8 lanes
    //                   (8 x 4096 = 32768 = 128 x 256 total connections).
    //   NUM_BATCHES   : outputs computed 8 at a time (1 per lane)
    //                   -> 256 / 8 = 32 rounds.
    //   BATCH_CYCLES  : 1 setup cycle (BRAM read only, no math yet)
    //                   + 128 cycles (one per input, pipelined) = 129.
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
    //   Map-index BRAMs - 8 separate memories, one per MAC lane.
    //   Each BRAM: 4096 entries x 9 bits -> fits exactly into one Xilinx
    //   BRAM36 tile, Simple-Dual-Port, 4K x 9 mode.
    //   Lane m stores the map indices for neurons {m, m+8, m+16, ..., m+248}
    //   (every 8th neuron, offset by lane number) across every input and batch.
    //   Address = {batch_idx (5b), input_idx (7b)} = 12 bits -> 4096 addresses.
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
    //   ST_IDLE    -> waits for start
    //   ST_COMPUTE -> runs all 32 batches (128 inputs each), 32 x 129 = 4128 cycles
    //   ST_DONE    -> exactly 1 cycle, pulses done, then returns to ST_IDLE
    typedef enum logic [1:0] {
        ST_IDLE, ST_COMPUTE, ST_DONE
    } state_t;
    state_t state, next_state;

    // Counters / control bits.
    logic [BATCH_BITS-1:0]          batch_idx;             // which batch (0..31) is running now
    logic [CYCLE_BITS-1:0]          input_idx;             // cycle-within-batch counter (0..128)
    logic                           batch_done;            // 1-cycle pulse: a batch just finished
    logic                           compute_active;        // 1 while batches are still running
    logic [$clog2(N_OUTPUTS)-1:0]   completed_batch_base;  // neuron index base of the batch that just finished

    // Pipeline registers.
    logic signed [DATA_WIDTH-1:0]   in_val_d1;                     // fc_in delayed 1 cycle to align with BRAM read latency
    logic [MAP_BITS-1:0]            map_idx  [0:PARALLEL_MACS-1];  // registered BRAM output (per lane)
    logic signed [ACCUM_WIDTH-1:0]  acc_mac  [0:PARALLEL_MACS-1];  // running dot-product sum (per lane)

    // Continuous nets.
    wire logic [11:0]                      bram_addr;     // 12-bit BRAM address {batch_idx, input_idx}
    wire logic [$clog2(N_OUTPUTS)-1:0]     neuron_base;   // first neuron index of current batch
    wire logic signed [DATA_WIDTH-1:0]     in_val;        // current (undelayed) input value
    wire logic signed [DATA_WIDTH-1:0]     weight   [0:PARALLEL_MACS-1];  // weight looked up from codebook
    wire logic signed [2*DATA_WIDTH-1:0]   product  [0:PARALLEL_MACS-1];  // in_val_d1 * weight (18b*18b=36b)

    assign neuron_base = batch_idx * PARALLEL_MACS;                 // e.g. batch 3 -> neuron 24
    assign bram_addr   = {batch_idx, input_idx[INPUT_BITS-1:0]};    // 12-bit BRAM address
    assign in_val      = fc_in[input_idx[INPUT_BITS-1:0]];          // input value for this cycle

    //=======================================================
    // weight_lookup
    //=======================================================
    // Turn each lane's 9-bit map index into the real weight value by looking
    // it up in the shared 375-entry codebook (the "decompression" step).
    generate
        for (genvar m = 0; m < PARALLEL_MACS; m++) begin : gen_weight_lookup
            assign weight[m] = UNIQUE_FC1_W[map_idx[m]];
        end
    endgenerate

    //=======================================================
    // product_compute
    //=======================================================
    // Multiply the (delayed) input by each lane's weight. Maps onto the
    // FPGA's hardened DSP48E2 multiplier blocks.
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
        //===================================================
        // Defaults
        //===================================================
        next_state = state;   // hold current state unless a transition fires below

        //===================================================
        // State transitions
        //===================================================
        case (state)
            // Leave IDLE the moment start is asserted.
            ST_IDLE:
                if (start)
                    next_state = ST_COMPUTE;

            // Leave COMPUTE only once the LAST batch has finished.
            // pulses after every batch, but `compute_active` only drops to 0
            // after batch 31 specifically, so this AND condition uniquely
            // identifies "the whole layer pass is complete".
            ST_COMPUTE:
                if (batch_done && !compute_active)
                    next_state = ST_DONE;

            // DONE always lasts exactly one cycle, then back to IDLE.
            ST_DONE:
                next_state = ST_IDLE;

            default:
                next_state = ST_IDLE;
        endcase
    end

    //=======================================================
    // datapath_control
    //=======================================================
    // Walks input_idx 0 -> 128 within each batch, and batch_idx 0 -> 31
    // across the pass.
    always_ff @(posedge clk or negedge arst_n)
    begin
        //===================================================
        // Reset
        //===================================================
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
        //===================================================
        // Running
        //===================================================
        else
        begin
            // Both are 1-cycle pulses: clear every cycle by default, then
            // re-assert below only on the specific cycle where they should fire.
            done       <= 1'b0;
            batch_done <= 1'b0;

            case (state)

                //===============================================
                // ST_IDLE
                //===============================================
                ST_IDLE:
                begin
                    busy <= 1'b0;
                    if (start)
                    begin
                        // Kick off a fresh pass: reset counters, mark active/busy.
                        batch_idx      <= '0;
                        input_idx      <= '0;
                        compute_active <= 1'b1;
                        busy           <= 1'b1;
                        in_val_d1      <= '0;
                    end
                end

                //===============================================
                // ST_COMPUTE
                //===============================================
                ST_COMPUTE:
                begin
                    busy <= 1'b1;

                    // Latch the current input so it's available NEXT cycle,
                    // aligned with the weight that the BRAM read (issued this
                    // cycle) will produce.
                    if (compute_active && input_idx < N_INPUTS)
                        in_val_d1 <= fc_in[input_idx[INPUT_BITS-1:0]];

                    if (compute_active)
                    begin
                        // input_idx == 128 means: all 128 MAC cycles for this
                        // batch are done.
                        if (input_idx == BATCH_CYCLES - 1)
                        begin
                            // Remember which neurons this finished batch
                            // corresponds to, for the bias/ReLU/writeback stage.
                            completed_batch_base <= batch_idx * PARALLEL_MACS;
                            input_idx            <= '0;   // restart per-batch counter
                            in_val_d1             <= '0;

                            if (batch_idx == NUM_BATCHES - 1)
                            begin
                                // That was the LAST batch (31) -> pass complete.
                                compute_active <= 1'b0;
                                batch_done     <= 1'b1;
                            end
                            else
                            begin
                                // More batches remain -> advance to the next one.
                                batch_idx  <= batch_idx + 1'b1;
                                batch_done <= 1'b1;
                            end
                        end
                        else
                        begin
                            // Still mid-batch -> just count up.
                            input_idx <= input_idx + 1'b1;
                        end
                    end
                end

                //===============================================
                // ST_DONE
                //===============================================
                ST_DONE:
                begin
                    done <= 1'b1;   // tell the outside world the pass finished
                    busy <= 1'b0;
                end

                default: ;
            endcase
        end
    end

    //=======================================================
    // bram_read_stage
    //=======================================================
    // Registered, 1-cycle latency, 8 lanes in parallel. Reads happen for
    // input_idx 0..127 (the "setup" cycle input_idx==0 is included, since
    // its result is needed by the time input_idx==1 arrives).
    always_ff @(posedge clk or negedge arst_n)
    begin
        //===================================================
        // Active read
        //===================================================
        if (state == ST_COMPUTE && compute_active && input_idx < N_INPUTS)
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
        //===================================================
        // Reset / new run
        //===================================================
        else if (~arst_n || (state == ST_IDLE && start))
        begin
            for (int m = 0; m < PARALLEL_MACS; m++)
                map_idx[m] <= '0;
        end
    end

    //=======================================================
    // mac_accumulate_stage
    //=======================================================
    // input_idx == 0      : setup cycle only (BRAM read in flight) -> no MAC.
    // input_idx == 1      : first REAL product is ready -> OVERWRITE the
    //                        accumulator (doubles as the "clear for a new
    //                        batch" step, avoiding a separate explicit reset
    //                        every batch).
    // input_idx == 2..128  : normal accumulate: acc += product.
    always_ff @(posedge clk or negedge arst_n)
    begin
        //===================================================
        // Reset / new run
        //===================================================
        if (~arst_n)
            for (int m = 0; m < PARALLEL_MACS; m++)
                acc_mac[m] <= '0;
        else if (state == ST_IDLE && start)
            for (int m = 0; m < PARALLEL_MACS; m++)
                acc_mac[m] <= '0;
        //===================================================
        // Accumulate
        //===================================================
        else if (state == ST_COMPUTE && compute_active && input_idx >= 1)
        begin
            if (input_idx == 1)
                for (int m = 0; m < PARALLEL_MACS; m++)
                    acc_mac[m] <= $signed(product[m]);            // overwrite = implicit clear
            else
                for (int m = 0; m < PARALLEL_MACS; m++)
                    acc_mac[m] <= acc_mac[m] + $signed(product[m]);  // accumulate
        end
    end

    //=======================================================
    // batch_complete_stage
    //=======================================================
    // Add bias, rescale, apply ReLU, write final output. Fires once per
    // batch (32 times per full pass) on the batch_done pulse.
    //
    // Fixed-point note: acc_mac is a sum of (Q_.FRAC_BITS x Q_.FRAC_BITS)
    // products, so its "true" scale is Q_.(2*FRAC_BITS). The bias, however,
    // is stored in plain Q_.FRAC_BITS. To add them correctly, the bias is
    // shifted LEFT by FRAC_BITS first (bias_aligned) to match the
    // accumulator's larger scale. After adding, the sum is shifted RIGHT by
    // FRAC_BITS to bring the result back down to normal Q_.FRAC_BITS output.
    always_ff @(posedge clk or negedge arst_n)
    begin
        //===================================================
        // Reset
        //===================================================
        if (~arst_n)
        begin
            for (int o = 0; o < N_OUTPUTS; o++)
                fc_out[o] <= '0;
        end
        //===================================================
        // Bias + rescale + ReLU + writeback
        //===================================================
        else if ((state == ST_COMPUTE || state == ST_DONE) && batch_done)
        begin
            logic signed [ACCUM_WIDTH-1:0] bias_wide, bias_aligned, total;
            logic signed [DATA_WIDTH-1:0]  result;
            int unsigned neuron;

            for (int m = 0; m < PARALLEL_MACS; m++)
            begin
                neuron       = completed_batch_base + m;       // actual neuron index (0..255)
                bias_wide    = $signed(FC1_BIAS[neuron]);      // sign-extend bias to ACCUM_WIDTH
                bias_aligned = bias_wide <<< FRAC_BITS;        // rescale bias to match acc_mac's scale
                total        = acc_mac[m] + bias_aligned;      // dot-product + bias
                result       = total >>> FRAC_BITS;            // rescale back down to Q_.FRAC_BITS
                if (result < 0)
                    result = '0;                               // ReLU: clamp negative to zero
                fc_out[neuron] <= result;
            end
        end
    end

    //=======================================================
    // weight_bram_init
    //=======================================================
    // Load each lane's map-index table from its own precomputed hex file
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
