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
// real 68000 is on the other end of it? Audio is real for both YM2203
// (jt03, jotego's clone — see "Real jt03 (YM2203) integration" below)
// and OKIM6295 x2 (jt6295, jotego's clone — see "Real jt6295 (OKIM6295
// x2) integration" below, including the actual ADPCM sample ROM data
// extracted from the real romset and the RET Z @0x0E5F oracle divergence
// this directly resolves — see docs/tier2-system.md). Video (tilemap +
// sprite rendering) is now real too — see rtl/mustang/video_mustang.sv's
// own header for the full derivation of that pipeline; this file just
// owns the VRAM/palette storage and the register decode video_mustang
// reads from (bg_xscroll_reg, sel_bgvram/txvram/palette).
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
//   088000-0887FF  palette RAM, 1024 x 16 (real — rendered by video_mustang)
//   08C000-08C001  mustang_scroll_w (W, word — real BG X-scroll, see
//                  "I/O registers" below)
//   08C002-08C087  nopw
//   090000-093FFF  bg tilemap VRAM, 8192 x 16 (real — rendered by video_mustang)
//   09C000-09C7FF  tx tilemap VRAM, 1024 x 16 (real — rendered by video_mustang)
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
//   - Real jt03/jt6295 audio timing/mixing is not consumed anywhere in
//     this simulation harness (no DAC/mixer exists here) — this
//     integration is specifically about each chip's bus/register-level
//     behavior (busy/status bits, IRQ, ROM sample fetch) being real, not
//     about audio fidelity or even necessarily cycle-exact synthesis
//     timing.
//   - jt03's and jt6295's own bus writes are "stretched" (see the
//     write-stretch logic near each instantiation below) rather than
//     passed through as the raw single-nmk004_clk_r-cycle pulse
//     nmk004_core.sv's ym_we/oki0_we/oki1_we naturally are: neither chip
//     has a bus-ready/ack output (real YM2203/OKIM6295 hardware doesn't
//     either — they just expect WR held for their own minimum pulse
//     width) and each only samples its bus inputs on its own cen pulses
//     (jt03) or every clk_sys cycle but still needs a stable pulse width
//     (jt6295), either of which could otherwise land entirely between
//     two cen edges and miss a narrow write outright. This is a real,
//     necessary integration detail for any bus-driven peripheral running
//     on a slower clock-enable than the CPU issuing the write, not
//     specific to either chip.
//   - jt6295's own `rom_ok` is tied constant high and its ROM reads are a
//     single-clk_sys-cycle-latency registered array lookup (a standard
//     FPGA-BRAM-style simplification, matching jt6295_rom.v's own
//     built-in latency tolerance — see its header comment) rather than
//     modeling real SDRAM arbitration latency, since there's no SDRAM
//     controller in this simulation harness at all.
//   - Bank 3 of each OKI ROM's banked window (`0x20000-0x3FFFF` on the
//     chip's own 18-bit address space) is architecturally out of range
//     for the dumped 512KB sample ROMs — the reference's own bank
//     arithmetic (`(bank+1)*0x20000 + offset`) computes an address one
//     full bank past the end of the ROM region for bank 3, a latent
//     quirk in the original hardware/MAME driver, not something this
//     integration introduces (see "Real jt6295" below for the derivation
//     and no evidence mustang's own firmware ever selects it). Wrapped
//     (masked) into the ROM's own size here rather than read out of
//     bounds, so an unexpected bank 3 selection reads deterministic data
//     instead of X in simulation.
//   - Interrupt generation to the 68000 now uses the real
//     `rtl/nmk_irq/nmk_irq.sv` — the actual dual-PROM-driven scanline
//     state machine (`set_interrupt_timing`/`NMK_IRQ` in the reference),
//     ported directly from `nmk_irq_device::scanline_callback` and driven
//     by mustang's own real, dumped V-PROM (`10.bpr`), replacing the
//     earlier `nmk_irq_hacky` fixed-scanline substitution (Tier 1's own
//     synthetic-first generator, still used unchanged for cactus, whose
//     real PROM is undumped). Building the real module surfaced a
//     genuine phase-calibration constant between MAME's own
//     `screen.vpos()` and this project's own `vcount` (both 0..277 over
//     the same 278-line frame, but with a different zero reference) —
//     empirically found and verified via a live MAME debugger capture
//     against real ISR-entry scanlines, not assumed — see
//     `rtl/nmk_irq/nmk_irq.sv`'s own header and docs/tier2-system.md's
//     "Milestone 5" for the full derivation. The real per-game H-timing
//     PROM is still not consumed (MAME's own reference device doesn't
//     consume it either — see that module's header), and non-lowres
//     screen classes remain future work for other families.
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
	parameter NMK004_EXT_FILE  = "",
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

	// YM2203 (jt03) bus/IRQ debug — same tier as dbg_eab/dbg_write above,
	// not throwaway bring-up scaffolding (kept permanently, matching
	// tb_mustang.cpp's own TB_LOG_M68K precedent) — see
	// docs/tier2-system.md's "Milestone 3" for what these found.
	output        dbg_ym_we,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_chip_irq_n,

	// OKIM6295 x2 (jt6295) bus debug — same tier as dbg_ym_* above; see
	// docs/tier2-system.md's "Real jt6295 (OKIM6295 x2) integration" for
	// what these found (the RET Z @0x0E5F root cause).
	output        dbg_oki0_we,
	output        dbg_oki0_cs,
	output  [7:0] dbg_oki0_chip_dout,
	output        dbg_oki1_we,
	output        dbg_oki1_cs,
	output  [7:0] dbg_oki1_chip_dout,

	// NMK004 live register/RAM-peek debug — for root-causing the RET Z at
	// 0x0E5F oracle divergence (see docs/tier2-system.md, "RET Z at
	// 0x0E5F"); same tier as dbg_ym_* above, not throwaway scaffolding.
	output [7:0]  dbg_nmk004_a,
	output [7:0]  dbg_nmk004_f,
	output [15:0] dbg_nmk004_hl,
	output [7:0]  dbg_nmk004_ram_hl,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	// — see rtl/mustang/video_mustang.sv's own header for the pipeline
	// this drives.
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

	// Pixel/raster-timing clock enable for video_timing/nmk_irq: 8MHz
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

	// NMK004's own P4 bit0 drives the 68000's reset line in the reference
	// (nmk004_device::port4_w -> reset_cb().set_inputline(m_maincpu,
	// INPUT_LINE_RESET)) — a REAL hold-then-release handshake (NMK004's
	// own boot firmware can hold the 68000 in reset while it finishes its
	// own init, then release it), not "future work" any more. `pwrUp`
	// stays tied to the system-wide `reset` alone (true cold power-on
	// only, not re-triggered by this runtime hold/release).
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
	// Dual-port video read taps — video_mustang.sv's own live, per-pixel
	// reads into the same arrays above, on a separate address bus from
	// the CPU's own (mustang_core.sv owns the storage, matching
	// bjtwin_core.sv/video_bjtwin.sv's own established split).
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

	// Palette/BG/TX VRAM debug taps — same tier as dbg_ym_*/dbg_oki_*
	// above, kept permanently (see tb_mustang.cpp's TB_DUMP_VRAM).
	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bgvram_data = bgvram[dbg_bgvram_addr];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

	// ------------------------------------------------------------------
	// I/O registers (write-captured only, see header)
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	// mustang_scroll_w: a single 16-bit port sequenced as two byte-writes
	// by the upper byte of `data` (0x00=set X-scroll high byte, 0x01=set
	// low byte, 0x02/0x03=dead per the reference's own switch — see
	// nmk16_v.cpp). Replicated directly rather than storing the raw last
	// write (see rtl/mustang/video_mustang.sv's own header).
	reg [15:0] bg_xscroll_reg;
	reg        nmi_level;

	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bg_xscroll_reg  <= 16'h0000;
			nmi_level       <= 1'b0;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)  flip_screen_reg <= oEdb[7:0];
			if (sel_scroll) begin
				case (oEdb[15:8])
					8'h00: bg_xscroll_reg[15:8] <= oEdb[7:0];
					8'h01: bg_xscroll_reg[7:0]  <= oEdb[7:0];
					default: ;
				endcase
			end
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

	wire       ym_cs, ym_we, ym_addr_sel;
	wire [7:0] ym_dout;
	wire       oki0_cs, oki0_we, oki1_cs, oki1_we;
	wire [7:0] oki0_dout, oki1_dout;
	wire       oki0_bank_we, oki1_bank_we;
	wire [7:0] oki0_bank, oki1_bank;

	// ------------------------------------------------------------------
	// YM2203 — real jt03 (jotego's YM2203 clone), replacing the earlier
	// register-latch stub. See header's "Real jt03 (YM2203) integration"
	// note for the write-stretch rationale.
	// ------------------------------------------------------------------
	// 1.5MHz from 32MHz clk_sys (matching the reference's own
	// YM2203(config,"ymsnd",1500000)) — 1.5/32 = 3/64 exactly, so a plain
	// phase accumulator gives an exact rate with no fractional error:
	// increment by 3 mod 64 every clk_sys cycle, pulse on each wraparound
	// (3 evenly-spaced pulses every 64 cycles).
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

	// jt03 has no bus-ready/ack output (matching real YM2203 hardware,
	// which simply expects WR held for at least its own minimum pulse
	// width) — but its cen pulses only ~every 21 clk_sys cycles on
	// average, while nmk004's own ym_we is a single nmk004_clk_r cycle
	// wide (4 clk_sys cycles), which could land entirely between two cen
	// pulses and be missed outright. Latch the write request (address +
	// data) on ym_we's rising edge and hold wr_n asserted for long enough
	// (40 clk_sys cycles, comfortably more than one cen period) to
	// guarantee at least one jt03 cen pulse samples it, rather than
	// passing the narrow raw pulse straight through.
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
		// Embedded YM2149 I/O pins — nothing in this milestone drives
		// them (mustang's own boot code doesn't touch the PSG I/O ports).
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		// Audio outputs unused in this milestone (no DAC/mixer in this
		// simulation harness) — this integration is about bus/register-
		// level correctness (busy/status bits, IRQ), not audio fidelity.
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(), .snd(), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — real jt6295 (jotego's clone), replacing the earlier
	// register-latch stub. See header's "Real jt6295 (OKIM6295 x2)
	// integration" notes for the write-stretch/rom_ok/bank-3 rationale.
	// ------------------------------------------------------------------
	// The reference's own mustang() config uses 16000000/4 = 4MHz for
	// both OKIM6295 chips, PIN7_LOW. jt6295_timing.v's own header says its
	// `cen` input "should be 1,000 kHz" regardless of the ss/PIN7 setting
	// (ss only changes the *internal* sample-rate divider, not the cen
	// rate jt6295 itself expects) — 1MHz from 32MHz clk_sys is an exact
	// /32, so a plain free-running 5-bit counter suffices (no fractional
	// accumulator needed, unlike jt03's 3/64 case).
	reg [4:0] oki_cen_cnt = 5'd0;
	wire      oki_cen = (oki_cen_cnt == 5'd31);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 5'd0 : oki_cen_cnt + 5'd1;

	// PIN7_LOW (the reference's okim6295_device::PIN7_LOW) is jt6295's
	// ss=0 — jt6295_timing.v's own header comment ("SS low = divides by
	// 164") is the same "slow"/"low" sample-rate mode PIN7_LOW selects on
	// real silicon.
	localparam OKI_SS = 1'b0;

	// Sample ROMs (90058-5/90058-6 in the real romset — see
	// tools/mkgfxrom.py's --mode concat, used to extract these). Each is
	// 512KB (0x80000), matching ROM_REGION(0x080000,"oki1"/"oki2") in the
	// reference exactly.
	reg [7:0] oki1_rom [0:524287];
	reg [7:0] oki2_rom [0:524287];
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki1_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki2_rom);

	// Bank registers — nmk004_core.sv's own oki0_bank/oki1_bank outputs
	// are the raw, unmasked latch value (see that module's header: bank
	// storage is deliberately left to the system wrapper, matching how
	// the reference's own m_okibank memory_bank objects live outside
	// nmk004_device too). Reference masks to 2 bits (`data & 3`,
	// nmk004_device::oki_bankswitch_w) before using it as a bank index;
	// replicated here. Sampling on clk_sys is safe even though
	// oki0_bank_we is generated on the nmk004_clk_r domain — it's a
	// genuinely divided-down clk_sys, not an independent clock, so its
	// own edges already meet clk_sys's setup/hold and the value is stable
	// for multiple clk_sys cycles either side of the update.
	reg [1:0] oki1_bank_r = 2'd0, oki2_bank_r = 2'd0;
	always @(posedge clk_sys) begin
		if (oki0_bank_we) oki1_bank_r <= oki0_bank[1:0];
		if (oki1_bank_we) oki2_bank_r <= oki1_bank[1:0];
	end

	// Address mapping — matches the reference's oki1_map/oki2_map exactly
	// (mame/src/mame/nmk/nmk16.cpp): jt6295's own 18-bit rom_addr is the
	// chip's own address space (bit17=0: fixed 0x00000-0x1FFFF; bit17=1:
	// banked 0x20000-0x3FFFF window), and the *reference's* bank
	// arithmetic is `(bank+1)*0x20000 + rom_addr[16:0]` (bank 0 maps to
	// physical 0x20000-0x3FFFF, ..., bank 3 to 0x80000-0x9FFFF — one full
	// bank past the dumped ROM's own 512KB end, see the header's "Known
	// simplifications" note on bank 3). Wrapped into the ROM's own 19-bit
	// size (masked, not clamped) so an actual bank-3 selection is
	// deterministic in simulation rather than X.
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

	// Registered (1-clk_sys-cycle-latency) ROM reads, matching
	// jt6295_rom.v's own built-in latency tolerance — see the header's
	// "Known simplifications" note. rom_ok tied high: no wait states to
	// model with an internal $readmemh array (no SDRAM controller exists
	// in this simulation harness at all).
	reg [7:0] oki1_rom_data, oki2_rom_data;
	always @(posedge clk_sys) oki1_rom_data <= oki1_rom[oki1_phys];
	always @(posedge clk_sys) oki2_rom_data <= oki2_rom[oki2_phys];

	// Write-stretch — same rationale as jt03's ym_wr_n above, duplicated
	// per chip (oki0_we/oki1_we are each a single nmk004_clk_r-cycle-wide
	// pulse, same source clock domain as ym_we).
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
	// Raster timing (rtl/bjtwin/video_timing.sv, reused unchanged) + real
	// interrupt generation (rtl/nmk_irq/nmk_irq.sv, replacing the earlier
	// nmk_irq_hacky.sv fixed-scanline substitution — see header's "Real
	// nmk_irq" note and docs/tier2-system.md's "Milestone 5").
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);

	wire sprite_dma_trigger; // consumed by video_mustang below
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
	// Video pipeline — real tilemap + sprite rendering. See
	// rtl/mustang/video_mustang.sv's own header for the full derivation.
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

	// frame_done marks a real raster frame boundary (vcount wrap),
	// generated directly off the shared vtiming counter — same
	// convention as bjtwin_core.sv's own (see its header for why).
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
