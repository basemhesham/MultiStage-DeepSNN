//==============================================================================
// Module      : fetch_handshake_unit
// Description :
//    Issues a single-cycle fetch_en_i pulse to the mapping controller once
//    per CLEAR_STAGE2_WORD visit (guarded by the internal fetch_pulse_sent
//    flag so the pulse is not re-issued every cycle while waiting for
//    done_load_o).
//==============================================================================
module fetch_handshake_unit
	import top_controller_pkg::*;
(
	input  wire logic                      clk        , // clock of system
	input  wire logic                      rst        , // reset of system (soft)
	input  wire logic                      arst_n     , // asynchronous reset (hard)
	input  wire logic                      done_load_o, // input done from mapping controller
	input  wire state_t                    state_q    , // current FSM state (from fsm_sequencer)

	output logic fetch_en_i // one-cycle pulse requesting the next fragment fetch from the mapping controller
);

	logic fetch_pulse_sent; // flag: the one-cycle fetch_en_i pulse has already been issued for the current CLEAR_STAGE2_WORD visit

	always_ff @(posedge clk or negedge arst_n)
		begin
			if (!arst_n)
				begin
					fetch_en_i       <= 1'b0;
					fetch_pulse_sent <= 1'b0;
				end
			else
				begin
					fetch_en_i <= 1'b0; // default: de-assert (single-cycle pulse)
					if (!done_load_o)
						begin
							fetch_pulse_sent <= 1'b0; // mapping controller no longer reports "loaded": arm for the next pulse
						end
					else if (state_q == CLEAR_STAGE2_WORD && !fetch_pulse_sent)
						begin
							fetch_en_i       <= 1'b1; // issue the one-cycle fetch request
							fetch_pulse_sent <= 1'b1; // and latch that it has been sent
						end
				end
		end

endmodule : fetch_handshake_unit
