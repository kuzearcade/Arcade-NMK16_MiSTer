// NMK16 MiSTerFPGA project — strahl hardware family (Tier 2, NMK004
// boards) system-level integration.
//
// The fourth Tier 2 NMK004-board game, after mustang, bioship, and
// blkheart (see those modules' own headers for the shared 68000/NMK004/
// jt03/jt6295 integration architecture this reuses wholesale). strahl
// is video-layout-wise a simplified version of bioship's own 3-layer
// shape (BG0 opaque + BG1 transparent + TX transparent), but BOTH BG
// layers here are plain VRAM tilemaps (no ROM-tile-index/bank-select
// complexity at all — see `rtl/strahl/video_strahl.sv`'s own header),
// and it has a genuinely different clock architecture and interrupt
// source from every prior port. Real differences below.
//
// Real, substantive differences from mustang_core.sv (and, where noted,
// bioship_core.sv/blkheart_core.sv):
//   - **No real V-PROM-driven interrupt timing exists for this game at
//     all.** strahl's own machine config (`nmk16.cpp`) calls
//     `set_hacky_interrupt_timing`, not `set_interrupt_timing` — MAME's
//     OWN fixed-scanline substitute (`nmk16_hacky_scanline`,
//     nmk16.cpp:4482-4511), not the real dual-PROM `NMK_IRQ` device.
//     Confirmed directly: strahl's own `ROM_START` has no
//     `nmk_irq:vtiming`/`nmk_irq:htiming` region at all — there is no
//     real PROM to dump. `rtl/nmk_irq/nmk_irq.sv` (the real state
//     machine every prior port used) genuinely doesn't apply here; this
//     module instead reuses `rtl/bjtwin/nmk_irq_hacky.sv` (Tier 1's own
//     synthetic fixed-scanline generator, already used for
//     cactus/sabotenb) UNCHANGED — its own hardcoded constants
//     (SL_IRQ2=16, SL_IRQ1_A=68, SL_IRQ1_B=196, SL_IRQ4=240,
//     SL_SPRDMA=242) already match `nmk16_hacky_scanline`'s own
//     computed values exactly (VBIN=16, IRQ1_1=16+52=68,
//     IRQ1_2=68+128=196, VBOUT=16+224=240, SPRDMA=240+2=242) — this
//     project's own Tier 1 module was built directly against that same
//     MAME function, so this is a genuine, verified drop-in reuse, not
//     a coincidence. Zero RTL changes needed for this piece.
//   - **The 68000 runs at 12MHz** (`M68000(config, m_maincpu, 12000000);
//     // 12 MHz ?` — MAME's own comment flags this as unverified/best-
//     guess) while NMK004/OKI/YM2203 stay at the other ports' own
//     nominal rates (8MHz/4MHz/1.5MHz). 12 and 8 share no clean
//     power-of-2 divisor, so `clk_sys` is 48MHz here: /4=12MHz (68000,
//     same clean divide-by-4 pattern), /6=8MHz (NMK004 + pixel/raster
//     clock — a genuine 6-cycle counter, 3-high/3-low this time since 6
//     is even, unlike bioship's own 5-cycle 2-high/3-low), /48=1MHz
//     (OKI cen), and — unlike every prior port's own fractional YM2203
//     accumulator — 1.5MHz divides 48MHz *exactly* (48/32=1.5MHz), so a
//     plain mod-32 counter suffices, no phase accumulator needed at all.
//   - **BG1 is a second, independent VRAM tilemap** (`common_get_bg_
//     tile_info<1,3>`, `bgvideoram1`), not bioship's own ROM-tile-index
//     BG0 — no tile-code bank register, no scene-select register, no
//     `tilerom`. Both BG layers get independent X+Y scroll via the
//     generic `scroll_w<Layer>` template (same as bioship/blkheart),
//     gated on `~LDSn` (the *lower* byte lane — matching blkheart's own
//     convention, not bioship's `~UDSn`).
//   - **`m_sprdma_base` is 0xF000, not the family's usual default
//     0x8000** (`nmk16_v.cpp`: `VIDEO_START_MEMBER(strahl)` sets
//     `m_sprdma_base = 0xf000;`) — sprite RAM lives at mainram *word*
//     offset `0xF000/2 = 0x7800`, not the `0x4000` every prior port's
//     own sprite-snapshot logic hardcoded. `video_strahl.sv`'s own
//     sprite-snapshot FSM takes this as a fixed constant matching
//     strahl specifically (not yet a module parameter — no other
//     currently-ported game needs a different value).
//   - **Main work RAM uses a plain, byte-lane-respecting write**, not
//     mustang's own `mainram_strange_w` unconditional-full-word quirk —
//     `strahl_map` maps `0xf0000-0xfffff` with bare `.ram()`, no write
//     handler override at all, meaning standard `COMBINE_DATA`
//     semantics (matching `bjtwin_core.sv`'s own correct byte-lane-
//     gated mainram write, not mustang's own deliberately-quirky one —
//     see mustang_core.sv's header for why that one's genuinely
//     different, and confirm this one is genuinely different too,
//     rather than assuming one "fixed" convention across the family).
//   - **The OKI sample ROMs are scrambled via `ROM_CONTINUE`** — a
//     single physical chip's own contents get sliced into four 0x20000
//     quarters and reassembled at non-sequential region offsets
//     (nmk16.cpp's own comment: "this is a mess"). `tools/mkgfxrom.py`
//     gained a new `segments` mode for this (explicit REGION:FILE:LEN
//     triples, one per `ROM_LOAD`/`ROM_CONTINUE` line) — verified
//     byte-for-byte against the raw dump before use, not just trusted
//     to be right.
//   - Sprite ROM (`0x180000`, three plain-`ROM_LOAD`-concatenated 0x80000
//     chips) is bigger than every prior port's own (mustang: 0x100000,
//     bioship: 0x80000, blkheart: 0x100000) — nmk16spr.cpp's own sprite
//     `code` field is a full 16-bit `spriteram[offs+3]` value (never
//     masked to 12 bits the way BG tile codes are), so this needs no
//     RTL changes at all, just a bigger array (matches the existing,
//     already-verified over-wide `[20:0]` truncation convention every
//     prior port's own `group16_pixel()` already uses).
//   - DSW2 is mapped (same as bioship/blkheart) — tied to the same
//     fixed idle value.
//   - Palette RAM lives at `0x8C000-0x8C7FF` (not `0x88000` — every
//     other port's own address), and the two scroll register blocks
//     live at `0x84000`/`0x88000` (not `0x8C000`/`0x8C010` — a
//     completely different address layout from bioship's own, not a
//     copy-paste error).
//
// Memory map (see strahl_map in mame/src/mame/nmk/nmk16.cpp):
//   000000-03FFFF  ROM (maincpu, 0x40000 region, 2 x 0x20000-byte chips)
//   080000-080001  IN0 (R)
//   080002-080003  IN1 (R)
//   080008-080009  DSW1 (R)
//   08000A-08000B  DSW2 (R)
//   08000F         NMK004 host-read latch (R, byte)
//   080015         flipscreen_w (W, byte)
//   080016-080017  nmk004_x0016_w (W, word) — standard NMI polarity
//   08001F         NMK004 host-write latch (W, byte)
//   084000-084007  scroll_w<0> (BG0 X/Y scroll, byte-sequenced, ~LDSn)
//   088000-088007  scroll_w<1> (BG1 X/Y scroll, byte-sequenced, ~LDSn)
//   08C000-08C7FF  palette RAM, 1024 x 16
//   090000-093FFF  BG0 tilemap VRAM, 8192 x 16
//   094000-097FFF  BG1 tilemap VRAM, 8192 x 16 ("bgvideoram1")
//   09C000-09C7FF  tx tilemap VRAM, 1024 x 16
//   0F0000-0FFFFF  main work RAM, 32768 x 16 — plain masked write (see above)
//
// Known simplifications: identical to mustang_core.sv's own list (DTACKn
// tied to ASn, jt03/jt6295 write-stretch, jt6295 rom_ok tied high,
// NMK004 fed a genuine divided clock rather than a clock-enable, IN0/
// IN1/DSW1/DSW2 tied to fixed idle values) — see that module's header
// for the full rationale, not repeated here since none of it changed.
module strahl_core #(
	parameter ROM_FILE      = "",
	parameter NMK004_BOOT_FILE = "",
	parameter NMK004_EXT_FILE  = "",
	parameter OKI1_ROM_FILE = "",
	parameter OKI2_ROM_FILE = "",
	parameter FGTILE_FILE   = "",
	parameter BGTILE_FILE   = "",
	parameter BG2TILE_FILE  = "",
	parameter SPRITES_FILE  = ""
) (
	input clk_sys,       // 48 MHz (68000 bus clk_sys/4=12MHz; NMK004/pixel/raster clk_sys/6=8MHz)
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
	input  [12:0] dbg_bg0vram_addr,
	output [15:0] dbg_bg0vram_data,
	input  [9:0]  dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables — see header for the 48MHz derivation.
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	// NMK004: a genuine divided clock, 8MHz from 48MHz clk_sys — /6 (3
	// high, 3 low; 6 is even, unlike bioship's own odd /5 case, so this
	// one IS a clean 50%-duty square wave, but still built as an
	// explicit counter rather than a power-of-2 MSB trick since 6 isn't
	// one — see mustang_core.sv's own "Known simplifications" note on
	// why this is a divided clock, not a clock-enable).
	reg [2:0] nmk004_div = 3'd0;
	always @(posedge clk_sys)
		nmk004_div <= reset ? 3'd0 : (nmk004_div == 3'd5 ? 3'd0 : nmk004_div + 3'd1);
	wire nmk004_clk_r = (nmk004_div < 3'd3);

	// Pixel/raster-timing clock enable: 8MHz from 48MHz clk_sys (/6,
	// same rate as NMK004 above, independent single-clk_sys-cycle-strobe
	// counter — matches mustang_core.sv's own ce_pix role).
	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd5);
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
	wire sel_scroll0   = (byte_addr >= 24'h084000) && (byte_addr <= 24'h084007);
	wire sel_scroll1   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h088007);
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire sel_palette   = (byte_addr >= 24'h08C000) && (byte_addr <= 24'h08C7FF);
	wire sel_bg0vram   = (byte_addr >= 24'h090000) && (byte_addr <= 24'h093FFF);
	wire sel_bg1vram   = (byte_addr >= 24'h094000) && (byte_addr <= 24'h097FFF);
	wire sel_txvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09C7FF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu)
	// ------------------------------------------------------------------
	reg [15:0] rom [0:131071]; // 0x20000 words = 0x40000 bytes
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[17:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — plain masked write, NOT mustang's own
	// mainram_strange_w quirk (see header).
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
	// BG0/BG1 tilemap VRAM (8192 x 16 each) — plain masked writes
	// ------------------------------------------------------------------
	reg [15:0] bg0vram [0:8191];
	wire [12:0] bg0vram_addr = byte_addr[13:1];
	always @(posedge clk_sys) begin
		if (sel_bg0vram & cpu_write) begin
			if (~UDSn) bg0vram[bg0vram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) bg0vram[bg0vram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] bg0vram_dout = bg0vram[bg0vram_addr];

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
	// Dual-port video read taps — video_strahl.sv's own live, per-pixel
	// reads into the same arrays above (strahl_core.sv owns the
	// storage, matching mustang_core.sv's own established split).
	// ------------------------------------------------------------------
	wire [12:0] vid_bg0vram_addr;
	wire [15:0] vid_bg0vram_dout = bg0vram[vid_bg0vram_addr];
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

	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bg0vram_data = bg0vram[dbg_bg0vram_addr];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers (write-captured only, see header)
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  scroll_reg [0:1][0:3]; // [0]=BG0 [1]=BG1, each [Xhi,Xlo,Yhi,Ylo]
	reg        nmi_level;

	wire [15:0] bg0_xscroll = {scroll_reg[0][0], scroll_reg[0][1]};
	wire [15:0] bg0_yscroll = {scroll_reg[0][2], scroll_reg[0][3]};
	wire [15:0] bg1_xscroll = {scroll_reg[1][0], scroll_reg[1][1]};
	wire [15:0] bg1_yscroll = {scroll_reg[1][2], scroll_reg[1][3]};

	integer si, sj;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			nmi_level       <= 1'b0;
			for (si = 0; si < 2; si = si + 1)
				for (sj = 0; sj < 4; sj = sj + 1)
					scroll_reg[si][sj] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)    flip_screen_reg <= oEdb[7:0];
			if (sel_scroll0 & ~LDSn) scroll_reg[0][scroll_word_idx] <= oEdb[7:0];
			if (sel_scroll1 & ~LDSn) scroll_reg[1][scroll_word_idx] <= oEdb[7:0];
			// nmk004_x0016_w: standard polarity, same as mustang_core.sv.
			if (sel_nmi)             nmi_level       <= oEdb[0];
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
	// YM2203 — real jt03. 1.5MHz from 48MHz clk_sys divides *exactly*
	// (48/32=1.5MHz) — unlike every prior port's own fractional
	// accumulator, a plain mod-32 free-running counter suffices here
	// (see header).
	// ------------------------------------------------------------------
	reg [4:0] ym_cen_cnt = 5'd0;
	wire      ym_cen = (ym_cen_cnt == 5'd31);
	always @(posedge clk_sys) ym_cen_cnt <= ym_cen ? 5'd0 : ym_cen_cnt + 5'd1;

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
	// OKIM6295 x2 — real jt6295. Reference uses 16000000/4=4MHz for both
	// chips here (same target rate as every prior port). 1MHz from
	// 48MHz clk_sys is an exact /48.
	// ------------------------------------------------------------------
	reg [5:0] oki_cen_cnt = 6'd0;
	wire      oki_cen = (oki_cen_cnt == 6'd47);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 6'd0 : oki_cen_cnt + 6'd1;

	localparam OKI_SS = 1'b0; // PIN7_LOW, same as mustang

	// Sample ROMs — scrambled via ROM_CONTINUE in the reference (see
	// header); tools/mkgfxrom.py's own new `segments` mode already
	// unscrambled this at extraction time, so the RTL side is a plain
	// flat 0xA0000-byte array like every other port's own OKI ROM.
	reg [7:0] oki1_rom [0:655359];
	reg [7:0] oki2_rom [0:655359];
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki1_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki2_rom);

	reg [1:0] oki1_bank_r = 2'd0, oki2_bank_r = 2'd0;
	always @(posedge clk_sys) begin
		if (oki0_bank_we) oki1_bank_r <= oki0_bank[1:0];
		if (oki1_bank_we) oki2_bank_r <= oki1_bank[1:0];
	end

	// Address mapping — same oki1_map/oki2_map bank arithmetic as
	// mustang_core.sv's own oki_phys_addr(). The reference's own bank
	// arithmetic still computes `(bank+1)*0x20000 + rom_addr[16:0]`
	// regardless of the ROM's own scrambled physical layout — that
	// scrambling exists specifically so this SAME unmodified arithmetic
	// lands on the right (unscrambled, logical) content once the ROM is
	// loaded per its own ROM_CONTINUE map, which is exactly what
	// tools/mkgfxrom.py's segments mode already replicated.
	function automatic [19:0] oki_phys_addr(input [17:0] rom_addr, input [1:0] bank);
		reg [2:0] bank_p1;
		reg [20:0] full;
		begin
			bank_p1 = {1'b0, bank} + 3'd1;
			full = rom_addr[17] ? ({bank_p1, 17'd0} + {3'd0, rom_addr[16:0]}) : {3'd0, rom_addr[16:0]};
			oki_phys_addr = full[19:0];
		end
	endfunction

	wire [17:0] oki1_rom_addr, oki2_rom_addr;
	wire [19:0] oki1_phys = oki_phys_addr(oki1_rom_addr, oki1_bank_r);
	wire [19:0] oki2_phys = oki_phys_addr(oki2_rom_addr, oki2_bank_r);

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
		else if (sel_bg0vram) rdata = bg0vram_dout;
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
	// "lowres" family geometry every prior port already uses) + the
	// SYNTHETIC fixed-scanline interrupt generator (rtl/bjtwin/
	// nmk_irq_hacky.sv, NOT the real PROM-driven nmk_irq.sv — see
	// header for why no real V-PROM exists for this game).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);

	wire sprite_dma_trigger; // consumed by video_strahl below
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
	// Video pipeline — real tilemap + sprite rendering. See
	// rtl/strahl/video_strahl.sv's own header for the full derivation.
	// ------------------------------------------------------------------
	video_strahl #(
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.BG2TILE_FILE(BG2TILE_FILE),
		.SPRITES_FILE(SPRITES_FILE)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.sprite_dma_trigger(sprite_dma_trigger),
		.bg0vram_addr(vid_bg0vram_addr), .bg0vram_data(vid_bg0vram_dout),
		.bg1vram_addr(vid_bg1vram_addr), .bg1vram_data(vid_bg1vram_dout),
		.txvram_addr(vid_txvram_addr), .txvram_data(vid_txvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout),
		.bg0_xscroll(bg0_xscroll), .bg0_yscroll(bg0_yscroll),
		.bg1_xscroll(bg1_xscroll), .bg1_yscroll(bg1_yscroll),
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
