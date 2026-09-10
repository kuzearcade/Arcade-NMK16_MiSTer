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
// "Original" aspect follows the orientation: 4:3 as the board outputs
// it, 3:4 once the framebuffer rotation turns tdragon2 upright.
assign VIDEO_ARX = (!ar) ? (video_rotated ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Macross2;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	// tdragon2 is a vertical (MAME ROT270) game drawn on its side by the
	// board; the two "Vert" choices both present it upright through the
	// framebuffer, as MAME does — "Vert 270" (the MAME-correct
	// rotate_ccw direction) and "Vert 90" (the opposite quarter-turn)
	// exist because a physical vertical cabinet's monitor can be mounted
	// rotated either way, and only one of the two will match a given
	// cabinet. Off (Horz) by default; hidden (H0) for macross2, which is
	// horizontal, and for direct (analog) video, where the framebuffer
	// path is unavailable. MiSTer keeps status bits across sessions
	// through the OSD's own settings save.
	"H0O[9:8],Orientation,Horz,Vert 270,Vert 90;",
	// "Flip screen" (upside-down, a 180-degree turn with no
	// quarter-rotation): only takes visible effect while Orientation is
	// Horz, since screen_rotate's own flip input is gated by no_rotate
	// (sys/arcade_video.v) — meaningful for macross2 always (which is
	// permanently Horz) and for tdragon2 when its own Orientation is left
	// at Horz. Offered for cabinets whose monitor ended up mounted
	// inverted: a HORIZONTAL monitor for macross2, or a horizontal
	// monitor being used to play tdragon2 un-rotated for either. Hidden
	// (H2) under direct video, same reason as Orientation above.
	"H2O[17],Flip screen,Off,On;",
	// Sync-position trims for CRT/analog users (docs/known-issues.md
	// NMK-2): move the H/V sync pulses within blanking while the active
	// picture (DE) stays put, so the image shifts on a CRT; 0 = the
	// placement shipped before these options existed. Positive = picture
	// right / down (sync earlier). H: ±16 px in 2-px steps, listed in
	// two's-complement order so the 4-bit value 0 is the default. V: only
	// 4 lines of vblank precede the current vsync (active ends at line
	// 239, vsync starts at 244), so the list is 0..+4 then -8..-1.
	"O[21:18],H Shift,0,+2,+4,+6,+8,+10,+12,+14,-16,-14,-12,-10,-8,-6,-4,-2;",
	"O[25:22],V Shift,0,+1,+2,+3,+4,-8,-7,-6,-5,-4,-3,-2,-1;",
	// Autofire on button 1: Off, or a frames-on/frames-off pattern
	// clocked by the game's own vblank (~56 Hz): 10Hz = 3/3, 12Hz = 2/3,
	// 15Hz = 2/2, 20Hz = 1/2, 30Hz = 1/1. While enabled for a player,
	// that player's button 3 is a plain (non-autofire) button 1 — on
	// macross2 too: the game's own input port has no 3rd button, but
	// macross2.mra declares the full 5-entry <buttons> list (see the
	// gamepad Coin note in docs/hw-bringup.md), so a gamepad's Button 3
	// is mapped and reaches this OR path. See the autofire block below.
	"O[12:10],P1 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"O[15:13],P2 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"-;",
	// "DIP;" is where MiSTer inserts the DIP-switch submenu it builds from
	// the loaded .mra's <switches>/<dip> entries (releases/*.mra declare
	// every DSW1/DSW2 option from nmk16.cpp). Changes are sent through
	// ioctl index 254 (dip_sw below) and MiSTer saves them itself to
	// config/dips/<mra>.dip, restored on the next load of that .mra.
	"DIP;",
	"-;",
	"R[0],Reset;",
	// Fixed at synthesis time as tdragon2's own superset (3 buttons) —
	// serves macross2 too, whose own .mra just declares fewer <buttons>
	// names (see in0_i/in1_i's own comment below).
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire        direct_video;
wire        game_macross2; // runtime game select, assigned from the .mra <switches> byte below
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
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	.status_menumask({direct_video, 1'b0, game_macross2 | direct_video}), // [2] hides Flip screen (direct video only), [1] unused, [0] hides Orientation (macross2/direct video)

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr_full),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),

	.ps2_key(ps2_key)
);
wire [24:0] ioctl_addr = ioctl_addr_full[24:0];

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
wire clk_ram;    // 96MHz SDRAM controller clock — see rtl/pll.v's own outclk_1 comment
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_ram),
	.locked(pll_locked)
);

