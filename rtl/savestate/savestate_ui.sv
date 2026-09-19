// Savestate OSD / keyboard front end (2026-09-18), after NES_MiSTer's
// savestate_ui.sv (keyboard hotkeys and the OSD "Savestate Slot" /
// "Save state" / "Restore state" entries). F1-F4 load slot 1-4, Alt+F1-F4
// save; the slot chosen from the keyboard is written back into the OSD
// (statusUpdate -> hps_io status_in). Result messages come from the
// engine's done pulses. Info codes (the top's "I," list):
//   1 = help, 2-5 = active slot n, 6-9 = state n saved, 10-13 = state n
//   loaded, 14 = savestate failed, 15 = slot empty.
module savestate_ui (
	input            clk,
	input     [10:0] ps2_key,
	input            allow_ss,
	input      [1:0] status_slot,     // the OSD's slot bits
	input      [1:0] OSD_saveload,    // R[n] pulses from the OSD: [0] save, [1] load
	input            done_ok,         // from the engine
	input            done_fail,
	input      [1:0] fail_code,
	input            was_load,
	output reg       ss_save,
	output reg       ss_load,
	output reg       ss_info_req,
	output reg [7:0] ss_info,
	output reg       statusUpdate,
	output     [1:0] selected_slot
);
	reg [1:0] ss_base = 2'd0;
	reg [1:0] lastOSDsetting = 2'd0;
	reg       old_state = 1'b0;
	reg       alt = 1'b0;
	reg [1:0] old_st = 2'b00;
	assign selected_slot = ss_base;
	wire pressed = ps2_key[9];

	always @(posedge clk) begin
		old_state    <= ps2_key[10];
		ss_save      <= 1'b0;
		ss_load      <= 1'b0;
		ss_info_req  <= 1'b0;
		statusUpdate <= 1'b0;
		lastOSDsetting <= status_slot;
		old_st <= OSD_saveload;

		if (allow_ss) begin
			// keyboard: F1-F4 = restore, Alt+F1-F4 = save
			if (old_state != ps2_key[10]) begin
				case (ps2_key[7:0])
					8'h11: alt <= pressed;   // left Alt
					8'h05: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; if (pressed) begin ss_base <= 2'd0; statusUpdate <= 1'b1; end end // F1
					8'h06: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; if (pressed) begin ss_base <= 2'd1; statusUpdate <= 1'b1; end end // F2
					8'h04: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; if (pressed) begin ss_base <= 2'd2; statusUpdate <= 1'b1; end end // F3
					8'h0C: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; if (pressed) begin ss_base <= 2'd3; statusUpdate <= 1'b1; end end // F4
					default: ;
				endcase
			end
			// OSD slot change
			if (lastOSDsetting != status_slot) begin
				ss_base     <= status_slot;
				ss_info     <= 8'd2 + {6'd0, status_slot};
				ss_info_req <= 1'b1;
			end
			// OSD save / load buttons
			if (old_st[0] ^ OSD_saveload[0]) ss_save <= OSD_saveload[0];
			if (old_st[1] ^ OSD_saveload[1]) ss_load <= OSD_saveload[1];
		end
		// results
		if (done_ok) begin
			ss_info     <= (was_load ? 8'd10 : 8'd6) + {6'd0, ss_base};
			ss_info_req <= 1'b1;
		end
		if (done_fail) begin
			ss_info     <= (fail_code == 2'd2) ? 8'd15 : 8'd14;
			ss_info_req <= 1'b1;
		end
	end
endmodule
