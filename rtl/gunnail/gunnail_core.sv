// NMK16 MiSTerFPGA project — gunnail hardware family (Tier 2's own
// Family D: TLCS-90 shared-RAM protection MCU, NMK-215/TMP90840
// variant). macross's own sibling — same protection mechanism
// (`gunnail_prot()`, nmk16.cpp, calls `gunnail(config)` then
// `base_nmk214_215(config)`, the identical dual-NMK214 config-load
// wiring macross uses), and gunnail's own protection ROM (`nmk-215.bin`)
// is the byte-identical file to macross's own (same CRC, `d355a06f`) —
// literally the same protection-MCU firmware, so all of this file's own
// protection-MCU/NMK214 wiring is copied verbatim from macross_core.sv.
//
// Confirmed directly from the reference (`gunnail_map`, nmk16.cpp:1022,
// diffed byte-for-byte against `macross_map`) — the ONLY real
// differences from macross_core.sv:
//   - Scroll registers: gunnail replaces macross's own single 4-byte
//     `scroll_w<0>` register at 0x08c000-0x08c007 with two independent
//     256-word write-only RAM arrays, `gunnail_scrollram`
//     (0x08c000-0x08c1ff) and `gunnail_scrollramy` (0x08c200-0x08c3ff)
//     — real per-scanline raster scroll tables, see video_gunnail.sv's
//     own header for how they're consumed.
//   - TX VRAM is 0x09c000-0x09cfff (2048 words, double macross's own
//     1024) with a `.mirror(0x001000)` — matches `VIDEO_START_MEMBER
//     (nmk16_state,gunnail)` calling `VIDEO_START_CALL_MEMBER(macross2)`
//     first (nmk16_v.cpp:164), which creates a 64x32-tile TX tilemap
//     (`TILEMAP_SCAN_COLS,8,8,64,32`), not macross's own 32x32 — see
//     video_gunnail.sv's own header for the wraparound-tilemap
//     consequence.
//   - `m_mainram` is a plain `.ram()` here (no `mainram_strange_w`
//     wrapper) — a non-issue: macross_core.sv's own mainram write is
//     already a plain byte-granular write regardless (copied verbatim).
//
// Everything else (68000/NMK004/sound clock architecture, address-decode
// base offsets, ROM/RAM storage, protection-MCU shared-bus wiring) is
// macross_core.sv's own, unchanged — confirmed the two memory maps share
// every other offset exactly.
//
// ROMs: maincpu (3e.u131/3o.u133, ROM_LOAD16_BYTE — byte-interleaved,
// NOT macross's own single WORD_SWAP file — see tools/mkgfxrom.py's
// `interleave` mode), nmk004 (92077_2.u101, 0x10000), fgtile (1.u21,
// 0x20000 — not descrambled), protcpu (nmk-215.bin, 0x2000, byte-
// identical to macross's own), bgtile (92077-4.u19, 0x100000 — HALF
// macross's own 2MB, so a 13-bit BG tile code like blkheart/tdragon's
// own, not macross's own 14-bit — see video_gunnail.sv), sprites
// (92077-7.u134, word_swap-mode, 0x200000 — same size as macross's
// own), oki1/oki2 (92077-5/6, 0x80000 each), htiming/vtiming
// (8_82s129.u35/... ).
module gunnail_core #(
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
	input clk_sys,       // 40 MHz (68000 bus clk_sys/4=10MHz; NMK004/pixel/raster clk_sys/5=8MHz; protcpu clk_sys/10=4MHz)
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
	output  [7:0] dbg_prot_int_ram_at_hl,
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
	input  [13:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables — identical to macross_core.sv's own.
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [2:0] nmk004_div = 3'd0;
	always @(posedge clk_sys)
		nmk004_div <= reset ? 3'd0 : (nmk004_div == 3'd4 ? 3'd0 : nmk004_div + 3'd1);
	wire nmk004_clk_r = (nmk004_div < 3'd2);

	reg [3:0] prot_div = 4'd0;
	always @(posedge clk_sys)
		prot_div <= reset ? 4'd0 : (prot_div == 4'd9 ? 4'd0 : prot_div + 4'd1);
	wire prot_clk_r = (prot_div < 4'd5); // 40MHz/10 = 4MHz

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// ------------------------------------------------------------------
	// fx68k — HALTn driven by the protection MCU, identical to
	// macross_core.sv's own.
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
	// Address decode — identical base offsets to macross_core.sv's own
	// (see this file's own header for the scroll/TX-VRAM deltas).
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h07FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1       = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040004); // 080008/080009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h040005); // 08000A/08000B
	wire sel_nmk004_r  = (byte_addr[23:1] == 23'h040007); // 08000E/08000F word
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015, LDS=low byte
	wire sel_nmi       = (byte_addr[23:1] == 23'h04000B); // 080016/080017
	wire sel_tilebank  = (byte_addr[23:1] == 23'h04000C); // 080018/080019, LDS=low byte
	wire sel_nmk004_w  = (byte_addr[23:1] == 23'h04000F); // 08001E/08001F word
	wire sel_palette   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h0887FF);
	// gunnail_scrollram/gunnail_scrollramy — 256 words each, write-only
	// in the reference (no read path modeled, matching that).
	wire sel_scrollram  = (byte_addr >= 24'h08C000) && (byte_addr <= 24'h08C1FF);
	wire sel_scrollramy = (byte_addr >= 24'h08C200) && (byte_addr <= 24'h08C3FF);
	wire sel_bgvram    = (byte_addr >= 24'h090000) && (byte_addr <= 24'h093FFF);
	// TX VRAM: 0x09c000-0x09cfff (2048 words), mirrored at +0x1000 —
	// both ranges alias the same array.
	wire sel_txvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09DFFF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// Protection MCU shared-bus decode — same regions, against the
	// 20-bit prot_addr (see macross_core.sv's own header).
	// ------------------------------------------------------------------
	wire [19:0] prot_addr;
	assign dbg_prot_addr = prot_addr;
	wire        prot_rd, prot_wr;
	wire [7:0]  prot_wdata;
	wire [7:0]  prot_rdata;

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
	// ROM (maincpu) — 0x80000 bytes = 262144 words, same size as
	// macross's own. Read-only for the protection MCU, same as real ROM.
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — protection MCU write given priority
	// on a same-cycle conflict (see macross_core.sv's own header — a
	// plain write here regardless of the reference's own
	// mainram_strange_w/plain-ram naming, matching macross_core.sv's own
	// already-verified behavior exactly).
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
	// TX tilemap VRAM (2048 x 16, double macross's own — see header).
	// Address decode ignores the mirror bit (byte_addr[12]) so both the
	// 0x09c000 and 0x09d000 windows alias the same array, matching the
	// reference's own `.mirror(0x001000)`.
	// ------------------------------------------------------------------
	reg [15:0] txvram [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	always @(posedge clk_sys) begin
		if (prot_wr & prot_sel_txvram) begin
			if (~prot_addr[0]) txvram[prot_addr[11:1]][15:8] <= prot_wdata;
			else                txvram[prot_addr[11:1]][7:0]  <= prot_wdata;
		end else if (sel_txvram & cpu_write) begin
			if (~UDSn) txvram[txvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) txvram[txvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] txvram_dout = txvram[txvram_addr];

	// ------------------------------------------------------------------
	// gunnail_scrollram / gunnail_scrollramy (256 x 16 each, write-only
	// in the reference) — real per-scanline raster X/Y scroll tables,
	// see video_gunnail.sv's own header for the consuming formula.
	// ------------------------------------------------------------------
	reg [15:0] scrollram  [0:255];
	reg [15:0] scrollramy [0:255];
	wire [7:0] scrollram_waddr  = byte_addr[8:1];
	wire [7:0] scrollramy_waddr = byte_addr[8:1];
	always @(posedge clk_sys) begin
		if (prot_wr & prot_sel_scrollram) begin
			if (~prot_addr[0]) scrollram[prot_addr[8:1]][15:8] <= prot_wdata;
			else                scrollram[prot_addr[8:1]][7:0]  <= prot_wdata;
		end else if (sel_scrollram & cpu_write) begin
			if (~UDSn) scrollram[scrollram_waddr][15:8] <= oEdb[15:8];
			if (~LDSn) scrollram[scrollram_waddr][7:0]  <= oEdb[7:0];
		end
		if (prot_wr & prot_sel_scrollramy) begin
			if (~prot_addr[0]) scrollramy[prot_addr[8:1]][15:8] <= prot_wdata;
			else                scrollramy[prot_addr[8:1]][7:0]  <= prot_wdata;
		end else if (sel_scrollramy & cpu_write) begin
			if (~UDSn) scrollramy[scrollramy_waddr][15:8] <= oEdb[15:8];
			if (~LDSn) scrollramy[scrollramy_waddr][7:0]  <= oEdb[7:0];
		end
	end
	// Video-side read taps — see video_gunnail.sv's own header: it needs
	// scrollram[0]/scrollramy[0] (fixed) plus scrollram[16+row]/
	// scrollramy[row] (row-indexed, driven by the video module).
	wire [7:0] vid_scrollram_row_addr;
	wire [7:0] vid_scrollramy_row_addr;
	wire [15:0] vid_scrollram_0    = scrollram[0];
	wire [15:0] vid_scrollramy_0   = scrollramy[0];
	wire [15:0] vid_scrollram_row  = scrollram[vid_scrollram_row_addr];
	wire [15:0] vid_scrollramy_row = scrollramy[vid_scrollramy_row_addr];

	// ------------------------------------------------------------------
	// Dual-port video read taps — identical to macross_core.sv's own.
	// ------------------------------------------------------------------
	wire [13:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout = bgvram[vid_bgvram_addr[12:0]];
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout = txvram[vid_txvram_addr];
	wire [9:0]  vid_palette_addr;
	wire [15:0] vid_palette_dout = palette[vid_palette_addr];
	wire [9:0]  vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout = palette[vid_spr_palette_addr];
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout = mainram[vid_mainram_addr];

	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bgvram_data = bgvram[dbg_bgvram_addr[12:0]];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers — protection MCU write given priority on a
	// same-cycle conflict, byte-granular per the reference's own
	// byte-addressed shared-bus access. No static scroll_reg here (see
	// header) — bg_bank (tilebank_w) is the only register left.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg        nmi_level;

	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			nmi_level       <= 1'b0;
		end else begin
			if (prot_wr & prot_sel_flip)      flip_screen_reg <= prot_wdata;
			else if (sel_flip & cpu_write & ~LDSn) flip_screen_reg <= oEdb[7:0];

			if (prot_wr & prot_sel_tilebank)      bgbank_reg <= prot_wdata;
			else if (sel_tilebank & cpu_write & ~LDSn) bgbank_reg <= oEdb[7:0];

			if (prot_wr & prot_sel_nmi)      nmi_level <= prot_wdata[0];
			else if (sel_nmi & cpu_write)    nmi_level <= oEdb[0];
		end
	end

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// NMK004 sound board — identical to macross_core.sv's own.
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

	// ------------------------------------------------------------------
	// YM2203 — real jt03. Identical to macross_core.sv's own.
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
	// OKIM6295 x2 — real jt6295. Identical to macross_core.sv's own.
	// ------------------------------------------------------------------
	reg [5:0] oki_cen_cnt = 6'd0;
	wire      oki_cen = (oki_cen_cnt == 6'd39);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 6'd0 : oki_cen_cnt + 6'd1;

	localparam OKI_SS = 1'b0; // PIN7_LOW, same as macross

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
	// Protection MCU (Family D, TMP90840/NMK-215 variant) — identical to
	// macross_core.sv's own instantiation (same firmware, byte-identical
	// ROM — see this file's own header).
	// ------------------------------------------------------------------
	wire nmk214_cfg_we;
	wire [7:0] nmk214_cfg_data;

	nmk_prot_core #(
		.BOOT_ROM_FILE(PROT_BOOT_FILE),
		.ROM_SIZE(8192), .RAM_BASE(16'hfec0), .RAM_SIZE(256)
	) prot_mcu (
		.clk(prot_clk_r), .reset(reset),
		.bus_addr(prot_addr), .bus_rd(prot_rd), .bus_wr(prot_wr),
		.bus_wdata(prot_wdata), .bus_rdata(prot_rdata),
		.vpos_div4(vt_vcount[9:2]),
		.halt_68k(halt_68k),
		.nmk214_cfg_we(nmk214_cfg_we), .nmk214_cfg_data(nmk214_cfg_data),
		.dbg_pc(dbg_prot_pc), .dbg_valid(dbg_prot_valid),
		.dbg_hl(dbg_prot_hl), .dbg_a(dbg_prot_a), .dbg_de(dbg_prot_de), .dbg_iy(dbg_prot_iy),
		.dbg_int_ram_at_hl(dbg_prot_int_ram_at_hl)
	);

	wire [15:0] prot_rom_dout     = rom[prot_addr[18:1]];
	wire [15:0] prot_mainram_dout = mainram[prot_addr[15:1]];
	wire [15:0] prot_palette_dout = palette[prot_addr[10:1]];
	wire [15:0] prot_bgvram_dout  = bgvram[prot_addr[13:1]];
	wire [15:0] prot_txvram_dout  = txvram[prot_addr[11:1]];

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
	// Read data mux (68000-side) — identical to macross_core.sv's own.
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
	// macross_core.sv's own (same shared video_timing/nmk_irq modules —
	// see docs/tier2-system.md's own established finding that this
	// project's single 8MHz/512-wide raster timing model is reused
	// unchanged regardless of MAME's own lowres/hires screen-config
	// split; gunnail is the first port to use set_screen_hires()
	// directly, but needs no new timing module for it).
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
		.reset(reset),
		.line_start(vt_line_start),
		.vcount(vt_vcount),
		.iack_cycle(iack_cycle),
		.iack_level(eab[3:1]),
		.ipl_level(ipl_level),
		.sprite_dma_trigger(sprite_dma_trigger)
	);

	// ------------------------------------------------------------------
	// Video pipeline — see video_gunnail.sv's own header for the
	// per-scanline raster scroll and wide-TX-tilemap wraparound wiring.
	// ------------------------------------------------------------------
	video_gunnail #(
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
		.bg_bank(bgbank_reg),
		.nmk214_cfg_we(nmk214_cfg_we), .nmk214_cfg_data(nmk214_cfg_data),
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
