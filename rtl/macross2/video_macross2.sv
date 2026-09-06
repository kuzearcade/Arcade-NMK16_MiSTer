// macross2 video pipeline — Tier 3's first port (Family C, Z80-direct-sound
// hi-res boards). Confirmed directly from the reference:
// `VIDEO_START_MEMBER(nmk16_state,macross2)` (nmk16_v.cpp:150-162) creates
// a `common_get_bg_tile_info<0,1>`-driven, `tilemap_scan_pages`-mapped,
// 256x32-tile (16x16 px) BG tilemap — the SAME BG geometry
// `rtl/macross/video_macross.sv` already implements (14-bit BG tile code,
// since macross2's own bgtile ROM is 0x200000 bytes/16384 tiles, identical
// size to macross's own) — plus a 64x32-tile (8x8 px) TX tilemap, which is
// `rtl/gunnail/video_gunnail.sv`'s own TX sizing (`gunnail`'s own
// VIDEO_START literally calls `VIDEO_START_CALL_MEMBER(macross2)` first,
// nmk16_v.cpp:164-168 — i.e. gunnail's TX layer IS macross2's own, not the
// other way around). This module is therefore video_macross.sv's own BG
// architecture + video_gunnail.sv's own TX sizing, with two more real
// differences confirmed directly from the reference, not assumed:
//
//   1. **No NMK214 descrambling** — macross2 has no protection MCU at all
//      (`init_banked_audiocpu` only, nmk16.cpp:10736); bgtile/sprites ROM
//      data is read directly, unlike video_macross.sv's own two live
//      nmk214 instances.
//   2. **5-bit sprite colour, not 4** — `macross2()`'s own machine config
//      uses `get_colour_5bit` (nmk16.cpp:5457, `colour &= 0x1f`), not
//      `get_colour_4bit` every single prior port in this project has used.
//      `gfx_macross2`'s own GFXDECODE_START (nmk16.cpp:4194-4198) confirms
//      the palette layout this requires: sprites at colour base `0x100`
//      with **32** colours (`0x100-0x2FF`, matching the 5-bit index
//      exactly), NOT `0x200` like macross's/gunnail's own. TX is also at a
//      DIFFERENT base here — `0x300`, 16 colours (`0x300-0x3FF`) — NOT
//      `0x200` like every prior port's own TX layer. BG stays at `0x000`,
//      16 colours, unchanged. Confirmed directly against `gfx_macross2`'s
//      own GFXDECODE_START rather than assumed from family resemblance —
//      these three bases exactly tile the full 1024-entry palette
//      (0x000-0x0FF BG, 0x100-0x2FF sprites, 0x300-0x3FF TX).
//
// Per-scanline raster scroll (video_gunnail.sv's own "hardest video item")
// does NOT apply here — macross2_map's own `130000-130007` is a single
// `scroll_w<0>` register (nmk16.cpp:1094), the same plain X/Y scroll shape
// every Tier 5 port's own video already used, not gunnail's own per-row
// scrollram tables. `bg_xscroll`/`bg_yscroll` below are frame-constant
// register inputs, not the row-indexed taps video_gunnail.sv needs.
//
// Everything else (palette decode, sprite double-buffer/draw FSM,
// composite order) is video_macross.sv's own, unchanged.
module video_macross2 #(
	parameter FGTILE_FILE  = "",
	parameter BGTILE_FILE  = "",
	parameter SPRITES_FILE = "",
	// See docs/hw-bringup.md. HW_ROMS=0 (default, every existing sim
	// testbench, including macross2's own — unchanged): $readmemh
	// 0-latency arrays exactly as before this parameter existed.
	// HW_ROMS=1 (tdragon2's real hardware top-level only): fgtile/
	// bgtile/sprites all read through rom_cache1_byte, sharing one
	// physical SDRAM port via a 3-way sdram_arb.
	parameter HW_ROMS = 0,
	parameter [22:0] BASE_WORD_FGTILE  = 23'd0,
	parameter [22:0] BASE_WORD_BGTILE  = 23'd0,
	parameter [22:0] BASE_WORD_SPRITES = 23'd0
) (
	input clk_sys,
	input reset,

	// Hardware-mode-only (HW_ROMS=1): one physical SDRAM port, shared
	// 3 ways (fgtile/bgtile/sprites) via an internal sdram_arb. Unused
	// at HW_ROMS=0 — every existing sim testbench (macross2's own and
	// tdragon2's own) instantiates this module without connecting them.
	output     [24:1] sd_addr,
	output            sd_wrl,
	output            sd_wrh,
	output     [15:0] sd_din,
	input      [15:0] sd_dout,
	output            sd_req,
	input             sd_ack,

	input sprite_dma_trigger, // from nmk_irq: snapshot sprite RAM now

	// register/RAM read ports into macross2_core's storage (dual-tap
	// reads, macross2_core owns the arrays)
	output [14:0] bgvram_addr,
	input  [15:0] bgvram_data,
	// bgvideoram_w<Layer>/scroll_w<Layer> (nmk16.cpp:465-503): macross2's
	// own bgvideoram is FOUR "banks" of the same 8192-tile-position
	// tilemap (0x10000 bytes vs. every other port's own 0x4000 — see
	// module header), selected by bits[5:4] of the scroll register's own
	// X-scroll-high byte (nmk16.cpp:490-501 — `newbank = (m_scroll[0]>>4)
	// & 3`; those same bits also land in the X-scroll VALUE itself via
	// `set_scrollx`'s own unmasked use of that byte, but get discarded by
	// the tilemap's own mod-4096 wraparound, so this doesn't corrupt the
	// visible scroll amount). Top 2 bits of bgvram_addr below.
	input  [1:0]  tilerambank,
	output [10:0] txvram_addr,
	input  [15:0] txvram_data,
	output [9:0]  palette_addr,     // tile-plane palette tap (live, per-pixel)
	input  [15:0] palette_data,
	output [9:0]  spr_palette_addr, // sprite-plane palette tap (read-time only)
	input  [15:0] spr_palette_data,
	output reg [14:0] mainram_addr,
	input      [15:0] mainram_data,
	// HW_ROMS=1 only: real block until the wrapper's registered mainram
	// read has settled for the current mainram_addr (that read is needed
	// for RAM inference — see mainram_ready's own definition in
	// tdragon2_core.sv). At HW_ROMS=0 the wrapper ties this to 1'b1, so
	// S_SNAP_WAIT below is a single pass-through cycle, matching the
	// pre-existing snapshot timing exactly.
	input              mainram_ready,

	input [15:0] bg_xscroll, bg_yscroll,
	input [7:0]  bg_bank,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0] rd_x,
	input  [7:0] rd_y,
	output [23:0] rd_rgb
);

	localparam integer SCREEN_W = 384;
	localparam integer SCREEN_H = 224;
	localparam integer VIDEOSHIFT = 92; // set_scrolldx(28+64,28+64), see video_gunnail.sv's own header
	localparam integer MAX_SPRITE_CLOCK = 134656; // 512*263, set_max_sprite_clock

	// Palette bases — see header. Sprite is 5-bit (32 colours), not 4-bit.
	localparam [9:0] BG_PAL_BASE  = 10'h000;
	localparam [9:0] SPR_PAL_BASE = 10'h100;
	localparam [9:0] TX_PAL_BASE  = 10'h300;

	// ------------------------------------------------------------------
	// Graphics ROMs (byte-addressed, see tools/mkgfxrom.py). No
	// descrambling — read directly (see header).
	// ------------------------------------------------------------------
	// HW_ROMS=0: unchanged $readmemh 0-latency sim arrays. HW_ROMS=1: all
	// three share one physical SDRAM port via a 3-way sdram_arb, each
	// behind its own rom_cache1_byte. See docs/hw-bringup.md — BG/TX
	// (fgtile) fetch is per-pixel/real-time (tied to ce_pix) and NOT
	// gated on cache-ready: a cache miss just serves the last-cached
	// byte for one extra pixel or two rather than stalling the whole
	// raster pipeline out of sync with real-time video timing, an
	// honest, documented, un-chased risk of a rare single-pixel visual
	// artifact under worst-case SDRAM contention (never a functional
	// hang — rom_cache1 itself is proven to always converge to the
	// correct value, see its own standalone verification). Sprite fetch
	// is different: it's an FSM-paced background compositing pass, not
	// tied to ce_pix at all, so it gets a REAL blocking wait instead
	// (see the sprite draw FSM below, S_SPR_WAIT).
	wire [7:0] fgtile_rom_byte;
	wire [7:0] bgtile_rom_byte;
	wire [7:0] sprites_rom_byte;
	wire       sprites_ready;
	generate
	if (!HW_ROMS) begin : g_video_rom_sim
		reg [7:0] fgtile_rom  [0:131071];  // mcrs2j.1, 8x8x4bpp packed_msb, 32B/tile
		reg [7:0] bgtile_rom  [0:2097151]; // bp932an.a04, 16x16 col_2x2_group, 128B/tile — 16384 tiles (14-bit code, see header)
		reg [7:0] sprites_rom [0:4194303]; // bp932an.a07+a08, word_swap-extracted, 128B/16x16-unit
		initial if (FGTILE_FILE  != "") $readmemh(FGTILE_FILE,  fgtile_rom);
		initial if (BGTILE_FILE  != "") $readmemh(BGTILE_FILE,  bgtile_rom);
		initial if (SPRITES_FILE != "") $readmemh(SPRITES_FILE, sprites_rom);
		assign fgtile_rom_byte  = fgtile_rom[fg_byte_addr_sim[16:0]];
		assign bgtile_rom_byte  = bgtile_rom[bg_byte_addr];
		assign sprites_rom_byte = sprites_rom[spr_byte_addr[21:0]];
		assign sprites_ready = 1'b1;
		assign sd_addr = 24'd0; assign sd_wrl = 1'b0; assign sd_wrh = 1'b0; assign sd_din = 16'd0; assign sd_req = 1'b0;
	end else begin : g_video_rom_hw
		wire        arb_busy [0:2];
		wire        arb_valid[0:2];
		wire [24:1] arb_addr [0:2];
		wire        arb_req  [0:2];
		wire [15:0] arb_dout [0:2];

		sdram_arb #(.N(3)) video_arb_inst (
			.clk(clk_sys), .reset(reset),
			.i_addr(arb_addr), .i_we('{1'b0,1'b0,1'b0}), .i_wrl('{1'b0,1'b0,1'b0}), .i_wrh('{1'b0,1'b0,1'b0}), .i_din('{16'd0,16'd0,16'd0}),
			.i_req(arb_req), .i_busy(arb_busy), .i_valid(arb_valid), .i_dout(arb_dout),
			.sdram_addr(sd_addr), .sdram_wrl(sd_wrl), .sdram_wrh(sd_wrh), .sdram_din(sd_din),
			.sdram_dout(sd_dout), .sdram_req(sd_req), .sdram_ack(sd_ack)
		);
		wire fgtile_ready;
		rom_cache1_byte #(.BASE_WORD_OFFSET(BASE_WORD_FGTILE)) fgtile_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({7'd0, fg_byte_addr_sim}), .data(fgtile_rom_byte), .ready(fgtile_ready),
			.sd_addr(arb_addr[0]), .sd_req(arb_req[0]), .sd_busy(arb_busy[0]), .sd_valid(arb_valid[0]), .sd_dout(arb_dout[0])
		);
		wire bgtile_ready;
		rom_cache1_byte #(.BASE_WORD_OFFSET(BASE_WORD_BGTILE)) bgtile_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({3'd0, bg_byte_addr}), .data(bgtile_rom_byte), .ready(bgtile_ready),
			.sd_addr(arb_addr[1]), .sd_req(arb_req[1]), .sd_busy(arb_busy[1]), .sd_valid(arb_valid[1]), .sd_dout(arb_dout[1])
		);
		rom_cache1_byte #(.BASE_WORD_OFFSET(BASE_WORD_SPRITES)) sprites_cache_inst (
			.clk(clk_sys), .reset(reset),
			.byte_addr({2'd0, spr_byte_addr}), .data(sprites_rom_byte), .ready(sprites_ready),
			.sd_addr(arb_addr[2]), .sd_req(arb_req[2]), .sd_busy(arb_busy[2]), .sd_valid(arb_valid[2]), .sd_dout(arb_dout[2])
		);
	end
	endgenerate

	// 8x8x4bpp packed_msb: 32 bytes/tile, hi nibble = even column first.
	function automatic [3:0] tile_nibble(input [7:0] byte_val, input col_odd);
		tile_nibble = col_odd ? byte_val[3:0] : byte_val[7:4];
	endfunction

	// fgtile (TX layer) byte address — code*32 + row*4 + (col>>1). See
	// g_video_rom_sim/g_video_rom_hw above for the actual byte lookup
	// (fgtile_rom_byte) this address feeds.
	wire [16:0] fg_byte_addr_sim = {txvram_data[11:0], 5'd0} + {12'd0, tx_py, 2'd0} + {15'd0, tx_px[2:1]};

	// ------------------------------------------------------------------
	// BG tile-fetch address — gfx_8x8x4_col_2x2_group_packed_msb layout:
	// 128 bytes/16x16 unit, left half (col 0-7) at +0, right half
	// (col 8-15) at +64, same as video_macross.sv's own derivation.
	// ------------------------------------------------------------------
	wire [20:0] bg_byte_addr;
	wire [7:0]  bgtile_byte = bgtile_rom_byte;

	function automatic [3:0] bg_tile_pixel_nib(input [7:0] byte_val, input integer col_local);
		bg_tile_pixel_nib = tile_nibble(byte_val, col_local[0]);
	endfunction

	// ------------------------------------------------------------------
	// Sprite tile-fetch address — plain byte read, no descrambling.
	// ------------------------------------------------------------------
	wire [21:0] spr_byte_addr;
	wire [7:0] sprites_byte = sprites_rom_byte;

	// ------------------------------------------------------------------
	// Palette decode: RRRRGGGGBBBBRGBx (emupal.cpp RRRRGGGGBBBBRGBx_decoder)
	// ------------------------------------------------------------------
	function automatic [7:0] expand5to8(input [4:0] v);
		expand5to8 = {v, v[4:2]};
	endfunction

	function automatic [23:0] decode_rgb(input [15:0] raw);
		reg [4:0] r5, g5, b5;
		begin
			r5 = {raw[15:12], raw[3]};
			g5 = {raw[11:8],  raw[2]};
			b5 = {raw[7:4],   raw[1]};
			decode_rgb = {expand5to8(r5), expand5to8(g5), expand5to8(b5)};
		end
	endfunction

	// ------------------------------------------------------------------
	// BG tilemap: page-mapped 16x16 tiles, 256 cols x 32 rows (4096x512
	// logical px) — video_macross.sv's own geometry, frame-constant
	// X/Y scroll (not per-row, see header).
	// ------------------------------------------------------------------
	wire [12:0] bg_line_x = (rd_x + 13'd4096 - VIDEOSHIFT[12:0] + bg_xscroll[12:0]) % 13'd4096;
	wire [12:0] bg_line_y = (rd_y + 13'd512 + bg_yscroll[12:0]) % 13'd512;
	wire [7:0]  bg_col = bg_line_x[11:4];
	wire [3:0]  bg_px  = bg_line_x[3:0];
	wire [4:0]  bg_row = bg_line_y[8:4];
	wire [3:0]  bg_py  = bg_line_y[3:0];

	// tilemap_scan_pages: (row&0xf) | ((col&0xff)<<4) | ((row&0x10)<<8)
	assign bgvram_addr = {tilerambank, bg_row[4], bg_col, bg_row[3:0]};

	// common_get_bg_tile_info<0,1>: (code&0xfff)|(m_bgbank<<12) — 14-bit
	// code for macross2's own 16384-tile ROM (bg_bank[1:0], same as
	// macross's own — see header).
	wire [13:0] bg_code = {bg_bank[1:0], bgvram_data[11:0]};
	wire [3:0]  bg_half_col = bg_px;
	assign bg_byte_addr = {bg_code, 7'd0} + (bg_half_col >= 4'd8 ? 21'd64 : 21'd0) + {15'd0, bg_py, 2'd0} + {19'd0, bg_half_col[2:1]};
	wire [3:0] bg_pix_nib = bg_tile_pixel_nib(bgtile_byte, bg_half_col & 4'h7);
	wire [9:0] bg_pal_addr = BG_PAL_BASE + {bgvram_data[15:12], bg_pix_nib};

	// ------------------------------------------------------------------
	// TX tilemap: fixed 8x8 tiles, 64x32 (512x256 logical px — see
	// header, video_gunnail.sv's own sizing), no scroll beyond the
	// shared dx, transparent pen 15.
	// ------------------------------------------------------------------
	wire [9:0] tx_sum = {2'b0, rd_x[7:0]} + 10'd512 - VIDEOSHIFT[9:0];
	wire [8:0] tx_line_x = tx_sum[8:0]; // mod 512 (logical width), truncation is the modulo
	wire [7:0] tx_line_y = rd_y;        // 256 logical height, no scroll — direct
	wire [5:0] tx_col = tx_line_x[8:3]; // 6 bits — 64 columns
	wire [2:0] tx_px  = tx_line_x[2:0];
	wire [4:0] tx_row = tx_line_y[7:3];
	wire [2:0] tx_py  = tx_line_y[2:0];

	// TILEMAP_SCAN_COLS, 64x32: tile_index = col*32 + row (11 bits, 0-2047)
	assign txvram_addr = {tx_col, 5'd0} + {6'd0, tx_row};

	wire [3:0] tx_pix_nib = tile_nibble(fgtile_rom_byte, tx_px[0]);
	wire       tx_opaque = (tx_pix_nib != 4'hF);
	wire [9:0] tx_pal_addr = TX_PAL_BASE + {2'd0, txvram_data[15:12], tx_pix_nib};

	// ------------------------------------------------------------------
	// Live per-pixel palette tap, shared by both tilemap layers — TX
	// wins when opaque (pen!=15), else BG.
	// ------------------------------------------------------------------
	assign palette_addr = tx_opaque ? tx_pal_addr : bg_pal_addr;
	wire [23:0] tile_rgb = decode_rgb(palette_data);

	// ------------------------------------------------------------------
	// Sprite RAM double-buffered snapshot — unchanged from
	// video_macross.sv's own (ping-ponging 2048-entry buffers).
	// ------------------------------------------------------------------
	// Two separate named arrays, not one 2D array with a dynamic outer
	// index (snap_buf[snap_cur][...]) — Quartus 17.0's own Verilog
	// elaborator segfaults on that construct when the write also sits
	// inside a `case` statement (confirmed directly: this exact crash
	// signature, VeriCaseStatement -> VeriNonBlockingAssign -> AssignRam,
	// appeared during Macross2's own first synthesis attempt). Simulation
	// (Verilator) has never had any issue with the original 2D form.
	reg [15:0] snap_buf_0 [0:2047];
	reg [15:0] snap_buf_1 [0:2047];
	reg        snap_cur; // buffer index the NEXT trigger will overwrite
	reg        snap_pending;
	reg [11:0] snap_idx;

	// ------------------------------------------------------------------
	// Sprite plane: double-buffered display/draw planes — 5-bit colour
	// field, sprite GFXDECODE colour base 0x100 (see header, NOT 4-bit/
	// 0x100-as-16-colours like every prior port's own).
	// ------------------------------------------------------------------
	// Single flat array addressed by {buffer_select, position} — NOT two
	// separate named arrays chosen by a mux. Two attempts at that shape
	// were each tried and rejected directly: a `sprite_plane[draw_buf]
	// [...]` 2D array with a dynamic outer index inside a `case`
	// statement segfaults Quartus 17.0's own Verilog elaborator
	// (confirmed: this exact crash signature, VeriCaseStatement ->
	// VeriNonBlockingAssign -> AssignRam, during Macross2's own first
	// synthesis attempt); splitting into two named arrays
	// (sprite_plane_0/sprite_plane_1) dodges that segfault but hits a
	// DIFFERENT wall at the next synthesis attempt — Quartus's RAM
	// inference flatly refuses to infer two separate array declarations
	// selected by a runtime control signal as one RAM, regardless of
	// read/write idiom (ternary vs. if/else, wire vs. direct-in-
	// always-block were each tried), reporting "uninferred due to
	// asynchronous read logic" and then building an ~1.7M-flip-flop
	// netlist for the two 86016-entry arrays combined — the whole
	// 5CSEBA6 fabric has under 84K registers — which is what actually
	// drove Timing-Driven Synthesis into a multi-GB, effectively-
	// unbounded runtime. Confirmed directly in a minimal standalone
	// repro (two arrays -> uninferred error; one array with a
	// concatenated select bit -> "210 RAM segments", 0 errors) before
	// applying here. snap_buf_0/snap_buf_1 above keep the two-named-
	// arrays shape: at 2048 entries each they're small enough to
	// implement as flip-flops outright (no RAM inference needed), so
	// they don't hit this wall and are left as they were.
	reg [9:0] sprite_plane [0:2*SCREEN_W*SCREEN_H-1]; // {valid,colour[4:0],pix[3:0]} = 1+5+4=10 bits; index = {buffer_select, y*SCREEN_W+x}
	reg        disp_buf;

	wire [16:0] rd_addr = rd_y * SCREEN_W + rd_x;
	wire        rd_in_range = (rd_x < SCREEN_W) && (rd_y < SCREEN_H);

	// HW_ROMS=1 (real hardware) only: registered (synchronous) sprite-
	// plane read, plus a matching 1-cycle delay on the TX/BG composite
	// inputs it's mixed with. An asynchronous read of this 86016-deep x2
	// array cannot be implemented as flip-flops on real hardware —
	// confirmed directly: Quartus 17.0's quartus_map, synthesizing
	// Macross2/tdragon2 (HW_ROMS=1) for the first time, tried exactly
	// that (the "uninferred RAM due to asynchronous read logic" warning
	// it emits for sprite_plane_0/1) and built a netlist needing ~1.7M
	// flip-flops for these two arrays alone — the whole 5CSEBA6 fabric
	// has under 84K registers total — which drove Timing-Driven
	// Synthesis into a multi-GB, effectively-unbounded runtime rather
	// than a clean out-of-resources error. Registering the read lets
	// Quartus infer real block RAM (M10K) instead. HW_ROMS=0 (every
	// existing sim testbench, unchanged): stays fully combinational/
	// zero-latency — those testbenches' own post-frame scan
	// (top.rd_x=x; top.eval(); read top.rd_rgb) never steps clk_sys, so
	// a registered read would never produce new data there, and
	// simulation has no real-BRAM constraint to satisfy in the first
	// place.
	wire       tx_opaque_al;
	wire [23:0] tile_rgb_al;
	wire       rd_in_range_al;
	wire [9:0] spr_entry;
	generate
	if (!HW_ROMS) begin : g_composite_sim
		wire [9:0] spr_entry_raw = sprite_plane[{disp_buf, rd_addr}];
		assign spr_entry      = !rd_in_range ? 10'd0 : spr_entry_raw;
		assign tx_opaque_al   = tx_opaque;
		assign tile_rgb_al    = tile_rgb;
		assign rd_in_range_al = rd_in_range;
	end else begin : g_composite_hw
		reg [9:0] spr_entry_r;
		always @(posedge clk_sys) spr_entry_r <= sprite_plane[{disp_buf, rd_addr}];
		reg        tx_opaque_r;
		reg [23:0] tile_rgb_r;
		reg        rd_in_range_r;
		always @(posedge clk_sys) begin
			tx_opaque_r   <= tx_opaque;
			tile_rgb_r    <= tile_rgb;
			rd_in_range_r <= rd_in_range;
		end
		assign spr_entry      = rd_in_range_r ? spr_entry_r : 10'd0;
		assign tx_opaque_al   = tx_opaque_r;
		assign tile_rgb_al    = tile_rgb_r;
		assign rd_in_range_al = rd_in_range_r;
	end
	endgenerate
	wire        spr_valid = spr_entry[9];

	assign spr_palette_addr = SPR_PAL_BASE + {1'd0, spr_entry[8:0]};
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	// Composite, top to bottom: TX (opaque) > sprite (opaque) > BG.
	assign rd_rgb = !rd_in_range_al ? 24'h0 : (tx_opaque_al ? tile_rgb_al : (spr_valid ? spr_rgb : tile_rgb_al));

	// ------------------------------------------------------------------
	// Sprite draw FSM — unchanged from video_macross.sv's own, except
	// the colour field is 5 bits wide (s_colour[4:0]) throughout instead
	// of 4 (see header), and the byte address is 22 bits wide (macross2's
	// own sprite ROM is 0x400000 bytes/4MB, double macross's own 2MB).
	// ------------------------------------------------------------------
	localparam
		S_RESET_CLR0 = 0,
		S_RESET_CLR1 = 1,
		S_IDLE        = 2,
		S_SNAP_REQ    = 3,
		S_SNAP_LATCH  = 4,
		S_CLEAR       = 5,
		S_SPR_HEAD    = 6,
		S_SPR_UNIT    = 7,
		S_SPR_CHECK   = 8,
		S_SPR_WAIT    = 13, // HW_ROMS=1 only: real block until sprites_ready (see rom_cache1_byte above); at HW_ROMS=0, sprites_ready is tied 1'b1, so this is a single pass-through cycle, unchanged from before this state existed
		S_SPR_CHECK2  = 9,
		S_SPR_PLOT    = 10,
		S_SPR_NEXT    = 11,
		S_DONE        = 12,
		S_SNAP_WAIT   = 14, // HW_ROMS=1 only: real block until mainram_ready (mirrors S_SPR_WAIT — see mainram_ready's own port declaration above); at HW_ROMS=0, mainram_ready is tied 1'b1, so this is a single pass-through cycle
		S_SPR_HEAD_RD     = 15, // read snap_buf's 6 needed words for this slot one at a time (see snap_rd_addr/snap_rd_data below) instead of all 6 combinationally in one cycle — that shape synthesized into a bare "1024:1" mux (Quartus's own multiplexer-restructuring report), ~21K LEs, before this fix
		S_SPR_HEAD_DECIDE = 16; // same decision logic S_SPR_HEAD used to run directly, now using the fully-latched w0/w1/w3/w4/w6/w7

	reg [4:0]  state;
	reg [16:0] clr_idx;
	reg        draw_buf;      // = ~disp_buf for the duration of one draw pass
	reg        draw_snap_idx; // = ~snap_cur, latched for the duration of one draw pass

	integer s_slot;
	integer clk_budget;
	integer s_w, s_h, s_code, s_colour, s_sx, s_sy;
	integer s_tx, s_ty, s_px, s_py;
	integer s_unit_code, s_pixel_x_base, s_pixel_y_base;
	integer s_pix_nib;
	reg [21:0] s_byte_addr;
	assign spr_byte_addr = s_byte_addr;

	// S_SPR_HEAD_RD: read snap_buf's 6 needed words (offsets 0,1,3,4,6,7
	// within the current slot's 8-word record) for one sprite slot,
	// spread one word per clk_sys cycle over a dedicated, unconditional
	// registered read port — mirrors sprite_plane's own working read fix
	// (see its header comment). Presenting all 6 offsets combinationally
	// in a single cycle (as this used to) left Quartus's own
	// multiplexer-restructuring report showing a bare "1024:1" mux for
	// the result, ~21K LEs, roughly on par with sprite_plane's own
	// footprint before ITS fix — same root cause (an async read of a
	// runtime-indexed array), just costing logic instead of registers
	// since snap_buf itself (2048 x 16 x 2) is small enough to stay
	// flip-flop-based. offs+7 (max slot 255) fits in 11 bits, matching
	// snap_idx's own width.
	reg  [10:0] snap_rd_addr;
	reg  [15:0] snap_rd_data;
	always @(posedge clk_sys)
		snap_rd_data <= draw_snap_idx ? snap_buf_1[snap_rd_addr] : snap_buf_0[snap_rd_addr];

	function automatic [10:0] head_rd_offset(input [2:0] idx);
		case (idx)
			3'd0: head_rd_offset = 11'd0;
			3'd1: head_rd_offset = 11'd1;
			3'd2: head_rd_offset = 11'd3;
			3'd3: head_rd_offset = 11'd4;
			3'd4: head_rd_offset = 11'd6;
			default: head_rd_offset = 11'd7;
		endcase
	endfunction

	reg [2:0]  head_rd_idx;
	reg [15:0] head_w0, head_w1, head_w3, head_w4, head_w6, head_w7;

	always @(posedge clk_sys) begin
		if (reset) begin
			state    <= S_RESET_CLR0;
			clr_idx  <= 17'd0;
			disp_buf <= 1'b0;
			snap_cur <= 1'b0;
			snap_pending <= 1'b0;
		end else begin
			if (sprite_dma_trigger) snap_pending <= 1'b1;

			case (state)
				S_RESET_CLR0: begin
					sprite_plane[{1'b0, clr_idx}] <= 10'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) begin
						clr_idx <= 17'd0;
						state <= S_RESET_CLR1;
					end else clr_idx <= clr_idx + 17'd1;
				end
				S_RESET_CLR1: begin
					sprite_plane[{1'b1, clr_idx}] <= 10'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) state <= S_IDLE;
					else clr_idx <= clr_idx + 17'd1;
				end

				S_IDLE: begin
					if (snap_pending) begin
						snap_pending <= 1'b0;
						snap_idx <= 12'd0;
						state <= S_SNAP_REQ;
					end
				end

				// snapshot mainram[0x8000+i] -> snap_buf[snap_cur][i], i=0..2047
				S_SNAP_REQ: begin
					mainram_addr <= 15'h4000 + snap_idx[10:0]; // 0x8000 bytes / 2 = 0x4000 word offset
					state <= S_SNAP_WAIT;
				end
				S_SNAP_WAIT: begin
					if (mainram_ready) state <= S_SNAP_LATCH;
				end
				S_SNAP_LATCH: begin
					if (snap_cur) snap_buf_1[snap_idx] <= mainram_data;
					else          snap_buf_0[snap_idx] <= mainram_data;
					if (snap_idx == 12'd2047) begin
						draw_buf <= ~disp_buf;
						draw_snap_idx <= ~snap_cur;
						clr_idx <= 17'd0;
						state <= S_CLEAR;
					end else begin
						snap_idx <= snap_idx + 12'd1;
						state <= S_SNAP_REQ;
					end
				end

				S_CLEAR: begin
					sprite_plane[{draw_buf, clr_idx}] <= 10'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) begin
						s_slot <= 0;
						clk_budget <= 0;
						state <= S_SPR_HEAD;
					end else clr_idx <= clr_idx + 17'd1;
				end

				// ---------------- sprites ----------------
				// S_SPR_HEAD kicks off the sequential snap_buf read for
				// this slot's 6 needed words (see snap_rd_addr/
				// head_rd_offset above); S_SPR_HEAD_RD walks the other 5;
				// S_SPR_HEAD_DECIDE runs the original decision logic once
				// they're all latched.
				S_SPR_HEAD: begin
					snap_rd_addr <= s_slot * 11'd8 + head_rd_offset(3'd0);
					head_rd_idx  <= 3'd0;
					state <= S_SPR_HEAD_RD;
				end
				S_SPR_HEAD_RD: begin
					case (head_rd_idx)
						3'd0: head_w0 <= snap_rd_data;
						3'd1: head_w1 <= snap_rd_data;
						3'd2: head_w3 <= snap_rd_data;
						3'd3: head_w4 <= snap_rd_data;
						3'd4: head_w6 <= snap_rd_data;
						default: head_w7 <= snap_rd_data; // head_rd_idx == 5
					endcase
					if (head_rd_idx == 3'd5) begin
						state <= S_SPR_HEAD_DECIDE;
					end else begin
						snap_rd_addr <= s_slot * 11'd8 + head_rd_offset(head_rd_idx + 3'd1);
						head_rd_idx  <= head_rd_idx + 3'd1;
					end
				end
				S_SPR_HEAD_DECIDE: begin
					begin : spr_head_decide_blk
						integer budget_after_scan, budget_after_draw;
						integer w, h;

						w = head_w1[3:0];
						h = head_w1[7:4];

						budget_after_scan = clk_budget + 16;
						budget_after_draw = budget_after_scan + 128 * w * h;

						if (budget_after_scan >= MAX_SPRITE_CLOCK) begin
							state <= S_DONE;
						end else if (!head_w0[0]) begin
							clk_budget <= budget_after_scan;
							if (s_slot == 255) state <= S_DONE;
							else begin s_slot <= s_slot + 1; state <= S_SPR_HEAD; end
						end else if (budget_after_draw >= MAX_SPRITE_CLOCK) begin
							state <= S_DONE;
						end else begin
							clk_budget <= budget_after_draw;
							s_w <= w;
							s_h <= h;
							s_code <= head_w3;
							s_colour <= head_w7[4:0];
							s_sx <= (int'(head_w4) & 9'h1ff) + VIDEOSHIFT;
							s_sy <= (int'(head_w6) & 9'h1ff);
							s_ty <= 0; s_tx <= 0; s_py <= 0; s_px <= 0;
							state <= S_SPR_UNIT;
						end
					end
				end

				S_SPR_UNIT: begin
					s_unit_code <= s_code + s_ty * (s_w + 1) + s_tx;
					s_pixel_x_base <= (s_sx + s_tx * 16) % 512;
					s_pixel_y_base <= (s_sy + s_ty * 16) % 512;
					s_px <= 0; s_py <= 0;
					state <= S_SPR_CHECK;
				end

				S_SPR_CHECK: begin
					begin : spr_check_blk
						integer half_offset, col_local, byte_addr;
						half_offset = (s_px >= 8) ? 64 : 0;
						col_local = s_px & 7;
						byte_addr = s_unit_code * 128 + half_offset + s_py * 4 + (col_local >> 1);
						s_byte_addr <= byte_addr[21:0];
					end
					state <= S_SPR_WAIT;
				end
				// Real blocking wait for the fetched byte (see rom_cache1_byte
				// above) — at HW_ROMS=0 sprites_ready is tied 1'b1, so this
				// exits after exactly one cycle, the same single settle cycle
				// this FSM already had before HW_ROMS existed.
				S_SPR_WAIT: begin
					if (sprites_ready) state <= S_SPR_CHECK2;
				end
				S_SPR_CHECK2: begin
					s_pix_nib = tile_nibble(sprites_byte, s_px[0]);
					if (s_pix_nib != 15) state <= S_SPR_PLOT;
					else state <= S_SPR_NEXT;
				end

				S_SPR_PLOT: begin
					begin : spr_plot_blk
						integer sx, sy;
						reg [16:0] plot_addr;
						sx = s_pixel_x_base + s_px;
						sy = s_pixel_y_base + s_py;
						plot_addr = sy * SCREEN_W + sx;
						if (sx < SCREEN_W && sy < SCREEN_H) begin
							sprite_plane[{draw_buf, plot_addr}] <= {1'b1, s_colour[4:0], s_pix_nib[3:0]};
						end
					end
					state <= S_SPR_NEXT;
				end

				S_SPR_NEXT: begin
					if (s_px == 15) begin
						s_px <= 0;
						if (s_py == 15) begin
							s_py <= 0;
							if (s_tx == s_w) begin
								s_tx <= 0;
								if (s_ty == s_h) begin
									if (s_slot == 255) state <= S_DONE;
									else begin s_slot <= s_slot + 1; state <= S_SPR_HEAD; end
								end else begin
									s_ty <= s_ty + 1;
									state <= S_SPR_UNIT;
								end
							end else begin
								s_tx <= s_tx + 1;
								state <= S_SPR_UNIT;
							end
						end else begin
							s_py <= s_py + 1;
							state <= S_SPR_CHECK;
						end
					end else begin
						s_px <= s_px + 1;
						state <= S_SPR_CHECK;
					end
				end

				S_DONE: begin
					disp_buf <= draw_buf;
					snap_cur <= ~snap_cur;
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
