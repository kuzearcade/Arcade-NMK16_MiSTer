// NMK16 MiSTerFPGA project — acrobatmbl (Tier 5, Family E "Raiden sound"
// bootleg of acrobatm) system-level integration.
//
// The third Tier 5 port, after mustangb (rtl/mustangb/mustangb_core.sv)
// and tdragonb (rtl/tdragonb/tdragonb_core.sv), which this file follows
// structurally line-for-line for the Z80/T80/seibu_sound/jtopl2/jt6295
// architecture (see mustangb_core.sv's own header, not repeated here).
// Reuses, unmodified: `rtl/seibu/seibu_sound.sv`, `rtl/third_party_gen/
// t80/T80s.v` (GHDL-translated Z80 core, twice proven cycle-exact
// against a real MAME oracle — see docs/t80-vhdl-toolchain.md),
// `rtl/bjtwin/video_timing.sv` + `rtl/bjtwin/nmk_irq_hacky.sv`
// (acrobatmbl's own machine config calls set_hacky_interrupt_timing,
// nmk16.cpp:4860, identical fixed-scanline table to mustangb/tdragonb —
// this board's timing PROMs are undumped too), and — genuinely new to
// Tier 5, though already built for Tier 2's `acrobatm` —
// `rtl/acrobatm/video_acrobatm.sv` (acrobatm_map and acrobatmbl_map,
// nmk16.cpp:747-781, share the identical video/VRAM/palette/tilebank/
// scroll register layout, confirmed by reading both directly — only the
// NMK004-specific entries, 0xC000F read / 0xC0016-17 write / 0xC001F
// write, are replaced by main_mustb_w at 0xC001E/F in the bootleg map).
//
// IMPORTANT: unlike video_acrobatm.sv's own donor, rtl/acrobatm/
// acrobatm_core.sv, this file does NOT use that module's 40MHz clk_sys
// architecture (10MHz 68000 = clk_sys/4, since the real acrobatm board's
// 68000 genuinely runs at 10MHz). acrobatmbl's own machine config uses
// `M68000(config, m_maincpu, 8_MHz_XTAL)` — a plain 8MHz — so this file
// uses the SAME 32MHz clk_sys convention mustangb_core.sv/
// tdragonb_core.sv already established (clk_sys/4 = 8MHz), not
// acrobatm_core.sv's. video_acrobatm.sv itself takes a generic clk_sys
// input and derives no frequency-specific timing of its own (confirmed:
// no ce_pix input, no internal frequency-dependent counter — verified by
// reading its own module port list and body directly), so it drops into
// either clock convention unchanged.
//
// Memory map (acrobatmbl_map, nmk16.cpp:766-781 — confirmed identical to
// acrobatm_map, nmk16.cpp:747-764, apart from the sound/protection
// entries noted above):
//   000000-03FFFF  ROM (maincpu, 0x40000, 2 x 0x20000-byte chips
//                  ROM_LOAD16_BYTE, then PIC-protection-patched — see
//                  "PIC protection patch" below)
//   080000-08FFFF  main work RAM, 32768 x 16, plain masked writes
//                  (COMBINE_DATA, same convention as tdragonb_core.sv's
//                  own mainram — acrobatm_map/acrobatmbl_map have no
//                  "mainram_strange_w"-style unconditional write)
//   0C0000-0C0001  IN0 (R)
//   0C0002-0C0003  IN1 (R)
//   0C0008-0C0009  DSW1 (R)
//   0C000A-0C000B  DSW2 (R)
//   0C0015         flipscreen_w (W, byte, LDS=low byte)
//   0C0019         tilebank_w (W, byte, LDS=low byte)
//   0C001E-0C001F  seibu_sound_device::main_mustb_w (W, word — see
//                  rtl/seibu/seibu_sound.sv's own header)
//   0C4000-0C45FF  palette RAM, 768 x 16 (real — video_acrobatm; note
//                  768 entries, NOT 1024 like mustangb/tdragonb — matches
//                  acrobatm's own PALETTE(...,768) in the reference)
//   0C8000-0C8007  scroll_w<0> (BG X/Y scroll, 4 byte sub-registers
//                  [Xhi,Xlo,Yhi,Ylo], sub-index = byte_addr[2:1],
//                  LDS-gated low-byte writes only — exact copy of
//                  acrobatm_core.sv:305-332's own working pattern)
//   0CC000-0CFFFF  BG tilemap VRAM, 8192 x 16 (real — video_acrobatm)
//   0D4000-0D47FF  tx tilemap VRAM, 1024 x 16 (real — video_acrobatm)
//
// Z80 memory map: identical to mustangb's/tdragonb's own (seibu_sound_map,
// seibusound.cpp:333-350) — see mustangb_core.sv's header, not repeated.
//
// PIC protection patch (init_acrobatmbl(), nmk16.cpp:6238-6262): the
// reference calls this "a PIC performing simple protection checks", but
// the PIC itself needs ZERO new RTL — its own machine config declares
// `PIC16C57(config,"mcu",8_MHz_XTAL/2).set_disable()` (MAME disables it
// outright), acrobatmbl_map has no read/write handler referencing any
// PIC/protection port at all, and the PIC's own ROM is genuinely
// undumped (`ROM_LOAD("pic16c57",0x0000,0x2000,NO_DUMP)`). MAME instead
// statically patches 4 sixteen-bit words in the 68000 program ROM,
// replacing two jumps into PIC-protected RAM with jumps elsewhere:
//   rom[0x6c8/2]=0x0000; rom[0x6ca/2]=0x2d84;
//   rom[0x6d4/2]=0x0000; rom[0x6d6/2]=0x3510;
// Reproduced as an offline ROM-extraction-time transform
// (tools/patch_rom_words.py, word indices 0x364/0x365/0x36A/0x36B),
// applied to the maincpu .hex this module's own $readmemh initial block
// loads — no live PIC/protection logic exists anywhere in this file,
// same category as tdragonb's own decode_tdragonb.py transform.
//
// Clock: 68000 at 8_MHz_XTAL = clk_sys/4 (clean, same ratio as
// mustangb's own — no phase accumulator needed, unlike tdragonb's own
// 10MHz case). Z80 + YM3812 both at 8_MHz_XTAL/2 = 4MHz = clk_sys/8 — a
// plain, clean power-of-2 ratio (nmk16.cpp:4862,4880), genuinely simpler
// than mustangb's/tdragonb's own awkward 14318180/4≈3.58MHz
// phase-accumulator case; a free-running counter suffices, no
// accumulator needed. OKIM6295 at 8_MHz_XTAL/8 = 1MHz = clk_sys/32
// (nmk16.cpp:4884), also clean.
//
// Known simplifications: identical list to mustangb_core.sv's own (no
// audio DAC/mixer, IN0/IN1/DSW1/DSW2 tied to fixed idle values, DTACKn
// tied to ASn, T80's WAIT_n tied high) — not repeated here.
module acrobatmbl_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI_ROM_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = ""
) (
	input clk_sys,        // 32 MHz (68000 bus/pixel clk_sys/4 = 8MHz)
	input reset,           // async, active high

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
	output        dbg_z80_iack_active,
	output  [7:0] dbg_z80_iack_vector,
	output        dbg_z80_cen,

	output        dbg_ym_we,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_irq_n,

	output        dbg_oki_we,
	output        dbg_oki_cs,
	output  [7:0] dbg_oki_chip_dout,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [12:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [9:0]  dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	// 68000: exact fx68kTop /4 pattern (see mustangb_core.sv/bjtwin_core.sv).
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	// Z80 + YM3812 shared clock enable: 8_MHz_XTAL/2 = 4MHz = clk_sys/8 —
	// a clean power-of-2 divide (see header), unlike mustangb's/
	// tdragonb's own 14318180/4 phase-accumulator case.
	reg [2:0] z80_div = 3'd0;
	always @(posedge clk_sys) z80_div <= z80_div + 3'd1;
	wire z80_cen = (z80_div == 3'd7);

	// OKIM6295: 8_MHz_XTAL/8 = 1MHz = clk_sys/32 — also a clean divide.
	reg [4:0] oki_div = 5'd0;
	always @(posedge clk_sys) oki_div <= oki_div + 5'd1;
	wire oki_cen = (oki_div == 5'd31);

	// Pixel/raster-timing clock enable for video_timing/nmk_irq_hacky:
	// 8MHz from 32MHz clk_sys — same ratio/reset-gating convention as
	// every prior "lowres" family port (see mustangb_core.sv's header).
	// NOT acrobatm_core.sv's own clk_sys/5 (that ratio is specific to its
	// 40MHz clk_sys convention, not reused here — see header).
	reg [1:0] pix_div = 2'd0;
	wire ce_pix = (pix_div == 2'd3);
	always @(posedge clk_sys) pix_div <= reset ? 2'd0 : (ce_pix ? 2'd0 : pix_div + 2'd1);

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
	// Address decode (68000 side) — matches acrobatm_map's own layout
	// (see header), no mirroring anywhere on either map.
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h03FFFF);
	wire sel_mainram   = (byte_addr >= 24'h080000) && (byte_addr <= 24'h08FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h060000); // 0C0000/0C0001
	wire sel_in1       = (byte_addr[23:1] == 23'h060001); // 0C0002/0C0003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h060004); // 0C0008/0C0009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h060005); // 0C000A/0C000B
	wire sel_flip      = (byte_addr[23:1] == 23'h06000A); // 0C0014/0C0015, LDS=low byte
	wire sel_tilebank  = (byte_addr[23:1] == 23'h06000C); // 0C0018/0C0019, LDS=low byte
	wire sel_mustb     = (byte_addr[23:1] == 23'h06000F); // 0C001E/0C001F word
	wire sel_palette   = (byte_addr >= 24'h0C4000) && (byte_addr <= 24'h0C45FF);
	wire sel_scroll    = (byte_addr >= 24'h0C8000) && (byte_addr <= 24'h0C8007);
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire sel_bgvram    = (byte_addr >= 24'h0CC000) && (byte_addr <= 24'h0CFFFF);
	wire sel_txvram    = (byte_addr >= 24'h0D4000) && (byte_addr <= 24'h0D47FF);

	// ------------------------------------------------------------------
	// ROM (maincpu) — already PIC-protection-patched offline (see header)
	// ------------------------------------------------------------------
	reg [15:0] rom [0:131071]; // 0x20000 words = 0x40000 bytes
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[17:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — plain masked write, no mirroring
	// (COMBINE_DATA, same convention as tdragonb_core.sv's own mainram).
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
	// Palette RAM (768 x 16 — NOT 1024, see header)
	// ------------------------------------------------------------------
	reg [15:0] palette [0:767];
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
	// BG tilemap VRAM (8192 x 16)
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
	// TX tilemap VRAM (1024 x 16)
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
	// Dual-port video read taps (video_acrobatm.sv's own live reads)
	// ------------------------------------------------------------------
	wire [12:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout = bgvram[vid_bgvram_addr];
	wire [9:0]  vid_txvram_addr;
	wire [15:0] vid_txvram_dout = txvram[vid_txvram_addr];
	wire [9:0]  vid_palette_addr;
	wire [15:0] vid_palette_dout = palette[vid_palette_addr];
	wire [9:0]  vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout = palette[vid_spr_palette_addr];
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout = mainram[vid_mainram_addr];

	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bgvram_data = bgvram[dbg_bgvram_addr];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers (write-captured only) — scroll/tilebank wiring is a
	// direct copy of acrobatm_core.sv:305-332's own working pattern.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg [7:0]  scroll_reg [0:3]; // [Xhi,Xlo,Yhi,Ylo]
	reg        mustb_we_pulse;
	reg [15:0] mustb_data_r;

	wire [15:0] bg_xscroll = {scroll_reg[0], scroll_reg[1]};
	wire [15:0] bg_yscroll = {scroll_reg[2], scroll_reg[3]};

	integer si;
	always @(posedge clk_sys) begin
		mustb_we_pulse <= 1'b0;
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			for (si = 0; si < 4; si = si + 1) scroll_reg[si] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank & ~LDSn) bgbank_reg       <= oEdb[7:0];
			if (sel_scroll & ~LDSn)   scroll_reg[scroll_word_idx] <= oEdb[7:0];
			if (sel_mustb) begin
				// main_mustb_w (seibusound.cpp:319-329): RST18 asserts
				// unconditionally, byte lanes latch independently — see
				// mustangb_core.sv's own identical comment/derivation.
				mustb_we_pulse <= 1'b1;
				if (~LDSn) mustb_data_r[7:0]  <= oEdb[7:0];
				if (~UDSn) mustb_data_r[15:8] <= oEdb[15:8];
			end
		end
	end

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// Z80 sound board: T80 + seibu_sound + jtopl2 + jt6295 — identical
	// integration to mustangb_core.sv's own (see that file for the full
	// derivation of every piece below); only the clock enables above
	// differ (clean power-of-2 ratios here, see header).
	// ------------------------------------------------------------------
	wire [15:0] z80_a;
	wire [7:0]  z80_do;
	wire [7:0]  z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
	wire        z80_int_n;

	T80s z80_cpu (
		.RESET_n(~reset),
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

	wire sel_z80_rom  = (z80_a < 16'h2000);
	wire sel_z80_ram  = (z80_a >= 16'h2000) && (z80_a < 16'h2800);
	wire sel_z80_seibu = (z80_a >= 16'h4000) && (z80_a < 16'h4020);
	wire sel_z80_oki  = (z80_a == 16'h6000);
	wire sel_z80_bank = (z80_a >= 16'h8000);

	// Audiocpu ROM: full 0x20000-byte flat image — same ROM_LOAD+
	// ROM_CONTINUE+ROM_COPY layout as mustangb's/tdragonb's own (see
	// header — byte-identical audiocpu ROM, CRC 99ee7505).
	reg [7:0] audiocpu_rom [0:131071];
	initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);

	wire        bank_sel;
	wire [16:0] z80_bank_base = bank_sel ? 17'h18000 : 17'h10000;
	wire [16:0] z80_bank_phys = z80_bank_base + {2'b00, z80_a[14:0]};

	reg [7:0] z80_ram [0:2047];
	always @(posedge clk_sys) if (sel_z80_ram & z80_mem_we) z80_ram[z80_a[10:0]] <= z80_do;

	wire ym_cs, ym_we, ym_addr_sel;
	wire [7:0] ym_wdata, ym_rdata;
	wire [7:0] seibu_z80_din;
	wire       z80_iack_active;
	wire [7:0] z80_iack_vector;

	seibu_sound seibu (
		.clk_sys(clk_sys), .reset(reset),
		.z80_addr(z80_a),
		.z80_dout(z80_do),
		.z80_sel(sel_z80_seibu),
		.z80_we(z80_mem_we),
		.z80_re(z80_mem_re),
		.z80_din(seibu_z80_din),
		.z80_m1_n(z80_m1_n),
		.z80_iorq_n(z80_iorq_n),
		.z80_iack_vector(z80_iack_vector),
		.z80_iack_active(z80_iack_active),
		.z80_int_n(z80_int_n),
		.m68k_mustb_we(mustb_we_pulse),
		.m68k_mustb_data(mustb_data_r),
		.ym_cs(ym_cs), .ym_we(ym_we), .ym_addr_sel(ym_addr_sel),
		.ym_wdata(ym_wdata), .ym_rdata(ym_rdata), .ym_irq_n(ym_chip_irq_n),
		.bank_sel(bank_sel)
	);

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	jtopl2 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(z80_cen),
		.din(ym_wdata), .addr(ym_addr_sel), .cs_n(~ym_cs), .wr_n(~ym_we),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.snd(), .sample()
	);
	assign ym_rdata = ym_chip_dout;

	// OKIM6295 — jt6295. Same write-stretch/rom_ok pattern as
	// mustangb_core.sv's own (z80_a==0x6000 is a Z80-domain strobe
	// narrower than jt6295's own cen period, needs latch-and-hold).
	reg [7:0] oki_rom [0:262143]; // 0x40000 bytes (ROM_REGION(0x040000,"oki"))
	initial if (OKI_ROM_FILE != "") $readmemh(OKI_ROM_FILE, oki_rom);

	wire [17:0] oki_rom_addr;
	reg  [7:0]  oki_rom_data;
	always @(posedge clk_sys) oki_rom_data <= oki_rom[oki_rom_addr[17:0]];

	wire sel_z80_oki_we = sel_z80_oki & z80_mem_we;
	reg [7:0] oki_din_latch;
	reg [5:0] oki_wr_hold = 6'd0;
	reg       oki_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		oki_we_prev <= sel_z80_oki_we;
		if (sel_z80_oki_we && !oki_we_prev) begin
			oki_din_latch <= z80_do;
			oki_wr_hold   <= 6'd40;
		end else if (oki_wr_hold != 6'd0) begin
			oki_wr_hold <= oki_wr_hold - 6'd1;
		end
	end
	wire oki_wr_n = ~(oki_wr_hold != 6'd0);

	wire [7:0] oki_chip_dout;
	jt6295 oki_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(1'b0),
		.wrn(oki_wr_n), .din(oki_din_latch), .dout(oki_chip_dout),
		.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(1'b1),
		.sound(), .sample()
	);

	// ------------------------------------------------------------------
	// Z80 read-data mux
	// ------------------------------------------------------------------
	reg [7:0] z80_rdata;
	always @(*) begin
		if (z80_iack_active)     z80_rdata = z80_iack_vector;
		else if (sel_z80_rom)    z80_rdata = audiocpu_rom[z80_a[12:0]];
		else if (sel_z80_ram)    z80_rdata = z80_ram[z80_a[10:0]];
		else if (sel_z80_seibu)  z80_rdata = seibu_z80_din;
		else if (sel_z80_oki)    z80_rdata = oki_chip_dout;
		else if (sel_z80_bank)   z80_rdata = audiocpu_rom[z80_bank_phys];
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
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + hacky fixed-scanline IRQ generator (see header —
	// acrobatmbl's own timing PROMs are undumped, unlike acrobatm's own
	// real V-PROM-driven rtl/nmk_irq/nmk_irq.sv).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);

	wire sprite_dma_trigger;
	nmk_irq_hacky irq_gen (
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
	// Video pipeline — rtl/acrobatm/video_acrobatm.sv, unmodified (see
	// header). Note the 3-way bg_xscroll/bg_yscroll/bg_bank port split,
	// matching acrobatm_core.sv:556-571's own instantiation exactly.
	// ------------------------------------------------------------------
	video_acrobatm #(
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
	assign dbg_z80_iack_active = z80_iack_active;
	assign dbg_z80_iack_vector = z80_iack_vector;
	assign dbg_z80_cen = z80_cen;

	assign dbg_ym_we = ym_we;
	assign dbg_ym_cs = ym_cs;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_irq_n = ym_chip_irq_n;

	assign dbg_oki_we = sel_z80_oki_we;
	assign dbg_oki_cs = sel_z80_oki;
	assign dbg_oki_chip_dout = oki_chip_dout;

endmodule
