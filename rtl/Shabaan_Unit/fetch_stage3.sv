// =====================================================================================
// Module name : fetch_stage3
// Purpose     : Generates the read and write addresses/enables for a LIF history BRAM
//               group (131072 positions). Pure address/control-timing module. Identical
//               architecture/logic to `fetch` - only the parameters differ.
//
//               ** Spare-bank ping-pong: ACTIVE_BANKS active banks + 1 spare bank. **
//               Instead of double-buffering the whole memory (2x depth), this uses
//               TOTAL_BANKS physical banks (ACTIVE_BANKS + 1 spare) but only sweeps
//               ACTIVE_BANKS of them in any one frame. The write window for frame N
//               and the read window for frame N+1 are the SAME ACTIVE_BANKS-bank
//               window (frame N+1 reads exactly what frame N wrote) - so the write
//               window only ever needs to avoid the ONE bank the read side is
//               currently on, which is guaranteed because the write window's start
//               bank decrements by exactly one bank every frame (mod TOTAL_BANKS),
//               continuously "rotating away" from whichever bank the trailing read
//               is still using.
//
//               Frame 1 : write window start = 0                                  no read
//               Frame 2 : write window start = TOTAL_BANKS-1   read window start = 0            (= frame 1's write)
//               Frame 3 : write window start = TOTAL_BANKS-2   read window start = TOTAL_BANKS-1 (= frame 2's write)
//               Frame N : write window start = (TOTAL_BANKS+1-N) mod TOTAL_BANKS   read window start = write window start of frame N-1
//               ... start bank decrementing by 1 every frame, wrapping mod TOTAL_BANKS.
//
//               Within a frame, the window always walks FORWARD through ACTIVE_BANKS
//               consecutive banks (mod TOTAL_BANKS) starting at that frame's start bank.
//
//               ** ADDRESSING (no divider/modulo hardware): **
//               Each bank is BANK_DEPTH deep (must be a power of 2). The sweep position
//               is tracked directly as (bank_adv, local_pos) - local_pos counts
//               0..BANK_DEPTH-1 and rolls over into bank_adv (0..ACTIVE_BANKS-1) instead
//               of deriving them from a flat counter via '/' and '%'. The physical bank
//               actually being accessed is (start_bank + bank_adv) wrapped mod
//               TOTAL_BANKS via a plain compare-and-subtract (no '%'). The final
//               physical address is a bit-concatenation of that bank index with
//               local_pos (bank_index * BANK_DEPTH + local_pos, done as {bank,
//               local_pos} since BANK_DEPTH is a power of 2) - a shift/concat, not a
//               multiply.
//
//               'frame_start' must be pulsed for exactly one cycle at the boundary
//               between two frames (after frame N's last in_valid, before frame N+1's
//               first in_valid) - and must NOT be pulsed before frame 0/frame 1, since
//               the rotation already starts at bank 0 out of reset.
// =====================================================================================
// Written by  : Abdelrahman Khaled
// Editor      : Manar
// Last edit   : 23-8-2026
// =====================================================================================

