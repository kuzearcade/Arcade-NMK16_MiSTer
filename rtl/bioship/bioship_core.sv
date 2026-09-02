// NMK16 MiSTerFPGA project — bioship hardware family (Tier 2, NMK004
// boards) system-level integration.
//
// The second Tier 2 NMK004-board game after mustang (rtl/mustang/
// mustang_core.sv — that module's own header covers the shared 68000/
// NMK004/jt03/jt6295/nmk_irq integration architecture this reuses
// wholesale; this header only covers what's genuinely different for
// bioship). Every constituent module (fx68k, nmk004_core, jt03, jt6295,
// nmk_irq) is already generic/game-parameterized from mustang's own
// integration work — this file is "new per-game glue", not new
// per-module RTL, except for rtl/bioship/video_bioship.sv (see that
// module's own header for the real video-pipeline differences: three
// tilemap layers instead of two, one of them ROM- rather than
// VRAM-based).
//
// Real, substantive differences from mustang_core.sv:
//   - The 68000 runs at 10MHz here, not 8MHz (nmk16.cpp bioship():
//     M68000(config, m_maincpu, XTAL(10'000'000)), vs mustang's own
//     XTAL(8'000'000)) — NMK004/OKI/YM2203 stay at the same nominal
//     rates as mustang (8MHz/4MHz/1.5MHz). Since 8 and 10 don't share a
//     clean power-of-2 common divisor, clk_sys is 40MHz here (not
//     mustang's 32MHz) — LCM-friendly: /4=10MHz (68000, same clean
//     divide-by-4 enPhi1/enPhi2 pattern mustang/bjtwin already use),
//     /5=8MHz (NMK004 clock + pixel/raster clock enable, a genuine
//     5-cycle counter rather than mustang's 2-bit-MSB /4 trick — see
//     "Clock enables" below), /10=4MHz (OKI cen), and a 3/80
//     phase-accumulator for YM2203's own 1.5MHz (same accumulator
//     *technique* as mustang's own 3/64-from-32MHz, different constants
//     since the base rate changed).
//   - `nmk004_bioship_x0016_w` INVERTS the watchdog-NMI polarity nmk16.cpp
//     uses everywhere else (`BIT(data,0) ? CLEAR_LINE : ASSERT_LINE`,
//     vs the standard `nmk004_x0016_w`'s `BIT(data,0) ? ASSERT_LINE :
//     CLEAR_LINE` mustang uses) — nmk16.cpp's own comment: "otherwise
//     bioship doesn't hit the NMI enough to keep the game alive". Wired
//     here as `nmi_level <= ~oEdb[0]` (mustang's own is `oEdb[0]`
//     directly). This session's own frame-CRC timing-drift chase
//     (docs/tier2-system.md) already established that this watchdog
//     NMI's exact *delivery timing* isn't something meaningfully
//     chaseable against MAME's own oracle (an unsynchronized scheduler-
//     quantum-dependent line on MAME's own side) — only the *polarity*
//     needs to be correct here, which this is.
//   - Video: three tilemap layers (see video_bioship.sv), not two —
//     BG0 is ROM-tile-index-based with an 8-bit bank-select register
//     (`bioship_bank_w`, byte @0x084001) and independent X/Y scroll;
//     BG1 is the familiar VRAM tilemap, ALSO with independent X/Y scroll
//     (mustang's own single BG layer only ever gets X-scroll — bioship's
//     `scroll_w<Layer>` template is the more general one, see
//     video_bioship.sv's header). Both scroll register blocks are the
//     generic byte-sequenced `scroll_w<Layer>` form (four bytes/layer:
//     X-hi, X-lo, Y-hi, Y-lo, each written via a `.umask16(0xff00)`
//     byte-lane at a word address — gated on ~UDSn here, NOT ~LDSn like
//     mustang's own odd-byte registers, since the upper byte lane is
//     the one carrying data for this template), not mustang's own
//     single mode-selector-byte `mustang_scroll_w` word register.
//   - DSW2 is mapped (bioship_map reads it, mustang_map doesn't) — tied
//     to the same fixed idle value as IN0/IN1/DSW1 (see header's "Known
//     simplifications", carried from mustang unchanged).
//
// Memory map (see bioship_map in mame/src/mame/nmk/nmk16.cpp):
//   000000-03FFFF  ROM (maincpu, 2 x 0x20000-byte chips, ROM_LOAD16_BYTE)
//   080000-080001  IN0 (R)
//   080002-080003  IN1 (R)
//   080008-080009  DSW1 (R)
//   08000A-08000B  DSW2 (R)
//   08000F         NMK004 host-read latch (R, byte)
//   080015         flipscreen_w (W, byte)
//   080016-080017  nmk004_bioship_x0016_w (W, word) — INVERTED NMI polarity, see above
//   08001F         NMK004 host-write latch (W, byte)
//   084001         bioship_bank_w (W, byte) — BG0's ROM-tilemap scene bank
//   088000-0887FF  palette RAM, 1024 x 16
//   08C000-08C007  scroll_w<1> (BG1 X/Y scroll, byte-sequenced, ~UDSn)
//   08C010-08C017  scroll_w<0> (BG0 X/Y scroll, byte-sequenced, ~UDSn)
//   090000-093FFF  BG1 tilemap VRAM, 8192 x 16 ("bgvideoram1")
//   09C000-09C7FF  tx tilemap VRAM, 1024 x 16
//   0F0000-0FFFFF  main work RAM, 32768 x 16 — mainram_strange_w, same
//                  unconditional full-word write as mustang (bioship_map
//                  uses the exact same handler)
//
// Known simplifications: identical to mustang_core.sv's own list (DTACKn
// tied to ASn, jt03/jt6295 write-stretch, jt6295 rom_ok tied high,
// NMK004 fed a genuine divided clock rather than a clock-enable, IN0/
// IN1/DSW1/DSW2 tied to fixed idle values) — see that module's header
// for the full rationale, not repeated here since none of it changed.
module bioship_core #(
	parameter ROM_FILE      = "",
	parameter NMK004_BOOT_FILE = "",
	parameter NMK004_EXT_FILE  = "",
	parameter OKI1_ROM_FILE = "",
	parameter OKI2_ROM_FILE = "",
	parameter VTIMING_FILE  = "",
	parameter FGTILE_FILE   = "",
	parameter BGTILE_FILE   = "",
	parameter BG2TILE_FILE  = "",
	parameter SPRITES_FILE  = "",
	parameter TILEROM_FILE  = ""
) (
	input clk_sys,       // 40 MHz (68000 bus clk_sys/4=10MHz; NMK004/pixel/raster clk_sys/5=8MHz)
	input reset,          // async, active high

	// debug/trace outputs for the Verilator testbench
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output [15:0] dbg_nmk004_pc,
	output        dbg_nmk004_valid,

	output        dbg_ym_we,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_chip_irq_n,

	output        dbg_oki0_we,
	output        dbg_oki0_cs,
	output  [7:0] dbg_oki0_chip_dout,
	output        dbg_oki1_we,
	output        dbg_oki1_cs,
	output  [7:0] dbg_oki1_chip_dout,

	output [7:0]  dbg_nmk004_a,
	output [7:0]  dbg_nmk004_f,
	output [15:0] dbg_nmk004_hl,
	output [7:0]  dbg_nmk004_ram_hl,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [12:0] dbg_bg1vram_addr,
	output [15:0] dbg_bg1vram_data,
	input  [9:0]  dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	// 68000: exact fx68kTop /4 pattern (see mustang_core.sv), now 10MHz
	// from 40MHz clk_sys instead of mustang's 8MHz-from-32MHz — same
	// clean divide-by-4, just a different base clk_sys rate.
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	// NMK004: a genuine divided clock, 8MHz from 40MHz clk_sys — /5, not
	// mustang's /4, so no clean 50%-duty MSB trick is available (5 is
	// odd). A 2-high/3-low mod-5 counter still gives exactly one rising
	// edge every 5 clk_sys cycles (=8MHz) with both phases comfortably
	// wider than one clk_sys cycle — tlcs90.sv only cares about rising
	// edges (see mustang_core.sv's own "Known simplifications" note on
	// why this is a divided clock, not a clock-enable), and duty-cycle
	// symmetry doesn't matter for a synchronous-design derived clock
	// like this one.
	reg [2:0] nmk004_div = 3'd0;
	always @(posedge clk_sys)
		nmk004_div <= reset ? 3'd0 : (nmk004_div == 3'd4 ? 3'd0 : nmk004_div + 3'd1);
	wire nmk004_clk_r = (nmk004_div < 3'd2);

	// Pixel/raster-timing clock enable for video_timing/nmk_irq: 8MHz
	// from 40MHz clk_sys (/5, same rate as NMK004 above, independent
	// counter since this one must stay a single-clk_sys-cycle strobe,
	// not a divided clock — matches mustang_core.sv's own ce_pix role).
	// Reset-gated for the same reason mustang_core.sv's own ce_pix is
	// (lockstep with video_timing's hcount, held at 0 through reset).
	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

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

	// Autovector plumbing matches mustang_core.sv/bjtwin_core.sv exactly.
	wire iack_cycle = FC0 & FC1 & FC2 & ~ASn;
	wire VPAn = ~iack_cycle;
	wire DTACKn = ASn | iack_cycle;

	// NMK004's own P4 bit0 drives the 68000's reset line — same real
	// hold-then-release handshake as mustang_core.sv (configure_nmk004()
	// wires reset_cb identically for bioship).
	wire [7:0] nmk004_p4;
	wire m68k_extReset = reset | nmk004_p4[0];

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(1'b1),
		.extReset(m68k_extReset),
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
	wire sel_rom       = (byte_addr <= 24'h03FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1       = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040004); // 080008/080009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h040005); // 08000A/08000B
	wire sel_nmk004_r  = (byte_addr[23:1] == 23'h040007); // 08000E/08000F word
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015, LDS=low byte
	wire sel_nmi       = (byte_addr[23:1] == 23'h04000B); // 080016/080017
	wire sel_nmk004_w  = (byte_addr[23:1] == 23'h04000F); // 08001E/08001F word
	wire sel_bg0_bank  = (byte_addr[23:1] == 23'h042000); // 084000/084001, LDS=low byte
	wire sel_palette   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h0887FF);
	wire sel_scroll1   = (byte_addr >= 24'h08C000) && (byte_addr <= 24'h08C007); // BG1 (VRAM layer)
	wire sel_scroll0   = (byte_addr >= 24'h08C010) && (byte_addr <= 24'h08C017); // BG0 (ROM-tilemap layer)
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire sel_bg1vram   = (byte_addr >= 24'h090000) && (byte_addr <= 24'h093FFF);
	wire sel_txvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09C7FF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu)
	// ------------------------------------------------------------------
	reg [15:0] rom [0:131071]; // 0x20000 words = 0x40000 bytes
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[17:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — mainram_strange_w: unconditional
	// full-word write, byte lanes ignored (see header).
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr = byte_addr[15:1];
	reg [15:0] mainram_dout;
	always @(posedge clk_sys) begin
		if (sel_mainram & cpu_write) mainram[mainram_addr] <= oEdb;
	end
	always @(*) mainram_dout = mainram[mainram_addr];

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16) — plain masked writes (palette_device::write16)
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
	// BG1 tilemap VRAM (8192 x 16) — plain masked writes (COMBINE_DATA)
	// ------------------------------------------------------------------
	reg [15:0] bg1vram [0:8191];
	wire [12:0] bg1vram_addr = byte_addr[13:1];
	always @(posedge clk_sys) begin
		if (sel_bg1vram & cpu_write) begin
			if (~UDSn) bg1vram[bg1vram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) bg1vram[bg1vram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] bg1vram_dout = bg1vram[bg1vram_addr];

	// ------------------------------------------------------------------
	// TX tilemap VRAM (1024 x 16) — plain masked writes (COMBINE_DATA)
	// ------------------------------------------------------------------
	reg [15:0] txvram [0:1023];
	wire [9:0] txvram_addr = byte_addr[10:1];
	always @(posedge clk_sys) begin
		if (sel_txvram & cpu_write) begin
			if (~UDSn) txvram[txvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) txvram[txvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] txvram_dout = txvram[txvram_addr];

	// ------------------------------------------------------------------
	// Dual-port video read taps — video_bioship.sv's own live, per-pixel
	// reads into the same arrays above (bioship_core.sv owns the
	// storage, matching mustang_core.sv's own established split).
	// ------------------------------------------------------------------
	wire [12:0] vid_bg1vram_addr;
	wire [15:0] vid_bg1vram_dout = bg1vram[vid_bg1vram_addr];
	wire [9:0]  vid_txvram_addr;
	wire [15:0] vid_txvram_dout = txvram[vid_txvram_addr];
	wire [9:0]  vid_palette_addr;
	wire [15:0] vid_palette_dout = palette[vid_palette_addr];
	wire [9:0]  vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout = palette[vid_spr_palette_addr];
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout = mainram[vid_mainram_addr];

	// Palette/BG1/TX VRAM debug taps — same tier as mustang_core.sv's own.
	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bg1vram_data = bg1vram[dbg_bg1vram_addr];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers (write-captured only, see header)
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bg0_bank_reg;
	reg [7:0]  scroll_reg [0:1][0:3]; // [0]=BG0(ROM-tilemap) [1]=BG1(VRAM), each [Xhi,Xlo,Yhi,Ylo]
	reg        nmi_level;

	wire [15:0] bg0_xscroll = {scroll_reg[0][0], scroll_reg[0][1]};
	wire [15:0] bg0_yscroll = {scroll_reg[0][2], scroll_reg[0][3]};
	wire [15:0] bg1_xscroll = {scroll_reg[1][0], scroll_reg[1][1]};
	wire [15:0] bg1_yscroll = {scroll_reg[1][2], scroll_reg[1][3]};

	integer si, sj;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bg0_bank_reg    <= 8'h00;
			nmi_level       <= 1'b0;
			for (si = 0; si < 2; si = si + 1)
				for (sj = 0; sj < 4; sj = sj + 1)
					scroll_reg[si][sj] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_bg0_bank & ~LDSn) bg0_bank_reg    <= oEdb[7:0];
			if (sel_scroll1 & ~UDSn)  scroll_reg[1][scroll_word_idx] <= oEdb[15:8];
			if (sel_scroll0 & ~UDSn)  scroll_reg[0][scroll_word_idx] <= oEdb[15:8];
			// nmk004_bioship_x0016_w: inverted polarity — see header.
			if (sel_nmi)              nmi_level       <= ~oEdb[0];
		end
	end

	// Fixed idle input state (see header) — future work: wire to real
	// HPS_IO player input / dipswitch config.
	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// NMK004 sound board
	// ------------------------------------------------------------------
	wire [7:0] nmk004_mcu_to_host;
	wire       nmk004_mcu_to_host_we;
	reg  [7:0] nmk004_host_to_mcu = 8'hFF;
	always @(posedge clk_sys) if (cpu_write & sel_nmk004_w & ~LDSn) nmk004_host_to_mcu <= oEdb[7:0];

	wire       ym_cs, ym_we, ym_addr_sel;
	wire [7:0] ym_dout;
	wire       oki0_cs, oki0_we, oki1_cs, oki1_we;
	wire [7:0] oki0_dout, oki1_dout;
	wire       oki0_bank_we, oki1_bank_we;
	wire [7:0] oki0_bank, oki1_bank;

	// ------------------------------------------------------------------
	// YM2203 — real jt03. 1.5MHz from 40MHz clk_sys: 1.5/40 = 3/80
	// exactly (mustang_core.sv's own precedent used 3/64 from 32MHz —
	// same accumulator technique, different constants for the new base
	// rate), so a plain phase accumulator still gives an exact rate with
	// no fractional error.
	// ------------------------------------------------------------------
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

	// Write-stretch — same rationale as mustang_core.sv's own (jt03 has
	// no bus-ready/ack output; its cen pulses less often than nmk004's
	// own single-nmk004_clk_r-cycle-wide we pulse, so latch+hold).
	reg [7:0] ym_din_latch;
	reg       ym_addr_latch;
	reg [5:0] ym_wr_hold = 6'd0;
	reg       ym_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		ym_we_prev <= ym_we;
		if (ym_we && !ym_we_prev) begin
			ym_din_latch  <= ym_dout;
			ym_addr_latch <= ym_addr_sel;
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
	// OKIM6295 x2 — real jt6295. Reference uses XTAL(8'000'000)/2=4MHz
	// for both chips here (mustang's own was 16MHz/4=4MHz — same 4MHz
	// result from a different divisor, doesn't matter to jt6295_timing.v
	// which just wants a ~1MHz cen regardless — see mustang_core.sv's
	// own header). 1MHz from 40MHz clk_sys is an exact /40.
	// ------------------------------------------------------------------
	reg [5:0] oki_cen_cnt = 6'd0;
	wire      oki_cen = (oki_cen_cnt == 6'd39);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 6'd0 : oki_cen_cnt + 6'd1;

	localparam OKI_SS = 1'b0; // PIN7_LOW, same as mustang

	reg [7:0] oki1_rom [0:524287];
	reg [7:0] oki2_rom [0:524287];
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki1_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki2_rom);

	reg [1:0] oki1_bank_r = 2'd0, oki2_bank_r = 2'd0;
	always @(posedge clk_sys) begin
		if (oki0_bank_we) oki1_bank_r <= oki0_bank[1:0];
		if (oki1_bank_we) oki2_bank_r <= oki1_bank[1:0];
	end

	// Address mapping — same oki1_map/oki2_map bank arithmetic as
	// mustang_core.sv's own oki_phys_addr() (shared nmk16_state code,
	// not redefined per-game in the reference).
	function automatic [18:0] oki_phys_addr(input [17:0] rom_addr, input [1:0] bank);
		reg [2:0] bank_p1;
		reg [19:0] full;
		begin
			bank_p1 = {1'b0, bank} + 3'd1;
			full = rom_addr[17] ? ({bank_p1, 17'd0} + {3'd0, rom_addr[16:0]}) : {3'd0, rom_addr[16:0]};
			oki_phys_addr = full[18:0];
		end
	endfunction

	wire [17:0] oki1_rom_addr, oki2_rom_addr;
	wire [18:0] oki1_phys = oki_phys_addr(oki1_rom_addr, oki1_bank_r);
	wire [18:0] oki2_phys = oki_phys_addr(oki2_rom_addr, oki2_bank_r);

	reg [7:0] oki1_rom_data, oki2_rom_data;
	always @(posedge clk_sys) oki1_rom_data <= oki1_rom[oki1_phys];
	always @(posedge clk_sys) oki2_rom_data <= oki2_rom[oki2_phys];

	reg [7:0] oki0_din_latch, oki1_din_latch;
	reg [5:0] oki0_wr_hold = 6'd0, oki1_wr_hold = 6'd0;
	reg       oki0_we_prev = 1'b0, oki1_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		oki0_we_prev <= oki0_we;
		if (oki0_we && !oki0_we_prev) begin
			oki0_din_latch <= oki0_dout;
			oki0_wr_hold   <= 6'd40;
		end else if (oki0_wr_hold != 6'd0) begin
			oki0_wr_hold <= oki0_wr_hold - 6'd1;
		end
	end
	always @(posedge clk_sys) begin
		oki1_we_prev <= oki1_we;
		if (oki1_we && !oki1_we_prev) begin
			oki1_din_latch <= oki1_dout;
			oki1_wr_hold   <= 6'd40;
		end else if (oki1_wr_hold != 6'd0) begin
			oki1_wr_hold <= oki1_wr_hold - 6'd1;
		end
	end
	wire oki0_wr_n = ~(oki0_wr_hold != 6'd0);
	wire oki1_wr_n = ~(oki1_wr_hold != 6'd0);

	wire [7:0] oki1_chip_dout, oki2_chip_dout;
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(OKI_SS),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr), .rom_data(oki1_rom_data), .rom_ok(1'b1),
		.sound(), .sample()
	);
	jt6295 oki2_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(OKI_SS),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki2_chip_dout),
		.rom_addr(oki2_rom_addr), .rom_data(oki2_rom_data), .rom_ok(1'b1),
		.sound(), .sample()
	);

	nmk004_core #(
		.BOOT_ROM_FILE(NMK004_BOOT_FILE),
		.EXT_ROM_FILE(NMK004_EXT_FILE)
	) nmk004 (
		.clk(nmk004_clk_r), .reset(reset),
		.nmi(nmi_level),
		.ym_cs(ym_cs), .ym_we(ym_we), .ym_addr_sel(ym_addr_sel),
		.ym_dout(ym_dout), .ym_din(ym_chip_dout), .ym_irq_n(ym_chip_irq_n),
		.oki0_cs(oki0_cs), .oki0_we(oki0_we), .oki0_dout(oki0_dout), .oki0_din(oki1_chip_dout),
		.oki1_cs(oki1_cs), .oki1_we(oki1_we), .oki1_dout(oki1_dout), .oki1_din(oki2_chip_dout),
		.oki0_bank_we(oki0_bank_we), .oki0_bank(oki0_bank),
		.oki1_bank_we(oki1_bank_we), .oki1_bank(oki1_bank),
		.host_to_mcu(nmk004_host_to_mcu),
		.mcu_to_host(nmk004_mcu_to_host), .mcu_to_host_we(nmk004_mcu_to_host_we),
		.dbg_pc(dbg_nmk004_pc), .dbg_valid(dbg_nmk004_valid),
		.dbg_a(dbg_nmk004_a), .dbg_f(dbg_nmk004_f), .dbg_hl(dbg_nmk004_hl),
		.dbg_ram_hl(dbg_nmk004_ram_hl),
		.p4(nmk004_p4), .bx(), .by()
	);

	reg [7:0] nmk004_to_host_latch = 8'hFF;
	always @(posedge clk_sys) if (nmk004_mcu_to_host_we) nmk004_to_host_latch <= nmk004_mcu_to_host;

	// ------------------------------------------------------------------
	// Read data mux
	// ------------------------------------------------------------------
	reg [15:0] rdata;
	always @(*) begin
		if (sel_rom)          rdata = rom_dout;
		else if (sel_mainram) rdata = mainram_dout;
		else if (sel_palette) rdata = palette_dout;
		else if (sel_bg1vram) rdata = bg1vram_dout;
		else if (sel_txvram)  rdata = txvram_dout;
		else if (sel_nmk004_r) rdata = {8'h00, nmk004_to_host_latch};
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing (rtl/bjtwin/video_timing.sv, reused unchanged — same
	// "lowres" family geometry mustang_core.sv already uses, since
	// bioship() calls the exact same set_screen_lowres/
	// set_max_sprite_clock(384*263) helpers) + real interrupt generation
	// (rtl/nmk_irq/nmk_irq.sv, driven by bioship's own dumped V-PROM).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);

	wire sprite_dma_trigger; // consumed by video_bioship below
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
	// Video pipeline — real tilemap + sprite rendering. See
	// rtl/bioship/video_bioship.sv's own header for the full derivation.
	// ------------------------------------------------------------------
	video_bioship #(
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.BG2TILE_FILE(BG2TILE_FILE),
		.SPRITES_FILE(SPRITES_FILE),
		.TILEROM_FILE(TILEROM_FILE)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.sprite_dma_trigger(sprite_dma_trigger),
		.bg1vram_addr(vid_bg1vram_addr), .bg1vram_data(vid_bg1vram_dout),
		.txvram_addr(vid_txvram_addr), .txvram_data(vid_txvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout),
		.bg0_xscroll(bg0_xscroll), .bg0_yscroll(bg0_yscroll),
		.bg1_xscroll(bg1_xscroll), .bg1_yscroll(bg1_yscroll),
		.bg0_bank(bg0_bank_reg),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb)
	);

	// frame_done marks a real raster frame boundary (vcount wrap), same
	// convention as mustang_core.sv's own.
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
	assign dbg_ym_we = ym_we;
	assign dbg_ym_cs = ym_cs;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_chip_irq_n = ym_chip_irq_n;
	assign dbg_oki0_we = oki0_we;
	assign dbg_oki0_cs = oki0_cs;
	assign dbg_oki0_chip_dout = oki1_chip_dout;
	assign dbg_oki1_we = oki1_we;
	assign dbg_oki1_cs = oki1_cs;
	assign dbg_oki1_chip_dout = oki2_chip_dout;
	assign dbg_as_n  = ASn;
	assign dbg_fc0   = FC0;
	assign dbg_fc1   = FC1;
	assign dbg_fc2   = FC2;

endmodule
