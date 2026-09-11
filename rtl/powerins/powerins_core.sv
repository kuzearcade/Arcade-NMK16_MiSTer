// NMK16 MiSTerFPGA project — powerins (Tier 3, Family C: Z80-direct-sound
// boards) system-level integration. Fourth and final currently-known Tier 3
// port. GAME() line: `GAME(1993,powerins,0,powerins,powerins,nmk16_state,
// empty_init,ROT0,"Atlus","Power Instinct (USA)",MACHINE_SUPPORTS_SAVE)` —
// a clean parent romset, no MACHINE_NOT_WORKING (unlike sibling bootleg
// `powerinsc`, "different sprites' format not implemented", confirming
// `powerins` itself is the right target).
//
// Reused, unmodified: rtl/third_party_gen/t80/T80s.v, rtl/bjtwin/
// video_timing.sv (this project's single shared 8MHz/512-wide raster
// model — see that file's own header for the full "is this really
// game-agnostic" derivation done for this port: the model's internal
// 512@8MHz produces an IDENTICAL real 64us/scanline period to powerins'
// own actual 448@7MHz raster, since 512/8MHz=64us=448/7MHz exactly, so
// nmk_irq's timing is exactly correct in real time regardless of the
// specific htotal/pixel-clock combo, not merely a coarse approximation),
// rtl/nmk_irq/nmk_irq.sv (powerins() calls set_interrupt_timing,
// nmk16.cpp:5736, same as every other Tier 3 port), and rtl/nmk112/
// nmk112.sv (dual OKI bank-switcher).
//
// Video: rtl/powerins/video_powerins.sv (new — see its own header for the
// full derivation: no tilerambank, 11-bit BG code + non-contiguous 5-bit
// BG colour, 6-bit sprite colour widening the palette to 2048 entries, a
// third distinct SCREEN_W=320 "midres" class, and genuinely new sprite
// horizontal-flip logic, the first in this project).
//
// Sound: Z80 + direct YM2203 (jt03) + dual OKIM6295 (jt6295 x2) through
// NMK112 — structurally macross2_core.sv's own sound path, but simpler in
// three confirmed ways:
//   1. `powerins_sound_map` (nmk16.cpp:1219-1225) has NO ROM banking at
//      all (`map(0x0000,0xbfff).rom()` — fixed, flat, no ROM_CONTINUE, no
//      bank-select register anywhere in the Z80 memory map — unlike
//      macross2's own 8-bank E001-selected window).
//   2. `map(0xe000,0xe000).r(m_soundlatch,...)` is READ-ONLY — there is
//      no soundlatch2 at all (`powerins()`'s own machine config has only
//      ONE `GENERIC_LATCH_8`, nmk16.cpp:5752, vs. macross2's two) and no
//      68000-side soundlatch2 read exists in `powerins_map` either
//      (nmk16.cpp:1193-1209, confirmed by reading it directly) — 68000->
//      Z80 communication is strictly one-way here.
//   3. `powerins_map`'s own `100016-100017` is a plain `nopw()`
//      ("IRQ enable or Z80 sound reset like in Macross 2?", genuinely
//      unclear per the reference's own comment) — UNLIKE macross2's own
//      real Z80-reset-line write at this exact same offset. The Z80's
//      reset is therefore tied directly to the global `reset` line here,
//      not held/released by a 68000-driven register.
// soundlatch itself has no data_pending_callback wired anywhere in
// powerins()'s own machine config (confirmed directly, no
// `.set_inputline(m_audiocpu,INPUT_LINE_NMI)` call exists) — a pure
// polling register, same as macross2's own. The Z80's only interrupt
// source is YM2203's own IRQ (`ymsnd.irq_handler().set_inputline(
// m_audiocpu,0)`, nmk16.cpp:5749, plain maskable IRQ0).
//
// Memory map (powerins_map, nmk16.cpp:1193-1209):
//   000000-0FFFFF  ROM (maincpu, 0x100000, TWO ROM_LOAD16_WORD_SWAP files
//                  at consecutive offsets — 93095-3a.u108@0x00000,
//                  93095-4.u109@0x80000 — see tools/mkrom_wordswap.py's
//                  own multi-file --file support, added for this port)
//   100000-100001  SYSTEM (R)
//   100002-100003  P1_P2 (R)
//   100008-100009  DSW1 (R)
//   10000A-10000B  DSW2 (R)
//   100015         flipscreen_w (W, byte, LDS) — stored but not consumed
//                  by rendering, same known-simplification every prior
//                  port's own flip_screen register already has
//   100016-100017  nopw() — genuinely a no-op here (see above), NOT a
//                  Z80-reset write like macross2's own same offset
//   100019         tilebank_w (W, byte, LDS)
//   10001F         soundlatch write (W, byte, LDS — 68000-written,
//                  Z80-read; NO interrupt side effect, see above)
//   120000-120FFF  palette RAM, 2048 x 16 (real — video_powerins, a
//                  WIDER palette than every prior Tier 3 port's own 1024)
//   130000-130007  scroll_w<0> (BG X/Y scroll, umask16(0x00ff) — LDS-
//                  gated low-byte writes only, same pattern as every
//                  Tier 5 port's own single-scroll-register wiring)
//   140000-143FFF  BG tilemap VRAM, 8192 x 16 (real — video_powerins,
//                  SAME smaller size every Tier 5 port's own bgvideoram
//                  used, NOT macross2's own four-times-bigger 0x10000 —
//                  no tilerambank needed, see video_powerins.sv's header)
//   170000-171FFF  tx tilemap VRAM, mirrored +0x1000 (real —
//                  video_powerins, 2048 x 16, same size/mirror
//                  convention as macross2's/gunnail's own)
//   180000-18FFFF  main work RAM, 32768 x 16, plain masked write
//
// Z80 memory map (powerins_sound_map, nmk16.cpp:1219-1225):
//   0000-BFFF  ROM (fixed, no banking at all — see above; only the first
//              0xC000 bytes of the 0x20000-byte audiocpu dump are ever
//              mapped)
//   C000-DFFF  RAM, 0x2000 bytes
//   E000       soundlatch read (from 68000) — READ ONLY, no soundlatch2
//
// Z80 I/O map (macross2_sound_io_map, nmk16.cpp:1157-1164 — reused
// identically, powerins() sets the SAME io map):
//   00-01  YM2203 (jt03) r/w
//   80     OKIM6295 chip 0 (oki1) r/w — through NMK112
//   88     OKIM6295 chip 1 (oki2) r/w — through NMK112
//   90-97  NMK112 bank-select write
//
// Clock: 68000 at XTAL(12'000'000)=12MHz (nmk16.cpp:5732) — a genuinely
// NEW ratio (every prior Tier 3 port used 10MHz or, for raphero, 14MHz).
// From 40MHz: GCD(12000000,40000000)=4000000 -> increment=3,modulus=10
// (verified: 40MHz*3/10=12MHz exact) — a phase accumulator drives
// enPhi1/enPhi2, same "wrap fires enPhi1, defer one enPhi2 to the very
// next non-wrap cycle" technique raphero_core.sv/tdragon2_core.sv already
// use. Verified by directly simulating the accumulator: the repeating
// 10-cycle pattern's enPhi1 pulses land at ticks 4,7,10 (mod 10) — a
// minimum gap of 3 cycles (never 1 or 2), so deferring enPhi2 exactly one
// cycle after each enPhi1 never collides with the next enPhi1.
//
// Z80 at XTAL(12'000'000)/2=6MHz (nmk16.cpp:5734) — ALSO a genuinely new
// ratio (every prior Tier 3 port's own Z80 ran at a clean 4MHz divide).
// From 40MHz: GCD(6000000,40000000)=2000000 -> increment=3,modulus=20
// (40MHz*3/20=6MHz exact) — a single-phase accumulator (T80s only needs
// CEN, not a real divided clock edge, unlike raphero's own TLCS-90/
// nmk004_periph pairing), same registered-pulse style as ym_cen below.
//
// YM2203 at XTAL(12'000'000)/8=1.5MHz (nmk16.cpp:5748) — the SAME
// accumulator every 40MHz-based port already uses (increment=3,
// modulus=80). OKIM6295 x2 at XTAL(16'000'000)/4=4MHz (nmk16.cpp:5753,
// 5757) — the SAME cen every 40MHz-based port's own two-OKI setup
// already uses (oki_cen_cnt==39, clk_sys/40 internal chip cen).
//
// NMK112: instantiated with THIS game's own ROM byte sizes — oki1/oki2
// are each 0x200000 bytes (nmk16.cpp:9027-9030), same size class as
// tdragon2's own, giving ROM0_BYTES=ROM1_BYTES=2097152, MASK0=MASK1=31 —
// comfortably clear of the raphero-discovered 22-bit truncation boundary.
//
// Known simplifications: same general list as every prior port (no audio
// DAC/mixer beyond the bus/register-level integration itself, SYSTEM/
// P1_P2/DSW1/DSW2 tied to fixed idle values, DTACKn tied to ASn, T80's
// WAIT_n tied high, flip_screen stored but not rendered). HALTn tied high
// (no protection MCU on this board). "color" PROM region (0x20 bytes) has
// ZERO consumers anywhere in the emulation (confirmed via
// `grep -c 'memregion("color")'` across nmk16.cpp/nmk16_v.cpp = 0) — not
// extracted, same precedent as raphero's/strahljbl's/tdragonb's own inert
// PROM regions.
module powerins_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI1_ROM_FILE  = "",
	parameter OKI2_ROM_FILE  = "",
	parameter VTIMING_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = ""
) (
	input clk_sys,        // 40 MHz (68000 bus clk_sys*3/10=12MHz; Z80 clk_sys*3/20=6MHz; pixel/raster clk_sys/5=8MHz)
	input reset,            // async, active high

	// debug/trace outputs for the Verilator testbench
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output [15:0] dbg_z80_pc,
	output        dbg_z80_m1_n,
	output        dbg_z80_mreq_n,
	output        dbg_z80_iorq_n,
	output        dbg_z80_int_n,
	output        dbg_z80_reset_n,
	output        dbg_z80_cen,

	output        dbg_ym_we,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_irq_n,

	output        dbg_oki0_we,
	output        dbg_oki1_we,
	output  [7:0] dbg_oki0_chip_dout,
	output  [7:0] dbg_oki1_chip_dout,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [10:0] dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [12:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables (see header for the full derivation).
	// ------------------------------------------------------------------
	// 68000: 12MHz via a phase accumulator — increment=3, modulus=10,
	// "wrap fires enPhi1, defer one enPhi2 to the very next non-wrap
	// cycle" (same technique raphero_core.sv/tdragon2_core.sv already use).
	localparam integer CPU_CEN_INC = 3;
	localparam integer CPU_CEN_MOD = 10;
	reg [3:0] cpu_cen_acc = 4'd0;
	reg       enPhi1 = 1'b0;
	reg       enPhi2 = 1'b0;
	reg       cpu_cen_half_pending = 1'b0;
	always @(posedge clk_sys) begin
		enPhi1 <= 1'b0;
		enPhi2 <= 1'b0;
		if (cpu_cen_acc + CPU_CEN_INC >= CPU_CEN_MOD) begin
			cpu_cen_acc <= cpu_cen_acc + CPU_CEN_INC - CPU_CEN_MOD;
			enPhi1 <= 1'b1;
			cpu_cen_half_pending <= 1'b1;
		end else begin
			cpu_cen_acc <= cpu_cen_acc + CPU_CEN_INC;
			if (cpu_cen_half_pending) begin
				enPhi2 <= 1'b1;
				cpu_cen_half_pending <= 1'b0;
			end
		end
	end

	// Pixel/raster: clk_sys/5=8MHz — same ratio/reset-gating convention
	// as every other 40MHz-based port (see header: exactly matches
	// powerins' own real 64us/scanline rate despite the differing
	// htotal/pixel-clock combo).
	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// Z80: 6MHz via a single-phase accumulator — increment=3, modulus=20
	// (see header).
	localparam integer Z80_CEN_INC = 3;
	localparam integer Z80_CEN_MOD = 20;
	reg [4:0] z80_cen_acc = 5'd0;
	reg       z80_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (z80_cen_acc + Z80_CEN_INC >= Z80_CEN_MOD) begin
			z80_cen_acc <= z80_cen_acc + Z80_CEN_INC - Z80_CEN_MOD;
			z80_cen <= 1'b1;
		end else begin
			z80_cen_acc <= z80_cen_acc + Z80_CEN_INC;
			z80_cen <= 1'b0;
		end
	end

	// YM2203: identical accumulator to every other 40MHz-based port's own
	// ym_cen (increment=3, modulus=80 -> 1.5MHz off 40MHz clk_sys).
	reg [6:0] ym_cen_cnt = 7'd0;
	reg       ym_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (ym_cen_cnt >= 7'd77) begin
			ym_cen_cnt <= ym_cen_cnt + 7'd3 - 7'd80;
			ym_cen <= 1'b1;
		end else begin
			ym_cen_cnt <= ym_cen_cnt + 7'd3;
			ym_cen <= 1'b0;
		end
	end

	// OKIM6295 x2: identical cen to every other 40MHz-based port's own
	// (clk_sys/40 -> 1MHz internal chip cen).
	reg [5:0] oki_cen_cnt = 6'd0;
	wire      oki_cen = (oki_cen_cnt == 6'd39);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 6'd0 : oki_cen_cnt + 6'd1;

	// ------------------------------------------------------------------
	// fx68k
	// ------------------------------------------------------------------
	wire        eRWn, ASn, LDSn, UDSn, VMAn;
	wire        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
	wire [15:0] iEdb, oEdb;
	wire [23:1] eab;

	wire [2:0] ipl_level;
	wire       IPL0n = ~ipl_level[0];
	wire       IPL1n = ~ipl_level[1];
	wire       IPL2n = ~ipl_level[2];

	wire iack_cycle = FC0 & FC1 & FC2 & ~ASn;
	wire VPAn = ~iack_cycle;
	wire DTACKn = ASn | iack_cycle;

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(1'b1), // no protection MCU on this board
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
	// Address decode (68000 side) — see header for the exact addresses.
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h0FFFFF);
	wire sel_system    = (byte_addr[23:1] == 23'h080000); // 100000/100001
	wire sel_p1p2      = (byte_addr[23:1] == 23'h080001); // 100002/100003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h080004); // 100008/100009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h080005); // 10000A/10000B
	wire sel_flip      = (byte_addr[23:1] == 23'h08000A); // 100014/100015, LDS=low byte
	wire sel_tilebank  = (byte_addr[23:1] == 23'h08000C); // 100018/100019, LDS=low byte
	wire sel_soundlatch_w = (byte_addr[23:1] == 23'h08000F); // 10001E/10001F word, byte reg at odd
	wire sel_palette   = (byte_addr >= 24'h120000) && (byte_addr <= 24'h120FFF);
	wire sel_scroll    = (byte_addr >= 24'h130000) && (byte_addr <= 24'h130007);
	wire sel_bgvram    = (byte_addr >= 24'h140000) && (byte_addr <= 24'h143FFF);
	// TX VRAM: 0x170000-0x170fff (2048 words), mirrored at +0x1000 — both
	// ranges alias the same array (ignore the mirror bit, byte_addr[12]).
	wire sel_txvram    = (byte_addr >= 24'h170000) && (byte_addr <= 24'h171FFF);
	wire sel_mainram   = (byte_addr >= 24'h180000) && (byte_addr <= 24'h18FFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu) — 0x100000 bytes = 524288 words (two consecutive
	// ROM_LOAD16_WORD_SWAP files, see tools/mkrom_wordswap.py).
	// ------------------------------------------------------------------
	reg [15:0] rom [0:524287];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[19:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — plain masked write.
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
	// Palette RAM (2048 x 16 — wider than every prior Tier 3 port's own
	// 1024, see header/video_powerins.sv's own header).
	// ------------------------------------------------------------------
	reg [15:0] palette [0:2047];
	wire [10:0] palette_addr = byte_addr[11:1];
	reg [15:0] palette_dout;
	always @(posedge clk_sys) begin
		if (sel_palette & cpu_write) begin
			if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
			if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) palette_dout = palette[palette_addr];

	// ------------------------------------------------------------------
	// BG tilemap VRAM (8192 x 16 — 0x4000 bytes, same smaller size every
	// Tier 5 port's own bgvideoram used, no tilerambank — see header).
	// ------------------------------------------------------------------
	reg [15:0] bgvram [0:8191];
	wire [12:0] bgvram_addr = byte_addr[13:1];
	always @(posedge clk_sys) begin
		if (sel_bgvram & cpu_write) begin
			if (~UDSn) bgvram[bgvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) bgvram[bgvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] bgvram_dout = bgvram[bgvram_addr];

	// ------------------------------------------------------------------
	// TX tilemap VRAM (2048 x 16)
	// ------------------------------------------------------------------
	reg [15:0] txvram [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	always @(posedge clk_sys) begin
		if (sel_txvram & cpu_write) begin
			if (~UDSn) txvram[txvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) txvram[txvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] txvram_dout = txvram[txvram_addr];

	// ------------------------------------------------------------------
	// Dual-port video read taps (video_powerins.sv's own live reads)
	// ------------------------------------------------------------------
	wire [12:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout = bgvram[vid_bgvram_addr];
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout = txvram[vid_txvram_addr];
	wire [10:0] vid_palette_addr;
	wire [15:0] vid_palette_dout = palette[vid_palette_addr];
	wire [10:0] vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout = palette[vid_spr_palette_addr];
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout = mainram[vid_mainram_addr];

	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bgvram_data = bgvram[dbg_bgvram_addr[12:0]];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;

	// scroll_w<0>: 4 byte sub-registers [Xhi,Xlo,Yhi,Ylo], sub-index =
	// byte_addr[2:1], LDS-gated low-byte writes only (umask16(0x00ff) —
	// same effect as every other port's own manual LDS gating).
	reg [7:0] scroll_reg [0:3];
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire [15:0] bg_xscroll = {scroll_reg[0], scroll_reg[1]};
	wire [15:0] bg_yscroll = {scroll_reg[2], scroll_reg[3]};

	integer si;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			for (si = 0; si < 4; si = si + 1) scroll_reg[si] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank & ~LDSn) bgbank_reg      <= oEdb[7:0];
			if (sel_scroll & ~LDSn)   scroll_reg[scroll_word_idx] <= oEdb[7:0];
		end
	end

	localparam [15:0] SYSTEM_IDLE = 16'hFFFF;
	localparam [15:0] P1P2_IDLE   = 16'hFFFF;
	localparam [15:0] DSW1_IDLE   = 16'hFFFF;
	localparam [15:0] DSW2_IDLE   = 16'hFFFF;

	// ------------------------------------------------------------------
	// soundlatch (68000->Z80, main2sub) — plain polling register, NO
	// interrupt side effect (see header). No soundlatch2 here at all.
	// ------------------------------------------------------------------
	reg [7:0] soundlatch_data;
	always @(posedge clk_sys) begin
		if (reset) soundlatch_data <= 8'h00;
		else if (sel_soundlatch_w & cpu_write & ~LDSn) soundlatch_data <= oEdb[7:0];
	end

	// ------------------------------------------------------------------
	// Z80 sound board: T80 + jt03 (YM2203) + NMK112 + jt6295 x2 (OKI)
	// ------------------------------------------------------------------
	wire [15:0] z80_a;
	wire [7:0]  z80_do;
	wire [7:0]  z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
	wire        z80_int_n;

	assign z80_int_n = ym_chip_irq_n;
	// No 68000-driven Z80 reset register here (powerins_map's own
	// 100016-100017 is a plain nopw(), see header) — reset ties directly
	// to the global reset line.
	wire z80_reset_n = ~reset;

	T80s z80_cpu (
		.RESET_n(z80_reset_n),
		.CLK(clk_sys),
		.CEN(z80_cen),
		.WAIT_n(1'b1),
		.INT_n(z80_int_n),
		.NMI_n(1'b1),
		.BUSRQ_n(1'b1),
		.OUT0(1'b0),
		.DI(z80_di),
		.M1_n(z80_m1_n),
		.MREQ_n(z80_mreq_n),
		.IORQ_n(z80_iorq_n),
		.RD_n(z80_rd_n),
		.WR_n(z80_wr_n),
		.RFSH_n(z80_rfsh_n),
		.HALT_n(z80_halt_n),
		.BUSAK_n(z80_busak_n),
		.A(z80_a),
		.DO(z80_do)
	);

	wire z80_mem_we = ~z80_mreq_n & ~z80_wr_n;
	wire z80_mem_re = ~z80_mreq_n & ~z80_rd_n;
	wire z80_io_we = ~z80_iorq_n & ~z80_wr_n;
	wire z80_io_re = ~z80_iorq_n & ~z80_rd_n;

	// powerins_sound_map: 0000-BFFF ROM (fixed, no banking at all — see
	// header), C000-DFFF RAM, E000 soundlatch read only.
	wire sel_z80_rom   = (z80_a < 16'hC000);
	wire sel_z80_ram   = (z80_a >= 16'hC000) && (z80_a < 16'hE000);
	wire sel_z80_soundlatch_r = (z80_a == 16'hE000);

	wire sel_io_ym_addr = (z80_a[7:0] == 8'h00);
	wire sel_io_ym_data = (z80_a[7:0] == 8'h01);
	wire sel_io_ym      = sel_io_ym_addr | sel_io_ym_data;
	wire sel_io_oki0    = (z80_a[7:0] == 8'h80);
	wire sel_io_oki1    = (z80_a[7:0] == 8'h88);
	wire sel_io_nmk112  = (z80_a[7:0] >= 8'h90) && (z80_a[7:0] <= 8'h97);

	// Audiocpu ROM: full 0x20000-byte flat image — only the first 0xC000
	// bytes are ever mapped/addressed (see header), rest of the array is
	// simply never read.
	reg [7:0] audiocpu_rom [0:131071];
	initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);

	reg [7:0] z80_ram [0:8191];
	always @(posedge clk_sys) if (sel_z80_ram & z80_mem_we) z80_ram[z80_a[12:0]] <= z80_do;

	// ------------------------------------------------------------------
	// YM2203 — real jt03. Same write-stretch pattern as every other
	// 40MHz-based port's own (40-cycle hold).
	//
	// BUG FOUND AND FIXED during this port's own bring-up (not present —
	// or at least never triggered — in macross2/tdragon2/raphero's own
	// identical-looking code, whose own boot ROMs may never happen to
	// read the status port immediately after a data-port write): jt03's
	// own `addr` input selects BOTH which register a write lands on AND
	// which byte a READ returns (offset0=address/status, `{busy,5'd0,
	// flag_B,flag_A}`; offset1=the embedded YM2149 PSG's own data-port
	// read, NOT the status byte — see jt12_dout.v). A write-only latch
	// for `addr` (updated solely on a new write's rising edge, held
	// unchanged otherwise) is WRONG for reads: after the Z80 write-polls
	// on a real busy-wait subroutine (`IN A,(0)` — offset0/status), the
	// most recent WRITE was very likely to the DATA port (offset1), so
	// the write-only latch stays parked on `addr=1`, and the "status"
	// read silently returns the PSG data byte instead — with bit7
	// essentially never reflecting the real busy flag. Confirmed via a
	// live jt12_mmr.v `busy`/`write` trace (temporary debug taps, since
	// reverted) that the Z80 issued several MORE register writes while
	// jt12_mmr's own `busy` was still genuinely 1, repeatedly resetting
	// its own 32-clk_en busy timer, until the writes finally landed
	// close enough together that the accumulated real busy window
	// outlasted the simulation — the READ side never actually seeing a
	// correct busy bit is what let the Z80 charge ahead of the chip in
	// the first place. Fixed by making `addr` track the LIVE port
	// decode during a plain read (`sel_io_ym_data`, off the current
	// `z80_a`), falling back to the write-latched value ONLY while a
	// write-stretch is actually in flight (`ym_wr_hold!=0`) — the latch
	// is still required there since the Z80's own `z80_a` bus has
	// already moved on well before the artificial 40-cycle write hold
	// elapses.
	// ------------------------------------------------------------------
	reg [7:0] ym_din_latch;
	reg       ym_addr_latch;
	reg [5:0] ym_wr_hold = 6'd0;
	reg       ym_we_prev = 1'b0;
	wire      ym_we_raw = z80_io_we & sel_io_ym;
	always @(posedge clk_sys) begin
		ym_we_prev <= ym_we_raw;
		if (ym_we_raw && !ym_we_prev) begin
			ym_din_latch  <= z80_do;
			ym_addr_latch <= sel_io_ym_data; // 0x00=addr/status (offset0), 0x01=data (offset1)
			ym_wr_hold    <= 6'd40;
		end else if (ym_wr_hold != 6'd0) begin
			ym_wr_hold <= ym_wr_hold - 6'd1;
		end
	end
	wire ym_wr_n = ~(ym_wr_hold != 6'd0);
	// Live during a plain read (or when idle); latched only while a
	// write-stretch is actually in flight — see the header note above.
	wire ym_addr_sel = (ym_wr_hold != 6'd0) ? ym_addr_latch : sel_io_ym_data;

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_sel), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(), .snd(), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// NMK112 — reg_sel[2]=chip, reg_sel[1:0]=banknum, matching
	// okibank_w's own offset decode (z80_a[2:0] directly).
	// ------------------------------------------------------------------
	wire nmk112_we = z80_io_we & sel_io_nmk112;
	wire [17:0] oki0_rom_addr_raw, oki1_rom_addr_raw;
	wire [21:0] oki0_rom_addr, oki1_rom_addr;

	nmk112 #(
		.ROM0_BYTES(2097152), // 93095-10.u48+93095-11.u49, 0x200000
		.ROM1_BYTES(2097152)  // 93095-8.u46+93095-9.u47, 0x200000
	) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(z80_a[2:0]), .reg_data(z80_do), .reg_we(nmk112_we),
		.rom0_addr_in(oki0_rom_addr_raw), .rom0_addr_out(oki0_rom_addr),
		.rom1_addr_in(oki1_rom_addr_raw), .rom1_addr_out(oki1_rom_addr)
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, driven by the Z80's own I/O bus through
	// NMK112. Same latch-and-hold write-stretch pattern as every other
	// Z80-domain OKI integration in this project.
	// ------------------------------------------------------------------
	reg [7:0] oki0_rom [0:2097151]; // 93095-10.u48+93095-11.u49, 0x200000
	reg [7:0] oki1_rom [0:2097151]; // 93095-8.u46+93095-9.u47, 0x200000
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki0_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki1_rom);

	reg [7:0] oki0_rom_data, oki1_rom_data;
	always @(posedge clk_sys) oki0_rom_data <= oki0_rom[oki0_rom_addr[20:0]];
	always @(posedge clk_sys) oki1_rom_data <= oki1_rom[oki1_rom_addr[20:0]];

	wire sel_oki0_we = z80_io_we & sel_io_oki0;
	wire sel_oki1_we = z80_io_we & sel_io_oki1;
	reg [7:0] oki0_din_latch, oki1_din_latch;
	reg [5:0] oki0_wr_hold = 6'd0, oki1_wr_hold = 6'd0;
	reg       oki0_we_prev = 1'b0, oki1_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		oki0_we_prev <= sel_oki0_we;
		if (sel_oki0_we && !oki0_we_prev) begin
			oki0_din_latch <= z80_do;
			oki0_wr_hold   <= 6'd40;
		end else if (oki0_wr_hold != 6'd0) begin
			oki0_wr_hold <= oki0_wr_hold - 6'd1;
		end
	end
	always @(posedge clk_sys) begin
		oki1_we_prev <= sel_oki1_we;
		if (sel_oki1_we && !oki1_we_prev) begin
			oki1_din_latch <= z80_do;
			oki1_wr_hold   <= 6'd40;
		end else if (oki1_wr_hold != 6'd0) begin
			oki1_wr_hold <= oki1_wr_hold - 6'd1;
		end
	end
	wire oki0_wr_n = ~(oki0_wr_hold != 6'd0);
	wire oki1_wr_n = ~(oki1_wr_hold != 6'd0);

	wire [7:0] oki0_chip_dout, oki1_chip_dout;
	jt6295 oki0_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(1'b0),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki0_chip_dout),
		.rom_addr(oki0_rom_addr_raw), .rom_data(oki0_rom_data), .rom_ok(1'b1),
		.sound(), .sample()
	);
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(1'b0),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr_raw), .rom_data(oki1_rom_data), .rom_ok(1'b1),
		.sound(), .sample()
	);

	// ------------------------------------------------------------------
	// Z80 read-data mux
	// ------------------------------------------------------------------
	reg [7:0] z80_rdata;
	always @(*) begin
		if (sel_z80_rom)        z80_rdata = audiocpu_rom[z80_a[14:0]];
		else if (sel_z80_ram)   z80_rdata = z80_ram[z80_a[12:0]];
		else if (z80_mem_re & sel_z80_soundlatch_r) z80_rdata = soundlatch_data;
		else if (z80_io_re & sel_io_ym)   z80_rdata = ym_chip_dout;
		else if (z80_io_re & sel_io_oki0) z80_rdata = oki0_chip_dout;
		else if (z80_io_re & sel_io_oki1) z80_rdata = oki1_chip_dout;
		else                     z80_rdata = 8'hFF;
	end
	assign z80_di = z80_rdata;

	// ------------------------------------------------------------------
	// 68000 read-data mux
	// ------------------------------------------------------------------
	reg [15:0] rdata;
	always @(*) begin
		if (sel_rom)          rdata = rom_dout;
		else if (sel_mainram) rdata = mainram_dout;
		else if (sel_palette) rdata = palette_dout;
		else if (sel_bgvram)  rdata = bgvram_dout;
		else if (sel_txvram)  rdata = txvram_dout;
		else if (sel_system)  rdata = SYSTEM_IDLE;
		else if (sel_p1p2)    rdata = P1P2_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + REAL V-PROM interrupt generation (see header —
	// video_timing.sv's own fixed 512@8MHz model, unmodified).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);

	wire sprite_dma_trigger;
	nmk_irq #(
		.VTIMING_FILE(VTIMING_FILE)
	) irq_gen (
		.clk_sys(clk_sys),
		.table_sel(3'd0),
		.reset(reset),
		.line_start(vt_line_start),
		.vcount(vt_vcount),
		.iack_cycle(iack_cycle),
		.iack_level(eab[3:1]),
		.ipl_level(ipl_level),
		.sprite_dma_trigger(sprite_dma_trigger)
	);

	// ------------------------------------------------------------------
	// Video pipeline — rtl/powerins/video_powerins.sv (see its own header
	// for the full derivation).
	// ------------------------------------------------------------------
	video_powerins #(
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.SPRITES_FILE(SPRITES_FILE)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.sprite_dma_trigger(sprite_dma_trigger),
		.bgvram_addr(vid_bgvram_addr), .bgvram_data(vid_bgvram_dout),
		.txvram_addr(vid_txvram_addr), .txvram_data(vid_txvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout),
		.bg_xscroll(bg_xscroll), .bg_yscroll(bg_yscroll),
		.bg_bank(bgbank_reg),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb)
	);

	reg frame_done_r;
	always @(posedge clk_sys) begin
		frame_done_r <= vt_line_start && (vt_vcount == 10'd0);
	end
	assign frame_done = frame_done_r;

	// ------------------------------------------------------------------
	// Debug/trace outputs
	// ------------------------------------------------------------------
	assign dbg_eab   = eab;
	assign dbg_data  = cpu_write ? oEdb : iEdb;
	assign dbg_write = cpu_write;
	assign dbg_as_n  = ASn;
	assign dbg_fc0   = FC0;
	assign dbg_fc1   = FC1;
	assign dbg_fc2   = FC2;

	assign dbg_z80_pc = z80_a; // no direct PC tap through T80s' port list; address bus is the closest available proxy during an M1 fetch
	assign dbg_z80_m1_n = z80_m1_n;
	assign dbg_z80_mreq_n = z80_mreq_n;
	assign dbg_z80_iorq_n = z80_iorq_n;
	assign dbg_z80_int_n = z80_int_n;
	assign dbg_z80_reset_n = z80_reset_n;
	assign dbg_z80_cen = z80_cen;

	assign dbg_ym_we = ym_we_raw;
	assign dbg_ym_cs = sel_io_ym;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_irq_n = ym_chip_irq_n;

	assign dbg_oki0_we = sel_oki0_we;
	assign dbg_oki1_we = sel_oki1_we;
	assign dbg_oki0_chip_dout = oki0_chip_dout;
	assign dbg_oki1_chip_dout = oki1_chip_dout;

endmodule
