// NMK16 MiSTerFPGA project — mustangb (Tier 5, Family E "Raiden sound"
// bootleg of mustang) system-level integration.
//
// First Z80-based port in this project (every prior port used the
// TLCS-90-based NMK004 or protection MCU). Wires a real 68000 (fx68k,
// same pattern as rtl/mustang/mustang_core.sv) to a real Z80 (T80 —
// consumed here as `rtl/third_party_gen/t80/T80s.v`, a GHDL-translated
// Verilog synthesis of the vendored T80 VHDL core, see
// docs/t80-vhdl-toolchain.md for how that was produced and verified;
// the real vendored VHDL itself is what goes into the Quartus hardware
// build) through a new `rtl/seibu/seibu_sound.sv` device (ported from
// `seibu_sound_device`, mame/src/mame/shared/seibusound.{h,cpp} — see
// that file's own header for the full port derivation), plus jtopl2
// (YM3812) and jt6295 (OKIM6295), reusing this project's existing
// jt6295 write-stretch integration pattern from mustang_core.sv.
//
// Video is a DIRECT, UNMODIFIED reuse of rtl/mustang/video_mustang.sv —
// mustang (Family B, NMK004) and mustangb share the identical
// screen_update_macross/gfx_macross/VIDEO_START_OVERRIDE(macross) trio
// in the reference (mame/src/mame/nmk/nmk16.cpp), and mustangb_map
// (nmk16.cpp:682-698) uses the identical VRAM/palette/scroll register
// layout as mustang_map (nmk16.cpp:663-679) for everything except the
// sound/IRQ handshake port. No new video RTL exists in this port.
//
// Interrupt timing: mustangb's own machine config calls
// `set_hacky_interrupt_timing` (nmk16.cpp:4642), NOT the real
// V-PROM-driven `set_interrupt_timing` mustang itself uses — this
// board's timing PROMs are undumped, so MAME substitutes a fixed
// scanline table (nmk16_hacky_scanline, nmk16.cpp:4482-4511). This is
// exactly what Tier 1's `rtl/bjtwin/nmk_irq_hacky.sv` (built for cactus,
// same undumped-PROM situation) already implements — reused unchanged
// here, not reimplemented.
//
// Memory map (see mustangb_map in mame/src/mame/nmk/nmk16.cpp:682-698):
//   000000-03FFFF  ROM (maincpu, 2 x 0x20000-byte chips, ROM_LOAD16_BYTE)
//   080000-080001  IN0 (R)
//   080002-080003  IN1 (R)
//   080004-080005  DSW1 (R)
//   08000E-08000F  noprw — genuinely unmapped on this board (confirmed:
//                  unlike mustang_map, mustangb_map has NO read handler
//                  here at all; mustang's own NMK004 host-read latch
//                  lived at this address, mustangb has nothing there)
//   080015         flipscreen_w (W, byte)
//   080016-080017  nopw ("frame number?" per reference comment — no
//                  register modeled, matches mustang's own nmk004_x0016
//                  NOT being present here either — mustangb doesn't
//                  drive anything real off it)
//   08001E-08001F  seibu_sound_device::main_mustb_w (W, WORD — low byte
//                  -> main2sub[0], high byte -> main2sub[1], then
//                  unconditionally asserts the Z80's RST18 — see
//                  rtl/seibu/seibu_sound.sv's own header)
//   088000-0887FF  palette RAM, 1024 x 16 (real — video_mustang)
//   08C000-08C001  mustang_scroll_w (W, word — real BG X-scroll)
//   08C002-08C087  nopw
//   090000-093FFF  bg tilemap VRAM, 8192 x 16 (real — video_mustang)
//   09C000-09C7FF  tx tilemap VRAM, 1024 x 16 (real — video_mustang)
//   0F0000-0FFFFF  main work RAM, 32768 x 16 — mainram_strange_w, same
//                  unconditional-full-word-write quirk as mustang_map
//                  (see mustang_core.sv's own header for the derivation
//                  — identical function, identical share(m_mainram))
//
// Z80 memory map (seibu_sound_map, seibusound.cpp:333-350):
//   0000-1FFF  ROM (fixed, first 8KB of the 0x20000-byte audiocpu ROM)
//   2000-27FF  RAM (2KB)
//   4000-401F  seibu_sound register block (rtl/seibu/seibu_sound.sv)
//   6000       OKIM6295 (jt6295) — mapped DIRECTLY here, bypassing
//              seibu_sound_device entirely (confirmed: seibu_sound_map's
//              own 0x6000 entry targets "oki", not "seibu_sound")
//   8000-FFFF  banked ROM window, 2 x 0x8000-byte banks at audiocpu ROM
//              file offset 0x10000/0x18000 (seibu_sound's own bank_sel)
//
// Audiocpu ROM layout (ROM_START(mustangb), nmk16.cpp:7041-7044):
// mustang.16 is loaded as ROM_LOAD(0x8000 bytes at region 0) +
// ROM_CONTINUE(0x8000 bytes at region 0x10000) — i.e. the WHOLE
// 0x10000-byte file, split across two non-adjacent region offsets —
// then ROM_COPY duplicates region 0x0-0x7FFF to region 0x18000-0x1FFFF
// (so bank 0 is just the fixed 0-0x1FFF...0x7FFF region repeated).
// Reproduced via tools/mkgfxrom.py's --mode segments (three segments:
// the file's own two halves at their real region offsets, plus a third
// segment re-reading FILE offset 0 into region 0x18000 — byte-identical
// to what ROM_COPY produces, since ROM_COPY's own source data is itself
// verbatim file content with no transformation applied to it).
//
// Known simplifications (same tier as mustang_core.sv's own — see that
// file's header for the general rationale, not repeated here):
//   - jt6295's own write-stretch/rom_ok/bank-arithmetic conventions are
//     reused unchanged from mustang_core.sv (single OKI here, not x2).
//   - jtopl2's cen is derived via an exact-ratio phase accumulator
//     (increment=715909, modulus=6400000 off 32MHz clk_sys — GCD-reduced
//     from 3579545/32000000, since 14318180/4 has no clean power-of-2
//     relationship to clk_sys, unlike the 68000's own /4 8MHz ratio).
//     T80's own CEN uses the identical accumulator — real hardware runs
//     the Z80 and YM3812 off the same 14.31818MHz-derived clock, per the
//     reference's own machine config (both `14318180/4`).
//   - No audio DAC/mixer exists in this simulation harness — jtopl2's
//     `snd`/jt6295's `sound`/`sample` outputs are unused, matching every
//     prior port's own documented scope (bus/register-level correctness,
//     not audio fidelity).
//   - IN0/IN1/DSW1 tied to fixed idle values (all 1s), not yet wired to
//     real HPS_IO input — matches every prior port.
//   - DTACKn tied to ASn (0-wait-state memory) for the 68000 side, same
//     documented simplification every prior port uses. The Z80 side
//     similarly has no WAIT_n source (T80's own WAIT_n tied high) — no
//     peripheral in this system ever needs to insert a wait state.
module mustangb_core #(
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
	// 68000: exact fx68kTop /4 pattern (see bjtwin_core.sv/mustang_core.sv).
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	// Z80 + YM3812 shared clock enable: real hardware clocks both from
	// 14318180/4 = 3579545 Hz (reference: Z80(config,m_audiocpu,
	// 14318180/4) and YM3812(config,"ymsnd",14318180/4) — the identical
	// divisor). 3579545/32000000 has no clean power-of-2 reduction
	// (unlike the 68000's own /4), so this is an exact-ratio phase
	// accumulator instead: GCD(3579545,32000000)=5, giving
	// increment=715909, modulus=6400000 — the long-run average rate is
	// exactly right, with the same bounded per-edge jitter this
	// project's own jt03/jt6295 cen generators already accept (see
	// mustang_core.sv's header).
	localparam integer Z80_CEN_INC = 715909;
	localparam integer Z80_CEN_MOD = 6400000;
	reg [22:0] z80_cen_acc = 23'd0;
	reg        z80_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (z80_cen_acc + Z80_CEN_INC >= Z80_CEN_MOD) begin
			z80_cen_acc <= z80_cen_acc + Z80_CEN_INC - Z80_CEN_MOD;
			z80_cen <= 1'b1;
		end else begin
			z80_cen_acc <= z80_cen_acc + Z80_CEN_INC;
			z80_cen <= 1'b0;
		end
	end

	// OKIM6295: reference uses 1320000 Hz (OKIM6295(config,"oki",1320000,
	// PIN7_LOW)). GCD(1320000,32000000)=40000 -> increment=33,
	// modulus=800 (exact ratio, small accumulator).
	reg [9:0] oki_cen_acc = 10'd0;
	wire      oki_cen = (oki_cen_acc + 10'd33 >= 10'd800);
	always @(posedge clk_sys) oki_cen_acc <= oki_cen ? (oki_cen_acc + 10'd33 - 10'd800) : (oki_cen_acc + 10'd33);

	// Pixel/raster-timing clock enable for video_timing/nmk_irq_hacky:
	// 8MHz from 32MHz clk_sys — same ratio/reset-gating convention as
	// every prior "lowres" family port (see mustang_core.sv's header).
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

	// Autovector plumbing matches every prior port exactly (see
	// bjtwin_core.sv's header for the DTACKn-must-not-assert-during-IACK
	// history).
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
	// Address decode (68000 side)
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h03FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1       = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040002); // 080004/080005
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015, LDS=low byte
	wire sel_mustb     = (byte_addr[23:1] == 23'h04000F); // 08001E/08001F word
	wire sel_palette   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h0887FF);
	wire sel_scroll    = (byte_addr[23:1] == 23'h046000); // 08C000/08C001
	wire sel_bgvram    = (byte_addr >= 24'h090000) && (byte_addr <= 24'h093FFF);
	wire sel_txvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09C7FF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu)
	// ------------------------------------------------------------------
	reg [15:0] rom [0:131071]; // 0x20000 words = 0x40000 bytes
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[17:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — mainram_strange_w: unconditional
	// full-word write, byte lanes ignored (see mustang_core.sv's header).
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr = byte_addr[15:1];
	reg [15:0] mainram_dout;
	always @(posedge clk_sys) begin
		if (sel_mainram & cpu_write) mainram[mainram_addr] <= oEdb;
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
	// Dual-port video read taps (video_mustang.sv's own live reads)
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
	// I/O registers (write-captured only)
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [15:0] bg_xscroll_reg;
	reg        mustb_we_pulse;
	reg [15:0] mustb_data_r;

	always @(posedge clk_sys) begin
		mustb_we_pulse <= 1'b0;
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bg_xscroll_reg  <= 16'h0000;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)  flip_screen_reg <= oEdb[7:0];
			if (sel_scroll) begin
				case (oEdb[15:8])
					8'h00: bg_xscroll_reg[15:8] <= oEdb[7:0];
					8'h01: bg_xscroll_reg[7:0]  <= oEdb[7:0];
					default: ;
				endcase
			end
			if (sel_mustb) begin
				// main_mustb_w (seibusound.cpp:319-329): RST18 asserts
				// unconditionally, but each byte latch only updates if its
				// own lane was actually accessed (ACCESSING_BITS_0_7/8_15) —
				// a byte-narrow write must leave the other half's previous
				// value alone, matching this file's own UDSn/LDSn gating
				// convention used for palette/bgvram/txvram above.
				mustb_we_pulse <= 1'b1;
				if (~LDSn) mustb_data_r[7:0]  <= oEdb[7:0];
				if (~UDSn) mustb_data_r[15:8] <= oEdb[15:8];
			end
		end
	end

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// Z80 sound board: T80 + seibu_sound + jtopl2 + jt6295
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

	// Audiocpu ROM: full 0x20000-byte flat image (see header's "Audiocpu
	// ROM layout" for how tools/mkgfxrom.py --mode segments reproduces
	// the reference's ROM_LOAD+ROM_CONTINUE+ROM_COPY layout byte-for-byte).
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

	// ------------------------------------------------------------------
	// YM3812 — jtopl2 (jotego's OPL2 core). cen shared with T80 (see
	// header's clock-enable note). No write-stretch needed here (unlike
	// jt03/jt6295 in mustang_core.sv, driven by a much-slower nmk004_clk_r
	// source cross-domain write): ym_we is generated directly off the
	// Z80's own bus strobes at the SAME clock enable jtopl2 itself
	// samples on, so a `wr_n` pulse aligned to z80_cen is inherently at
	// least one whole z80_cen period wide — no separate clock domain to
	// bridge.
	// ------------------------------------------------------------------
	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	jtopl2 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(z80_cen),
		.din(ym_wdata), .addr(ym_addr_sel), .cs_n(~ym_cs), .wr_n(~ym_we),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.snd(), .sample()
	);
	assign ym_rdata = ym_chip_dout;

	// ------------------------------------------------------------------
	// OKIM6295 — jt6295 (single chip here, unlike mustang's x2). Same
	// write-stretch/rom_ok/bank-arithmetic pattern as mustang_core.sv's
	// own jt6295 integration (see that file's header) — z80_a==0x6000 is
	// a Z80-domain strobe just like nmk004's own oki_we, narrower than
	// jt6295's own cen period, so it needs the same latch-and-hold.
	// ------------------------------------------------------------------
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
	// Video pipeline — rtl/mustang/video_mustang.sv, unmodified (see
	// header).
	// ------------------------------------------------------------------
	video_mustang #(
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
		.bg_xscroll_reg(bg_xscroll_reg),
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
