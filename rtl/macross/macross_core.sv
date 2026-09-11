// NMK16 MiSTerFPGA project — macross hardware family (Tier 2's own
// Family D: TLCS-90 shared-RAM protection MCU, NMK-215/TMP90840
// variant). The third Family D game, after tdragon1/hachamf, and the
// first to add the dual-NMK214 GFX descrambler on top of the base
// protection mechanism.
//
// Confirmed directly from the reference: `macross_prot()` (nmk16.cpp:
// 5707) calls `macross(config)` FIRST, then `base_nmk214_215(config)` —
// same "protection is a pure addition on top of unprotected hardware"
// pattern as tdragon1/hachamf's own `tdragon_prot()`/`hachamf_prot()`.
// `macross()`'s own memory map (`macross_map`, nmk16.cpp:985) is
// address-identical to hachamf()'s own (same base offsets for IN0/IN1/
// DSW/NMK004/flip/tilebank/palette/scroll/bgvram/txvram/mainram — this
// file's own address-decode section is therefore hachamf_core.sv's own,
// unchanged), and macross's own clock ratio (68000 @10MHz, NMK004
// @8MHz) is hachamf's own too — so this file's clock generation and
// base 68000/NMK004/sound wiring are hachamf_core.sv's own, unchanged.
// `video_macross.sv` is a genuine new module though: same base tilemap
// architecture as `video_hachamfb.sv`/`video_tdragon.sv`, but macross's
// own bgtile ROM is 2MB (double blkheart/tdragon/hachamf's own 1MB),
// needing a 14-bit BG tile code, and both bgtile/sprites are
// descrambled through two `nmk214` instances (see that module's own
// header) — the protection mechanism this variant actually adds.
//
// Genuinely new versus tdragon1_core.sv/hachamf_core.sv's own
// protection-MCU wiring:
//   - The protection MCU itself is a **TMP90840** (NMK-215), not
//     tdragon1/hachamf's own TMP91640 — same on-chip peripheral
//     register map (see nmk_prot_core.sv's own header), but a smaller
//     internal ROM (8KB, confirmed from ROM_START(macross)'s own
//     `protcpu` region: `nmk-215.bin`, 0x2000 bytes) and RAM (256B at
//     0xfec0-0xffbf, not 512B at 0xfdc0-0xffbf) — wired via
//     nmk_prot_core.sv's new `ROM_SIZE`/`RAM_BASE`/`RAM_SIZE`
//     parameters (added this session specifically for this variant;
//     tdragon1/hachamf's own instantiations keep the defaults, which
//     match their own TMP91640 unchanged).
//   - **Dual-NMK214 config load**: the reference's own
//     `mcu_port3_to_214_w`/`mcu_port7_to_214_w` (nmk16.cpp:5640-5679) —
//     a P7-write-then-P3-strobe handshake that loads one shared init
//     byte into both on-board NMK214 chips at once — is exposed by
//     nmk_prot_core.sv as `nmk214_cfg_we`/`nmk214_cfg_data` (new this
//     session), wired here directly into `video_macross.sv`'s own two
//     `nmk214` instances (kept out of nmk_prot_core.sv itself, which
//     stays GFX-agnostic — every other protection-MCU game has no
//     NMK214s at all).
//   - No P7 external-read override needed (macross's own NMK-215 ROM is
//     dedicated, not a shared multi-game firmware image like hachamf's
//     own NMK-113) — `P7_EXT_EN` stays at its default off.
//
// ROMs: maincpu (921a03, WORD_SWAP, 0x80000), nmk004 (921a02, 0x10000),
// fgtile (921a01, 0x20000 — NOT descrambled, see video_macross.sv's own
// header), protcpu (nmk-215.bin, 0x2000), bgtile (921a04, 0x200000,
// concat-mode extraction — single ROM_LOAD, no interleaving),
// sprites (921a07, word_swap-mode extraction, 0x200000), oki1/oki2
// (921a05/921a06, 0x80000 each), htiming/vtiming (921a08/921a09). The
// "color" PROM (921a10, 0x20 bytes) is confirmed unused anywhere in the
// reference's own driver code (`grep -rn 'memregion("color")'` — zero
// hits across the whole file, for macross or any other romset that
// carries this same vestigial region) — not modeled, same "don't build
// RTL for a MAME-side stub" precedent as tlcs90.sv's own TSET/LDA.
module macross_core #(
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
	input  [12:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [9:0]  dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables — identical to hachamf_core.sv's own (same 40MHz
	// clk_sys / 10MHz 68000 / 8MHz NMK004 / 4MHz protcpu architecture).
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
	// tdragon1_core.sv's/hachamf_core.sv's own.
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
	// Address decode — identical to hachamf_core.sv's own (macross_map
	// and hachamf's own map share the same address layout, confirmed
	// directly from nmk16.cpp — see this file's own header).
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
	wire sel_scroll    = (byte_addr >= 24'h08C000) && (byte_addr <= 24'h08C007);
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire sel_bgvram    = (byte_addr >= 24'h090000) && (byte_addr <= 24'h093FFF);
	wire sel_txvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09C7FF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// Protection MCU shared-bus decode — same regions, evaluated
	// against the 20-bit prot_addr (see tdragon1_core.sv's own header
	// for why the same constants apply numerically unchanged).
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
	wire prot_sel_scroll    = (prot_addr >= 20'h08C000) && (prot_addr <= 20'h08C007);
	wire prot_sel_bgvram    = (prot_addr >= 20'h090000) && (prot_addr <= 20'h093FFF);
	wire prot_sel_txvram    = (prot_addr >= 20'h09C000) && (prot_addr <= 20'h09C7FF);
	wire prot_sel_mainram   = (prot_addr >= 20'h0F0000) && (prot_addr <= 20'h0FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu) — 0x80000 bytes = 262144 words (double hachamf's own
	// 0x40000 — macross's own maincpu ROM is a single full-size
	// ROM_LOAD16_WORD_SWAP, confirmed from ROM_START(macross)). Read-only
	// for the protection MCU, same as real ROM.
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — protection MCU write given priority
	// on a same-cycle conflict (see tdragon1_core.sv's own header).
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
	// Dual-port video read taps — identical to hachamf_core.sv's own.
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
	// same-cycle conflict, byte-granular per the reference's own
	// byte-addressed shared-bus access.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg [7:0]  scroll_reg [0:3]; // [Xhi,Xlo,Yhi,Ylo] — single BG layer here
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
	// NMK004 sound board — identical to hachamf_core.sv's own. The
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

	// ------------------------------------------------------------------
	// YM2203 — real jt03. 1.5MHz from 40MHz clk_sys: 1.5/40 = 3/80
	// exactly — same accumulator as hachamf_core.sv's own.
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
	// OKIM6295 x2 — real jt6295. 1MHz from 40MHz clk_sys is an exact
	// /40, same as hachamf_core.sv's own.
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
	// mustang_core.sv's own oki_phys_addr().
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
	// Protection MCU (Family D, TMP90840/NMK-215 variant) — see
	// rtl/tlcs90/nmk_prot_core.sv's own header and this file's own
	// header for the ROM/RAM sizing and dual-NMK214 config-load wiring.
	// ------------------------------------------------------------------
	wire nmk214_cfg_we;
	wire [7:0] nmk214_cfg_data;

	nmk_prot_core #(
		.BOOT_ROM_FILE(PROT_BOOT_FILE),
		.ROM_SIZE(8192), .RAM_BASE(16'hfec0), .RAM_SIZE(256)
	) prot_mcu (
		.clk(prot_clk_r), .reset(reset),
		.p7_ext_en_i(1'b0), .p7_ext_val_i(8'h00),
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
	// Read data mux (68000-side) — identical to hachamf_core.sv's own.
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
	// hachamf_core.sv's own (same V-PROM, same nmk_irq instance).
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
	// Video pipeline — see video_macross.sv's own header for the
	// dual-NMK214 descramble wiring and 14-bit BG tile code.
	// ------------------------------------------------------------------
	video_macross #(
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
