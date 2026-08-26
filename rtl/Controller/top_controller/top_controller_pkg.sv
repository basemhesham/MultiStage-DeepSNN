//==============================================================================
// Package     : top_controller_pkg
// Description :
//    Shared type definitions for the top_controller module hierarchy.
//    Keeping the FSM state type in one package (instead of duplicating the
//    typedef in every module that needs it) guarantees that top_controller,
//    fsm_sequencer, fetch_handshake_unit, and output_mux_unit all agree on
//    the same state identifiers and the same 3-bit encoding.
//==============================================================================
package top_controller_pkg;

	typedef enum logic [2:0] {
		IDLE              , // waiting for 'enable' to start a run
		CLEAR_STAGE2_WORD , // one-time: zero the Stage-2 memory word before Stage1 begins
		STAGE1            , // sweep the current fragment's valid positions through Stage-1
		CLEAR_STAGE3_WORD , // one-time: zero the Stage-3 memory word before Stage2 begins
		STAGE2            , // sweep the current fragment's valid positions through Stage-2 (per filter)
		STAGE3            , // process the current fragment through Stage-3 (per filter)
		DONE                // entire run finished (run_complete asserted)
	} state_t;

endpackage : top_controller_pkg
