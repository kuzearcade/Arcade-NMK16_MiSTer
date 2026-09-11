// NMK16 MiSTerFPGA project — GunNail (gunnail, gunnailp) system-level
// integration, hardware-ready. Built on raphero_core.sv's HW_ROMS
// machinery (every ROM through caches over rtl/sdram.sv, loaded by
// ioctl_download; registered on-chip RAMs; sprite-DMA CPU stall; audio
// mix; real inputs) and rtl/macross2/video_macross2.sv with the
// gfx_macross parameters (4-bit sprite colour, TX palette at 0x200,
// 13-bit BG code), RASTER_SCROLL=1 and the two NMK214 descramblers.
// See docs/hw-bringup.md.
//
// What the board is (nmk16.cpp gunnail() + gunnail_prot(), cross-checked):
//   - 68000 at 10 MHz (XTAL(10'000'000), verified on PCB), gunnail_map:
//     I/O at 0x080000, palette 0x088000, gunnail_scrollram/scrollramy at
//     0x08C000/0x08C200 (write-only, 256 words each), 0x08C400-0x08C7FF
//     nopw, BG VRAM 0x090000 (8192 words, no tilerambank), TX VRAM
//     0x09C000 mirrored at +0x1000, main RAM 0x0F0000 (plain, no swap).
//   - NMK004 sound MCU (TLCS-90 TMP90C840, rtl/tlcs90/nmk004_core.sv) at
//     8 MHz: 8 KB internal boot ROM (nmk004.bin) + the game's 64 KB
//     external program (92077_2.u101), YM2203 at 1.5 MHz, two OKIM6295
//     at 4 MHz pin 7 low whose upper 128 KB window the NMK004 banks
//     (oki1_map/oki2_map + nmk004's fc01/fc02 bank writes). The NMK004's
//     P4 bit 0 resets the 68000; 0x080016 bit 0 drives its NMI (a
//     watchdog kick). Both MCUs run on clk_sys with clock enables here
//     (tlcs90.sv's cen): the NMK004's 8 MHz enable is withheld while its
//     program-ROM cache misses (0.1% of pulses in the raphero sim, same
//     mechanism), the protection MCU's 4 MHz enable while a shared-bus
//     access waits for its RAM port.
//   - NMK-215 protection MCU (TMP90840, nmk_prot_core.sv, 8 KB ROM
//     nmk-215.bin, byte-identical to macross's) at 4 MHz: in this game
//     it only loads the two NMK214 descrambler configs at boot through
//     its port 3/port 7 (a MAME Lua trace over 30 s of attract mode
//     shows no 68000-bus access at all, and its port 6 writes are
//     0x03/0x0B — never the 0x08 "halt the 68000" the NMK-110/113
//     firmware uses). The shared-bus path is still wired (RAM-port steal
//     with the 68000 held off by DTACK, own ROM cache) so the mechanism
//     is real if a firmware uses it.
//   - Video: VIDEO_START gunnail = macross2's 64x32 TX tilemap + the
//     per-line scroll tables (bg_update: both tables indexed by bitmap
//     y), gfx_macross bases (BG 0x000, sprites 0x100 x16, TX 0x200),
//     BG ROM 1 MB (13-bit code), sprite ROM 2 MB, both descrambled
//     per-fetch by the NMK214s. Same V-PROM as macross (9_82s135.u72).
//
// SDRAM layout (bytes; word offset = byte offset / 2), see BASE_BYTE_*:
//   0x000000 maincpu  0x080000 (3o.u133 even / 3e.u131 odd bytes — the
//                     .mra <interleave> puts the LOW-byte chip on even
//                     ioctl addresses, which the parity rebuild makes the
//                     word's low byte; gunnailp's single WORD_SWAP file
//                     gives the same order)
//   0x080000 nmk004 external program 0x010000 (92077_2.u101; 0x0000-
//                     0x1FFF of it is hidden by the internal ROM)
//   0x090000 nmk004 boot ROM 0x002000 (nmk004.bin, from nmk004.zip)
//   0x092000 protection MCU ROM 0x002000 (nmk-215.bin) — also copied
//                     into the MCU's on-chip array during the download
//   0x094000 fgtile   0x020000
//   0x0B4000 bgtile   0x100000
//   0x1B4000 sprites  0x200000 (ROM_LOAD16_WORD_SWAP)
//   0x3B4000 oki1     0x080000
//   0x434000 oki2     0x080000, image ends 0x4B4000
// The regions are CONTIGUOUS: the MiSTer .mra loader streams the <part>s
// back to back with no way to place one at an offset, so any gap in this
// table shifts every later ROM (the first hardware build had a 0xC000
// gap after the protection ROM and drew scrambled BG tiles and sprites
// from the shifted data while the text layer happened to survive).
module gunnail_core #(
	parameter ROM_FILE          = "",
	parameter NMK004_BOOT_FILE  = "",
	parameter NMK004_EXT_FILE   = "",
	parameter PROT_BOOT_FILE    = "",
	parameter OKI1_ROM_FILE     = "",
	parameter OKI2_ROM_FILE     = "",
	parameter VTIMING_FILE      = "",
	parameter FGTILE_FILE       = "",
	parameter BGTILE_FILE       = "",
	parameter SPRITES_FILE      = "",
	// HW_ROMS=0 (reference sim): $readmemh 0-latency arrays. HW_ROMS=1
	// (Gunnail.sv and the gunnail_hw sim): every ROM through a cache over
	// rtl/sdram.sv, loaded via ioctl_download.
	parameter HW_ROMS           = 0,
	parameter DBG_MISS_PAINT    = 0
) (
	input clk_sys,        // 40 MHz (68000 clk_sys/4 = 10 MHz; NMK004/pixel clk_sys/5 = 8 MHz; protection MCU clk_sys/10 = 4 MHz)
	input reset,          // async, active high

	// Hardware-mode-only ports (HW_ROMS=1) — see tdragon2_core.sv.
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input      [7:0]  ioctl_dout,
	input     [15:0]  ioctl_index,
	output            ioctl_wait,

	// SDRAM port 0: ioctl_download writes muxed with maincpu ROM reads.
	output     [24:1] sd0_addr,
	output            sd0_wrl,
	output            sd0_wrh,
	output     [15:0] sd0_din,
	input      [15:0] sd0_dout,
	input      [31:0] sd0_dout_pair,
	output            sd0_req,
	input             sd0_ack,
	// SDRAM port 1: NMK004 program ROM, OKI0/OKI1 samples, protection
	// MCU ROM — 4-way arbitrated internally.
	output     [24:1] sd1_addr,
	output            sd1_req,
	input      [15:0] sd1_dout,
	input      [31:0] sd1_dout_pair,
	input             sd1_ack,
	// SDRAM port 2: video_macross2.sv's BG-tile prefetch stream.
	output     [24:1] sd2_addr,
	output            sd2_wrl,
	output            sd2_wrh,
	output     [15:0] sd2_din,
	input      [15:0] sd2_dout,
	input      [31:0] sd2_dout_pair,
	output            sd2_req,
	input             sd2_ack,
	// SDRAM port 3: video_macross2.sv's TX-tile prefetch + sprite fetch.
	output     [24:1] sd3_addr,
	output            sd3_req,
	input      [15:0] sd3_dout,
	input      [31:0] sd3_dout_pair,
	input             sd3_ack,

	// debug/trace outputs for the Verilator testbenches
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output [15:0] dbg_nmk004_pc,
	output        dbg_nmk004_valid,
	output        dbg_nmk004_cen,
	output        dbg_nmk004_stall,
	output [31:0] dbg_nmk004_cen_total,   // sim only
	output [31:0] dbg_nmk004_stall_total, // sim only
	// 68000 <-> NMK004 latch traffic (for the boot-handshake trace)
	output        dbg_host_cmd_we,
	output [7:0]  dbg_host_cmd,
	output        dbg_mcu_reply_we,
	output [7:0]  dbg_mcu_reply,

	output [15:0] dbg_prot_pc,
	output        dbg_prot_valid,
	output        dbg_halt_68k,
	output [15:0] dbg_prot_hl,
	output  [7:0] dbg_prot_a,
	output [15:0] dbg_prot_de,
	output [15:0] dbg_prot_iy,
	output [19:0] dbg_prot_addr,
	output  [7:0] dbg_prot_int_ram_at_hl,
	output        dbg_prot_bus_rd,
	output        dbg_prot_bus_wr,
	output [9:0]  dbg_vt_vcount,
	output        dbg_nmk214_cfg_we,
	output [7:0]  dbg_nmk214_cfg_data,

	output        dbg_ym_we,
	// per-source audio taps (sim level checks against MAME's routes)
	output signed [15:0] dbg_fm_snd,
	output        [9:0]  dbg_psg_snd,
	output signed [13:0] dbg_oki0_snd,
	output signed [13:0] dbg_oki1_snd,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_chip_irq_n,
	output  [7:0] dbg_ym_wdata,   // data the sound CPU writes to the YM2203
	output        dbg_ym_waddr,   // 0 = register select, 1 = data

	output        dbg_oki0_we,
	output        dbg_oki0_cs,
	output  [7:0] dbg_oki0_chip_dout,
	output        dbg_oki1_we,
	output        dbg_oki1_cs,
	output  [7:0] dbg_oki1_chip_dout,
	output [31:0] dbg_oki0_adpcm_total,
	output [31:0] dbg_oki0_adpcm_unserved,
	output [31:0] dbg_oki1_adpcm_total,
	output [31:0] dbg_oki1_adpcm_unserved,
	output [31:0] dbg_oki_cen_total,
	output [31:0] dbg_oki0_stall_cen,
	output [31:0] dbg_oki1_stall_cen,

	output [7:0]  dbg_nmk004_a,
	output [7:0]  dbg_nmk004_f,
	output [15:0] dbg_nmk004_hl,
	output [7:0]  dbg_nmk004_ram_hl,
	output [15:0] dbg_nmk004_de,
	output [15:0] dbg_nmk004_bc,
	output [15:0] dbg_nmk004_ix,
	output [15:0] dbg_nmk004_iy,
	output [15:0] dbg_nmk004_sp,

	// pixel readback (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [13:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done,

	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	output        ce_pix_o,
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,
	output        hblank_o,
	output        vblank_o,

	// Real inputs (HW_ROMS=1 only; the sim path reads 0xFFFF = idle).
	input  [15:0] in0_i,
	input  [15:0] in1_i,
	input  [15:0] dsw1_i,
	input  [15:0] dsw2_i,

	input extra_por_hold
);

	// ------------------------------------------------------------------
	// Power-on-only reset for the SDRAM req/arb instances (see
	// tdragon2_core.sv's por_rst).
	// ------------------------------------------------------------------
	reg [3:0] por_cnt = 4'd0;
	reg       por_rst = 1'b1;
	always @(posedge clk_sys) begin
		if (extra_por_hold) begin
			por_cnt <= 4'd0;
			por_rst <= 1'b1;
		end else if (por_rst) begin
			if (por_cnt == 4'd15) por_rst <= 1'b0;
			else por_cnt <= por_cnt + 4'd1;
		end
	end

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// NMK004: 8 MHz enable, withheld while its ROM cache misses (never
	// in reset — the core samples reset on cen edges).
	reg [2:0] snd_div = 3'd0;
	always @(posedge clk_sys) snd_div <= (snd_div == 3'd4) ? 3'd0 : snd_div + 3'd1;
	wire nmk004_rom_stall;
	wire snd_stall = nmk004_rom_stall & ~reset;
	wire snd_cen   = (snd_div == 3'd4) & ~snd_stall;

	// Protection MCU: 4 MHz enable, withheld while a shared-bus access
	// (or its own ROM fetch on the hardware path) is not yet served.
	reg [3:0] prot_div = 4'd0;
	always @(posedge clk_sys) prot_div <= (prot_div == 4'd9) ? 4'd0 : prot_div + 4'd1;
	wire prot_stall;
	wire prot_cen = (prot_div == 4'd9) & ~(prot_stall & ~reset);

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

	// OKIM6295 x2 at XTAL(16 MHz)/4 = 4 MHz, pin 7 low: clk_sys/10.
	reg [3:0] oki_cen_cnt = 4'd0;
	wire      oki_cen = (oki_cen_cnt == 4'd9);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 4'd0 : oki_cen_cnt + 4'd1;

	// ------------------------------------------------------------------
	// fx68k — HALTn from the protection MCU, extReset also from the
	// NMK004's P4 bit 0 (nmk004_device reset_cb, the watchdog).
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
	wire rom_wait     = sel_rom     & cpu_read & ~rom_ready;
	wire mainram_wait = sel_mainram & cpu_read & ~mainram_ready;
	wire sprite_dma_busy;
	wire mainram_dma_wait = sel_mainram & ~ASn & sprite_dma_busy;
	wire palette_wait = sel_palette & cpu_read & ~palette_ready;
	wire bgvram_wait  = sel_bgvram  & cpu_read & ~bgvram_ready;
	wire txvram_wait  = sel_txvram  & cpu_read & ~txvram_ready;
	wire DTACKn = ASn | iack_cycle | rom_wait | mainram_wait | mainram_dma_wait | palette_wait | bgvram_wait | txvram_wait;

	wire [7:0] nmk004_p4;
	wire m68k_extReset = reset | nmk004_p4[0];

	wire halt_68k;
	assign dbg_halt_68k = halt_68k;

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(~halt_68k),
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
	// Address decode (gunnail_map)
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h07FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1       = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040004); // 080008/080009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h040005); // 08000A/08000B
	wire sel_nmk004_r  = (byte_addr[23:1] == 23'h040007); // 08000E/08000F
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015
	wire sel_nmi       = (byte_addr[23:1] == 23'h04000B); // 080016/080017
	wire sel_tilebank  = (byte_addr[23:1] == 23'h04000C); // 080018/080019
	wire sel_nmk004_w  = (byte_addr[23:1] == 23'h04000F); // 08001E/08001F
	wire sel_palette   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h0887FF);
	wire sel_scrollram  = (byte_addr >= 24'h08C000) && (byte_addr <= 24'h08C1FF);
	wire sel_scrollramy = (byte_addr >= 24'h08C200) && (byte_addr <= 24'h08C3FF);
	wire sel_bgvram    = (byte_addr >= 24'h090000) && (byte_addr <= 24'h093FFF);
	wire sel_txvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09DFFF); // mirror bit 12 ignored
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// Protection MCU shared-bus decode (20-bit byte address)
	// ------------------------------------------------------------------
	wire [19:0] prot_addr;
	assign dbg_prot_addr = prot_addr;
	wire        prot_rd, prot_wr;
	wire [7:0]  prot_wdata;
	wire [7:0]  prot_rdata;
	assign dbg_prot_bus_rd = prot_rd;
	assign dbg_prot_bus_wr = prot_wr;

	wire prot_sel_rom       = (prot_addr <= 20'h07FFFF);
	wire prot_sel_in0       = (prot_addr[19:1] == 19'h040000);
	wire prot_sel_in1       = (prot_addr[19:1] == 19'h040001);
	wire prot_sel_dsw1      = (prot_addr[19:1] == 19'h040004);
	wire prot_sel_dsw2      = (prot_addr[19:1] == 19'h040005);
	wire prot_sel_nmk004_r  = (prot_addr[19:1] == 19'h040007);
	wire prot_sel_flip      = (prot_addr[19:1] == 19'h04000A);
	wire prot_sel_nmi       = (prot_addr[19:1] == 19'h04000B);
	wire prot_sel_tilebank  = (prot_addr[19:1] == 19'h04000C);
	wire prot_sel_nmk004_w  = (prot_addr[19:1] == 19'h04000F);
	wire prot_sel_palette   = (prot_addr >= 20'h088000) && (prot_addr <= 20'h0887FF);
	wire prot_sel_scrollram  = (prot_addr >= 20'h08C000) && (prot_addr <= 20'h08C1FF);
	wire prot_sel_scrollramy = (prot_addr >= 20'h08C200) && (prot_addr <= 20'h08C3FF);
	wire prot_sel_bgvram    = (prot_addr >= 20'h090000) && (prot_addr <= 20'h093FFF);
	wire prot_sel_txvram    = (prot_addr >= 20'h09C000) && (prot_addr <= 20'h09DFFF);
	wire prot_sel_mainram   = (prot_addr >= 20'h0F0000) && (prot_addr <= 20'h0FFFFF);

	// ------------------------------------------------------------------
	// SDRAM image offsets — see header.
	// ------------------------------------------------------------------
	localparam [23:0] BASE_BYTE_NMK004_EXT  = 24'h080000;
	localparam [23:0] BASE_BYTE_NMK004_BOOT = 24'h090000;
	localparam [23:0] BASE_BYTE_PROT        = 24'h092000;
	localparam [23:0] BASE_BYTE_FGTILE      = 24'h094000;
	localparam [23:0] BASE_BYTE_BGTILE      = 24'h0B4000;
	localparam [23:0] BASE_BYTE_SPRITES     = 24'h1B4000;
	localparam [23:0] BASE_BYTE_OKI1        = 24'h3B4000;
	localparam [23:0] BASE_BYTE_OKI2        = 24'h434000;
	localparam [22:0] BASE_WORD_NMK004      = BASE_BYTE_NMK004_EXT[23:1]; // boot at +0x10000 bytes, see nmk004_cache_addr
	localparam [22:0] BASE_WORD_PROT        = BASE_BYTE_PROT[23:1];
	localparam [22:0] BASE_WORD_FGTILE      = BASE_BYTE_FGTILE[23:1];
	localparam [22:0] BASE_WORD_BGTILE      = BASE_BYTE_BGTILE[23:1];
	localparam [22:0] BASE_WORD_SPRITES     = BASE_BYTE_SPRITES[23:1];
	localparam [22:0] BASE_WORD_OKI1        = BASE_BYTE_OKI1[23:1];
	localparam [22:0] BASE_WORD_OKI2        = BASE_BYTE_OKI2[23:1];

	// ------------------------------------------------------------------
	// ROM (maincpu), 0x80000 bytes. HW_ROMS=1: rom_cache1 over SDRAM
	// port 0, shared with the ioctl_download writes; the cache only sees
	// ROM addresses (see raphero_core.sv's rom_addr_held).
	// ------------------------------------------------------------------
	wire [15:0] rom_dout;
	wire        rom_ready;
	wire        ioctl_rom_wr = ioctl_download && (ioctl_index == 16'd0);
	generate
	if (!HW_ROMS) begin : g_rom_sim
		reg [15:0] rom [0:262143];
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
		assign rom_dout  = rom[byte_addr[18:1]];
		assign rom_ready = 1'b1;
		assign prot_rom_word = rom[prot_addr[18:1]];
		assign sd0_addr = 24'd0; assign sd0_wrl = 1'b0; assign sd0_wrh = 1'b0;
		assign sd0_din  = 16'd0; assign sd0_req = 1'b0;
		assign ioctl_wait = 1'b0;
	end else begin : g_rom_hw
		wire        cache_busy, cache_valid;
		wire [15:0] cache_dout;
		wire [31:0] cache_dout_pair;
		wire [24:1] cache_sd_addr;
		wire        cache_sd_req;

		sdram_req sd0_inst (
			.clk(clk_sys), .reset(por_rst),
			.addr(ioctl_download ? ioctl_addr[24:1] : cache_sd_addr),
			.we(ioctl_rom_wr), .wrl(ioctl_rom_wr & ~ioctl_addr[0]), .wrh(ioctl_rom_wr & ioctl_addr[0]),
			.din({ioctl_dout, ioctl_dout}),
			.req(ioctl_download ? (ioctl_rom_wr & ioctl_wr) : cache_sd_req),
			.busy(cache_busy), .valid(cache_valid), .dout(cache_dout), .dout_pair(cache_dout_pair),
			.sdram_addr(sd0_addr), .sdram_wrl(sd0_wrl), .sdram_wrh(sd0_wrh), .sdram_din(sd0_din),
			.sdram_dout(sd0_dout), .sdram_dout_pair(sd0_dout_pair), .sdram_req(sd0_req), .sdram_ack(sd0_ack),
			.dbg_we_r_o(), .dbg_addr_r_o()
		);
		assign ioctl_wait = ioctl_download & cache_busy;
		assign prot_rom_word = {prot_rom_din, prot_rom_din}; // byte cache: the wanted byte at both positions

		reg [18:1] rom_addr_held;
		always @(posedge clk_sys) if (sel_rom) rom_addr_held <= byte_addr[18:1];
		wire [18:1] rom_cache_addr = sel_rom ? byte_addr[18:1] : rom_addr_held;
		// 16 pairs + next-pair prefetch instead of rom_cache1's single
		// pair: see rtl/rom_cache_n.sv (68000 slowdown vs MAME).
		rom_cache_n #(.LINES(16), .PREFETCH(1), .LAST_PAIR(22'h01FFFF)) rom_cache_inst (
			.clk(clk_sys), .reset(reset | ioctl_download),
			.addr(rom_cache_addr), .data(rom_dout), .ready(rom_ready),
			.sd_addr(cache_sd_addr), .sd_req(cache_sd_req),
			.sd_busy(cache_busy), .sd_valid(cache_valid), .sd_dout(cache_dout), .sd_dout_pair(cache_dout_pair)
		);
`ifdef VERILATOR
		reg [15:0] golden_rom [0:262143];
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, golden_rom);
		reg [31:0] rom_words_checked = 32'd0, rom_words_wrong = 32'd0;
		reg        dtackn_d = 1'b1;
		always @(posedge clk_sys) begin
			dtackn_d <= DTACKn;
			if (ROM_FILE != "" && dtackn_d && !DTACKn && sel_rom && cpu_read) begin
				rom_words_checked <= rom_words_checked + 32'd1;
				if (rom_dout != golden_rom[byte_addr[18:1]]) begin
					rom_words_wrong <= rom_words_wrong + 32'd1;
					if (rom_words_wrong < 32'd10)
						$display("[%0t] ROM wrong word: addr=%06x got=%04x golden=%04x", $time, byte_addr, rom_dout, golden_rom[byte_addr[18:1]]);
				end
			end
		end
		final $display("ROM golden-word audit: %0d words checked, %0d wrong", rom_words_checked, rom_words_wrong);
`endif
	end
	endgenerate

	// ------------------------------------------------------------------
	// Protection-MCU shared-bus arbitration onto the RAM ports (HW_ROMS=1).
	// Each on-chip RAM has one CPU-side port (read + write, registered
	// read for block-RAM inference) and one video-side port. The
	// protection MCU steals the CPU-side port for a cycle whenever the
	// 68000 is not mid-cycle on that RAM; the 68000's own combinational
	// ready flag (registered address == its address AND the last read was
	// its own) then holds DTACK for the one clock it lost. The MCU's cen
	// is withheld until its read has been served (prot_rd_ready) or its
	// write performed once (prot_wr_done).
	// ------------------------------------------------------------------
	wire prot_acc = prot_rd | prot_wr;
	reg  prot_wr_done;
	wire mainram_prot_grant, palette_prot_grant, bgvram_prot_grant, txvram_prot_grant; // 1 = the MCU owns that RAM's CPU-side port this clock
	wire [15:0] prot_rom_word;

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16, plain — gunnail_map has no address swap)
	// ------------------------------------------------------------------
	// Two 8-bit lane arrays with the shared 68000/MCU port coded as a
	// true-dual-port read/write port (its read register takes the byte
	// being written, otherwise the array): Quartus 17 then infers ONE
	// M10K set in BIDIR_DUAL_PORT mode (port A here, port B the video
	// read) instead of a simple-dual-port set plus a second full copy
	// for the video read, which the old-data read-during-write of a
	// 16-bit array with lane writes forced on every dual-read RAM (NMK-10;
	// raphero_core.sv has the isolated synthesis test's story).
	reg [7:0] mainram_hi [0:32767];
	reg [7:0] mainram_lo [0:32767];
	wire [14:0] mainram_addr_cpu = byte_addr[15:1];
	reg  [15:0] mainram_dout;
	wire        mainram_ready;
	wire        prot_mainram_ready;
	wire [15:0] prot_mainram_dout;
	generate
	if (!HW_ROMS) begin : g_mainram_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_mainram & prot_cen) begin
				if (~prot_addr[0]) mainram_hi[prot_addr[15:1]] <= prot_wdata;
				else                mainram_lo[prot_addr[15:1]] <= prot_wdata;
			end else if (sel_mainram & cpu_write & ~sprite_dma_busy) begin
				if (~UDSn) mainram_hi[mainram_addr_cpu] <= oEdb[15:8];
				if (~LDSn) mainram_lo[mainram_addr_cpu] <= oEdb[7:0];
			end
		end
		always @(*) mainram_dout = {mainram_hi[mainram_addr_cpu], mainram_lo[mainram_addr_cpu]};
		assign mainram_ready      = 1'b1;
		assign prot_mainram_dout  = {mainram_hi[prot_addr[15:1]], mainram_lo[prot_addr[15:1]]};
		assign prot_mainram_ready = 1'b1;
		assign mainram_prot_grant = 1'b1;
	end else begin : g_mainram_hw
		wire        grant = prot_acc & prot_sel_mainram & ~(sel_mainram & ~ASn) & ~sprite_dma_busy;
		wire [14:0] port_addr = grant ? prot_addr[15:1] : mainram_addr_cpu;
		reg  [14:0] port_addr_r;
		reg         port_src_r;
		wire        prot_w = grant & prot_wr & ~prot_wr_done;
		wire        we_hi = (prot_w & ~prot_addr[0]) | (~grant & sel_mainram & cpu_write & ~UDSn & ~sprite_dma_busy);
		wire        we_lo = (prot_w &  prot_addr[0]) | (~grant & sel_mainram & cpu_write & ~LDSn & ~sprite_dma_busy);
		wire [7:0]  wd_hi = prot_w ? prot_wdata : oEdb[15:8];
		wire [7:0]  wd_lo = prot_w ? prot_wdata : oEdb[7:0];
		always @(posedge clk_sys) begin
			if (we_hi) begin mainram_hi[port_addr] <= wd_hi; mainram_dout[15:8] <= wd_hi; end
			else       mainram_dout[15:8] <= mainram_hi[port_addr];
			if (we_lo) begin mainram_lo[port_addr] <= wd_lo; mainram_dout[7:0]  <= wd_lo; end
			else       mainram_dout[7:0]  <= mainram_lo[port_addr];
			port_addr_r  <= port_addr;
			port_src_r   <= grant;
		end
		assign mainram_ready      = ~port_src_r & (port_addr_r == mainram_addr_cpu);
		assign prot_mainram_dout  = mainram_dout;
		assign prot_mainram_ready = port_src_r & (port_addr_r == prot_addr[15:1]);
		assign mainram_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16)
	// ------------------------------------------------------------------
	reg [15:0] palette [0:1023];
	wire [9:0] palette_addr = byte_addr[10:1];
	reg  [15:0] palette_dout;
	wire        palette_ready;
	wire        prot_palette_ready;
	wire [15:0] prot_palette_dout;
	generate
	if (!HW_ROMS) begin : g_palette_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_palette & prot_cen) begin
				if (~prot_addr[0]) palette[prot_addr[10:1]][15:8] <= prot_wdata;
				else                palette[prot_addr[10:1]][7:0]  <= prot_wdata;
			end else if (sel_palette & cpu_write) begin
				if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
				if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
			end
		end
		always @(*) palette_dout = palette[palette_addr];
		assign palette_ready      = 1'b1;
		assign prot_palette_dout  = palette[prot_addr[10:1]];
		assign prot_palette_ready = 1'b1;
		assign palette_prot_grant = 1'b1;
	end else begin : g_palette_hw
		wire       grant = prot_acc & prot_sel_palette & ~(sel_palette & ~ASn);
		wire [9:0] port_addr = grant ? prot_addr[10:1] : palette_addr;
		reg  [9:0] port_addr_r;
		reg        port_src_r;
		wire       prot_w = grant & prot_wr & ~prot_wr_done;
		always @(posedge clk_sys) begin
			if ((prot_w & ~prot_addr[0]) | (~grant & sel_palette & cpu_write & ~UDSn)) palette[port_addr][15:8] <= prot_w ? prot_wdata : oEdb[15:8];
			if ((prot_w &  prot_addr[0]) | (~grant & sel_palette & cpu_write & ~LDSn)) palette[port_addr][7:0]  <= prot_w ? prot_wdata : oEdb[7:0];
			palette_dout <= palette[port_addr];
			port_addr_r  <= port_addr;
			port_src_r   <= grant;
		end
		assign palette_ready      = ~port_src_r & (port_addr_r == palette_addr);
		assign prot_palette_dout  = palette_dout;
		assign prot_palette_ready = port_src_r & (port_addr_r == prot_addr[10:1]);
		assign palette_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// BG tilemap VRAM (8192 x 16)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port shared port, as mainram above (NMK-10).
	reg [7:0] bgvram_hi [0:8191];
	reg [7:0] bgvram_lo [0:8191];
	wire [12:0] bgvram_addr = byte_addr[13:1];
	reg  [15:0] bgvram_dout;
	wire        bgvram_ready;
	wire        prot_bgvram_ready;
	wire [15:0] prot_bgvram_dout;
	generate
	if (!HW_ROMS) begin : g_bgvram_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_bgvram & prot_cen) begin
				if (~prot_addr[0]) bgvram_hi[prot_addr[13:1]] <= prot_wdata;
				else                bgvram_lo[prot_addr[13:1]] <= prot_wdata;
			end else if (sel_bgvram & cpu_write) begin
				if (~UDSn) bgvram_hi[bgvram_addr] <= oEdb[15:8];
				if (~LDSn) bgvram_lo[bgvram_addr] <= oEdb[7:0];
			end
		end
		always @(*) bgvram_dout = {bgvram_hi[bgvram_addr], bgvram_lo[bgvram_addr]};
		assign bgvram_ready      = 1'b1;
		assign prot_bgvram_dout  = {bgvram_hi[prot_addr[13:1]], bgvram_lo[prot_addr[13:1]]};
		assign prot_bgvram_ready = 1'b1;
		assign bgvram_prot_grant = 1'b1;
	end else begin : g_bgvram_hw
		wire        grant = prot_acc & prot_sel_bgvram & ~(sel_bgvram & ~ASn);
		wire [12:0] port_addr = grant ? prot_addr[13:1] : bgvram_addr;
		reg  [12:0] port_addr_r;
		reg         port_src_r;
		wire        prot_w = grant & prot_wr & ~prot_wr_done;
		wire        we_hi = (prot_w & ~prot_addr[0]) | (~grant & sel_bgvram & cpu_write & ~UDSn);
		wire        we_lo = (prot_w &  prot_addr[0]) | (~grant & sel_bgvram & cpu_write & ~LDSn);
		wire [7:0]  wd_hi = prot_w ? prot_wdata : oEdb[15:8];
		wire [7:0]  wd_lo = prot_w ? prot_wdata : oEdb[7:0];
		always @(posedge clk_sys) begin
			if (we_hi) begin bgvram_hi[port_addr] <= wd_hi; bgvram_dout[15:8] <= wd_hi; end
			else       bgvram_dout[15:8] <= bgvram_hi[port_addr];
			if (we_lo) begin bgvram_lo[port_addr] <= wd_lo; bgvram_dout[7:0]  <= wd_lo; end
			else       bgvram_dout[7:0]  <= bgvram_lo[port_addr];
			port_addr_r <= port_addr;
			port_src_r  <= grant;
		end
		assign bgvram_ready      = ~port_src_r & (port_addr_r == bgvram_addr);
		assign prot_bgvram_dout  = bgvram_dout;
		assign prot_bgvram_ready = port_src_r & (port_addr_r == prot_addr[13:1]);
		assign bgvram_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// TX tilemap VRAM (2048 x 16, mirror bit ignored)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port shared port, as mainram above (NMK-10).
	reg [7:0] txvram_hi [0:2047];
	reg [7:0] txvram_lo [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	reg  [15:0] txvram_dout;
	wire        txvram_ready;
	wire        prot_txvram_ready;
	wire [15:0] prot_txvram_dout;
	generate
	if (!HW_ROMS) begin : g_txvram_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_txvram & prot_cen) begin
				if (~prot_addr[0]) txvram_hi[prot_addr[11:1]] <= prot_wdata;
				else                txvram_lo[prot_addr[11:1]] <= prot_wdata;
			end else if (sel_txvram & cpu_write) begin
				if (~UDSn) txvram_hi[txvram_addr] <= oEdb[15:8];
				if (~LDSn) txvram_lo[txvram_addr] <= oEdb[7:0];
			end
		end
		always @(*) txvram_dout = {txvram_hi[txvram_addr], txvram_lo[txvram_addr]};
		assign txvram_ready      = 1'b1;
		assign prot_txvram_dout  = {txvram_hi[prot_addr[11:1]], txvram_lo[prot_addr[11:1]]};
		assign prot_txvram_ready = 1'b1;
		assign txvram_prot_grant = 1'b1;
	end else begin : g_txvram_hw
		wire        grant = prot_acc & prot_sel_txvram & ~(sel_txvram & ~ASn);
		wire [10:0] port_addr = grant ? prot_addr[11:1] : txvram_addr;
		reg  [10:0] port_addr_r;
		reg         port_src_r;
		wire        prot_w = grant & prot_wr & ~prot_wr_done;
		wire        we_hi = (prot_w & ~prot_addr[0]) | (~grant & sel_txvram & cpu_write & ~UDSn);
		wire        we_lo = (prot_w &  prot_addr[0]) | (~grant & sel_txvram & cpu_write & ~LDSn);
		wire [7:0]  wd_hi = prot_w ? prot_wdata : oEdb[15:8];
		wire [7:0]  wd_lo = prot_w ? prot_wdata : oEdb[7:0];
		always @(posedge clk_sys) begin
			if (we_hi) begin txvram_hi[port_addr] <= wd_hi; txvram_dout[15:8] <= wd_hi; end
			else       txvram_dout[15:8] <= txvram_hi[port_addr];
			if (we_lo) begin txvram_lo[port_addr] <= wd_lo; txvram_dout[7:0]  <= wd_lo; end
			else       txvram_dout[7:0]  <= txvram_lo[port_addr];
			port_addr_r <= port_addr;
			port_src_r  <= grant;
		end
		assign txvram_ready      = ~port_src_r & (port_addr_r == txvram_addr);
		assign prot_txvram_dout  = txvram_dout;
		assign prot_txvram_ready = port_src_r & (port_addr_r == prot_addr[11:1]);
		assign txvram_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// gunnail_scrollram / gunnail_scrollramy (256 x 16 each, write-only
	// for the 68000 — reads fall through to the unmapped 0xFFFF). One
	// 512 x 16 array: [0:255] X table, [256:511] Y table. Word 0 of each
	// is mirrored in a register for the video's scrollram_0/scrollramy_0
	// taps; the rows are read through the video port (registered, two
	// rows on alternate cycles).
	// ------------------------------------------------------------------
	reg [15:0] scrollmem [0:511];
	wire       sel_scrollmem      = sel_scrollram | sel_scrollramy;
	wire       prot_sel_scrollmem = prot_sel_scrollram | prot_sel_scrollramy;
	wire [8:0] scroll_addr_cpu  = {sel_scrollramy, byte_addr[8:1]};
	wire [8:0] scroll_addr_prot = {prot_sel_scrollramy, prot_addr[8:1]};
	reg [15:0] scrollram0_reg, scrollramy0_reg;
	wire [7:0]  vid_scroll_row_addr;
	wire [15:0] vid_scrollram_row, vid_scrollramy_row;
	// Write port: the protection MCU's byte write wins the cycle (it is
	// also the rarer one); the 68000 write is byte-enabled.
	wire        scroll_prot_w = prot_wr & prot_sel_scrollmem & (HW_ROMS ? ~prot_wr_done : prot_cen);
	wire [8:0]  scroll_waddr  = scroll_prot_w ? scroll_addr_prot : scroll_addr_cpu;
	wire        scroll_cpu_w  = sel_scrollmem & cpu_write & ~scroll_prot_w;
	wire        scroll_w_hi   = (scroll_prot_w & ~prot_addr[0]) | (scroll_cpu_w & ~UDSn);
	wire        scroll_w_lo   = (scroll_prot_w &  prot_addr[0]) | (scroll_cpu_w & ~LDSn);
	wire [7:0]  scroll_w_hi_d = scroll_prot_w ? prot_wdata : oEdb[15:8];
	wire [7:0]  scroll_w_lo_d = scroll_prot_w ? prot_wdata : oEdb[7:0];
	always @(posedge clk_sys) begin
		if (reset) begin
			scrollram0_reg  <= 16'h0000;
			scrollramy0_reg <= 16'h0000;
		end else begin
			if (scroll_waddr == 9'd0) begin
				if (scroll_w_hi) scrollram0_reg[15:8] <= scroll_w_hi_d;
				if (scroll_w_lo) scrollram0_reg[7:0]  <= scroll_w_lo_d;
			end
			if (scroll_waddr == 9'd256) begin
				if (scroll_w_hi) scrollramy0_reg[15:8] <= scroll_w_hi_d;
				if (scroll_w_lo) scrollramy0_reg[7:0]  <= scroll_w_lo_d;
			end
		end
	end
	generate
	if (!HW_ROMS) begin : g_scrollmem_sim
		always @(posedge clk_sys) begin
			if (scroll_w_hi) scrollmem[scroll_waddr][15:8] <= scroll_w_hi_d;
			if (scroll_w_lo) scrollmem[scroll_waddr][7:0]  <= scroll_w_lo_d;
		end
		assign vid_scrollram_row  = scrollmem[{1'b0, vid_scroll_row_addr}];
		assign vid_scrollramy_row = scrollmem[{1'b1, vid_scroll_row_addr}];
	end else begin : g_scrollmem_hw
		reg        vid_scroll_phase = 1'b0, vid_scroll_phase_d;
		reg [15:0] vid_scroll_q, vid_scrollram_row_r, vid_scrollramy_row_r;
		always @(posedge clk_sys) begin
			if (scroll_w_hi) scrollmem[scroll_waddr][15:8] <= scroll_w_hi_d;
			if (scroll_w_lo) scrollmem[scroll_waddr][7:0]  <= scroll_w_lo_d;
			vid_scroll_phase   <= ~vid_scroll_phase;
			vid_scroll_phase_d <= vid_scroll_phase;
			vid_scroll_q       <= scrollmem[{vid_scroll_phase, vid_scroll_row_addr}];
			if (vid_scroll_phase_d) vid_scrollramy_row_r <= vid_scroll_q;
			else                    vid_scrollram_row_r  <= vid_scroll_q;
		end
		assign vid_scrollram_row  = vid_scrollram_row_r;
		assign vid_scrollramy_row = vid_scrollramy_row_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Dual-port video read taps
	// ------------------------------------------------------------------
	wire [14:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout;
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout;
	wire [9:0]  vid_palette_addr;
	wire [15:0] vid_palette_dout;
	wire [9:0]  vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout;
	generate
	if (!HW_ROMS) begin : g_vidpal_sim
		assign vid_palette_dout     = palette[vid_palette_addr];
		assign vid_spr_palette_dout = palette[vid_spr_palette_addr];
	end else begin : g_vidpal_hw
		// Registered reads — video_macross2.sv's HW_ROMS=1 palette-tap
		// contract (one clock behind the address), so the palette infers
		// as block RAM on every port (NMK-10; the CPU/MCU port above
		// already was).
		reg [15:0] vid_palette_dout_r, vid_spr_palette_dout_r;
		always @(posedge clk_sys) begin
			vid_palette_dout_r     <= palette[vid_palette_addr];
			vid_spr_palette_dout_r <= palette[vid_spr_palette_addr];
		end
		assign vid_palette_dout     = vid_palette_dout_r;
		assign vid_spr_palette_dout = vid_spr_palette_dout_r;
	end
	endgenerate
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout;
	wire        vid_mainram_ready;
	generate
	if (!HW_ROMS) begin : g_vidram_read_sim
		assign vid_bgvram_dout  = {bgvram_hi[vid_bgvram_addr[12:0]], bgvram_lo[vid_bgvram_addr[12:0]]};
		assign vid_txvram_dout  = {txvram_hi[vid_txvram_addr],       txvram_lo[vid_txvram_addr]};
		assign vid_mainram_dout = {mainram_hi[vid_mainram_addr],     mainram_lo[vid_mainram_addr]};
		assign vid_mainram_ready = 1'b1;
	end else begin : g_vidram_read_hw
		reg [15:0] vid_bgvram_dout_r, vid_txvram_dout_r, vid_mainram_dout_r;
		reg [14:0] vid_mainram_addr_r;
		always @(posedge clk_sys) begin
			vid_bgvram_dout_r  <= {bgvram_hi[vid_bgvram_addr[12:0]], bgvram_lo[vid_bgvram_addr[12:0]]};
			vid_txvram_dout_r  <= {txvram_hi[vid_txvram_addr],       txvram_lo[vid_txvram_addr]};
			vid_mainram_dout_r <= {mainram_hi[vid_mainram_addr],     mainram_lo[vid_mainram_addr]};
			vid_mainram_addr_r <= vid_mainram_addr;
		end
		assign vid_bgvram_dout   = vid_bgvram_dout_r;
		assign vid_txvram_dout   = vid_txvram_dout_r;
		assign vid_mainram_dout  = vid_mainram_dout_r;
		assign vid_mainram_ready = (vid_mainram_addr_r == vid_mainram_addr);
	end
	endgenerate

	generate
	if (!HW_ROMS) begin : g_dbgram_sim
		assign dbg_pal_data = palette[dbg_pal_addr];
		assign dbg_bgvram_data = {bgvram_hi[dbg_bgvram_addr[12:0]], bgvram_lo[dbg_bgvram_addr[12:0]]};
		assign dbg_txvram_data = {txvram_hi[dbg_txvram_addr], txvram_lo[dbg_txvram_addr]};
	end else begin : g_dbgram_hw
		assign dbg_pal_data = 16'd0;
		assign dbg_bgvram_data = 16'd0;
		assign dbg_txvram_data = 16'd0;
	end
	endgenerate

	// ------------------------------------------------------------------
	// I/O registers — protection MCU write wins a same-cycle conflict.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg        nmi_level;
	wire       prot_reg_w = prot_wr & (HW_ROMS ? ~prot_wr_done : prot_cen);
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			nmi_level       <= 1'b0;
		end else begin
			if (prot_reg_w & prot_sel_flip)           flip_screen_reg <= prot_wdata;
			else if (sel_flip & cpu_write & ~LDSn)     flip_screen_reg <= oEdb[7:0];

			if (prot_reg_w & prot_sel_tilebank)       bgbank_reg <= prot_wdata;
			else if (sel_tilebank & cpu_write & ~LDSn) bgbank_reg <= oEdb[7:0];

			if (prot_reg_w & prot_sel_nmi)            nmi_level <= prot_wdata[0];
			else if (sel_nmi & cpu_write)              nmi_level <= oEdb[0];
		end
	end

	// ------------------------------------------------------------------
	// NMK004 host latches (nmk004_device::read/write)
	// ------------------------------------------------------------------
	wire [7:0] nmk004_mcu_to_host;
	wire       nmk004_mcu_to_host_we;
	reg  [7:0] nmk004_host_to_mcu = 8'hFF;
	wire       host_cmd_we = (prot_reg_w & prot_sel_nmk004_w) | (cpu_write & sel_nmk004_w & ~LDSn);
	wire [7:0] host_cmd    = (prot_reg_w & prot_sel_nmk004_w) ? prot_wdata : oEdb[7:0];
	always @(posedge clk_sys) if (host_cmd_we) nmk004_host_to_mcu <= host_cmd;
	assign dbg_host_cmd_we = host_cmd_we;
	assign dbg_host_cmd    = host_cmd;

	reg [7:0] nmk004_to_host_latch = 8'hFF;
	always @(posedge clk_sys) if (nmk004_mcu_to_host_we & snd_cen) nmk004_to_host_latch <= nmk004_mcu_to_host;
	assign dbg_mcu_reply_we = nmk004_mcu_to_host_we & snd_cen;
	assign dbg_mcu_reply    = nmk004_mcu_to_host;

	// ------------------------------------------------------------------
	// NMK004 sound MCU — nmk004_core.sv on clk_sys + snd_cen. Program
	// ROM: $readmemh at HW_ROMS=0; at HW_ROMS=1 one oki_rom_cache over
	// SDRAM port 1 serving both the boot ROM and the external program
	// (see the layout in the header), with the cen withheld on a miss.
	// ------------------------------------------------------------------
	wire       ym_cs, ym_we, ym_addr_sel;
	wire [7:0] ym_dout;
	wire       oki0_cs, oki0_we, oki1_cs, oki1_we;
	wire [7:0] oki0_dout, oki1_dout;
	wire       oki0_bank_we, oki1_bank_we;
	wire [7:0] oki0_bank, oki1_bank;

	wire [15:0] nmk004_rom_addr;
	wire        nmk004_rom_rd;
	wire [7:0]  nmk004_rom_din;
	wire        nmk004_rom_ready;
	// boot ROM 0x0000-0x1FFF lives at BASE_BYTE_NMK004_BOOT = ext base +
	// 0x10000, so relative to BASE_WORD_NMK004: boot at byte 0x10000+a,
	// program at byte a.
	wire [21:0] nmk004_cache_addr = (nmk004_rom_addr < 16'h2000) ? {5'd0, 1'b1, nmk004_rom_addr} : {6'd0, nmk004_rom_addr};

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	wire [7:0] oki1_chip_dout, oki2_chip_dout;

	nmk004_core #(
		.BOOT_ROM_FILE(NMK004_BOOT_FILE),
		.EXT_ROM_FILE(NMK004_EXT_FILE),
		.USE_CEN(1),
		.ROM_EXTERNAL(HW_ROMS)
	) nmk004 (
		.clk(clk_sys), .cen(snd_cen), .reset(reset),
		.rom_addr(nmk004_rom_addr), .rom_rd(nmk004_rom_rd), .rom_din(nmk004_rom_din), .rom_ready(nmk004_rom_ready), .rom_stall(nmk004_rom_stall),
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
		.dbg_de(dbg_nmk004_de), .dbg_bc(dbg_nmk004_bc), .dbg_ix(dbg_nmk004_ix),
		.dbg_iy(dbg_nmk004_iy), .dbg_sp(dbg_nmk004_sp),
		.p4(nmk004_p4), .bx(), .by()
	);
	assign dbg_nmk004_cen   = snd_cen;
	assign dbg_nmk004_stall = snd_stall;

	// SDRAM port 1, four channels: NMK004 ROM, OKI0, OKI1, protection ROM.
	wire        p1_busy [0:4];
	wire        p1_valid[0:4];
	wire [24:1] p1_addr [0:4];
	wire        p1_req  [0:4];
	wire [15:0] p1_dout [0:4];
	wire [31:0] p1_dout_pair [0:4];
	wire [7:0]  prot_rom_din;
	wire        prot_rom_ready;
	generate
	if (!HW_ROMS) begin : g_p1_sim
		assign nmk004_rom_din   = 8'h00;
		assign nmk004_rom_ready = 1'b1;
		assign prot_rom_din     = 8'h00;
		assign prot_rom_ready   = 1'b1;
		assign sd3_addr = 24'd0; assign sd3_req = 1'b0;
		assign p1_busy  = '{1'b0, 1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_valid = '{1'b0, 1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_dout  = '{16'd0, 16'd0, 16'd0, 16'd0, 16'd0};
		assign p1_dout_pair = '{32'd0, 32'd0, 32'd0, 32'd0, 32'd0};
		// channel 0 (TX prefetch) is driven by the video module's txc_* outputs
		assign p1_addr[1] = 24'd0; assign p1_addr[2] = 24'd0; assign p1_addr[3] = 24'd0; assign p1_addr[4] = 24'd0;
		// channel 0 (TX prefetch) is driven by the video module's txc_* outputs
		assign p1_req[1] = 1'b0; assign p1_req[2] = 1'b0; assign p1_req[3] = 1'b0; assign p1_req[4] = 1'b0;
	end else begin : g_p1_hw
		// Physical port 3: channel 0 is the video module's TX prefetch
		// stream (top priority, it is real-time), the sound consumers
		// follow. The sprite fetch has physical port 1 to itself (video
		// sd_b_*) — see video_macross2.sv TX_EXTERNAL.
		sdram_arb #(.N(5), .FIXED_PRIO(1)) p1_arb_inst (
			.clk(clk_sys), .reset(por_rst),
			.i_addr(p1_addr), .i_we('{1'b0, 1'b0, 1'b0, 1'b0, 1'b0}), .i_wrl('{1'b0, 1'b0, 1'b0, 1'b0, 1'b0}), .i_wrh('{1'b0, 1'b0, 1'b0, 1'b0, 1'b0}), .i_din('{16'd0, 16'd0, 16'd0, 16'd0, 16'd0}),
			.i_req(p1_req), .i_busy(p1_busy), .i_valid(p1_valid), .i_dout(p1_dout), .i_dout_pair(p1_dout_pair),
			.sdram_addr(sd3_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
			.sdram_dout(sd3_dout), .sdram_dout_pair(sd3_dout_pair), .sdram_req(sd3_req), .sdram_ack(sd3_ack)
		);
		oki_rom_cache #(.BASE_WORD_OFFSET(BASE_WORD_NMK004)) nmk004_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr(nmk004_cache_addr), .data(nmk004_rom_din), .ready(nmk004_rom_ready), .stall(),
			.sd_addr(p1_addr[1]), .sd_req(p1_req[1]), .sd_busy(p1_busy[1]), .sd_valid(p1_valid[1]), .sd_dout(p1_dout[1]), .sd_dout_pair(p1_dout_pair[1])
		);
		// Protection MCU reads of the 68000 ROM (none in this game's
		// firmware, wired for completeness): its own 1-line byte cache.
		rom_cache1_byte #(.BASE_WORD_OFFSET(23'd0)) prot_rom_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({5'd0, prot_addr[18:0]}), .data(prot_rom_din), .word(), .ready(prot_rom_ready),
			.sd_addr(p1_addr[4]), .sd_req(p1_req[4]), .sd_busy(p1_busy[4]), .sd_valid(p1_valid[4]), .sd_dout(p1_dout[4]), .sd_dout_pair(p1_dout_pair[4])
		);
	end
	endgenerate

	// ------------------------------------------------------------------
	// YM2203 — jt03, 40-cycle write stretch from the NMK004's write strobe.
	// ------------------------------------------------------------------
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
	// Live port decode for reads (status polls), the latch only while a
	// write stretch is in flight — see tdragon2_core.sv.
	wire ym_addr_eff = (ym_wr_hold != 6'd0) ? ym_addr_latch : ym_addr_sel;

	wire signed [15:0] ym_snd;
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_eff), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(dbg_fm_snd), .psg_snd(dbg_psg_snd), .snd(ym_snd), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, NMK004-driven banking: 0x00000-0x1FFFF fixed,
	// 0x20000-0x3FFFF = bank (n+1) x 0x20000 of the 0x80000 ROM
	// (oki1_map/oki2_map + nmk004_device's okibank entries).
	// ------------------------------------------------------------------
	reg [1:0] oki1_bank_r = 2'd0, oki2_bank_r = 2'd0;
	always @(posedge clk_sys) begin
		if (oki0_bank_we & snd_cen) oki1_bank_r <= oki0_bank[1:0];
		if (oki1_bank_we & snd_cen) oki2_bank_r <= oki1_bank[1:0];
	end

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

	wire [7:0] oki1_rom_data, oki2_rom_data;
	wire       oki1_rom_ok, oki2_rom_ok;
	wire       oki1_stall, oki2_stall;
	generate
	if (!HW_ROMS) begin : g_oki_sim
		reg [7:0] oki1_rom [0:524287];
		reg [7:0] oki2_rom [0:524287];
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki1_rom);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki2_rom);
		reg [7:0] oki1_rom_data_r, oki2_rom_data_r;
		always @(posedge clk_sys) oki1_rom_data_r <= oki1_rom[oki1_phys];
		always @(posedge clk_sys) oki2_rom_data_r <= oki2_rom[oki2_phys];
		assign oki1_rom_data = oki1_rom_data_r;
		assign oki2_rom_data = oki2_rom_data_r;
		assign oki1_rom_ok = 1'b1;
		assign oki2_rom_ok = 1'b1;
		assign oki1_stall = 1'b0;
		assign oki2_stall = 1'b0;
		assign dbg_oki0_adpcm_total = 32'd0; assign dbg_oki0_adpcm_unserved = 32'd0;
		assign dbg_oki1_adpcm_total = 32'd0; assign dbg_oki1_adpcm_unserved = 32'd0;
		assign dbg_oki_cen_total = 32'd0; assign dbg_oki0_stall_cen = 32'd0; assign dbg_oki1_stall_cen = 32'd0;
	end else begin : g_oki_hw
		oki_rom_cache #(.BASE_WORD_OFFSET(BASE_WORD_OKI1)) oki1_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({3'd0, oki1_phys}), .data(oki1_rom_data), .ready(oki1_rom_ok), .stall(oki1_stall),
			.sd_addr(p1_addr[2]), .sd_req(p1_req[2]), .sd_busy(p1_busy[2]), .sd_valid(p1_valid[2]), .sd_dout(p1_dout[2]), .sd_dout_pair(p1_dout_pair[2])
		);
		oki_rom_cache #(.BASE_WORD_OFFSET(BASE_WORD_OKI2)) oki2_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({3'd0, oki2_phys}), .data(oki2_rom_data), .ready(oki2_rom_ok), .stall(oki2_stall),
			.sd_addr(p1_addr[3]), .sd_req(p1_req[3]), .sd_busy(p1_busy[3]), .sd_valid(p1_valid[3]), .sd_dout(p1_dout[3]), .sd_dout_pair(p1_dout_pair[3])
		);
`ifdef VERILATOR
		reg [31:0] oki0_adpcm_total_r = 32'd0, oki0_adpcm_unserved_r = 32'd0;
		reg [31:0] oki1_adpcm_total_r = 32'd0, oki1_adpcm_unserved_r = 32'd0;
		reg [31:0] oki_cen_total_r = 32'd0, oki0_stall_cen_r = 32'd0, oki1_stall_cen_r = 32'd0;
		reg [7:0] golden0 [0:524287];
		reg [7:0] golden1 [0:524287];
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, golden0);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, golden1);
		reg [31:0] oki0_bytes_wrong = 32'd0, oki1_bytes_wrong = 32'd0, oki0_bytes_checked = 32'd0, oki1_bytes_checked = 32'd0;
		always @(posedge clk_sys) begin
			if (oki_cen) begin
				oki_cen_total_r <= oki_cen_total_r + 32'd1;
				if (oki1_stall) oki0_stall_cen_r <= oki0_stall_cen_r + 32'd1;
				if (oki2_stall) oki1_stall_cen_r <= oki1_stall_cen_r + 32'd1;
			end
			if (oki1_chip.u_rom.st == 8'h02 && oki1_chip.u_rom.cen32) begin
				oki0_adpcm_total_r <= oki0_adpcm_total_r + 32'd1;
				if (!oki1_rom_ok) oki0_adpcm_unserved_r <= oki0_adpcm_unserved_r + 32'd1;
				if (OKI1_ROM_FILE != "") begin
					oki0_bytes_checked <= oki0_bytes_checked + 32'd1;
					if (oki1_rom_data != golden0[oki1_phys]) oki0_bytes_wrong <= oki0_bytes_wrong + 32'd1;
				end
			end
			if (oki2_chip.u_rom.st == 8'h02 && oki2_chip.u_rom.cen32) begin
				oki1_adpcm_total_r <= oki1_adpcm_total_r + 32'd1;
				if (!oki2_rom_ok) oki1_adpcm_unserved_r <= oki1_adpcm_unserved_r + 32'd1;
				if (OKI2_ROM_FILE != "") begin
					oki1_bytes_checked <= oki1_bytes_checked + 32'd1;
					if (oki2_rom_data != golden1[oki2_phys]) oki1_bytes_wrong <= oki1_bytes_wrong + 32'd1;
				end
			end
		end
		final $display("OKI golden-byte audit: oki0 %0d latches / %0d wrong, oki1 %0d latches / %0d wrong",
			oki0_bytes_checked, oki0_bytes_wrong, oki1_bytes_checked, oki1_bytes_wrong);
		assign dbg_oki0_adpcm_total = oki0_adpcm_total_r; assign dbg_oki0_adpcm_unserved = oki0_adpcm_unserved_r;
		assign dbg_oki1_adpcm_total = oki1_adpcm_total_r; assign dbg_oki1_adpcm_unserved = oki1_adpcm_unserved_r;
		assign dbg_oki_cen_total = oki_cen_total_r; assign dbg_oki0_stall_cen = oki0_stall_cen_r; assign dbg_oki1_stall_cen = oki1_stall_cen_r;
`else
		assign dbg_oki0_adpcm_total = 32'd0; assign dbg_oki0_adpcm_unserved = 32'd0;
		assign dbg_oki1_adpcm_total = 32'd0; assign dbg_oki1_adpcm_unserved = 32'd0;
		assign dbg_oki_cen_total = 32'd0; assign dbg_oki0_stall_cen = 32'd0; assign dbg_oki1_stall_cen = 32'd0;
`endif
	end
	endgenerate

`ifdef VERILATOR
	reg [31:0] snd_cen_total_r = 32'd0, snd_stall_total_r = 32'd0;
	always @(posedge clk_sys) if (snd_div == 3'd4) begin
		if (snd_stall) snd_stall_total_r <= snd_stall_total_r + 32'd1;
		else           snd_cen_total_r   <= snd_cen_total_r + 32'd1;
	end
	assign dbg_nmk004_cen_total   = snd_cen_total_r;
	assign dbg_nmk004_stall_total = snd_stall_total_r;
`else
	assign dbg_nmk004_cen_total   = 32'd0;
	assign dbg_nmk004_stall_total = 32'd0;
`endif

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

	wire signed [13:0] oki1_snd, oki2_snd;
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki1_stall), .ss(1'b0),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr), .rom_data(oki1_rom_data), .rom_ok(oki1_rom_ok),
		.sound(oki1_snd), .sample()
	);
	jt6295 oki2_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki2_stall), .ss(1'b0),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki2_chip_dout),
		.rom_addr(oki2_rom_addr), .rom_data(oki2_rom_data), .rom_ok(oki2_rom_ok),
		.sound(oki2_snd), .sample()
	);

	// Audio mix — same routes as tdragon2/raphero (FM 1.20, PSG 0.50 x3,
	// each OKI 0.10): jt03's mixed snd + each OKI x 3/8, saturated.
	wire signed [17:0] oki0_ext = {{4{oki1_snd[13]}}, oki1_snd};
	wire signed [17:0] oki1_ext = {{4{oki2_snd[13]}}, oki2_snd};
	wire signed [17:0] oki0_g   = oki0_ext + (oki0_ext >>> 1); // x 3/2 (was 3/8 -- measured 8-13dB quiet vs MAME's real OKI:FM balance)
	wire signed [17:0] oki1_g   = oki1_ext + (oki1_ext >>> 1);
	wire signed [17:0] audio_sum = {{2{ym_snd[15]}}, ym_snd} + oki0_g + oki1_g;
	wire signed [15:0] audio_mix =
		(audio_sum > 18'sd32767)  ? 16'sd32767  :
		(audio_sum < -18'sd32768) ? -16'sd32768 :
		audio_sum[15:0];
	assign audio_l = audio_mix;
	assign audio_r = audio_mix;
	assign dbg_oki0_snd = oki1_snd;
	assign dbg_oki1_snd = oki2_snd;

	// ------------------------------------------------------------------
	// Protection MCU (NMK-215/TMP90840) — nmk_prot_core.sv on clk_sys +
	// prot_cen. Boot ROM: $readmemh at HW_ROMS=0; at HW_ROMS=1 written
	// into its on-chip array from the ioctl stream (the 8 KB at
	// BASE_BYTE_PROT) while the core is in reset.
	// ------------------------------------------------------------------
	wire nmk214_cfg_we;
	wire [7:0] nmk214_cfg_data;
	assign dbg_nmk214_cfg_we   = nmk214_cfg_we;
	assign dbg_nmk214_cfg_data = nmk214_cfg_data;

	wire prot_rom_we = HW_ROMS && ioctl_rom_wr && ioctl_wr && (ioctl_addr[24:13] == {1'b0, BASE_BYTE_PROT[23:13]});
	wire [13:0] prot_rom_waddr = {1'b0, ioctl_addr[12:0]}; // offset within the 8 KB region

	wire [9:0] vt_hcount, vt_vcount;
	nmk_prot_core #(
		.BOOT_ROM_FILE(PROT_BOOT_FILE),
		.ROM_SIZE(8192), .RAM_BASE(16'hfec0), .RAM_SIZE(256),
		.USE_CEN(1)
	) prot_mcu (
		.clk(clk_sys), .cen(prot_cen), .reset(reset),
		.rom_we(prot_rom_we), .rom_waddr(prot_rom_waddr), .rom_wdata(ioctl_dout),
		.bus_addr(prot_addr), .bus_rd(prot_rd), .bus_wr(prot_wr),
		.bus_wdata(prot_wdata), .bus_rdata(prot_rdata),
		.vpos_div4(vt_vcount[9:2]),
		.halt_68k(halt_68k),
		.nmk214_cfg_we(nmk214_cfg_we), .nmk214_cfg_data(nmk214_cfg_data),
		.dbg_pc(dbg_prot_pc), .dbg_valid(dbg_prot_valid),
		.dbg_hl(dbg_prot_hl), .dbg_a(dbg_prot_a), .dbg_de(dbg_prot_de), .dbg_iy(dbg_prot_iy),
		.dbg_int_ram_at_hl(dbg_prot_int_ram_at_hl)
	);

	// Shared-bus read mux (byte) and the ready/stall logic.
	reg [15:0] prot_rdata16;
	always @(*) begin
		if (prot_sel_rom)          prot_rdata16 = prot_rom_word;
		else if (prot_sel_mainram) prot_rdata16 = prot_mainram_dout;
		else if (prot_sel_palette) prot_rdata16 = prot_palette_dout;
		else if (prot_sel_bgvram)  prot_rdata16 = prot_bgvram_dout;
		else if (prot_sel_txvram)  prot_rdata16 = prot_txvram_dout;
		else if (prot_sel_nmk004_r) prot_rdata16 = {8'h00, nmk004_to_host_latch};
		else if (prot_sel_in0)     prot_rdata16 = HW_ROMS ? in0_i  : 16'hFFFF;
		else if (prot_sel_in1)     prot_rdata16 = HW_ROMS ? in1_i  : 16'hFFFF;
		else if (prot_sel_dsw1)    prot_rdata16 = HW_ROMS ? dsw1_i : 16'hFFFF;
		else if (prot_sel_dsw2)    prot_rdata16 = HW_ROMS ? dsw2_i : 16'hFFFF;
		else                       prot_rdata16 = 16'hFFFF;
	end
	assign prot_rdata = prot_addr[0] ? prot_rdata16[7:0] : prot_rdata16[15:8];

	wire prot_rd_ready =
		prot_sel_rom     ? prot_rom_ready :
		prot_sel_mainram ? prot_mainram_ready :
		prot_sel_palette ? prot_palette_ready :
		prot_sel_bgvram  ? prot_bgvram_ready :
		prot_sel_txvram  ? prot_txvram_ready : 1'b1;
	// A write is "done" once the granted RAM-port write (or a register
	// write, always granted) has happened in this CPU cycle.
	wire prot_wr_granted_now =
		prot_sel_mainram ? mainram_prot_grant :
		prot_sel_palette ? palette_prot_grant :
		prot_sel_bgvram  ? bgvram_prot_grant :
		prot_sel_txvram  ? txvram_prot_grant : 1'b1;
	always @(posedge clk_sys) begin
		if (reset | prot_cen) prot_wr_done <= 1'b0;
		else if (prot_wr & prot_wr_granted_now) prot_wr_done <= 1'b1;
	end
	assign prot_stall = HW_ROMS ? ((prot_rd & ~prot_rd_ready) | (prot_wr & ~prot_wr_done & ~prot_wr_granted_now)) : 1'b0;

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
		else if (sel_nmk004_r) rdata = {8'h00, nmk004_to_host_latch};
		else if (sel_in0)     rdata = HW_ROMS ? in0_i  : 16'hFFFF;
		else if (sel_in1)     rdata = HW_ROMS ? in1_i  : 16'hFFFF;
		else if (sel_dsw1)    rdata = HW_ROMS ? dsw1_i : 16'hFFFF;
		else if (sel_dsw2)    rdata = HW_ROMS ? dsw2_i : 16'hFFFF;
		else                  rdata = 16'hFFFF; // unmapped (incl. the write-only scroll tables)
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + V-PROM interrupt generation
	// ------------------------------------------------------------------
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);
	assign dbg_vt_vcount = vt_vcount;
	assign ce_pix_o = ce_pix;
	assign hcount_o = vt_hcount;
	assign vcount_o = vt_vcount;
	assign hblank_o = vt_hblank;
	assign vblank_o = vt_vblank;

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
	// Video — video_macross2.sv, gfx_macross parameters + per-line scroll
	// + NMK214 descramble.
	// ------------------------------------------------------------------
	video_macross2 #(
		.TX_EXTERNAL(1),
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.SPRITES_FILE(SPRITES_FILE),
		.HW_ROMS(HW_ROMS),
		.DBG_MISS_PAINT(DBG_MISS_PAINT),
		.BASE_WORD_FGTILE(BASE_WORD_FGTILE),
		.BASE_WORD_BGTILE(BASE_WORD_BGTILE),
		.BASE_WORD_SPRITES(BASE_WORD_SPRITES),
		.RASTER_SCROLL(1),
		.SPRITES_BYTES(2097152),
		.SPR_COLOUR_BITS(4),
		.TX_PAL_BASE_P(10'h200),
		.BG_CODE_BITS(13),
		.NMK214(1)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.sprite_dma_trigger(sprite_dma_trigger), .sprite_dma_busy(sprite_dma_busy),
		.bgvram_addr(vid_bgvram_addr), .bgvram_data(vid_bgvram_dout),
		.txvram_addr(vid_txvram_addr), .txvram_data(vid_txvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout), .mainram_ready(vid_mainram_ready),
		.bg_xscroll(16'd0), .bg_yscroll(16'd0),
		.scrollram_0(scrollram0_reg), .scrollramy_0(scrollramy0_reg),
		.scroll_row_addr(vid_scroll_row_addr),
		.scrollram_row(vid_scrollram_row), .scrollramy_row(vid_scrollramy_row),
		.nmk214_cfg_we(nmk214_cfg_we), .nmk214_cfg_data(nmk214_cfg_data),
		.bg_bank(bgbank_reg),
		.tilerambank(2'd0),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb),
		.sd_addr(sd2_addr), .sd_wrl(sd2_wrl), .sd_wrh(sd2_wrh), .sd_din(sd2_din),
		.sd_dout(sd2_dout), .sd_dout_pair(sd2_dout_pair), .sd_req(sd2_req), .sd_ack(sd2_ack),
		.sd_b_addr(sd1_addr), .sd_b_req(sd1_req), .sd_b_dout(sd1_dout), .sd_b_dout_pair(sd1_dout_pair), .sd_b_ack(sd1_ack),
		.txc_addr(p1_addr[0]), .txc_req(p1_req[0]), .txc_busy(p1_busy[0]), .txc_valid(p1_valid[0]), .txc_dout(p1_dout[0]), .txc_dout_pair(p1_dout_pair[0])
	);

	reg frame_done_r;
	always @(posedge clk_sys) frame_done_r <= vt_line_start && (vt_vcount == 10'd0);
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
	assign dbg_ym_we = ym_we;
	assign dbg_ym_cs = ym_cs;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_chip_irq_n = ym_chip_irq_n;
	assign dbg_ym_wdata = ym_dout;
	assign dbg_ym_waddr = ym_addr_sel;
	assign dbg_oki0_we = oki0_we;
	assign dbg_oki0_cs = oki0_cs;
	assign dbg_oki0_chip_dout = oki1_chip_dout;
	assign dbg_oki1_we = oki1_we;
	assign dbg_oki1_cs = oki1_cs;
	assign dbg_oki1_chip_dout = oki2_chip_dout;

endmodule
