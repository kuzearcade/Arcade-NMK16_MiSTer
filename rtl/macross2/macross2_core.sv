// NMK16 MiSTerFPGA project — macross2 (Tier 3, Family C: Z80-direct-sound
// hi-res boards) system-level integration. First Tier 3 port.
//
// Reused, unmodified: rtl/third_party_gen/t80/T80s.v (GHDL-translated Z80
// core, five times proven cycle-exact against a real MAME oracle — see
// docs/t80-vhdl-toolchain.md), rtl/bjtwin/video_timing.sv (this project's
// single shared 8MHz/512-wide raster model, unchanged regardless of
// lowres/hires screen config — see gunnail_core.sv's own header), and —
// genuinely new to this session — rtl/nmk_irq/nmk_irq.sv, the REAL
// V-PROM-driven interrupt generator (macross2() calls set_interrupt_timing,
// nmk16.cpp:5449, NOT the "hacky" fixed-scanline substitute every Tier 5
// port used) and rtl/nmk112/nmk112.sv, a new reusable OKI-bank-switcher
// device (see that module's own header for the full derivation).
//
// Video: rtl/macross2/video_macross2.sv (new — see its own header: derived
// from rtl/macross/video_macross.sv's own BG tilemap architecture (14-bit
// tile code, no per-scanline scroll) plus rtl/gunnail/video_gunnail.sv's
// own wider 64x32 TX tilemap sizing, with no NMK214 descrambling (no
// protection MCU on this board) and a widened 5-bit sprite colour field).
//
// Sound: Z80 + direct YM2203 (jt03) + dual OKIM6295 (jt6295 x2) through
// NMK112 + dual soundlatch — nearly identical to gunnailb_core.sv's own
// newly-built sound path (same macross2_audiobank_w banking scheme —
// literally the same function name, since gunnailb's bootleg reused it),
// but genuinely different in three ways, confirmed directly against the
// reference rather than assumed:
//   1. Both OKIs stay on the Z80's own I/O bus (through NMK112), unlike
//      gunnailb's own bootleg-specific "OKI moved to the 68000" wiring.
//   2. The Z80 has a real RESET line driven by the 68000
//      (macross2_sound_reset_w, nmk16.cpp:295-300/1090 — "every time music
//      changes Z80 is reset" per a PCB-behavior-verified comment; implemented
//      as a real reset input into T80s, not folded into the global reset).
//   3. soundlatch (68000->Z80, nmk16.cpp:10001F/0xF000) has NO
//      data_pending_callback wired anywhere in macross2()'s own machine
//      config (nmk16.cpp:5444-5488, confirmed by reading it directly — no
//      `.set_inputline(m_audiocpu, INPUT_LINE_NMI)` call exists here, unlike
//      gunnailb's own explicit wiring) — so unlike gunnailb, writing
//      soundlatch here does NOT interrupt the Z80 at all; the Z80's own
//      only interrupt source is YM2203's own IRQ (`ymsnd.irq_handler().
//      set_inputline(m_audiocpu,0)`, nmk16.cpp:5471, plain maskable IRQ0).
//      soundlatch is therefore a pure polling register here.
//
// Memory map (macross2_map, nmk16.cpp:1081-1098):
//   000000-07FFFF  ROM (maincpu, 0x80000, single ROM_LOAD16_WORD_SWAP file
//                  — see tools/mkrom_wordswap.py, NOT the usual two-chip
//                  ROM_LOAD16_BYTE pair)
//   100000-100001  IN0 (R)
//   100002-100003  IN1 (R)
//   100008-100009  DSW1 (R)
//   10000A-10000B  DSW2 (R)
//   10000F         soundlatch2 read (R, byte — Z80-written, 68000-read)
//   100015         flipscreen_w (W, byte)
//   100016-100017  macross2_sound_reset_w (W, word — Z80 reset line, see
//                  above)
//   100019         tilebank_w (W, byte)
//   10001F         soundlatch write (W, byte — 68000-written, Z80-read;
//                  NO interrupt side effect here, see above)
//   120000-1207FF  palette RAM, 1024 x 16 (real — video_macross2)
//   130000-130007  scroll_w<0> (BG X/Y scroll, 4 byte sub-registers
//                  [Xhi,Xlo,Yhi,Ylo], sub-index = byte_addr[2:1],
//                  LDS-gated low-byte writes only — same pattern every
//                  Tier 5 port's own single-scroll-register wiring used)
//   140000-14FFFF  BG tilemap VRAM, 32768 x 16 (real — video_macross2 —
//                  FOUR TIMES every Tier 5 port's own bgvideoram size)
//   170000-170FFF  tx tilemap VRAM, mirrored +0x1000 (real — video_macross2,
//                  2048 x 16, same size/mirror convention as gunnail's own)
//   1F0000-1FFFFF  main work RAM, 32768 x 16, plain masked write
//
// Z80 memory map (macross2_sound_map, nmk16.cpp:1147-1155):
//   0000-7FFF  ROM (fixed, first 0x8000 bytes of the 0x20000-byte
//              audiocpu ROM — a flat single-file load, no ROM_CONTINUE/
//              ROM_COPY, same shape as gunnailb's own)
//   8000-BFFF  banked ROM window, 8 x 0x4000-byte banks (same flat-overlay
//              banking scheme as gunnailb's own — bank N sources region
//              bytes N*0x4000..N*0x4000+0x3FFF from the same ROM array)
//   A000       nopr — "IRQ ack? watchdog?" per the reference's own comment,
//              genuinely unclear; treated as a no-op read, no behavior
//              invented for it
//   C000-DFFF  RAM, 0x2000 bytes
//   E001       audiobank select, write (macross2_audiobank_w —
//              audiobank<=data&0x7 — literally the same function
//              gunnailb's own bootleg reused)
//   F000       soundlatch read (from 68000, no IRQ side effect here) /
//              soundlatch2 write (to 68000)
//
// Z80 I/O map (macross2_sound_io_map, nmk16.cpp:1157-1164):
//   00-01  YM2203 (jt03) r/w — standard 2-register convention
//   80     OKIM6295 chip 0 (oki1) r/w — through NMK112
//   88     OKIM6295 chip 1 (oki2) r/w — through NMK112
//   90-97  NMK112 bank-select write (8 registers — see rtl/nmk112/
//          nmk112.sv's own header)
//
// Clock: 68000 at XTAL(10'000'000) = 10MHz (nmk16.cpp:5447), same nominal
// rate as gunnail_core.sv's own — this file uses the identical 40MHz
// clk_sys convention (clk_sys/4=10MHz CPU, clk_sys/5=8MHz pixel/raster).
// Z80 at 4MHz (nmk16.cpp:5451, `Z80(config,m_audiocpu,4000000)`). From
// 40MHz: GCD(4000000,40000000)=4000000 -> increment=1, modulus=10 — a
// clean divide (40MHz/10=4MHz exactly), plain free-running counter, no
// phase accumulator needed. YM2203 at XTAL(12'000'000)/8=1.5MHz
// (nmk16.cpp:5470) — the SAME accumulator gunnail_core.sv's/gunnailb_
// core.sv's own ym_cen already uses (increment=3,modulus=80 off 40MHz).
// OKIM6295 x2 at XTAL(16'000'000)/4=4MHz (nmk16.cpp:5481,5485) — the SAME
// rate/accumulator gunnail_core.sv's own two OKIs already use
// (oki_cen_cnt==39, i.e. clk_sys/40 off 40MHz — verified: 40MHz/40=1MHz...
// wait, gunnail_core.sv's own OKI cen is actually clk_sys/40 giving 1MHz,
// but its own reference OKIs also run at 16MHz/4=4MHz — see that file's
// own oki_cen derivation, reused verbatim here since the clock/ratio is
// identical, not re-derived).
//
// Known simplifications: same general list as every prior port (no audio
// DAC/mixer beyond the bus/register-level integration itself, IN0/IN1/
// DSW1/DSW2 tied to fixed idle values, DTACKn tied to ASn, T80's WAIT_n
// tied high). HALTn tied high (no protection MCU exists on this board).
module macross2_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI1_ROM_FILE  = "",
	parameter OKI2_ROM_FILE  = "",
	parameter VTIMING_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = ""
) (
	input clk_sys,        // 40 MHz (68000 bus clk_sys/4=10MHz; pixel/raster clk_sys/5=8MHz)
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
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [14:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables — 68000/pixel identical to gunnail_core.sv's own
	// 40MHz convention (see header).
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// Z80: 4MHz from 40MHz clk_sys — a clean divide (clk_sys/10), plain
	// free-running counter (see header).
	reg [3:0] z80_div = 4'd0;
	always @(posedge clk_sys) z80_div <= (z80_div == 4'd9) ? 4'd0 : z80_div + 4'd1;
	wire z80_cen = (z80_div == 4'd9);

	// YM2203: identical accumulator to gunnail_core.sv's/gunnailb_core.sv's
	// own ym_cen (increment=3, modulus=80 -> 1.5MHz off 40MHz clk_sys).
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

	// OKIM6295 x2: identical cen to gunnail_core.sv's own (clk_sys/40 ->
	// 1MHz internal chip cen — jt6295's own SS pin/internal divider takes
	// it the rest of the way to the real 4MHz sample-fetch rate, same as
	// gunnail_core.sv's own already-verified integration; not re-derived).
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
	wire sel_sndreset  = (byte_addr[23:1] == 23'h08000B); // 100016/100017 word
	wire sel_tilebank  = (byte_addr[23:1] == 23'h08000C); // 100018/100019, LDS=low byte
	wire sel_soundlatch_w = (byte_addr[23:1] == 23'h08000F); // 10001E/10001F word, byte reg at odd
	wire sel_palette   = (byte_addr >= 24'h120000) && (byte_addr <= 24'h1207FF);
	wire sel_scroll    = (byte_addr >= 24'h130000) && (byte_addr <= 24'h130007);
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
	// BG tilemap VRAM (32768 x 16 — 0x10000 bytes, four times every Tier
	// 5 port's own bgvideoram size, see header).
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
	// Dual-port video read taps (video_macross2.sv's own live reads)
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

	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bgvram_data = bgvram[dbg_bgvram_addr[14:0]];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg        z80_reset_n_reg;

	// scroll_w<0>: 4 byte sub-registers [Xhi,Xlo,Yhi,Yhi], sub-index =
	// byte_addr[2:1], LDS-gated low-byte writes only — same pattern every
	// Tier 5 port's own single-scroll-register wiring used.
	reg [7:0] scroll_reg [0:3];
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire [15:0] bg_xscroll = {scroll_reg[0], scroll_reg[1]};
	wire [15:0] bg_yscroll = {scroll_reg[2], scroll_reg[3]};

	// tilerambank (nmk16.cpp:490-495): derived from bits[5:4] of the SAME
	// byte written to scroll_reg[0] (X-scroll high byte, offset 0 of
	// scroll_w<0>) — see video_macross2.sv's own port comment for the
	// full derivation. Only updates on an offset-0 write, matching the
	// reference's own `if (... && offset==0)` gate exactly.
	reg [1:0] tilerambank_reg;
	wire sel_scroll_off0 = sel_scroll & (scroll_word_idx == 2'd0);

	integer si;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			z80_reset_n_reg <= 1'b0; // held in reset until the 68000 releases it
			tilerambank_reg <= 2'd0;
			for (si = 0; si < 4; si = si + 1) scroll_reg[si] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank & ~LDSn) bgbank_reg      <= oEdb[7:0];
			if (sel_scroll & ~LDSn) begin
				scroll_reg[scroll_word_idx] <= oEdb[7:0];
				if (sel_scroll_off0) tilerambank_reg <= oEdb[5:4];
			end
			// macross2_sound_reset_w (nmk16.cpp:295-300): m_audiocpu->
			// set_input_line(INPUT_LINE_RESET, data ? CLEAR_LINE : ASSERT_LINE)
			// — data!=0 releases reset, data==0 asserts it. Word write, use
			// the low byte's own LSB (matches every other single-bit
			// register's own convention in this project).
			if (sel_sndreset)         z80_reset_n_reg <= (oEdb != 16'h0000);
		end
	end

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// soundlatch (68000->Z80, main2sub) / soundlatch2 (Z80->68000,
	// sub2main) — plain polling registers, NO interrupt side effect on
	// either direction here (see header — genuinely different from
	// gunnailb's own NMI-driven soundlatch).
	// ------------------------------------------------------------------
	reg [7:0] soundlatch_data;
	reg [7:0] soundlatch2_data;

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
	wire z80_reset_n = ~reset & z80_reset_n_reg;

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

	wire sel_z80_rom   = (z80_a < 16'h8000);
	// A000 is a nopr() carve-out INSIDE the 8000-BFFF banked-ROM range
	// (nmk16.cpp:1151, "IRQ ack? watchdog?" — genuinely unclear, treated
	// as open-bus like every other unmapped read in this project) —
	// excluded from sel_z80_bank explicitly so it doesn't silently read
	// banked ROM data instead.
	wire sel_z80_nopr  = (z80_a == 16'hA000);
	wire sel_z80_bank  = (z80_a >= 16'h8000) && (z80_a < 16'hC000) && !sel_z80_nopr;
	wire sel_z80_ram   = (z80_a >= 16'hC000) && (z80_a < 16'hE000);
	wire sel_z80_soundlatch2_w = z80_mem_we & (z80_a == 16'hF000);
	wire sel_z80_soundlatch_r  = (z80_a == 16'hF000);

	// E001 (audiobank_w) is memory-mapped (Z80 address space, not I/O —
	// nmk16.cpp:1150-1153), unlike gunnailb's own I/O-mapped port 0x00.
	wire sel_mem_audiobank_w = z80_mem_we & (z80_a == 16'hE001);

	wire sel_io_ym_addr = (z80_a[7:0] == 8'h00);
	wire sel_io_ym_data = (z80_a[7:0] == 8'h01);
	wire sel_io_ym      = sel_io_ym_addr | sel_io_ym_data;
	wire sel_io_oki0    = (z80_a[7:0] == 8'h80);
	wire sel_io_oki1    = (z80_a[7:0] == 8'h88);
	wire sel_io_nmk112  = (z80_a[7:0] >= 8'h90) && (z80_a[7:0] <= 8'h97);

	// Audiocpu ROM: full 0x20000-byte flat image, fixed-mapped at
	// 0-0x7FFF, ALSO the source for the 8-entry x 0x4000-byte bank window
	// at 0x8000-0xBFFF — same flat-overlay banking scheme as gunnailb's
	// own (see header).
	reg [7:0] audiocpu_rom [0:131071];
	initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);

	reg [2:0] audiobank_reg;
	always @(posedge clk_sys) begin
		if (~z80_reset_n) audiobank_reg <= 3'd0;
		else if (sel_mem_audiobank_w) audiobank_reg <= z80_do[2:0]; // macross2_audiobank_w: audiobank<=data&0x7
	end

	reg [7:0] z80_ram [0:8191];
	always @(posedge clk_sys) if (sel_z80_ram & z80_mem_we) z80_ram[z80_a[12:0]] <= z80_do;

	wire [16:0] z80_bank_phys = {audiobank_reg, 14'd0} + {3'd0, z80_a[13:0]};

	always @(posedge clk_sys) begin
		if (~z80_reset_n) soundlatch2_data <= 8'h00;
		else if (sel_z80_soundlatch2_w) soundlatch2_data <= z80_do;
	end

	// ------------------------------------------------------------------
	// YM2203 — real jt03. Same write-stretch pattern as gunnail_core.sv's/
	// gunnailb_core.sv's own (40-cycle hold — see gunnailb_core.sv's own
	// review-verified derivation, safely exceeding ym_cen's own 27-cycle
	// worst-case gap).
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
	// jt03 has no separate read-strobe input — dout always reflects whatever
	// addr currently holds, so a status/busy read must see the live port
	// decode, not the write-only latch (which would still show the previous
	// write's offset, e.g. after a data-port write, breaking busy-flag polls).
	// Fall back to the latched value only while a write-stretch is in flight,
	// since ym_din_latch itself is only valid for that same window.
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
	// NMK112 — see rtl/nmk112/nmk112.sv's own header. reg_sel[2]=chip,
	// reg_sel[1:0]=banknum, matching okibank_w's own offset decode
	// (z80_a[2:0] directly, since 0x90-0x97's own low 3 bits ARE that
	// offset).
	// ------------------------------------------------------------------
	wire nmk112_we = z80_io_we & sel_io_nmk112;
	wire [17:0] oki0_rom_addr_raw, oki1_rom_addr_raw;
	wire [21:0] oki0_rom_addr, oki1_rom_addr;

	nmk112 #(
		.ROM0_BYTES(2097152), // bp932an.a06, 0x200000
		.ROM1_BYTES(1048576)  // bp932an.a05, 0x100000
	) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(z80_a[2:0]), .reg_data(z80_do), .reg_we(nmk112_we),
		.rom0_addr_in(oki0_rom_addr_raw), .rom0_addr_out(oki0_rom_addr),
		.rom1_addr_in(oki1_rom_addr_raw), .rom1_addr_out(oki1_rom_addr)
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, driven by the Z80's own I/O bus through
	// NMK112 (see header — genuinely different from gunnailb's own
	// direct-68000 wiring). Same latch-and-hold write-stretch pattern as
	// every other Z80-domain OKI integration in this project.
	// ------------------------------------------------------------------
	reg [7:0] oki0_rom [0:2097151]; // bp932an.a06, 0x200000
	reg [7:0] oki1_rom [0:1048575]; // bp932an.a05, 0x100000
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki0_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki1_rom);

	reg [7:0] oki0_rom_data, oki1_rom_data;
	always @(posedge clk_sys) oki0_rom_data <= oki0_rom[oki0_rom_addr[20:0]];
	always @(posedge clk_sys) oki1_rom_data <= oki1_rom[oki1_rom_addr[19:0]];

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
		else if (sel_z80_bank)  z80_rdata = audiocpu_rom[z80_bank_phys[16:0]];
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
	// nmk_irq.sv — see this file's own header; NOT the hacky fixed-
	// scanline substitute every Tier 5 port used).
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
	// Video pipeline — rtl/macross2/video_macross2.sv (see header + that
	// file's own header for the full derivation).
	// ------------------------------------------------------------------
	video_macross2 #(
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
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout), .mainram_ready(1'b1),
		.bg_xscroll(bg_xscroll), .bg_yscroll(bg_yscroll),
		.bg_bank(bgbank_reg),
		.tilerambank(tilerambank_reg),
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
