// NMK16 MiSTerFPGA project — Rapid Hero / Arcadia (raphero, arcadian,
// rapheroa: one machine config, nmk16.cpp raphero()) system-level
// integration, hardware-ready. Built on rtl/tdragon2/tdragon2_core.sv's
// hardware path (HW_ROMS=1: every ROM through rom caches over the real
// rtl/sdram.sv, loaded by ioctl_download; registered on-chip RAMs for
// block-RAM inference; sprite-DMA CPU stall; audio mix; real inputs) and
// rtl/macross2/video_macross2.sv with RASTER_SCROLL=1 and a 6 MB sprite
// ROM. See docs/hw-bringup.md.
//
// What differs from tdragon2/macross2 (cross-checked against nmk16.cpp):
//
//   - 68000 at 14 MHz (raphero(): XTAL(14'000'000)), not 10 MHz — a 7/20
//     phase accumulator from the 40 MHz clk_sys drives enPhi1/enPhi2.
//   - Sound CPU is a TMP90841 (TLCS-90, rtl/tlcs90/tlcs90.sv +
//     nmk004_periph.sv) at 8 MHz, memory-mapped (raphero_sound_mem_map),
//     not a Z80 with I/O ports. It has no WAIT pin: on the hardware path
//     its 8 MHz clock enable is withheld while a program-ROM fetch is
//     outstanding (oki_rom_cache: 16 four-byte lines + next-line
//     prefetch, so sequential code mostly hits). 0x100016 is nopw() —
//     the 68000 cannot reset the sound CPU (macross2's own
//     sound_reset_w has no counterpart here).
//   - Per-scanline X+Y background scroll: gunnail_scrollram/scrollramy
//     at 0x130000/0x130200 (256 words each), raphero_scroll_w deriving
//     tilerambank from bits [13:12] of scrollram[0] (nmk16_v.cpp:295-311),
//     applied per bitmap line by bg_update() — served to
//     video_macross2.sv's RASTER_SCROLL taps (see its header).
//   - Sprite ROM is 0x600000 (3 files); both OKI ROMs are 0x400000
//     (NMK112 masks 63). oki1 = rhp94099.6+7, oki2 = rhp94099.5+6 —
//     rhp94099.6 is the same file in both, so the SDRAM image holds
//     .5,.6,.7 once, contiguously, and the two 4 MB regions overlap
//     (oki2 at BASE_BYTE_OKI2, oki1 2 MB above it). That keeps the
//     whole image inside the 16 MB the 23-bit rom-cache word addresses
//     reach (17.5 MB otherwise).
//   - Main RAM has tdragon2's own address-line swap (mainram_swapped_r/w,
//     word-address bits 7 and 10 exchanged); the sprite-DMA tap stays
//     unswapped (sprite_dma() memcpys the raw array).
//   - Same V-PROM as tdragon2/macross2 (prom2.u53, CRC e6ead349).
//
// SDRAM layout (bytes; word offset = byte offset / 2), see BASE_BYTE_*:
//   0x000000 maincpu  0x080000 (ROM_LOAD16_WORD_SWAP, rebuilt by byte parity)
//   0x080000 audiocpu 0x020000
//   0x0A0000 fgtile   0x020000
//   0x0C0000 bgtile   0x200000
//   0x2C0000 sprites  0x600000 (3 files, ROM_LOAD16_WORD_SWAP)
//   0x8C0000 rhp94099.5 / oki2 base
//   0xAC0000 rhp94099.6 / oki1 base (oki2's upper half)
//   0xCC0000 rhp94099.7 (oki1's upper half), image ends 0xEC0000
module raphero_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI1_ROM_FILE  = "",
	parameter OKI2_ROM_FILE  = "",
	parameter VTIMING_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = "",
	// See docs/hw-bringup.md. HW_ROMS=0 (default, the reference sim):
	// $readmemh 0-latency arrays. HW_ROMS=1 (Raphero.sv and the
	// raphero_hw sim): every ROM region reads through a cache over the
	// real rtl/sdram.sv controller, loaded via ioctl_download.
	parameter HW_ROMS        = 0,
	// DIAGNOSTIC passthrough to video_macross2.sv — see its own comment.
	parameter DBG_MISS_PAINT = 0,
	// 68000 clock-enable ratio: clk_sys * INC / MOD (7/20 = 14 MHz).
	parameter integer CPU_CEN_INC = 7,
	parameter integer CPU_CEN_MOD = 20
) (
	input clk_sys,        // 40 MHz (68000 bus clk_sys*7/20 = 14 MHz; pixel clk_sys/5 = 8 MHz)
	input reset,          // async, active high

	// Hardware-mode-only ports (HW_ROMS=1) — unused at HW_ROMS=0, see
	// tdragon2_core.sv's own port comments for the ioctl_index gate and
	// the ioctl_wait backpressure.
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
	// SDRAM port 1: sound-CPU program ROM + OKI0/OKI1 sample reads,
	// 3-way arbitrated internally.
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

	output [15:0] dbg_snd_pc,
	output        dbg_snd_valid,
	output        dbg_snd_cen,     // one pulse per sound-CPU clock actually delivered
	output        dbg_snd_stall,   // HW path: sound CPU held for a ROM fetch

	output        dbg_ym_we,
	// per-source audio taps (sim level checks against MAME's routes)
	output signed [15:0] dbg_fm_snd,
	output        [9:0]  dbg_psg_snd,
	output signed [13:0] dbg_oki0_snd,
	output signed [13:0] dbg_oki1_snd,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_irq_n,

	output        dbg_oki0_we,
	output        dbg_oki1_we,
	output  [7:0] dbg_oki0_chip_dout,
	output  [7:0] dbg_oki1_chip_dout,
	// Simulation-only (Verilator) OKI sample-fetch audit — see g_oki_hw.
	output [31:0] dbg_oki0_adpcm_total,
	output [31:0] dbg_oki0_adpcm_unserved,
	output [31:0] dbg_oki1_adpcm_total,
	output [31:0] dbg_oki1_adpcm_unserved,
	output [31:0] dbg_oki_cen_total,
	output [31:0] dbg_oki0_stall_cen,
	output [31:0] dbg_oki1_stall_cen,
	// Simulation-only: sound-CPU clock pulses delivered / withheld.
	output [31:0] dbg_snd_cen_total,
	output [31:0] dbg_snd_stall_total,

	// pixel readback (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [14:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done,

	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	// Real raster timing for the hardware top's sync generation.
	output        ce_pix_o,
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,
	output        hblank_o,
	output        vblank_o,

	// Real inputs (HW_ROMS=1 only; the sim path reads 0xFFFF = idle).
	// Same IN0/IN1 layout as tdragon2 (INPUT_PORTS_START(raphero)).
	input  [15:0] in0_i,
	input  [15:0] in1_i,
	input  [15:0] dsw1_i,
	input  [15:0] dsw2_i,

	// Hold por_rst's countdown while the PLL is not locked — see
	// tdragon2_core.sv's own por_rst comment.
	input extra_por_hold
);

	// ------------------------------------------------------------------
	// Power-on-only reset for the SDRAM req/arb instances — see
	// tdragon2_core.sv: the game `reset` is held for the whole download,
	// during which the SDRAM path must keep working.
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
	// 68000: 14 MHz via a 7/20 phase accumulator (wrap fires enPhi1, the
	// very next non-wrap cycle fires enPhi2; consecutive enPhi1 pulses
	// are never closer than 2 cycles, so the alternation always holds).
	// (parameters rather than localparams so a sim build can override the
	// ratio, e.g. -GCPU_CEN_INC=1 -GCPU_CEN_MOD=4 for a 10 MHz experiment)
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

	// Pixel: clk_sys/5 = 8 MHz.
	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// TLCS-90: 8 MHz = clk_sys/5, as a clock ENABLE on clk_sys. On the
	// hardware path a pulse is withheld while the program-ROM cache does
	// not yet hold the byte the CPU is reading (snd_stall, below) — the
	// CPU then simply sees a longer cycle. Never withheld during reset:
	// the core samples reset on cen edges.
	reg [2:0] snd_div = 3'd0;
	always @(posedge clk_sys) snd_div <= (snd_div == 3'd4) ? 3'd0 : snd_div + 3'd1;
	wire snd_stall;
	wire snd_cen = (snd_div == 3'd4) & ~snd_stall;

	// YM2203 at 1.5 MHz: 3/80 accumulator.
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
	// jt6295's cen IS the chip clock (see tdragon2_core.sv: the earlier
	// 1 MHz cen played every sample 4x too slow).
	reg [3:0] oki_cen_cnt = 4'd0;
	wire      oki_cen = (oki_cen_cnt == 4'd9);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 4'd0 : oki_cen_cnt + 4'd1;

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
	// Wait states (HW_ROMS=1 only — every *_ready is 1'b1 in the sim
	// path): maincpu ROM cache, registered RAM reads, sprite DMA.
	wire rom_wait     = sel_rom     & cpu_read & ~rom_ready;
	wire mainram_wait = sel_mainram & cpu_read & ~mainram_ready;
	wire sprite_dma_busy;
	wire mainram_dma_wait = sel_mainram & ~ASn & sprite_dma_busy;
	wire bgvram_wait  = sel_bgvram  & cpu_read & ~bgvram_ready;
	wire palette_wait = sel_palette & cpu_read & ~palette_ready;
	wire txvram_wait  = sel_txvram  & cpu_read & ~txvram_ready;
	wire scroll_wait  = (sel_scrollram | sel_scrollramy | sel_pad0400) & cpu_read & ~scroll_ready;
	wire DTACKn = ASn | iack_cycle | rom_wait | mainram_wait | mainram_dma_wait | bgvram_wait | txvram_wait | scroll_wait | palette_wait;

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
	// Address decode (raphero_map, nmk16.cpp)
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h07FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h080000); // 100000/100001
	wire sel_in1       = (byte_addr[23:1] == 23'h080001); // 100002/100003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h080004); // 100008/100009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h080005); // 10000A/10000B
	wire sel_soundlatch2_r = (byte_addr[23:1] == 23'h080007); // 10000E/10000F, byte reg at odd
	wire sel_flip      = (byte_addr[23:1] == 23'h08000A); // 100014/100015, LDS = low byte
	// 100016/100017 is nopw() — no sound-CPU reset here.
	wire sel_tilebank  = (byte_addr[23:1] == 23'h08000C); // 100018/100019, LDS = low byte
	wire sel_soundlatch_w = (byte_addr[23:1] == 23'h08000F); // 10001E/10001F, byte reg at odd
	wire sel_palette   = (byte_addr >= 24'h120000) && (byte_addr <= 24'h1207FF);
	wire sel_scrollram  = (byte_addr >= 24'h130000) && (byte_addr <= 24'h1301FF);
	wire sel_scrollramy = (byte_addr >= 24'h130200) && (byte_addr <= 24'h1303FF);
	wire sel_pad0400    = (byte_addr >= 24'h130400) && (byte_addr <= 24'h1307FF); // plain RAM
	wire sel_bgvram    = (byte_addr >= 24'h140000) && (byte_addr <= 24'h14FFFF);
	// TX VRAM 0x170000-0x170FFF mirrored at +0x1000 (byte_addr[12] ignored).
	wire sel_txvram    = (byte_addr >= 24'h170000) && (byte_addr <= 24'h171FFF);
	wire sel_mainram   = (byte_addr >= 24'h1F0000) && (byte_addr <= 24'h1FFFFF);

	// ------------------------------------------------------------------
	// Absolute byte offsets in the shared SDRAM image — see header.
	// 24-bit values (a 23-bit literal silently drops bit 23, see
	// tdragon2_core.sv's own note).
	// ------------------------------------------------------------------
	localparam [23:0] BASE_BYTE_AUDIOCPU = 24'h080000;
	localparam [23:0] BASE_BYTE_FGTILE   = 24'h0A0000;
	localparam [23:0] BASE_BYTE_BGTILE   = 24'h0C0000;
	localparam [23:0] BASE_BYTE_SPRITES  = 24'h2C0000;
	localparam [23:0] BASE_BYTE_OKI2     = 24'h8C0000;  // rhp94099.5, then .6
	localparam [23:0] BASE_BYTE_OKI1     = 24'hAC0000;  // rhp94099.6, then .7
	localparam [22:0] BASE_WORD_AUDIOCPU = BASE_BYTE_AUDIOCPU[23:1];
	localparam [22:0] BASE_WORD_FGTILE   = BASE_BYTE_FGTILE[23:1];
	localparam [22:0] BASE_WORD_BGTILE   = BASE_BYTE_BGTILE[23:1];
	localparam [22:0] BASE_WORD_SPRITES  = BASE_BYTE_SPRITES[23:1];
	localparam [22:0] BASE_WORD_OKI1     = BASE_BYTE_OKI1[23:1];
	localparam [22:0] BASE_WORD_OKI2     = BASE_BYTE_OKI2[23:1];

	// ------------------------------------------------------------------
	// ROM (maincpu) — 0x80000 bytes. HW_ROMS=1: rom_cache1 over SDRAM
	// port 0, shared with the ioctl_download writes (mutually exclusive
	// in time: the core is in reset for the whole download).
	// ------------------------------------------------------------------
	wire [15:0] rom_dout;
	wire        rom_ready;
	generate
	if (!HW_ROMS) begin : g_rom_sim
		reg [15:0] rom [0:262143];
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
		assign rom_dout  = rom[byte_addr[18:1]];
		assign rom_ready = 1'b1;
		assign sd0_addr = 24'd0; assign sd0_wrl = 1'b0; assign sd0_wrh = 1'b0;
		assign sd0_din  = 16'd0; assign sd0_req = 1'b0;
		assign ioctl_wait = 1'b0;
	end else begin : g_rom_hw
		wire        cache_busy, cache_valid;
		wire [15:0] cache_dout;
		wire [31:0] cache_dout_pair;
		wire [24:1] cache_sd_addr;
		wire        cache_sd_req;
		// Only the <rom index="0"> session writes SDRAM; the .mra
		// <switches> block (index 254) restarts at address 0 and would
		// otherwise land on the reset vector — see tdragon2_core.sv.
		wire ioctl_rom_wr = ioctl_download && (ioctl_index == 16'd0);

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

		// The cache only ever sees ROM addresses. rom_cache1 refetches
		// whenever its address input changes, so feeding it the raw bus
		// address made every main-RAM/VRAM access start a speculative
		// SDRAM read of an unrelated word; when that fill landed during
		// the NEXT program fetch — after the 68000 had sampled DTACK on a
		// cache hit but before it latched the data (enPhi2 to enPhi2) —
		// the line was overwritten under it and the CPU took an F-line
		// exception on the garbage opcode (hardware sim: boot RAM test,
		// fetch of $0025DA reading $FFFF). At 10 MHz the fill always
		// landed before the next fetch's DTACK; at 14 MHz it did not.
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
		// Golden-word audit (sim only, when ROM_FILE is given to an
		// HW_ROMS=1 build): every word the CPU actually takes from the
		// cache is compared with the plain ROM image.
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
						$display("[%0t] ROM wrong word: addr=%06x got=%04x golden=%04x pair=%08x sd_addr=%06x", $time,
							byte_addr, rom_dout, golden_rom[byte_addr[18:1]], cache_dout_pair, cache_sd_addr);
				end
			end
		end
		final $display("ROM golden-word audit: %0d words checked, %0d wrong", rom_words_checked, rom_words_wrong);
`endif
	end
	endgenerate

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16), CPU path address-line-swapped
	// (mainram_swapped_r/w: word-address bits 7 and 10 exchanged, i.e.
	// byte_addr bits 8 and 11). HW_ROMS=1: registered read + flattened
	// byte-enable writes for block-RAM inference (tdragon2_core.sv has
	// the full story), one extra DTACK wait via mainram_ready.
	// ------------------------------------------------------------------
	// Two 8-bit lane arrays, not one 16-bit array with lane writes
	// (2026-09-10, NMK-10): with the CPU port coded as a read/write port
	// whose read returns the byte being written (Quartus's true-dual-port
	// template, see g_mainram_cpu_hw) Quartus 17 infers ONE M10K set in
	// BIDIR_DUAL_PORT mode — CPU port A, video port B. The 16-bit form's
	// old-data read-during-write can only be met by a simple-dual-port set
	// plus a second full copy for the video read, which is what every
	// dual-read RAM here was getting (bgvram 64 extra M10K, mainram 16,
	// txvram 4). Isolated 4-variant synthesis test in docs/hw-bringup.md.
	// mainram_ready/DTACK, the address swap and the DMA gate are unchanged.
	reg [7:0] mainram_hi [0:32767];
	reg [7:0] mainram_lo [0:32767];
	wire [14:0] mainram_addr_cpu =
		{byte_addr[15:12], byte_addr[8], byte_addr[10:9], byte_addr[11], byte_addr[7:1]};
	reg [15:0] mainram_dout;
	wire       mainram_ready;
	generate
	if (!HW_ROMS) begin : g_mainram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_mainram & cpu_write & ~sprite_dma_busy) begin
				if (~UDSn) mainram_hi[mainram_addr_cpu] <= oEdb[15:8];
				if (~LDSn) mainram_lo[mainram_addr_cpu] <= oEdb[7:0];
			end
		end
		always @(*) mainram_dout  = {mainram_hi[mainram_addr_cpu], mainram_lo[mainram_addr_cpu]};
		assign mainram_ready = 1'b1;
	end else begin : g_mainram_cpu_hw
		// ready is COMBINATIONAL on the registered address: 1 exactly when
		// mainram_dout (read at the same edge that captured the address)
		// belongs to the address on the bus now. A registered ready flag
		// (tdragon2_core.sv's form) is stale-high for the first clk_sys
		// after the address changes; at 10 MHz the 68000 never samples
		// DTACK in that window, but at 14 MHz (enPhi2 one clk_sys after
		// enPhi1) it can, and then ends the bus cycle with the previous
		// address's data — seen in the hardware sim as the boot RAM test
		// faulting with an illegal-opcode exception.
		// True-dual-port template: on a write the read register takes the
		// written byte (never consumed — a 68000 bus cycle is read OR
		// write), otherwise the array. Keep this exact shape; see above.
		reg [14:0] mainram_addr_cpu_r;
		wire       we_hi = sel_mainram & cpu_write & ~UDSn & ~sprite_dma_busy;
		wire       we_lo = sel_mainram & cpu_write & ~LDSn & ~sprite_dma_busy;
		always @(posedge clk_sys) begin
			if (we_hi) begin mainram_hi[mainram_addr_cpu] <= oEdb[15:8]; mainram_dout[15:8] <= oEdb[15:8]; end
			else       mainram_dout[15:8] <= mainram_hi[mainram_addr_cpu];
			if (we_lo) begin mainram_lo[mainram_addr_cpu] <= oEdb[7:0];  mainram_dout[7:0]  <= oEdb[7:0];  end
			else       mainram_dout[7:0]  <= mainram_lo[mainram_addr_cpu];
			mainram_addr_cpu_r <= mainram_addr_cpu;
		end
		assign mainram_ready = (mainram_addr_cpu_r == mainram_addr_cpu);
	end
	endgenerate

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16)
	// ------------------------------------------------------------------
	// HW_ROMS=1: every read of this array is registered (CPU port here,
	// the two video taps below) so it infers as block RAM — one M10K pair
	// per read port — instead of 16K flip-flops behind three 1024:1
	// asynchronous muxes, which was most of this module's own logic in
	// the fitter's entity report (NMK-10). CPU reads take one DTACK wait
	// (palette_wait), the bgvram pattern.
	reg [15:0] palette [0:1023];
	wire [9:0] palette_addr = byte_addr[10:1];
	reg [15:0] palette_dout;
	wire       palette_ready;
	generate
	if (!HW_ROMS) begin : g_palette_sim
		always @(posedge clk_sys) begin
			if (sel_palette & cpu_write) begin
				if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
				if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
			end
		end
		always @(*) palette_dout = palette[palette_addr];
		assign palette_ready = 1'b1;
	end else begin : g_palette_hw
		reg [9:0] palette_addr_r;
		always @(posedge clk_sys) begin
			if (sel_palette & cpu_write & ~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
			if (sel_palette & cpu_write & ~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
			palette_dout   <= palette[palette_addr];
			palette_addr_r <= palette_addr;
		end
		assign palette_ready = (palette_addr_r == palette_addr); // see mainram_ready
	end
	endgenerate

	// ------------------------------------------------------------------
	// BG tilemap VRAM (32768 x 16)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port CPU port, as mainram above (NMK-10).
	reg [7:0] bgvram_hi [0:32767];
	reg [7:0] bgvram_lo [0:32767];
	wire [14:0] bgvram_addr = byte_addr[15:1];
	wire [15:0] bgvram_dout;
	reg  [15:0] bgvram_dout_r;
	wire        bgvram_ready;
	generate
	if (!HW_ROMS) begin : g_bgvram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_bgvram & cpu_write) begin
				if (~UDSn) bgvram_hi[bgvram_addr] <= oEdb[15:8];
				if (~LDSn) bgvram_lo[bgvram_addr] <= oEdb[7:0];
			end
		end
		assign bgvram_dout = {bgvram_hi[bgvram_addr], bgvram_lo[bgvram_addr]};
		assign bgvram_ready = 1'b1;
	end else begin : g_bgvram_cpu_hw
		reg [14:0] bgvram_addr_r;
		wire       we_hi = sel_bgvram & cpu_write & ~UDSn;
		wire       we_lo = sel_bgvram & cpu_write & ~LDSn;
		always @(posedge clk_sys) begin
			if (we_hi) begin bgvram_hi[bgvram_addr] <= oEdb[15:8]; bgvram_dout_r[15:8] <= oEdb[15:8]; end
			else       bgvram_dout_r[15:8] <= bgvram_hi[bgvram_addr];
			if (we_lo) begin bgvram_lo[bgvram_addr] <= oEdb[7:0];  bgvram_dout_r[7:0]  <= oEdb[7:0];  end
			else       bgvram_dout_r[7:0]  <= bgvram_lo[bgvram_addr];
			bgvram_addr_r <= bgvram_addr;
		end
		assign bgvram_ready = (bgvram_addr_r == bgvram_addr); // see mainram_ready
		assign bgvram_dout = bgvram_dout_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// TX tilemap VRAM (2048 x 16)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port CPU port, as mainram above (NMK-10).
	reg [7:0] txvram_hi [0:2047];
	reg [7:0] txvram_lo [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	wire [15:0] txvram_dout;
	reg  [15:0] txvram_dout_r;
	wire        txvram_ready;
	generate
	if (!HW_ROMS) begin : g_txvram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_txvram & cpu_write) begin
				if (~UDSn) txvram_hi[txvram_addr] <= oEdb[15:8];
				if (~LDSn) txvram_lo[txvram_addr] <= oEdb[7:0];
			end
		end
		assign txvram_dout = {txvram_hi[txvram_addr], txvram_lo[txvram_addr]};
		assign txvram_ready = 1'b1;
	end else begin : g_txvram_cpu_hw
		reg [10:0] txvram_addr_r;
		wire       we_hi = sel_txvram & cpu_write & ~UDSn;
		wire       we_lo = sel_txvram & cpu_write & ~LDSn;
		always @(posedge clk_sys) begin
			if (we_hi) begin txvram_hi[txvram_addr] <= oEdb[15:8]; txvram_dout_r[15:8] <= oEdb[15:8]; end
			else       txvram_dout_r[15:8] <= txvram_hi[txvram_addr];
			if (we_lo) begin txvram_lo[txvram_addr] <= oEdb[7:0];  txvram_dout_r[7:0]  <= oEdb[7:0];  end
			else       txvram_dout_r[7:0]  <= txvram_lo[txvram_addr];
			txvram_addr_r <= txvram_addr;
		end
		assign txvram_ready = (txvram_addr_r == txvram_addr); // see mainram_ready
		assign txvram_dout = txvram_dout_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// gunnail_scrollram / gunnail_scrollramy (256 x 16 each) + the plain
	// 0x130400-0x1307FF RAM (512 x 16). raphero_scroll_w's tilerambank
	// side effect on a write to scrollram word 0 uses bits [13:12] of the
	// word AFTER COMBINE_DATA — kept in scrollram0_reg (a register copy
	// of word 0, also the video's scrollram_0 tap) so a single-byte write
	// can merge with the other half without a RAM read. scrollramy word 0
	// likewise mirrored in scrollramy0_reg for the video tap.
	//
	// HW_ROMS=1: the three arrays are one 1024 x 16 block RAM (CPU port
	// r/w + video port read), registered reads with scroll_ready holding
	// DTACKn one cycle as for bgvram. Video-side row reads (one address
	// for both tables, video_macross2.sv's scroll_row_addr) go through a
	// second registered port; the one-cycle lag only matters inside the
	// horizontal blank where rd_y changes.
	// ------------------------------------------------------------------
	reg [15:0] scrollmem [0:1023];   // [0:255] scrollram, [256:511] scrollramy, [512:1023] pad0400
	wire [9:0] scroll_addr_cpu = sel_scrollram  ? {2'd0, byte_addr[8:1]} :
	                             sel_scrollramy ? {2'd1, byte_addr[8:1]} :
	                                              {1'b1, byte_addr[9:1]};
	wire       sel_scrollmem = sel_scrollram | sel_scrollramy | sel_pad0400;
	wire       sel_scrollram_off0 = sel_scrollram & (byte_addr[8:1] == 8'd0);
	wire       sel_scrollramy_off0 = sel_scrollramy & (byte_addr[8:1] == 8'd0);
	reg [15:0] scrollram0_reg, scrollramy0_reg;
	reg [1:0]  tilerambank_reg;
	wire [15:0] scrollram0_new  = {~UDSn ? oEdb[15:8] : scrollram0_reg[15:8],  ~LDSn ? oEdb[7:0] : scrollram0_reg[7:0]};
	wire [15:0] scrollramy0_new = {~UDSn ? oEdb[15:8] : scrollramy0_reg[15:8], ~LDSn ? oEdb[7:0] : scrollramy0_reg[7:0]};
	always @(posedge clk_sys) begin
		if (reset) begin
			scrollram0_reg  <= 16'h0000;
			scrollramy0_reg <= 16'h0000;
			tilerambank_reg <= 2'd0;
		end else if (cpu_write) begin
			if (sel_scrollram_off0) begin
				scrollram0_reg  <= scrollram0_new;
				tilerambank_reg <= scrollram0_new[13:12]; // newbank = (scrollram[0] >> 12) & 3
			end
			if (sel_scrollramy_off0) scrollramy0_reg <= scrollramy0_new;
		end
	end

	wire [15:0] scroll_dout;
	wire        scroll_ready;
	wire [7:0]  vid_scroll_row_addr;
	wire [15:0] vid_scrollram_row, vid_scrollramy_row;
	generate
	if (!HW_ROMS) begin : g_scrollmem_sim
		always @(posedge clk_sys) begin
			if (sel_scrollmem & cpu_write) begin
				if (~UDSn) scrollmem[scroll_addr_cpu][15:8] <= oEdb[15:8];
				if (~LDSn) scrollmem[scroll_addr_cpu][7:0]  <= oEdb[7:0];
			end
		end
		assign scroll_dout  = scrollmem[scroll_addr_cpu];
		assign scroll_ready = 1'b1;
		assign vid_scrollram_row  = scrollmem[{2'd0, vid_scroll_row_addr}];
		assign vid_scrollramy_row = scrollmem[{2'd1, vid_scroll_row_addr}];
	end else begin : g_scrollmem_hw
		reg [9:0]  scroll_addr_cpu_r;
		reg [15:0] scroll_dout_r;
		// Video port: the two rows are read on alternate cycles through
		// one port and held in registers, so the RAM stays 2-port.
		reg        vid_scroll_phase = 1'b0;
		reg [15:0] vid_scroll_q, vid_scrollram_row_r, vid_scrollramy_row_r;
		reg        vid_scroll_phase_d;
		always @(posedge clk_sys) begin
			if (sel_scrollmem & cpu_write & ~UDSn) scrollmem[scroll_addr_cpu][15:8] <= oEdb[15:8];
			if (sel_scrollmem & cpu_write & ~LDSn) scrollmem[scroll_addr_cpu][7:0]  <= oEdb[7:0];
			scroll_dout_r     <= scrollmem[scroll_addr_cpu];
			scroll_addr_cpu_r <= scroll_addr_cpu;

			vid_scroll_phase   <= ~vid_scroll_phase;
			vid_scroll_phase_d <= vid_scroll_phase;
			vid_scroll_q       <= scrollmem[{1'b0, vid_scroll_phase, vid_scroll_row_addr}];
			if (vid_scroll_phase_d) vid_scrollramy_row_r <= vid_scroll_q;
			else                    vid_scrollram_row_r  <= vid_scroll_q;
		end
		assign scroll_dout  = scroll_dout_r;
		assign scroll_ready = (scroll_addr_cpu_r == scroll_addr_cpu); // see mainram_ready
		assign vid_scrollram_row  = vid_scrollram_row_r;
		assign vid_scrollramy_row = vid_scrollramy_row_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Dual-port video read taps. vid_mainram_addr/dout is UNSWAPPED
	// (sprite_dma() reads the raw array). HW_ROMS=1: registered reads,
	// vid_mainram_ready for the byte-exact snapshot FSM.
	// ------------------------------------------------------------------
	wire [14:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout;
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout;
	wire [10:0] vid_palette_addr;     // 11 bits: video_macross2.sv's port; bit 10 is only set in its powerins mode
	wire [15:0] vid_palette_dout;
	wire [10:0] vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout;
	generate
	if (!HW_ROMS) begin : g_vidpal_sim
		assign vid_palette_dout     = palette[vid_palette_addr[9:0]];
		assign vid_spr_palette_dout = palette[vid_spr_palette_addr[9:0]];
	end else begin : g_vidpal_hw
		// Registered reads — video_macross2.sv's HW_ROMS=1 palette-tap
		// contract (one clock behind the address); see the palette block.
		reg [15:0] vid_palette_dout_r, vid_spr_palette_dout_r;
		always @(posedge clk_sys) begin
			vid_palette_dout_r     <= palette[vid_palette_addr[9:0]];
			vid_spr_palette_dout_r <= palette[vid_spr_palette_addr[9:0]];
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
		assign vid_bgvram_dout  = {bgvram_hi[vid_bgvram_addr],   bgvram_lo[vid_bgvram_addr]};
		assign vid_txvram_dout  = {txvram_hi[vid_txvram_addr],   txvram_lo[vid_txvram_addr]};
		assign vid_mainram_dout = {mainram_hi[vid_mainram_addr], mainram_lo[vid_mainram_addr]};
		assign vid_mainram_ready = 1'b1;
	end else begin : g_vidram_read_hw
		reg [15:0] vid_bgvram_dout_r, vid_txvram_dout_r, vid_mainram_dout_r;
		reg [14:0] vid_mainram_addr_r;
		always @(posedge clk_sys) begin
			vid_bgvram_dout_r   <= {bgvram_hi[vid_bgvram_addr],   bgvram_lo[vid_bgvram_addr]};
			vid_txvram_dout_r   <= {txvram_hi[vid_txvram_addr],   txvram_lo[vid_txvram_addr]};
			vid_mainram_dout_r  <= {mainram_hi[vid_mainram_addr], mainram_lo[vid_mainram_addr]};
			vid_mainram_addr_r  <= vid_mainram_addr;
		end
		assign vid_bgvram_dout   = vid_bgvram_dout_r;
		assign vid_txvram_dout   = vid_txvram_dout_r;
		assign vid_mainram_dout  = vid_mainram_dout_r;
		assign vid_mainram_ready = (vid_mainram_addr_r == vid_mainram_addr); // see mainram_ready
	end
	endgenerate

	// Testbench-only third read port (TB_DUMP_VRAM); tied off in hardware.
	generate
	if (!HW_ROMS) begin : g_dbgram_sim
		assign dbg_pal_data = palette[dbg_pal_addr];
		assign dbg_bgvram_data = {bgvram_hi[dbg_bgvram_addr[14:0]], bgvram_lo[dbg_bgvram_addr[14:0]]};
		assign dbg_txvram_data = {txvram_hi[dbg_txvram_addr], txvram_lo[dbg_txvram_addr]};
	end else begin : g_dbgram_hw
		assign dbg_pal_data = 16'd0;
		assign dbg_bgvram_data = 16'd0;
		assign dbg_txvram_data = 16'd0;
	end
	endgenerate

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

	// soundlatch (68000 -> TLCS-90) / soundlatch2 (TLCS-90 -> 68000):
	// plain polling registers, no interrupt side effect.
	reg [7:0] soundlatch_data;
	reg [7:0] soundlatch2_data;
	always @(posedge clk_sys) begin
		if (reset) soundlatch_data <= 8'h00;
		else if (sel_soundlatch_w & cpu_write & ~LDSn) soundlatch_data <= oEdb[7:0];
	end

	// ------------------------------------------------------------------
	// TLCS-90 sound board: tlcs90.sv + nmk004_periph.sv on clk_sys with
	// the 8 MHz snd_cen, raphero_sound_mem_map decode, NMK112, jt03
	// (YM2203), jt6295 x2.
	// ------------------------------------------------------------------
	wire [7:0]  snd_din, snd_dout;
	wire [15:0] snd_addr;
	wire [3:0]  snd_addr_bank;
	wire        snd_mem_rd, snd_mem_wr;
	wire [10:0] irq_mask, irq_req_periph;
	wire [3:0]  snd_bx, snd_by;

	// YM2203 IRQ (active low) into INT0 — same wiring as nmk004_core.sv.
	wire [10:0] irq_req_to_cpu = {irq_req_periph[10:1], irq_req_periph[0] | ~ym_chip_irq_n};

	tlcs90 snd_cpu (
		.clk(clk_sys), .cen(snd_cen), .reset(reset),
		.din(snd_din), .dout(snd_dout), .addr(snd_addr), .addr_bank(snd_addr_bank),
		.mem_rd(snd_mem_rd), .mem_wr(snd_mem_wr),
		.nmi(1'b0), .irq_req(irq_req_to_cpu), .irq_mask(irq_mask),
		.ix_bank(snd_bx), .iy_bank(snd_by),
		.dbg_pc(dbg_snd_pc), .dbg_valid(dbg_snd_valid), .dbg_halt(),
		.dbg_a(), .dbg_f(), .dbg_hl(), .dbg_de(), .dbg_iy()
	);

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
	// External RAM backs E000-FEBF; FEC0-FFBF is the TLCS-90's internal
	// RAM and FFC0-FFEF its peripheral registers.
	wire sel_snd_ext_ram = snd_bank0 && (snd_addr >= 16'hE000) && (snd_addr <= 16'hFEBF);
	wire sel_snd_int_ram = snd_bank0 && (snd_addr >= 16'hFEC0) && (snd_addr <= 16'hFFBF);
	wire sel_snd_periph  = snd_bank0 && (snd_addr >= 16'hFFC0) && (snd_addr <= 16'hFFEF);

	reg [2:0] audiobank_reg;
	always @(posedge clk_sys) begin
		if (reset) audiobank_reg <= 3'd0;
		else if (sel_snd_audiobank & snd_mem_wr & snd_cen) audiobank_reg <= snd_dout[2:0]; // macross2_audiobank_w
	end
	wire [16:0] snd_bank_phys = {audiobank_reg, 14'd0} + {3'd0, snd_addr[13:0]};

	// Program ROM: 0x20000 flat image, fixed at 0-7FFF, 8 x 0x4000 bank
	// window at 8000-BFFF.
	wire [7:0] audiocpu_dout;
	wire       audiocpu_ready;
	wire [21:0] audiocpu_byte_addr = sel_snd_bank ? {5'd0, snd_bank_phys} : {7'd0, snd_addr[14:0]};
	// Withhold the CPU clock while the byte being read is not resident
	// (never in reset — the CPU samples reset on cen edges).
	assign snd_stall = (sel_snd_rom | sel_snd_bank) & snd_mem_rd & ~audiocpu_ready & ~reset;

	// SDRAM port 1, three channels: program ROM, OKI0, OKI1 samples.
	wire        p1_busy [0:3];
	wire        p1_valid[0:3];
	wire [24:1] p1_addr [0:3];
	wire        p1_req  [0:3];
	wire [15:0] p1_dout [0:3];
	wire [31:0] p1_dout_pair [0:3];
	generate
	if (!HW_ROMS) begin : g_audiocpu_sim
		reg [7:0] audiocpu_rom [0:131071];
		initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);
		assign audiocpu_dout  = audiocpu_rom[audiocpu_byte_addr[16:0]];
		assign audiocpu_ready = 1'b1;
		assign sd3_addr = 24'd0; assign sd3_req = 1'b0;
		assign p1_busy  = '{1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_valid = '{1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_dout  = '{16'd0, 16'd0, 16'd0, 16'd0};
		assign p1_dout_pair = '{32'd0, 32'd0, 32'd0, 32'd0};
		// channel 0 (TX prefetch) is driven by the video module's txc_* outputs
		assign p1_addr[1] = 24'd0; assign p1_addr[2] = 24'd0; assign p1_addr[3] = 24'd0;
		// channel 0 (TX prefetch) is driven by the video module's txc_* outputs
		assign p1_req[1] = 1'b0; assign p1_req[2] = 1'b0; assign p1_req[3] = 1'b0;
	end else begin : g_audiocpu_hw
		// Physical port 3: channel 0 is the video module's TX prefetch
		// stream (top priority, it is real-time), the sound consumers
		// follow. The sprite fetch has physical port 1 to itself (video
		// sd_b_*) — see video_macross2.sv TX_EXTERNAL.
		sdram_arb #(.N(4), .FIXED_PRIO(1)) p1_arb_inst (
			.clk(clk_sys), .reset(por_rst),
			.i_addr(p1_addr), .i_we('{1'b0, 1'b0, 1'b0, 1'b0}), .i_wrl('{1'b0, 1'b0, 1'b0, 1'b0}), .i_wrh('{1'b0, 1'b0, 1'b0, 1'b0}), .i_din('{16'd0, 16'd0, 16'd0, 16'd0}),
			.i_req(p1_req), .i_busy(p1_busy), .i_valid(p1_valid), .i_dout(p1_dout), .i_dout_pair(p1_dout_pair),
			.sdram_addr(sd3_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
			.sdram_dout(sd3_dout), .sdram_dout_pair(sd3_dout_pair), .sdram_req(sd3_req), .sdram_ack(sd3_ack)
		);
		// oki_rom_cache (multi-line, next-line prefetch), not the 1-line
		// rom_cache1_byte the Z80 boards use: the TLCS-90 fetches a byte
		// every few 8 MHz cycles and has no WAIT pin, so every miss is a
		// full clock stall — the prefetch hides most of them.
		oki_rom_cache audiocpu_cache_inst (
			.base_word(BASE_WORD_AUDIOCPU),
			.clk(clk_sys), .reset(reset),
			.byte_addr(audiocpu_byte_addr), .data(audiocpu_dout), .ready(audiocpu_ready), .stall(),
			.sd_addr(p1_addr[1]), .sd_req(p1_req[1]), .sd_busy(p1_busy[1]), .sd_valid(p1_valid[1]), .sd_dout(p1_dout[1]), .sd_dout_pair(p1_dout_pair[1])
		);
	end
	endgenerate

	// External RAM (E000-FEBF) + internal RAM (FEC0-FFBF). Writes are
	// taken on the cen edge that ends the CPU's write cycle (mem_wr is
	// held for the whole cycle). Reads are registered (block-RAM
	// inference): the CPU captures din on a cen edge, at least 5 clk_sys
	// after it presented the address.
	reg [7:0] snd_ext_ram [0:7871];
	reg [7:0] snd_int_ram [0:255];
	reg [7:0] snd_ext_q, snd_int_q;
	wire [12:0] snd_ext_addr = snd_addr[12:0]; // E000-FEBF -> 0-1EBF
	always @(posedge clk_sys) begin
		if (sel_snd_ext_ram & snd_mem_wr & snd_cen) snd_ext_ram[snd_ext_addr] <= snd_dout;
		snd_ext_q <= snd_ext_ram[snd_ext_addr];
	end
	always @(posedge clk_sys) begin
		if (sel_snd_int_ram & snd_mem_wr & snd_cen) snd_int_ram[snd_addr[7:0]] <= snd_dout;
		snd_int_q <= snd_int_ram[snd_addr[7:0]];
	end

	always @(posedge clk_sys) begin
		if (reset) soundlatch2_data <= 8'h00;
		else if (sel_snd_soundlatch2_w & snd_mem_wr & snd_cen) soundlatch2_data <= snd_dout;
	end

	wire [7:0] periph_rdata;
	nmk004_periph periph (
		.clk(clk_sys), .cen(snd_cen), .reset(reset),
		.reg_addr(snd_addr[5:0]),
		.wdata(snd_dout),
		.we(sel_snd_periph & snd_mem_wr),
		.re(sel_snd_periph & snd_mem_rd),
		.rdata(periph_rdata),
		.irq_mask(irq_mask), .irq_req(irq_req_periph),
		.p4_latch(), .bx(snd_bx), .by(snd_by),
		.p5_ext_en(1'b0), .p5_ext_val(8'h00),
		.p6_ext_en(1'b0), .p6_ext_val(8'h00),
		.p6_we(), .p6_wdata(),
		.p7_ext_en(1'b0), .p7_ext_val(8'h00),
		.p3_we(), .p3_wdata(),
		.p7_we(), .p7_wdata()
	);

	// ------------------------------------------------------------------
	// YM2203 — jt03, 40-cycle write stretch (exceeds ym_cen's 27-cycle
	// worst-case gap). C000 = address/status, C001 = data.
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
			ym_addr_latch <= snd_addr[0];
			ym_wr_hold    <= 6'd40;
		end else if (ym_wr_hold != 6'd0) begin
			ym_wr_hold <= ym_wr_hold - 6'd1;
		end
	end
	wire ym_wr_n = ~(ym_wr_hold != 6'd0);
	// jt03's dout follows addr live — a status read must see the live
	// decode, not the write latch (tdragon2_core.sv has the story).
	wire ym_addr_sel = (ym_wr_hold != 6'd0) ? ym_addr_latch : snd_addr[0];

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	wire signed [15:0] ym_snd;
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_sel), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(dbg_fm_snd), .psg_snd(dbg_psg_snd), .snd(ym_snd), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// NMK112 — both OKI ROMs 0x400000 (masks 63). reg_sel = C810-C817's
	// low 3 bits (okibank_w offset).
	// ------------------------------------------------------------------
	wire nmk112_we = sel_snd_nmk112 & snd_mem_wr & snd_cen;
	wire [17:0] oki0_rom_addr_raw, oki1_rom_addr_raw;
	wire [21:0] oki0_rom_addr, oki1_rom_addr;
	// "A gated OKI cen is passing this clock" — a bank write landing on
	// this edge would change the remapped address inside jt6295's
	// registered-cen latch window (rtl/nmk112.sv `hold`, NMK-15). Assigned
	// below, after the stall wires exist.
	wire nmk112_hold;
	nmk112 #(
		.ROM0_BYTES(4194304), // rhp94099.6+7 (oki1)
		.ROM1_BYTES(4194304)  // rhp94099.5+6 (oki2)
	) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(snd_addr[2:0]), .reg_data(snd_dout), .reg_we(nmk112_we), .hold(nmk112_hold),
		.rom0_addr_in(oki0_rom_addr_raw), .rom0_addr_out(oki0_rom_addr),
		.rom1_addr_in(oki1_rom_addr_raw), .rom1_addr_out(oki1_rom_addr)
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295. HW_ROMS=1: oki_rom_cache per chip on SDRAM
	// port 1 channels 1/2, `stall` gating the chip's cen (jt6295's ADPCM
	// fetch ignores rom_ok — see rtl/oki_rom_cache.sv).
	// ------------------------------------------------------------------
	wire [7:0] oki0_rom_data, oki1_rom_data;
	wire       oki0_rom_ok, oki1_rom_ok;
	wire       oki0_stall, oki1_stall;
	assign nmk112_hold = oki_cen & (~oki0_stall | ~oki1_stall);
	generate
	if (!HW_ROMS) begin : g_oki_sim
		reg [7:0] oki0_rom [0:4194303]; // rhp94099.6+7
		reg [7:0] oki1_rom [0:4194303]; // rhp94099.5+6
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki0_rom);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki1_rom);
		reg [7:0] oki0_rom_data_r, oki1_rom_data_r;
		always @(posedge clk_sys) oki0_rom_data_r <= oki0_rom[oki0_rom_addr];
		always @(posedge clk_sys) oki1_rom_data_r <= oki1_rom[oki1_rom_addr];
		assign oki0_rom_data = oki0_rom_data_r;
		assign oki1_rom_data = oki1_rom_data_r;
		assign oki0_rom_ok = 1'b1;
		assign oki1_rom_ok = 1'b1;
		assign oki0_stall = 1'b0;
		assign oki1_stall = 1'b0;
		assign dbg_oki0_adpcm_total = 32'd0; assign dbg_oki0_adpcm_unserved = 32'd0;
		assign dbg_oki1_adpcm_total = 32'd0; assign dbg_oki1_adpcm_unserved = 32'd0;
		assign dbg_oki_cen_total = 32'd0; assign dbg_oki0_stall_cen = 32'd0; assign dbg_oki1_stall_cen = 32'd0;
	end else begin : g_oki_hw
		oki_rom_cache oki0_cache_inst (
			.base_word(BASE_WORD_OKI1),
			.clk(clk_sys), .reset(reset),
			.byte_addr(oki0_rom_addr), .data(oki0_rom_data), .ready(oki0_rom_ok), .stall(oki0_stall),
			.sd_addr(p1_addr[2]), .sd_req(p1_req[2]), .sd_busy(p1_busy[2]), .sd_valid(p1_valid[2]), .sd_dout(p1_dout[2]), .sd_dout_pair(p1_dout_pair[2])
		);
		oki_rom_cache oki1_cache_inst (
			.base_word(BASE_WORD_OKI2),
			.clk(clk_sys), .reset(reset),
			.byte_addr(oki1_rom_addr), .data(oki1_rom_data), .ready(oki1_rom_ok), .stall(oki1_stall),
			.sd_addr(p1_addr[3]), .sd_req(p1_req[3]), .sd_busy(p1_busy[3]), .sd_valid(p1_valid[3]), .sd_dout(p1_dout[3]), .sd_dout_pair(p1_dout_pair[3])
		);
`ifdef VERILATOR
		// Sample-fetch audit + golden-byte check against the plain ROM
		// images (given as OKI*_ROM_FILE to an HW_ROMS=1 sim build) —
		// see tdragon2_core.sv's g_oki_hw for the derivation.
		reg [31:0] oki0_adpcm_total_r = 32'd0, oki0_adpcm_unserved_r = 32'd0;
		reg [31:0] oki1_adpcm_total_r = 32'd0, oki1_adpcm_unserved_r = 32'd0;
		reg [31:0] oki_cen_total_r = 32'd0, oki0_stall_cen_r = 32'd0, oki1_stall_cen_r = 32'd0;
		reg [7:0] golden0 [0:4194303];
		reg [7:0] golden1 [0:4194303];
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, golden0);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, golden1);
		reg [31:0] oki0_bytes_wrong = 32'd0, oki1_bytes_wrong = 32'd0, oki0_bytes_checked = 32'd0, oki1_bytes_checked = 32'd0;
		// One- and two-clock history of the OKI0 fetch interface, so a
		// mismatch line can say what changed in the registered-cen window
		// (NMK-15): was the address different a clock ago, was it resident
		// then, and did the cache fill anything on the last two clocks.
		reg [21:0] oki0_addr_d1 = 22'd0, oki0_addr_d2 = 22'd0;
		reg        oki0_ok_d1 = 1'b0, oki0_ok_d2 = 1'b0;
		reg        oki0_fill_d1 = 1'b0, oki0_fill_d2 = 1'b0;
		reg  [3:0] oki0_fill_victim_d1 = 4'd0, oki0_fill_victim_d2 = 4'd0;
		reg        oki0_fill_pf_d1 = 1'b0, oki0_fill_pf_d2 = 1'b0;
		reg        oki0_cen_d1 = 1'b0;
		always @(posedge clk_sys) begin
			oki0_addr_d2 <= oki0_addr_d1; oki0_addr_d1 <= oki0_rom_addr;
			oki0_ok_d2   <= oki0_ok_d1;   oki0_ok_d1   <= oki0_rom_ok;
			oki0_fill_d2 <= oki0_fill_d1; oki0_fill_d1 <= oki0_cache_inst.pending & oki0_cache_inst.sd_valid;
			oki0_fill_victim_d2 <= oki0_fill_victim_d1; oki0_fill_victim_d1 <= oki0_cache_inst.victim;
			oki0_fill_pf_d2 <= oki0_fill_pf_d1; oki0_fill_pf_d1 <= oki0_cache_inst.req_is_prefetch;
			oki0_cen_d1 <= oki_cen & ~oki0_stall;
		end
		always @(posedge clk_sys) begin
			if (oki_cen) begin
				oki_cen_total_r <= oki_cen_total_r + 32'd1;
				if (oki0_stall) oki0_stall_cen_r <= oki0_stall_cen_r + 32'd1;
				if (oki1_stall) oki1_stall_cen_r <= oki1_stall_cen_r + 32'd1;
			end
			if (oki0_chip.u_rom.st == 8'h02 && oki0_chip.u_rom.cen32) begin
				oki0_adpcm_total_r <= oki0_adpcm_total_r + 32'd1;
				if (!oki0_rom_ok) oki0_adpcm_unserved_r <= oki0_adpcm_unserved_r + 32'd1;
				if (OKI1_ROM_FILE != "") begin
					oki0_bytes_checked <= oki0_bytes_checked + 32'd1;
					if (oki0_rom_data != golden0[oki0_rom_addr]) begin
						oki0_bytes_wrong <= oki0_bytes_wrong + 32'd1;
						// Every mismatch is worth a line: the audit is otherwise exact,
						// so a stray byte is a real fetch race to chase (NMK-15).
						$display("OKI0 GOLDEN MISMATCH addr=%06x got=%02x want=%02x rom_ok=%0d stall=%0d latch#%0d | 1clk ago: addr=%06x ok=%0d cen_passed=%0d fill=%0d(victim %0d pf %0d) | 2clk ago: addr=%06x ok=%0d fill=%0d(victim %0d pf %0d) | cache now: hit=%0d idx=%0d pending=%0d victim=%0d pf=%0d req_line=%05x",
							oki0_rom_addr, oki0_rom_data, golden0[oki0_rom_addr], oki0_rom_ok, oki0_stall, oki0_bytes_checked,
							oki0_addr_d1, oki0_ok_d1, oki0_cen_d1, oki0_fill_d1, oki0_fill_victim_d1, oki0_fill_pf_d1,
							oki0_addr_d2, oki0_ok_d2, oki0_fill_d2, oki0_fill_victim_d2, oki0_fill_pf_d2,
							oki0_cache_inst.hit_cur, oki0_cache_inst.idx_cur, oki0_cache_inst.pending, oki0_cache_inst.victim, oki0_cache_inst.req_is_prefetch, oki0_cache_inst.req_line);
					end
				end
			end
			if (oki1_chip.u_rom.st == 8'h02 && oki1_chip.u_rom.cen32) begin
				oki1_adpcm_total_r <= oki1_adpcm_total_r + 32'd1;
				if (!oki1_rom_ok) oki1_adpcm_unserved_r <= oki1_adpcm_unserved_r + 32'd1;
				if (OKI2_ROM_FILE != "") begin
					oki1_bytes_checked <= oki1_bytes_checked + 32'd1;
					if (oki1_rom_data != golden1[oki1_rom_addr]) begin
						oki1_bytes_wrong <= oki1_bytes_wrong + 32'd1;
						$display("OKI1 GOLDEN MISMATCH t=%0t addr=%06x got=%02x want=%02x rom_ok=%0d stall=%0d latch#%0d",
							$time, oki1_rom_addr, oki1_rom_data, golden1[oki1_rom_addr], oki1_rom_ok, oki1_stall, oki1_bytes_checked);
					end
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

	// Sound-CPU clock audit (sim only): delivered vs withheld pulses.
`ifdef VERILATOR
	reg [31:0] snd_cen_total_r = 32'd0, snd_stall_total_r = 32'd0;
	always @(posedge clk_sys) if (snd_div == 3'd4) begin
		if (snd_stall) snd_stall_total_r <= snd_stall_total_r + 32'd1;
		else           snd_cen_total_r   <= snd_cen_total_r + 32'd1;
	end
	assign dbg_snd_cen_total   = snd_cen_total_r;
	assign dbg_snd_stall_total = snd_stall_total_r;
`else
	assign dbg_snd_cen_total   = 32'd0;
	assign dbg_snd_stall_total = 32'd0;
`endif

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
	wire signed [13:0] oki0_snd, oki1_snd;
	jt6295 oki0_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki0_stall), .ss(1'b0),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki0_chip_dout),
		.rom_addr(oki0_rom_addr_raw), .rom_data(oki0_rom_data), .rom_ok(oki0_rom_ok),
		.sound(oki0_snd), .sample()
	);
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki1_stall), .ss(1'b0),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr_raw), .rom_data(oki1_rom_data), .rom_ok(oki1_rom_ok),
		.sound(oki1_snd), .sample()
	);

	// ------------------------------------------------------------------
	// Audio mix — mono, same balance as tdragon2_core.sv (raphero()'s
	// routes are identical: FM 1.20, PSG 0.50 x3, each OKI 0.10): jt03's
	// mixed snd + each OKI x 3/8, saturated.
	// ------------------------------------------------------------------
	wire signed [17:0] oki0_ext = {{4{oki0_snd[13]}}, oki0_snd};
	wire signed [17:0] oki1_ext = {{4{oki1_snd[13]}}, oki1_snd};
	wire signed [17:0] oki0_g   = oki0_ext + (oki0_ext >>> 1); // x 3/2 (was 3/8 -- measured 8-13dB quiet vs MAME's real OKI:FM balance)
	wire signed [17:0] oki1_g   = oki1_ext + (oki1_ext >>> 1);
	wire signed [17:0] audio_sum = {{2{ym_snd[15]}}, ym_snd} + oki0_g + oki1_g;
	wire signed [15:0] audio_mix =
		(audio_sum > 18'sd32767)  ? 16'sd32767  :
		(audio_sum < -18'sd32768) ? -16'sd32768 :
		audio_sum[15:0];
	assign audio_l = audio_mix;
	assign audio_r = audio_mix;
	assign dbg_oki0_snd = oki0_snd;
	assign dbg_oki1_snd = oki1_snd;

	// ------------------------------------------------------------------
	// TLCS-90 read-data mux (memory-mapped: no I/O-space hazard here)
	// ------------------------------------------------------------------
	reg [7:0] snd_rdata;
	always @(*) begin
		if (sel_snd_rom)          snd_rdata = audiocpu_dout;
		else if (sel_snd_bank)    snd_rdata = audiocpu_dout;
		else if (sel_snd_ext_ram) snd_rdata = snd_ext_q;
		else if (sel_snd_int_ram) snd_rdata = snd_int_q;
		else if (sel_snd_periph)  snd_rdata = periph_rdata;
		else if (sel_snd_soundlatch_r) snd_rdata = soundlatch_data;
		else if (sel_snd_ym)      snd_rdata = ym_chip_dout;
		else if (sel_snd_oki0)    snd_rdata = oki0_chip_dout;
		else if (sel_snd_oki1)    snd_rdata = oki1_chip_dout;
		else                      snd_rdata = 8'h00;
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
		else if (sel_scrollmem) rdata = scroll_dout;
		else if (sel_soundlatch2_r) rdata = {8'h00, soundlatch2_data};
		else if (sel_in0)     rdata = HW_ROMS ? in0_i  : 16'hFFFF;
		else if (sel_in1)     rdata = HW_ROMS ? in1_i  : 16'hFFFF;
		else if (sel_dsw1)    rdata = HW_ROMS ? dsw1_i : 16'hFFFF;
		else if (sel_dsw2)    rdata = HW_ROMS ? dsw2_i : 16'hFFFF;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + V-PROM interrupt generation
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);
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
	// Video pipeline — rtl/macross2/video_macross2.sv with per-line
	// scroll taps and the 6 MB sprite ROM.
	// ------------------------------------------------------------------
	video_macross2 #(
		.TX_EXTERNAL(1),
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.SPRITES_FILE(SPRITES_FILE),
		.HW_ROMS(HW_ROMS),
		.DBG_MISS_PAINT(DBG_MISS_PAINT),
		.RASTER_SCROLL(1),
		.SPRITES_BYTES(6291456)
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
		.nmk214_cfg_we(1'b0), .nmk214_cfg_data(8'h00),
		.scrollram_row(vid_scrollram_row), .scrollramy_row(vid_scrollramy_row),
		.bg_bank(bgbank_reg),
		.game_powerins(1'b0), .base_word_fgtile(BASE_WORD_FGTILE), .base_word_bgtile(BASE_WORD_BGTILE), .base_word_sprites(BASE_WORD_SPRITES),
		.lowres(1'b0), .raster_scroll(1'b1), .cfg_rt(1'b0), .bga_pal_base_i(11'd0), .bgb_pal_base_i(11'd0), .spr_pal_base_i(11'd0), .tx_pal_base_i(11'd0),
		.bga_code_mask_i(14'd0), .bgb_code_mask_i(14'd0), .spr_units_i(18'd0), .sprdma_word_base(15'h4000), .nmk214_en(1'b1),
		.bg2_en(1'b0), .bga_rom2(1'b0), .bgb_rom2(1'b0), .base_word_bgtile_b(23'd0), .bgvram_b_addr(), .bgvram_b_data(16'd0), .bgb_xscroll(16'd0), .bgb_yscroll(16'd0),
		.tilerambank(tilerambank_reg),
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

	assign dbg_snd_cen   = snd_cen;
	assign dbg_snd_stall = snd_stall;

	assign dbg_ym_we = ym_we_raw;
	assign dbg_ym_cs = sel_snd_ym;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_irq_n = ym_chip_irq_n;

	assign dbg_oki0_we = sel_oki0_we;
	assign dbg_oki1_we = sel_oki1_we;
	assign dbg_oki0_chip_dout = oki0_chip_dout;
	assign dbg_oki1_chip_dout = oki1_chip_dout;

endmodule
