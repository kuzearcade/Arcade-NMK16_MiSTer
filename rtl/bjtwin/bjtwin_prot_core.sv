// NMK16 MiSTerFPGA project — bjtwin hardware family core, PROTECTED
// variant (Family D: bjtwin/bjtwina/bjtwinpa/sabotenb/sabotenba/
// nouryoku — `bjtwin_prot()` in the reference, which calls `bjtwin()`
// then `base_nmk214_215(config)`, the same NMK-215/TMP90840 +
// dual-NMK214-descrambler mechanism macross/gunnail already use).
//
// Built directly on top of the already-verified, unprotected
// rtl/bjtwin/bjtwin_core.sv (Tier 1's own cactus/bjtwinp/nouryokup
// target) — kept as its own separate file rather than modifying that
// one, matching this project's own established per-game-variant
// convention (tdragon1_core.sv was built the same way on top of
// tdragon_core.sv, hachamf_core.sv on top of hachamfb_core.sv).
// bjtwin_core.sv's own memory map is REUSED VERBATIM here — confirmed
// directly against `bjtwin_map()` in nmk16.cpp (not `bjtwin_prot()`'s
// own map, since bjtwin_prot() doesn't define a separate one; it's the
// same map, same base config): 000000-07FFFF ROM, 080000-08000B I/O,
// 080015 flipscreen, 084001/084011 OKI0/1 data, 084020-08402F nmk112
// bank, 088000-0887FF palette, 094001 tilebank, 094003 Y-scroll,
// 09C000-09CFFF bgvram (mirrored at +0x1000), 0F0000-0FFFFF mainram —
// all identical to bjtwin_core.sv's own already-documented map.
//
// Two real differences from bjtwin_core.sv (both confirmed directly
// against the reference, not assumed):
//   - `bjtwin()`'s own base config calls `set_interrupt_timing(config)`
//     — the REAL V-PROM-driven nmk_irq state machine (rtl/nmk_irq/
//     nmk_irq.sv, already built and verified by mustang/tdragon1/
//     macross/gunnail/etc.) — NOT cactus's own `nmk_irq_hacky`
//     fixed-scanline substitute (cactus() explicitly removes the real
//     nmk_irq device and swaps in the hacky one; bjtwin_prot() never
//     does that, so it keeps the real one bjtwin()'s own base config
//     already wires up).
//   - The protection MCU + dual NMK214 descramblers, wired identically
//     to macross_core.sv's own pattern (same TMP90840 ROM/RAM sizing,
//     same nmk214_cfg_we/nmk214_cfg_data config-load path — see
//     rtl/tlcs90/nmk_prot_core.sv's own header). The protection MCU's
//     own ROM (`nmk-215.bin`) is byte-identical to macross's and
//     gunnail's own (confirmed via CRC in nmk16.cpp's own ROM_START
//     blocks, `d355a06f` for all three) — see this project's own
//     docs/tier2-system.md for the already-well-characterized
//     small-but-nonzero cumulative timing-drift issue this shared
//     firmware exposes, expected to recur here too.
//
// Sound (nmk112 + 2x OKIM6295, no NMK004 at all — this hardware family
// never had a sound MCU) stays exactly as bjtwin_core.sv's own: STUBBED
// (084001/084011 OKI ports return 8'hFF, nmk112 bank writes accepted
// but discarded). This is an EXISTING, already-documented limitation of
// cactus's own build carried forward unchanged — not a new gap
// introduced for this port, and out of scope here (see bjtwin_core.sv's
// own header for the original rationale).
module bjtwin_prot_core #(
	parameter ROM_FILE      = "",
	parameter FGTILE_FILE   = "",
	parameter BGTILE_FILE   = "",
	parameter SPRITES_FILE  = "",
	parameter PROT_BOOT_FILE = "",
	parameter VTIMING_FILE  = ""
) (
	input clk_sys,        // 40 MHz
	input reset,           // async, active high

	// debug/trace outputs for the Verilator testbench
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_uds_n,
	output        dbg_lds_n,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output        dbg_halt_68k,
	output [15:0] dbg_prot_pc,
	output        dbg_prot_valid,
	output [15:0] dbg_prot_hl,
	output  [7:0] dbg_prot_a,
	output [15:0] dbg_prot_de,
	output [15:0] dbg_prot_iy,
	output [19:0] dbg_prot_addr,
	output [9:0]  dbg_vt_vcount,

	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,

	input  [10:0] dbg_snap_addr,
	output [15:0] dbg_snap_data,

	output        frame_done
);

	// ------------------------------------------------------------------
	// Clock enables — identical to bjtwin_core.sv's own: CPU clean /4
	// (10MHz from 40MHz), pixel/sprite clean /5 (8MHz, hires class —
	// see rtl/bjtwin/video_timing.sv, already the hi-res timing class
	// bjtwin()'s own set_screen_hires() needs, confirmed by its
	// HTOTAL=512/HACTIVE_START=28/HACTIVE_END=412 constants matching
	// set_screen_hires()'s own set_raw() args exactly — no change
	// needed here). Protection MCU adds a new /10 (4MHz), same divider
	// shape as macross_core.sv's/gunnail_core.sv's own.
	// ------------------------------------------------------------------
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	wire enPhi1 = (cpu_div == 2'd3);
	wire enPhi2 = (cpu_div == 2'd1);

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	reg [3:0] prot_div = 4'd0;
	always @(posedge clk_sys)
		prot_div <= reset ? 4'd0 : (prot_div == 4'd9 ? 4'd0 : prot_div + 4'd1);
	wire prot_clk_r = (prot_div < 4'd5); // 40MHz/10 = 4MHz

	// ------------------------------------------------------------------
	// fx68k
	// ------------------------------------------------------------------
	wire        eRWn, ASn, LDSn, UDSn, VMAn, VPAn_i;
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

	wire halt_68k;
	assign dbg_halt_68k = halt_68k;

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(~halt_68k),
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
	// Address decode — identical to bjtwin_core.sv's own.
	// ------------------------------------------------------------------
	wire sel_rom      = (byte_addr <= 24'h07FFFF);
	wire sel_in0      = (byte_addr[23:1] == 23'h040000);
	wire sel_in1      = (byte_addr[23:1] == 23'h040001);
	wire sel_dsw1      = (byte_addr[23:1] == 23'h040004);
	wire sel_dsw2      = (byte_addr[23:1] == 23'h040005);
	wire sel_flip      = (byte_addr[23:1] == 23'h04000A);
	wire sel_oki0      = (byte_addr[23:1] == 23'h042000);
	wire sel_oki1      = (byte_addr[23:1] == 23'h042008);
	wire sel_nmk112    = (byte_addr >= 24'h084020) && (byte_addr <= 24'h08402F);
	wire sel_palette   = (byte_addr >= 24'h088000) && (byte_addr <= 24'h0887FF);
	wire sel_tilebank  = (byte_addr[23:1] == 23'h04A000);
	wire sel_scroll    = (byte_addr[23:1] == 23'h04A001);
	wire sel_bgvram    = (byte_addr >= 24'h09C000) && (byte_addr <= 24'h09DFFF);
	wire sel_mainram   = (byte_addr >= 24'h0F0000) && (byte_addr <= 24'h0FFFFF);

	// ------------------------------------------------------------------
	// ROM (maincpu)
	// ------------------------------------------------------------------
	reg [15:0] rom [0:262143];
	initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
	wire [15:0] rom_dout = rom[byte_addr[18:1]];

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — with a second, shared-bus write port
	// for the protection MCU's own full-bus reach (see nmk_prot_core.sv's
	// own header), matching macross_core.sv's own dual-write pattern.
	// ------------------------------------------------------------------
	reg [15:0] mainram [0:32767];
	wire [14:0] mainram_addr = byte_addr[15:1];
	reg [15:0] mainram_dout;
	always @(posedge clk_sys) begin
		if (sel_mainram & cpu_write) begin
			if (~UDSn) mainram[mainram_addr][15:8] <= oEdb[15:8];
			if (~LDSn) mainram[mainram_addr][7:0]  <= oEdb[7:0];
		end
		if (prot_wr & prot_sel_mainram) begin
			if (~prot_addr[0]) mainram[prot_addr[15:1]][15:8] <= prot_wdata;
			else                mainram[prot_addr[15:1]][7:0]  <= prot_wdata;
		end
	end
	always @(*) mainram_dout = mainram[mainram_addr];

	wire [14:0] vid_mainram_addr;
	reg  [15:0] vid_mainram_dout;
	always @(*) vid_mainram_dout = mainram[vid_mainram_addr];

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16) — dual-write, same pattern.
	// ------------------------------------------------------------------
	reg [15:0] palette [0:1023];
	wire [9:0] palette_addr = byte_addr[10:1];
	reg [15:0] palette_dout;
	always @(posedge clk_sys) begin
		if (sel_palette & cpu_write) begin
			if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
			if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
		end
		if (prot_wr & prot_sel_palette) begin
			if (~prot_addr[0]) palette[prot_addr[10:1]][15:8] <= prot_wdata;
			else                palette[prot_addr[10:1]][7:0]  <= prot_wdata;
		end
	end
	always @(*) palette_dout = palette[palette_addr];

	wire [9:0] vid_palette_addr;
	reg  [15:0] vid_palette_dout;
	always @(*) vid_palette_dout = palette[vid_palette_addr];

	wire [9:0] vid_spr_palette_addr;
	reg  [15:0] vid_spr_palette_dout;
	always @(*) vid_spr_palette_dout = palette[vid_spr_palette_addr];

	// ------------------------------------------------------------------
	// BG tilemap VRAM (2048 x 16, mirrored) — dual-write, same pattern.
	// ------------------------------------------------------------------
	reg [15:0] bgvram [0:2047];
	wire [10:0] bgvram_addr_w = byte_addr[11:1];
	reg [15:0] bgvram_dout;
	always @(posedge clk_sys) begin
		if (sel_bgvram & cpu_write) begin
			if (~UDSn) bgvram[bgvram_addr_w][15:8] <= oEdb[15:8];
			if (~LDSn) bgvram[bgvram_addr_w][7:0]  <= oEdb[7:0];
		end
		if (prot_wr & prot_sel_bgvram) begin
			if (~prot_addr[0]) bgvram[prot_addr[11:1]][15:8] <= prot_wdata;
			else                bgvram[prot_addr[11:1]][7:0]  <= prot_wdata;
		end
	end
	always @(*) bgvram_dout = bgvram[bgvram_addr_w];

	wire [10:0] vid_bgvram_addr;
	reg  [15:0] vid_bgvram_dout;
	always @(*) vid_bgvram_dout = bgvram[vid_bgvram_addr];

	// ------------------------------------------------------------------
	// I/O registers (OKI/nmk112 stubbed, see module header)
	// ------------------------------------------------------------------
	reg [7:0] flip_screen_reg;
	reg [7:0] tilebank_reg;
	reg [7:0] scroll_y_reg;
	reg [7:0] nmk112_bank [0:7];

	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			tilebank_reg    <= 8'h00;
			scroll_y_reg    <= 8'h00;
		end else begin
			if (cpu_write & ~LDSn) begin
				if (sel_flip)     flip_screen_reg <= oEdb[7:0];
				if (sel_tilebank) tilebank_reg    <= oEdb[7:0];
				if (sel_scroll)   scroll_y_reg    <= oEdb[7:0];
				if (sel_nmk112)   nmk112_bank[byte_addr[3:1]] <= oEdb[7:0];
			end
			if (prot_wr & prot_sel_flip)     flip_screen_reg <= prot_wdata;
			if (prot_wr & prot_sel_tilebank) tilebank_reg    <= prot_wdata;
			if (prot_wr & prot_sel_scroll)   scroll_y_reg    <= prot_wdata;
		end
	end

	localparam [15:0] IN0_IDLE  = 16'hFFFF;
	localparam [15:0] IN1_IDLE  = 16'hFFFF;
	localparam [15:0] DSW1_IDLE = 16'hFFFF;
	localparam [15:0] DSW2_IDLE = 16'hFFFF;

	// ------------------------------------------------------------------
	// Read data mux (68000-side)
	// ------------------------------------------------------------------
	reg [15:0] rdata;
	always @(*) begin
		if (sel_rom)          rdata = rom_dout;
		else if (sel_mainram) rdata = mainram_dout;
		else if (sel_palette) rdata = palette_dout;
		else if (sel_bgvram)  rdata = bgvram_dout;
		else if (sel_in0)     rdata = IN0_IDLE;
		else if (sel_in1)     rdata = IN1_IDLE;
		else if (sel_dsw1)    rdata = DSW1_IDLE;
		else if (sel_dsw2)    rdata = DSW2_IDLE;
		else if (sel_oki0)    rdata = 16'h00FF; // stub
		else if (sel_oki1)    rdata = 16'h00FF; // stub
		else                  rdata = 16'hFFFF;
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + REAL interrupt generation (the real difference
	// from bjtwin_core.sv's own hacky substitute — see module header).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	assign dbg_vt_vcount = vt_vcount;
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
	// Protection MCU (Family D, TMP90840/NMK-215 variant) — identical
	// wiring to macross_core.sv's/gunnail_core.sv's own, see this
	// module's own header for the shared-firmware timing-drift caveat.
	// ------------------------------------------------------------------
	wire [19:0] prot_addr;
	assign dbg_prot_addr = prot_addr;
	wire        prot_rd, prot_wr;
	wire [7:0]  prot_wdata;
	wire [7:0]  prot_rdata;

	wire nmk214_cfg_we;
	wire [7:0] nmk214_cfg_data;

	nmk_prot_core #(
		.BOOT_ROM_FILE(PROT_BOOT_FILE),
		.ROM_SIZE(8192), .RAM_BASE(16'hfec0), .RAM_SIZE(256)
	) prot_mcu (
		.clk(prot_clk_r), .reset(reset),
		.bus_addr(prot_addr), .bus_rd(prot_rd), .bus_wr(prot_wr),
		.bus_wdata(prot_wdata), .bus_rdata(prot_rdata),
		.vpos_div4(vt_vcount[9:2]),
		.halt_68k(halt_68k),
		.nmk214_cfg_we(nmk214_cfg_we), .nmk214_cfg_data(nmk214_cfg_data),
		.dbg_pc(dbg_prot_pc), .dbg_valid(dbg_prot_valid),
		.dbg_hl(dbg_prot_hl), .dbg_a(dbg_prot_a), .dbg_de(dbg_prot_de), .dbg_iy(dbg_prot_iy),
		.dbg_int_ram_at_hl()
	);

	wire prot_sel_rom       = (prot_addr <= 20'h07FFFF);
	wire prot_sel_in0       = (prot_addr[19:1] == 19'h040000);
	wire prot_sel_in1       = (prot_addr[19:1] == 19'h040001);
	wire prot_sel_dsw1      = (prot_addr[19:1] == 19'h040004);
	wire prot_sel_dsw2      = (prot_addr[19:1] == 19'h040005);
	wire prot_sel_flip      = (prot_addr[19:1] == 19'h04000A);
	wire prot_sel_palette   = (prot_addr >= 20'h088000) && (prot_addr <= 20'h0887FF);
	wire prot_sel_tilebank  = (prot_addr[19:1] == 19'h04A000);
	wire prot_sel_scroll    = (prot_addr[19:1] == 19'h04A001);
	wire prot_sel_bgvram    = (prot_addr >= 20'h09C000) && (prot_addr <= 20'h09DFFF);
	wire prot_sel_mainram   = (prot_addr >= 20'h0F0000) && (prot_addr <= 20'h0FFFFF);

	wire [15:0] prot_rom_dout     = rom[prot_addr[18:1]];
	wire [15:0] prot_mainram_dout = mainram[prot_addr[15:1]];
	wire [15:0] prot_palette_dout = palette[prot_addr[10:1]];
	wire [15:0] prot_bgvram_dout  = bgvram[prot_addr[11:1]];

	reg [15:0] prot_rdata16;
	always @(*) begin
		if (prot_sel_rom)          prot_rdata16 = prot_rom_dout;
		else if (prot_sel_mainram) prot_rdata16 = prot_mainram_dout;
		else if (prot_sel_palette) prot_rdata16 = prot_palette_dout;
		else if (prot_sel_bgvram)  prot_rdata16 = prot_bgvram_dout;
		else if (prot_sel_in0)     prot_rdata16 = IN0_IDLE;
		else if (prot_sel_in1)     prot_rdata16 = IN1_IDLE;
		else if (prot_sel_dsw1)    prot_rdata16 = DSW1_IDLE;
		else if (prot_sel_dsw2)    prot_rdata16 = DSW2_IDLE;
		else                       prot_rdata16 = 16'hFFFF;
	end
	assign prot_rdata = prot_addr[0] ? prot_rdata16[7:0] : prot_rdata16[15:8];

	// ------------------------------------------------------------------
	// Video pipeline — see rtl/bjtwin/video_bjtwin_prot.sv's own header
	// for the dual-NMK214 descramble wiring.
	// ------------------------------------------------------------------
	video_bjtwin_prot #(
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.SPRITES_FILE(SPRITES_FILE)
	) video (
		.clk_sys(clk_sys),
		.reset(reset),
		.sprite_dma_trigger(sprite_dma_trigger),
		.nmk214_cfg_we(nmk214_cfg_we), .nmk214_cfg_data(nmk214_cfg_data),
		.bgvram_addr(vid_bgvram_addr), .bgvram_data(vid_bgvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout),
		.tilebank_reg(tilebank_reg),
		.scroll_y_reg(scroll_y_reg),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb),
		.dbg_snap_addr(dbg_snap_addr), .dbg_snap_data(dbg_snap_data)
	);

	reg frame_done_r;
	always @(posedge clk_sys) begin
		frame_done_r <= vt_line_start && (vt_vcount == 10'd0);
	end
	assign frame_done = frame_done_r;

	// ------------------------------------------------------------------
	// Debug/trace outputs
	// ------------------------------------------------------------------
	assign dbg_eab    = eab;
	assign dbg_data   = cpu_write ? oEdb : iEdb;
	assign dbg_write  = cpu_write;
	assign dbg_uds_n  = UDSn;
	assign dbg_lds_n  = LDSn;
	assign dbg_as_n   = ASn;
	assign dbg_fc0    = FC0;
	assign dbg_fc1    = FC1;
	assign dbg_fc2    = FC2;

endmodule
