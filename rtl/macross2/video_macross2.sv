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
// Per-scanline raster scroll: macross2/tdragon2 (RASTER_SCROLL=0) have a
// single `scroll_w<0>` register (nmk16.cpp:1094) — `bg_xscroll`/
// `bg_yscroll` below are frame-constant register inputs. raphero
// (RASTER_SCROLL=1, VIDEO_START gunnail) instead has the two 256-word
// tables gunnail_scrollram/scrollramy, applied per bitmap line by
// nmk16_v.cpp bg_update(): for bitmap line y (16..239, i == y1 there),
// yscroll = scrollramy[0] + scrollramy[y], the tilemap row shown is
// (y + yscroll) & 0x1ff, and that row's xscroll = scrollram[0] +
// scrollram[y]. BOTH tables are indexed by the BITMAP y (screen y + 16),
// so scroll_row_addr below is bm_y. The core owns the tables and serves
// the taps; the prefetch tags are tile positions, so per-line changes
// need nothing else here.
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
	// DIAGNOSTIC (HW_ROMS=1 only): paint every pixel whose BG prefetch
	// cache missed magenta and every TX miss cyan, so a real-hardware
	// screenshot shows directly whether a visible artifact is a cache
	// miss (bandwidth/latency) or a hit serving wrong data. 0 = normal.
	parameter DBG_MISS_PAINT = 0,
	// HW_ROMS=1 only. 0: port B carries TX prefetch + sprite fetch (TX
	// first). 1: the TX prefetch stream leaves through the txc_* consumer
	// channel (one sdram_arb channel in the core, where it must get top
	// priority) and the sprite fetch owns port B alone — see the
	// sprite-fetch comments in g_video_rom_hw.
	parameter TX_EXTERNAL = 0,
	parameter [22:0] BASE_WORD_FGTILE  = 23'd0,
	parameter [22:0] BASE_WORD_BGTILE  = 23'd0,
	parameter [22:0] BASE_WORD_SPRITES = 23'd0,
	// Per-scanline X+Y scroll from the scrollram/scrollramy taps (raphero)
	// instead of the frame-constant bg_xscroll/bg_yscroll — see header.
	parameter RASTER_SCROLL = 0,
	// Sprite ROM size in bytes: 0x400000 (macross2/tdragon2, 2 files) or
	// 0x600000 (raphero, 3 files). Sizes the sim array and the tile-code
	// wrap (MAME draws code % elements, elements = bytes/128).
	parameter integer SPRITES_BYTES = 4194304,
	// gfx_macross (gunnail: get_colour_4bit, sprites 0x100 with 16
	// colours, TX at 0x200) vs gfx_macross2 (5-bit sprite colour, TX at
	// 0x300). BG_CODE_BITS: 14 for a 2 MB BG ROM (bg_bank[1:0]), 13 for
	// 1 MB (bg_bank[0] only). NMK214=1: BG bytes and sprite words pass
	// through the two NMK214 descramblers (nmk16.cpp base_nmk214_215),
	// configured by the protection MCU through nmk214_cfg_we/data.
	parameter SPR_COLOUR_BITS = 5,
	parameter [9:0] TX_PAL_BASE_P = 10'h300,
	parameter BG_CODE_BITS = 14,
	parameter NMK214 = 0
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
	input      [31:0] sd_dout_pair,
	output            sd_req,
	input             sd_ack,
	// HW_ROMS=1 only: a SECOND physical SDRAM port (read-only) for the TX
	// prefetch + sprites, so the two real-time tile streams (BG on sd_*,
	// TX here) fetch in parallel — see g_video_rom_hw below.
	output     [24:1] sd_b_addr,
	output            sd_b_req,
	input      [15:0] sd_b_dout,
	input      [31:0] sd_b_dout_pair,
	input             sd_b_ack,
	// TX_EXTERNAL=1: TX prefetch as a consumer-level channel (sdram_arb
	// shape: hold req until valid). Tied off otherwise.
	output     [24:1] txc_addr,
	output            txc_req,
	input             txc_busy,
	input             txc_valid,
	input      [15:0] txc_dout,
	input      [31:0] txc_dout_pair,

	input sprite_dma_trigger, // from nmk_irq: snapshot sprite RAM now
	// High while the sprite-table copy is in progress. The real board's
	// sprite DMA holds the 68000 off the bus for the ~200us the copy
	// takes; MAME copies the whole table in an instant. This copy takes
	// ~2.5 scanlines while the CPU keeps running — and the vblank IRQ
	// (scanline 240) precedes the DMA trigger (242), so a fast CPU can be
	// clearing or rebuilding the table before the copy is through, giving
	// that frame a mostly empty sprite plane (seen in the zero-latency
	// sim as sprites vanishing on random frames). The core stalls the
	// CPU's main-RAM accesses on this signal (tdragon2_core.sv's DTACKn).
	output sprite_dma_busy,

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
	input  [15:0] palette_data,     // HW_ROMS=0: combinational; HW_ROMS=1: registered read, one clk_sys behind palette_addr (see the composite stage)
	output [9:0]  spr_palette_addr, // sprite-plane palette tap (read-time only)
	input  [15:0] spr_palette_data, // same contract as palette_data
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
	// RASTER_SCROLL=1 only (tie the inputs to 0 otherwise): entry 0 of
	// each table plus the entry at scroll_row_addr (the bitmap y of the
	// line being drawn, 16..239 — see header). The core may serve
	// scrollram_row/scrollramy_row one clk_sys late (registered RAM read):
	// rd_y only changes at the hcount wrap, inside the horizontal blank.
	input  [15:0] scrollram_0, scrollramy_0,
	output [7:0]  scroll_row_addr,
	input  [15:0] scrollram_row, scrollramy_row,

	// NMK214=1 only: config-load strobe from the NMK-215 protection MCU
	// (nmk_prot_core.sv), delivered to both descramblers at once.
	input        nmk214_cfg_we,
	input  [7:0] nmk214_cfg_data,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0] rd_x,
	input  [7:0] rd_y,
	output [23:0] rd_rgb
);

	localparam integer SCREEN_W = 384;
	localparam integer SCREEN_H = 224;
	localparam integer VIDEOSHIFT = 92; // set_scrolldx(28+64,28+64) and the sprite generator's videoshift(28+64) — both in MAME BITMAP coordinates, see BITMAP_X0 below
	// MAME positions tilemaps and sprites in BITMAP coordinates: the bitmap
	// spans the whole raster (512x278) and the visible area starts at
	// bitmap (28,16) — the hblank/vblank widths. scrolldx(92) therefore
	// means tilemap x = bitmap_x - 92 + scrollx = screen_x + 28 - 92 +
	// scrollx (hence MAME's own "leftmost 64 pixels have to be retrieved
	// from the other side" comment), tilemap y = screen_y + 16 + scrolly,
	// and a sprite at X lands at bitmap X + 92 = screen X + 64. rd_x/rd_y
	// here are SCREEN coordinates (0..383 / 0..223), so they are converted
	// to bitmap coordinates before any of that math. Before this
	// conversion the whole picture sat 28 pixels right and 16 lines down
	// of MAME's (measured: shifting a sim frame by (-28,-16) matched MAME's
	// snapshot on 96.5% of all pixels), pushing the rightmost 28 columns
	// and bottom 16 rows off-screen — see docs/hw-bringup.md.
	localparam integer BITMAP_X0 = 28;
	localparam integer BITMAP_Y0 = 16;
	localparam integer MAX_SPRITE_CLOCK = 134656; // 512*263, set_max_sprite_clock

	// Palette bases — see header. Sprite is 5-bit (32 colours), not 4-bit.
	localparam [9:0] BG_PAL_BASE  = 10'h000;
	localparam [9:0] SPR_PAL_BASE = 10'h100;
	localparam [9:0] TX_PAL_BASE  = TX_PAL_BASE_P;

	// ------------------------------------------------------------------
	// Graphics ROMs (byte-addressed, see tools/mkgfxrom.py). No
	// descrambling — read directly (see header).
	// ------------------------------------------------------------------
	// HW_ROMS=0: unchanged $readmemh 0-latency sim arrays. HW_ROMS=1: BG
	// on one physical SDRAM port, TX + sprites on a second (fixed priority
	// TX > sprites) — see g_video_rom_hw. BG/TX fetch is per-pixel/real-time
	// (tied to ce_pix) and NOT gated on cache-ready: each goes through a
	// tile_prefetch_byte, whose lookahead stream (the pixel 16 ahead of the
	// one being drawn — `x_look` below — owns the VRAM read port) fetches
	// words four ahead of use, so the use pixel hits a small cache instead
	// of waiting on an on-demand fetch it could never win (see
	// tile_prefetch_byte's own header and docs/hw-bringup.md for the
	// visible artifacts a 1-word on-demand cache left even at 96MHz). A
	// miss still just serves the previous word rather than stalling the
	// raster out of sync with real-time video timing. Sprite fetch is
	// different: it's an FSM-paced background compositing pass, not tied
	// to ce_pix at all, so it keeps a 1-word cache with a REAL blocking
	// wait (see the sprite draw FSM below, S_SPR_WAIT).
	wire [7:0] fgtile_rom_byte;   // TX byte for the pixel being drawn
	wire [7:0] bgtile_rom_byte;   // BG byte for the pixel being drawn
	wire [7:0] sprites_rom_byte;
	wire [15:0] sprites_rom_word;   // the big-endian word the byte belongs to (NMK214 word-mode descramble)
	wire       sprites_ready;
	// VRAM word of the tile the pixel being drawn belongs to (its colour
	// bits [15:12] select the palette row). HW_ROMS=0: the live VRAM read,
	// whose address follows that pixel. HW_ROMS=1: the VRAM read port
	// follows the LOOKAHEAD pixel instead, so this comes back out of the
	// prefetch cache entry that was filled from it.
	wire [15:0] bg_vram_use;
	wire [15:0] tx_vram_use;
	wire        bg_hit, tx_hit; // prefetch-cache hit flags (DBG_MISS_PAINT only; tied 1 at HW_ROMS=0)
	generate
	if (!HW_ROMS) begin : g_video_rom_sim
		reg [7:0] fgtile_rom  [0:131071];  // mcrs2j.1, 8x8x4bpp packed_msb, 32B/tile
		reg [7:0] bgtile_rom  [0:2097151]; // bp932an.a04, 16x16 col_2x2_group, 128B/tile — 16384 tiles (14-bit code, see header)
		reg [7:0] sprites_rom [0:SPRITES_BYTES-1]; // word_swap-extracted, 128B/16x16-unit (see SPRITES_BYTES)
		initial if (FGTILE_FILE  != "") $readmemh(FGTILE_FILE,  fgtile_rom);
		initial if (BGTILE_FILE  != "") $readmemh(BGTILE_FILE,  bgtile_rom);
		initial if (SPRITES_FILE != "") $readmemh(SPRITES_FILE, sprites_rom);
		assign fgtile_rom_byte  = fgtile_rom[fg_byte_addr_sim[16:0]];
		assign bgtile_rom_byte  = bgtile_rom[bg_byte_addr];
		assign sprites_rom_byte = sprites_rom[spr_byte_addr];
		assign sprites_rom_word = {sprites_rom[{spr_byte_addr[22:1], 1'b0}], sprites_rom[{spr_byte_addr[22:1], 1'b1}]}; // get_u16be
		assign sprites_ready = 1'b1;
		assign bgvram_addr = bg_vram_addr_use;
		assign txvram_addr = tx_vram_addr_use;
		assign bg_vram_use = bgvram_data;
		assign tx_vram_use = txvram_data;
		assign bg_hit = 1'b1;
		assign tx_hit = 1'b1;
		assign sd_addr = 24'd0; assign sd_wrl = 1'b0; assign sd_wrh = 1'b0; assign sd_din = 16'd0; assign sd_req = 1'b0;
		assign sd_b_addr = 24'd0; assign sd_b_req = 1'b0;
		assign txc_addr = 24'd0; assign txc_req = 1'b0;
	end else begin : g_video_rom_hw
		// Port A (sd_*): the BG prefetch stream alone, straight onto its own
		// sdram_req. Port B (sd_b_*): TX prefetch + sprites, fixed priority.
		// Two physical ports because the two real-time tile streams each
		// need a word per 4 pixels and a fetch's full round trip (arbiter,
		// both clock crossings, waiting behind the other ports' transactions
		// in rtl/sdram.sv, the transaction itself) is close to that on real
		// hardware: serialised on ONE port they could not both be fed (the
		// miss-painting diagnostic showed BG missing on two thirds of the
		// screen); on separate ports their round trips overlap.
		wire        bg_sd_busy, bg_sd_valid;
		wire [15:0] bg_sd_dout;
		wire [31:0] bg_sd_dout_pair;
		wire [24:1] bg_sd_addr;
		wire        bg_sd_req;
		sdram_req bg_req_inst (
			.clk(clk_sys), .reset(reset),
			.addr(bg_sd_addr), .we(1'b0), .wrl(1'b0), .wrh(1'b0), .din(16'd0),
			.req(bg_sd_req), .busy(bg_sd_busy), .valid(bg_sd_valid), .dout(bg_sd_dout), .dout_pair(bg_sd_dout_pair),
			.sdram_addr(sd_addr), .sdram_wrl(sd_wrl), .sdram_wrh(sd_wrh), .sdram_din(sd_din),
			.sdram_dout(sd_dout), .sdram_dout_pair(sd_dout_pair), .sdram_req(sd_req), .sdram_ack(sd_ack)
		);
		// Consumer-level channels of the TX prefetch and the sprite fetch.
		// TX_EXTERNAL=0: both share port B through a fixed-priority
		// arbiter, TX first. TX_EXTERNAL=1: TX leaves through txc_* and
		// the sprite fetch has port B to itself — the compositing pass is
		// bound by its ROM fetch round trips (32 aligned 4-byte groups per
		// 16x16 unit, ~12 clk_sys each through an arbiter), so sharing the
		// port with the real-time TX stream cost it about a quarter of its
		// frame budget at gameplay sprite loads (docs/hw-bringup.md,
		// "Slowdown").
		wire        arb_busy [0:1];
		wire        arb_valid[0:1];
		wire [24:1] arb_addr [0:1];
		wire        arb_req  [0:1];
		wire [15:0] arb_dout [0:1];
		wire [31:0] arb_dout_pair [0:1];
		if (TX_EXTERNAL) begin : g_tx_ext
			assign txc_addr     = arb_addr[0];
			assign txc_req      = arb_req[0];
			assign arb_busy[0]  = txc_busy;
			assign arb_valid[0] = txc_valid;
			assign arb_dout[0]  = txc_dout;
			assign arb_dout_pair[0] = txc_dout_pair;
			sdram_req spr_req_inst (
				.clk(clk_sys), .reset(reset),
				.addr(arb_addr[1]), .we(1'b0), .wrl(1'b0), .wrh(1'b0), .din(16'd0),
				.req(arb_req[1]), .busy(arb_busy[1]), .valid(arb_valid[1]), .dout(arb_dout[1]), .dout_pair(arb_dout_pair[1]),
				.sdram_addr(sd_b_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
				.sdram_dout(sd_b_dout), .sdram_dout_pair(sd_b_dout_pair), .sdram_req(sd_b_req), .sdram_ack(sd_b_ack)
			);
		end else begin : g_tx_int
			assign txc_addr = 24'd0; assign txc_req = 1'b0;
			sdram_arb #(.N(2), .FIXED_PRIO(1)) video_arb_inst (
				.clk(clk_sys), .reset(reset),
				.i_addr(arb_addr), .i_we('{1'b0,1'b0}), .i_wrl('{1'b0,1'b0}), .i_wrh('{1'b0,1'b0}), .i_din('{16'd0,16'd0}),
				.i_req(arb_req), .i_busy(arb_busy), .i_valid(arb_valid), .i_dout(arb_dout), .i_dout_pair(arb_dout_pair),
				.sdram_addr(sd_b_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
				.sdram_dout(sd_b_dout), .sdram_dout_pair(sd_b_dout_pair), .sdram_req(sd_b_req), .sdram_ack(sd_b_ack)
			);
		end
		assign bgvram_addr = bg_vram_addr_look;
		assign txvram_addr = tx_vram_addr_look;
		tile_prefetch_byte #(.TAG_W(19), .ENTRIES(8), .BASE_WORD_OFFSET(BASE_WORD_FGTILE)) fgtile_cache_inst (
			.clk(clk_sys), .reset(reset),
			.pf_tag(tx_look_tag), .pf_byte_addr({7'd0, fgl_byte_addr}), .pf_vram(txvram_data),
			.use_tag(tx_use_tag), .use_sel(tx_px[2:1]), .data(fgtile_rom_byte), .vram(tx_vram_use), .hit(tx_hit),
			.sd_addr(arb_addr[0]), .sd_req(arb_req[0]), .sd_busy(arb_busy[0]), .sd_valid(arb_valid[0]), .sd_dout(arb_dout[0]), .sd_dout_pair(arb_dout_pair[0])
		);
		tile_prefetch_byte #(.TAG_W(19), .ENTRIES(8), .BASE_WORD_OFFSET(BASE_WORD_BGTILE)) bgtile_cache_inst (
			.clk(clk_sys), .reset(reset),
			.pf_tag(bg_look_tag), .pf_byte_addr({3'd0, bgl_byte_addr}), .pf_vram(bgvram_data),
			.use_tag(bg_use_tag), .use_sel(bg_half_col[2:1]), .data(bgtile_rom_byte), .vram(bg_vram_use), .hit(bg_hit),
			.sd_addr(bg_sd_addr), .sd_req(bg_sd_req), .sd_busy(bg_sd_busy), .sd_valid(bg_sd_valid), .sd_dout(bg_sd_dout), .sd_dout_pair(bg_sd_dout_pair)
		);
		// Sprite ROM byte order on the hardware path: the ROMs are
		// ROM_LOAD16_WORD_SWAP, and MAME's graphics decoder reads the
		// region BYTE-wise from the swapped memory image, where byte b is
		// raw file byte b^1 (the sim's $readmemh array is built that way
		// by mkgfxrom --mode word_swap). The SDRAM image holds the raw
		// file order: the download rebuilds words by byte parity and
		// rom_cache1_byte picks the byte by the same parity, so those two
		// cancel — right for the 68000's word reads (its region is read
		// as words), wrong here. Without the ^1 every sprite row had its
		// 2-pixel column pairs swapped: the jagged "combing" seen in
		// native screenshots on hardware while the sim was pixel-exact.
		// BG/TX/OKI/Z80 regions are plain ROM_LOADs and stay as they are.
		// rom_cache_n_byte (8 pairs + next-pair prefetch), not the 1-pair
		// rom_cache1_byte: see its header — with one pair every 4-byte
		// group of a unit cost a full arbiter round trip and the pass
		// outlasted the frame at gameplay sprite loads.
`ifdef SPR_CACHE1_BASELINE
		// measurement builds only (sim/rtl/tdragon2_hw): the previous 1-pair cache
		rom_cache1_byte #(.BASE_WORD_OFFSET(BASE_WORD_SPRITES)) sprites_cache_inst (
`else
		rom_cache_n_byte #(.BASE_WORD_OFFSET(BASE_WORD_SPRITES), .LINES(8), .PREFETCH(1), .REGION_BYTES(SPRITES_BYTES)) sprites_cache_inst (
`endif
			.clk(clk_sys), .reset(reset),
			.byte_addr({1'd0, spr_byte_addr ^ 23'd1}), .data(sprites_rom_byte), .word(sprites_rom_word), .ready(sprites_ready),
			.sd_addr(arb_addr[1]), .sd_req(arb_req[1]), .sd_busy(arb_busy[1]), .sd_valid(arb_valid[1]), .sd_dout(arb_dout[1]), .sd_dout_pair(arb_dout_pair[1])
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
	wire [7:0]  bgtile_byte;

	function automatic [3:0] bg_tile_pixel_nib(input [7:0] byte_val, input integer col_local);
		bg_tile_pixel_nib = tile_nibble(byte_val, col_local[0]);
	endfunction

	// ------------------------------------------------------------------
	// Sprite tile-fetch address — plain byte read, no descrambling.
	// ------------------------------------------------------------------
	wire [22:0] spr_byte_addr;
	wire [7:0] sprites_byte;

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
	// Lookahead pixel for the HW_ROMS=1 prefetch streams (see
	// g_video_rom_hw above): 16 pixels ahead of the one being drawn, four
	// 4-pixel words (80 clk_sys of slack per word — an 8-pixel lookahead
	// still left a few hundred misses per frame on real hardware in the
	// lines right after vblank, where the 68000's port is busiest, and in
	// sprite-heavy columns). The 9-bit wrap mirrors rd_x's own derivation
	// from hcount (rd_x = hcount - 28 mod 512), so during the horizontal
	// blank before a line — rd_x 496..511 — x_look already runs 0..15 and
	// the line's first words are fetched before its first visible pixel;
	// vcount has advanced by then (it steps at the hcount wrap), so they
	// are fetched for the right line. Unused at HW_ROMS=0.
	wire [8:0] x_look = rd_x + 9'd16;

	wire [9:0]  bm_x      = rd_x + BITMAP_X0[9:0];   // bitmap x of the pixel being drawn
	wire [9:0]  bm_x_look = x_look + BITMAP_X0[9:0]; // ... and of the lookahead pixel
	wire [8:0]  bm_y      = rd_y + BITMAP_Y0[8:0];
	// Effective scroll for this line — see header (RASTER_SCROLL).
	assign scroll_row_addr = bm_y[7:0];
	wire [15:0] bg_xscroll_eff = RASTER_SCROLL ? (scrollram_0 + scrollram_row)   : bg_xscroll;
	wire [15:0] bg_yscroll_eff = RASTER_SCROLL ? (scrollramy_0 + scrollramy_row) : bg_yscroll;
	wire [12:0] bg_line_x = (bm_x + 13'd4096 - VIDEOSHIFT[12:0] + bg_xscroll_eff[12:0]) % 13'd4096;
	wire [12:0] bg_line_y = (bm_y + 13'd512 + bg_yscroll_eff[12:0]) % 13'd512;
	wire [7:0]  bg_col = bg_line_x[11:4];
	wire [3:0]  bg_px  = bg_line_x[3:0];
	wire [4:0]  bg_row = bg_line_y[8:4];
	wire [3:0]  bg_py  = bg_line_y[3:0];

	// tilemap_scan_pages: (row&0xf) | ((col&0xff)<<4) | ((row&0x10)<<8)
	wire [14:0] bg_vram_addr_use = {tilerambank, bg_row[4], bg_col, bg_row[3:0]};

	// Same derivation for the lookahead pixel (same line, so the same
	// row/py). HW_ROMS=1 drives bgvram_addr from this one.
	wire [12:0] bgl_line_x = (bm_x_look + 13'd4096 - VIDEOSHIFT[12:0] + bg_xscroll_eff[12:0]) % 13'd4096;
	wire [7:0]  bgl_col      = bgl_line_x[11:4];
	wire [3:0]  bgl_half_col = bgl_line_x[3:0];
	wire [14:0] bg_vram_addr_look = {tilerambank, bg_row[4], bgl_col, bg_row[3:0]};
	// Tile-space word-PAIR identity ({line_y, line_x>>3}, 8 pixels) — see
	// tile_prefetch_byte's own header for why the tags are positions,
	// not ROM addresses.
	wire [18:0] bg_use_tag  = {1'b0, bg_line_y[8:0], bg_line_x[11:3]};
	wire [18:0] bg_look_tag = {1'b0, bg_line_y[8:0], bgl_line_x[11:3]};

	// common_get_bg_tile_info<0,1>: (code&0xfff)|(m_bgbank<<12) — 14-bit
	// code for macross2's own 16384-tile ROM (bg_bank[1:0], same as
	// macross's own — see header). bg_code is whichever tile the VRAM
	// port currently points at: the use pixel's at HW_ROMS=0 (feeding
	// bg_byte_addr), the lookahead pixel's at HW_ROMS=1 (feeding
	// bgl_byte_addr; bg_byte_addr is then unused).
	wire [13:0] bg_code = (BG_CODE_BITS == 14) ? {bg_bank[1:0], bgvram_data[11:0]} : {1'b0, bg_bank[0], bgvram_data[11:0]};
	wire [3:0]  bg_half_col = bg_px;
	assign bg_byte_addr = {bg_code, 7'd0} + (bg_half_col >= 4'd8 ? 21'd64 : 21'd0) + {15'd0, bg_py, 2'd0} + {19'd0, bg_half_col[2:1]};
	wire [20:0] bgl_byte_addr = {bg_code, 7'd0} + (bgl_half_col >= 4'd8 ? 21'd64 : 21'd0) + {15'd0, bg_py, 2'd0} + {19'd0, bgl_half_col[2:1]};
	// Byte address of the USE pixel, from the VRAM word that travels
	// with the cached byte (bg_vram_use == bgvram_data at HW_ROMS=0) —
	// the NMK214 selects its data bitswap from bits of this address.
	wire [13:0] bg_use_code = (BG_CODE_BITS == 14) ? {bg_bank[1:0], bg_vram_use[11:0]} : {1'b0, bg_bank[0], bg_vram_use[11:0]};
	wire [20:0] bg_use_byte_addr = {bg_use_code, 7'd0} + (bg_half_col >= 4'd8 ? 21'd64 : 21'd0) + {15'd0, bg_py, 2'd0} + {19'd0, bg_half_col[2:1]};
	wire [3:0] bg_pix_nib = bg_tile_pixel_nib(bgtile_byte, bg_half_col & 4'h7);
	wire [9:0] bg_pal_addr = BG_PAL_BASE + {bg_vram_use[15:12], bg_pix_nib};

	// ------------------------------------------------------------------
	// TX tilemap: fixed 8x8 tiles, 64x32 (512x256 logical px — see
	// header, video_gunnail.sv's own sizing), no scroll beyond the
	// shared dx, transparent pen 15.
	// ------------------------------------------------------------------
	// Full 9-bit rd_x: the TX tilemap is 64 tiles = 512 logical px wide
	// and the screen is 384 wide, so screen x 256..383 maps to logical
	// (x+420)%512 = 164..255. Truncating rd_x to 8 bits (as this once did,
	// inherited from video_gunnail.sv) made those columns repeat logical
	// 420..511 — the right third of the text layer was a copy of the left
	// third (a second NMK logo on tdragon2's title, no HUD column, Macross
	// II's "SPECIAL THANKS" cut at x=256). Found by comparing real-hardware
	// captures against MAME snapshots, see docs/hw-bringup.md.
	wire [9:0] tx_sum = bm_x + 10'd512 - VIDEOSHIFT[9:0];
	wire [8:0] tx_line_x = tx_sum[8:0]; // mod 512 (logical width), truncation is the modulo
	wire [7:0] tx_line_y = bm_y[7:0];   // 256 logical height, no scroll — bitmap y directly
	wire [5:0] tx_col = tx_line_x[8:3]; // 6 bits — 64 columns
	wire [2:0] tx_px  = tx_line_x[2:0];
	wire [4:0] tx_row = tx_line_y[7:3];
	wire [2:0] tx_py  = tx_line_y[2:0];

	// TILEMAP_SCAN_COLS, 64x32: tile_index = col*32 + row (11 bits, 0-2047)
	wire [10:0] tx_vram_addr_use = {tx_col, 5'd0} + {6'd0, tx_row};

	// Lookahead-pixel derivation (same line): HW_ROMS=1 drives txvram_addr
	// from this one and fetches fgl_byte_addr — see the BG block above.
	wire [9:0]  txl_sum    = bm_x_look + 10'd512 - VIDEOSHIFT[9:0];
	wire [8:0]  txl_line_x = txl_sum[8:0];
	wire [5:0]  txl_col    = txl_line_x[8:3];
	wire [2:0]  txl_px     = txl_line_x[2:0];
	wire [10:0] tx_vram_addr_look = {txl_col, 5'd0} + {6'd0, tx_row};
	wire [18:0] tx_use_tag  = {5'd0, tx_line_y, tx_line_x[8:3]};
	wire [18:0] tx_look_tag = {5'd0, tx_line_y, txl_line_x[8:3]};
	wire [16:0] fgl_byte_addr = {txvram_data[11:0], 5'd0} + {12'd0, tx_py, 2'd0} + {15'd0, txl_px[2:1]};

	wire [3:0] tx_pix_nib = tile_nibble(fgtile_rom_byte, tx_px[0]);
	wire       tx_opaque = (tx_pix_nib != 4'hF);
	wire [9:0] tx_pal_addr = TX_PAL_BASE + {2'd0, tx_vram_use[15:12], tx_pix_nib};

	// ------------------------------------------------------------------
	// Live per-pixel palette tap, shared by both tilemap layers — TX
	// wins when opaque (pen!=15), else BG.
	// ------------------------------------------------------------------
	assign palette_addr = tx_opaque ? tx_pal_addr : bg_pal_addr;
	wire [23:0] tile_rgb = (DBG_MISS_PAINT && !bg_hit) ? 24'hFF00FF :
	                       (DBG_MISS_PAINT && !tx_hit) ? 24'h00FFFF :
	                       decode_rgb(palette_data);

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
	// The snapshot is taken by its OWN engine (see the always block after
	// the draw FSM's declarations below), at the DMA trigger, regardless
	// of what the draw FSM is doing — into whichever buffer the current
	// draw pass is not reading. It used to be a state of the draw FSM,
	// only reachable once a pass had finished: harmless in the
	// zero-latency sim, where a pass always finishes well within a frame,
	// but on real hardware a sprite-heavy pass (every pixel waits on an
	// SDRAM fetch) can outlast the frame, and the copy then happened at an
	// arbitrary point in the 68000's own frame — mid-update of the sprite
	// table — instead of at the DMA scanline. Static screens survive
	// that (the table never changes); the attract demos did not: sprites
	// missing or garbled. MAME copies the table atomically at the trigger
	// (`sprite_dma()` from the scanline timer), as real hardware does.
	reg        snap_active;   // a copy is in progress
	reg        snap_ready;    // a completed copy awaits a draw pass
	reg        snap_done_idx; // buffer that completed copy landed in
	reg        snap_tgt;      // buffer the running copy writes
	reg  [1:0] snap_phase;    // 0 request, 1 wait, 2 latch — same handshake timing as before
	reg [11:0] snap_idx;
	reg        snap_consume;  // one-cycle pulse from the draw FSM: it has taken snap_done_idx
	assign sprite_dma_busy = snap_active;

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
	// Index = plane * PLANE_PX + (y*SCREEN_W + x) — an OFFSET, not a bit
	// concatenation. This array has 2 x 86016 entries, but it used to be
	// indexed as {plane, y*384+x}, i.e. plane 1 at +131072: its rows from
	// 107 down (indices 172032..217087) lay beyond the array. Verilator
	// dropped those writes (the lower half of every other plane stayed
	// empty: sprites vanishing on alternate frames in the sim); Quartus
	// built a 172032-deep RAM whose out-of-range addresses alias onto
	// indices 0..45055 — the top 117 rows of plane 0 — so drawing plane 1
	// scribbled sprites into the plane being displayed and the next clear
	// wiped them mid-frame: the lines through moving sprites and the
	// flicker seen on hardware.
	localparam integer PLANE_PX = SCREEN_W*SCREEN_H;
	reg [9:0] sprite_plane [0:2*SCREEN_W*SCREEN_H-1]; // {valid,colour[4:0],pix[3:0]} = 1+5+4=10 bits
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
	//
	// Palette taps at HW_ROMS=1 (2026-09-10, NMK-10): palette_data and
	// spr_palette_data are the wrapper's REGISTERED reads of palette_addr
	// / spr_palette_addr — the word arrives one clk_sys after the address
	// — so the 1024 x 16 palette can live in block RAM instead of 16K
	// flip-flops behind three 1024:1 asynchronous read muxes (raphero_core
	// alone: ~16K registers and ~9K ALMs of mux, the bulk of its "own"
	// logic in the fitter's entity report). The composite therefore has
	// two register stages here: stage 1 (one clock after rd_x) holds the
	// plane entry, the TX/BG flags and the tile palette word; stage 2 adds
	// the sprite palette word, whose address only exists at stage 1.
	// rd_rgb is two clk_sys behind rd_x — still inside the 5-clk_sys pixel
	// period, and the framework (and every *_hw testbench) samples rd_rgb
	// at the ce_pix clock at the END of that period. HW_ROMS=0 is
	// untouched: combinational taps, zero latency, as before.
	wire       tx_opaque_al;
	wire [23:0] tile_rgb_al;
	wire       rd_in_range_al;
	wire       spr_valid_al;
	wire [9:0] spr_entry;
	generate
	if (!HW_ROMS) begin : g_composite_sim
		wire [9:0] spr_entry_raw = sprite_plane[rd_addr + (disp_buf ? PLANE_PX : 0)];
		assign spr_entry      = !rd_in_range ? 10'd0 : spr_entry_raw;
		assign tx_opaque_al   = tx_opaque;
		assign tile_rgb_al    = tile_rgb;
		assign rd_in_range_al = rd_in_range;
		assign spr_valid_al   = spr_entry[9];
	end else begin : g_composite_hw
		// Stage 1: plane entry (registered read), TX/BG flags, and the
		// tile palette word — palette_data already IS one clock behind
		// palette_addr, i.e. aligned with these registers.
		reg [9:0] spr_entry_r;
		always @(posedge clk_sys) spr_entry_r <= sprite_plane[rd_addr + (disp_buf ? PLANE_PX : 0)];
		reg        tx_opaque_r;
		reg        rd_in_range_r;
		reg        bg_hit_r, tx_hit_r;
		always @(posedge clk_sys) begin
			tx_opaque_r   <= tx_opaque;
			rd_in_range_r <= rd_in_range;
			bg_hit_r      <= bg_hit;
			tx_hit_r      <= tx_hit;
		end
		wire [23:0] tile_rgb_s1 = (DBG_MISS_PAINT && !bg_hit_r) ? 24'hFF00FF :
		                          (DBG_MISS_PAINT && !tx_hit_r) ? 24'h00FFFF :
		                          decode_rgb(palette_data);
		assign spr_entry = rd_in_range_r ? spr_entry_r : 10'd0; // -> spr_palette_addr
		// Stage 2: the sprite palette word arrives; hold the tile side
		// one more clock to meet it.
		reg        tx_opaque_r2;
		reg        rd_in_range_r2;
		reg        spr_valid_r2;
		reg [23:0] tile_rgb_r2;
		always @(posedge clk_sys) begin
			tx_opaque_r2   <= tx_opaque_r;
			rd_in_range_r2 <= rd_in_range_r;
			spr_valid_r2   <= spr_entry[9];
			tile_rgb_r2    <= tile_rgb_s1;
		end
		assign tx_opaque_al   = tx_opaque_r2;
		assign tile_rgb_al    = tile_rgb_r2;
		assign rd_in_range_al = rd_in_range_r2;
		assign spr_valid_al   = spr_valid_r2;
	end
	endgenerate

	assign spr_palette_addr = SPR_PAL_BASE + {1'd0, spr_entry[8:0]};
	wire [23:0] spr_rgb = decode_rgb(spr_palette_data);

	// Composite, top to bottom: TX (opaque) > sprite (opaque) > BG.
	assign rd_rgb = !rd_in_range_al ? 24'h0 : (tx_opaque_al ? tile_rgb_al : (spr_valid_al ? spr_rgb : tile_rgb_al));

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
		S_SNAP_REQ    = 3,  // retired: the snapshot has its own engine (see snap_* above)
		S_SNAP_LATCH  = 4,  // retired
		S_CLEAR       = 5,
		S_SPR_HEAD    = 6,
		S_SPR_UNIT    = 7,
		S_SPR_CHECK   = 8,
		S_SPR_WAIT    = 13, // retired: S_SPR_CHECK waits in place
		S_SPR_CHECK2  = 9,  // retired: folded into S_SPR_CHECK
		S_SPR_PLOT    = 10, // retired: folded into S_SPR_CHECK2
		S_SPR_NEXT    = 11, // retired: folded into S_SPR_CHECK2
		S_DONE        = 12,
		S_SNAP_WAIT   = 14, // HW_ROMS=1 only: real block until mainram_ready (mirrors S_SPR_WAIT — see mainram_ready's own port declaration above); at HW_ROMS=0, mainram_ready is tied 1'b1, so this is a single pass-through cycle
		S_SPR_HEAD_RD     = 15, // read snap_buf's 6 needed words for this slot one at a time (see snap_rd_addr/snap_rd_data below) instead of all 6 combinationally in one cycle — that shape synthesized into a bare "1024:1" mux (Quartus's own multiplexer-restructuring report), ~21K LEs, before this fix
		S_SPR_HEAD_DECIDE = 16; // same decision logic S_SPR_HEAD used to run directly, now using the fully-latched w0/w1/w3/w4/w6/w7

	reg [4:0]  state;
	reg [16:0] clr_idx;
	reg        draw_buf;      // = ~disp_buf for the duration of one draw pass
	// A finished plane is NOT displayed the moment its pass ends — that
	// happened at whatever scanline the pass reached, so the top of the
	// frame was scanned from the old plane and the bottom from the new
	// one, cutting every sprite that had moved between the two passes at
	// a swap line that wandered from frame to frame (seen on hardware as
	// lines through moving sprites that also seemed to flicker). It waits
	// in pass_done and is swapped in at the sprite-DMA trigger (scanline
	// 242, inside vblank), as the real hardware's frame-synchronous buffer
	// swap does; the next pass does not start until then, so it cannot
	// overwrite the waiting plane. A pass that outlasts a frame just
	// delays the swap by a frame instead of tearing.
	reg        pass_done;
	reg        draw_snap_idx; // = ~snap_cur, latched for the duration of one draw pass

	integer s_slot;
	integer clk_budget;
	integer s_w, s_h, s_code, s_colour, s_sx, s_sy;
	integer s_tx, s_ty, s_px, s_py;
	integer s_unit_code, s_pixel_x_base, s_pixel_y_base;
	integer s_pix_nib;
	// Sprite ROM byte address, COMBINATIONAL from the pixel counters so
	// the cache's `ready` (which follows its address input) is valid in
	// the same cycle the pixel is examined: one cycle per cached pixel in
	// S_SPR_CHECK below, instead of a register-then-wait-then-plot
	// sequence of three. Layout: 128 bytes per 16x16 unit, left half
	// (cols 0-7) at +0, right half at +64, 4 bytes per row.
	// Tile code wraps modulo the ROM's element count (MAME: code %
	// elements). Two conditional subtractions cover every reachable unit
	// code (16-bit sprite code + at most 255 more per multi-tile sprite)
	// for both ROM sizes without a divider; a power-of-two size wraps the
	// same way plain truncation did.
	localparam integer SPR_UNITS = SPRITES_BYTES / 128;
	wire [31:0] s_unit_wrapped = (s_unit_code >= 2*SPR_UNITS) ? s_unit_code - 2*SPR_UNITS :
	                             (s_unit_code >= SPR_UNITS)   ? s_unit_code - SPR_UNITS : s_unit_code;
	wire [31:0] spr_byte_addr_full = s_unit_wrapped * 128 + ((s_px >= 8) ? 64 : 0) + s_py * 4 + ((s_px & 7) >> 1);
	assign spr_byte_addr = spr_byte_addr_full[22:0];

	// ------------------------------------------------------------------
	// NMK214 descramble (NMK214=1) — per-fetch, exactly what MAME's
	// decode_nmk214() precomputes: BG byte at byte address A becomes
	// decode_byte(A, rom[A]); the big-endian sprite word at word address
	// W becomes decode_word(W, word). Data bitswaps only — no address
	// remap — so this sits after the caches, keyed by the logical
	// address of the byte in use. Address bitswap tables: nmk16.cpp
	// nmk214_bg_address_bitswap / nmk214_sprites_address_bitswap.
	// ------------------------------------------------------------------
	generate
	if (NMK214) begin : g_nmk214
		wire [15:0] spr_dec_word;
		nmk214 #(
			.MODE(1'b1), .ADDR_WIDTH(21),
			.ADDR_BITSWAP({5'd20,5'd19,5'd18,5'd17,5'd16,5'd15,5'd14,5'd13,5'd11,5'd3,5'd2,5'd1,5'd0})
		) nmk214_bg (
			.clk(clk_sys), .reset(reset),
			.cfg_we(nmk214_cfg_we), .cfg_data(nmk214_cfg_data), .initialized(),
			.addr(bg_use_byte_addr), .din(16'h0), .dout_word(),
			.din8(bgtile_rom_byte), .dout_byte(bgtile_byte)
		);
		nmk214 #(
			.MODE(1'b0), .ADDR_WIDTH(21),
			.ADDR_BITSWAP({5'd19,5'd18,5'd17,5'd16,5'd15,5'd14,5'd13,5'd12,5'd10,5'd3,5'd2,5'd1,5'd0})
		) nmk214_spr (
			.clk(clk_sys), .reset(reset),
			.cfg_we(nmk214_cfg_we), .cfg_data(nmk214_cfg_data), .initialized(),
			.addr({1'b0, spr_byte_addr[22:1] & 22'hFFFFF}), .din(sprites_rom_word), .dout_word(spr_dec_word),
			.din8(8'h0), .dout_byte()
		);
		assign sprites_byte = spr_byte_addr[0] ? spr_dec_word[7:0] : spr_dec_word[15:8];
	end else begin : g_no_nmk214
		assign bgtile_byte  = bgtile_rom_byte;
		assign sprites_byte = sprites_rom_byte;
	end
	endgenerate

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
	reg        head_rd_settle; // snap_rd_data is REGISTERED: one cycle between presenting an address and its word being readable
	reg [15:0] head_w0, head_w1, head_w3, head_w4, head_w6, head_w7;

	// ---- snapshot engine (see snap_* declarations above) ----
	// A pass reads snap_buf[draw_snap_idx] from S_CLEAR to S_DONE; a copy
	// therefore targets ~draw_snap_idx while a pass is active, and
	// otherwise the buffer opposite the last completed copy (which a pass
	// may be about to start on). A pass never starts while a copy is in
	// flight, so a copy's target can never be the buffer being read.
	wire pass_active = (state != S_IDLE);
	always @(posedge clk_sys) begin
		if (reset) begin
			snap_active   <= 1'b0;
			snap_ready    <= 1'b0;
			snap_done_idx <= 1'b0;
			snap_tgt      <= 1'b0;
			snap_phase    <= 2'd0;
			snap_idx      <= 12'd0;
		end else begin
			if (snap_consume) snap_ready <= 1'b0;
			if (!snap_active) begin
				if (sprite_dma_trigger) begin
					snap_active <= 1'b1;
					snap_idx    <= 12'd0;
					snap_phase  <= 2'd0;
					snap_tgt    <= pass_active ? ~draw_snap_idx : ~snap_done_idx;
				end
			end else begin
				case (snap_phase)
					2'd0: begin // request: mainram[0x8000 + 2*i] -> snap_buf[snap_tgt][i], i = 0..2047
						mainram_addr <= 15'h4000 + snap_idx[10:0]; // 0x8000 bytes / 2 = 0x4000 word offset
						snap_phase <= 2'd1;
					end
					2'd1: if (mainram_ready) snap_phase <= 2'd2; // HW_ROMS=1: real block; HW_ROMS=0: one pass-through cycle
					default: begin // latch
						if (snap_tgt) snap_buf_1[snap_idx] <= mainram_data;
						else          snap_buf_0[snap_idx] <= mainram_data;
						if (snap_idx == 12'd2047) begin
							snap_active   <= 1'b0;
							snap_ready    <= 1'b1;
							snap_done_idx <= snap_tgt;
						end else begin
							snap_idx   <= snap_idx + 12'd1;
							snap_phase <= 2'd0;
						end
					end
				endcase
			end
		end
	end

	always @(posedge clk_sys) begin
		snap_consume <= 1'b0;
		if (reset) begin
			state    <= S_RESET_CLR0;
			clr_idx  <= 17'd0;
			disp_buf  <= 1'b0;
			pass_done <= 1'b0;
		end else begin
			case (state)
				S_RESET_CLR0: begin
					sprite_plane[clr_idx] <= 10'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) begin
						clr_idx <= 17'd0;
						state <= S_RESET_CLR1;
					end else clr_idx <= clr_idx + 17'd1;
				end
				S_RESET_CLR1: begin
					sprite_plane[clr_idx + PLANE_PX] <= 10'd0;
					if (clr_idx == SCREEN_W*SCREEN_H-1) state <= S_IDLE;
					else clr_idx <= clr_idx + 17'd1;
				end

				S_IDLE: begin
					// Start a pass on the latest completed snapshot, never while
					// a copy is in flight (see the snapshot engine above).
					if (snap_ready && !snap_active && !pass_done) begin
						draw_buf      <= ~disp_buf;
						draw_snap_idx <= snap_done_idx;
						snap_consume  <= 1'b1;
						clr_idx       <= 17'd0;
						state         <= S_CLEAR;
					end
				end

				S_CLEAR: begin
					sprite_plane[clr_idx + (draw_buf ? PLANE_PX : 0)] <= 10'd0;
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
					snap_rd_addr   <= s_slot * 11'd8 + head_rd_offset(3'd0);
					head_rd_idx    <= 3'd0;
					head_rd_settle <= 1'b1;
					state <= S_SPR_HEAD_RD;
				end
				// Two cycles per word: snap_rd_data is a registered read, so
				// the cycle after an address is presented only lets the word
				// land; the next cycle latches it and presents the next
				// address. Latching in the same cycle as the address change
				// (as this once did) delivered every word one offset late —
				// the visible flag from the previous slot's colour word, the
				// size from the flag word, the code from the size word —
				// which is why moving sprites were missing or garbled on
				// hardware and in simulation while the sprite-free title
				// screens still matched MAME pixel for pixel.
				S_SPR_HEAD_RD: begin
					if (head_rd_settle) begin
						head_rd_settle <= 1'b0;
					end else begin
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
							snap_rd_addr   <= s_slot * 11'd8 + head_rd_offset(head_rd_idx + 3'd1);
							head_rd_idx    <= head_rd_idx + 3'd1;
							head_rd_settle <= 1'b1;
						end
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
							s_colour <= (SPR_COLOUR_BITS == 5) ? head_w7[4:0] : {1'b0, head_w7[3:0]}; // get_colour_5bit / get_colour_4bit
							// bitmap X+92 / Y, converted to screen coordinates (see BITMAP_X0)
							s_sx <= (int'(head_w4) & 9'h1ff) + VIDEOSHIFT - BITMAP_X0;
							s_sy <= ((int'(head_w6) & 9'h1ff) + 512 - BITMAP_Y0) % 512;
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

				// One state per pixel. The ROM byte address is combinational
				// from (s_unit_code, s_px, s_py) — see spr_byte_addr — so when
				// the byte is already in the cache (sprites_ready, 7 of every 8
				// pixels with the 4-byte cache line) the pixel is plotted and
				// the counters advance in this same cycle; otherwise the state
				// simply repeats until the fetch lands. Tiles that lie wholly
				// outside the screen are skipped on their first pixel (MAME
				// clips them too); the game keeps plenty of off-screen objects
				// in its table, and walking their 256 pixels each (and fetching
				// their ROM data) was a large part of why a pass could outlast
				// a frame, which halved the sprite update rate.
				S_SPR_CHECK: begin
					begin : spr_pix_blk
						integer sx, sy;
						reg [16:0] plot_addr;
						reg        tile_visible, advance;
						integer    px_eff, py_eff; // pixel position the advance logic sees (forced to the tile's last pixel when skipping)
						tile_visible = ((s_pixel_x_base < SCREEN_W) || (s_pixel_x_base > 512 - 16)) &&
						               ((s_pixel_y_base < SCREEN_H) || (s_pixel_y_base > 512 - 16));
						advance = 1'b0; px_eff = s_px; py_eff = s_py;
						if (!tile_visible) begin
							// skip the whole tile: behave as if its last pixel was just done
							px_eff = 15; py_eff = 15; advance = 1'b1;
						end else if (sprites_ready) begin
							s_pix_nib = tile_nibble(sprites_byte, s_px[0]);
							sx = (s_pixel_x_base + s_px) % 512; // wrap per pixel: a sprite straddling the
							sy = (s_pixel_y_base + s_py) % 512; // top/left edge shows its visible part
							plot_addr = sy * SCREEN_W + sx;
							if (s_pix_nib != 15 && sx < SCREEN_W && sy < SCREEN_H) begin
								sprite_plane[plot_addr + (draw_buf ? PLANE_PX : 0)] <= {1'b1, s_colour[4:0], s_pix_nib[3:0]};
							end
							advance = 1'b1;
						end
						if (advance) begin
							if (px_eff == 15) begin
								s_px <= 0;
								if (py_eff == 15) begin
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
								end
							end else begin
								s_px <= s_px + 1;
							end
						end
					end
				end

				S_DONE: begin
					pass_done <= 1'b1;
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase

			// Frame-synchronous plane swap (see pass_done above). Written
			// after the case so a pass finishing in the trigger's own cycle
			// is swapped in at once.
			if (sprite_dma_trigger && (pass_done || state == S_DONE)) begin
				disp_buf  <= draw_buf;
				pass_done <= 1'b0;
			end
		end
	end

`ifdef VERILATOR
	// Sprite-latency tags (docs/known-issues.md NMK-1): number every DMA
	// trigger, carry that number with its snapshot through the draw pass
	// and the plane swap, and report at each trigger which DMA's table was
	// on screen during the frame that just ended. Reference (nmk16_v.cpp
	// screen_update_macross draws m_spriteram_old2, sprite_dma() shifts
	// old2 <- old <- mainram at line 242, the frame is rendered at VBOUT
	// 240 before that DMA): frame j shows the table from DMA j-2. Pure
	// RTL measurement — no MAME frame-index alignment involved.
	integer lat_dma_seq = 0;      // triggers seen so far
	integer lat_snap_seq = 0;     // DMA number of the copy in flight
	integer lat_done_seq = 0;     // DMA number of the completed copy
	integer lat_pass_seq = 0;     // DMA number the running/finished pass rendered
	integer lat_disp_seq = 0;     // DMA number of the plane on screen
	reg     lat_snap_ready_d = 1'b0;
	always @(posedge clk_sys) begin
		lat_snap_ready_d <= snap_ready;
		if (sprite_dma_trigger) begin
			$display("SPRLAT dma#%0d: frame %0d showed table from dma#%0d (lag %0d)", lat_dma_seq + 1, lat_dma_seq + 1, lat_disp_seq, lat_dma_seq + 1 - lat_disp_seq);
			if (pass_done || state == S_DONE) lat_disp_seq = lat_pass_seq;   // same condition as the swap above
			if (!snap_active) lat_snap_seq = lat_dma_seq + 1;                 // same condition as the snapshot start
			lat_dma_seq = lat_dma_seq + 1;
		end
		if (snap_ready && !lat_snap_ready_d) lat_done_seq = lat_snap_seq;    // copy completed
		if (snap_consume) lat_pass_seq = lat_done_seq;                        // pass took it
	end
`endif

endmodule
