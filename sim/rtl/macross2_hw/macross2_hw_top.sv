// Hardware-mode verification harness for the macross2 game running on the
// SHARED Family C core (rtl/tdragon2/tdragon2_core.sv, HW_ROMS=1,
// game_macross2=1 — see that file's own header: it now serves both
// tdragon2 and macross2 from one module). Originally instantiated a
// separate rtl/macross2/macross2_core.sv; retired once the two games'
// cores were merged (see git history for the pre-merge version).
// Otherwise identical to sim/rtl/tdragon2_hw/tdragon2_hw_top.sv (see that
// file's own header): a real rtl/sdram.sv + sim/models/sdram_model.sv
// wired to all four sd0-sd3 ports (sd2 forwarded internally to
// video_macross2.sv's own arbiter), driven by a real ioctl_download byte
// stream instead of $readmemh. See docs/hw-bringup.md.
//
// rd_x/rd_y are driven INTERNALLY from the core's own live hcount_o/
// vcount_o raster counters, exactly as Macross2.sv's own real hardware
// top does — see tdragon2_hw_top.sv's own header for why a raw
// testbench-controlled sweep is not a faithful model of video_macross2.sv's
// HW_ROMS=1 real-time tile-byte SDRAM fetch pacing.
module macross2_hw_top
(
	input  clk_sys,
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

	output [15:0] dbg_z80_pc,
	output        dbg_z80_m1_n,
	output        dbg_z80_mreq_n,
	output        dbg_z80_iorq_n,
	output        dbg_z80_int_n,
	output        dbg_z80_reset_n,
	output        dbg_z80_cen,

	output        dbg_ym_we,
	output        dbg_ym_cs,
	output [7:0]  dbg_ym_chip_dout,
	output        dbg_ym_irq_n,

	output        dbg_oki0_we,
	output        dbg_oki1_we,
	output [7:0]  dbg_oki0_chip_dout,
	output [7:0]  dbg_oki1_chip_dout,

	output [23:0] rd_rgb,
	output        ce_pix_o,
	output        hblank_o,
	output        vblank_o,
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,

	output        frame_done
);

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
	wire        p0_req, p1_req, p2_req, p3_req;
	wire        p0_ack, p1_ack, p2_ack, p3_ack;

	// REFRESH_CYCLES=240 (6us @ 40MHz clk_sys) — matches Macross2.sv's
	// own real hardware override; see rtl/sdram.sv's own parameter
	// comment. sim/models/sdram_model.sv doesn't model charge decay so
	// this doesn't change simulated behavior, but keeps this testbench
	// consistent with real hardware's own instantiation.
	sdram #(.REFRESH_CYCLES(10'd240)) sdram_inst (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(reset), .clk(clk_sys), .prio_mode(2'd0),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din), .dout0(p0_dout), .req0(p0_req), .ack0(p0_ack),
		.addr1(p1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(p1_dout), .req1(p1_req), .ack1(p1_ack),
		.addr2(p2_addr), .wrl2(p2_wrl), .wrh2(p2_wrh), .din2(p2_din), .dout2(p2_dout), .req2(p2_req), .ack2(p2_ack),
		.addr3(p3_addr), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(p3_dout), .req3(p3_req), .ack3(p3_ack)
	);

	sdram_model model_inst (
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
	);

	// VTIMING_FILE: nmk_irq.sv's own V-PROM has no HW_ROMS gating at
	// all — always loaded via $readmemh regardless — so this must be
	// wired here too, matching Macross2.sv's own real hardware top,
	// or this testbench would silently run with an uninitialized (all
	// zero) interrupt-timing table despite otherwise exercising the
	// real HW_ROMS=1 path.
	tdragon2_core #(.HW_ROMS(1), .VTIMING_FILE("roms/macross2_vtiming.hex")) core_inst (
		.clk_sys(clk_sys), .reset(reset), .game_macross2(1'b1),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.ioctl_index(16'd0), // this testbench streams only the <rom index="0"> data — see tdragon2_core.sv's ioctl_index port comment
		.sd0_addr(p0_addr), .sd0_wrl(p0_wrl), .sd0_wrh(p0_wrh), .sd0_din(p0_din), .sd0_dout(p0_dout), .sd0_req(p0_req), .sd0_ack(p0_ack),
		.sd1_addr(p1_addr), .sd1_req(p1_req), .sd1_dout(p1_dout), .sd1_ack(p1_ack),
		.sd2_addr(p2_addr), .sd2_wrl(p2_wrl), .sd2_wrh(p2_wrh), .sd2_din(p2_din), .sd2_dout(p2_dout), .sd2_req(p2_req), .sd2_ack(p2_ack),
		.sd3_addr(p3_addr), .sd3_req(p3_req), .sd3_dout(p3_dout), .sd3_ack(p3_ack),

		.dbg_eab(dbg_eab), .dbg_data(dbg_data), .dbg_write(dbg_write), .dbg_as_n(dbg_as_n),
		.dbg_fc0(dbg_fc0), .dbg_fc1(dbg_fc1), .dbg_fc2(dbg_fc2),
		.dbg_z80_pc(dbg_z80_pc), .dbg_z80_m1_n(dbg_z80_m1_n), .dbg_z80_mreq_n(dbg_z80_mreq_n),
		.dbg_z80_iorq_n(dbg_z80_iorq_n), .dbg_z80_int_n(dbg_z80_int_n), .dbg_z80_reset_n(dbg_z80_reset_n), .dbg_z80_cen(dbg_z80_cen),
		.dbg_ym_we(dbg_ym_we), .dbg_ym_cs(dbg_ym_cs), .dbg_ym_chip_dout(dbg_ym_chip_dout), .dbg_ym_irq_n(dbg_ym_irq_n),
		.dbg_oki0_we(dbg_oki0_we), .dbg_oki1_we(dbg_oki1_we), .dbg_oki0_chip_dout(dbg_oki0_chip_dout), .dbg_oki1_chip_dout(dbg_oki1_chip_dout),
		.rd_x(rd_x_screen), .rd_y(rd_y_screen), .rd_rgb(rd_rgb),
		.dbg_pal_addr(10'd0), .dbg_pal_data(), .dbg_bgvram_addr(15'd0), .dbg_bgvram_data(),
		.dbg_txvram_addr(11'd0), .dbg_txvram_data(),
		.frame_done(frame_done),

		.audio_l(), .audio_r(),
		.ce_pix_o(ce_pix_o), .hcount_o(hcount_o), .vcount_o(vcount_o), .hblank_o(hblank_o), .vblank_o(vblank_o),
		.in0_i(16'hFFFF), .in1_i(16'hFFFF), .dsw1_i(16'hFFFF), .dsw2_i(16'hFFFF)
	);

endmodule
