// NMK16 MiSTerFPGA project — tdragon2 (Tier 3, Family C) system-level
// integration. Second Tier 3 port, after macross2 — read
// rtl/macross2/macross2_core.sv's own header first, this file follows it
// line-for-line except for the two differences below (confirmed directly
// against the reference, not assumed from family resemblance):
// `tdragon2()`'s own machine config (nmk16.cpp:5490-5533) is otherwise
// BYTE-FOR-BYTE IDENTICAL to macross2()'s own (same 68000/Z80 clocks, same
// macross2_sound_map/io_map — literally the same functions — same
// gfx_macross2/VIDEO_START_OVERRIDE(macross2), same NMK112/dual-OKI setup),
// so rtl/macross2/video_macross2.sv is reused completely UNMODIFIED (not
// even a derivative — referenced directly from this file, verified there is
// truly no video-relevant difference before doing this) and rtl/nmk112/
// nmk112.sv is reused unmodified too, just instantiated with this game's
// own ROM byte sizes (oki2 is 0x200000 here, not macross2's own 0x100000
// — see below).
//
// Difference 1 — mainram address-line swap (nmk16.cpp:280-288,1100-1104):
// `tdragon2_map` is `macross2_map(map)` plus one override,
// `map(0x1f0000,0x1fffff).rw(mainram_swapped_r,mainram_swapped_w)`, which
// applies `bitswap<16>(offset,15,14,13,12,11,7,9,8,10,6,5,4,3,2,1,0)` to the
// WORD OFFSET before indexing m_mainram — verified independently (not
// trusted from the bit-list alone) that this swaps ONLY address bits 7 and
// 10 with each other; every other bit passes through unchanged. A real PCB
// address-line miswiring, faithfully replicated — NOT a data-bit scramble.
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
// UNSWAPPED, reading the SAME raw `mainram` array the CPU-facing accessor
// also indexes into — only the CPU-facing address computation below is
// swapped. Getting this backwards (swapping both paths, or swapping
// neither) would silently corrupt sprite draw order without necessarily
// breaking anything else — a genuinely non-obvious point, verified against
// the reference before implementing rather than assumed from the primary
// session's own delegation brief (which only anticipated a single, uniform
// swap).
//
// Difference 2 — OKI2 ROM size: tdragon2's own oki2 (ww930915.3) is
// 0x200000 bytes (nmk16.cpp:8351-8352), DOUBLE macross2's own 0x100000
// (bp932an.a05) — oki1 stays the same 0x200000 both games use. nmk112's
// own ROM1_BYTES parameter, the oki1_rom array size/addressing width
// (macross2_core.sv's own naming: the Verilog array named "oki1_rom"
// backs nmk112's chip 1 / MAME tag "oki2" — a pre-existing naming
// mismatch in macross2_core.sv itself, not introduced here), and
// AUDIOCPU_FILE/ROM sizes elsewhere are otherwise identical.
//
// Everything else — clock derivation, address decode, I/O register
// wiring, Z80 sound path, video pipeline instantiation, real V-PROM
// nmk_irq wiring — is copied unchanged from macross2_core.sv; see that
// file's own header for the full derivation of anything not re-explained
// here.
module tdragon2_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI1_ROM_FILE  = "",
	parameter OKI2_ROM_FILE  = "",
	parameter VTIMING_FILE   = "",
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
	output        frame_done
);

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
	wire DTACKn = ASn | iack_cycle;

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
	// ROM (maincpu) — 0x80000 bytes = 262144 words.
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — address-line-swapped for the CPU-facing
	// path ONLY (see header). mainram_addr_cpu[10]<-byte_addr[11] and
	// mainram_addr_cpu[7]<-byte_addr[8] (word-address bits 10/7 swapped,
	// i.e. byte_addr bits 11/8 since word_addr[k]=byte_addr[k+1]); every
	// other bit passes straight through.
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr_cpu =
		{byte_addr[15:12], byte_addr[8], byte_addr[10:9], byte_addr[11], byte_addr[7:1]};
	reg [15:0] mainram_dout;
	always @(posedge clk_sys) begin
		if (sel_mainram & cpu_write) begin
			if (~UDSn) mainram[mainram_addr_cpu][15:8] <= oEdb[15:8];
			if (~LDSn) mainram[mainram_addr_cpu][7:0]  <= oEdb[7:0];
		end
	end
	always @(*) mainram_dout = mainram[mainram_addr_cpu];

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
	// Dual-port video read taps (video_macross2.sv's own live reads).
	// vid_mainram_addr/dout is DELIBERATELY UNSWAPPED — see header
	// ("Difference 1"): it mirrors MAME's own raw sprite_dma() memcpy,
	// which bypasses the swapped bus handler entirely.
	// ------------------------------------------------------------------
	wire [14:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout = bgvram[vid_bgvram_addr];
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout = txvram[vid_txvram_addr];
	wire [9:0]  vid_palette_addr;
	wire [15:0] vid_palette_dout = palette[vid_palette_addr];
	wire [9:0]  vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout = palette[vid_spr_palette_addr];
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout = mainram[vid_mainram_addr];

	assign dbg_pal_data = palette[dbg_pal_addr];
	assign dbg_bgvram_data = bgvram[dbg_bgvram_addr[14:0]];
	assign dbg_txvram_data = txvram[dbg_txvram_addr];

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

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

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

	reg [7:0] audiocpu_rom [0:131071];
	initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);

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
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_sel), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(), .psg_snd(), .snd(), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// NMK112 — see rtl/nmk112/nmk112.sv's own header. ROM1_BYTES is
	// 0x200000 here, not macross2's own 0x100000 (see this file's own
	// header, "Difference 2").
	// ------------------------------------------------------------------
	wire nmk112_we = z80_io_we & sel_io_nmk112;
	wire [17:0] oki0_rom_addr_raw, oki1_rom_addr_raw;
	wire [21:0] oki0_rom_addr, oki1_rom_addr;

	nmk112 #(
		.ROM0_BYTES(2097152), // ww930916.4, 0x200000 (oki1)
		.ROM1_BYTES(2097152)  // ww930915.3, 0x200000 (oki2 — DOUBLE macross2's own)
	) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(z80_a[2:0]), .reg_data(z80_do), .reg_we(nmk112_we),
		.rom0_addr_in(oki0_rom_addr_raw), .rom0_addr_out(oki0_rom_addr),
		.rom1_addr_in(oki1_rom_addr_raw), .rom1_addr_out(oki1_rom_addr)
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, driven by the Z80's own I/O bus through
	// NMK112. oki1_rom (chip 1 / MAME tag "oki2") is now 0x200000 bytes,
	// 21-bit-addressed — widened from macross2_core.sv's own 0x100000/
	// 20-bit array (see header, "Difference 2").
	// ------------------------------------------------------------------
	reg [7:0] oki0_rom [0:2097151]; // ww930916.4, 0x200000
	reg [7:0] oki1_rom [0:2097151]; // ww930915.3, 0x200000 (was 0x100000 in macross2_core.sv)
	initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki0_rom);
	initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki1_rom);

	reg [7:0] oki0_rom_data, oki1_rom_data;
	always @(posedge clk_sys) oki0_rom_data <= oki0_rom[oki0_rom_addr[20:0]];
	always @(posedge clk_sys) oki1_rom_data <= oki1_rom[oki1_rom_addr[20:0]]; // 21 bits, was [19:0]

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
	jt6295 oki0_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(1'b0),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki0_chip_dout),
		.rom_addr(oki0_rom_addr_raw), .rom_data(oki0_rom_data), .rom_ok(1'b1),
		.sound(), .sample()
	);
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen), .ss(1'b0),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr_raw), .rom_data(oki1_rom_data), .rom_ok(1'b1),
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
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
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
		.tilerambank(tilerambank_reg),
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
