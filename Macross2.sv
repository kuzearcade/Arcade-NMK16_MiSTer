// NMK16 MiSTerFPGA project — real hardware top-level for the Family C
// "Macross2" RBF (macross2/tdragon2 share an identical machine config,
// see rtl/tdragon2/tdragon2_core.sv's own header — one .rbf, one .mra
// per game). tdragon2 is the pilot; see docs/hw-bringup.md for the full
// architecture writeup and docs/PLAN.md for the project's overall
// progress. First real hardware top-level in this project — every
// other completed port so far exists only as simulation-verified RTL.
//
// Known, honestly-flagged limitations of this first pass, not yet
// resolved:
//   - HSync/VSync timing below is a reasonable placeholder (this
//     board's real CRT sync timing isn't documented anywhere this
//     project has sourced) — needs tuning against real hardware.
//   - Player input bit mapping (joystick_0/1 -> IN0/IN1) is a
//     reasonable placeholder, not yet cross-checked bit-for-bit against
//     nmk16.cpp's own tdragon2 INPUT_PORTS beyond the directions/
//     buttons/coin/start groupings already confirmed when in0_i/in1_i
//     were added to tdragon2_core.sv.
//   - DSW1/DSW2 are tied to the idle default (all switches off);  no
//     OSD DIP-switch menu yet.
module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1; // signed PCM
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Macross2;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"R[0],Reset;",
	"J1,Button 1,Button 2,Start,Coin;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr_full;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({1'b0}),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr_full),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);
wire [24:0] ioctl_addr = ioctl_addr_full[24:0];

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

