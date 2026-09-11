// NMK16 MiSTerFPGA project — tdragon1 hardware family (Tier 2's own
// Family D: TLCS-90 shared-RAM protection MCU) system-level integration.
//
// The first Family D game, and the ninth NMK004-board-derived port this
// session (see tdragon_core.sv's own header for the full 68000/NMK004/
// jt03/jt6295/nmk_irq architecture this reuses wholesale). Confirmed
// directly from the reference (`tdragon_prot(machine_config &config)`
// in mame/src/mame/nmk/nmk16.cpp) that `tdragon_prot()` calls `tdragon
// (config)` FIRST, then only ADDS a protection-MCU device on top — the
// 68000/video/sound hardware, and therefore the 68000's own memory map
// (`tdragon_map`) and `video_tdragon.sv`, are byte-for-byte unchanged
// from the already-ported `tdragon`. This file is tdragon_core.sv with
// exactly one addition: a second, independent TLCS-90 instance
// (`rtl/tlcs90/nmk_prot_core.sv`) wired as a genuine shared-bus master
// over the SAME storage arrays (mainram/palette/bgvram/txvram/rom) and
// the same small I/O-register cluster the 68000 itself uses — see
// nmk_prot_core.sv's own header for the protection mechanism itself
// (full-bus read/write, a real 68000 HALT line, scanline/bus-status
// port reads).
//
// New wiring, all additive (every prior tdragon_core.sv signal/array is
// untouched other than gaining a second write source):
//   - `nmk_prot_core` runs at 4MHz (XTAL(4'000'000) in the reference's
//     own `TMP91640(config, m_protcpu, 4000000)`) — a new /8 clock
//     divider off clk_sys (32MHz/8), parallel to the existing NMK004
//     /4 divider (32MHz/4=8MHz).
//   - The protection MCU's own 20-bit byte address (`{addr_bank,addr}`,
//     see nmk_prot_core.sv's header) numerically overlaps the 68000's
//     own byte_addr directly (every real tdragon region lives at or
//     below 0x0D07FF, comfortably inside the 20-bit 0x000000-0x0FFFFF
//     range) — so the SAME range constants tdragon_core.sv's own
//     sel_* decode already uses are reused verbatim for the
//     protection MCU's own prot_sel_* decode, just evaluated against
//     the 20-bit `prot_addr` instead of the 24-bit `byte_addr`, and at
//     BYTE (not word+UDS/LDS) granularity, since the reference's own
//     `mcu_side_shared_r/w` are genuinely byte-addressed
//     (`read_byte`/`write_byte`), unlike the 68000's own word bus.
//   - Every RAM array the protection MCU can reach (mainram, palette,
//     bgvram, txvram) gets a second write-enable branch, with the
//     protection MCU's own write given priority on a same-cycle
//     conflict — justified by the real hardware's own HALT-before-
//     sensitive-access guarantee (the protection MCU always asserts
//     HALT via port 6 before touching shared RAM in the real
//     handshake the reference's own comments describe, so a genuine
//     same-cycle conflict with the 68000 itself shouldn't occur in
//     practice; the priority is a deterministic tie-break for
//     simulation, not a modeled real arbitration circuit). ROM stays
//     read-only for the protection MCU (writes silently dropped, same
//     as real ROM).
//   - `fx68k`'s own `HALTn` input, tied `1'b1` (never halted) in every
//     prior port, is now driven for real: `~halt_68k`, halt_68k being
//     nmk_prot_core's own output (port 6 write 0x08/0x0B).
//   - Port 5 (scanline read) wired from `vt_vcount[9:2]` (`>>2`,
//     matching `screen.vpos()>>2` exactly — `vt_vcount` is already the
//     same 10-bit raster line counter nmk_irq/video_tdragon both use).
//
// ROMs: tdragon1.zip supplies only `thund.7`/`thund.8` (maincpu — a
// different program from tdragon's own `91070_68k.7/.8`, despite
// identical loading convention) and `nmk-110-tdragon.bin` (16KB
// protection-MCU boot ROM). Every other region (fgtile/bgtile/sprites/
// nmk004 boot+ext/oki1/oki2/vtiming) is byte-for-byte identical to the
// already-extracted tdragon romset (same filenames/CRCs, confirmed via
// `unzip -l`) — reused directly, same split-zip pattern already
// established for hachamfb/hachamf.
module tdragon1_core #(
	parameter ROM_FILE      = "",
	parameter NMK004_BOOT_FILE = "",
	parameter NMK004_EXT_FILE  = "",
	parameter PROT_BOOT_FILE = "",
	parameter OKI1_ROM_FILE = "",
	parameter OKI2_ROM_FILE = "",
	parameter VTIMING_FILE  = "",
	parameter FGTILE_FILE   = "",
	parameter BGTILE_FILE   = "",
	parameter SPRITES_FILE  = ""
) (
	input clk_sys,       // 32 MHz (68000 effective bus and pixel/raster clock both clk_sys/4 = 8MHz)
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

	output [15:0] dbg_prot_pc,
	output        dbg_prot_valid,
	output        dbg_halt_68k,
	output [15:0] dbg_prot_hl,
	output  [7:0] dbg_prot_a,
	output [15:0] dbg_prot_de,
	output [15:0] dbg_prot_iy,
	output [19:0] dbg_prot_addr,
	output [9:0]  dbg_vt_vcount,

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
	input  [12:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [9:0]  dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables — identical to tdragon_core.sv's own, plus a new
	// /8 divider for the 4MHz protection MCU (see header).
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [1:0] nmk004_div = 2'd0;
	always @(posedge clk_sys) nmk004_div <= reset ? 2'd0 : nmk004_div + 2'd1;
	wire nmk004_clk_r = nmk004_div[1];

	reg [2:0] prot_div = 3'd0;
	always @(posedge clk_sys) prot_div <= reset ? 3'd0 : prot_div + 3'd1;
	wire prot_clk_r = prot_div[2]; // 32MHz/8 = 4MHz

	reg [1:0] pix_div = 2'd0;
	wire ce_pix = (pix_div == 2'd3);
	always @(posedge clk_sys) pix_div <= reset ? 2'd0 : (ce_pix ? 2'd0 : pix_div + 2'd1);

	// ------------------------------------------------------------------
	// fx68k — HALTn now genuinely driven by the protection MCU (see
	// header); every other input identical to tdragon_core.sv's own.
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
	// Address decode — identical to tdragon_core.sv's own (see that
	// module's header for the mirroring derivation).
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h03FFFF);
	wire sel_mainram   = (byte_addr[23:18] == 6'b000010);

	wire [23:0] io_addr = byte_addr & ~24'h020000;
	wire sel_in0       = (io_addr[23:1] == 23'h060000);
	wire sel_in1       = (io_addr[23:1] == 23'h060001);
	wire sel_dsw1      = (io_addr[23:1] == 23'h060004);
	wire sel_dsw2      = (io_addr[23:1] == 23'h060005);
	wire sel_nmk004_r  = (io_addr[23:1] == 23'h060007);
	wire sel_flip      = (io_addr[23:1] == 23'h06000A);
	wire sel_nmi       = (io_addr[23:1] == 23'h06000B);
	wire sel_tilebank  = (io_addr[23:1] == 23'h06000C);
	wire sel_nmk004_w  = (io_addr[23:1] == 23'h06000F);

	wire sel_scroll    = (byte_addr >= 24'h0C4000) && (byte_addr <= 24'h0C4007);
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire sel_palette   = (byte_addr >= 24'h0C8000) && (byte_addr <= 24'h0C87FF);
	wire sel_bgvram    = (byte_addr >= 24'h0CC000) && (byte_addr <= 24'h0CFFFF);
	wire sel_txvram    = (byte_addr >= 24'h0D0000) && (byte_addr <= 24'h0D07FF);

	// ------------------------------------------------------------------
	// Protection MCU shared-bus decode — same regions, evaluated
	// against the 20-bit prot_addr instead (see header for why the
	// same constants apply numerically unchanged).
	// ------------------------------------------------------------------
	wire [19:0] prot_addr;
	assign dbg_prot_addr = prot_addr;
	wire        prot_rd, prot_wr;
	wire [7:0]  prot_wdata;
	wire [7:0]  prot_rdata;

	wire prot_sel_rom       = (prot_addr <= 20'h03FFFF);
	wire prot_sel_mainram   = (prot_addr[19:18] == 2'b10);

	wire [19:0] prot_io_addr = prot_addr & ~20'h020000;
	wire prot_sel_in0        = (prot_io_addr[19:1] == 19'h060000);
	wire prot_sel_in1        = (prot_io_addr[19:1] == 19'h060001);
	wire prot_sel_dsw1       = (prot_io_addr[19:1] == 19'h060004);
	wire prot_sel_dsw2       = (prot_io_addr[19:1] == 19'h060005);
	wire prot_sel_nmk004_r   = (prot_io_addr[19:1] == 19'h060007);
	wire prot_sel_flip       = (prot_io_addr[19:1] == 19'h06000A);
	wire prot_sel_nmi        = (prot_io_addr[19:1] == 19'h06000B);
	wire prot_sel_tilebank   = (prot_io_addr[19:1] == 19'h06000C);
	wire prot_sel_nmk004_w   = (prot_io_addr[19:1] == 19'h06000F);

	wire prot_sel_scroll     = (prot_addr >= 20'h0C4000) && (prot_addr <= 20'h0C4007);
	wire prot_sel_palette    = (prot_addr >= 20'h0C8000) && (prot_addr <= 20'h0C87FF);
	wire prot_sel_bgvram     = (prot_addr >= 20'h0CC000) && (prot_addr <= 20'h0CFFFF);
	wire prot_sel_txvram     = (prot_addr >= 20'h0D0000) && (prot_addr <= 20'h0D07FF);

	// ------------------------------------------------------------------
	// ROM (maincpu) — read-only for the protection MCU, same as real
	// ROM silicon; only the CPU's own read path is in the storage
	// section, protection-MCU reads are built in the read-mux section
	// below directly from this same array.
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — protection MCU write given priority
	// on a same-cycle conflict (see header).
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr = byte_addr[15:1];
	reg [15:0] mainram_dout;
	always @(posedge clk_sys) begin
		if (prot_wr & prot_sel_mainram) begin
			if (~prot_addr[0]) mainram[prot_addr[15:1]][15:8] <= prot_wdata;
			else                mainram[prot_addr[15:1]][7:0]  <= prot_wdata;
		end else if (sel_mainram & cpu_write) begin
			if (~UDSn) mainram[mainram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) mainram[mainram_addr][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) mainram_dout = mainram[mainram_addr];

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16) — same protection-MCU priority pattern.
	// ------------------------------------------------------------------
	reg [15:0] palette [0:1023];
	wire [9:0] palette_addr = byte_addr[10:1];
	reg [15:0] palette_dout;
	always @(posedge clk_sys) begin
		if (prot_wr & prot_sel_palette) begin
			if (~prot_addr[0]) palette[prot_addr[10:1]][15:8] <= prot_wdata;
			else                palette[prot_addr[10:1]][7:0]  <= prot_wdata;
		end else if (sel_palette & cpu_write) begin
			if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
			if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) palette_dout = palette[palette_addr];

	// ------------------------------------------------------------------
	// BG tilemap VRAM (8192 x 16) — same protection-MCU priority pattern.
	// ------------------------------------------------------------------
	reg [15:0] bgvram [0:8191];
	wire [12:0] bgvram_addr = byte_addr[13:1];
	always @(posedge clk_sys) begin
		if (prot_wr & prot_sel_bgvram) begin
			if (~prot_addr[0]) bgvram[prot_addr[13:1]][15:8] <= prot_wdata;
			else                bgvram[prot_addr[13:1]][7:0]  <= prot_wdata;
		end else if (sel_bgvram & cpu_write) begin
			if (~UDSn) bgvram[bgvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) bgvram[bgvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] bgvram_dout = bgvram[bgvram_addr];

	// ------------------------------------------------------------------
	// TX tilemap VRAM (1024 x 16) — same protection-MCU priority pattern.
	// ------------------------------------------------------------------
	reg [15:0] txvram [0:1023];
	wire [9:0] txvram_addr = byte_addr[10:1];
	always @(posedge clk_sys) begin
		if (prot_wr & prot_sel_txvram) begin
			if (~prot_addr[0]) txvram[prot_addr[10:1]][15:8] <= prot_wdata;
			else                txvram[prot_addr[10:1]][7:0]  <= prot_wdata;
		end else if (sel_txvram & cpu_write) begin
			if (~UDSn) txvram[txvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) txvram[txvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] txvram_dout = txvram[txvram_addr];

	// ------------------------------------------------------------------
	// Dual-port video read taps — identical to tdragon_core.sv's own.
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
	// I/O registers — protection MCU write given priority on a
	// same-cycle conflict (see header), byte-granular per the
	// reference's own byte-addressed shared-bus access.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg [7:0]  scroll_reg [0:3];
	reg        nmi_level;

	wire [15:0] bg_xscroll = {scroll_reg[0], scroll_reg[1]};
	wire [15:0] bg_yscroll = {scroll_reg[2], scroll_reg[3]};

	integer si;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			nmi_level       <= 1'b0;
			for (si = 0; si < 4; si = si + 1) scroll_reg[si] <= 8'h00;
		end else begin
			if (prot_wr & prot_sel_flip)      flip_screen_reg <= prot_wdata;
			else if (sel_flip & cpu_write & ~LDSn) flip_screen_reg <= oEdb[7:0];

			if (prot_wr & prot_sel_tilebank)      bgbank_reg <= prot_wdata;
			else if (sel_tilebank & cpu_write & ~LDSn) bgbank_reg <= oEdb[7:0];

			if (prot_wr & prot_sel_scroll)
				scroll_reg[prot_addr[2:1]] <= prot_wdata;
			else if (sel_scroll & cpu_write & ~LDSn)
				scroll_reg[scroll_word_idx] <= oEdb[7:0];

			if (prot_wr & prot_sel_nmi)      nmi_level <= prot_wdata[0];
			else if (sel_nmi & cpu_write)    nmi_level <= oEdb[0];
		end
	end

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// NMK004 sound board — identical to tdragon_core.sv's own. The
	// host-to-mcu latch also gets a protection-MCU write branch.
	// ------------------------------------------------------------------
	wire [7:0] nmk004_mcu_to_host;
	wire       nmk004_mcu_to_host_we;
	reg  [7:0] nmk004_host_to_mcu = 8'hFF;
	always @(posedge clk_sys) begin
		if (prot_wr & prot_sel_nmk004_w) nmk004_host_to_mcu <= prot_wdata;
		else if (cpu_write & sel_nmk004_w & ~LDSn) nmk004_host_to_mcu <= oEdb[7:0];
	end

	wire       ym_cs, ym_we, ym_addr_sel;
	wire [7:0] ym_dout;
	wire       oki0_cs, oki0_we, oki1_cs, oki1_we;
	wire [7:0] oki0_dout, oki1_dout;
	wire       oki0_bank_we, oki1_bank_we;
	wire [7:0] oki0_bank, oki1_bank;

	reg [5:0] ym_cen_cnt = 6'd0;
	reg       ym_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (ym_cen_cnt >= 6'd61) begin
			ym_cen_cnt <= ym_cen_cnt + 6'd3 - 6'd64;
			ym_cen <= 1'b1;
		end else begin
			ym_cen_cnt <= ym_cen_cnt + 6'd3;
			ym_cen <= 1'b0;
		end
	end

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

	reg [4:0] oki_cen_cnt = 5'd0;
	wire      oki_cen = (oki_cen_cnt == 5'd31);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 5'd0 : oki_cen_cnt + 5'd1;

	localparam OKI_SS = 1'b0;

	reg [7:0] oki1_rom [0:524287];
	reg [7:0] oki2_rom [0:524287];
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki1_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki2_rom);

	reg [1:0] oki1_bank_r = 2'd0, oki2_bank_r = 2'd0;
	always @(posedge clk_sys) begin
		if (oki0_bank_we) oki1_bank_r <= oki0_bank[1:0];
		if (oki1_bank_we) oki2_bank_r <= oki1_bank[1:0];
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
	// Protection MCU (Family D) — see nmk_prot_core.sv's own header.
	// ------------------------------------------------------------------
	nmk_prot_core #(
		.BOOT_ROM_FILE(PROT_BOOT_FILE)
	) prot_mcu (
		.clk(prot_clk_r), .reset(reset),
		.p7_ext_en_i(1'b0), .p7_ext_val_i(8'h00),
		.bus_addr(prot_addr), .bus_rd(prot_rd), .bus_wr(prot_wr),
		.bus_wdata(prot_wdata), .bus_rdata(prot_rdata),
		.vpos_div4(vt_vcount[9:2]),
		.halt_68k(halt_68k),
		.dbg_pc(dbg_prot_pc), .dbg_valid(dbg_prot_valid),
		.dbg_hl(dbg_prot_hl), .dbg_a(dbg_prot_a), .dbg_de(dbg_prot_de), .dbg_iy(dbg_prot_iy)
	);

	wire [15:0] prot_rom_dout     = rom[prot_addr[18:1]];
	wire [15:0] prot_mainram_dout = mainram[prot_addr[15:1]];
	wire [15:0] prot_palette_dout = palette[prot_addr[10:1]];
	wire [15:0] prot_bgvram_dout  = bgvram[prot_addr[13:1]];
	wire [15:0] prot_txvram_dout  = txvram[prot_addr[10:1]];

	reg [15:0] prot_rdata16;
	always @(*) begin
		if (prot_sel_rom)          prot_rdata16 = prot_rom_dout;
		else if (prot_sel_mainram) prot_rdata16 = prot_mainram_dout;
		else if (prot_sel_palette) prot_rdata16 = prot_palette_dout;
		else if (prot_sel_bgvram)  prot_rdata16 = prot_bgvram_dout;
		else if (prot_sel_txvram)  prot_rdata16 = prot_txvram_dout;
		else if (prot_sel_nmk004_r) prot_rdata16 = {8'h00, nmk004_to_host_latch};
		else if (prot_sel_in0)     prot_rdata16 = IN0_IDLE;
		else if (prot_sel_in1)     prot_rdata16 = IN1_IDLE;
		else if (prot_sel_dsw1)    prot_rdata16 = DSW1_IDLE;
		else if (prot_sel_dsw2)    prot_rdata16 = DSW2_IDLE;
		else                       prot_rdata16 = 16'hFFFF;
	end
	assign prot_rdata = prot_addr[0] ? prot_rdata16[7:0] : prot_rdata16[15:8];

	// ------------------------------------------------------------------
	// Read data mux (68000-side) — identical to tdragon_core.sv's own.
	// ------------------------------------------------------------------
	reg [15:0] rdata;
	always @(*) begin
		if (sel_rom)          rdata = rom_dout;
		else if (sel_mainram) rdata = mainram_dout;
		else if (sel_palette) rdata = palette_dout;
		else if (sel_bgvram)  rdata = bgvram_dout;
		else if (sel_txvram)  rdata = txvram_dout;
		else if (sel_nmk004_r) rdata = {8'h00, nmk004_to_host_latch};
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else                  rdata = 16'hFFFF;
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + real interrupt generation — identical to
	// tdragon_core.sv's own (same V-PROM, same nmk_irq instance).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	assign dbg_vt_vcount = vt_vcount;
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
	// Video pipeline — reused unchanged from tdragon (see header).
	// ------------------------------------------------------------------
	video_tdragon #(
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
