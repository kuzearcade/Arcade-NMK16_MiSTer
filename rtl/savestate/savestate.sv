// Savestate engine (2026-09-18) — MiSTer savestate framework
// (https://mister-devel.github.io/MkDocs_MiSTer/developer/savestates/).
//
// One slot is `SLOT_STRIDE` 64-bit DDR words at DDR_BASE + slot*SLOT_STRIDE:
// a control word {size in 32-bit words [63:32], change counter [31:0]} then
// the image. The firmware persists a slot to disk whenever the counter
// changes and, at core start, presents each slot's file (size word set) or
// zeros (empty). Slot addresses are in 8-byte units (DDRAM_ADDR).
//
// The core exposes its whole state as SS_WORDS 16-bit words on a flat bus
// (ss_addr / ss_rdata / ss_wr / ss_wdata) that is only meaningful while
// every CPU is parked (ss_freeze -> ss_frozen); see the core for the map.
// A save waits for the next VBlank, parks, streams the image up, writes
// the control word and releases; a load parks, checks the control word's
// size, streams the image down, lets the core replay its sound-chip
// register shadows (ss_replay -> ss_replay_done) and releases. Any step
// that cannot complete in 2^TIMEOUT_BITS clocks (a CPU that will not park:
// held in reset, halted, paused) aborts and releases what was parked.
//
// The DDR port runs on clk_ddr (the framework's DDRAM_CLK, the video clock
// here, since screen_rotate owns that pin) with a toggle handshake to the
// core clock. The framebuffer's writes win any cycle they appear on
// (rot_we); this engine takes the bus only in the gaps, so rotated video is
// untouched by a save or load.
module savestate #(
	parameter        SS_WORDS     = 65536,          // 16-bit words in the image (multiple of 4)
	parameter [28:0] DDR_BASE     = 29'h07C00000,   // 0x3E000000 >> 3
	parameter [28:0] SLOT_STRIDE  = 29'h00008000,   // 0x40000 bytes >> 3
	parameter        TIMEOUT_BITS = 22,
	parameter        RD_LAT       = 3                // clocks from ss_addr to a valid ss_rdata
) (
	input             clk,
	input             reset,

	input             save_req,      // one-clock pulses (ignored while busy)
	input             load_req,
	input       [1:0] slot,
	input             vblank,
	input             allow,         // the game is running (ROM loaded, not in reset)

	// core snapshot bus
	output reg        ss_freeze,     // park request, held until the CPUs have left their monitors
	input             ss_frozen,     // every CPU is parked / frozen
	input             ss_parked,     // a CPU is still inside its park monitor
	output reg        ss_resume,     // release phase
	output reg        ss_active,     // image transfer in progress: the RAM ports are the engine's
	output reg [19:0] ss_addr,
	input      [15:0] ss_rdata,
	output reg        ss_wr,
	output reg [15:0] ss_wdata,
	output reg        ss_replay,
	input             ss_replay_done,

	output            busy,
	output reg        done_ok,       // pulses
	output reg        done_fail,
	output reg  [1:0] fail_code,     // 1 = could not park, 2 = empty slot, 3 = DDR timeout
	output reg        was_load,      // what the last op was

	// DDR side (clk_ddr)
	input             clk_ddr,
	input             ddr_busy,
	input             rot_we,        // screen_rotate is writing this cycle
	output            ddr_we,
	output            ddr_rd,
	output     [28:0] ddr_addr,
	output     [63:0] ddr_din,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready
);
	localparam [31:0] SIZE32 = SS_WORDS / 2;

	// ------------------------------------------------------------------
	// core -> DDR request handshake
	// ------------------------------------------------------------------
	reg        req_tog = 1'b0, req_we = 1'b0;
	reg [28:0] req_addr;
	reg [63:0] req_wdata;
	reg        ack_tog_d = 1'b0;
	wire       ack_tog;
	reg [63:0] d_rdata;     // DDR-side read data: written before ack_tog flips, stable until the next request
	reg  [1:0] ack_sync = 2'b00;
	always @(posedge clk) ack_sync <= {ack_sync[0], ack_tog};
	wire       ddr_done = (ack_sync[1] != ack_tog_d);

	// ------------------------------------------------------------------
	// core-side FSM
	// ------------------------------------------------------------------
	localparam [3:0] S_IDLE = 4'd0, S_WAITVB = 4'd1, S_FREEZE = 4'd2, S_HDR = 4'd3, S_HDRWAIT = 4'd4,
	                 S_SRD = 4'd5, S_SWR = 4'd6, S_SHDR = 4'd7, S_LRD = 4'd8, S_LWR = 4'd9,
	                 S_REPLAY = 4'd10, S_RELEASE = 4'd11, S_END = 4'd12, S_RELWAIT = 4'd13;
	reg [3:0]  state = S_IDLE;
	reg        op_load = 1'b0;
	reg [1:0]  op_slot = 2'd0;
	reg        ok_r = 1'b0;
	reg [1:0]  fail_r = 2'd0;
	reg [TIMEOUT_BITS-1:0] tmo = '0;
	reg        vb_d = 1'b0;
	reg [17:0] widx;        // 64-bit word index within the image
	reg [1:0]  k;           // 16-bit word within the 64-bit word
	reg [3:0]  cnt;
	reg [63:0] pack;
	reg [31:0] counter;
	reg [1:0]  rel_cnt = 2'd1;   // VBlank edges to wait before the release
	wire [28:0] slot_base = DDR_BASE + SLOT_STRIDE * op_slot;
	wire        tmo_hit = &tmo;
	assign busy = (state != S_IDLE);

	always @(posedge clk) begin
		done_ok <= 1'b0; done_fail <= 1'b0; ss_wr <= 1'b0;
		vb_d <= vblank;
		if (reset) begin
			state <= S_IDLE; ss_freeze <= 1'b0; ss_resume <= 1'b0; ss_active <= 1'b0; ss_replay <= 1'b0;
			ack_tog_d <= ack_sync[1]; tmo <= '0;
		end else begin
			tmo <= tmo + 1'b1;
			case (state)
				S_IDLE: begin
					ss_freeze <= 1'b0; ss_resume <= 1'b0; ss_active <= 1'b0; ss_replay <= 1'b0;
					if ((save_req | load_req) & allow) begin
						op_load <= load_req; op_slot <= slot; was_load <= load_req;
						rel_cnt <= load_req ? 2'd3 : 2'd1;
						ok_r <= 1'b0; fail_r <= 2'd0; tmo <= '0;
						state <= S_WAITVB;
					end
				end
				S_WAITVB: begin
					if (vblank & ~vb_d) begin state <= S_FREEZE; ss_freeze <= 1'b1; tmo <= '0; end
					else if (tmo_hit) begin fail_r <= 2'd1; state <= S_END; end
				end
				S_FREEZE: begin
					if (ss_frozen) begin
						// read the slot's control word first (counter for a save, size check for a load)
						req_we <= 1'b0; req_addr <= slot_base; req_tog <= ~req_tog;
						state <= S_HDRWAIT; tmo <= '0;
					end else if (tmo_hit) begin fail_r <= 2'd1; state <= S_RELEASE; ss_resume <= 1'b1; tmo <= '0; end
				end
				S_HDRWAIT: begin
					if (ddr_done) begin
						ack_tog_d <= ack_sync[1];
						counter <= d_rdata[31:0];
						widx <= 18'd0; k <= 2'd0; cnt <= 4'd0; tmo <= '0;
						if (op_load) begin
							if (d_rdata[63:32] == SIZE32) begin
								ss_active <= 1'b1;
								req_we <= 1'b0; req_addr <= slot_base + 29'd1; req_tog <= ~req_tog;
								state <= S_LRD;
							end else begin fail_r <= 2'd2; state <= S_RELEASE; ss_resume <= 1'b1; end
						end else begin
							ss_active <= 1'b1;
							ss_addr <= 20'd0;
							state <= S_SRD;
						end
					end else if (tmo_hit) begin fail_r <= 2'd3; state <= S_RELEASE; ss_resume <= 1'b1; tmo <= '0; end
				end
				// ---- save: 4 bus reads, one DDR write ----
				S_SRD: begin
					cnt <= cnt + 1'b1;
					if (cnt == RD_LAT) begin
						case (k)
							2'd0: pack[15:0]  <= ss_rdata;
							2'd1: pack[31:16] <= ss_rdata;
							2'd2: pack[47:32] <= ss_rdata;
							2'd3: pack[63:48] <= ss_rdata;
						endcase
						cnt <= 4'd0;
						ss_addr <= ss_addr + 1'b1;
						k <= k + 1'b1;
						if (k == 2'd3) state <= S_SWR;
					end
				end
				S_SWR: begin
					if (cnt == 4'd0) begin
						req_we <= 1'b1; req_addr <= slot_base + 29'd1 + {11'd0, widx}; req_wdata <= pack; req_tog <= ~req_tog;
						cnt <= 4'd1; tmo <= '0;
					end else if (ddr_done) begin
						ack_tog_d <= ack_sync[1]; cnt <= 4'd0;
						widx <= widx + 1'b1;
						if (widx == (SS_WORDS / 4) - 1) begin
							ss_active <= 1'b0;
							req_we <= 1'b1; req_addr <= slot_base; req_wdata <= {SIZE32, counter + 32'd1}; req_tog <= ~req_tog;
							state <= S_SHDR; tmo <= '0;
						end else state <= S_SRD;
					end else if (tmo_hit) begin fail_r <= 2'd3; ss_active <= 1'b0; state <= S_RELEASE; ss_resume <= 1'b1; tmo <= '0; end
				end
				S_SHDR: begin
					if (ddr_done) begin ack_tog_d <= ack_sync[1]; ok_r <= 1'b1; state <= S_RELEASE; ss_resume <= 1'b1; tmo <= '0; end
					else if (tmo_hit) begin fail_r <= 2'd3; state <= S_RELEASE; ss_resume <= 1'b1; tmo <= '0; end
				end
				// ---- load: one DDR read, 4 bus writes ----
				S_LRD: begin
					if (ddr_done) begin
						ack_tog_d <= ack_sync[1]; pack <= d_rdata; k <= 2'd0; cnt <= 4'd0;
						state <= S_LWR;
					end else if (tmo_hit) begin fail_r <= 2'd3; ss_active <= 1'b0; state <= S_RELEASE; ss_resume <= 1'b1; tmo <= '0; end
				end
				S_LWR: begin
					cnt <= cnt + 1'b1;
					if (cnt == 4'd0) begin
						ss_addr <= {widx, k};
						case (k)
							2'd0: ss_wdata <= pack[15:0];
							2'd1: ss_wdata <= pack[31:16];
							2'd2: ss_wdata <= pack[47:32];
							2'd3: ss_wdata <= pack[63:48];
						endcase
					end
					if (cnt == 4'd1) ss_wr <= 1'b1;
					if (cnt == 4'd3) begin
						cnt <= 4'd0; k <= k + 1'b1;
						if (k == 2'd3) begin
							widx <= widx + 1'b1;
							if (widx == (SS_WORDS / 4) - 1) begin
								ss_active <= 1'b0; ss_replay <= 1'b1; state <= S_REPLAY; tmo <= '0;
							end else begin
								req_we <= 1'b0; req_addr <= slot_base + 29'd2 + {11'd0, widx}; req_tog <= ~req_tog;
								state <= S_LRD; tmo <= '0;
							end
						end
					end
				end
				S_REPLAY: begin
					if (ss_replay_done | tmo_hit) begin ss_replay <= 1'b0; ok_r <= 1'b1; state <= S_RELEASE; ss_resume <= 1'b1; tmo <= '0; end
				end
				S_RELEASE: begin
					// Release at a VBlank edge, so the machine resumes at the same
					// frame phase after a save and after a load (a load of that save
					// then replays the exact same frames -- the sim harness checks
					// this). ss_resume was raised by the state that came here; hold
					// it off until the edge. A load waits TWO more frames first: the
					// video's sprite double buffer is not part of the image, and the
					// sprite DMA (which keeps running while the machine is parked)
					// needs two frames to refill both stages from the restored RAM --
					// without the wait the first two frames after a load showed the
					// pre-load sprites (raphero_hw: 9,880 / 9,134 pixels).
					ss_resume <= 1'b0;
					if (tmo_hit) begin ss_resume <= 1'b1; state <= S_RELWAIT; tmo <= '0; end
					else if (vblank & ~vb_d) begin
						rel_cnt <= rel_cnt - 1'b1;
						if (rel_cnt == 2'd1) begin ss_resume <= 1'b1; state <= S_RELWAIT; tmo <= '0; end
					end
				end
				S_RELWAIT: begin
					// the MCUs run again at once (the core gates their freeze with ss_resume);
					// the 68000/Z80 monitors exit on RESUME and report when they have left
					if (~ss_parked | tmo_hit) begin ss_freeze <= 1'b0; ss_resume <= 1'b0; state <= S_END; end
				end
				S_END: begin
					done_ok <= ok_r; done_fail <= ~ok_r; fail_code <= fail_r;
					state <= S_IDLE;
				end
				default: state <= S_IDLE;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// DDR side (clk_ddr)
	// ------------------------------------------------------------------
	reg  [1:0] req_sync = 2'b00;
	reg        req_seen = 1'b0;
	reg        ack_tog_r = 1'b0;
	reg        d_we = 1'b0, d_rd = 1'b0, d_wait = 1'b0;
	reg [28:0] d_addr;
	reg [63:0] d_din;
	assign ack_tog = ack_tog_r;
	always @(posedge clk_ddr) begin
		req_sync <= {req_sync[0], req_tog};
		if (d_wait) begin
			if (ddr_dout_ready) begin d_rdata <= ddr_dout; d_wait <= 1'b0; ack_tog_r <= ~ack_tog_r; end
		end else if (d_we | d_rd) begin
			if (~rot_we & ~ddr_busy) begin   // accepted this cycle
				d_we <= 1'b0; d_rd <= 1'b0;
				if (d_we) ack_tog_r <= ~ack_tog_r;
				else d_wait <= 1'b1;
			end
		end else if (req_sync[1] != req_seen) begin
			req_seen <= req_sync[1];
			d_addr <= req_addr; d_din <= req_wdata;
			if (req_we) d_we <= 1'b1; else d_rd <= 1'b1;
		end
	end
	assign ddr_we   = d_we & ~rot_we;
	assign ddr_rd   = d_rd & ~rot_we;
	assign ddr_addr = d_addr;
	assign ddr_din  = d_din;
endmodule