// ------------------------------------------------------------------
// Player inputs — see this file's own header for the "not yet
// bit-verified against nmk16.cpp" caveat. Active-low at the core
// (matches nmk16.cpp's own IPT_* convention); joystick_0/1 bit
// convention follows MiSTer's own standard d-pad+4-button mapping
// (bits[3:0]=up/down/left/right, [4]=A/button1, [5]=B/button2,
// [8]=start, [9]=coin — the latter two per this core's own CONF_STR
// "J1,...,Start,Coin" mapping order).
// ------------------------------------------------------------------
wire [15:0] in0_i = ~{5'd0, joystick_1[9], joystick_0[9], 1'b0, joystick_1[8], joystick_0[8]};
wire [15:0] in1_i = ~{2'd0, joystick_1[5:4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3],
                      2'd0, joystick_0[5:4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};
wire [15:0] dsw1_i = 16'hFFFF;
wire [15:0] dsw2_i = 16'hFFFF;

// ------------------------------------------------------------------
// SDRAM — single physical rtl/sdram.sv instance, 4 ports, all running
// at clk_sys itself (see docs/hw-bringup.md — no separate SDRAM clock
// domain, no CDC anywhere in this design).
// ------------------------------------------------------------------
wire [24:1] sd0_addr, sd1_addr, sd2_addr, sd3_addr;
wire        sd0_wrl, sd0_wrh, sd2_wrl, sd2_wrh;
wire [15:0] sd0_din, sd2_din;
wire [15:0] sd0_dout, sd1_dout, sd2_dout, sd3_dout;
wire        sd0_req, sd1_req, sd2_req, sd3_req;
wire        sd0_ack, sd1_ack, sd2_ack, sd3_ack;
wire        sdram_ready;

sdram sdram_inst
(
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
	.init(~pll_locked), .clk(clk_sys), .prio_mode(2'd0),
	.addr0(sd0_addr), .wrl0(sd0_wrl), .wrh0(sd0_wrh), .din0(sd0_din), .dout0(sd0_dout), .req0(sd0_req), .ack0(sd0_ack),
	.addr1(sd1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(sd1_dout), .req1(sd1_req), .ack1(sd1_ack),
	.addr2(sd2_addr), .wrl2(sd2_wrl), .wrh2(sd2_wrh), .din2(sd2_din), .dout2(sd2_dout), .req2(sd2_req), .ack2(sd2_ack),
	.addr3(sd3_addr), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(sd3_dout), .req3(sd3_req), .ack3(sd3_ack)
);

// ------------------------------------------------------------------
// Core
// ------------------------------------------------------------------
wire [23:0] rd_rgb;
wire [8:0]  rd_x_screen;
wire [7:0]  rd_y_screen;
wire        ce_pix_core;
wire [9:0]  hcount_core, vcount_core;
wire        hblank_core, vblank_core;
wire signed [15:0] audio_l, audio_r;

// rd_x/rd_y are screen-relative (0..383/0..223, see video_macross2.sv's
// own rd_in_range check) — the raw raster counters are blanking-
// inclusive (0..511/0..277), so subtract the active-window origin.
// The 9-bit/8-bit truncation below deliberately relies on the
// subtraction underflowing to a value >=384/>=224 during blanking
// (verified arithmetically, not just assumed) so rd_in_range correctly
// reads "not visible" without extra clamping logic.
assign rd_x_screen = hcount_core[8:0] - 9'd28;
assign rd_y_screen = vcount_core[7:0] - 8'd16;

tdragon2_core #(.HW_ROMS(1)) core
(
	.clk_sys(clk_sys), .reset(reset),

	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),

	.sd0_addr(sd0_addr), .sd0_wrl(sd0_wrl), .sd0_wrh(sd0_wrh), .sd0_din(sd0_din), .sd0_dout(sd0_dout), .sd0_req(sd0_req), .sd0_ack(sd0_ack),
	.sd1_addr(sd1_addr), .sd1_req(sd1_req), .sd1_dout(sd1_dout), .sd1_ack(sd1_ack),
	.sd2_addr(sd2_addr), .sd2_wrl(sd2_wrl), .sd2_wrh(sd2_wrh), .sd2_din(sd2_din), .sd2_dout(sd2_dout), .sd2_req(sd2_req), .sd2_ack(sd2_ack),
	.sd3_addr(sd3_addr), .sd3_req(sd3_req), .sd3_dout(sd3_dout), .sd3_ack(sd3_ack),

	.dbg_eab(), .dbg_data(), .dbg_write(), .dbg_as_n(),
	.dbg_fc0(), .dbg_fc1(), .dbg_fc2(),
	.dbg_z80_pc(), .dbg_z80_m1_n(), .dbg_z80_mreq_n(), .dbg_z80_iorq_n(),
	.dbg_z80_int_n(), .dbg_z80_reset_n(), .dbg_z80_cen(),
	.dbg_ym_we(), .dbg_ym_cs(), .dbg_ym_chip_dout(), .dbg_ym_irq_n(),
	.dbg_oki0_we(), .dbg_oki1_we(), .dbg_oki0_chip_dout(), .dbg_oki1_chip_dout(),

	.rd_x(rd_x_screen), .rd_y(rd_y_screen), .rd_rgb(rd_rgb),
	.dbg_pal_addr('0), .dbg_pal_data(), .dbg_bgvram_addr('0), .dbg_bgvram_data(),
	.dbg_txvram_addr('0), .dbg_txvram_data(),
	.frame_done(),

	.audio_l(audio_l), .audio_r(audio_r),

	.ce_pix_o(ce_pix_core), .hcount_o(hcount_core), .vcount_o(vcount_core),
	.hblank_o(hblank_core), .vblank_o(vblank_core),

	.in0_i(in0_i), .in1_i(in1_i), .dsw1_i(dsw1_i), .dsw2_i(dsw2_i)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

// ------------------------------------------------------------------
// Video sync — see this file's own header: placeholder timing, not
// yet tuned against real hardware. HSync/VSync pulses placed within
// the existing hblank/vblank windows video_timing.sv already defines
// (HTOTAL=512/HACTIVE 28-412, VTOTAL=278/VACTIVE 16-240).
// ------------------------------------------------------------------
wire hsync = (hcount_core >= 10'd440) && (hcount_core < 10'd472);
wire vsync = (vcount_core >= 10'd244) && (vcount_core < 10'd247);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix_core;

assign VGA_DE = ~(hblank_core | vblank_core);
assign VGA_HS = hsync;
assign VGA_VS = vsync;
assign VGA_R  = rd_rgb[23:16];
assign VGA_G  = rd_rgb[15:8];
assign VGA_B  = rd_rgb[7:0];

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
