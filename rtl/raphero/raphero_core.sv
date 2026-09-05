// NMK16 MiSTerFPGA project — raphero (Tier 3, Family C) system-level
// integration. Third Tier 3 port, after macross2/tdragon2 — read
// rtl/macross2/macross2_core.sv's and rtl/tdragon2/tdragon2_core.sv's own
// headers first for the shared architecture, not re-explained here.
// `arcadian`/`raphero`/`rapheroa` all share the identical raphero()
// machine config (nmk16.cpp:5554-5597) — this file targets `raphero`
// itself as the representative romset.
//
// TWO genuinely new things versus every prior Tier 3 port, both confirmed
// directly against the reference:
//
// 1. **Sound CPU is TLCS-90, not Z80.** raphero() uses
//    `TMP90841(config,m_audiocpu,XTAL(16'000'000)/2)` (nmk16.cpp:5561) —
//    the SAME TLCS-90 core family already built for NMK004/protection-MCU
//    roles (rtl/tlcs90/tlcs90.sv), wired here as a bare sound CPU with its
//    own direct memory-mapped bus to YM2203/dual-OKI/NMK112
//    (raphero_sound_mem_map, nmk16.cpp:1134-1145), not through NMK004's
//    host-latch handshake or the protection-MCU's shared-RAM scheme.
//    Confirmed directly from mame/src/devices/cpu/tlcs90/tlcs90.cpp:
//    `tmp90841_mem()` (line 80-84) is "rom-less" (no internal boot ROM,
//    unlike TMP90840's own 8KB) but uses the IDENTICAL internal 256B RAM
//    (0xFEC0-0xFFBF) and peripheral register block (`tmp90840_regs`,
//    0xFFC0-0xFFEF) as TMP90840 — i.e. the SAME register map
//    rtl/tlcs90/nmk004_periph.sv already implements. Reused here
//    UNMODIFIED (p5/p6/p7_ext_en tied low for "plain" behavior, matching
//    nmk004_core.sv's own instantiation pattern exactly — see that file
//    for the template this follows). YM2203's own IRQ maps to MAME's
//    "line 0" (ymsnd.irq_handler().set_inputline(m_audiocpu,0),
//    nmk16.cpp:5580) = INT0 = irq_req bit0 (per nmk004_periph.sv's own
//    documented bit ordering) — OR'd in exactly like nmk004_core.sv's own
//    `irq_req_to_cpu` pattern, not exposed as a separate CPU input.
//
//    CRITICAL, easy-to-miss subtlety: raphero_sound_mem_map's own
//    `map(0xe000,0xffff).ram()` declaration does NOT mean the full
//    0x2000-byte range is external RAM — the real TLCS-90 chip's own
//    fixed internal RAM (0xFEC0-0xFFBF) and peripheral SFRs
//    (0xFFC0-0xFFEF) sit ABOVE MAME's own board-level address_map
//    dispatch entirely (confirmed via tlcs90_device's own base-class
//    tmp90841_mem(), which the CPU device installs on its OWN internal
//    memory space, intercepting those addresses before nmk16.cpp's own
//    driver-level map ever sees them — same reasoning nmk004_core.sv's
//    own header already documents for NMK004's own case). So the REAL
//    external RAM only backs 0xE000-0xFEBF (0x1EC0 = 7872 bytes); 0xFEC0+
//    is routed to internal RAM/nmk004_periph.sv instead, regardless of
//    the literal board-level ROM_START/memory-map text.
//
//    Also confirmed: raphero_map's own `map(0x100016,0x100017).nopw()`
//    (nmk16.cpp:1122, "IRQ enable or z80 sound reset like in Macross 2?")
//    is a genuine no-op here — UNLIKE macross2's/tdragon2's own
//    macross2_sound_reset_w at the identical address, raphero's own
//    TLCS-90 has NO software-triggered reset capability from the 68000 at
//    all. It runs continuously off the shared global reset only.
//
// 2. **Video is a genuine hybrid** — see rtl/raphero/video_raphero.sv's
//    own header for the full derivation (per-scanline raster scroll from
//    video_gunnail.sv's own approach + tilerambank BG-VRAM banking from
//    video_macross2.sv's own approach, re-sourced from a 16-bit word
//    register instead of an 8-bit byte one).
//
// Memory map (raphero_map, nmk16.cpp:1113-1132):
//   000000-07FFFF  ROM (maincpu, 0x80000, single ROM_LOAD16_WORD_SWAP file)
//   100000-100001  IN0 (R)
//   100002-100003  IN1 (R)
//   100008-100009  DSW1 (R)
//   10000A-10000B  DSW2 (R)
//   10000F         soundlatch2 read (R, byte)
//   100015         flipscreen_w (W, byte)
//   100016-100017  nopw (genuinely unused here — see above)
//   100019         tilebank_w (W, byte)
//   10001F         soundlatch write (W, byte)
//   120000-1207FF  palette RAM, 1024 x 16 (real — video_raphero)
//   130000-1301FF  gunnail_scrollram, 256 x 16, raphero_scroll_w
//                  (nmk16_v.cpp:295-311 — COMBINE_DATA + tilerambank
//                  derivation on offset==0: newbank=(scrollram[0]>>12)&3)
//   130200-1303FF  gunnail_scrollramy, 256 x 16, plain (no side effect)
//   130400-1307FF  plain unnamed RAM, 0x400 bytes (nmk16.cpp:1128 — no
//                  named purpose in the reference, implemented faithfully
//                  as inert storage, not investigated further)
//   140000-14FFFF  BG tilemap VRAM, 32768 x 16 (real — video_raphero)
//   170000-170FFF  tx tilemap VRAM, mirrored +0x1000 (real — video_raphero)
//   1F0000-1FFFFF  main work RAM, 32768 x 16 — address-line-swapped for
//                  the CPU-facing path ONLY (mainram_swapped_r/w, same
//                  bits-7/10 swap tdragon2_core.sv already implements;
//                  same sprite-DMA-bypasses-the-swap subtlety applies
//                  here too — the video module's own mainram tap stays
//                  UNSWAPPED)
//
// TLCS-90 external bus decode (raphero_sound_mem_map, nmk16.cpp:1134-1145
// — genuinely new, memory-mapped not I/O-port-mapped like macross2's own):
//   0000-7FFF  ROM (fixed)
//   8000-BFFF  banked ROM window, 8 x 0x4000-byte banks
//              (init_banked_audiocpu() — same convention as every prior
//              Tier 3 port)
//   C000-C001  YM2203 (jt03) r/w
//   C800       OKIM6295 chip 0 (oki1) r/w
//   C808       OKIM6295 chip 1 (oki2) r/w
//   C810-C817  NMK112 bank-select write (8 registers)
//   D000       audiobank select write (macross2_audiobank_w — same
//              function every Tier 3/gunnailb port reuses)
//   D800       soundlatch read (from 68000) / soundlatch2 write (to 68000)
//   E000-FEBF  RAM, 0x1EC0 bytes (external — see note above; NOT the full
//              declared E000-FFFF, since FEC0+ is intercepted internally)
//   FEC0-FFBF  TLCS-90 internal RAM, 256 bytes (nmk004_periph-adjacent —
//              same fixed location as NMK004's own tmp90840_mem)
//   FFC0-FFEF  TLCS-90 peripheral registers — rtl/tlcs90/nmk004_periph.sv,
//              reused unmodified
//
// Clock: 68000 at XTAL(14'000'000)=14MHz (nmk16.cpp:5557) — a genuinely
// NEW ratio, not the 10MHz every prior Tier 3 port used. Staying on the
// established 40MHz clk_sys convention: GCD(14000000,40000000)=2000000 ->
// increment=7,modulus=20 (verified: 40MHz*7/20=14MHz exact) — a small
// phase accumulator drives enPhi1/enPhi2 (same "wrap fires enPhi1, defer
// one enPhi2 to the very next non-wrap cycle" technique tdragon2_core.sv/
// strahljbl_core.sv already use). Verified by directly simulating the
// accumulator: minimum gap between consecutive enPhi1 pulses is 2 cycles
// (never 1), so deferring enPhi2 exactly one cycle after each enPhi1
// never collides with the next enPhi1 — strict alternation holds for
// every step of the repeating 20-cycle pattern, zero violations.
//
// TLCS-90 (audiocpu) at XTAL(16'000'000)/2=8MHz (nmk16.cpp:5561). From
// 40MHz: GCD(8000000,40000000)=8000000 -> increment=1,modulus=5, a CLEAN
// divide (40MHz/5=8MHz exactly). UNLIKE T80s/jt03/jt6295 (clk=full-rate
// clk_sys + separate cen input), tlcs90.sv/nmk004_periph.sv need a REAL
// divided CLOCK EDGE on their own `clk` port (confirmed directly from
// rtl/mustang/mustang_core.sv's own nmk004_core instantiation:
// `.clk(nmk004_clk_r)`, a genuinely toggled signal, not clk_sys+cen) — so
// `tlcs90_clk` below is a real 8MHz square-ish wave (one clean rising
// edge every 5 clk_sys cycles, not necessarily 50% duty — duty cycle
// doesn't matter for a purely-synchronous digital core, only rising-edge
// timing does), not a clk_sys-rate enable pulse.
//
// YM2203 at XTAL(12'000'000)/8=1.5MHz (nmk16.cpp:5579) — the SAME
// accumulator every 40MHz-based port already uses (increment=3,
// modulus=80). OKIM6295 x2 at XTAL(16'000'000)/4=4MHz (nmk16.cpp:5590,
// 5594) — the SAME cen every 40MHz-based port's own two-OKI setup
// already uses (oki_cen_cnt==39, clk_sys/40 internal chip cen).
//
// NMK112: reused unmodified, instantiated with THIS game's own ROM byte
// sizes — oki1/oki2 are each 0x400000 bytes (nmk16.cpp:8598-8604, double
// tdragon2's own oki1, quadruple macross2's own oki2), giving
// ROM0_BYTES=ROM1_BYTES=4194304, MASK0=MASK1=63 (6-bit). Verified this is
// still safely within nmk112.sv's own 22-bit output-width headroom (page
// 63 shifted left 16 = 0x3F0000, which fits in 22 bits; the module's own
// worst-case-representable page before truncation is exactly 63 — this
// game's own valid range sits RIGHT AT that boundary with zero slack, not
// past it, confirmed by direct calculation, not assumed safe by
// resemblance to a smaller prior case).
//
// Known simplifications: same general list as every prior port (no audio
// DAC/mixer beyond bus/register-level integration, IN0/IN1/DSW1/DSW2 tied
// to fixed idle values, DTACKn tied to ASn, TLCS-90's own NMI tied
// inactive — no NMI source anywhere in raphero's own machine config).
// HALTn tied high (no protection MCU on this board).
module raphero_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI1_ROM_FILE  = "",
	parameter OKI2_ROM_FILE  = "",
	parameter VTIMING_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = ""
) (
	input clk_sys,        // 40 MHz (68000 bus clk_sys*7/20=14MHz; pixel/raster clk_sys/5=8MHz)
	input reset,            // async, active high

	// debug/trace outputs for the Verilator testbench
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output [15:0] dbg_snd_pc,
	output        dbg_snd_valid,
	output        dbg_snd_cen,

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
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [14:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	// 68000: 14MHz via a phase accumulator (see header) — increment=7,
	// modulus=20, "wrap fires enPhi1, defer one enPhi2 to the very next
	// non-wrap cycle" (same technique tdragon2_core.sv/strahljbl_core.sv
	// already use).
	localparam integer CPU_CEN_INC = 7;
	localparam integer CPU_CEN_MOD = 20;
	reg [4:0] cpu_cen_acc = 5'd0;
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
	// as every other 40MHz-based port.
	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// TLCS-90: a REAL divided clock edge, not a clk_sys-rate cen (see
	// header) — clk_sys/5=8MHz, a clean divide. One rising edge every 5
	// clk_sys cycles, regardless of exact duty split.
	reg [2:0] tlcs90_clk_div = 3'd0;
	always @(posedge clk_sys) tlcs90_clk_div <= (tlcs90_clk_div == 3'd4) ? 3'd0 : tlcs90_clk_div + 3'd1;
	wire tlcs90_clk = (tlcs90_clk_div >= 3'd3);

	// YM2203: identical accumulator to every other 40MHz-based port's own
	// ym_cen (increment=3, modulus=80 -> 1.5MHz).
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
	wire sel_rom       = (byte_addr <= 24'h07FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h080000); // 100000/100001
	wire sel_in1       = (byte_addr[23:1] == 23'h080001); // 100002/100003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h080004); // 100008/100009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h080005); // 10000A/10000B
	wire sel_soundlatch2_r = (byte_addr[23:1] == 23'h080007); // 10000E/10000F word, byte reg at odd
	wire sel_flip      = (byte_addr[23:1] == 23'h08000A); // 100014/100015, LDS=low byte
	// 100016/100017 is nopw() here — genuinely unused, no register at all
	// (see header — unlike macross2's/tdragon2's own sound-reset here).
	wire sel_tilebank  = (byte_addr[23:1] == 23'h08000C); // 100018/100019, LDS=low byte
	wire sel_soundlatch_w = (byte_addr[23:1] == 23'h08000F); // 10001E/10001F word, byte reg at odd
	wire sel_palette   = (byte_addr >= 24'h120000) && (byte_addr <= 24'h1207FF);
	wire sel_scrollram  = (byte_addr >= 24'h130000) && (byte_addr <= 24'h1301FF);
	wire sel_scrollramy = (byte_addr >= 24'h130200) && (byte_addr <= 24'h1303FF);
	wire sel_pad0400    = (byte_addr >= 24'h130400) && (byte_addr <= 24'h1307FF); // plain unnamed RAM, see header
	wire sel_bgvram    = (byte_addr >= 24'h140000) && (byte_addr <= 24'h14FFFF);
	// TX VRAM: 0x170000-0x170fff (2048 words), mirrored at +0x1000 — both
	// ranges alias the same array (ignore the mirror bit, byte_addr[12]).
	wire sel_txvram    = (byte_addr >= 24'h170000) && (byte_addr <= 24'h171FFF);
	wire sel_mainram   = (byte_addr >= 24'h1F0000) && (byte_addr <= 24'h1FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu) — 0x80000 bytes = 262144 words.
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — address-line-swapped for the CPU-facing
	// path ONLY (same bits-7/10 swap tdragon2_core.sv already implements
	// — see this file's own header).
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr_cpu =
		{byte_addr[15:12], byte_addr[8], byte_addr[10:9], byte_addr[11], byte_addr[7:1]};
	reg [15:0] mainram_dout;
	always @(posedge clk_sys) begin
		if (sel_mainram & cpu_write) begin
			if (~UDSn) mainram[mainram_addr_cpu][15:8] <= oEdb[15:8];
			if (~LDSn) mainram[mainram_addr_cpu][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) mainram_dout = mainram[mainram_addr_cpu];

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
	// BG tilemap VRAM (32768 x 16)
	// ------------------------------------------------------------------
	reg [15:0] bgvram [0:32767];
	wire [14:0] bgvram_addr = byte_addr[15:1];
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
	// gunnail_scrollram / gunnail_scrollramy (256 x 16 each) +
	// raphero_scroll_w's own tilerambank derivation (nmk16_v.cpp:295-311)
	// — see header. Only scrollram (not scrollramy) has the tilerambank
	// side effect, and only on an offset-0 write.
	// ------------------------------------------------------------------
	reg [15:0] scrollram  [0:255];
	reg [15:0] scrollramy [0:255];
	wire [7:0] scrollram_waddr  = byte_addr[8:1];
	wire [7:0] scrollramy_waddr = byte_addr[8:1];
	wire       sel_scrollram_off0 = sel_scrollram & (scrollram_waddr == 8'd0);

	reg [1:0] tilerambank_reg;

	// Plain unnamed 0x400-byte RAM block (0x130400-0x1307FF) — no named
	// purpose in the reference, implemented as inert storage.
	reg [7:0] pad0400 [0:1023];
	wire [9:0] pad0400_addr = byte_addr[10:1];

	integer si2;
	always @(posedge clk_sys) begin
		if (reset) begin
			tilerambank_reg <= 2'd0;
			for (si2 = 0; si2 < 256; si2 = si2 + 1) begin
				scrollram[si2]  <= 16'h0000;
				scrollramy[si2] <= 16'h0000;
			end
		end else if (cpu_write) begin
			if (sel_scrollram) begin
				if (~UDSn) scrollram[scrollram_waddr][15:8] <= oEdb[15:8];
				if (~LDSn) scrollram[scrollram_waddr][7:0]  <= oEdb[7:0];
				// newbank = (scrollram[0]>>12) & 3 — bits[13:12] of the WORD
				// (verified independently against the reference, NOT
				// pattern-matched from macross2's own byte-register bit
				// positions). Uses the JUST-WRITTEN byte(s) combined with
				// whichever half wasn't written this cycle (matching the
				// reference's own read-modify-write via COMBINE_DATA before
				// re-reading scrollram[0]).
				if (sel_scrollram_off0)
					tilerambank_reg <= (~UDSn ? oEdb[13:12] : scrollram[0][13:12]);
			end
			if (sel_scrollramy) begin
				if (~UDSn) scrollramy[scrollramy_waddr][15:8] <= oEdb[15:8];
				if (~LDSn) scrollramy[scrollramy_waddr][7:0]  <= oEdb[7:0];
			end
			if (sel_pad0400 & ~LDSn) pad0400[pad0400_addr] <= oEdb[7:0];
		end
	end
	wire [15:0] scrollram_dout  = scrollram[scrollram_waddr];
	wire [15:0] scrollramy_dout = scrollramy[scrollramy_waddr];
	wire [15:0] pad0400_dout    = {8'h00, pad0400[pad0400_addr]};

	// ------------------------------------------------------------------
	// Dual-port video read taps (video_raphero.sv's own live reads).
	// vid_mainram_addr/dout is DELIBERATELY UNSWAPPED (sprite-DMA snapshot
	// mechanism — see header).
	// ------------------------------------------------------------------
	wire [14:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout = bgvram[vid_bgvram_addr];
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout = txvram[vid_txvram_addr];
	wire [9:0]  vid_palette_addr;
	wire [15:0] vid_palette_dout = palette[vid_palette_addr];
	wire [9:0]  vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout = palette[vid_spr_palette_addr];
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout = mainram[vid_mainram_addr];

	wire [7:0] vid_scrollram_row_addr;
	wire [7:0] vid_scrollramy_row_addr;
	wire [15:0] vid_scrollram_0    = scrollram[0];
	wire [15:0] vid_scrollramy_0   = scrollramy[0];
	wire [15:0] vid_scrollram_row  = scrollram[vid_scrollram_row_addr];
	wire [15:0] vid_scrollramy_row = scrollramy[vid_scrollramy_row_addr];

	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bgvram_data = bgvram[dbg_bgvram_addr[14:0]];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;

	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank & ~LDSn) bgbank_reg      <= oEdb[7:0];
		end
	end

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// soundlatch (68000->TLCS-90, main2sub) / soundlatch2 (TLCS-90->68000,
	// sub2main) — plain polling registers, no interrupt side effect on
	// either direction (raphero's own machine config wires no
	// data_pending_callback anywhere, same as macross2's/tdragon2's own).
	// ------------------------------------------------------------------
	reg [7:0] soundlatch_data;
	reg [7:0] soundlatch2_data;

	always @(posedge clk_sys) begin
		if (reset) soundlatch_data <= 8'h00;
		else if (sel_soundlatch_w & cpu_write & ~LDSn) soundlatch_data <= oEdb[7:0];
	end

	// ------------------------------------------------------------------
	// TLCS-90 sound board: tlcs90.sv + nmk004_periph.sv (reused unmodified,
	// see header) + a NEW external bus decode matching
	// raphero_sound_mem_map + NMK112 + jt03 (YM2203) + jt6295 x2 (OKI).
	// ------------------------------------------------------------------
	wire [7:0]  snd_din, snd_dout;
	wire [15:0] snd_addr;
	wire [3:0]  snd_addr_bank;
	wire        snd_mem_rd, snd_mem_wr;
	wire [10:0] irq_mask, irq_req_periph;
	wire [3:0]  snd_bx, snd_by;

	// YM2203's own IRQ (active-low) OR'd into irq_req bit0 (INT0) — same
	// pattern nmk004_core.sv's own irq_req_to_cpu uses (see header).
	wire [10:0] irq_req_to_cpu = {irq_req_periph[10:1], irq_req_periph[0] | ~ym_chip_irq_n};

	tlcs90 snd_cpu (
		.clk(tlcs90_clk), .reset(reset),
		.din(snd_din), .dout(snd_dout), .addr(snd_addr), .addr_bank(snd_addr_bank),
		.mem_rd(snd_mem_rd), .mem_wr(snd_mem_wr),
		.nmi(1'b0), .irq_req(irq_req_to_cpu), .irq_mask(irq_mask),
		.ix_bank(snd_bx), .iy_bank(snd_by),
		.dbg_pc(dbg_snd_pc), .dbg_valid(dbg_snd_valid), .dbg_halt(),
		.dbg_a(), .dbg_f(), .dbg_hl(), .dbg_de(), .dbg_iy()
	);

	// Every region below is bank 0 (see nmk004_core.sv's own "Address
	// decode" comment for why — no known raphero program legitimately
	// banks beyond 64KB).
	wire snd_bank0 = (snd_addr_bank == 4'h0);

	wire sel_snd_rom    = snd_bank0 && (snd_addr < 16'h8000);
	wire sel_snd_bank   = snd_bank0 && (snd_addr >= 16'h8000) && (snd_addr < 16'hC000);
	wire sel_snd_ym     = snd_bank0 && (snd_addr == 16'hC000 || snd_addr == 16'hC001);
	wire sel_snd_oki0   = snd_bank0 && (snd_addr == 16'hC800);
	wire sel_snd_oki1   = snd_bank0 && (snd_addr == 16'hC808);
	wire sel_snd_nmk112 = snd_bank0 && (snd_addr >= 16'hC810) && (snd_addr <= 16'hC817);
	wire sel_snd_audiobank = snd_bank0 && (snd_addr == 16'hD000);
	wire sel_snd_soundlatch_r  = snd_bank0 && (snd_addr == 16'hD800);
	wire sel_snd_soundlatch2_w = snd_bank0 && (snd_addr == 16'hD800);
	// External RAM only backs E000-FEBF — FEC0+ is intercepted by the
	// TLCS-90's own internal RAM/peripheral SFRs (see header).
	wire sel_snd_ext_ram = snd_bank0 && (snd_addr >= 16'hE000) && (snd_addr <= 16'hFEBF);
	wire sel_snd_int_ram = snd_bank0 && (snd_addr >= 16'hFEC0) && (snd_addr <= 16'hFFBF);
	wire sel_snd_periph  = snd_bank0 && (snd_addr >= 16'hFFC0) && (snd_addr <= 16'hFFEF);

	// Audiocpu ROM: full 0x20000-byte flat image, fixed-mapped at
	// 0-0x7FFF, ALSO the source for the 8-entry x 0x4000-byte bank window
	// at 0x8000-0xBFFF — same flat-overlay banking scheme every prior
	// Tier 3 port's own audiocpu uses.
	reg [7:0] audiocpu_rom [0:131071];
	initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);

	reg [2:0] audiobank_reg;
	always @(posedge clk_sys) begin
		if (reset) audiobank_reg <= 3'd0;
		else if (sel_snd_audiobank & snd_mem_wr) audiobank_reg <= snd_dout[2:0]; // macross2_audiobank_w
	end

	wire [16:0] snd_bank_phys = {audiobank_reg, 14'd0} + {3'd0, snd_addr[13:0]};

	// External RAM (E000-FEBF, 0x1EC0 bytes) + TLCS-90 internal RAM
	// (FEC0-FFBF, 256 bytes) — kept as separate arrays matching the real
	// hardware's own separate external-bus-vs-internal-RAM distinction
	// (see header), though nothing in this simulation actually depends on
	// them being physically separate.
	reg [7:0] snd_ext_ram [0:7871]; // 0x1EC0 bytes
	reg [7:0] snd_int_ram [0:255];
	always @(posedge clk_sys) if (sel_snd_ext_ram & snd_mem_wr) snd_ext_ram[snd_addr - 16'hE000] <= snd_dout;
	always @(posedge clk_sys) if (sel_snd_int_ram & snd_mem_wr) snd_int_ram[snd_addr[7:0]] <= snd_dout;

	always @(posedge clk_sys) begin
		if (reset) soundlatch2_data <= 8'h00;
		else if (sel_snd_soundlatch2_w & snd_mem_wr) soundlatch2_data <= snd_dout;
	end

	// ------------------------------------------------------------------
	// TLCS-90 on-chip peripherals — rtl/tlcs90/nmk004_periph.sv, reused
	// UNMODIFIED (see header; every override-enable tied inert).
	// ------------------------------------------------------------------
	wire [7:0] periph_rdata;
	wire       periph_p6_we, periph_p3_we, periph_p7_we;
	wire [7:0] periph_p6_wdata, periph_p3_wdata, periph_p7_wdata;
	wire [7:0] periph_p4;

	nmk004_periph periph (
		.clk(tlcs90_clk), .reset(reset),
		.reg_addr(snd_addr[5:0]),
		.wdata(snd_dout),
		.we(sel_snd_periph & snd_mem_wr),
		.re(sel_snd_periph & snd_mem_rd),
		.rdata(periph_rdata),
		.irq_mask(irq_mask), .irq_req(irq_req_periph),
		.p4_latch(periph_p4), .bx(snd_bx), .by(snd_by),
		.p5_ext_en(1'b0), .p5_ext_val(8'h00),
		.p6_ext_en(1'b0), .p6_ext_val(8'h00),
		.p6_we(periph_p6_we), .p6_wdata(periph_p6_wdata),
		.p7_ext_en(1'b0), .p7_ext_val(8'h00),
		.p3_we(periph_p3_we), .p3_wdata(periph_p3_wdata),
		.p7_we(periph_p7_we), .p7_wdata(periph_p7_wdata)
	);

	// ------------------------------------------------------------------
	// YM2203 — real jt03. Same write-stretch pattern as every other
	// 40MHz-based port's own (40-cycle hold, safely exceeding ym_cen's
	// own 27-cycle worst-case gap).
	// ------------------------------------------------------------------
	reg [7:0] ym_din_latch;
	reg       ym_addr_latch;
	reg [5:0] ym_wr_hold = 6'd0;
	reg       ym_we_prev = 1'b0;
	wire      ym_we_raw = sel_snd_ym & snd_mem_wr;
	always @(posedge clk_sys) begin
		ym_we_prev <= ym_we_raw;
		if (ym_we_raw && !ym_we_prev) begin
			ym_din_latch  <= snd_dout;
			ym_addr_latch <= snd_addr[0]; // C000=addr/status (offset0), C001=data (offset1)
			ym_wr_hold    <= 6'd40;
		end else if (ym_wr_hold != 6'd0) begin
			ym_wr_hold <= ym_wr_hold - 6'd1;
		end
	end
	wire ym_wr_n = ~(ym_wr_hold != 6'd0);

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_latch), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(), .snd(), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// NMK112 — see rtl/nmk112/nmk112.sv's own header. reg_sel matches
	// okibank_w's own offset decode: C810-C817's own low 3 bits.
	// ------------------------------------------------------------------
	wire nmk112_we = sel_snd_nmk112 & snd_mem_wr;
	wire [17:0] oki0_rom_addr_raw, oki1_rom_addr_raw;
	wire [21:0] oki0_rom_addr, oki1_rom_addr;

	nmk112 #(
		.ROM0_BYTES(4194304), // rhp94099.6+7, 0x400000 (oki1)
		.ROM1_BYTES(4194304)  // rhp94099.5+6, 0x400000 (oki2)
	) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(snd_addr[2:0]), .reg_data(snd_dout), .reg_we(nmk112_we),
		.rom0_addr_in(oki0_rom_addr_raw), .rom0_addr_out(oki0_rom_addr),
		.rom1_addr_in(oki1_rom_addr_raw), .rom1_addr_out(oki1_rom_addr)
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, driven by the TLCS-90's own bus through
	// NMK112. Same latch-and-hold write-stretch pattern as every other
	// port's own OKI integration.
	// ------------------------------------------------------------------
	reg [7:0] oki0_rom [0:4194303]; // rhp94099.6+7, 0x400000
	reg [7:0] oki1_rom [0:4194303]; // rhp94099.5+6, 0x400000
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki0_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki1_rom);

	reg [7:0] oki0_rom_data, oki1_rom_data;
	always @(posedge clk_sys) oki0_rom_data <= oki0_rom[oki0_rom_addr[21:0]];
	always @(posedge clk_sys) oki1_rom_data <= oki1_rom[oki1_rom_addr[21:0]];

	wire sel_oki0_we = sel_snd_oki0 & snd_mem_wr;
	wire sel_oki1_we = sel_snd_oki1 & snd_mem_wr;
	reg [7:0] oki0_din_latch, oki1_din_latch;
	reg [5:0] oki0_wr_hold = 6'd0, oki1_wr_hold = 6'd0;
	reg       oki0_we_prev = 1'b0, oki1_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		oki0_we_prev <= sel_oki0_we;
		if (sel_oki0_we && !oki0_we_prev) begin
			oki0_din_latch <= snd_dout;
			oki0_wr_hold   <= 6'd40;
		end else if (oki0_wr_hold != 6'd0) begin
			oki0_wr_hold <= oki0_wr_hold - 6'd1;
		end
	end
	always @(posedge clk_sys) begin
		oki1_we_prev <= sel_oki1_we;
		if (sel_oki1_we && !oki1_we_prev) begin
			oki1_din_latch <= snd_dout;
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
	// TLCS-90 read-data mux
	// ------------------------------------------------------------------
	reg [7:0] snd_rdata;
	always @(*) begin
		if (sel_snd_rom)        snd_rdata = audiocpu_rom[snd_addr[14:0]];
		else if (sel_snd_bank)  snd_rdata = audiocpu_rom[snd_bank_phys[16:0]];
		else if (sel_snd_ext_ram) snd_rdata = snd_ext_ram[snd_addr - 16'hE000];
		else if (sel_snd_int_ram) snd_rdata = snd_int_ram[snd_addr[7:0]];
		else if (sel_snd_periph)  snd_rdata = periph_rdata;
		else if (sel_snd_soundlatch_r) snd_rdata = soundlatch_data;
		else if (sel_snd_ym)    snd_rdata = ym_chip_dout;
		else if (sel_snd_oki0)  snd_rdata = oki0_chip_dout;
		else if (sel_snd_oki1)  snd_rdata = oki1_chip_dout;
		else                     snd_rdata = 8'h00;
	end
	assign snd_din = snd_rdata;

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
		else if (sel_scrollram)  rdata = scrollram_dout;
		else if (sel_scrollramy) rdata = scrollramy_dout;
		else if (sel_pad0400)    rdata = pad0400_dout;
		else if (sel_soundlatch2_r) rdata = {8'h00, soundlatch2_data};
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + REAL V-PROM interrupt generation (rtl/nmk_irq/
	// nmk_irq.sv).
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
		.reset(reset),
		.line_start(vt_line_start),
		.vcount(vt_vcount),
		.iack_cycle(iack_cycle),
		.iack_level(eab[3:1]),
		.ipl_level(ipl_level),
		.sprite_dma_trigger(sprite_dma_trigger)
	);

	// ------------------------------------------------------------------
	// Video pipeline — rtl/raphero/video_raphero.sv (see that file's own
	// header for the full hybrid derivation).
	// ------------------------------------------------------------------
	video_raphero #(
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
		.scrollram_0(vid_scrollram_0), .scrollramy_0(vid_scrollramy_0),
		.scrollram_row_addr(vid_scrollram_row_addr), .scrollram_row(vid_scrollram_row),
		.scrollramy_row_addr(vid_scrollramy_row_addr), .scrollramy_row(vid_scrollramy_row),
		.tilerambank(tilerambank_reg),
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

	assign dbg_snd_cen = tlcs90_clk;

	assign dbg_ym_we = ym_we_raw;
	assign dbg_ym_cs = sel_snd_ym;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_irq_n = ym_chip_irq_n;

	assign dbg_oki0_we = sel_oki0_we;
	assign dbg_oki1_we = sel_oki1_we;
	assign dbg_oki0_chip_dout = oki0_chip_dout;
	assign dbg_oki1_chip_dout = oki1_chip_dout;

endmodule