module fetch_stage3 #(
    parameter BANK_DEPTH   = 2048,                       // depth of a single physical bank - MUST be a power of 2
    parameter ACTIVE_BANKS = 64,                     // banks swept per frame (the "sweep window" size)
    parameter TOTAL_BANKS  = 65,                      // total physical banks = ACTIVE_BANKS + spare bank(s)
    parameter ADDR_WIDTH   = $clog2(TOTAL_BANKS*BANK_DEPTH)      // covers the full physical address range
) (
    input  logic                     clk,
    input  logic                     arst_n,

    // Caller-facing side (mapping controller)
    input  logic  [3:0]              frame_count, // indicate which frame we are in as to write only in the first and read only in the last
    input  logic                     frame_start, // 1-cycle pulse at each frame boundary (NOT before frame 1)
    input  logic                     in_valid,    // position valid this cycle (advances the position counter)

    // Memory-facing side (drive the BRAM ports directly)
    output logic                     rd_en,       // -> BRAM port B enb
    output logic [ADDR_WIDTH-1:0]    rd_addr,     // -> BRAM port B addrb
    output logic                     wr_en,       // -> BRAM port A ena/wea
    output logic [ADDR_WIDTH-1:0]    wr_addr,     // -> BRAM port A addra

    // Caller-facing side
    output logic                     out_valid,
    output logic [ADDR_WIDTH-1:0]    addr_out
);

    localparam int BANK_IDX_WIDTH = $clog2(TOTAL_BANKS);    // width for a bank index (0..TOTAL_BANKS-1)
    localparam int ADV_WIDTH      = $clog2(ACTIVE_BANKS);   // width for the in-frame bank-advance count (0..ACTIVE_BANKS-1)
    localparam int LOCAL_WIDTH    = $clog2(BANK_DEPTH);     // width for the local in-bank offset (0..BANK_DEPTH-1)

    // -----------------------------------------------------------------
    // Rotating start-bank: cur_bank is the bank index where THIS
    // frame's write window starts; prev_bank is where the PREVIOUS
    // frame's write window started (and therefore where this frame's
    // read window starts). Both DECREMENT by ONE bank each frame_start,
    // wrapping mod TOTAL_BANKS via a plain compare (no '%').
    // -----------------------------------------------------------------
    localparam [BANK_IDX_WIDTH-1:0] TOTAL_BANKS_M1 = BANK_IDX_WIDTH'(TOTAL_BANKS - 1);

    reg [BANK_IDX_WIDTH-1:0] cur_bank;
    reg [BANK_IDX_WIDTH-1:0] prev_bank;
    wire [BANK_IDX_WIDTH-1:0] cur_bank_dec;   // pre-computed decrement (kept out of the ternary below)
    wire [BANK_IDX_WIDTH-1:0] cur_bank_next;
    assign cur_bank_dec  = cur_bank - 1'b1;
    assign cur_bank_next = (cur_bank == '0) ? TOTAL_BANKS_M1 : cur_bank_dec;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            cur_bank  <= '0;   // frame 1 writes starting at bank 0
            prev_bank <= '0;   // unused while first_frame=1
        end else if (frame_start && (frame_count != 0)) begin
            prev_bank <= cur_bank;       // this frame's read window starts where the last frame's write did
            cur_bank  <= cur_bank_next;  // next frame's write window starts one bank further back
        end
    end

    // -----------------------------------------------------------------
    // Sweep counter, tracked directly as (bank_adv, local_pos) instead
    // of a flat position that would need dividing by BANK_DEPTH:
    //   - local_pos counts 0..BANK_DEPTH-1 and rolls back to 0
    //   - on rollover, bank_adv advances by one bank, wrapping mod
    //     ACTIVE_BANKS (the window only ever walks ACTIVE_BANKS banks
    //     forward from the frame's start bank)
    // -----------------------------------------------------------------
    localparam [ADV_WIDTH-1:0] ACTIVE_BANKS_M1 = ADV_WIDTH'(ACTIVE_BANKS - 1);

    reg [LOCAL_WIDTH-1:0] local_pos;
    reg [ADV_WIDTH-1:0]   bank_adv;

    wire local_pos_wraps = (local_pos == BANK_DEPTH-1);
    wire [ADV_WIDTH-1:0] bank_adv_inc = bank_adv + 1'b1;  // pre-computed increment (kept out of the ternary below)

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            local_pos <= '0;
            bank_adv  <= '0;
        end else if (frame_start) begin
            local_pos <= '0;
            bank_adv  <= '0;
        end else if (in_valid) begin
            if (local_pos_wraps) begin
                local_pos <= '0;
                bank_adv  <= (bank_adv == ACTIVE_BANKS_M1) ? '0 : bank_adv_inc;
            end else begin
                local_pos <= local_pos + 1'b1;
            end
        end
    end

    // -----------------------------------------------------------------
    // Bank-index helper: base bank + bank_adv, wrapped mod TOTAL_BANKS
    // via a plain compare-and-subtract (no '%'). This is where the
    // window "walks forward" from the frame's start bank, wrapping
    // past TOTAL_BANKS-1 straight back to bank 0.
    // -----------------------------------------------------------------
    function automatic [BANK_IDX_WIDTH-1:0] wrapped_bank(
        input [BANK_IDX_WIDTH-1:0] base,
        input [ADV_WIDTH-1:0]      adv
    );
        logic [BANK_IDX_WIDTH:0] sum;
        logic [BANK_IDX_WIDTH:0] sum_wrapped;  // pre-computed wrap (kept out of the ternary below)
        begin
            sum         = {1'b0, base} + {{(BANK_IDX_WIDTH+1-ADV_WIDTH){1'b0}}, adv};
            sum_wrapped = sum - TOTAL_BANKS;
            wrapped_bank = (sum >= TOTAL_BANKS) ? BANK_IDX_WIDTH'(sum_wrapped) : sum[BANK_IDX_WIDTH-1:0];
        end
    endfunction

    // -----------------------------------------------------------------
    // Read side: combinational, sweeps from prev_bank, suppressed
    // entirely during frame 1 (first_frame=1), since there is no
    // previous-frame history yet. Physical address = bank index
    // concatenated with local_pos (bank*BANK_DEPTH + local, done as a
    // concat since BANK_DEPTH is a power of 2 - no multiplier).
    // -----------------------------------------------------------------
    wire [BANK_IDX_WIDTH-1:0] rd_bank = wrapped_bank(prev_bank, bank_adv);

    assign rd_en   = (in_valid && (|frame_count != 0)) ? 1 : 0; // read when it's not the first frame
    assign rd_addr = ADDR_WIDTH'({rd_bank, local_pos});

    // -----------------------------------------------------------------
    // Write side: delayed 1 cycle to align with the BRAM's read
    // latency, sweeps from cur_bank at the position that was active
    // when in_valid was asserted.
    // -----------------------------------------------------------------
    reg                      valid_d1;
    reg [LOCAL_WIDTH-1:0]    local_pos_d1;
    reg [ADV_WIDTH-1:0]      bank_adv_d1;
    reg [BANK_IDX_WIDTH-1:0] cur_bank_d1;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            valid_d1     <= 1'b0;
            local_pos_d1 <= '0;
            bank_adv_d1  <= '0;
            cur_bank_d1  <= '0;
        end else begin
            valid_d1     <= in_valid;
            local_pos_d1 <= local_pos;
            bank_adv_d1  <= bank_adv;
            cur_bank_d1  <= cur_bank;
        end
    end

    wire [BANK_IDX_WIDTH-1:0] wr_bank = wrapped_bank(cur_bank_d1, bank_adv_d1);

    // We ALWAYS write, even on frame 1, to populate the history for frame 2.
    assign wr_en   = (valid_d1 && (&frame_count != 1)) ? 1 : 0;  // writing when it's not the last frame
    assign wr_addr = ADDR_WIDTH'({wr_bank, local_pos_d1});

    // -----------------------------------------------------------------
    // Status passthrough to the caller/wrapper - aligned to the same
    // cycle as wr_en/wr_addr.
    // -----------------------------------------------------------------
    assign out_valid = valid_d1;
    assign addr_out  = wr_addr;

endmodule
