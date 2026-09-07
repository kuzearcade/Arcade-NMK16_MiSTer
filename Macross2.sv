// NMK16 MiSTerFPGA project — real hardware top-level for the Family C
// "Macross2" RBF, serving BOTH macross2 and tdragon2 (identical machine
// config, merged into one runtime-selectable core — see
// rtl/tdragon2/tdragon2_core.sv's own header for the full derivation of
// why a merge was safe/necessary: two nearly-identical ~60%-ALM-budget
// cores could not both fit as separate instances). tdragon2 was the
// pilot; see docs/hw-bringup.md for the full architecture writeup and
// docs/PLAN.md for the project's overall progress. First real hardware
// top-level in this project — every other completed port so far exists
// only as simulation-verified RTL.
//
// Game select: game_macross2 below is a genuine RUNTIME core input, not
// a build-time choice — driven from a HIDDEN status[] bit (status[16])
// that each game's own .mra sets via its <switches default="..."> raw
// byte string's own third byte (no corresponding <dip> entry — see
// releases/tdragon2.mra's/macross2.mra's own header for the derivation
// of this mechanism, and docs/mra-workflow.md's own Donkey Kong reference
// example for the precedent: a <switches default="..."> byte with no
// <dip> declaration over it stays fixed at that raw value, invisible to
// the OSD, exactly the "pick a game with zero user interaction and no
// stray-toggle risk" property this needs). Loading tdragon2.mra vs
// macross2.mra on this SAME Macross2.rbf therefore deterministically
// boots the matching game with no manual OSD step.
//
// Known, honestly-flagged limitations of this first pass, not yet
// resolved:
//   - HSync/VSync timing below is a reasonable placeholder (this
//     board's real CRT sync timing isn't documented anywhere this
//     project has sourced) — needs tuning against real hardware.
//   - Player input bit mapping (joystick_0/1 -> IN0/IN1) is now
//     cross-checked bit-for-bit against nmk16.cpp's own
//     INPUT_PORTS_START(tdragon2)/(macross2) (see in0_i/in1_i's own
//     comment below — macross2's own IN0/IN1 layout is confirmed a
//     strict subset of tdragon2's, so one shared derivation serves both;
//     macross2's own missing 3rd button bit simply goes unread by that
//     game's own core-side logic) and DSW1/DSW2 are wired to hps_io's
//     real status[] bus (see dsw1_i/dsw2_i's own comment below and each
//     .mra's own <switches>) — neither has been confirmed against real
//     hardware, since no JTAG/SD-card access exists in this
//     environment, only that they compile and the bit/bus math is
//     internally consistent with the source they were derived from.
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
	// Fixed at synthesis time as tdragon2's own superset (3 buttons) —
	// serves macross2 too, whose own .mra just declares fewer <buttons>
	// names (see in0_i/in1_i's own comment below).
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
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
// Player inputs — cross-checked bit-for-bit against
// INPUT_PORTS_START(tdragon2) (nmk16.cpp:2890-2917). Also verified
// against INPUT_PORTS_START(macross2) (nmk16.cpp:2801-2826): IN0 is
// identical, and IN1 is a strict SUBSET (same R/L/D/U/Button1/Button2/
// Start/Coin bit positions, just missing tdragon2's own Button3 — that
// bit is simply IPT_UNKNOWN on macross2's own real board, so leaving it
// wired here is harmless: macross2-mode core logic never reads it
// meaningfully). One shared derivation below therefore serves both
// games with no game_macross2 gating needed at this layer.
//   IN0: bit0=COIN1 bit1=COIN2 bit2=SERVICE1 bit3=START1 bit4=START2
//        bits[7:5]=unused
//   IN1: bit0=P1_RIGHT bit1=P1_LEFT bit2=P1_DOWN bit3=P1_UP
//        bit4=P1_BUTTON1 bit5=P1_BUTTON2 bit6=P1_BUTTON3(tdragon2 only)
//        bit7=unused; bits[14:8]=same 7-bit pattern for P2, bit15=unused
// Both active-low at the core (matches nmk16.cpp's own IPT_* IP_ACTIVE_LOW).
//
// joystick_0/1 bit convention (MiSTer standard): [0]=Right [1]=Left
// [2]=Down [3]=Up, then buttons assigned sequentially starting at [4]
// in the SAME order CONF_STR's own "J1,..." list declares them above
// (Button1=[4], Button2=[5], Button3=[6], Start=[7], Coin=[8] — CONF_STR
// is compiled once for both games as tdragon2's own superset list;
// macross2's own .mra just declares fewer <buttons> names, leaving
// Button3 unmapped in the OSD for that game without changing the
// underlying bit scheme) — this is why in1_i needs no bit reordering at
// all: MAME's own IN1 layout (R,L,D,U,then buttons starting at bit4)
// already matches joystick_0/1[6:0] directly, bit for bit, for both
// games.
// ------------------------------------------------------------------
wire [15:0] in0_i = ~{11'd0, joystick_1[7], joystick_0[7], 1'b0, joystick_1[8], joystick_0[8]};
wire [15:0] in1_i = ~{1'b0, joystick_1[6:0], 1'b0, joystick_0[6:0]};
// DIP switches — the MiSTer .mra loader auto-generates its own "DIP
// Switches" OSD submenu directly from each loaded .mra's own
// <switches>/<dip bits="N" .../> declarations (no CONF_STR "O" entry
// needed for these — that's only for the standard/video-mode options
// above), and writes each dip's configured value straight into
// hps_io's own status[] bus at the exact bit position its own "bits"
// attribute names. Both tdragon2.mra and macross2.mra pack DSW1 at
// status[7:0] and DSW2 at status[15:8] (byte order matches the core's
// own address decode, sel_dsw1 before sel_dsw2 — same for both games,
// see either .mra's own header for the derivation), so this is a
// direct, unmodified read regardless of which game is loaded — no
// inversion needed, since MAME's own dsw bit encoding is already
// exactly what PORT_DIPNAME/PORT_DIPSETTING's raw mask/value pairs
// specify. Upper byte of each 16-bit CPU-bus word is don't-care (DSW1/
// DSW2 are 8-bit hardware switch banks) and idles high, matching in0_i/
// in1_i's own convention for their own unused bits.
wire [15:0] dsw1_i = {8'hFF, status[7:0]};
wire [15:0] dsw2_i = {8'hFF, status[15:8]};

// Runtime game select — see this file's own header. status[16] is a
// HIDDEN bit (no <dip> entry declares it in either .mra), set purely by
// each .mra's own <switches default="..."> third byte on load.
wire game_macross2 = status[16];

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

// VTIMING_FILE: nmk_irq.sv's own V-PROM (tdragon2's own "10.bpr",
// ROM_START(tdragon2), nmk16.cpp:8357-8358) has no HW_ROMS gating at
// all — it's always loaded via $readmemh, baked into the bitstream at
// synthesis time rather than through ioctl_download like every other
// ROM region here, and it is NOT gated by game_macross2 either: this
// exact same PROM content (byte-identical CRC32/SHA1, confirmed
// directly) is macross2's own "mcrs2bpr.10" too — same physical chip,
// same board family — so one shared file genuinely serves both games,
// no per-game selection needed. Without this, vtiming_prom is never
// initialized (stays all-zeros), silently breaking frame-IRQ/
// sprite-DMA-trigger timing on real hardware despite a clean compile —
// this file must exist locally at quartus_map time (generated the same
// way the sim testbenches do: python3 tools/mkgfxrom.py --zip
// mame_roms/tdragon2.zip --mode concat --files 10.bpr --out
// roms/tdragon2_vtiming.hex) since, like every other ROM file in this
// project, its content is copyrighted MAME dump data and is never
// committed (see .gitignore's **/roms/*.hex).
tdragon2_core #(.HW_ROMS(1), .VTIMING_FILE("roms/tdragon2_vtiming.hex")) core
(
	.clk_sys(clk_sys), .reset(reset), .game_macross2(game_macross2),

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
