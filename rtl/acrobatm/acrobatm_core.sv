// NMK16 MiSTerFPGA project — acrobatm hardware family (Tier 2, NMK004
// boards) system-level integration.
//
// The fifth Tier 2 NMK004-board game, after mustang, bioship, blkheart,
// and strahl (see those modules' own headers for the shared 68000/
// NMK004/jt03/jt6295/nmk_irq integration architecture this reuses
// wholesale). acrobatm is a genuine hybrid of two prior ports: its
// video family is *identical* to blkheart's own (`screen_update_macross`,
// `VIDEO_START_MEMBER(macross)`, `gfx_macross` — same single-BG-layer-
// plus-TX layout, same BG tile-code bank extension via `tilebank_w`,
// same palette color bases), while its CPU/NMK004 clock ratio is
// *identical* to bioship's own (10MHz 68000 against NMK004's unchanged
// 8MHz) — so `rtl/acrobatm/video_acrobatm.sv` is a close derivative of
// `video_blkheart.sv`, and this file's own clock-enable section reuses
// bioship_core.sv's own 40MHz `clk_sys` architecture verbatim. The one
// genuinely new thing here is the memory map itself, which is laid out
// completely differently from every prior port. Real differences below.
//
// Real, substantive differences from mustang_core.sv (and, where noted,
// blkheart_core.sv/bioship_core.sv):
//   - **The memory map is laid out completely differently** — not a
//     copy-paste variation of any prior port's own addresses (see
//     `acrobatm_map` in nmk16.cpp): main work RAM sits at
//     `0x080000-0x08FFFF` (every prior port's own is `0xF0000-0xFFFFF`
//     — i.e. right after the ROM here, not at the very top of the
//     address space), while the I/O/register block (IN0/IN1/DSW1/DSW2/
//     NMK004 latches/flip/NMI/tilebank) sits at `0xC0000+` (every prior
//     port's own is `0x80000+`). Confirmed bit-alignment directly
//     before relying on plain `byte_addr[N:1]` slicing for each region
//     (every region base here happens to still be cleanly aligned to
//     its own size, same convenient property every prior port's own
//     memory map had — checked, not assumed).
//   - **Palette RAM is 768 entries, not the family's usual 1024**
//     (`PALETTE(config, m_palette).set_format(...,768)` — confirmed
//     against `acrobatm_map`'s own palette region size, `0xC4000-
//     0xC45FF` = 0x600 bytes = 768 words exactly, matching).
//   - **BG tile-code bank extension**, same mechanism as blkheart's own
//     `tilebank_w` (byte @0xC0019 here, not blkheart's 0x080019) —
//     acrobatm's own "bgtile" ROM is 0x100000 bytes (8192 tiles),
//     double the 4096-tile range a bare 12-bit VRAM tile code
//     addresses, same as blkheart's own reasoning exactly.
//   - **The 68000 runs at 10MHz**, not mustang's/blkheart's own 8MHz —
//     same rate and same `clk_sys` derivation as bioship's own (40MHz
//     `clk_sys`, /4=10MHz 68000, /5=8MHz NMK004+pixel, /40=1MHz OKI
//     cen, 3/80 YM2203 accumulator) — reused verbatim, not re-derived,
//     since the underlying clock relationship is identical to bioship's.
//   - A real V-PROM DOES exist for this game (`nmk_irq:vtiming`,
//     `11.ic80`) — same CRC (`633ab1c9`) as mustang's own `10.bpr`,
//     confirming (yet again) this is genuinely shared PROM content
//     across the family, not a new table — so `rtl/nmk_irq/nmk_irq.sv`
//     is reused unchanged, just fed acrobatm's own dumped copy.
//   - Sprite ROM (`0x180000`, two plain-`ROM_LOAD`-concatenated files of
//     different sizes — 0x100000 + 0x080000, not same-size chips) needs
//     no RTL changes, same "sprite code is a full 16-bit value, not
//     bank-limited" reasoning strahl's own header already established.
//   - `nmk004_x0016_w` uses the STANDARD NMI polarity (same as mustang/
//     blkheart, unlike bioship's own inverted variant).
//   - Main work RAM uses a plain, byte-lane-respecting write here too
//     (no write-handler override in `acrobatm_map` at all) — same as
//     strahl's own convention, not mustang's `mainram_strange_w` quirk.
//
// Memory map (see acrobatm_map in mame/src/mame/nmk/nmk16.cpp):
//   000000-03FFFF  ROM (maincpu, 0x40000 region, 2 x 0x20000-byte chips)
//   080000-08FFFF  main work RAM, 32768 x 16 — plain masked write
//   0C0000-0C0001  IN0 (R)
//   0C0002-0C0003  IN1 (R)
//   0C0008-0C0009  DSW1 (R)
//   0C000A-0C000B  DSW2 (R)
//   0C000F         NMK004 host-read latch (R, byte)
//   0C0015         flipscreen_w (W, byte)
//   0C0016-0C0017  nmk004_x0016_w (W, word) — standard NMI polarity
//   0C0019         tilebank_w (W, byte) — BG tile-code bit 12 (bgbank)
//   0C001F         NMK004 host-write latch (W, byte)
//   0C4000-0C45FF  palette RAM, 768 x 16
//   0C8000-0C8007  scroll_w<0> (BG X/Y scroll, byte-sequenced, ~LDSn)
//   0CC000-0CFFFF  BG tilemap VRAM, 8192 x 16
//   0D4000-0D47FF  tx tilemap VRAM, 1024 x 16
//
// Known simplifications: identical to mustang_core.sv's own list (DTACKn
// tied to ASn, jt03/jt6295 write-stretch, jt6295 rom_ok tied high,
// NMK004 fed a genuine divided clock rather than a clock-enable, IN0/
// IN1/DSW1/DSW2 tied to fixed idle values) — see that module's header
// for the full rationale, not repeated here since none of it changed.
module acrobatm_core #(
	parameter ROM_FILE      = "",
	parameter NMK004_BOOT_FILE = "",
	parameter NMK004_EXT_FILE  = "",
	parameter OKI1_ROM_FILE = "",
	parameter OKI2_ROM_FILE = "",
	parameter VTIMING_FILE  = "",
	parameter FGTILE_FILE   = "",
	parameter BGTILE_FILE   = "",
	parameter SPRITES_FILE  = ""
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
	input  [12:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [9:0]  dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables — same 40MHz clk_sys architecture as bioship_core.sv
	// (10MHz/8MHz 68000/NMK004 ratio, identical to acrobatm's own).
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [2:0] nmk004_div = 3'd0;
	always @(posedge clk_sys)
		nmk004_div <= reset ? 3'd0 : (nmk004_div == 3'd4 ? 3'd0 : nmk004_div + 3'd1);
	wire nmk004_clk_r = (nmk004_div < 3'd2);

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

	wire iack_cycle = FC0 & FC1 & FC2 & ~ASn;
	wire VPAn = ~iack_cycle;
	wire DTACKn = ASn | iack_cycle;

	// NMK004's own P4 bit0 drives the 68000's reset line — same real
	// hold-then-release handshake as mustang_core.sv.
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
	// Address decode — see header for the memory map, and its own note
	// on why plain byte_addr[N:1] slicing is still safe (every region
	// base checked to be size-aligned).
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h03FFFF);
	wire sel_mainram   = (byte_addr >= 24'h080000) && (byte_addr <= 24'h08FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h060000); // 0C0000/0C0001
	wire sel_in1       = (byte_addr[23:1] == 23'h060001); // 0C0002/0C0003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h060004); // 0C0008/0C0009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h060005); // 0C000A/0C000B
	wire sel_nmk004_r  = (byte_addr[23:1] == 23'h060007); // 0C000E/0C000F word
	wire sel_flip      = (byte_addr[23:1] == 23'h06000A); // 0C0014/0C0015, LDS=low byte
	wire sel_nmi       = (byte_addr[23:1] == 23'h06000B); // 0C0016/0C0017
	wire sel_tilebank  = (byte_addr[23:1] == 23'h06000C); // 0C0018/0C0019, LDS=low byte
	wire sel_nmk004_w  = (byte_addr[23:1] == 23'h06000F); // 0C001E/0C001F word
	wire sel_palette   = (byte_addr >= 24'h0C4000) && (byte_addr <= 24'h0C45FF);
	wire sel_scroll    = (byte_addr >= 24'h0C8000) && (byte_addr <= 24'h0C8007);
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire sel_bgvram    = (byte_addr >= 24'h0CC000) && (byte_addr <= 24'h0CFFFF);
	wire sel_txvram    = (byte_addr >= 24'h0D4000) && (byte_addr <= 24'h0D47FF);

	// ------------------------------------------------------------------
	// ROM (maincpu)
	// ------------------------------------------------------------------
	reg [15:0] rom [0:131071]; // 0x20000 words = 0x40000 bytes
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[17:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — plain masked write, NOT mustang's own
	// mainram_strange_w quirk (see header — same convention as strahl's own).
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
	// Palette RAM (768 x 16, not the family's usual 1024 — see header)
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
	// BG tilemap VRAM (8192 x 16) — plain masked writes (COMBINE_DATA)
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
	// Dual-port video read taps — video_acrobatm.sv's own live, per-pixel
	// reads into the same arrays above (acrobatm_core.sv owns the
	// storage, matching mustang_core.sv's own established split).
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
	// I/O registers (write-captured only, see header)
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
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank & ~LDSn) bgbank_reg       <= oEdb[7:0];
			if (sel_scroll & ~LDSn)   scroll_reg[scroll_word_idx] <= oEdb[7:0];
			// nmk004_x0016_w: standard polarity, same as mustang_core.sv.
			if (sel_nmi)              nmi_level       <= oEdb[0];
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
	// exactly — same accumulator as bioship_core.sv's own.
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
	// OKIM6295 x2 — real jt6295. Reference uses XTAL(16'000'000)/4=4MHz
	// for both chips here (same 4MHz target as every prior port). 1MHz
	// from 40MHz clk_sys is an exact /40, same as bioship_core.sv's own.
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
	// Read data mux
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
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing (rtl/bjtwin/video_timing.sv, reused unchanged — same
	// "lowres" family geometry every prior port already uses) + real
	// interrupt generation (rtl/nmk_irq/nmk_irq.sv, driven by
	// acrobatm's own dumped V-PROM — see header, a real one exists).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);

	wire sprite_dma_trigger; // consumed by video_acrobatm below
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
	// rtl/acrobatm/video_acrobatm.sv's own header for the full derivation.
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
