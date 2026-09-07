// NMK16 MiSTerFPGA project — SHARED Family C system-level integration,
// serving BOTH tdragon2 and macross2 from one core (module name kept as
// "tdragon2_core" — tdragon2 was the pilot game and this file's own
// identity predates the merge; renaming would touch a wide, working blast
// radius of Makefiles/testbenches/Quartus sources for no functional gain).
// Game selection is a genuine RUNTIME input (game_macross2 below), not a
// synthesis-time parameter — see docs/hw-bringup.md: this is what lets one
// Macross2.rbf boot either game, selected by a hidden status[] bit each
// game's own .mra sets on load (see Macross2.sv's own header).
//
// This merge exists because `tdragon2()` and `macross2()`'s own machine
// configs (nmk16.cpp:5490-5533 / 5444-5488) are BYTE-FOR-BYTE IDENTICAL
// (same 68000/Z80 clocks, same macross2_sound_map/io_map — literally the
// same functions — same gfx_macross2/VIDEO_START_OVERRIDE(macross2), same
// NMK112/dual-OKI setup) except for exactly ONE genuine runtime behavior
// difference (mainram address-line swap, below) plus two things that
// turned out NOT to need per-game switching at all once checked directly
// against the reference rather than assumed:
//
//   - V-PROM content: tdragon2's own "10.bpr" and macross2's own
//     "mcrs2bpr.10" have IDENTICAL CRC32/SHA1 (e6ead349 /
//     6d81b1c0233580aa48f9718bade42d640e5ef3dd) — same physical PROM,
//     same board family, one shared VTIMING_FILE genuinely suffices for
//     both games (not just "close enough" — byte-identical).
//   - NMK112 ROM1_BYTES (oki2 chip sizing, rtl/nmk112/nmk112.sv): the
//     ONLY effect of this parameter is masking WRITTEN bank-select page
//     indices (`data & MASK1`, MASK1 = ROM1_BYTES/65536 - 1). tdragon2's
//     own oki2 is 0x200000 (MASK1=0x1F, 32 pages); macross2's own oki2 is
//     HALF that, 0x100000 (16 pages) — but using tdragon2's wider mask
//     for macross2 too is provably harmless: macross2's own game code
//     never writes a bank index beyond its own real chip's 16-page range
//     (there is nothing on that PCB to select), so the extra mask
//     headroom is simply never exercised. Kept at tdragon2's fixed
//     (wider) sizing unconditionally below — no runtime toggle needed.
//
// Difference (the one genuine runtime behavior split) — mainram
// address-line swap (nmk16.cpp:280-288,1100-1104): `tdragon2_map` is
// `macross2_map(map)` plus one override,
// `map(0x1f0000,0x1fffff).rw(mainram_swapped_r,mainram_swapped_w)`, which
// applies `bitswap<16>(offset,15,14,13,12,11,7,9,8,10,6,5,4,3,2,1,0)` to the
// WORD OFFSET before indexing m_mainram — verified independently (not
// trusted from the bit-list alone) that this swaps ONLY address bits 7 and
// 10 with each other; every other bit passes through unchanged. A real PCB
// address-line miswiring, faithfully replicated — NOT a data-bit scramble.
// macross2_map itself has no such override at all. Selected below by the
// game_macross2 runtime input (mainram_addr_cpu computation) — a single
// small mux, negligible LE cost, no separate core copy needed.
//
// CRITICAL: this swap applies ONLY to the 68000 CPU-facing bus handler
// (mainram_swapped_r/w, both directions) — it does NOT apply to MAME's own
// sprite-DMA snapshot mechanism. Confirmed directly: `sprite_dma()`
// (nmk16.cpp:4518-4524, the SAME shared function every game in this driver
// uses, including tdragon2 via nmk_irq's own sprite_dma_cb) does a raw C++
// `memcpy(m_spriteram_old.get(), m_mainram + m_sprdma_base/2, 0x1000)` —
// this bypasses MAME's own address_map dispatch entirely (it's a direct
// pointer read of the underlying array member, not a call through the
// swapped handler), so it reads the SAME raw, unswapped physical layout the
// CPU's own swapped writes actually land in. video_macross2.sv's own
// mainram_addr/mainram_data tap (used for exactly this sprite-snapshot
// mechanism, see that file's own header/body) therefore must stay
// UNSWAPPED for tdragon2, reading the SAME raw `mainram` array the
// CPU-facing accessor also indexes into — only the CPU-facing address
// computation below is swapped, and only for tdragon2 (game_macross2=0).
// For macross2 (game_macross2=1) there is no swap on EITHER path at all —
// both taps already compute the same way, so this asymmetry is naturally
// game_macross2-gated purely by the mainram_addr_cpu mux below; the video
// tap itself needs no separate per-game logic.
//
// Everything else — clock derivation, address decode, I/O register
// wiring, Z80 sound path, video pipeline instantiation, real V-PROM
// nmk_irq wiring, all HW_ROMS=1 SDRAM infrastructure — serves both games
// identically, unconditional on game_macross2.
module tdragon2_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI1_ROM_FILE  = "",
	parameter OKI2_ROM_FILE  = "",
	parameter VTIMING_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = "",
	// See docs/hw-bringup.md. HW_ROMS=0 (default, every existing sim
	// testbench): behavior is completely unchanged from before this
	// parameter existed — $readmemh-loaded 0-latency arrays. HW_ROMS=1
	// (the real hardware top-level only): every ROM region instead reads
	// through rom_cache1/sdram_arb over the real rtl/sdram.sv controller,
	// loaded via ioctl_download rather than $readmemh.
	parameter HW_ROMS        = 0
) (
	input clk_sys,        // 40 MHz (68000 bus clk_sys/4=10MHz; pixel/raster clk_sys/5=8MHz)
	input reset,            // async, active high

	// Runtime game select — 0=tdragon2, 1=macross2 (see this file's own
	// header). Every existing sim testbench that doesn't drive this port
	// leaves it floating at 0 (tdragon2 behavior), byte-for-byte
	// unchanged from before this port existed.
	input game_macross2,

	// ------------------------------------------------------------------
	// Hardware-mode-only ports (HW_ROMS=1). Unused/unconnected at
	// HW_ROMS=0 — every existing sim testbench instantiates this module
	// without them, which Verilator/Quartus both accept (floating
	// inputs default to 0, unconnected outputs are simply unread).
	// ------------------------------------------------------------------
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0]  ioctl_addr,
	input      [7:0]  ioctl_dout,
	// Real MiSTer hps_io.sv already has an ioctl_wait INPUT specifically
	// for this: each SDRAM write takes several clk_sys cycles to
	// complete, far more than one ioctl_wr pulse's own spacing, so the
	// downloader must be held off between bytes or most writes are
	// silently dropped (sdram_req.sv correctly ignores a new request
	// while the previous one is still in flight). This is not just a
	// testbench convenience — it's the real, required backpressure path.
	output            ioctl_wait,

	// SDRAM port 0: ioctl_download writes (whole address space) muxed
	// with maincpu program-ROM reads — mutually exclusive in time (the
	// core is held in reset for the whole download), so a plain mux on
	// ioctl_download, no arbitration needed.
	output     [24:1] sd0_addr,
	output            sd0_wrl,
	output            sd0_wrh,
	output     [15:0] sd0_din,
	input      [15:0] sd0_dout,
	output            sd0_req,
	input             sd0_ack,

	// SDRAM port 1: Z80 audiocpu program-ROM reads only.
	output     [24:1] sd1_addr,
	output            sd1_req,
	input      [15:0] sd1_dout,
	input             sd1_ack,

	// SDRAM port 2: passed straight through to video_macross2.sv's own
	// HW_ROMS ports (that module owns the 3-way BG/TX/sprite arbiter).
	output     [24:1] sd2_addr,
	output            sd2_wrl,
	output            sd2_wrh,
	output     [15:0] sd2_din,
	input      [15:0] sd2_dout,
	output            sd2_req,
	input             sd2_ack,

	// SDRAM port 3: OKI0/OKI1 sample reads, 2-way arbitrated internally.
	output     [24:1] sd3_addr,
	output            sd3_req,
	input      [15:0] sd3_dout,
	input             sd3_ack,

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
	output        dbg_z80_reset_n,
	output        dbg_z80_cen,

	output        dbg_ym_we,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_irq_n,

	output        dbg_oki0_we,
	output        dbg_oki1_we,
	output  [7:0] dbg_oki0_chip_dout,
	output  [7:0] dbg_oki1_chip_dout,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [14:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done,

	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	// Real raster timing, for the hardware top-level's own video sync
	// generation — video_timing.sv lives inside this module (shared
	// with the CPU interrupt generator below), so this is the only way
	// a real top-level can derive HSync/VSync from the same counters
	// nmk_irq.sv itself uses. Unused by every existing sim testbench.
	output        ce_pix_o,
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,
	output        hblank_o,
	output        vblank_o,

	// Real inputs (HW_ROMS=1 top-level only — see the HW_ROMS-gated mux
	// below, which falls back to the exact same fixed 0xFFFF "idle"
	// constant every existing sim testbench already implicitly relies on
	// at HW_ROMS=0, so leaving these unconnected there is exactly
	// byte-for-byte unchanged; Verilator doesn't accept ANSI default
	// values on plain `input` ports in this module's own port-list
	// style, hence the explicit generate-gated fallback instead of a
	// port default). IN0 (nmk16.cpp tdragon2/macross2 INPUT_PORTS):
	// coin/start/service, active low, low byte only. IN1: 2-player
	// 8-way joystick + 2 buttons each, active low, full word.
	input  [15:0] in0_i,
	input  [15:0] in1_i,
	input  [15:0] dsw1_i,
	input  [15:0] dsw2_i
);

	// ------------------------------------------------------------------
	// HW_ROMS=1 only: a power-on-only reset for the SDRAM req/arb
	// instances (sd0/sd1/oki_arb below, and video_macross2.sv's own),
	// deliberately NOT the same as the `reset` port above. `reset` stays
	// asserted for the whole ioctl_download window (correctly, to keep
	// the CPU/game logic quiescent while its ROMs load) — but the SDRAM
	// path itself must keep working THROUGH that same window to actually
	// perform the download. Tying sdram_req.sv's own reset to the game
	// `reset` would hold it permanently reset for the entire download,
	// silently dropping every single write (found exactly this way: a
	// real hardware-mode test run showed 0 bytes ever landing, traced to
	// this). Real MiSTer cores make the same distinction — the SDRAM
	// controller resets once at FPGA configuration (or PLL lock), not on
	// every user-triggered "soft" game reset.
	reg [3:0] por_cnt = 4'd0;
	reg       por_rst = 1'b1;
	always @(posedge clk_sys) if (por_rst) begin
		if (por_cnt == 4'd15) por_rst <= 1'b0;
		else por_cnt <= por_cnt + 4'd1;
	end

	// ------------------------------------------------------------------
	// Clock enables — identical to macross2_core.sv's own (see that
	// file's own header).
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	reg [3:0] z80_div = 4'd0;
	always @(posedge clk_sys) z80_div <= (z80_div == 4'd9) ? 4'd0 : z80_div + 4'd1;
	wire z80_cen = (z80_div == 4'd9);

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

	reg [5:0] oki_cen_cnt = 6'd0;
	wire      oki_cen = (oki_cen_cnt == 6'd39);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 6'd0 : oki_cen_cnt + 6'd1;

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
	// HW_ROMS=1 only: hold DTACKn off while the maincpu ROM cache hasn't
	// yet produced data for the current address (see rom_cache1/sd0
	// wiring below), or while the mainram/bgvram registered read (see
	// g_mainram_read_hw/g_bgvram_read_hw below — needed for RAM
	// inference, same reasoning as the ROM cache) hasn't settled yet for
	// the current address — every other region stays real 0-wait on-chip
	// work RAM, unaffected. At HW_ROMS=0, rom_ready/mainram_ready/
	// bgvram_ready are all tied to 1'b1 (see each region's own g_*_sim
	// branch), so this composite reduces to the original DTACKn exactly,
	// byte-for-byte, for every existing sim testbench.
	wire rom_wait     = sel_rom     & cpu_read & ~rom_ready;
	wire mainram_wait = sel_mainram & cpu_read & ~mainram_ready;
	wire bgvram_wait  = sel_bgvram  & cpu_read & ~bgvram_ready;
	wire txvram_wait  = sel_txvram  & cpu_read & ~txvram_ready;
	wire DTACKn = ASn | iack_cycle | rom_wait | mainram_wait | bgvram_wait | txvram_wait;

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(1'b1), // no protection MCU on this board
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
	// Address decode (68000 side) — identical addresses to macross2_map's
	// own (see macross2_core.sv's header) except mainram, below.
	// ------------------------------------------------------------------
	wire sel_rom       = (byte_addr <= 24'h07FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h080000); // 100000/100001
	wire sel_in1       = (byte_addr[23:1] == 23'h080001); // 100002/100003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h080004); // 100008/100009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h080005); // 10000A/10000B
	wire sel_soundlatch2_r = (byte_addr[23:1] == 23'h080007); // 10000E/10000F word, byte reg at odd
	wire sel_flip      = (byte_addr[23:1] == 23'h08000A); // 100014/100015, LDS=low byte
	wire sel_sndreset  = (byte_addr[23:1] == 23'h08000B); // 100016/100017 word
	wire sel_tilebank  = (byte_addr[23:1] == 23'h08000C); // 100018/100019, LDS=low byte
	wire sel_soundlatch_w = (byte_addr[23:1] == 23'h08000F); // 10001E/10001F word, byte reg at odd
	wire sel_palette   = (byte_addr >= 24'h120000) && (byte_addr <= 24'h1207FF);
	wire sel_scroll    = (byte_addr >= 24'h130000) && (byte_addr <= 24'h130007);
	wire sel_bgvram    = (byte_addr >= 24'h140000) && (byte_addr <= 24'h14FFFF);
	wire sel_txvram    = (byte_addr >= 24'h170000) && (byte_addr <= 24'h171FFF);
	wire sel_mainram   = (byte_addr >= 24'h1F0000) && (byte_addr <= 24'h1FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu) — 0x80000 bytes = 262144 words. HW_ROMS=0: unchanged
	// $readmemh sim array, 0-latency. HW_ROMS=1: rom_cache1 over SDRAM
	// port 0 (base offset 0x000000 in the layout docs/hw-bringup.md
	// documents), shared with ioctl_download writes via a plain mux
	// (mutually exclusive in time — the core stays in reset for the
	// whole download). A real wait-state: DTACKn is held off (via
	// rom_wait below) until the cache reports ready for the current
	// address, unlike every other still-0-latency on-chip region.
	// ------------------------------------------------------------------
	wire [15:0] rom_dout;
	wire        rom_ready;
	generate
	if (!HW_ROMS) begin : g_rom_sim
		reg [15:0] rom [0:262143];
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
		assign rom_dout  = rom[byte_addr[18:1]];
		assign rom_ready = 1'b1;
		assign sd0_addr = 24'd0; assign sd0_wrl = 1'b0; assign sd0_wrh = 1'b0;
		assign sd0_din  = 16'd0; assign sd0_req = 1'b0;
		assign ioctl_wait = 1'b0;
	end else begin : g_rom_hw
		wire        cache_busy, cache_valid;
		wire [15:0] cache_dout;
		wire [24:1] cache_sd_addr;
		wire        cache_sd_req;

		sdram_req sd0_inst (
			.clk(clk_sys), .reset(por_rst),
			.addr(ioctl_download ? ioctl_addr[24:1] : cache_sd_addr),
			.we(ioctl_download), .wrl(ioctl_download & ~ioctl_addr[0]), .wrh(ioctl_download & ioctl_addr[0]),
			.din({ioctl_dout, ioctl_dout}),
			.req(ioctl_download ? ioctl_wr : cache_sd_req),
			.busy(cache_busy), .valid(cache_valid), .dout(cache_dout),
			.sdram_addr(sd0_addr), .sdram_wrl(sd0_wrl), .sdram_wrh(sd0_wrh), .sdram_din(sd0_din),
			.sdram_dout(sd0_dout), .sdram_req(sd0_req), .sdram_ack(sd0_ack)
		);
		assign ioctl_wait = ioctl_download & cache_busy;

		rom_cache1 rom_cache_inst (
			.clk(clk_sys), .reset(reset | ioctl_download),
			.addr(byte_addr[18:1]), .data(rom_dout), .ready(rom_ready),
			.sd_addr(cache_sd_addr), .sd_req(cache_sd_req),
			.sd_busy(cache_busy), .sd_valid(cache_valid), .sd_dout(cache_dout)
		);
	end
	endgenerate

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — address-line-swapped for the CPU-facing
	// path ONLY, and ONLY for tdragon2 (game_macross2=0 — see header).
	// Swapped form: mainram_addr_cpu[10]<-byte_addr[11] and
	// mainram_addr_cpu[7]<-byte_addr[8] (word-address bits 10/7 swapped,
	// i.e. byte_addr bits 11/8 since word_addr[k]=byte_addr[k+1]); every
	// other bit passes straight through. macross2 (game_macross2=1) has
	// no swap at all — plain byte_addr[15:1], matching macross2_map's own
	// lack of any override on this range.
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr_cpu = game_macross2 ? byte_addr[15:1] :
		{byte_addr[15:12], byte_addr[8], byte_addr[10:9], byte_addr[11], byte_addr[7:1]};
	reg [15:0] mainram_dout;
	reg        mainram_ready;
	// HW_ROMS=1 only: registered (synchronous) CPU-side read, write
	// folded into the same always block as that read (one port, one
	// address), AND — the actually load-bearing fix, isolated by direct
	// testing below — each byte-lane write expressed as its own
	// top-level ANDed `if`, not nested inside a shared
	// "if (sel_mainram & cpu_write) begin if(~UDSn)...if(~LDSn)... end".
	// The nested form silently defeats Quartus's byte-enable RAM
	// inference: no "uninferred" diagnostic, nothing, just an ~524K-
	// flip-flop fallback (32768 x 16). Confirmed directly with a minimal
	// isolated repro at this exact 32768 depth: nested ifs (regardless
	// of port count — even reduced to a single write+read port, matching
	// the working sprite_plane idiom otherwise byte-for-byte) still fell
	// back to flip-flops; flattening to top-level ANDed ifs alone (same
	// single port) was sufficient to get real block RAM. The write
	// folded into the read's own port (as below) isn't required either,
	// but keeps mainram within Cyclone V's 2-independent-port-per-M10K
	// limit (CPU port + video port = 2) rather than 3, which is good
	// practice regardless. mainram_ready holds DTACKn off for the one
	// extra clk_sys cycle the registered read needs, mirroring
	// rom_wait/rom_ready's own existing mechanism (see DTACKn below).
	// HW_ROMS=0 (every existing sim testbench, unchanged): stays fully
	// combinational/zero-latency — the write-side text below is
	// byte-for-byte identical to what a plain always block outside any
	// generate would have contained.
	generate
	if (!HW_ROMS) begin : g_mainram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_mainram & cpu_write) begin
				if (~UDSn) mainram[mainram_addr_cpu][15:8] <= oEdb[15:8];
				if (~LDSn) mainram[mainram_addr_cpu][7:0]  <= oEdb[7:0];
			end
		end
		always @(*) mainram_dout  = mainram[mainram_addr_cpu];
		always @(*) mainram_ready = 1'b1;
	end else begin : g_mainram_cpu_hw
		// Write conditions flattened to top-level ANDed ifs, not nested
		// inside a shared "if (sel_mainram & cpu_write) begin ... end" —
		// confirmed directly (isolated repro, both at this array's real
		// 32768-depth and a fast 256-entry version): the nested form is
		// what was actually blocking RAM inference all along, regardless
		// of port count. Nested: 0 RAM segments, ~939K logic cells, no
		// diagnostic at all. Flattened, otherwise identical: real block
		// RAM, done in ~1 minute instead of ~50.
		reg [14:0] mainram_addr_cpu_r;
		always @(posedge clk_sys) begin
			if (sel_mainram & cpu_write & ~UDSn) mainram[mainram_addr_cpu][15:8] <= oEdb[15:8];
			if (sel_mainram & cpu_write & ~LDSn) mainram[mainram_addr_cpu][7:0]  <= oEdb[7:0];
			mainram_dout       <= mainram[mainram_addr_cpu];
			mainram_addr_cpu_r <= mainram_addr_cpu;
			mainram_ready      <= (mainram_addr_cpu_r == mainram_addr_cpu);
		end
	end
	endgenerate

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
	// BG tilemap VRAM (32768 x 16)
	// ------------------------------------------------------------------
	reg [15:0] bgvram [0:32767];
	wire [14:0] bgvram_addr = byte_addr[15:1];
	// Same reasoning/mechanism as mainram above — CPU write folded into
	// the same always block as the CPU read, keeping bgvram within
	// Cyclone V's 2-independent-port-per-M10K limit (CPU port + video
	// port).
	wire [15:0] bgvram_dout;
	reg  [15:0] bgvram_dout_r;
	reg         bgvram_ready;
	generate
	if (!HW_ROMS) begin : g_bgvram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_bgvram & cpu_write) begin
				if (~UDSn) bgvram[bgvram_addr][15:8] <= oEdb[15:8];
				if (~LDSn) bgvram[bgvram_addr][7:0]  <= oEdb[7:0];
			end
		end
		assign bgvram_dout = bgvram[bgvram_addr];
		always @(*) bgvram_ready = 1'b1;
	end else begin : g_bgvram_cpu_hw
		// Same flattened-condition fix as mainram above — see its own
		// comment for the full story.
		reg [14:0] bgvram_addr_r;
		always @(posedge clk_sys) begin
			if (sel_bgvram & cpu_write & ~UDSn) bgvram[bgvram_addr][15:8] <= oEdb[15:8];
			if (sel_bgvram & cpu_write & ~LDSn) bgvram[bgvram_addr][7:0]  <= oEdb[7:0];
			bgvram_dout_r <= bgvram[bgvram_addr];
			bgvram_addr_r <= bgvram_addr;
			bgvram_ready  <= (bgvram_addr_r == bgvram_addr);
		end
		assign bgvram_dout = bgvram_dout_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// TX tilemap VRAM (2048 x 16)
	// ------------------------------------------------------------------
	reg [15:0] txvram [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	// Despite its modest 32,768-bit storage, an asynchronous read of a
	// 2048-entry array still costs real logic: Quartus's own multiplexer
	// restructuring reported a bare "2048:1" mux for this exact
	// combinational read at 16,380 LEs — comparable to sprite_plane's
	// own footprint before ITS fix, just spent on read-select logic
	// instead of storage registers. Same fix, same reasoning as mainram/
	// bgvram above (registered read + write folded into the same
	// always block, flattened byte-enable ifs — see mainram's own
	// comment for the full byte-enable story).
	wire [15:0] txvram_dout;
	reg  [15:0] txvram_dout_r;
	reg         txvram_ready;
	generate
	if (!HW_ROMS) begin : g_txvram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_txvram & cpu_write) begin
				if (~UDSn) txvram[txvram_addr][15:8] <= oEdb[15:8];
				if (~LDSn) txvram[txvram_addr][7:0]  <= oEdb[7:0];
			end
		end
		assign txvram_dout = txvram[txvram_addr];
		always @(*) txvram_ready = 1'b1;
	end else begin : g_txvram_cpu_hw
		reg [10:0] txvram_addr_r;
		always @(posedge clk_sys) begin
			if (sel_txvram & cpu_write & ~UDSn) txvram[txvram_addr][15:8] <= oEdb[15:8];
			if (sel_txvram & cpu_write & ~LDSn) txvram[txvram_addr][7:0]  <= oEdb[7:0];
			txvram_dout_r <= txvram[txvram_addr];
			txvram_addr_r <= txvram_addr;
			txvram_ready  <= (txvram_addr_r == txvram_addr);
		end
		assign txvram_dout = txvram_dout_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Dual-port video read taps (video_macross2.sv's own live reads).
	// vid_mainram_addr/dout is DELIBERATELY UNSWAPPED — see header
	// ("Difference 1"): it mirrors MAME's own raw sprite_dma() memcpy,
	// which bypasses the swapped bus handler entirely.
	// ------------------------------------------------------------------
	wire [14:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout;
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout;
	wire [9:0]  vid_palette_addr;
	wire [15:0] vid_palette_dout = palette[vid_palette_addr];
	wire [9:0]  vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout = palette[vid_spr_palette_addr];
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout;
	wire        vid_mainram_ready;

	// HW_ROMS=1 only: registered (synchronous) reads on both video-side
	// dual-port taps, needed for the SAME RAM-inference reason as the
	// CPU-side ports above (both ports of a shared array must be
	// synchronous, or Quartus won't infer real block RAM for any of it).
	// bgvram_addr only changes once per 16-pixel tile column in
	// video_macross2.sv's own combinational chain, so the 1-cycle lag
	// this introduces self-resolves within that same tile — a rare,
	// single-pixel-at-the-tile-boundary artifact, the same class already
	// accepted (and documented) for external bgtile ROM cache misses, so
	// no further change is needed in video_macross2.sv itself for BG.
	// mainram, by contrast, is read every cycle by the sprite-snapshot
	// FSM (S_SNAP_REQ/S_SNAP_WAIT/S_SNAP_LATCH) with byte-exact
	// requirements — that FSM now blocks on vid_mainram_ready (mirrors
	// sprites_ready/S_SPR_WAIT) via video_macross2's own mainram_ready
	// port instead. txvram_addr is tile-quantized (once per 8-pixel TX
	// column) same as bgvram, same tolerance applies.
	generate
	if (!HW_ROMS) begin : g_vidram_read_sim
		assign vid_bgvram_dout  = bgvram[vid_bgvram_addr];
		assign vid_txvram_dout  = txvram[vid_txvram_addr];
		assign vid_mainram_dout = mainram[vid_mainram_addr];
		assign vid_mainram_ready = 1'b1;
	end else begin : g_vidram_read_hw
		reg [15:0] vid_bgvram_dout_r, vid_txvram_dout_r, vid_mainram_dout_r;
		reg [14:0] vid_mainram_addr_r;
		reg        vid_mainram_ready_r;
		always @(posedge clk_sys) begin
			vid_bgvram_dout_r   <= bgvram[vid_bgvram_addr];
			vid_txvram_dout_r   <= txvram[vid_txvram_addr];
			vid_mainram_dout_r  <= mainram[vid_mainram_addr];
			vid_mainram_addr_r  <= vid_mainram_addr;
			vid_mainram_ready_r <= (vid_mainram_addr_r == vid_mainram_addr);
		end
		assign vid_bgvram_dout   = vid_bgvram_dout_r;
		assign vid_txvram_dout   = vid_txvram_dout_r;
		assign vid_mainram_dout  = vid_mainram_dout_r;
		assign vid_mainram_ready = vid_mainram_ready_r;
	end
	endgenerate

	// dbg_* taps are a testbench-only third read port (TB_DUMP_VRAM) —
	// not wired to anything in the real hardware top (Macross2.sv), and
	// a third port would complicate dual-port RAM inference for no
	// benefit, so they're tied off at HW_ROMS=1 instead of adding real
	// read logic for them.
	generate
	if (!HW_ROMS) begin : g_dbgram_sim
		assign dbg_pal_data = palette[dbg_pal_addr];
		assign dbg_bgvram_data = bgvram[dbg_bgvram_addr[14:0]];
		assign dbg_txvram_data = txvram[dbg_txvram_addr];
	end else begin : g_dbgram_hw
		assign dbg_pal_data = 16'd0;
		assign dbg_bgvram_data = 16'd0;
		assign dbg_txvram_data = 16'd0;
	end
	endgenerate

	// ------------------------------------------------------------------
	// I/O registers — identical to macross2_core.sv's own.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg        z80_reset_n_reg;

	reg [7:0] scroll_reg [0:3];
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire [15:0] bg_xscroll = {scroll_reg[0], scroll_reg[1]};
	wire [15:0] bg_yscroll = {scroll_reg[2], scroll_reg[3]};

	reg [1:0] tilerambank_reg;
	wire sel_scroll_off0 = sel_scroll & (scroll_word_idx == 2'd0);

	integer si;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			z80_reset_n_reg <= 1'b0; // held in reset until the 68000 releases it
			tilerambank_reg <= 2'd0;
			for (si = 0; si < 4; si = si + 1) scroll_reg[si] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank & ~LDSn) bgbank_reg      <= oEdb[7:0];
			if (sel_scroll & ~LDSn) begin
				scroll_reg[scroll_word_idx] <= oEdb[7:0];
				if (sel_scroll_off0) tilerambank_reg <= oEdb[5:4];
			end
			if (sel_sndreset)         z80_reset_n_reg <= (oEdb != 16'h0000);
		end
	end


	// ------------------------------------------------------------------
	// soundlatch (68000->Z80, main2sub) / soundlatch2 (Z80->68000,
	// sub2main) — plain polling registers, no interrupt side effect.
	// ------------------------------------------------------------------
	reg [7:0] soundlatch_data;
	reg [7:0] soundlatch2_data;

	always @(posedge clk_sys) begin
		if (reset) soundlatch_data <= 8'h00;
		else if (sel_soundlatch_w & cpu_write & ~LDSn) soundlatch_data <= oEdb[7:0];
	end

	// ------------------------------------------------------------------
	// Z80 sound board: T80 + jt03 (YM2203) + NMK112 + jt6295 x2 (OKI)
	// ------------------------------------------------------------------
	wire [15:0] z80_a;
	wire [7:0]  z80_do;
	wire [7:0]  z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
	wire        z80_int_n;

	assign z80_int_n = ym_chip_irq_n;
	wire z80_reset_n = ~reset & z80_reset_n_reg;

	T80s z80_cpu (
		.RESET_n(z80_reset_n),
		.CLK(clk_sys),
		.CEN(z80_cen),
		.WAIT_n(z80_wait_n),
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
	wire z80_io_we = ~z80_iorq_n & ~z80_wr_n;
	wire z80_io_re = ~z80_iorq_n & ~z80_rd_n;

	wire sel_z80_rom   = (z80_a < 16'h8000);
	wire sel_z80_nopr  = (z80_a == 16'hA000);
	wire sel_z80_bank  = (z80_a >= 16'h8000) && (z80_a < 16'hC000) && !sel_z80_nopr;
	wire sel_z80_ram   = (z80_a >= 16'hC000) && (z80_a < 16'hE000);
	wire sel_z80_soundlatch2_w = z80_mem_we & (z80_a == 16'hF000);
	wire sel_z80_soundlatch_r  = (z80_a == 16'hF000);

	wire sel_mem_audiobank_w = z80_mem_we & (z80_a == 16'hE001);

	wire sel_io_ym_addr = (z80_a[7:0] == 8'h00);
	wire sel_io_ym_data = (z80_a[7:0] == 8'h01);
	wire sel_io_ym      = sel_io_ym_addr | sel_io_ym_data;
	wire sel_io_oki0    = (z80_a[7:0] == 8'h80);
	wire sel_io_oki1    = (z80_a[7:0] == 8'h88);
	wire sel_io_nmk112  = (z80_a[7:0] >= 8'h90) && (z80_a[7:0] <= 8'h97);

	// Absolute byte offsets within the shared 32MB SDRAM address space
	// this game's ioctl-download stream is laid out at — see
	// docs/hw-bringup.md's table. Word offset = byte offset / 2.
	localparam [22:0] BASE_WORD_AUDIOCPU = 23'h080000 >> 1;
	localparam [22:0] BASE_WORD_FGTILE   = 23'h0A0000 >> 1;
	localparam [22:0] BASE_WORD_BGTILE   = 23'h0C0000 >> 1;
	localparam [22:0] BASE_WORD_SPRITES  = 23'h2C0000 >> 1;
	localparam [22:0] BASE_WORD_OKI1     = 23'h6C0000 >> 1;
	localparam [22:0] BASE_WORD_OKI2     = 23'h8C0000 >> 1;

	wire [7:0] audiocpu_dout;
	wire       audiocpu_ready;
	// HW_ROMS=1 only: hold the Z80 with WAIT asserted while a real ROM
	// fetch is outstanding (audiocpu_ready tied to 1'b1 at HW_ROMS=0, so
	// this reduces to the original always-1 WAIT_n exactly).
	wire z80_wait_n = ~((sel_z80_rom | sel_z80_bank) & z80_mem_re & ~audiocpu_ready);
	wire [23:0] audiocpu_byte_addr = sel_z80_rom ? {9'd0, z80_a[14:0]} : {7'd0, z80_bank_phys[16:0]};
	generate
	if (!HW_ROMS) begin : g_audiocpu_sim
		reg [7:0] audiocpu_rom [0:131071];
		initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);
		assign audiocpu_dout  = audiocpu_rom[audiocpu_byte_addr[16:0]];
		assign audiocpu_ready = 1'b1;
		assign sd1_addr = 24'd0; assign sd1_req = 1'b0;
	end else begin : g_audiocpu_hw
		wire        cache_busy, cache_valid;
		wire [15:0] cache_dout;
		wire [24:1] cache_sd_addr;
		wire        cache_sd_req;

		sdram_req sd1_inst (
			.clk(clk_sys), .reset(por_rst),
			.addr(cache_sd_addr), .we(1'b0), .wrl(1'b0), .wrh(1'b0), .din(16'd0),
			.req(cache_sd_req), .busy(cache_busy), .valid(cache_valid), .dout(cache_dout),
			.sdram_addr(sd1_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
			.sdram_dout(sd1_dout), .sdram_req(sd1_req), .sdram_ack(sd1_ack)
		);
		rom_cache1_byte #(.BASE_WORD_OFFSET(BASE_WORD_AUDIOCPU)) audiocpu_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr(audiocpu_byte_addr), .data(audiocpu_dout), .ready(audiocpu_ready),
			.sd_addr(cache_sd_addr), .sd_req(cache_sd_req), .sd_busy(cache_busy), .sd_valid(cache_valid), .sd_dout(cache_dout)
		);
	end
	endgenerate

	reg [2:0] audiobank_reg;
	always @(posedge clk_sys) begin
		if (~z80_reset_n) audiobank_reg <= 3'd0;
		else if (sel_mem_audiobank_w) audiobank_reg <= z80_do[2:0]; // macross2_audiobank_w
	end

	reg [7:0] z80_ram [0:8191];
	always @(posedge clk_sys) if (sel_z80_ram & z80_mem_we) z80_ram[z80_a[12:0]] <= z80_do;

	wire [16:0] z80_bank_phys = {audiobank_reg, 14'd0} + {3'd0, z80_a[13:0]};

	always @(posedge clk_sys) begin
		if (~z80_reset_n) soundlatch2_data <= 8'h00;
		else if (sel_z80_soundlatch2_w) soundlatch2_data <= z80_do;
	end

	// ------------------------------------------------------------------
	// YM2203 — real jt03. Same write-stretch pattern as macross2_core.sv's
	// own (40-cycle hold, safely exceeding ym_cen's own 27-cycle worst-case
	// gap).
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
			ym_addr_latch <= sel_io_ym_data;
			ym_wr_hold    <= 6'd40;
		end else if (ym_wr_hold != 6'd0) begin
			ym_wr_hold <= ym_wr_hold - 6'd1;
		end
	end
	wire ym_wr_n = ~(ym_wr_hold != 6'd0);
	// jt03 has no separate read-strobe input — dout always reflects whatever
	// addr currently holds, so a status/busy read must see the live port
	// decode, not the write-only latch (which would still show the previous
	// write's offset, e.g. after a data-port write, breaking busy-flag polls).
	// Fall back to the latched value only while a write-stretch is in flight,
	// since ym_din_latch itself is only valid for that same window.
	wire ym_addr_sel = (ym_wr_hold != 6'd0) ? ym_addr_latch : sel_io_ym_data;

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	wire signed [15:0] ym_snd;
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_sel), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(), .snd(ym_snd), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// NMK112 — see rtl/nmk112/nmk112.sv's own header. ROM1_BYTES fixed at
	// tdragon2's own (larger) 0x200000 unconditionally, serving macross2
	// too (its own oki2 is half that, 0x100000, but the wider mask is
	// provably harmless — see this file's own header for the derivation;
	// no game_macross2 toggle needed here).
	// ------------------------------------------------------------------
	wire nmk112_we = z80_io_we & sel_io_nmk112;
	wire [17:0] oki0_rom_addr_raw, oki1_rom_addr_raw;
	wire [21:0] oki0_rom_addr, oki1_rom_addr;

	nmk112 #(
		.ROM0_BYTES(2097152), // ww930916.4 / bp932an.a06, 0x200000 (oki1, same both games)
		.ROM1_BYTES(2097152)  // ww930915.3, 0x200000 (oki2 — macross2's own bp932an.a05 is half this; harmless, see header)
	) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(z80_a[2:0]), .reg_data(z80_do), .reg_we(nmk112_we),
		.rom0_addr_in(oki0_rom_addr_raw), .rom0_addr_out(oki0_rom_addr),
		.rom1_addr_in(oki1_rom_addr_raw), .rom1_addr_out(oki1_rom_addr)
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, driven by the Z80's own I/O bus through
	// NMK112. oki1_rom (chip 1 / MAME tag "oki2") is sized 0x200000/
	// 21-bit-addressed for both games (macross2's own real chip is half
	// that — harmless, see header); its own OKI2_ROM_FILE simply loads
	// into the low half when macross2's own smaller image is used.
	// ------------------------------------------------------------------
	// HW_ROMS=0: unchanged sim arrays (jt6295's own rom_ok tied to 1'b1
	// below, matching the original design exactly). HW_ROMS=1: both OKI
	// sample ROMs share SDRAM port 3 through a 2-way rom_cache1/
	// sdram_arb, with jt6295's own real rom_ok/rom_data wait-state
	// protocol driven for real (see docs/hw-bringup.md — verified this
	// is a genuine, effectively-unbounded wait, not a fixed few-cycle
	// deadline, by reading rtl/third_party/jt6295/hdl/jt6295_rom.v
	// directly: once its own internal wait2 counter saturates, it
	// re-samples rom_ok/rom_data every single cycle thereafter for as
	// long as its own ctrl_addr stays stable).
	wire [7:0] oki0_rom_data, oki1_rom_data;
	wire       oki0_rom_ok, oki1_rom_ok;
	generate
	if (!HW_ROMS) begin : g_oki_sim
		reg [7:0] oki0_rom [0:2097151]; // ww930916.4 / bp932an.a06, 0x200000
		reg [7:0] oki1_rom [0:2097151]; // ww930915.3, 0x200000 (macross2's own bp932an.a05 is 0x100000 — loads into the low half)
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki0_rom);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki1_rom);
		reg [7:0] oki0_rom_data_r, oki1_rom_data_r;
		always @(posedge clk_sys) oki0_rom_data_r <= oki0_rom[oki0_rom_addr[20:0]];
		always @(posedge clk_sys) oki1_rom_data_r <= oki1_rom[oki1_rom_addr[20:0]];
		assign oki0_rom_data = oki0_rom_data_r;
		assign oki1_rom_data = oki1_rom_data_r;
		assign oki0_rom_ok = 1'b1;
		assign oki1_rom_ok = 1'b1;
		assign sd3_addr = 24'd0; assign sd3_req = 1'b0;
	end else begin : g_oki_hw
		wire        arb_busy [0:1];
		wire        arb_valid[0:1];
		wire [24:1] arb_addr [0:1];
		wire        arb_req  [0:1];
		wire [15:0] arb_dout [0:1];

		sdram_arb #(.N(2)) oki_arb_inst (
			.clk(clk_sys), .reset(por_rst),
			.i_addr(arb_addr), .i_we('{1'b0, 1'b0}), .i_wrl('{1'b0, 1'b0}), .i_wrh('{1'b0, 1'b0}), .i_din('{16'd0, 16'd0}),
			.i_req(arb_req), .i_busy(arb_busy), .i_valid(arb_valid), .i_dout(arb_dout),
			.sdram_addr(sd3_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
			.sdram_dout(sd3_dout), .sdram_req(sd3_req), .sdram_ack(sd3_ack)
		);
		rom_cache1_byte #(.BASE_WORD_OFFSET(BASE_WORD_OKI1)) oki0_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({2'd0, oki0_rom_addr}), .data(oki0_rom_data), .ready(oki0_rom_ok),
			.sd_addr(arb_addr[0]), .sd_req(arb_req[0]), .sd_busy(arb_busy[0]), .sd_valid(arb_valid[0]), .sd_dout(arb_dout[0])
		);
		rom_cache1_byte #(.BASE_WORD_OFFSET(BASE_WORD_OKI2)) oki1_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({2'd0, oki1_rom_addr}), .data(oki1_rom_data), .ready(oki1_rom_ok),
			.sd_addr(arb_addr[1]), .sd_req(arb_req[1]), .sd_busy(arb_busy[1]), .sd_valid(arb_valid[1]), .sd_dout(arb_dout[1])
		);
	end
	endgenerate

	wire sel_oki0_we = z80_io_we & sel_io_oki0;
	wire sel_oki1_we = z80_io_we & sel_io_oki1;
	reg [7:0] oki0_din_latch, oki1_din_latch;
	reg [5:0] oki0_wr_hold = 6'd0, oki1_wr_hold = 6'd0;
	reg       oki0_we_prev = 1'b0, oki1_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		oki0_we_prev <= sel_oki0_we;
		if (sel_oki0_we && !oki0_we_prev) begin
			oki0_din_latch <= z80_do;
			oki0_wr_hold   <= 6'd40;
		end else if (oki0_wr_hold != 6'd0) begin
			oki0_wr_hold <= oki0_wr_hold - 6'd1;
		end
	end
	always @(posedge clk_sys) begin
		oki1_we_prev <= sel_oki1_we;
		if (sel_oki1_we && !oki1_we_prev) begin
			oki1_din_latch <= z80_do;
			oki1_wr_hold   <= 6'd40;
		end else if (oki1_wr_hold != 6'd0) begin
			oki1_wr_hold <= oki1_wr_hold - 6'd1;
		end
	end
	wire oki0_wr_n = ~(oki0_wr_hold != 6'd0);
	wire oki1_wr_n = ~(oki1_wr_hold != 6'd0);

	wire [7:0] oki0_chip_dout, oki1_chip_dout;
	wire signed [13:0] oki0_snd, oki1_snd;
	jt6295 oki0_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(1'b0),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki0_chip_dout),
		.rom_addr(oki0_rom_addr_raw), .rom_data(oki0_rom_data), .rom_ok(oki0_rom_ok),
		.sound(oki0_snd), .sample()
	);
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(1'b0),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr_raw), .rom_data(oki1_rom_data), .rom_ok(oki1_rom_ok),
		.sound(oki1_snd), .sample()
	);

	// ------------------------------------------------------------------
	// Audio mix — mono (no separate panning info anywhere in this
	// driver): jt03's own already-mixed FM+PSG `snd` (16-bit) plus both
	// OKI chips' own 14-bit `sound`, sign-extended and modestly
	// upscaled to keep the OKI channels audible against the wider FM
	// range, summed in a wider accumulator then saturated to 16 bits
	// rather than allowed to silently wrap on overflow.
	// ------------------------------------------------------------------
	wire signed [17:0] audio_sum = {{2{ym_snd[15]}}, ym_snd} +
	                                {{2{oki0_snd[13]}}, oki0_snd, 2'b00} +
	                                {{2{oki1_snd[13]}}, oki1_snd, 2'b00};
	wire signed [15:0] audio_mix =
		(audio_sum > 18'sd32767)  ? 16'sd32767  :
		(audio_sum < -18'sd32768) ? -16'sd32768 :
		audio_sum[15:0];
	assign audio_l = audio_mix;
	assign audio_r = audio_mix;

	// ------------------------------------------------------------------
	// Z80 read-data mux
	// ------------------------------------------------------------------
	reg [7:0] z80_rdata;
	always @(*) begin
		if (sel_z80_rom)        z80_rdata = audiocpu_dout;
		else if (sel_z80_bank)  z80_rdata = audiocpu_dout;
		else if (sel_z80_ram)   z80_rdata = z80_ram[z80_a[12:0]];
		else if (z80_mem_re & sel_z80_soundlatch_r) z80_rdata = soundlatch_data;
		else if (z80_io_re & sel_io_ym)   z80_rdata = ym_chip_dout;
		else if (z80_io_re & sel_io_oki0) z80_rdata = oki0_chip_dout;
		else if (z80_io_re & sel_io_oki1) z80_rdata = oki1_chip_dout;
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
		else if (sel_soundlatch2_r) rdata = {8'h00, soundlatch2_data};
		else if (sel_in0)     rdata = HW_ROMS ? in0_i  : 16'hFFFF;
		else if (sel_in1)     rdata = HW_ROMS ? in1_i  : 16'hFFFF;
		else if (sel_dsw1)    rdata = HW_ROMS ? dsw1_i : 16'hFFFF;
		else if (sel_dsw2)    rdata = HW_ROMS ? dsw2_i : 16'hFFFF;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + REAL V-PROM interrupt generation (rtl/nmk_irq/
	// nmk_irq.sv).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);
	assign ce_pix_o = ce_pix;
	assign hcount_o = vt_hcount;
	assign vcount_o = vt_vcount;
	assign hblank_o = vt_hblank;
	assign vblank_o = vt_vblank;

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
	// Video pipeline — rtl/macross2/video_macross2.sv, reused UNMODIFIED
	// (see this file's own header).
	// ------------------------------------------------------------------
	video_macross2 #(
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.SPRITES_FILE(SPRITES_FILE),
		.HW_ROMS(HW_ROMS),
		.BASE_WORD_FGTILE(BASE_WORD_FGTILE),
		.BASE_WORD_BGTILE(BASE_WORD_BGTILE),
		.BASE_WORD_SPRITES(BASE_WORD_SPRITES)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.sprite_dma_trigger(sprite_dma_trigger),
		.bgvram_addr(vid_bgvram_addr), .bgvram_data(vid_bgvram_dout),
		.txvram_addr(vid_txvram_addr), .txvram_data(vid_txvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout), .mainram_ready(vid_mainram_ready),
		.bg_xscroll(bg_xscroll), .bg_yscroll(bg_yscroll),
		.bg_bank(bgbank_reg),
		.tilerambank(tilerambank_reg),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb),
		.sd_addr(sd2_addr), .sd_wrl(sd2_wrl), .sd_wrh(sd2_wrh), .sd_din(sd2_din),
		.sd_dout(sd2_dout), .sd_req(sd2_req), .sd_ack(sd2_ack)
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

	assign dbg_z80_pc = z80_a;
	assign dbg_z80_m1_n = z80_m1_n;
	assign dbg_z80_mreq_n = z80_mreq_n;
	assign dbg_z80_iorq_n = z80_iorq_n;
	assign dbg_z80_int_n = z80_int_n;
	assign dbg_z80_reset_n = z80_reset_n;
	assign dbg_z80_cen = z80_cen;

	assign dbg_ym_we = ym_we_raw;
	assign dbg_ym_cs = sel_io_ym;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_irq_n = ym_chip_irq_n;

	assign dbg_oki0_we = sel_oki0_we;
	assign dbg_oki1_we = sel_oki1_we;
	assign dbg_oki0_chip_dout = oki0_chip_dout;
	assign dbg_oki1_chip_dout = oki1_chip_dout;

endmodule
