// NMK16 MiSTerFPGA project — mustang hardware family (Tier 2, NMK004
// boards) system-level integration.
//
// This is CPU-to-CPU integration work, not a playable core: it wires a
// real 68000 (fx68k, the same core Tier 1's bjtwin_core.sv already
// oracle-verifies) to the completed NMK004 sound board (rtl/tlcs90/
// nmk004_core.sv — CPU + peripherals + interrupt dispatch, all separately
// verified this session, see docs/tier2-tlcs90.md) through the real
// shared-latch host handshake, to answer the specific question the
// CPU-only TLCS-90 testbench (sim/rtl/tlcs90/tb_nmk004.cpp) could not:
// does NMK004 actually get *past* the host-handshake wait loop once a
// real 68000 is on the other end of it? Video (tilemap/sprite rendering)
// and audio (real jt12/jt6295 cores, as opposed to the register-latch
// stubs below) are explicitly NOT in scope here — see "Known
// simplifications" below. Both are natural, separate next increments
// once this milestone's own question is answered.
//
// Memory map (see mustang_map in mame/src/mame/nmk/nmk16.cpp):
//   000000-03FFFF  ROM (maincpu, 2 x 0x20000-byte chips, ROM_LOAD16_BYTE)
//   080000-080001  IN0 (R)
//   080002-080003  IN1 (R)
//   080004-080005  DSW1 (R)
//   08000E-08000F  nopw (writes here are no-ops in the reference)
//   08000F         NMK004 host-read latch (R, byte — nmk004_device::read)
//   080015         flipscreen_w (W, byte)
//   080016-080017  nmk004_x0016_w (W, word) — drives NMK004's NMI line,
//                  bit0 level (a watchdog-keepalive mechanism per the
//                  reference's own comment, not required for the boot
//                  handshake itself to resolve, but wired for real since
//                  nmk004_core.sv already has a real nmi input)
//   08001F         NMK004 host-write latch (W, byte — nmk004_device::write)
//   088000-0887FF  palette RAM, 1024 x 16 (write-captured, not rendered)
//   08C000-08C001  mustang_scroll_w (W, word, write-captured)
//   08C002-08C087  nopw
//   090000-093FFF  bg tilemap VRAM, 8192 x 16 (write-captured, not rendered)
//   09C000-09C7FF  tx tilemap VRAM, 1024 x 16 (write-captured, not rendered)
//   0F0000-0FFFFF  main work RAM, 32768 x 16 — mainram_strange_w: the
//                  reference writes the FULL 16-bit `data` unconditionally,
//                  ignoring UDS/LDS byte-lane strobes entirely (confirmed
//                  by reading the reference source directly — the historical
//                  byte-lane-aware version is `#if 0`'d out, replaced by a
//                  plain unconditional `m_mainram[offset] = data;` with a
//                  comment noting the *68000 core itself* now replicates
//                  mirrored-byte behavior in `data` regardless of mask, so
//                  the handler doesn't need to). This is a REAL, deliberate
//                  divergence from bjtwin_core.sv's own (correctly
//                  byte-lane-gated) mainram write — don't "fix" it to match
//                  that pattern, it would be wrong for mustang specifically.
//
// Known simplifications (documented, not hidden — see bjtwin_core.sv's own
// header for the precedent this follows):
//   - YM2203/OKIM6295 x2 are plain register-latch stubs here (accept
//     writes, return a fixed idle byte on reads), NOT the real jt12/jt6295
//     cores already vendored in rtl/third_party/ — wiring those is real
//     audio-chip integration work, orthogonal to whether the CPU-to-CPU
//     handshake mechanically works, and deliberately deferred to keep this
//     milestone's scope answerable. nmk004_core.sv's own ym_*/oki_* ports
//     are real external ports specifically so this wrapper (or a later,
//     more complete one) can swap in real cores without touching NMK004's
//     own RTL again.
//   - Interrupt generation to the 68000 now uses `nmk_irq_hacky` (Tier
//     1's own synthetic-first fixed-scanline IRQ generator, reused
//     unchanged from rtl/bjtwin/) rather than the reference's *real* IRQ
//     source for this family, `set_interrupt_timing`/`NMK_IRQ` — a
//     PROM-driven scanline state machine (per-game V-PROM dump), which
//     is genuinely separate, substantial video-timing work (see
//     docs/PLAN.md's "nmk_irq timing generator" component) not yet built
//     for this family. This is a deliberate, documented substitution, not
//     an accident: the fixed-scanline table `nmk_irq_hacky` encodes is
//     copied directly from the reference's own
//     `nmk16_hacky_scanline`/`set_hacky_interrupt_timing` — MAME's own
//     documented fallback for exactly this situation (real PROM-driven
//     games with an undumped PROM) — and mustang uses the same "lowres"
//     screen class (`set_screen_lowres`) as Tier 1's bjtwin/cactus, with
//     an *independently confirmed* matching frame geometry (278 total
//     scanlines, VBlank-in at line 16, VBlank-out at line 240 — both the
//     hacky scanline constants and the reference's own frame-timing
//     comment block agree, and both match `video_timing.sv`'s existing
//     bjtwin-family constants exactly), so reusing both modules unchanged
//     is a real methodology match, not a coincidence of convenience. See
//     docs/tier2-system.md for what this unblocks and the oracle-match
//     result. The real per-game PROM timing (and non-lowres games) remain
//     future work.
//   - NMK004's own `clk` is fed a genuine divided-down clock (clk_sys/4,
//     matching the 68000's own bus-cycle divider, since both CPUs are
//     nominally 8MHz per the reference's machine config) rather than a
//     clock-enable pulse on a shared single clock domain — tlcs90.sv has
//     no clock-enable input (every `always @(posedge clk)` fires on `clk`
//     directly), and refactoring that core to add one is out of scope for
//     a simulation-only integration milestone. Real hardware will need
//     either that refactor or genuine independent PLL clocking — flagged
//     as known follow-up work.
//   - DTACKn is tied to ASn (0-wait-state memory), same documented
//     simplification bjtwin_core.sv already uses and the same reasoning:
//     not needed for BRAM-style $readmemh ROM in simulation.
//   - IN0/IN1/DSW1 are tied to fixed idle values (all bits 1), same as
//     bjtwin_core.sv — not yet wired to real HPS_IO input.
module mustang_core #(
	parameter ROM_FILE      = "",
	parameter NMK004_BOOT_FILE = "",
	parameter NMK004_EXT_FILE  = ""
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
	output        dbg_nmk004_valid
);

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	// 68000: exact fx68kTop /4 pattern (see bjtwin_core.sv, reproduced
	// there from rtl/third_party/fx68k/fx68k.sv's own fx68kTop).
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	// NMK004: a genuine divided clock (clk_sys/4 — the MSB of a
	// free-running 2-bit counter is a clean 50%-duty square wave with
	// exactly one rising edge every 4 clk_sys cycles), matching the
	// 68000 side's own ratio — see header's "Known simplifications"
	// (tlcs90.sv has no clock-enable input).
	reg [1:0] nmk004_div = 2'd0;
	always @(posedge clk_sys) nmk004_div <= reset ? 2'd0 : nmk004_div + 2'd1;
	wire nmk004_clk_r = nmk004_div[1];

	// Pixel/raster-timing clock enable for video_timing/nmk_irq_hacky: 8MHz
	// from 32MHz clk_sys (clk_sys/4 — the same ratio the 68000 bus divider
	// above uses, and matching bjtwin's own 8MHz pixel clock; see the
	// header for why the same "lowres" family constants apply here too).
	// Reset-gated (not free-running) for the same reason bjtwin_core.sv's
	// own ce_pix already is: keeps it in lockstep with video_timing's
	// hcount, which is held at 0 through reset.
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

	// Autovector plumbing matches bjtwin_core.sv exactly, including the
	// same DTACKn-must-not-assert-during-IACK fix that project's own
	// history found necessary (see bjtwin_core.sv's header for the full
	// story — a stray vectored-interrupt read instead of autovectoring,
	// caught via PC-trace divergence).
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
	// Address decode
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h03FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h040000); // 080000/080001
	wire sel_in1       = (byte_addr[23:1] == 23'h040001); // 080002/080003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040002); // 080004/080005
	// `byte_addr` is always word-aligned ({eab,1'b0} — the 68000 has no
	// separate byte-address bus, only a word address plus UDS/LDS
	// strobes), so a byte-granular register at an ODD address (like
	// NMK004's own 0x08000F/0x08001F handshake ports) must be matched at
	// the WORD level here and then gated on ~LDSn (the low byte) wherever
	// the actual byte capture happens — exactly like sel_flip already
	// does below. An earlier version of this decode checked
	// `byte_addr == 24'h08000F`/`24'h08001F` directly, which — since
	// byte_addr's LSB is hardwired to 0 — could never match at all: the
	// real 68000's own write to the handshake port was silently falling
	// through unmapped, the root cause of NMK004 never getting past its
	// host-handshake poll loop even with a real 68000 attached. Found via
	// direct 68000 bus-write tracing (see tb_mustang.cpp's TB_LOG_M68K).
	wire sel_nmk004_r  = (byte_addr[23:1] == 23'h040007); // 08000E/08000F word
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A); // 080014/080015, LDS=low byte
	wire sel_nmi       = (byte_addr[23:1] == 23'h04000B); // 080016/080017
	wire sel_nmk004_w  = (byte_addr[23:1] == 23'h04000F); // 08001E/08001F word
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
	// full-word write, byte lanes ignored (see header).
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
	// I/O registers (write-captured only, see header)
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [15:0] scroll_reg;
	reg        nmi_level;

	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			scroll_reg      <= 16'h0000;
			nmi_level       <= 1'b0;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)  flip_screen_reg <= oEdb[7:0];
			if (sel_scroll)        scroll_reg      <= oEdb;
			if (sel_nmi)           nmi_level       <= oEdb[0];
		end
	end

	// Fixed idle input state (see header) — future work: wire to real
	// HPS_IO player input / dipswitch config.
	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// NMK004 sound board
	// ------------------------------------------------------------------
	wire [7:0] nmk004_mcu_to_host;
	wire       nmk004_mcu_to_host_we;
	// Reference default is 0xff (nmk004_device's own to_nmk004(0xff)
	// constructor init) — matches the idle value the CPU-only TLCS-90
	// testbench already ties host_to_mcu to before any real write exists.
	reg  [7:0] nmk004_host_to_mcu = 8'hFF;
	always @(posedge clk_sys) if (cpu_write & sel_nmk004_w & ~LDSn) nmk004_host_to_mcu <= oEdb[7:0];

	// YM2203/OKI register-latch stubs (see header) — accept writes,
	// return a fixed idle byte on reads. Real enough to let boot-time
	// register-table-init loops run to completion without hanging on a
	// busy/status-bit poll (nothing here ever reports "busy").
	wire       ym_cs, ym_we, ym_addr_sel;
	wire [7:0] ym_dout;
	wire       oki0_cs, oki0_we, oki1_cs, oki1_we;
	wire [7:0] oki0_dout, oki1_dout;
	wire       oki0_bank_we, oki1_bank_we;
	wire [7:0] oki0_bank, oki1_bank;

	nmk004_core #(
		.BOOT_ROM_FILE(NMK004_BOOT_FILE),
		.EXT_ROM_FILE(NMK004_EXT_FILE)
	) nmk004 (
		.clk(nmk004_clk_r), .reset(reset),
		.nmi(nmi_level),
		.ym_cs(ym_cs), .ym_we(ym_we), .ym_addr_sel(ym_addr_sel),
		.ym_dout(ym_dout), .ym_din(8'h00),
		.oki0_cs(oki0_cs), .oki0_we(oki0_we), .oki0_dout(oki0_dout), .oki0_din(8'hFF),
		.oki1_cs(oki1_cs), .oki1_we(oki1_we), .oki1_dout(oki1_dout), .oki1_din(8'hFF),
		.oki0_bank_we(oki0_bank_we), .oki0_bank(oki0_bank),
		.oki1_bank_we(oki1_bank_we), .oki1_bank(oki1_bank),
		.host_to_mcu(nmk004_host_to_mcu),
		.mcu_to_host(nmk004_mcu_to_host), .mcu_to_host_we(nmk004_mcu_to_host_we),
		.dbg_pc(dbg_nmk004_pc), .dbg_valid(dbg_nmk004_valid),
		.p4(), .bx(), .by()
	);

	reg [7:0] nmk004_to_host_latch = 8'hFF; // reference default: to_main(0xff)
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
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + interrupt generation — see header for why these
	// two modules (both from rtl/bjtwin/, reused unchanged) apply here.
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);

	wire sprite_dma_trigger; // not consumed yet — no sprite engine in this milestone
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
	// Debug/trace outputs
	// ------------------------------------------------------------------
	assign dbg_eab   = eab;
	assign dbg_data  = cpu_write ? oEdb : iEdb;
	assign dbg_write = cpu_write;
	assign dbg_as_n  = ASn;
	assign dbg_fc0   = FC0;
	assign dbg_fc1   = FC1;
	assign dbg_fc2   = FC2;

endmodule
