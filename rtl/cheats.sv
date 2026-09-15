// Cheat engine — applies Pugsy MAME-database pokes to work RAM once a frame.
//
// MiSTer's CONF_STR is compiled into the core and shared by every game on the
// .rbf, so a per-game menu of cheat NAMES cannot be built. The core therefore
// offers SLOTS fixed, well-known cheats (Infinite Credits, P1/P2
// Invincibility, P1/P2 Infinite Lives, P1/P2 Infinite Bombs) and each .mra
// supplies that game's addresses for them as its <rom index="5"> region. A
// slot the loaded game has no entry for reports itself unavailable, and the
// top level hides it from the OSD through status_menumask.
//
// Table layout (big-endian), 14 bytes per slot, SLOTS slots — written by
// tools/gen_cheats_mra.py:
//     1 byte   count for this slot (0..ACTS)
//     1 byte   reserved
//     ACTS x { 3 bytes address, 1 byte size (0=byte, 1=word), 2 bytes value }
//
// Writes go out on the same shared game-RAM port the hiscore module uses, so
// this adds no RAM port of its own (NMK-10 — see docs/known-issues.md). The
// port is only driven while pause_cpu is asserted and the top level has
// granted it, and a whole frame's pokes are at most ACTS*SLOTS*2 = 28 bytes,
// so the CPU stall is a few dozen cycles out of ~700,000 in a frame.
//
// Poke semantics follow MAME's "run" state: the value is written every frame
// for as long as the cheat is enabled, which is what makes "infinite" cheats
// hold against the game decrementing the counter.
module cheats #(
	parameter SLOTS = 7,
	parameter ACTS  = 2
) (
	input                    clk,
	input                    reset,

	// Table load, .mra <rom index="5">
	input                    ioctl_download,
	input                    ioctl_wr,
	input             [24:0] ioctl_addr,
	input             [15:0] ioctl_index,
	input              [7:0] ioctl_dout,

	input        [SLOTS-1:0] enable,      // OSD toggles
	output       [SLOTS-1:0] available,   // slot has data in this game's table

	input                    vblank,      // once-per-frame trigger

	// Shared work-RAM port (same contract as the hiscore port)
	output reg        [23:0] ram_addr,
	output reg         [7:0] ram_din,
	output reg               ram_write,
	output reg               ram_access,
	output reg               pause_cpu
);

	localparam BYTES_PER_SLOT = 2 + ACTS*6;
	localparam TBL_BYTES      = SLOTS*BYTES_PER_SLOT;

	reg [7:0] tbl [0:TBL_BYTES-1];
	reg       loaded = 1'b0;

	wire tbl_we = ioctl_download & ioctl_wr & (ioctl_index == 16'd5) & (ioctl_addr < TBL_BYTES);
	always @(posedge clk) begin
		if (tbl_we) begin
			tbl[ioctl_addr[$clog2(TBL_BYTES)-1:0]] <= ioctl_dout;
			loaded <= 1'b1;
		end
	end

	// A slot is available when its count byte is non-zero.
	genvar g;
	generate
		for (g = 0; g < SLOTS; g = g + 1) begin : g_avail
			assign available[g] = loaded & (tbl[g*BYTES_PER_SLOT] != 8'd0);
		end
	endgenerate

	// ------------------------------------------------------------------
	// Per-frame poke walk. One byte per pass through S_WRITE; a word action
	// is just two byte writes, high byte first (68000 big-endian).
	// ------------------------------------------------------------------
	localparam S_IDLE = 3'd0, S_SLOT = 3'd1, S_ACT = 3'd2,
	           S_WRITE = 3'd3, S_HOLD = 3'd4, S_NEXT = 3'd5, S_DONE = 3'd6;

	reg  [2:0] state = S_IDLE;
	reg  [3:0] slot;
	reg  [3:0] act;
	reg        half;        // 0 = first byte, 1 = second byte of a word
	reg  [2:0] hold;
	reg        vblank_d;

	wire [$clog2(TBL_BYTES)-1:0] base = slot*BYTES_PER_SLOT;
	wire [7:0] cnt  = tbl[base];
	wire [$clog2(TBL_BYTES)-1:0] aoff = base + 2 + act*6;
	wire [23:0] a_addr = {tbl[aoff], tbl[aoff+1], tbl[aoff+2]};
	wire        a_word = tbl[aoff+3][0];
	wire  [7:0] a_hi   = tbl[aoff+4];
	wire  [7:0] a_lo   = tbl[aoff+5];

	always @(posedge clk) begin
		vblank_d <= vblank;
		ram_write <= 1'b0;

		if (reset) begin
			state <= S_IDLE; ram_access <= 1'b0; pause_cpu <= 1'b0;
		end else case (state)
			S_IDLE: begin
				ram_access <= 1'b0;
				pause_cpu  <= 1'b0;
				// rising edge of vblank, and only if something is enabled
				if (~vblank_d & vblank & loaded & |(enable & available)) begin
					slot <= 4'd0; pause_cpu <= 1'b1; state <= S_SLOT;
				end
			end
			S_SLOT: begin
				if (slot >= SLOTS) state <= S_DONE;
				else if (enable[slot[2:0]] & (cnt != 8'd0)) begin
					act <= 4'd0; half <= 1'b0; state <= S_ACT;
				end else slot <= slot + 4'd1;
			end
			S_ACT: begin
				if (act >= cnt[3:0]) begin
					slot <= slot + 4'd1; state <= S_SLOT;
				end else begin
					// byte action writes a_lo at the address; word writes
					// a_hi then a_lo across addr, addr+1.
					ram_addr   <= a_word ? (a_addr + {23'd0, half}) : a_addr;
					ram_din    <= a_word ? (half ? a_lo : a_hi) : a_lo;
					ram_access <= 1'b1;
					ram_write  <= 1'b1;
					hold       <= 3'd2;
					state      <= S_HOLD;
				end
			end
			S_HOLD: begin
				ram_access <= 1'b1;
				if (hold != 3'd0) hold <= hold - 3'd1;
				else state <= S_NEXT;
			end
			S_NEXT: begin
				if (a_word & ~half) begin
					half <= 1'b1; state <= S_ACT;
				end else begin
					half <= 1'b0; act <= act + 4'd1; state <= S_ACT;
				end
			end
			S_DONE: begin
				ram_access <= 1'b0;
				pause_cpu  <= 1'b0;
				state      <= S_IDLE;
			end
			default: state <= S_IDLE;
		endcase
	end

endmodule