// ~pll_locked was previously NOT part of this gate — only the SDRAM
// controller's own .init(~pll_locked) accounted for PLL lock at all.
// That left every other clk_sys-domain block (the whole core, both
// SDRAM req/arb instances via tdragon2_core.sv's own por_rst, hps_io's
// own clk_sys-domain logic) free to start operating the instant
// `reset` first deasserts, even if clk_sys itself hadn't yet settled to
// a stable 40MHz (a genuine race at FPGA configuration time, before the
// PLL has locked) — a real, if hard-to-observe-without-hardware,
// omission fixed here defensively.
wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked;

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
// ------------------------------------------------------------------
// Keyboard: MAME's default key bindings, always active, ORed with the
// joysticks. hps_io's ps2_key is {toggle, pressed, extended, code}
// (PS/2 scan-code set 2; toggle flips on every event). Keys held are
// tracked in the kb_* registers below; "extended" (E0-prefixed) codes
// are matched with bit 8 set.
//   P1: Up/Down/Left/Right arrows, B1 LCtrl, B2 LAlt, B3 Space, Start 1
//   P2: R/F/D/G, B1 A, B2 S, B3 Q, Start 2
//   Coin 1 = 5, Coin 2 = 6, Service (IPT_SERVICE1) = 9
//   Test / Service Mode = F2: a TOGGLE, as in MAME, flipping DSW1 SW1:8
//   (PORT_SERVICE_DIPLOC, active low) — see dsw1_i below.
// ------------------------------------------------------------------
reg [6:0] kb_p1 = 7'd0, kb_p2 = 7'd0;   // [0]=R [1]=L [2]=D [3]=U [4]=B1 [5]=B2 [6]=B3, joystick bit order
reg kb_start1 = 1'b0, kb_start2 = 1'b0, kb_coin1 = 1'b0, kb_coin2 = 1'b0, kb_service = 1'b0;
reg kb_test_mode = 1'b0;   // toggled by each F2 press
reg kb_f2_held = 1'b0;
reg kb_toggle_d = 1'b0;
always @(posedge clk_sys) begin
	kb_toggle_d <= ps2_key[10];
	if (kb_toggle_d != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h175: kb_p1[3] <= ps2_key[9];   // Up arrow
			9'h172: kb_p1[2] <= ps2_key[9];   // Down arrow
			9'h16B: kb_p1[1] <= ps2_key[9];   // Left arrow
			9'h174: kb_p1[0] <= ps2_key[9];   // Right arrow
			9'h014: kb_p1[4] <= ps2_key[9];   // Left Ctrl  = P1 button 1
			9'h011: kb_p1[5] <= ps2_key[9];   // Left Alt   = P1 button 2
			9'h029: kb_p1[6] <= ps2_key[9];   // Space      = P1 button 3
			9'h02D: kb_p2[3] <= ps2_key[9];   // R = P2 up
			9'h02B: kb_p2[2] <= ps2_key[9];   // F = P2 down
			9'h023: kb_p2[1] <= ps2_key[9];   // D = P2 left
			9'h034: kb_p2[0] <= ps2_key[9];   // G = P2 right
			9'h01C: kb_p2[4] <= ps2_key[9];   // A = P2 button 1
			9'h01B: kb_p2[5] <= ps2_key[9];   // S = P2 button 2
			9'h015: kb_p2[6] <= ps2_key[9];   // Q = P2 button 3
			9'h016: kb_start1  <= ps2_key[9]; // 1
			9'h01E: kb_start2  <= ps2_key[9]; // 2
			9'h02E: kb_coin1   <= ps2_key[9]; // 5
			9'h036: kb_coin2   <= ps2_key[9]; // 6
			9'h046: kb_service <= ps2_key[9]; // 9
			9'h006: begin                     // F2: toggle on press (ignore key repeat while held)
				if (ps2_key[9] && !kb_f2_held) kb_test_mode <= ~kb_test_mode;
				kb_f2_held <= ps2_key[9];
			end
			default: ;
		endcase
	end
end

wire [15:0] in0_i = ~{11'd0, joystick_1[7] | kb_start2, joystick_0[7] | kb_start1, kb_service, joystick_1[8] | kb_coin2, joystick_0[8] | kb_coin1};

// ------------------------------------------------------------------
// Autofire (status[12:10] P1, status[15:13] P2; 0 = off). The pattern
// counter advances once per game frame (vblank_core rising edge) and
// restarts on each new press, so a tap always fires on its first frame.
// Button 1 out = (held & pattern) | button 3; button 3 out = 0 while
// enabled — its ordinary input is not sent to the game in that mode.
// ------------------------------------------------------------------
wire        hblank_core, vblank_core;   // from the core, also used by the video output below
wire [6:0] p1_raw = joystick_0[6:0] | kb_p1;
wire [6:0] p2_raw = joystick_1[6:0] | kb_p2;
reg  vbl_d = 1'b0;
wire frame_tick = vblank_core & ~vbl_d;
always @(posedge clk_sys) vbl_d <= vblank_core;

function automatic [3:0] af_on(input [2:0] m);   // frames on
	case (m) 3'd1: af_on = 4'd3; 3'd2: af_on = 4'd2; 3'd3: af_on = 4'd2; 3'd4: af_on = 4'd1; 3'd5: af_on = 4'd1; default: af_on = 4'd0; endcase
endfunction
function automatic [3:0] af_len(input [2:0] m);  // frames per cycle (on + off)
	case (m) 3'd1: af_len = 4'd6; 3'd2: af_len = 4'd5; 3'd3: af_len = 4'd4; 3'd4: af_len = 4'd3; 3'd5: af_len = 4'd2; default: af_len = 4'd1; endcase
endfunction

reg [3:0] af1_phase = 4'd0, af2_phase = 4'd0;
reg       af1_held_d = 1'b0, af2_held_d = 1'b0;
wire [2:0] af1_mode = status[12:10];
wire [2:0] af2_mode = status[15:13];
always @(posedge clk_sys) begin
	af1_held_d <= p1_raw[4];
	af2_held_d <= p2_raw[4];
	if (p1_raw[4] & ~af1_held_d) af1_phase <= 4'd0;                                   // new press: start of pattern
	else if (frame_tick) af1_phase <= (af1_phase + 4'd1 >= af_len(af1_mode)) ? 4'd0 : af1_phase + 4'd1;
	if (p2_raw[4] & ~af2_held_d) af2_phase <= 4'd0;
	else if (frame_tick) af2_phase <= (af2_phase + 4'd1 >= af_len(af2_mode)) ? 4'd0 : af2_phase + 4'd1;
end
wire af1_en = (af1_mode != 3'd0);
wire af2_en = (af2_mode != 3'd0);
wire p1_b1 = af1_en ? ((p1_raw[4] & (af1_phase < af_on(af1_mode))) | p1_raw[6]) : p1_raw[4];
wire p2_b1 = af2_en ? ((p2_raw[4] & (af2_phase < af_on(af2_mode))) | p2_raw[6]) : p2_raw[4];
wire p1_b3 = af1_en ? 1'b0 : p1_raw[6];
wire p2_b3 = af2_en ? 1'b0 : p2_raw[6];
wire [6:0] p1_btn = {p1_b3, p1_raw[5], p1_b1, p1_raw[3:0]};
wire [6:0] p2_btn = {p2_b3, p2_raw[5], p2_b1, p2_raw[3:0]};

wire [15:0] in1_i = ~{1'b0, p2_btn, 1'b0, p1_btn};
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
// dsw1_i/dsw2_i/game_macross2 are now driven from the .mra <switches>
// block's own ioctl index-254 transfer (see dip_sw below, after the ioctl
// wires are declared) — NOT from status[]: the official MiSTer MRA docs
// state <switches> data is sent via ioctl_index 254 "instead of the
// status bits", so the previous status[15:0]/status[16] wiring never
// actually received it. Same pattern Arcade-Darius_MiSTer and
// Arcade-TMNT_MiSTer use. This is also the transfer that, un-gated,
// used to overwrite the 68000 reset vector in SDRAM — see
// tdragon2_core.sv's own ioctl_index port comment.
wire [15:0] dsw1_i;
wire [15:0] dsw2_i;

// Runtime game select — see this file's own header. status[16] is a
// HIDDEN bit (no <dip> entry declares it in either .mra), set purely by
// each .mra's own <switches default="..."> third byte on load.
// game_macross2 is declared above hps_io (it feeds status_menumask); assigned below from dip_sw[2][0] (| status[16]) — see dsw1_i's comment

// ------------------------------------------------------------------
// SDRAM — single physical rtl/sdram.sv instance, 4 ports, all running
// at clk_sys itself (see docs/hw-bringup.md — no separate SDRAM clock
// domain, no CDC anywhere in this design).
// ------------------------------------------------------------------
wire [24:1] sd0_addr, sd1_addr, sd2_addr, sd3_addr;
wire        sd0_wrl, sd0_wrh, sd2_wrl, sd2_wrh;
wire [15:0] sd0_din, sd2_din;
wire [15:0] sd0_dout, sd1_dout, sd2_dout, sd3_dout;
wire [31:0] sd0_dout_pair, sd1_dout_pair, sd2_dout_pair, sd3_dout_pair;
wire        sd0_req, sd1_req, sd2_req, sd3_req;
wire        sd0_ack, sd1_ack, sd2_ack, sd3_ack;
wire        sdram_ready;

// REFRESH_CYCLES=240 (6us @ 40MHz clk_sys) — see rtl/sdram.sv's own
// parameter comment: its 850-cycle default assumes a ~96MHz+ clk, and
// at this project's own 40MHz clk_sys that default stretches the real
// refresh interval to ~174ms, well past the MT48LC16M16's 64ms JEDEC
// retention spec — confirmed to cause real data corruption on actual
// hardware via SdramTest.sv, a standalone diagnostic core built during
// this session's own real-hardware black-screen investigation.
// The controller runs on the 96MHz clk_ram (see rtl/pll.v's own outclk_1
// comment); every consumer stays on clk_sys and reaches it through
// rtl/sdram_req.sv, which carries the clock crossing together with
// rtl/sdram.sv's own req synchronizers. REFRESH_CYCLES=740 = 7.7us @
// 96MHz, inside the 7.8125us JEDEC row-refresh interval (the earlier 240
// was the same interval at 40MHz).
sdram #(.REFRESH_CYCLES(10'd740)) sdram_inst
(
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
	.init(~pll_locked), .clk(clk_ram), .prio_mode(2'd0),
	.addr0(sd0_addr), .wrl0(sd0_wrl), .wrh0(sd0_wrh), .din0(sd0_din), .dout0(sd0_dout), .dout0_pair(sd0_dout_pair), .req0(sd0_req), .ack0(sd0_ack),
	.addr1(sd1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(sd1_dout), .dout1_pair(sd1_dout_pair), .req1(sd1_req), .ack1(sd1_ack),
	.addr2(sd2_addr), .wrl2(sd2_wrl), .wrh2(sd2_wrh), .din2(sd2_din), .dout2(sd2_dout), .dout2_pair(sd2_dout_pair), .req2(sd2_req), .ack2(sd2_ack),
	.addr3(sd3_addr), .wrl3(1'b0), .wrh3(1'b0), .din3('0), .dout3(sd3_dout), .dout3_pair(sd3_dout_pair), .req3(sd3_req), .ack3(sd3_ack)
);

// ------------------------------------------------------------------
// Core
// ------------------------------------------------------------------
wire [23:0] rd_rgb;
wire [8:0]  rd_x_screen;
wire [7:0]  rd_y_screen;
wire [15:0] rom_csum;
wire [15:0] rom_csum_count;
wire        rom_csum_done;
wire [15:0] rom_fetch_csum;
wire [15:0] rom_fetch_csum_count;
wire        rom_fetch_csum_done;
wire [15:0] ioctl_csum;
wire [19:0] ioctl_csum_count;
wire        ioctl_csum_done;
wire [0:127] ioctl_bucket_fail;
wire [0:127] rom_fetch_bucket_touched;
wire [0:127] rom_fetch_bucket_sim_touched;
wire [0:127] rom_fetch_bucket_fail;
wire [0:127] rom_fetch_fine_touched;
wire [0:127] rom_fetch_fine_sim_touched;
wire [0:127] rom_fetch_fine_fail;
wire [0:15] rom_fetch_word_touched;
wire [0:15] rom_fetch_word_sim_touched;
wire [0:15] rom_fetch_word_fail;
wire [15:0] rom_word0_raw, rom_word1_raw, rom_word2_raw, rom_word3_raw;
wire        rom_word0_was_write, rom_word1_was_write, rom_word2_was_write, rom_word3_was_write;
wire        rom_word0_addr_ok, rom_word1_addr_ok, rom_word2_addr_ok, rom_word3_addr_ok;
wire [23:0] ioctl_wr_max_gap;
wire [23:0] ioctl_wr_over_refresh_count;
wire [15:0] ioctl_index;
wire [7:0]  ioctl_session_count;
wire [15:0] ioctl_last_index;
wire [15:0] ioctl_nonrom_word0;

// .mra <switches> capture — the canonical MiSTer MRA-doc snippet: up to
// 8 raw bytes arrive on ioctl index 254, byte 0 = DIP bits 7:0, byte 1 =
// bits 15:8, etc. Defaults to all-ones (every switch "off"/idle-high,
// matching in0_i/in1_i's own unused-bit convention) until the loader
// sends the block. Byte layout follows releases/*.mra's own
// <switches default="F7,FF,0x">: byte0/byte1 = DSW1/DSW2 low bytes,
// byte2 bit0 = the hidden game-select bit (00=tdragon2, 01=macross2).
reg [7:0] dip_sw [0:7];
integer dip_i;
initial for (dip_i = 0; dip_i < 8; dip_i = dip_i + 1) dip_sw[dip_i] = 8'hFF;
always @(posedge clk_sys) begin
	if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
// DSW1 bit 0 is SW1:8 "Service Mode" (active low). F2 toggles it like
// MAME's Service Mode key, on top of whatever the OSD DIP setting is.
assign dsw1_i = {8'hFF, dip_sw[0] ^ {7'd0, kb_test_mode}};
assign dsw2_i = {8'hFF, dip_sw[1]};
// OR'd with status[16] so game select still works if a MiSTer build ever
// does mirror <switches> into status[] as well; either path alone selects
// macross2 only for macross2.mra (tdragon2.mra's byte 2 is 00).
assign game_macross2 = dip_sw[2][0] | status[16];
wire        ce_pix_core;
wire [9:0]  hcount_core, vcount_core;
// hblank_core/vblank_core are declared above the autofire block (frame tick).
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
// IOCTL_BUCKET_REF_FILE: NOT copyrighted ROM dump data (a small table of
// checksums derived from it), safe to commit directly — see
// tdragon2_core.sv's own IOCTL_BUCKET_REF_FILE parameter comment.
tdragon2_core #(.HW_ROMS(1), .VTIMING_FILE("roms/tdragon2_vtiming.hex"),
	.IOCTL_BUCKET_REF_FILE("rtl/tdragon2/tdragon2_ioctl_bucket_ref.hex"),
	.ROM_FETCH_BUCKET_REF_FILE("rtl/tdragon2/tdragon2_fetch_bucket_ref.hex"),
	.ROM_FETCH_BUCKET_TOUCHED_FILE("rtl/tdragon2/tdragon2_fetch_bucket_touched.hex"),
	.ROM_FETCH_FINE_REF_FILE("rtl/tdragon2/tdragon2_fetch_fine_ref.hex"),
	.ROM_FETCH_FINE_TOUCHED_FILE("rtl/tdragon2/tdragon2_fetch_fine_touched.hex"),
	.ROM_FETCH_WORD_REF_FILE("rtl/tdragon2/tdragon2_fetch_word_ref.hex"),
	.ROM_FETCH_WORD_TOUCHED_FILE("rtl/tdragon2/tdragon2_fetch_word_touched.hex")) core
(
	.clk_sys(clk_sys), .reset(reset), .game_macross2(game_macross2),
	.extra_por_hold(~pll_locked),

	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),

	.sd0_addr(sd0_addr), .sd0_wrl(sd0_wrl), .sd0_wrh(sd0_wrh), .sd0_din(sd0_din), .sd0_dout(sd0_dout), .sd0_dout_pair(sd0_dout_pair), .sd0_req(sd0_req), .sd0_ack(sd0_ack),
	.sd1_addr(sd1_addr), .sd1_req(sd1_req), .sd1_dout(sd1_dout), .sd1_dout_pair(sd1_dout_pair), .sd1_ack(sd1_ack),
	.sd2_addr(sd2_addr), .sd2_wrl(sd2_wrl), .sd2_wrh(sd2_wrh), .sd2_din(sd2_din), .sd2_dout(sd2_dout), .sd2_dout_pair(sd2_dout_pair), .sd2_req(sd2_req), .sd2_ack(sd2_ack),
	.sd3_addr(sd3_addr), .sd3_req(sd3_req), .sd3_dout(sd3_dout), .sd3_dout_pair(sd3_dout_pair), .sd3_ack(sd3_ack),

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

	// Real inputs restored (they were temporarily forced to 16'hFFFF
	// during the real-hardware black-screen investigation so rom_csum
	// could be compared apples-to-apples against the fixed-input sim
	// reference — that comparison now matches, 0x44D8 on both, with the
	// ioctl_index ROM-write gate in place; see docs/hw-bringup.md).
	.in0_i(in0_i), .in1_i(in1_i), .dsw1_i(dsw1_i), .dsw2_i(dsw2_i),

	.rom_csum_o(rom_csum), .rom_csum_count_o(rom_csum_count), .rom_csum_done_o(rom_csum_done),
	.rom_fetch_csum_o(rom_fetch_csum), .rom_fetch_csum_count_o(rom_fetch_csum_count), .rom_fetch_csum_done_o(rom_fetch_csum_done),
	.ioctl_csum_o(ioctl_csum), .ioctl_csum_count_o(ioctl_csum_count), .ioctl_csum_done_o(ioctl_csum_done),
	.ioctl_bucket_fail_o(ioctl_bucket_fail),
	.dbg_bucket_sel_i(7'd0), .dbg_bucket_state_o(), .dbg_bucket_touched_o(),
	.rom_fetch_bucket_touched_o(rom_fetch_bucket_touched),
	.rom_fetch_bucket_sim_touched_o(rom_fetch_bucket_sim_touched), .rom_fetch_bucket_fail_o(rom_fetch_bucket_fail),
	.dbg_fine_state_o(), .dbg_fine_touched_o(),
	.rom_fetch_fine_touched_o(rom_fetch_fine_touched),
	.rom_fetch_fine_sim_touched_o(rom_fetch_fine_sim_touched), .rom_fetch_fine_fail_o(rom_fetch_fine_fail),
	.dbg_word_state_o(), .dbg_word_touched_o(),
	.rom_fetch_word_touched_o(rom_fetch_word_touched),
	.rom_fetch_word_sim_touched_o(rom_fetch_word_sim_touched), .rom_fetch_word_fail_o(rom_fetch_word_fail),
	.rom_word0_raw_o(rom_word0_raw), .rom_word1_raw_o(rom_word1_raw),
	.rom_word2_raw_o(rom_word2_raw), .rom_word3_raw_o(rom_word3_raw),
	.rom_word0_was_write_o(rom_word0_was_write), .rom_word1_was_write_o(rom_word1_was_write),
	.rom_word2_was_write_o(rom_word2_was_write), .rom_word3_was_write_o(rom_word3_was_write),
	.rom_word0_race_addr_o(), .rom_word1_race_addr_o(), .rom_word2_race_addr_o(), .rom_word3_race_addr_o(),
	.rom_word0_addr_ok_o(rom_word0_addr_ok), .rom_word1_addr_ok_o(rom_word1_addr_ok),
	.rom_word2_addr_ok_o(rom_word2_addr_ok), .rom_word3_addr_ok_o(rom_word3_addr_ok),
	.ioctl_wr_max_gap_o(ioctl_wr_max_gap), .ioctl_wr_over_refresh_count_o(ioctl_wr_over_refresh_count),
	.ioctl_session_count_o(ioctl_session_count), .ioctl_last_index_o(ioctl_last_index),
	.ioctl_nonrom_word0_o(ioctl_nonrom_word0)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

// ------------------------------------------------------------------
// Video sync — see this file's own header: placeholder timing, not
// yet tuned against real hardware. HSync/VSync pulses placed within
// the existing hblank/vblank windows video_timing.sv already defines
// (HTOTAL=512/HACTIVE 28-412, VTOTAL=278/VACTIVE 16-240).
// ------------------------------------------------------------------
// H/V Shift (status[21:18], [25:22] — see CONF_STR): the sync pulses
// move, the DE window does not. Positive = picture right/down = sync
// earlier, so the start is 440/244 MINUS the shift. Ranges keep both
// pulses inside blanking (hblank 412..511, vblank 240..277 of the
// 512x278 raster): hsync start 426..456 (+32), vsync start 240..252 (+3).
wire  [3:0] hshift_sel = status[21:18];
wire  [9:0] hshift_px  = {{5{hshift_sel[3]}}, hshift_sel, 1'b0};   // two's complement x2: -16..+14
reg   [9:0] vshift_ln;                                              // 0..+4, then -8..-1
always @* case (status[25:22])
	4'd1: vshift_ln = 10'd1;   4'd2: vshift_ln = 10'd2;   4'd3: vshift_ln = 10'd3;   4'd4: vshift_ln = 10'd4;
	4'd5: vshift_ln = -10'd8;  4'd6: vshift_ln = -10'd7;  4'd7: vshift_ln = -10'd6;  4'd8: vshift_ln = -10'd5;
	4'd9: vshift_ln = -10'd4;  4'd10: vshift_ln = -10'd3; 4'd11: vshift_ln = -10'd2; 4'd12: vshift_ln = -10'd1;
	default: vshift_ln = 10'd0;
endcase
wire [9:0] hs_start = 10'd440 - hshift_px;
wire [9:0] vs_start = 10'd244 - vshift_ln;
wire hsync = (hcount_core >= hs_start) && (hcount_core < hs_start + 10'd32);
wire vsync = (vcount_core >= vs_start) && (vcount_core < vs_start + 10'd3);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix_core;

assign VGA_DE = ~(hblank_core | vblank_core);
assign VGA_HS = hsync;
assign VGA_VS = vsync;
// ------------------------------------------------------------------
// DIAGNOSTIC ONLY: a wide overlay (256 of the screen's 384 columns)
// across the bottom 16 rows of the active picture, showing
// tdragon2_core.sv's own rom_csum as a 16-bit black/white barcode
// (16px per bit — a clean power-of-2 bit width, avoiding a non-power-
// of-2 divider in this combinational per-pixel path — MSB leftmost)
// once rom_csum_done, solid BLUE while still accumulating — see that
// module's own rom_csum comment for the full derivation/purpose. A
// first attempt at this used a small 64x8-pixel corner box (4px/bit) —
// too fine to decode reliably through the real analog-capture chain
// this project's own direct-video testing setup uses (several bits
// landed ambiguously between black/white when sampled from a real
// screenshot, confirmed directly); this wider version trades screen
// area for a 4x per-bit margin. Added during this project's own real-
// hardware black-screen investigation; remove this block (and the
// rom_csum_o/_count_o/_done_o wiring above) once no longer needed.
// ------------------------------------------------------------------
wire       dbg_ov_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd208);
wire [3:0] dbg_ov_col    = rd_x_screen[7:4];           // 0..15, 16px/bit (x already <256, fits in 8 bits)
wire [3:0] dbg_ov_bit    = 4'd15 - dbg_ov_col;         // MSB leftmost
wire [23:0] dbg_ov_rgb   = !rom_csum_done ? 24'h0000FF : (rom_csum[dbg_ov_bit] ? 24'hFFFFFF : 24'h000000);

// DIAGNOSTIC ONLY: a second barcode strip, same 16px/bit encoding as
// dbg_ov_rgb above, directly above it (rows 192-207 vs. 208-223),
// showing tdragon2_core.sv's own rom_fetch_csum_o — a checksum tapped
// one stage upstream of rom_csum_o, at rom_cache1's own SDRAM-fetch-
// completion event rather than the CPU/DTACKn bus cycle — see that
// port's own comment in tdragon2_core.sv for the full rationale. A
// GREEN (not blue) idle color distinguishes "still accumulating" here
// from the strip below, since both can be mid-accumulation at once and
// need to stay visually distinct at a glance.
wire       dbg_ov2_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd192) && (rd_y_screen < 8'd208);
wire [3:0] dbg_ov2_col    = rd_x_screen[7:4];
wire [3:0] dbg_ov2_bit    = 4'd15 - dbg_ov2_col;
wire [23:0] dbg_ov2_rgb   = !rom_fetch_csum_done ? 24'h00FF00 : (rom_fetch_csum[dbg_ov2_bit] ? 24'hFFFFFF : 24'h000000);

// DIAGNOSTIC ONLY: a THIRD barcode strip, same 16px/bit encoding,
// directly above the other two (rows 176-191) — tdragon2_core.sv's own
// ioctl_csum_o, the raw ioctl_download WRITE-side byte checksum over
// the maincpu ROM region (see that port's own comment for the full
// rationale). A RED idle color (distinct from the BLUE/GREEN of the
// two strips below) so all three stay visually distinguishable at a
// glance while independently accumulating.
wire       dbg_ov3_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd176) && (rd_y_screen < 8'd192);
wire [3:0] dbg_ov3_col    = rd_x_screen[7:4];
wire [3:0] dbg_ov3_bit    = 4'd15 - dbg_ov3_col;
wire [23:0] dbg_ov3_rgb   = !ioctl_csum_done ? 24'hFF0000 : (ioctl_csum[dbg_ov3_bit] ? 24'hFFFFFF : 24'h000000);

// DIAGNOSTIC ONLY: a FOURTH strip, full screen width (rows 160-175),
// directly above the other three — tdragon2_core.sv's own
// ioctl_bucket_fail_o, one bit per 4096-byte bucket of the maincpu ROM
// ioctl_download write stream, RED if that bucket's own live checksum
// didn't match its known-good reference value, GREEN if it did — same
// 128-bucket/3px-per-bucket layout as this project's own SdramTest.sv
// Phase 1 display (128*3=384=full screen width), chosen so a mismatch
// can be spatially localized directly from a screenshot instead of only
// knowing (via ioctl_csum_o's own aggregate value) THAT something
// differs. See ioctl_bucket_fail_o's own comment in tdragon2_core.sv.
wire       dbg_ov4_active = (rd_y_screen >= 8'd160) && (rd_y_screen < 8'd176);
wire [6:0] dbg_ov4_bucket = rd_x_screen / 9'd3;
wire [23:0] dbg_ov4_rgb   = !ioctl_csum_done ? 24'h0000FF : (ioctl_bucket_fail[dbg_ov4_bucket] ? 24'hFF0000 : 24'h00FF00);

// DIAGNOSTIC ONLY: a FIFTH strip, full screen width (rows 144-159),
// directly above the other four — a spatial/address-bucketed companion
// to rom_fetch_csum_o (rows 192-207, strip #2), same 128-bucket/3px
// layout as strip #4 just below. Unlike ioctl_bucket_fail_o's write-side
// bucketing (monotonic, full-coverage, so simple GREEN/RED suffices),
// this needs FOUR states since coverage here is inherently partial and
// real-hardware-timing-dependent — see rom_fetch_bucket_fail_o's own
// comment in tdragon2_core.sv:
//   BLACK = the reference (sim) run itself never touched this bucket —
//           uninformative, not evidence either way.
//   GREY  = the reference run touched it but real hardware hasn't (at
//           the moment this frame was captured) — a coverage gap, not
//           itself proof of a data problem.
//   GREEN = both touched it, and real hardware's own live checksum
//           matches the reference exactly.
//   RED   = both touched it, and they differ — the real, localized
//           evidence this whole diagnostic exists to find.
wire       dbg_ov5_active = (rd_y_screen >= 8'd144) && (rd_y_screen < 8'd160);
wire [6:0] dbg_ov5_bucket = rd_x_screen / 9'd3;
wire [23:0] dbg_ov5_rgb   =
	!rom_fetch_bucket_sim_touched[dbg_ov5_bucket] ? 24'h000000 :
	!rom_fetch_bucket_touched[dbg_ov5_bucket]     ? 24'h808080 :
	rom_fetch_bucket_fail[dbg_ov5_bucket]         ? 24'hFF0000 : 24'h00FF00;

// DIAGNOSTIC ONLY: a SIXTH strip, full screen width (rows 128-143),
// directly above strip #5 — a further zoomed-in companion covering ONLY
// word addresses [0,2048) (strip #5's own bucket 0, which real hardware
// showed a genuine mismatch on) at 16 words/bucket instead of 2048 —
// 128x finer, to localize whether the CPU's own reset vector (bucket 0
// here = word addresses 0-15 = byte 0x000-0x01F, which includes the
// initial SP at byte 0-3 and initial PC at byte 4-7) is itself
// corrupted, or only later boot code within that same 4KB range. Same
// 4-color BLACK/GREY/GREEN/RED convention as strip #5 — see
// rom_fetch_fine_fail_o's own comment in tdragon2_core.sv.
wire       dbg_ov6_active = (rd_y_screen >= 8'd128) && (rd_y_screen < 8'd144);
wire [6:0] dbg_ov6_bucket = rd_x_screen / 9'd3;
wire [23:0] dbg_ov6_rgb   =
	!rom_fetch_fine_sim_touched[dbg_ov6_bucket] ? 24'h000000 :
	!rom_fetch_fine_touched[dbg_ov6_bucket]     ? 24'h808080 :
	rom_fetch_fine_fail[dbg_ov6_bucket]         ? 24'hFF0000 : 24'h00FF00;

// DIAGNOSTIC ONLY: a SEVENTH strip, full screen width (rows 112-127),
// directly above strip #6 — TRUE per-word granularity over word
// addresses [0,16) (strip #6's own fine bucket 0, the only one that
// showed any real traffic) — 16 buckets at 24px each (384/16=24,
// exactly), one per individual word, to pinpoint EXACTLY which word(s)
// in this 32-byte span (including the CPU's own reset vector at words
// 0-3) are wrong on real hardware. Same 4-color convention as strips #5
// and #6 — see rom_fetch_word_fail_o's own comment in tdragon2_core.sv.
wire       dbg_ov7_active = (rd_y_screen >= 8'd112) && (rd_y_screen < 8'd128);
wire [3:0] dbg_ov7_bucket = rd_x_screen / 9'd24;
wire [23:0] dbg_ov7_rgb   =
	!rom_fetch_word_sim_touched[dbg_ov7_bucket] ? 24'h000000 :
	!rom_fetch_word_touched[dbg_ov7_bucket]     ? 24'h808080 :
	rom_fetch_word_fail[dbg_ov7_bucket]         ? 24'hFF0000 : 24'h00FF00;

// DIAGNOSTIC ONLY: four RAW-VALUE barcode strips (16px/bit, same
// encoding as dbg_ov_rgb/strip #1's own rom_csum barcode — MSB
// leftmost), rows 32-95 (well clear of the OSD info box that occupies
// roughly the first ~22 native rows of a direct-video capture),
// displaying tdragon2_core.sv's own rom_word0..3_raw_o directly — the
// ACTUAL values real hardware's reset-vector-region fetch returns for
// word addresses 0-3 (word0/1=initial SP, word2/3=initial PC), not just
// pass/fail. See rom_word0_raw_o's own comment in tdragon2_core.sv for
// why: 3 of these 4 words were already found to mismatch a known-good
// reference (rows 112-127's own strip #7), and the actual wrong value
// may reveal a recognizable pattern (stale ioctl_download data, a
// shifted/aliased address, all-0s/all-1s) pointing at the specific
// mechanism at fault. BLUE while !touched (mirrors dbg_ov_rgb's own
// idle convention), though by the time rom_fetch_csum_done_o latches
// (gating all these accumulators, see rom_fetch_word_fail_o's own
// comment) these 4 specific words are already known to be touched.
wire       dbg_ov8_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd32) && (rd_y_screen < 8'd48);
wire [3:0] dbg_ov8_bit    = 4'd15 - rd_x_screen[7:4];
wire [23:0] dbg_ov8_rgb   = !rom_fetch_word_touched[0] ? 24'h0000FF : (rom_word0_raw[dbg_ov8_bit] ? 24'hFFFFFF : 24'h000000);

wire       dbg_ov9_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd48) && (rd_y_screen < 8'd64);
wire [3:0] dbg_ov9_bit    = 4'd15 - rd_x_screen[7:4];
wire [23:0] dbg_ov9_rgb   = !rom_fetch_word_touched[1] ? 24'h0000FF : (rom_word1_raw[dbg_ov9_bit] ? 24'hFFFFFF : 24'h000000);

wire       dbg_ov10_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd64) && (rd_y_screen < 8'd80);
wire [3:0] dbg_ov10_bit    = 4'd15 - rd_x_screen[7:4];
wire [23:0] dbg_ov10_rgb   = !rom_fetch_word_touched[2] ? 24'h0000FF : (rom_word2_raw[dbg_ov10_bit] ? 24'hFFFFFF : 24'h000000);

wire       dbg_ov11_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd80) && (rd_y_screen < 8'd96);
wire [3:0] dbg_ov11_bit    = 4'd15 - rd_x_screen[7:4];
wire [23:0] dbg_ov11_rgb   = !rom_fetch_word_touched[3] ? 24'h0000FF : (rom_word3_raw[dbg_ov11_bit] ? 24'hFFFFFF : 24'h000000);

// DIAGNOSTIC ONLY: a race-detector summary strip, rows 96-111 (directly
// below the 4 raw-value strips, still clear of the main 7-strip block
// at rows 112-223), 4 segments of 64px each (256/4=64) — one per
// reset-vector word — RED if that word's own cache_valid pulse actually
// belonged to a WRITE (sd0_dbg_we captured at that exact cycle), GREEN
// if it was a genuine read. Tests the specific race hypothesis this
// project's own real-hardware bring-up work raised after finding words
// 0/1/3 read back mostly-zero — see rom_word0_was_write_o's own comment
// in tdragon2_core.sv.
// 3-color: RED = the completing transaction was actually a WRITE (the
// race hypothesis); ORANGE = it was a genuine read, but of the WRONG
// address (a different bug — see rom_word0_addr_ok_o's own comment);
// GREEN = genuine read of the correct address (i.e. this specific
// mechanism is clean — the wrong DATA must come from somewhere else,
// e.g. real SDRAM read timing itself).
wire       dbg_ov12_active = (rd_x_screen < 9'd256) && (rd_y_screen >= 8'd96) && (rd_y_screen < 8'd112);
wire [1:0] dbg_ov12_seg    = rd_x_screen[7:6];
wire       dbg_ov12_was_write = (dbg_ov12_seg==2'd0) ? rom_word0_was_write :
                                 (dbg_ov12_seg==2'd1) ? rom_word1_was_write :
                                 (dbg_ov12_seg==2'd2) ? rom_word2_was_write : rom_word3_was_write;
wire       dbg_ov12_addr_ok   = (dbg_ov12_seg==2'd0) ? rom_word0_addr_ok :
                                 (dbg_ov12_seg==2'd1) ? rom_word1_addr_ok :
                                 (dbg_ov12_seg==2'd2) ? rom_word2_addr_ok : rom_word3_addr_ok;
wire [23:0] dbg_ov12_rgb   = dbg_ov12_was_write ? 24'hFF0000 : !dbg_ov12_addr_ok ? 24'hFF8000 : 24'h00FF00;

// DIAGNOSTIC ONLY: two full-width, 16px/bit barcode strips (rows 0-15
// and 16-31 — the only rows this whole diagnostic overlay hadn't
// already claimed), showing tdragon2_core.sv's own real ioctl_wr
// pulse-timing instrumentation directly — see ioctl_wr_max_gap_o's own
// comment there for the full rationale (testing real hps_io/ARM-side
// download pacing after two synthetic, purely-in-FPGA repros both
// passed cleanly). 24 bits each, MSB leftmost, matching the barcode
// convention used throughout this overlay. May be partially obscured
// on a capture taken while the MiSTer scaler's own OSD info box is
// still showing (top-left corner, fades after a few seconds) — the
// lower/right-hand bits stay readable regardless.
// Rows 0-15/16-31 repurposed (the ioctl_wr gap-timing readouts they
// previously showed were decoded and recorded — see docs/hw-bringup.md)
// to prove the multi-session ioctl clobber directly — see
// tdragon2_core.sv's own ioctl_index port comment:
//   strip 13: {ioctl_session_count[7:0], ioctl_last_index[15:0]}
//   strip 14: {8'd0, ioctl_nonrom_word0[15:0]} — what a non-ROM session
//             wrote at SDRAM word 0 (compare against the real reset
//             vector's own first word, 0x001F, and the clobbered value
//             0x0180 read back before the fix).
wire [23:0] dbg_ov13_val   = {ioctl_session_count, ioctl_last_index};
wire       dbg_ov13_active = (rd_y_screen < 8'd16);
wire [4:0] dbg_ov13_col    = rd_x_screen[8:4];          // 0..23, 16px/bit over the full 384px width
wire [4:0] dbg_ov13_bit    = 5'd23 - dbg_ov13_col;
wire [23:0] dbg_ov13_rgb   = dbg_ov13_val[dbg_ov13_bit] ? 24'hFFFFFF : 24'h000000;

wire [23:0] dbg_ov14_val   = {8'd0, ioctl_nonrom_word0};
wire       dbg_ov14_active = (rd_y_screen >= 8'd16) && (rd_y_screen < 8'd32);
wire [4:0] dbg_ov14_col    = rd_x_screen[8:4];
wire [4:0] dbg_ov14_bit    = 5'd23 - dbg_ov14_col;
wire [23:0] dbg_ov14_rgb   = dbg_ov14_val[dbg_ov14_bit] ? 24'hFFFFFF : 24'h000000;

// Diagnostic overlays disconnected from the picture now that the
// black-screen root cause is fixed (the dbg_ov* wires above and the
// core's own diagnostic ports are left in place, unread — Quartus
// optimizes them away; re-attach the ternary chain here to bring the
// overlays back if a future real-hardware investigation needs them).
// The bare-final_rgb chain is preserved in git history / docs/hw-bringup.md.
wire [23:0] final_rgb    = rd_rgb;

assign VGA_R  = final_rgb[23:16];
assign VGA_G  = final_rgb[15:8];
assign VGA_B  = final_rgb[7:0];

// ------------------------------------------------------------------
// Orientation (status[9:8], "Vert 270"/"Vert 90", tdragon2 only) and
// Flip screen (status[17], both games): the framework's screen_rotate
// (sys/arcade_video.v) copies the finished frame into a DDR3
// framebuffer and hands it to the scaler (FB_EN). With neither option
// in effect, no_rotate holds FB_EN low, nothing is written to DDRAM and
// the scaler takes the direct VGA_* path exactly as before — the
// core's own video pipeline above is untouched either way. tdragon2 is
// ROT270 in MAME, i.e. the board's image has to be turned
// counter-clockwise to stand upright, which is screen_rotate's
// rotate_ccw=1 case ("Vert 270"); "Vert 90" is rotate_ccw=0, the
// opposite quarter-turn, for cabinets whose vertical monitor is mounted
// the other way around. "Flip screen" only takes visible effect while
// no_rotate is asserted internally to screen_rotate, giving a
// 180-degree upside-down image with no quarter-turn: meaningful for
// macross2 always (permanently Horz) and for tdragon2 whenever its own
// Orientation is left at Horz — offered for cabinets whose monitor
// ended up mounted inverted.
// ------------------------------------------------------------------
wire  [1:0] orientation = status[9:8];
wire        flip_screen = status[17];
wire        video_rotated;
wire        no_rotate = (orientation == 2'd0) | game_macross2 | direct_video;
wire        rotate_ccw = orientation != 2'd2;
wire        flip = flip_screen & ~direct_video;
screen_rotate screen_rotate (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(flip), .video_rotated(video_rotated),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD)
);
assign FB_FORCE_BLANK = 1'b0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
