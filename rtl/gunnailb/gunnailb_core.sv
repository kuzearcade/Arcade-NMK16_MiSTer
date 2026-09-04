// NMK16 MiSTerFPGA project — gunnailb (Tier 5, "GunNail (bootleg)")
// system-level integration.
//
// The fifth Tier 5 port — but architecturally DIFFERENT from all four
// prior ones (mustangb/tdragonb/acrobatmbl/strahljbl): gunnailb does NOT
// use the Seibu Sound System at all (confirmed: mame/src/mame/nmk/
// nmk16.cpp:172's own "uses the Seibu Raiden sound hardware" comment lists
// only acrobatmbl/mustangb/strahljb/tdragonb, not gunnailb). Its own
// gunnailb() machine config (nmk16.cpp:5419-5442) calls gunnail(config)
// FIRST — inheriting the real Tier 4 rtl/gunnail/gunnail_core.sv's own
// 68000 clock (10MHz) and YM2203 instance — then overrides the memory map,
// swaps in a Z80 with its own distinct sound/IO maps (gunnailb_sound_map/
// gunnailb_sound_io_map, nmk16.cpp:1065-1079, NOT seibu_sound_map), wires
// the YM2203 IRQ directly to the Z80 (plain maskable IRQ0, no Seibu-style
// IM0 vector arbitration), replaces the OKI with a single no-banking chip
// wired DIRECTLY to the 68000 (nmk16.cpp:1077's own comment: "since the
// bootleggers used the same audio CPU ROM as airbustr but a different Oki
// ROM, they connected the Oki to the main CPU"), and removes the NMK004
// device entirely (config.device_remove("nmk004")) — so this port is fully
// decoupled from gunnail's own still-open protection-MCU timing-drift
// issue (docs/PLAN.md's Tier 4 section).
//
// Reused, unmodified: rtl/third_party_gen/t80/T80s.v (GHDL-translated Z80
// core, four times proven cycle-exact against a real MAME oracle — see
// docs/t80-vhdl-toolchain.md), rtl/bjtwin/video_timing.sv +
// rtl/bjtwin/nmk_irq_hacky.sv (gunnailb's own machine config calls
// set_hacky_interrupt_timing, nmk16.cpp:5424, NOT gunnail's own real
// V-PROM-driven set_interrupt_timing — this board's timing PROMs are
// undumped too; video_timing.sv is this project's single shared 8MHz/
// 512-wide raster model regardless of lowres/hires screen config, per
// gunnail_core.sv's own header, so it needs no adaptation here either).
//
// NOT reused: rtl/gunnail/video_gunnail.sv. That module drives its own
// bgtile/sprites ROM fetches through two LIVE rtl/nmk214/nmk214.sv
// instances, configured via a protection-MCU handshake this board doesn't
// have. gunnailb's own bgtile/sprites ROM data is instead descrambled
// ONCE, OFFLINE (decode_gfx(), nmk16.cpp:6005-6054 — a completely separate
// mechanism from nmk214 despite sharing the same "8 tables, address-bits
// select which one" conceptual shape; see tools/decode_gunnailb_gfx.py's
// own header), so this port uses a new derivative, video_gunnailb.sv (same
// directory, see its own header for the exact diff against video_gunnail.sv
// — the nmk214 stages removed, everything else unchanged), and drives it
// with entirely local (not protection-MCU-shared) VRAM/palette/scrollram
// storage below — no prot_wr/prot_addr/prot_sel_* arbitration exists
// anywhere in this file, unlike gunnail_core.sv's own.
//
// Memory map (gunnailb_map, nmk16.cpp:1043-1063 — confirmed identical to
// gunnail_map, nmk16.cpp:1022-1041, apart from the sound/protection
// entries noted above):
//   000000-07FFFF  ROM (maincpu, 0x80000, 2 x 0x40000-byte chips
//                  ROM_LOAD16_BYTE — no maincpu decode/patch needed, only
//                  bgtile/sprites are touched by decode_gfx())
//   080000-080001  IN0 (R)
//   080002-080003  IN1 (R)
//   080008-080009  DSW1 (R)
//   08000A-08000B  DSW2 (R)
//   08000F         soundlatch2 read (R, byte — Z80-written, 68000-read)
//   080015         flipscreen_w (W, byte, LDS=low byte)
//   080016-080017  unmapped (nmk004_x0016_w is gone entirely — commented
//                  out in the reference itself, nothing wired here)
//   080019         tilebank_w (W, byte, LDS=low byte)
//   08001F         soundlatch write (W, byte — 68000-written, Z80-read;
//                  also sets the Z80's own NMI pending, see below)
//   088000-0887FF  palette RAM, 1024 x 16 (real — video_gunnailb)
//   08C000-08C1FF  gunnail_scrollram (W-only, 256 x 16 — real per-scanline
//                  raster X scroll table, see video_gunnailb.sv's own
//                  header)
//   08C200-08C3FF  gunnail_scrollramy (W-only, 256 x 16 — same, Y)
//   08C400-08C7FF  unmapped ("unknown" per the reference's own comment)
//   090000-093FFF  BG tilemap VRAM, 8192 x 16 (real — video_gunnailb)
//   09C000-09CFFF  tx tilemap VRAM, 2048 x 16, mirrored +0x1000 (real —
//                  video_gunnailb)
//   0F0000-0FFFFF  main work RAM, 32768 x 16, plain masked write (no
//                  protection-MCU arbitration — see header)
//   194001         OKIM6295 write (W, byte, ODD address — see "OKI on the
//                  68000" below). No corresponding read entry anywhere in
//                  the reference's own map — the 68000 program apparently
//                  never polls OKI's busy/status flag, consistent with
//                  this game being flagged MACHINE_IMPERFECT_SOUND
//                  ("crappy sound, unknown how much of it is incomplete
//                  emulation and how much bootleg quality").
//
// Z80 memory map (gunnailb_sound_map, nmk16.cpp:1065-1070):
//   0000-7FFF  ROM (fixed, first 0x8000 bytes of the 0x20000-byte
//              audiocpu ROM — "27c010.3b", comment: "matches the one for
//              Kaneko's Air Buster" — a completely unrelated game's Z80
//              sound program, reused verbatim by the bootleggers)
//   8000-BFFF  banked ROM window, 8 x 0x4000-byte banks
//              (init_banked_audiocpu(), nmk16.cpp:6171-6173 —
//              configure_entries(0,8,region_base,0x4000): bank N sources
//              region bytes N*0x4000..N*0x4000+0x3FFF from the SAME flat
//              0x20000-byte ROM the fixed region also reads from — a
//              standard flat-overlay banking scheme, bank 0/1 duplicate
//              the fixed region's own content)
//   C000-DFFF  RAM, 0x2000 bytes
//
// Z80 I/O map (gunnailb_sound_io_map, nmk16.cpp:1072-1079,
// map.global_mask(0xff) — 8-bit I/O address space, decoded here off
// z80_a[7:0] only):
//   00      write: macross2_audiobank_w (nmk16.cpp:302-305) — audiobank
//           <= data & 0x7
//   02/03   r/w: YM2203 (jt03) — 02=addr/status (offset0), 03=data
//           (offset1), matching ym2203_device::read/write(offset)'s own
//           standard 2-register convention
//   04      noprw — genuinely unused (Oki moved to the 68000, see above)
//   06      read: soundlatch (68000-written data); write: soundlatch2
//           (Z80-written, 68000-readable)
//
// soundlatch/soundlatch2 (GENERIC_LATCH_8, nmk16.cpp:5430-5433): plain
// 8-bit registers, no existing device to reuse (new here, genuinely
// simple — not the Family-C-adjacent macross2 sound architecture in
// general, just this one game's own specific wiring, don't treat this as
// a reusable general-purpose device the way rtl/seibu/seibu_sound.sv is).
// soundlatch's own data_pending_callback().set_inputline(m_audiocpu,
// INPUT_LINE_NMI) (nmk16.cpp:5431) means the 68000->Z80 direction drives
// the Z80's NMI as a LEVEL held low from the moment the 68000 writes until
// the Z80 itself reads the latch back (io port 0x06 read) — matching
// MAME's own devcb_write_line ASSERT_LINE/CLEAR_LINE semantics for this
// callback shape; T80's own internal NMI edge-detector (real Z80 hardware
// behavior: NMI fires once on the falling edge, ignores the level
// afterward until the next fresh falling edge) handles the "only once per
// write" part on its own, so this file only needs to hold nmi_n low while
// pending and clear it on read, not generate a pulse itself. soundlatch2
// has no such callback — plain data-only, no interrupt side effect.
//
// OKI on the 68000 (0x194001, nmk16.cpp:1062): a single byte-write
// register directly driving jt6295's own command/data input, no bank
// device layer at all (OKIM6295(config.replace(),m_oki[0],12000000/4,...)
// // no OKI banking, nmk16.cpp:5437) — genuinely simpler than gunnail's
// own two-OKI banked setup: driven straight from the 68000's own bus
// rather than relayed through the Z80's own domain. Still uses the same
// latch-and-hold write-stretch this project's other 68000/Z80-driven OKI
// integrations already established (a 40-clk_sys-cycle wrn hold, see the
// oki_wr_hold logic below) — the 68000's own bus cycle is already wide
// enough on its own that this is likely belt-and-suspenders rather than
// strictly required, but it costs nothing and removes any doubt about
// exact alignment against jt6295's own cen edges.
//
// Clock: reuses gunnail_core.sv's own 40MHz clk_sys convention exactly
// (NOT the 32MHz convention every Family E port used) — because
// gunnailb(config) inherits gunnail(config)'s own 68000 instantiation
// (XTAL(10'000'000)) UNCHANGED, only overriding the memory-map function
// pointer afterward. 68000: clk_sys/4=10MHz (identical cpu_div pattern).
// Pixel/raster: clk_sys/5=8MHz (identical pix_div pattern, shared video_
// timing model — see header). YM2203: identical accumulator to gunnail_
// core.sv's own ym_cen (increment=3,modulus=80 -> 1.5MHz — the SAME chip
// instance/clock the base gunnail(config) already set up; gunnailb() only
// rewires its IRQ destination, not its clock, nmk16.cpp:5435). New here:
//   - Z80: 6MHz (Z80(config,m_audiocpu,6000000), nmk16.cpp:5426). From
//     40MHz: GCD(6000000,40000000)=2000000 -> increment=3, modulus=20 —
//     small phase accumulator (single cen pulse, T80's own CEN — no
//     two-phase enPhi1/enPhi2 pair needed, that's a 68000-specific
//     requirement).
//   - OKI: 3MHz (12000000/4, nmk16.cpp:5437). From 40MHz:
//     GCD(3000000,40000000)=1000000 -> increment=3, modulus=40 — another
//     small accumulator.
//
// Known simplifications: same general list as every prior port (no audio
// DAC/mixer, IN0/IN1/DSW1/DSW2 tied to fixed idle values, DTACKn tied to
// ASn, T80's WAIT_n tied high) — not repeated in full here. HALTn tied
// high (no protection MCU exists to drive it, unlike gunnail_core.sv's own
// `.HALTn(~halt_68k)` — matches every other Tier 5 port's own `.HALTn(1'b1)`).
module gunnailb_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI_ROM_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = ""
) (
	input clk_sys,        // 40 MHz (68000 bus clk_sys/4=10MHz; pixel/raster clk_sys/5=8MHz)
	input reset,            // async, active high

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
	output        dbg_z80_nmi_n,
	output        dbg_z80_cen,

	output        dbg_ym_we,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_irq_n,

	output        dbg_oki_we,
	output  [7:0] dbg_oki_chip_dout,

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
	// Clock enables — 68000/pixel identical to gunnail_core.sv's own (see
	// header); Z80/OKI are new here.
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// Z80: 6MHz from 40MHz clk_sys. GCD(6000000,40000000)=2000000 ->
	// increment=3, modulus=20 (verified: 40e6*3/20=6e6 exact).
	localparam integer Z80_CEN_INC = 3;
	localparam integer Z80_CEN_MOD = 20;
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

	// YM2203: identical accumulator to gunnail_core.sv's own ym_cen
	// (increment=3, modulus=80 -> 1.5MHz off 40MHz clk_sys, unchanged
	// since gunnailb reuses the SAME ymsnd device/clock the base
	// gunnail(config) already set up — see header).
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

	// OKI: 3MHz from 40MHz. GCD(3000000,40000000)=1000000 ->
	// increment=3, modulus=40 (verified: 40e6*3/40=3e6 exact).
	localparam integer OKI_CEN_INC = 3;
	localparam integer OKI_CEN_MOD = 40;
	reg [5:0] oki_cen_acc = 6'd0;
	reg       oki_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (oki_cen_acc + OKI_CEN_INC >= OKI_CEN_MOD) begin
			oki_cen_acc <= oki_cen_acc + OKI_CEN_INC - OKI_CEN_MOD;
			oki_cen <= 1'b1;
		end else begin
			oki_cen_acc <= oki_cen_acc + OKI_CEN_INC;
			oki_cen <= 1'b0;
		end
	end

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
		.HALTn(1'b1), // no protection MCU exists to halt this port (unlike gunnail_core.sv's own)
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
	// Address decode (68000 side) — see header for the exact addresses.
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h07FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1       = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040004); // 080008/080009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h040005); // 08000A/08000B
	wire sel_soundlatch2_r = (byte_addr[23:1] == 23'h040007); // 08000E/08000F word, byte reg at odd
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015, LDS=low byte
	wire sel_tilebank  = (byte_addr[23:1] == 23'h04000C); // 080018/080019, LDS=low byte
	wire sel_soundlatch_w = (byte_addr[23:1] == 23'h04000F); // 08001E/08001F word, byte reg at odd
	wire sel_palette   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h0887FF);
	wire sel_scrollram  = (byte_addr >= 24'h08C000) && (byte_addr <= 24'h08C1FF);
	wire sel_scrollramy = (byte_addr >= 24'h08C200) && (byte_addr <= 24'h08C3FF);
	wire sel_bgvram    = (byte_addr >= 24'h090000) && (byte_addr <= 24'h093FFF);
	// TX VRAM: 0x09c000-0x09cfff (2048 words), mirrored at +0x1000 — both
	// ranges alias the same array (ignore the mirror bit, byte_addr[12]).
	wire sel_txvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09DFFF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);
	// OKI write, single ODD byte at 0x194001 (nmk16.cpp:1062) — word
	// address 0x194000/1 pair, active lane is the LOW byte (odd address),
	// matching every other single-byte register's own ~LDSn convention.
	wire sel_oki_w     = (byte_addr[23:1] == 23'h0CA000); // 194000/194001

	// ------------------------------------------------------------------
	// ROM (maincpu) — 0x80000 bytes = 262144 words.
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — plain masked write, no protection-MCU
	// arbitration (see header).
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
	// Palette RAM (1024 x 16)
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
	// TX tilemap VRAM (2048 x 16)
	// ------------------------------------------------------------------
	reg [15:0] txvram [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	always @(posedge clk_sys) begin
		if (sel_txvram & cpu_write) begin
			if (~UDSn) txvram[txvram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) txvram[txvram_addr][7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] txvram_dout = txvram[txvram_addr];

	// ------------------------------------------------------------------
	// gunnail_scrollram / gunnail_scrollramy (256 x 16 each, write-only
	// in the reference) — real per-scanline raster X/Y scroll tables, see
	// video_gunnailb.sv's own header for the consuming formula.
	// ------------------------------------------------------------------
	reg [15:0] scrollram  [0:255];
	reg [15:0] scrollramy [0:255];
	wire [7:0] scrollram_waddr  = byte_addr[8:1];
	wire [7:0] scrollramy_waddr = byte_addr[8:1];
	always @(posedge clk_sys) begin
		if (sel_scrollram & cpu_write) begin
			if (~UDSn) scrollram[scrollram_waddr][15:8] <= oEdb[15:8];
			if (~LDSn) scrollram[scrollram_waddr][7:0]  <= oEdb[7:0];
		end
		if (sel_scrollramy & cpu_write) begin
			if (~UDSn) scrollramy[scrollramy_waddr][15:8] <= oEdb[15:8];
			if (~LDSn) scrollramy[scrollramy_waddr][7:0]  <= oEdb[7:0];
		end
	end
	// Video-side read taps — see video_gunnailb.sv's own header: it needs
	// scrollram[0]/scrollramy[0] (fixed) plus scrollram[16+row]/
	// scrollramy[row] (row-indexed, driven by the video module).
	wire [7:0] vid_scrollram_row_addr;
	wire [7:0] vid_scrollramy_row_addr;
	wire [15:0] vid_scrollram_0    = scrollram[0];
	wire [15:0] vid_scrollramy_0   = scrollramy[0];
	wire [15:0] vid_scrollram_row  = scrollram[vid_scrollram_row_addr];
	wire [15:0] vid_scrollramy_row = scrollramy[vid_scrollramy_row_addr];

	// ------------------------------------------------------------------
	// Dual-port video read taps (video_gunnailb.sv's own live reads)
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

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// soundlatch (68000->Z80, main2sub) / soundlatch2 (Z80->68000,
	// sub2main) — see header. soundlatch's own pending flag drives the
	// Z80's NMI as a held-low level (T80 handles the "fire once, on the
	// falling edge" semantics internally).
	// ------------------------------------------------------------------
	reg [7:0] soundlatch_data;
	reg       soundlatch_pending;
	reg [7:0] soundlatch2_data;

	always @(posedge clk_sys) begin
		if (reset) begin
			soundlatch_data    <= 8'h00;
			soundlatch_pending <= 1'b0;
		end else begin
			if (sel_soundlatch_w & cpu_write & ~LDSn) begin
				soundlatch_data    <= oEdb[7:0];
				soundlatch_pending <= 1'b1;
			end else if (z80_io_soundlatch_re) begin
				soundlatch_pending <= 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------
	// Z80 sound board: T80 + jt03 (YM2203) + jt6295 (OKI, driven by the
	// 68000 directly, see header)
	// ------------------------------------------------------------------
	wire [15:0] z80_a;
	wire [7:0]  z80_do;
	wire [7:0]  z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
	wire        z80_int_n, z80_nmi_n;

	assign z80_int_n = ym_chip_irq_n;
	assign z80_nmi_n = ~soundlatch_pending;

	T80s z80_cpu (
		.RESET_n(~reset),
		.CLK(clk_sys),
		.CEN(z80_cen),
		.WAIT_n(1'b1),
		.INT_n(z80_int_n),
		.NMI_n(z80_nmi_n),
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
	// IO cycle: IORQ asserted with RD/WR (not M1 — an interrupt-ack cycle
	// asserts IORQ+M1 together with RD_n/WR_n both staying high, so these
	// two are naturally exclusive of IACK without an explicit M1_n check).
	wire z80_io_we = ~z80_iorq_n & ~z80_wr_n;
	wire z80_io_re = ~z80_iorq_n & ~z80_rd_n;

	wire sel_z80_rom  = (z80_a < 16'h8000);
	wire sel_z80_bank = (z80_a >= 16'h8000) && (z80_a < 16'hC000);
	wire sel_z80_ram  = (z80_a >= 16'hC000) && (z80_a < 16'hE000);

	wire sel_io_bank    = z80_io_we & (z80_a[7:0] == 8'h00);
	wire sel_io_ym_addr = (z80_a[7:0] == 8'h02);
	wire sel_io_ym_data = (z80_a[7:0] == 8'h03);
	wire sel_io_ym      = sel_io_ym_addr | sel_io_ym_data;
	wire sel_io_soundlatch = (z80_a[7:0] == 8'h06);
	wire z80_io_soundlatch_re = z80_io_re & sel_io_soundlatch;

	// Audiocpu ROM: full 0x20000-byte flat image, fixed-mapped at
	// 0-0x7FFF, ALSO the source for the 8-entry x 0x4000-byte bank window
	// at 0x8000-0xBFFF (see header — a standard flat-overlay banking
	// scheme, no separate bank-only ROM region).
	reg [7:0] audiocpu_rom [0:131071];
	initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);

	reg [2:0] audiobank_reg;
	always @(posedge clk_sys) begin
		if (reset) audiobank_reg <= 3'd0;
		else if (sel_io_bank) audiobank_reg <= z80_do[2:0]; // macross2_audiobank_w: audiobank<=data&0x7
	end

	reg [7:0] z80_ram [0:8191];
	always @(posedge clk_sys) if (sel_z80_ram & z80_mem_we) z80_ram[z80_a[12:0]] <= z80_do;

	wire [16:0] z80_bank_phys = {audiobank_reg, 14'd0} + {3'd0, z80_a[13:0]};

	// ------------------------------------------------------------------
	// YM2203 — real jt03. Same write-stretch pattern as gunnail_core.sv's
	// own (see header), source signals now the Z80's own I/O bus decode
	// instead of an NMK004 relay.
	// ------------------------------------------------------------------
	reg [7:0] ym_din_latch;
	reg       ym_addr_latch;
	reg [5:0] ym_wr_hold = 6'd0;
	reg       ym_we_prev = 1'b0;
	wire      ym_we_raw = z80_io_we & sel_io_ym;
	always @(posedge clk_sys) begin
		ym_we_prev <= ym_we_raw;
		if (ym_we_raw && !ym_we_prev) begin
			ym_din_latch  <= z80_do;
			ym_addr_latch <= sel_io_ym_data; // 0x02=addr/status (offset0), 0x03=data (offset1)
			// ym_cen's own worst-case gap is 27 clk_sys cycles (inc=3,
			// mod=80 — verified directly by simulating the accumulator);
			// 40 (the same value gunnail_core.sv/macross_core.sv already
			// use for the identical chip/cen setup) safely exceeds that
			// with margin. A shorter hold here risked missing a cen edge
			// entirely and silently dropping the register write.
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
	// OKIM6295 — jt6295, driven directly by the 68000's own bus write at
	// 0x194001 (see header). No bank device layer, but still uses the
	// same latch-and-hold write-stretch pattern this project's other
	// OKI integrations use (see oki_wr_hold below).
	// ------------------------------------------------------------------
	reg [7:0] oki_rom [0:262143]; // 0x40000 bytes (ROM_REGION(0x040000,"oki1"))
	initial if (OKI_ROM_FILE != "") $readmemh(OKI_ROM_FILE, oki_rom);

	wire [17:0] oki_rom_addr;
	reg  [7:0]  oki_rom_data;
	always @(posedge clk_sys) oki_rom_data <= oki_rom[oki_rom_addr[17:0]];

	wire sel_oki_we = sel_oki_w & cpu_write & ~LDSn;
	reg [7:0] oki_din_latch;
	reg [5:0] oki_wr_hold = 6'd0;
	reg       oki_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		oki_we_prev <= sel_oki_we;
		if (sel_oki_we && !oki_we_prev) begin
			oki_din_latch <= oEdb[7:0];
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
		if (sel_z80_rom)        z80_rdata = audiocpu_rom[z80_a[14:0]];
		else if (sel_z80_bank)  z80_rdata = audiocpu_rom[z80_bank_phys[16:0]];
		else if (sel_z80_ram)   z80_rdata = z80_ram[z80_a[12:0]];
		else if (z80_io_re & sel_io_ym) z80_rdata = ym_chip_dout;
		else if (z80_io_soundlatch_re)  z80_rdata = soundlatch_data;
		else                     z80_rdata = 8'hFF;
	end
	assign z80_di = z80_rdata;

	always @(posedge clk_sys) begin
		if (reset) soundlatch2_data <= 8'h00;
		else if (z80_io_we & sel_io_soundlatch) soundlatch2_data <= z80_do;
	end

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
		else if (sel_soundlatch2_r) rdata = {8'h00, soundlatch2_data};
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing (rtl/bjtwin/video_timing.sv) + hacky fixed-scanline
	// IRQ generator (rtl/bjtwin/nmk_irq_hacky.sv) — see header. NOT
	// gunnail_core.sv's own real V-PROM-driven nmk_irq.
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
	// Video pipeline — rtl/gunnail/video_gunnailb.sv (see header for why
	// this is a separate file from video_gunnail.sv, not a shared reuse).
	// ------------------------------------------------------------------
	video_gunnailb #(
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
	assign dbg_z80_nmi_n = z80_nmi_n;
	assign dbg_z80_cen = z80_cen;

	assign dbg_ym_we = ym_we_raw;
	assign dbg_ym_cs = sel_io_ym;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_irq_n = ym_chip_irq_n;

	assign dbg_oki_we = sel_oki_we;
	assign dbg_oki_chip_dout = oki_chip_dout;

endmodule
