// NMK16 MiSTerFPGA project — strahljbl (Tier 5, Family E "Raiden sound"
// bootleg of strahl) system-level integration.
//
// The fourth Tier 5 port, after mustangb (rtl/mustangb/mustangb_core.sv),
// tdragonb (rtl/tdragonb/tdragonb_core.sv), and acrobatmbl
// (rtl/acrobatmbl/acrobatmbl_core.sv), which this file follows
// structurally line-for-line for the Z80/T80/seibu_sound/jtopl2/jt6295
// architecture (see mustangb_core.sv's own header, not repeated here).
// Reuses, unmodified: `rtl/seibu/seibu_sound.sv`, `rtl/third_party_gen/
// t80/T80s.v` (GHDL-translated Z80 core, three times proven cycle-exact
// against a real MAME oracle — see docs/t80-vhdl-toolchain.md),
// `rtl/bjtwin/video_timing.sv` + `rtl/bjtwin/nmk_irq_hacky.sv`
// (strahljbl's own machine config calls set_hacky_interrupt_timing,
// nmk16.cpp:5197, identical fixed-scanline table to every prior Tier 5
// port — this board's timing PROMs are undumped too, confirmed: no
// nmk_irq:vtiming/htiming region in ROM_START(strahljbl)), and —
// genuinely new to Tier 5, though already built for Tier 2's `strahl` —
// `rtl/strahl/video_strahl.sv` (strahl_map and strahljbl_map,
// nmk16.cpp:947-983, share the identical video/VRAM/palette/scroll
// register layout, confirmed by reading both directly — only the
// NMK004-specific entries, 0x8000F read / 0x80016-17 write / 0x8001F
// write, are replaced by main_mustb_w at 0x8001E/F in the bootleg map).
// This is this project's first Tier 5 game with a dual-BG-layer video
// architecture (Strahl has two independent VRAM tilemaps, BG0+BG1, each
// with its own X/Y scroll — unlike mustangb/tdragonb/acrobatmbl's own
// single-BG-layer video).
//
// IMPORTANT: unlike video_strahl.sv's own donor, rtl/strahl/
// strahl_core.sv, this file does NOT use that module's own 48MHz
// clk_sys architecture (12MHz 68000 = clk_sys/4, NMK004/pixel clk_sys/6
// = 8MHz). strahljbl's own machine config uses `M68000(config,
// m_maincpu, 12_MHz_XTAL)` — a plain 12MHz — so this file uses the SAME
// 32MHz clk_sys convention mustangb_core.sv/tdragonb_core.sv/
// acrobatmbl_core.sv already established. video_strahl.sv itself takes
// a generic clk_sys input and derives no frequency-specific timing of
// its own (confirmed by reading its own module port list and body
// directly — same as video_acrobatm.sv's own confirmed-generic
// behavior), so it drops into either clock convention unchanged.
//
// Memory map (strahljbl_map, nmk16.cpp:967-983 — confirmed identical to
// strahl_map, nmk16.cpp:947-965, apart from the sound/protection
// entries noted above):
//   000000-03FFFF  ROM (maincpu, 0x40000, 2 x 0x20000-byte chips
//                  ROM_LOAD16_BYTE — no decode/patch needed, empty_init())
//   080000-080001  IN0 (R)
//   080002-080003  IN1 (R)
//   080008-080009  DSW1 (R)
//   08000A-08000B  DSW2 (R)
//   080015         flipscreen_w (W, byte, LDS=low byte)
//   08001E-08001F  seibu_sound_device::main_mustb_w (W, word — see
//                  rtl/seibu/seibu_sound.sv's own header)
//   084000-084007  scroll_w<0> (BG0 X/Y scroll, 4 byte sub-registers
//                  [Xhi,Xlo,Yhi,Ylo], sub-index = byte_addr[2:1],
//                  LDS-gated low-byte writes only — exact copy of
//                  strahl_core.sv's own working pattern)
//   088000-088007  scroll_w<1> (BG1 X/Y scroll, same shape as BG0's own)
//   08C000-08C7FF  palette RAM, 1024 x 16 (real — video_strahl)
//   090000-093FFF  BG0 tilemap VRAM, 8192 x 16 (real — video_strahl)
//   094000-097FFF  BG1 tilemap VRAM, 8192 x 16 (real — video_strahl)
//   09C000-09C7FF  tx tilemap VRAM, 1024 x 16 (real — video_strahl)
//   0F0000-0FFFFF  main work RAM, 32768 x 16 — plain masked write (no
//                  "mainram_strange_w" quirk; strahl_map/strahljbl_map
//                  both map this with bare .ram(), no write-handler
//                  override, so standard COMBINE_DATA semantics apply —
//                  same convention as strahl_core.sv's own, tdragonb's
//                  own, and acrobatmbl's own mainram, NOT mustang's).
//   Neither strahl_map nor strahljbl_map has a tilebank_w entry at all.
//
// Z80 memory map: identical to mustangb's/tdragonb's/acrobatmbl's own
// (seibu_sound_map, seibusound.cpp:333-350) — see mustangb_core.sv's
// header, not repeated.
//
// No protection workaround needed: strahljbl uses empty_init()
// (GAME(1992, strahljbl, ...), nmk16.cpp:10787) — no ROM patching, no
// bit-permutation, nothing analogous to tdragonb's decode_tdragonb.py or
// acrobatmbl's patch_rom_words.py. The audiocpu ROM (a6.u417, CRC
// 99ee7505) and OKI ROM (a5.u304, CRC f6f6c4bf) are — again —
// byte-identical to every prior Tier 5 port's own, same ROM_LOAD+
// ROM_CONTINUE+ROM_COPY audiocpu layout.
//
// Clock: 68000 at 12_MHz_XTAL. From 32MHz clk_sys: GCD(12000000,
// 32000000)=4000000 -> increment=3, modulus=8 — a small 3-bit phase
// accumulator drives enPhi1/enPhi2 (same technique as tdragonb_core.sv's
// own 10MHz case; verified by hand-tracing the accumulator sequence:
// enPhi1 fires at acc-wrap steps 2,5,7 of every repeating 8-cycle
// window (rate 3/8 exact), enPhi2 always exactly one clk_sys cycle
// later, strict alternation holds — never two of the same enable
// back-to-back, confirmed for the full 8-cycle repeating pattern).
// Z80 + YM3812 both at 12_MHz_XTAL/4 = 3MHz (nmk16.cpp:5199,5213 — the
// identical divisor, same shared-clock convention as every prior port).
// From 32MHz: GCD(3000000,32000000)=1000000 -> increment=3, modulus=32
// — another small accumulator (single-phase, same style as mustangb's
// own Z80/YM3812 cen). OKIM6295 at 12_MHz_XTAL/12 = 1MHz
// (nmk16.cpp:5217). From 32MHz: GCD(1000000,32000000)=1000000 ->
// increment=1, modulus=32 — this one IS a clean divisor, clk_sys/32, a
// plain free-running counter suffices (same as acrobatmbl_core.sv's own
// OKI cen).
//
// Known simplifications: identical list to mustangb_core.sv's own (no
// audio DAC/mixer, IN0/IN1/DSW1/DSW2 tied to fixed idle values, DTACKn
// tied to ASn, T80's WAIT_n tied high) — not repeated here.
module strahljbl_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI_ROM_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter BG2TILE_FILE   = "",
	parameter SPRITES_FILE   = ""
) (
	input clk_sys,        // 32 MHz (68000 bus/pixel clk_sys/4 = 8MHz, CPU enable via accumulator)
	input reset,           // async, active high

	// debug/trace outputs for the Verilator testbench
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,
	output        dbg_cpu_cen, // enPhi1 pulse — the real 12MHz-equivalent tick

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
	input  [12:0] dbg_bg0vram_addr,
	output [15:0] dbg_bg0vram_data,
	input  [12:0] dbg_bg1vram_addr,
	output [15:0] dbg_bg1vram_data,
	input  [9:0]  dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	// 68000: 12MHz from 32MHz clk_sys, GCD(12000000,32000000)=4000000 ->
	// increment=3, modulus=8 — exact-ratio phase accumulator (see
	// header). enPhi1/enPhi2 need two distinct, never-simultaneous,
	// strictly-alternating pulses per fx68k clock period — reproduced
	// here via the same "wrap fires enPhi1, defer one enPhi2 to the very
	// next non-wrap cycle" technique tdragonb_core.sv's own 5/16 case
	// established.
	localparam integer CPU_CEN_INC = 3;
	localparam integer CPU_CEN_MOD = 8;
	reg [2:0] cpu_cen_acc = 3'd0;
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

	// Z80 + YM3812 shared clock enable: 12_MHz_XTAL/4 = 3MHz. GCD(3000000,
	// 32000000)=1000000 -> increment=3, modulus=32 — small accumulator,
	// single-phase (T80/jtopl2 both just need a plain cen pulse, no
	// two-phase relationship like the 68000's own enPhi1/enPhi2).
	localparam integer Z80_CEN_INC = 3;
	localparam integer Z80_CEN_MOD = 32;
	reg [4:0] z80_cen_acc = 5'd0;
	reg       z80_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (z80_cen_acc + Z80_CEN_INC >= Z80_CEN_MOD) begin
			z80_cen_acc <= z80_cen_acc + Z80_CEN_INC - Z80_CEN_MOD;
			z80_cen <= 1'b1;
		end else begin
			z80_cen_acc <= z80_cen_acc + Z80_CEN_INC;
			z80_cen <= 1'b0;
		end
	end

	// OKIM6295: 12_MHz_XTAL/12 = 1MHz = clk_sys/32 — a clean divide, no
	// accumulator needed (GCD(1000000,32000000)=1000000 -> increment=1).
	reg [4:0] oki_div = 5'd0;
	always @(posedge clk_sys) oki_div <= oki_div + 5'd1;
	wire oki_cen = (oki_div == 5'd31);

	// Pixel/raster-timing clock enable for video_timing/nmk_irq_hacky:
	// 8MHz from 32MHz clk_sys — same ratio/reset-gating convention as
	// every prior "lowres" family port (see mustangb_core.sv's header).
	// NOT strahl_core.sv's own clk_sys/6 (that ratio is specific to its
	// 48MHz clk_sys convention, not reused here — see header).
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
	// Address decode (68000 side) — matches strahl_map's own layout (see
	// header), no mirroring anywhere on either map.
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h03FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1       = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040004); // 080008/080009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h040005); // 08000A/08000B
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015, LDS=low byte
	wire sel_mustb     = (byte_addr[23:1] == 23'h04000F); // 08001E/08001F word
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
	// Main work RAM (32768 x 16) — plain masked write, no mirroring
	// (COMBINE_DATA, same convention as strahl_core.sv's own mainram —
	// see header).
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
	// Dual-port video read taps (video_strahl.sv's own live reads)
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
	assign dbg_bg1vram_data = bg1vram[dbg_bg1vram_addr];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers (write-captured only) — scroll wiring is a direct
	// copy of strahl_core.sv's own working pattern.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  scroll_reg [0:1][0:3]; // [0]=BG0 [1]=BG1, each [Xhi,Xlo,Yhi,Ylo]
	reg        mustb_we_pulse;
	reg [15:0] mustb_data_r;

	wire [15:0] bg0_xscroll = {scroll_reg[0][0], scroll_reg[0][1]};
	wire [15:0] bg0_yscroll = {scroll_reg[0][2], scroll_reg[0][3]};
	wire [15:0] bg1_xscroll = {scroll_reg[1][0], scroll_reg[1][1]};
	wire [15:0] bg1_yscroll = {scroll_reg[1][2], scroll_reg[1][3]};

	integer si, sj;
	always @(posedge clk_sys) begin
		mustb_we_pulse <= 1'b0;
		if (reset) begin
			flip_screen_reg <= 8'h00;
			for (si = 0; si < 2; si = si + 1)
				for (sj = 0; sj < 4; sj = sj + 1)
					scroll_reg[si][sj] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_scroll0 & ~LDSn)  scroll_reg[0][scroll_word_idx] <= oEdb[7:0];
			if (sel_scroll1 & ~LDSn)  scroll_reg[1][scroll_word_idx] <= oEdb[7:0];
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
	// differ (accumulator-based, see header).
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
	// ROM_CONTINUE+ROM_COPY layout as mustangb's/tdragonb's/acrobatmbl's
	// own (see header — byte-identical audiocpu ROM, CRC 99ee7505).
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
		.m68k_mustb_we(mustb_we_pulse), .m68k_mustb_lds(1'b1), .m68k_mustb_uds(1'b1),
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
		else if (sel_bg0vram) rdata = bg0vram_dout;
		else if (sel_bg1vram) rdata = bg1vram_dout;
		else if (sel_txvram)  rdata = txvram_dout;
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing (rtl/bjtwin/video_timing.sv) + hacky fixed-scanline
	// IRQ generator (rtl/bjtwin/nmk_irq_hacky.sv) — see header.
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
	// Video pipeline — rtl/strahl/video_strahl.sv, unmodified (see
	// header). Note the dual-BG-layer port split (bg0/bg1 vram+scroll),
	// matching strahl_core.sv's own instantiation exactly.
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
	assign dbg_cpu_cen = enPhi1;

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
