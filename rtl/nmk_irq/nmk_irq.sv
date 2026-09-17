// Real NMK IRQ Generator — the dual-PROM-driven scanline state machine
// this hardware family actually uses, replacing the fixed-scanline
// nmk_irq_hacky.sv substitution (rtl/bjtwin/nmk_irq_hacky.sv, still used
// as-is for cactus/Tier 1, whose real PROM is undumped — see that
// module's own header). Ported directly from
// mame/src/mame/nmk/nmk_irq.cpp's own scanline_callback() — see that
// file's extensive header comment for the hardware background (dual
// counters + H/V timing PROMs inside the NMK902 custom chip).
//
// MAME's own nmk_irq_device does NOT consume the H-timing PROM at all
// (commented out in nmk_irq.h/.cpp, and that file's own "TODO: Horizontal
// timing generator emulation?") — screen geometry instead comes from the
// fixed per-resolution-class pixel-clock/htotal tables this project's own
// video_timing.sv already implements (see docs/PLAN.md's "nmk_irq timing
// generator" component note). This module therefore only needs the
// V-PROM.
//
// Every game using this hardware calls set_interrupt_timing() in
// nmk16.cpp unconditionally with the SAME fixed configuration
// (prom_start_offset=0x75, vtiming_prom_usage=0x100) — only the V-PROM's
// own 256-byte contents vary per game — so those constants are hardwired
// here rather than exposed as module parameters.
//
// Phase calibration (empirically verified, not derived from documentation
// alone): MAME's own screen.vpos() — the `y` the reference's address
// formula uses directly — is NOT the same numbering as this project's own
// video_timing.sv `vcount` (both run 0..277 over an identical 278-line
// frame, verified via Milestone 2's own independent frame-geometry
// cross-check, but with a different zero-reference point). Verified via a
// live MAME debugger capture (breakpoints at mustang's own IRQ1-4 ISR
// entry addresses, resolved from the ROM's own autovector table, printing
// the debugger's `beamy` pseudo-symbol) against mustang's real, dumped
// V-PROM (`10.bpr`): the reference's own address formula, fed raw
// `vcount` directly, computes addresses that decode to the *correct*
// IRQ/sprite-DMA bit patterns, just 66 scanlines "early" relative to
// where MAME's real hardware actually asserts them (four independent
// live-captured trigger points — IRQ1 at 68 and 196, IRQ2 at 16, IRQ4 at
// 240 — all match the formula's output for `vcount+66` exactly, and a
// fifth, the sprite-DMA trigger, independently lands on the same
// scanline nmk_irq_hacky.sv's own SL_SPRDMA=242 constant already uses).
// This module therefore feeds `(vcount + 66) mod 278` into the reference
// formula rather than `vcount` directly — see docs/tier2-system.md's
// "Milestone 5" for the full derivation and verification methodology.
module nmk_irq #(
	parameter VTIMING_FILE = ""
) (
	input        clk_sys,
	input        reset,

	// Multiple V-PROM tables (2026-09-11): a shared RBF that serves boards
	// with different PROMs (NMK16_Macross2.rbf: tdragon2/macross2 vs powerins;
	// NMK16_Gunnail.rbf: 633ab1c9 / 98ed1c97 / e6ead349 / de156d99) loads a
	// VTIMING_FILE of up to 4096 lines — table N in lines 256N..256N+255 —
	// and selects with this input. A 256-line file (every single-game
	// build and sim) leaves the other tables unused; tie 0.
	input  [3:0] table_sel,
	// NMK-29: half-populated 82S147 dump (ssmissin/airattck, A5 tied to GND).
	// The dump is loaded RAW (512 bytes at 0..511, hole blocks included) and
	// the compaction table[i] == dump[{i[7:5],1'b0,i[4:0]}] is applied HERE at
	// read time. It used to be applied at load time, keyed on game_sel -- but
	// MiSTer sends the .mra <switches> (index 254, where game_sel comes from)
	// AFTER the ROM parts, so game_sel was still 0 while the PROM streamed and
	// the raw dump went in untransformed: 139/139 entries in the read window
	// wrong, 75 of them zero. game_sel is valid by the time anything is read.
	input        halfpop,

	// Runtime PROM load (2026-09-15). The V-PROM used to be baked into the
	// bitstream by the $readmemh below, which meant a shipped .rbf carried
	// arcade PROM content and the Quartus build needed a locally generated
	// roms/*_vtiming.hex. It now arrives the same way every other ROM does:
	// the .mra streams it as its own <rom index="1"> region and the core
	// drives these three ports from ioctl_download. VTIMING_FILE stays for
	// the HW_ROMS=0 reference sims, which have no ioctl path at all.
	//
	// One table is loaded this way, at table 0, because a .mra can only
	// name ROMs from its own game's zip -- so tie table_sel to 0 on the
	// hardware path. The multi-table VTIMING_FILE layout below is now a
	// simulation-only arrangement.
	input        prom_we,
	input [11:0] prom_addr,
	input  [7:0] prom_data,

	input        line_start,   // pulse at hcount==0, from video_timing
	input  [9:0] vcount,       // 0..277, from video_timing

	input        iack_cycle,   // FC=111 & ~ASn
	input  [3:1] iack_level,   // eab[3:1] during an iack cycle == level being acked

	output [2:0] ipl_level,    // 0,1,2,4 (mustang never sets IRQ3 — see reference)
	output       sprite_dma_trigger
);

	localparam [8:0] PROM_START = 9'd117; // 0x75
	localparam [8:0] PROM_USAGE = 9'd256; // 0x100
	localparam [8:0] PROM_SPAN  = PROM_USAGE - PROM_START; // 139
	localparam [8:0] VPHASE     = 9'd66;  // see header's "Phase calibration"
	localparam [8:0] VTOTAL     = 9'd278;

	reg [7:0] vtiming_prom [0:4095]; // up to sixteen 256-entry tables, see table_sel
	initial if (VTIMING_FILE != "") $readmemh(VTIMING_FILE, vtiming_prom);
	// Synchronous write port, so Quartus still infers M10K here rather than
	// 4096 flops (NMK-10 -- see docs/known-issues.md). Unused on the
	// HW_ROMS=0 path, where prom_we is tied 0 and $readmemh does the work.
	always @(posedge clk_sys)
		if (prom_we) vtiming_prom[prom_addr] <= prom_data;

	// y_arg = (vcount + VPHASE) mod VTOTAL — see header. vcount+VPHASE
	// maxes out at 277+66=343, always < 2*VTOTAL(556), so a single
	// conditional subtract suffices instead of a full modulo. vcount is
	// declared [9:0] but never exceeds 277 (9 bits), matching VPHASE/
	// VTOTAL's own [8:0] width here.
	wire [8:0] y_sum = vcount[8:0] + VPHASE;
	wire [8:0] y_arg = (y_sum >= VTOTAL) ? (y_sum - VTOTAL) : y_sum;

	// Reference: address = ((((y/2) + start) % (usage-start)) + start) % len
	// — mod-before-re-adding-start, matching the reference's own
	// operator precedence exactly (don't simplify away the two-step
	// structure). y/2's max (138) + start (117) = 255, always < 2*SPAN,
	// so again a single conditional subtract replaces the modulo.
	wire [8:0] y2   = {1'b0, y_arg[8:1]};
	wire [8:0] a    = y2 + PROM_START;
	wire [8:0] term = (a >= PROM_SPAN) ? (a - PROM_SPAN) : a;
	wire [7:0] addr = term[7:0] + PROM_START[7:0]; // 117..255, fits in 8 bits

	// REGISTERED read (2026-09-15). This array gained a write port above, so
	// it is now a RAM rather than a $readmemh constant, and an asynchronous
	// read would cost 4096 flops instead of one M10K -- NMK-10, for the
	// fourth time. `addr` is combinational from vcount, which video_timing
	// advances on the cycle hcount wraps, i.e. it is already the new line's
	// value when line_start pulses; the registered read therefore settles
	// one clk_sys later, so the sampling below runs off a one-cycle-delayed
	// line_start. line_start is `ce_pix & (hcount==0)`, exactly one cycle
	// wide, so the delayed copy is too. At 96 MHz the whole decision moves
	// ~10 ns later in a 64 us scanline.
	reg [7:0] rom_q;
	reg       line_start_d;
	reg       vcount0_d;
	always @(posedge clk_sys) begin
		rom_q        <= vtiming_prom[halfpop ? {3'd0, addr[7:5], 1'b0, addr[4:0]} : {table_sel, addr}];
		line_start_d <= line_start;
		vcount0_d    <= vcount[0];
	end
	wire [7:0] rom_val = rom_q;
	wire [2:0] rom_lvl = {rom_val[6], rom_val[5], rom_val[4]};

	reg [7:0] prev_val = 8'hFF; // matches m_vtiming_val's own reset value
	reg [7:1] pending;
	reg       sprdma_pulse;

	always @(posedge clk_sys) begin
		sprdma_pulse <= 1'b0;

		if (reset) begin
			prev_val <= 8'hFF;
			pending  <= 7'd0;
		end else begin
			// Every PROM entry is addressed every 2 scanlines — only
			// even-vcount samples actually address it, matching the
			// reference's own `(y & 0x1) == 0x0` gate exactly.
			if (line_start_d && !vcount0_d) begin
				// Interrupt/sprite-DMA requests trigger on a raw 0->1
				// bit transition (`val & ~prev_val`), computed before
				// prev_val itself updates — matches the reference's own
				// ordering exactly.
				if (rom_val[7] && !prev_val[7] && rom_lvl != 3'd0)
					pending[rom_lvl] <= 1'b1;
				if (rom_val[0] && !prev_val[0])
					sprdma_pulse <= 1'b1;
				prev_val <= rom_val;
			end

			if (iack_cycle && iack_level != 3'd0)
				pending[iack_level] <= 1'b0;
		end
	end

	// Priority-encode the highest pending level — matches real 68000 IPL
	// priority (higher numeric level wins when multiple are pending) and
	// nmk_irq_hacky.sv's own equivalent fixed priority chain.
	function automatic [2:0] highest_pending(input [7:1] p);
		integer i;
		begin
			highest_pending = 3'd0;
			for (i = 1; i <= 7; i = i + 1)
				if (p[i]) highest_pending = i[2:0];
		end
	endfunction
	assign ipl_level = highest_pending(pending);
	assign sprite_dma_trigger = sprdma_pulse;

endmodule
