// Prefetching byte cache for the real-time BG/TX tilemap fetch (HW_ROMS=1
// only) — the replacement for rom_cache1_byte on those two consumers.
//
// Why a plain 1-word on-demand cache is not enough, even at 96MHz: the
// tile pipeline in video_macross2.sv computes the wanted ROM byte
// combinationally from the pixel being drawn RIGHT NOW, so a 1-word
// cache can only start fetching a word when the first pixel that needs
// it is already on screen. The request-to-data round trip (arbitration,
// the clock crossing into and out of rtl/sdram.sv, the transaction
// itself) is several clk_sys cycles, i.e. one to two pixels, so the
// first pixel or two of EVERY new word is served from the previous word
// — and at line start, where both layers plus the sprite pass all want
// the bus at once, several pixels are. That is exactly the residual
// left after the 96MHz change: a garbage column at x=0..6 and short
// horizontal dashes wherever the sprite compositing pass was busy (see
// docs/hw-bringup.md).
//
// The fix is to separate the REQUEST stream from the USE stream:
//
//   pf_*  — the "lookahead" pixel, PF pixels ahead of the one being
//           drawn (video_macross2.sv uses PF=16, four words ahead). Its
//           tile-space identity (`pf_tag`), its ROM byte address and the
//           VRAM word that address was derived from are presented here;
//           any word not already cached or in flight gets fetched.
//   use_* — the pixel being drawn. Its `use_tag` is looked up in a small
//           fully-associative cache (ENTRIES words) that, in steady
//           state, holds word(x) .. word(x+PF), so it hits — with ~PF
//           pixels (16 px = 80 clk_sys) of slack per fetch instead of
//           zero.
//
// Each entry is one aligned word PAIR (4 bytes = 8 pixels), which is
// exactly what one rtl/sdram.sv transaction returns; a TX tile row and a
// BG half-tile row are each one such group, 4-byte aligned in ROM.
//
// Tags are tile-SPACE positions ({line_y, line_x>>3}), not ROM
// addresses: the use pixel's ROM address would need its own VRAM read
// (the tile code), but there is only one VRAM read port and the
// lookahead owns it. The entry therefore also stores the VRAM word that
// produced it, and hands it back on the use side so the palette bits
// (VRAM[15:12]) come from the right tile too.
//
// Non-blocking, like rom_cache1_byte before it: on a miss (only if a
// fetch has fallen more than PF pixels behind) the most recent hit's
// word is served, never a stall of the raster.
//
// Fetch-order replacement: entries are overwritten round-robin, which
// is exactly "evict the oldest" because the lookahead issues fetches in
// pixel order. ENTRIES must be a power of two and exceed PF/4 + 1 (the
// live words); video_macross2.sv uses 8 for PF=16.
//
// The lookahead's VRAM read may be registered (it is, in
// tdragon2_core.sv's HW_ROMS=1 wrapper: one cycle), so a fetch is only
// issued once `pf_tag` has been stable for two cycles — by then
// `pf_vram`/`pf_byte_addr` reflect it. A pixel lasts five clk_sys
// cycles, so this never delays a fetch by more than it must.
// base_word (2026-09-11): the region's SDRAM word offset is a runtime
// input, not a parameter — see rom_cache_n_byte.sv.
module tile_prefetch_byte #(
	parameter TAG_W = 19,
	parameter ENTRIES = 4                      // power of two
) (
	input             clk,
	input             reset,

	input  [22:0]     base_word,     // this ROM region's byte offset / 2 in the shared SDRAM

	// lookahead (prefetch) stream
	input  [TAG_W-1:0] pf_tag,
	input  [23:0]      pf_byte_addr,   // relative to this region's own base; bit 0 ignored
	input  [15:0]      pf_vram,        // VRAM word pf_byte_addr was derived from

	// use stream
	input  [TAG_W-1:0] use_tag,
	input  [1:0]       use_sel,        // byte select within the 4-byte group (the use pixel's byte_addr[1:0])
	output [7:0]       data,
	output [15:0]      vram,           // VRAM word stored with the matching entry
	output             hit,            // diagnostic: 1 iff data/vram are the use pixel's own, not stale

	// one logical channel of an sdram_arb.sv instance (hold req until valid)
	output [24:1] sd_addr,
	output        sd_req,
	input         sd_busy,
	input         sd_valid,
	input  [15:0] sd_dout,      // unused: the whole aligned pair is cached
	input  [31:0] sd_dout_pair
);

	localparam PTR_W = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES);

	reg [TAG_W-1:0]   e_tag  [0:ENTRIES-1];
	reg [31:0]        e_word [0:ENTRIES-1]; // aligned word pair = 4 bytes = 8 pixels
	reg [15:0]        e_vram [0:ENTRIES-1];
	reg [ENTRIES-1:0] e_valid;
	reg [PTR_W-1:0]   wr_ptr;

	reg [TAG_W-1:0] pf_tag_r, pf_tag_rr;
	reg             pending;
	reg [TAG_W-1:0] req_tag;
	reg [15:0]      req_vram;
	reg [22:0]      req_word;

	reg [31:0] last_word;
	reg [15:0] last_vram;

	// ---- use side: fully associative lookup, stale-serve on miss ----
	integer i;
	reg        use_hit;
	reg [31:0] use_word;
	reg [15:0] use_vram;
	always @* begin
		use_hit  = 1'b0;
		use_word = last_word;
		use_vram = last_vram;
		for (i = 0; i < ENTRIES; i = i + 1) begin
			if (e_valid[i] && (e_tag[i] == use_tag)) begin
				use_hit  = 1'b1;
				use_word = e_word[i];
				use_vram = e_vram[i];
			end
		end
	end
	always @(posedge clk) begin
		if (reset) begin
			last_word <= 32'd0;
			last_vram <= 16'd0;
		end else if (use_hit) begin
			last_word <= use_word;
			last_vram <= use_vram;
		end
	end
	assign data = (use_sel == 2'd0) ? use_word[7:0]   :
	              (use_sel == 2'd1) ? use_word[15:8]  :
	              (use_sel == 2'd2) ? use_word[23:16] : use_word[31:24];
	assign vram = use_vram;
	assign hit  = use_hit;

	// ---- prefetch side ----
	reg pf_present;
	always @* begin
		pf_present = pending && (req_tag == pf_tag);
		for (i = 0; i < ENTRIES; i = i + 1)
			if (e_valid[i] && (e_tag[i] == pf_tag)) pf_present = 1'b1;
	end
	wire pf_stable = (pf_tag == pf_tag_r) && (pf_tag_r == pf_tag_rr);

	assign sd_addr = {1'b0, req_word};
	assign sd_req  = pending;

	always @(posedge clk) begin
		pf_tag_r  <= pf_tag;
		pf_tag_rr <= pf_tag_r;
		if (reset) begin
			pending <= 1'b0;
			e_valid <= '0;
			wr_ptr  <= '0;
		end else begin
			if (!pending && pf_stable && !pf_present) begin
				pending  <= 1'b1;
				req_tag  <= pf_tag;
				req_vram <= pf_vram;
				req_word <= base_word + pf_byte_addr[23:1];
			end
			if (pending && sd_valid) begin
				e_tag[wr_ptr]   <= req_tag;
				e_word[wr_ptr]  <= sd_dout_pair;
				e_vram[wr_ptr]  <= req_vram;
				e_valid[wr_ptr] <= 1'b1;
				wr_ptr  <= wr_ptr + 1'b1;
				pending <= 1'b0;
			end
		end
	end

endmodule
