// TOP-LEVEL harness (NMK-24): gunnail_core PLUS the real
// rtl/third_party/hiscore/hiscore.v, wired exactly as NMK16_Gunnail.sv
// wires it, so the hiscore state machine itself is under test.
// Hardware-mode verification harness for gunnail_core (HW_ROMS=1) — a
// real rtl/sdram.sv + sim/models/sdram_model.sv on all four sd0-sd3
// ports, loaded by a real ioctl_download byte stream. Mirrors
// sim/rtl/tdragon2_hw/tdragon2_hw_top.sv (see its header for why rd_x/
// rd_y are driven from the core's live raster counters, exactly as
// NMK16_Gunnail.sv does, and not swept by the testbench).
// Multi-game variant (2026-09-11): GAME_SEL and the ROM/V-PROM files are
// parameters, see the Makefile.
module gunnail_hs_top #(
	parameter GAME_SEL      = 0,
	// NMK-29: 1 = derive game_sel from an ioctl index-254 <switches> stream,
	// mirroring NMK16_Gunnail.sv (dip_sw capture, game_sel_comb, registered
	// game_sel_r reset to 0). MiSTer sends that block AFTER the ROM parts, so
	// game_sel is 0 while every ROM/PROM streams -- the class of bug the
	// parameter-driven default can never show. The tb must push 254 LAST.
	parameter SWITCHES_FROM_IOCTL = 0,
	parameter VTIMING_FILE  = "",
	parameter ROM_FILE      = "",
	parameter OKI1_ROM_FILE = "",
	parameter OKI2_ROM_FILE = "",
	// DBG_MISS_PAINT=1: paint BG prefetch-cache misses magenta and TX misses
	// cyan, the same diagnostic the board builds use. Forwarded so a sim run
	// can be compared against a board capture of the same build.
	parameter DBG_MISS_PAINT = 0
) (
	input  clk_sys,
	input  clk_ram, // SDRAM controller clock — see sdram_inst below
	input  reset,

	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input  [7:0]  ioctl_dout,
	output        ioctl_wait,

	output sdram_ready,

	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output [15:0] dbg_nmk004_pc,
	output        dbg_nmk004_valid,
	output        dbg_nmk004_cen,
	output        dbg_nmk004_stall,
	output [31:0] dbg_nmk004_cen_total,
	output [31:0] dbg_nmk004_stall_total,
	output        dbg_host_cmd_we,
	output [7:0]  dbg_host_cmd,
	output        dbg_mcu_reply_we,
	output [7:0]  dbg_mcu_reply,
	output [15:0] dbg_prot_pc,
	output        dbg_prot_valid,
	output        dbg_halt_68k,
	output        dbg_prot_bus_rd,
	output        dbg_prot_bus_wr,
	output [19:0] dbg_prot_addr,
	output        dbg_nmk214_cfg_we,
	output [7:0]  dbg_nmk214_cfg_data,

	output        dbg_ym_we,
	output        dbg_ym_cs,
	output [7:0]  dbg_ym_chip_dout,
	output        dbg_ym_chip_irq_n,

	output        dbg_oki0_we,
	output        dbg_oki1_we,
	output [7:0]  dbg_oki0_chip_dout,
	output [7:0]  dbg_oki1_chip_dout,
	output [31:0] dbg_oki0_adpcm_total,
	output [31:0] dbg_oki0_adpcm_unserved,
	output [31:0] dbg_oki1_adpcm_total,
	output [31:0] dbg_oki1_adpcm_unserved,
	output [31:0] dbg_oki_cen_total,
	output [31:0] dbg_oki0_stall_cen,
	output [31:0] dbg_oki1_stall_cen,
	output signed [15:0] audio_l,

	output [23:0] rd_rgb,
	output        ce_pix_o,
	output        hblank_o,
	output        vblank_o,
	output        lowres_o,
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,

	output        frame_done,

	input  [15:0] ioctl_index,
	// NMK-24 rework probe: isolate the two things hiscore does to the
	// running machine -- pausing the CPU, and taking the RAM port.
	input         hs_pause_en,
	input         hs_access_en,

	// Hiscore observability
	output        hs_pause_o,
	output        hs_configured_o,
	output [23:0] hs_addr_o,
	output        hs_write_o,
	output [31:0] dbg_hs_prot_drop,
	output [31:0] dbg_hs_pause_cycles,
	output [31:0] dbg_hs_writes,

	// Savestates (2026-09-18): rtl/savestate/savestate.sv against a DDR
	// model here (4 slots), driven by the tb's TB_SS_* knobs.
	input         ss_save,
	input         ss_load,
	input   [1:0] ss_slot,
	output        ss_busy,
	output        ss_done_ok,
	output        ss_done_fail,
	output  [1:0] ss_fail_code,
	output        ss_frozen_o,
	output        ss_active_o
);

	wire        ss_freeze, ss_frozen, ss_parked, ss_resume, ss_active, ss_wr, ss_replay, ss_replay_done;
	wire [19:0] ss_addr;
	wire [15:0] ss_rdata, ss_wdata;
	wire        ddr_we, ddr_rd;
	wire [28:0] ddr_addr;
	wire [63:0] ddr_din;
	reg  [63:0] ddr_dout = 64'd0;
	reg         ddr_ready = 1'b0;
	reg  [63:0] ddr_mem [0:131071];   // 4 x 0x8000 64-bit words from 0x3E000000
	integer di;
	initial for (di = 0; di < 131072; di = di + 1) ddr_mem[di] = 64'd0;
	wire [16:0] ddr_idx = ddr_addr[16:0];   // DDR_BASE is 0x07C00000: its low 17 bits are 0
	always @(posedge clk_sys) begin
		ddr_ready <= 1'b0;
		if (ddr_we) ddr_mem[ddr_idx] <= ddr_din;
		if (ddr_rd) begin ddr_dout <= ddr_mem[ddr_idx]; ddr_ready <= 1'b1; end
	end
	assign ss_frozen_o = ss_frozen;
	assign ss_active_o = ss_active;
	savestate #(.SS_WORDS(65536)) ss (
		.clk(clk_sys), .reset(reset),
		.save_req(ss_save), .load_req(ss_load), .slot(ss_slot), .vblank(vblank_o), .allow(1'b1),
		.ss_freeze(ss_freeze), .ss_frozen(ss_frozen), .ss_parked(ss_parked), .ss_resume(ss_resume), .ss_active(ss_active),
		.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
		.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
		.busy(ss_busy), .done_ok(ss_done_ok), .done_fail(ss_done_fail), .fail_code(ss_fail_code), .was_load(),
		.clk_ddr(clk_sys), .ddr_busy(1'b0), .rot_we(1'b0),
		.ddr_we(ddr_we), .ddr_rd(ddr_rd), .ddr_addr(ddr_addr), .ddr_din(ddr_din), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_ready)
	);

	// ------------------------------------------------------------------
	// The real hiscore module, parameterised as NMK16_Gunnail.sv does.
	// ------------------------------------------------------------------
	wire [23:0] hs_addr;
	wire  [7:0] hs_din, hs_dout;
	wire        hs_write, hs_access, hs_pause, hs_configured;
	wire        hi_intent_rd, hi_intent_wr;

	hiscore #(
		.HS_ADDRESSWIDTH(24),
		.HS_SCOREWIDTH(13),
		.CFG_ADDRESSWIDTH(4),
		.CFG_LENGTHWIDTH(2)
	) hi (
		.clk(clk_sys),
		.reset(reset),
		.paused(hs_pause),
		.autosave(1'b1),
		.OSD_STATUS(1'b0),
		.ioctl_upload(1'b0),
		.ioctl_upload_req(),
		.ioctl_download(ioctl_download),
		.ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr),
		.ioctl_index(ioctl_index[7:0]),
		.data_from_hps(ioctl_dout),
		.data_to_hps(),
		.data_from_ram(hs_dout),
		.data_to_ram(hs_din),
		.ram_address(hs_addr),
		.ram_write(hs_write),
		.ram_intent_read(hi_intent_rd),
		.ram_intent_write(hi_intent_wr),
		.pause_cpu(hs_pause),
		.configured(hs_configured)
	);

	// NMK-24: yield the RAM port ONLY on the cycles hiscore actually needs
	// it, not for the whole pause. Holding it for the entire pause locks the
	// protection MCU out of main RAM for the duration of the compare loop.
	assign hs_access       = hs_access_en & hs_pause & (hi_intent_rd | hi_intent_wr);
	wire   hs_pause_core   = hs_pause_en & hs_pause;
	assign hs_pause_o      = hs_pause;
	assign hs_configured_o = hs_configured;
	assign hs_addr_o       = hs_addr;
	assign hs_write_o      = hs_write;

	reg [31:0] pause_cycles = 32'd0, hs_write_cnt = 32'd0;
	always @(posedge clk_sys) begin
		if (reset) begin pause_cycles <= 32'd0; hs_write_cnt <= 32'd0; end
		else begin
			if (hs_pause) pause_cycles <= pause_cycles + 32'd1;
			if (hs_write) hs_write_cnt <= hs_write_cnt + 32'd1;
		end
	end
	assign dbg_hs_pause_cycles = pause_cycles;
	assign dbg_hs_writes       = hs_write_cnt;

	// Same computation as NMK16_Gunnail.sv's own rd_x_screen/rd_y_screen.
	wire [8:0] rd_x_screen = hcount_o[8:0] - (lowres_o ? 9'd92 : 9'd28);
	wire [7:0] rd_y_screen = vcount_o[7:0] - 8'd16;

	wire [15:0] SDRAM_DQ;
	wire [12:0] SDRAM_A;
	wire [1:0]  SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE;

	wire [24:1] p0_addr, p1_addr, p2_addr, p3_addr;
	wire        p0_wrl, p0_wrh, p2_wrl, p2_wrh;
	wire [15:0] p0_din, p2_din;
	wire [15:0] p0_dout, p1_dout, p2_dout, p3_dout;
	wire [31:0] p0_dout_pair, p1_dout_pair, p2_dout_pair, p3_dout_pair;
	wire        p0_req, p1_req, p2_req, p3_req;
	wire        p0_ack, p1_ack, p2_ack, p3_ack;

	// REFRESH_CYCLES=740 at the 96MHz clk_ram — matches NMK16_Gunnail.sv.
	sdram #(.REFRESH_CYCLES(10'd740)) sdram_inst (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(reset), .clk(clk_ram), .prio_mode(2'd0),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .dout0_pair(p0_dout_pair), .req0(p0_req), .ack0(p0_ack),
		.addr1(p1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(p1_dout), .dout1_pair(p1_dout_pair), .req1(p1_req), .ack1(p1_ack),
		.addr2(p2_addr), .wrl2(p2_wrl), .wrh2(p2_wrh), .din2(p2_din), .dout2(p2_dout), .dout2_pair(p2_dout_pair), .req2(p2_req), .ack2(p2_ack),
		.addr3(p3_addr), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(p3_dout), .dout3_pair(p3_dout_pair), .req3(p3_req), .ack3(p3_ack)
	);

	sdram_model model_inst (
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
	);

	// ---- NMK-29: index-254 <switches> capture (copy of NMK16_Gunnail.sv) ----
	reg [7:0] dip_sw [0:7];
	integer dip_i;
	initial for (dip_i = 0; dip_i < 8; dip_i = dip_i + 1) dip_sw[dip_i] = 8'hFF;
	always @(posedge clk_sys)
		if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
			dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
	wire [5:0] game_sel_comb = (dip_sw[2] == 8'hFF) ? 6'd0 : dip_sw[2][5:0];
	reg  [5:0] game_sel_r = 6'd0;
	always @(posedge clk_sys) game_sel_r <= game_sel_comb;
	wire [5:0] game_sel_eff = (SWITCHES_FROM_IOCTL != 0) ? game_sel_r : GAME_SEL[5:0];

	// VTIMING_FILE is always $readmemh (no HW_ROMS gating). OKI*_ROM_FILE
	// feed only the golden-byte audit of the HW-path OKI caches.
	gunnail_core #(.HW_ROMS(1), .VTIMING_FILE(VTIMING_FILE),
	               .ROM_FILE(ROM_FILE), .DBG_MISS_PAINT(DBG_MISS_PAINT),
	               .OKI1_ROM_FILE(OKI1_ROM_FILE), .OKI2_ROM_FILE(OKI2_ROM_FILE)) core_inst (
		.clk_sys(clk_sys), .reset(reset), .game_sel(game_sel_eff), .lowres_o(lowres_o),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.ioctl_index(ioctl_index),
		.sd0_addr(p0_addr), .sd0_wrl(p0_wrl), .sd0_wrh(p0_wrh), .sd0_din(p0_din), .sd0_dout(p0_dout), .sd0_dout_pair(p0_dout_pair), .sd0_req(p0_req), .sd0_ack(p0_ack),
		.sd1_addr(p1_addr), .sd1_req(p1_req), .sd1_dout(p1_dout), .sd1_dout_pair(p1_dout_pair), .sd1_ack(p1_ack),
		.sd2_addr(p2_addr), .sd2_wrl(p2_wrl), .sd2_wrh(p2_wrh), .sd2_din(p2_din), .sd2_dout(p2_dout), .sd2_dout_pair(p2_dout_pair), .sd2_req(p2_req), .sd2_ack(p2_ack),
		.sd3_addr(p3_addr), .sd3_req(p3_req), .sd3_dout(p3_dout), .sd3_dout_pair(p3_dout_pair), .sd3_ack(p3_ack),

		.dbg_eab(dbg_eab), .dbg_data(dbg_data), .dbg_write(dbg_write), .dbg_as_n(dbg_as_n),
		.dbg_fc0(dbg_fc0), .dbg_fc1(dbg_fc1), .dbg_fc2(dbg_fc2),
		.dbg_nmk004_pc(dbg_nmk004_pc), .dbg_nmk004_valid(dbg_nmk004_valid), .dbg_nmk004_cen(dbg_nmk004_cen), .dbg_nmk004_stall(dbg_nmk004_stall),
		.dbg_nmk004_cen_total(dbg_nmk004_cen_total), .dbg_nmk004_stall_total(dbg_nmk004_stall_total),
		.dbg_host_cmd_we(dbg_host_cmd_we), .dbg_host_cmd(dbg_host_cmd), .dbg_mcu_reply_we(dbg_mcu_reply_we), .dbg_mcu_reply(dbg_mcu_reply),
		.dbg_prot_pc(dbg_prot_pc), .dbg_prot_valid(dbg_prot_valid), .dbg_halt_68k(dbg_halt_68k),
		.dbg_prot_hl(), .dbg_prot_a(), .dbg_prot_de(), .dbg_prot_iy(), .dbg_prot_addr(dbg_prot_addr), .dbg_prot_int_ram_at_hl(),
		.dbg_prot_bus_rd(dbg_prot_bus_rd), .dbg_prot_bus_wr(dbg_prot_bus_wr), .dbg_vt_vcount(),
		.dbg_nmk214_cfg_we(dbg_nmk214_cfg_we), .dbg_nmk214_cfg_data(dbg_nmk214_cfg_data),
		.dbg_ym_we(dbg_ym_we), .dbg_ym_cs(dbg_ym_cs), .dbg_ym_chip_dout(dbg_ym_chip_dout), .dbg_ym_chip_irq_n(dbg_ym_chip_irq_n),
		.dbg_oki0_we(dbg_oki0_we), .dbg_oki0_cs(), .dbg_oki0_chip_dout(dbg_oki0_chip_dout), .dbg_oki1_we(dbg_oki1_we), .dbg_oki1_cs(), .dbg_oki1_chip_dout(dbg_oki1_chip_dout),
		.dbg_oki0_adpcm_total(dbg_oki0_adpcm_total), .dbg_oki0_adpcm_unserved(dbg_oki0_adpcm_unserved),
		.dbg_oki1_adpcm_total(dbg_oki1_adpcm_total), .dbg_oki1_adpcm_unserved(dbg_oki1_adpcm_unserved),
		.dbg_oki_cen_total(dbg_oki_cen_total), .dbg_oki0_stall_cen(dbg_oki0_stall_cen), .dbg_oki1_stall_cen(dbg_oki1_stall_cen),
		.dbg_nmk004_a(), .dbg_nmk004_f(), .dbg_nmk004_hl(), .dbg_nmk004_ram_hl(),
		.rd_x(rd_x_screen), .rd_y(rd_y_screen), .rd_rgb(rd_rgb),
		.dbg_pal_addr(10'd0), .dbg_pal_data(), .dbg_bgvram_addr(14'd0), .dbg_bgvram_data(),
		.dbg_txvram_addr(11'd0), .dbg_txvram_data(),
		.frame_done(frame_done),

		.audio_l(audio_l), .audio_r(),
		.ce_pix_o(ce_pix_o), .hcount_o(hcount_o), .vcount_o(vcount_o), .hblank_o(hblank_o), .vblank_o(vblank_o),
		.in0_i(16'hFFFF), .in1_i(16'hFFFF), .dsw1_i(16'hFFFD), .dsw2_i(16'hFFFF), .osd_flip(1'b0),
		.extra_por_hold(1'b0),

		.pause(hs_pause_core & ~ss_busy),
		.hs_addr(hs_addr), .hs_din(hs_din), .hs_dout(hs_dout),
		.hs_write(hs_write), .hs_access(hs_access),
		.dbg_hs_prot_drop(dbg_hs_prot_drop),

		.ss_freeze(ss_freeze), .ss_resume(ss_resume), .ss_active(ss_active), .ss_frozen(ss_frozen), .ss_parked(ss_parked),
		.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
		.ss_replay(ss_replay), .ss_replay_done(ss_replay_done)
	);

endmodule
