// Hardware-mode verification harness for gunnail_core (HW_ROMS=1) — a
// real rtl/sdram.sv + sim/models/sdram_model.sv on all four sd0-sd3
// ports, loaded by a real ioctl_download byte stream. Mirrors
// sim/rtl/tdragon2_hw/tdragon2_hw_top.sv (see its header for why rd_x/
// rd_y are driven from the core's live raster counters, exactly as
// Gunnail.sv does, and not swept by the testbench).
module gunnail_hw_top #(
	parameter integer UNUSED = 0
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
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,

	output        frame_done
);

	// Same computation as Gunnail.sv's own rd_x_screen/rd_y_screen.
	wire [8:0] rd_x_screen = hcount_o[8:0] - 9'd28;
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

	// REFRESH_CYCLES=740 at the 96MHz clk_ram — matches Gunnail.sv.
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

	// VTIMING_FILE is always $readmemh (no HW_ROMS gating). OKI*_ROM_FILE
	// feed only the golden-byte audit of the HW-path OKI caches.
	gunnail_core #(.HW_ROMS(1), .VTIMING_FILE("roms/gunnail_vtiming.hex"),
	               .ROM_FILE("../gunnail/roms/gunnail_maincpu.hex"),
	               .OKI1_ROM_FILE("../gunnail/roms/gunnail_oki1.hex"), .OKI2_ROM_FILE("../gunnail/roms/gunnail_oki2.hex")) core_inst (
		.clk_sys(clk_sys), .reset(reset), .game_sel(4'd0), .lowres_o(),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.ioctl_index(16'd0),
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
		.in0_i(16'hFFFF), .in1_i(16'hFFFF), .dsw1_i(16'hFFFD), .dsw2_i(16'hFFFF),
		.extra_por_hold(1'b0)
	);

endmodule
