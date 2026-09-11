// Video-only harness: rtl/macross2/video_macross2.sv (HW_ROMS=0) fed with a
// MAME video-state dump (scroll tables, BG/TX VRAM, palette, the sprite RAM
// copy, tilebank) of one frame, so a single rendered frame can be compared
// pixel-for-pixel with MAME's snapshot of that same frame. Used to verify
// the per-line (raster) scroll path with real per-row table contents, which
// the attract demo only exercises after the sim and MAME have drifted apart.
// Parameters select the game's own video configuration (gunnail here).
module video_state_top #(
	parameter FGTILE_FILE = "", parameter BGTILE_FILE = "", parameter SPRITES_FILE = "",
	parameter SCROLLRAM_FILE = "", parameter SCROLLRAMY_FILE = "", parameter BGVRAM_FILE = "",
	parameter TXVRAM_FILE = "", parameter PALETTE_FILE = "", parameter SPRITERAM_FILE = "",
	parameter integer SPRITES_BYTES = 2097152,
	parameter SPR_COLOUR_BITS = 4, parameter [9:0] TX_PAL_BASE_P = 10'h200, parameter BG_CODE_BITS = 13,
	parameter NMK214 = 1, parameter [7:0] NMK214_CFG_SPR = 8'h02, parameter [7:0] NMK214_CFG_BG = 8'h0E
) (
	input clk_sys, input reset,
	input [7:0] bg_bank,
	input [1:0] tilerambank,
	input sprite_dma_trigger,
	output sprite_dma_busy,
	input [8:0] rd_x, input [7:0] rd_y, output [23:0] rd_rgb
);
	reg [15:0] scrollram [0:255];  reg [15:0] scrollramy [0:255];
	reg [15:0] bgvram [0:32767];   reg [15:0] txvram [0:2047];
	reg [15:0] palette [0:1023];   reg [15:0] mainram [0:32767];   // sprite copy lands at word 0x4000 (byte 0x8000)
	reg [15:0] spriteram [0:2047];
	integer i;
	initial begin
		$readmemh(SCROLLRAM_FILE, scrollram); $readmemh(SCROLLRAMY_FILE, scrollramy);
		$readmemh(BGVRAM_FILE, bgvram); $readmemh(TXVRAM_FILE, txvram); $readmemh(PALETTE_FILE, palette);
		$readmemh(SPRITERAM_FILE, spriteram);
		for (i = 0; i < 2048; i = i + 1) mainram[15'h4000 + i] = spriteram[i];
	end
	wire [14:0] bgvram_addr; wire [10:0] txvram_addr; wire [9:0] pal_addr, spal_addr; wire [14:0] mainram_addr; wire [7:0] row;
	// NMK214 config load: two strobes right after reset
	reg [3:0] cfg_cnt = 4'd0; reg cfg_we; reg [7:0] cfg_data;
	always @(posedge clk_sys) begin
		cfg_we <= 1'b0;
		if (reset) cfg_cnt <= 4'd0;
		else if (cfg_cnt < 4'd4) begin
			cfg_cnt <= cfg_cnt + 4'd1;
			if (cfg_cnt == 4'd1) begin cfg_we <= 1'b1; cfg_data <= NMK214_CFG_SPR; end
			if (cfg_cnt == 4'd3) begin cfg_we <= 1'b1; cfg_data <= NMK214_CFG_BG; end
		end
	end
	video_macross2 #(
		.FGTILE_FILE(FGTILE_FILE), .BGTILE_FILE(BGTILE_FILE), .SPRITES_FILE(SPRITES_FILE),
		.HW_ROMS(0), .RASTER_SCROLL(1), .SPRITES_BYTES(SPRITES_BYTES),
		.SPR_COLOUR_BITS(SPR_COLOUR_BITS), .TX_PAL_BASE_P(TX_PAL_BASE_P), .BG_CODE_BITS(BG_CODE_BITS), .NMK214(NMK214)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.game_powerins(1'b0), .base_word_fgtile(23'd0), .base_word_bgtile(23'd0), .base_word_sprites(23'd0),
		.lowres(1'b0), .raster_scroll(1'b1), .cfg_rt(1'b0), .bga_pal_base_i(11'd0), .bgb_pal_base_i(11'd0), .spr_pal_base_i(11'd0), .tx_pal_base_i(11'd0),
		.bga_code_mask_i(14'd0), .bgb_code_mask_i(14'd0), .spr_units_i(18'd0), .sprdma_word_base(15'h4000), .nmk214_en(1'b1), .spr_swap(1'b1),
		.bg2_en(1'b0), .bga_rom2(1'b0), .bgb_rom2(1'b0), .base_word_bgtile_b(23'd0), .bgvram_b_addr(), .bgvram_b_data(16'd0), .bgb_xscroll(16'd0), .bgb_yscroll(16'd0),
		.txc_addr(), .txc_req(), .txc_busy(1'b0), .txc_valid(1'b0), .txc_dout(16'd0), .txc_dout_pair(32'd0),
		.sprite_dma_trigger(sprite_dma_trigger), .sprite_dma_busy(sprite_dma_busy),
		.bgvram_addr(bgvram_addr), .bgvram_data(bgvram[bgvram_addr]),
		.txvram_addr(txvram_addr), .txvram_data(txvram[txvram_addr]),
		.palette_addr(pal_addr), .palette_data(palette[pal_addr]),
		.spr_palette_addr(spal_addr), .spr_palette_data(palette[spal_addr]),
		.mainram_addr(mainram_addr), .mainram_data(mainram[mainram_addr]), .mainram_ready(1'b1),
		.bg_xscroll(16'd0), .bg_yscroll(16'd0),
		.scrollram_0(scrollram[0]), .scrollramy_0(scrollramy[0]),
		.scroll_row_addr(row), .scrollram_row(scrollram[row]), .scrollramy_row(scrollramy[row]),
		.nmk214_cfg_we(cfg_we), .nmk214_cfg_data(cfg_data),
		.bg_bank(bg_bank), .tilerambank(tilerambank),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb),
		.sd_addr(), .sd_wrl(), .sd_wrh(), .sd_din(), .sd_dout(16'd0), .sd_dout_pair(32'd0), .sd_req(), .sd_ack(1'b0),
		.sd_b_addr(), .sd_b_req(), .sd_b_dout(16'd0), .sd_b_dout_pair(32'd0), .sd_b_ack(1'b0)
	);
endmodule
