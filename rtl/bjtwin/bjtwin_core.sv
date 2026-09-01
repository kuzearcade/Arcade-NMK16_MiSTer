// NMK16 MiSTerFPGA project — bjtwin hardware family core.
//
// Tier 1 target: cactus / bjtwinp / nouryokup (docs/game-inventory.md family A,
// docs/PLAN.md Tier 1). This module is the CPU + memory-map + interrupt
// subsystem, built and verified first per docs/PLAN.md's verification
// methodology ("TLCS-90 core validated first in isolation" principle
// applied here to fx68k, since this family has no TLCS-90). Video (tilemap
// + nmk16spr sprite engine) and audio (nmk112 + 2x OKIM6295) are stubbed —
// writes to those regions are captured on the bus (so a MAME oracle diff
// can still validate them) but have no functional effect yet.
//
// Memory map (see docs/PLAN.md Milestone research, "bjtwin_map"):
//   000000-07FFFF  ROM (maincpu)
//   080000-080001  IN0 (R)
//   080002-080003  IN1 (R)
//   080008-080009  DSW1 (R)
//   08000A-08000B  DSW2 (R)
//   080015         flipscreen_w (W, low byte of word 080014)
//   084001         OKI chip 0 data (R/W, low byte of word 084000) [stub]
//   084011         OKI chip 1 data (R/W, low byte of word 084010) [stub]
//   084020-08402E  nmk112 okibank_w, 8 registers, low byte only [stub]
//   088000-0887FF  palette RAM, 1024 x 16
//   094001         tilebank_w (W, low byte of word 094000)
//   094003         bjtwin_scroll_w, Y-scroll only (W, low byte of word 094002)
//   09C000-09CFFF  bg tilemap VRAM, 2048 x 16 (mirrored at 09D000-09DFFF)
//   0F0000-0FFFFF  main work RAM, 32768 x 16 (spriteram sub-region at
//                  0F8000-0F8FFF, DMA'd into the sprite engine — not
//                  implemented yet, see rtl/bjtwin/nmk_irq_hacky.sv)
//
// Clocking: CPU = 10.000000 MHz undivided, pixel/sprite = 8.000000 MHz
// (XTAL(16MHz)/2), OKI x2 = 4.000000 MHz (XTAL(16MHz)/4). clk_sys here is
// 40MHz so the CPU clock-enable is a clean /4 (matching fx68k's own
// fx68kTop reference divider exactly) and the pixel/sprite clock-enable is
// a clean /5 — see ce_pix below. The real PLL parameters to produce 40MHz
// from the DE10-Nano's 50MHz input are a Quartus-integration task, not
// needed for this simulation milestone.
//
// Known simplifications, to be revisited before this is trusted on real
// hardware (documented rather than silently assumed correct):
//   - DTACKn is tied to ASn (0-wait-state memory). Real SDRAM-backed ROM
//     will need genuine wait-state generation; not needed for BRAM-style
//     $readmemh ROM in simulation, and not yet known whether real bjtwin
//     hardware has wait states on any region.
//   - OKI chip read/write ports are stubs (always read 8'hFF, writes are
//     accepted/acked but discarded) — if cactus's boot code polls an OKI
//     busy/status bit before proceeding, this will diverge from the MAME
//     oracle. Flagged as the first thing to check if CPU trace comparison
//     fails partway through.
//   - IN0/IN1/DSW1/DSW2 are tied to fixed idle values (all bits 1) rather
//     than driven by real HPS_IO input — matches MAME's default "nothing
//     pressed" input state for a boot-sequence trace, but not yet wired to
//     actual controller input.
module bjtwin_core #(
	parameter ROM_FILE = ""
) (
	input clk_sys,       // 40 MHz
	input reset,          // async, active high

	// debug/trace outputs for the Verilator testbench (sim/rtl/bjtwin/tb_bjtwin.cpp)
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_uds_n,
	output        dbg_lds_n,
	output        dbg_as_n,
	output [7:0]  dbg_pc_valid_pulse, // one-hot-ish marker, unused placeholder
	output [31:0] dbg_pc
);

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	// CPU: exact fx68kTop /4 pattern (see rtl/third_party/fx68k/fx68k.sv
	// fx68kTop) reproduced here directly (not via fx68kTop itself) since
	// we need independent enables for the video/sprite clock domain too.
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	// pixel/sprite: /5 -> 8MHz from 40MHz. Not consumed by anything yet in
	// this milestone (video isn't implemented), kept here so the clock
	// tree is established once and reused by rtl/bjtwin video modules later.
	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= ce_pix ? 3'd0 : pix_div + 3'd1;

	// ------------------------------------------------------------------
	// fx68k
	// ------------------------------------------------------------------
	wire        eRWn, ASn, LDSn, UDSn, VMAn, VPAn_i;
	wire        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
	wire [15:0] iEdb, oEdb;
	wire [23:1] eab;
	wire        DTACKn = ASn; // 0-wait-state memory, see module header

	wire [2:0] ipl_level;
	wire       IPL0n = ~ipl_level[0];
	wire       IPL1n = ~ipl_level[1];
	wire       IPL2n = ~ipl_level[2];

	// Autovector: request it during any interrupt-acknowledge cycle
	// (FC=111, address strobe active).
	wire iack_cycle = FC0 & FC1 & FC2 & ~ASn;
	wire VPAn = ~iack_cycle;

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(1'b1),
		.extReset(reset),
		.pwrUp(reset),
		.enPhi1(enPhi1),
		.enPhi2(enPhi2),

		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
		.E(), .VMAn(VMAn),

		.FC0(FC0), .FC1(FC1), .FC2(FC2),
		.BGn(BGn),
		.oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
		.DTACKn(DTACKn), .VPAn(VPAn),
		.BERRn(1'b1),
		.BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(IPL0n), .IPL1n(IPL1n), .IPL2n(IPL2n),
		.iEdb(iEdb), .oEdb(oEdb),
		.eab(eab)
	);

	wire [23:0] byte_addr = {eab, 1'b0};
	wire        cpu_write = ~eRWn & ~ASn;
	wire        cpu_read  = eRWn & ~ASn;

	// ------------------------------------------------------------------
	// Address decode
	// ------------------------------------------------------------------
	wire sel_rom      = (byte_addr <= 24'h07FFFF);
	wire sel_in0      = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1      = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040004); // 080008/080009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h040005); // 08000A/08000B
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015, LDS=low byte
	wire sel_oki0      = (byte_addr[23:1] == 23'h042000); // 084000/084001
	wire sel_oki1      = (byte_addr[23:1] == 23'h042008); // 084010/084011
	wire sel_nmk112    = (byte_addr >= 24'h084020) && (byte_addr <= 24'h08402F);
	wire sel_palette   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h0887FF);
	wire sel_tilebank  = (byte_addr[23:1] == 23'h04A000); // 094000/094001
	wire sel_scroll    = (byte_addr[23:1] == 23'h04A001); // 094002/094003
	wire sel_bgvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09DFFF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu)
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143]; // 0x40000 words = 0x80000 bytes
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16)
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr = byte_addr[15:1];
	reg [15:0] mainram_dout;
	always @(posedge clk_sys) begin
		if (sel_mainram & cpu_write) begin
			if (~UDSn) mainram[mainram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) mainram[mainram_addr][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) mainram_dout = mainram[mainram_addr];

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16)
	// ------------------------------------------------------------------
	reg [15:0] palette [0:1023];
	wire [9:0] palette_addr = byte_addr[10:1];
	reg [15:0] palette_dout;
	always @(posedge clk_sys) begin
		if (sel_palette & cpu_write) begin
			if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
			if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) palette_dout = palette[palette_addr];

	// ------------------------------------------------------------------
	// BG tilemap VRAM (2048 x 16, mirrored)
	// ------------------------------------------------------------------
	reg [15:0] bgvram [0:2047];
	wire [10:0] bgvram_addr = byte_addr[11:1];
	reg [15:0] bgvram_dout;
	always @(posedge clk_sys) begin
		if (sel_bgvram & cpu_write) begin
			if (~UDSn) bgvram[bgvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) bgvram[bgvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) bgvram_dout = bgvram[bgvram_addr];

	// ------------------------------------------------------------------
	// I/O registers (stubs where noted, see module header)
	// ------------------------------------------------------------------
	reg [7:0] flip_screen_reg;
	reg [7:0] tilebank_reg;
	reg [7:0] scroll_y_reg;
	reg [7:0] nmk112_bank [0:7];

	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			tilebank_reg    <= 8'h00;
			scroll_y_reg    <= 8'h00;
		end else if (cpu_write & ~LDSn) begin
			if (sel_flip)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank) tilebank_reg    <= oEdb[7:0];
			if (sel_scroll)   scroll_y_reg    <= oEdb[7:0];
			if (sel_nmk112)   nmk112_bank[byte_addr[3:1]] <= oEdb[7:0];
		end
	end

	// Fixed idle input state (see module header) — future work: wire to
	// real HPS_IO player input / dipswitch config.
	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// Read data mux
	// ------------------------------------------------------------------
	reg [15:0] rdata;
	always @(*) begin
		if (sel_rom)          rdata = rom_dout;
		else if (sel_mainram) rdata = mainram_dout;
		else if (sel_palette) rdata = palette_dout;
		else if (sel_bgvram)  rdata = bgvram_dout;
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else if (sel_oki0)    rdata = 16'h00FF; // stub: OKI status/data, see header
		else if (sel_oki1)    rdata = 16'h00FF; // stub
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// nmk_irq — cactus "hacky" fixed-scanline variant
	// (bjtwinp/nouryokup need the real vtiming-PROM state machine, a
	// separate module — see docs/PLAN.md Tier 1 notes; not implemented
	// in this milestone since cactus, the ROM we're validating against,
	// uses the fixed-table variant.)
	// ------------------------------------------------------------------
	wire sprite_dma_trigger;
	nmk_irq_hacky irq_gen (
		.clk_sys(clk_sys),
		.ce_pix(ce_pix),
		.reset(reset),
		.iack_cycle(iack_cycle),
		.iack_level(eab[3:1]),
		.ipl_level(ipl_level),
		.sprite_dma_trigger(sprite_dma_trigger)
	);

	// ------------------------------------------------------------------
	// Debug/trace outputs
	// ------------------------------------------------------------------
	assign dbg_eab    = eab;
	assign dbg_data   = cpu_write ? oEdb : iEdb;
	assign dbg_write  = cpu_write;
	assign dbg_uds_n  = UDSn;
	assign dbg_lds_n  = LDSn;
	assign dbg_as_n   = ASn;
	assign dbg_pc_valid_pulse = 8'h00;
	assign dbg_pc = 32'h0; // PC is not directly observable from fx68k's external pins;
	                        // see tb_bjtwin.cpp for how register-level cross-checking
	                        // is done instead (via oracle R lines + bus-event correlation).

endmodule
