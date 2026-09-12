// NMK16 MiSTerFPGA project — real hardware top-level for the "Gunnail"
// RBF: GunNail (gunnail, gunnailp — nmk16.cpp gunnail_prot()) and, since
// 2026-09-11, the nine lowres NMK004 boards (macross, blkheart, mustang,
// bioship, vandyke, acrobatm, strahl, tdragon/tdragon1, hachamf) as
// runtime game modes of rtl/gunnail/gunnail_core.sv (game_sel, from the
// .mra <switches> third byte). Cloned from Raphero.sv: the same
// framework wiring (hps_io, SDRAM, MAME-style keyboard, P1/P2 autofire,
// framebuffer rotation, .mra DIP capture) plus Macross2.sv's video
// output retimer (here at 48 MHz: 8 MHz pixels for gunnail's 512-px
// line, 6 MHz for the lowres boards' 384-px line). See docs/hw-bringup.md.
//
// gunnail, macross, vandyke, acrobatm and tdragon are ROT270 (drawn on
// their side by the board): the Orientation option turns them upright
// over HDMI; it is hidden for the horizontal games. Every IN1 layout in
// this set is the same (joystick, button 1, button 2; acrobatm also
// reads button 3, "used by secret code"), so the CONF_STR button list is
// "Button 1,Button 2,Button 3,Start,Coin" and Start/Coin sit at joystick
// bits 7/8. Every Gunnail .mra carries that five-entry <buttons> list
// (MiSTer's gamepad mapping is positional against it).
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
// it, 3:4 once the framebuffer rotation turns the game upright.
assign VIDEO_ARX = (!ar) ? (video_rotated ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Gunnail;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	// A vertical (MAME ROT270) game drawn on its side by the board; the
	// two "Vert" choices both present it upright through the framebuffer,
	// as MAME does — "Vert 270" (the MAME-correct rotate_ccw direction)
	// and "Vert 90" (the opposite quarter-turn) exist because a physical
	// vertical cabinet's monitor can be mounted rotated either way, and
	// only one of the two will match a given cabinet. Off (Horz) by
	// default; hidden (H0) for direct (analog) video, where the
	// framebuffer path is unavailable. MiSTer keeps status bits across
	// sessions through the OSD's own settings save.
	"H0O[9:8],Orientation,Horz,Vert 270,Vert 90;",
	// Flip screen (180-degree upside-down, no quarter-turn): only takes
	// visible effect while Orientation is Horz, since screen_rotate's own
	// flip input is gated by no_rotate (sys/arcade_video.v). For a
	// cabinet with a HORIZONTAL monitor mounted upside-down, playing this
	// vertical game un-rotated (Horz) the way the board naturally outputs
	// it. Hidden (H0, same tag/mask as Orientation) under direct video.
	"H0O[17],Flip screen,Off,On;",
	// Sync-position trims for CRT/analog users (docs/known-issues.md
	// NMK-2): move the H/V sync pulses within blanking while the active
	// picture (DE) stays put, so the image shifts on a CRT. Positive =
	// picture right / down (sync earlier). H: ±16 px in 2-px steps,
	// listed in two's-complement order so the 4-bit value 0 is the
	// default = the original placement (hsync at 440). V: ±20 lines,
	// listed 0..+20 then -20..-1 so the 6-bit value 0 is the default;
	// the vsync is nominally re-centred in the 54-line vblank (start at
	// row 264 instead of the original 244, which had only 4 blank lines
	// before it and could not take a ±20 range) — "+20" therefore
	// reproduces the pre-2026-09-10 placement exactly.
	"O[21:18],H Shift,0,+2,+4,+6,+8,+10,+12,+14,-16,-14,-12,-10,-8,-6,-4,-2;",
	"O[27:22],V Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// Autofire on button 1: Off, or a frames-on/frames-off pattern
	// clocked by the game's own vblank (~56 Hz): 10Hz = 3/3, 12Hz = 2/3,
	// 15Hz = 2/2, 20Hz = 1/2, 30Hz = 1/1 (this game has no third button
	// to double as a plain fire).
	"O[12:10],P1 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"O[15:13],P2 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"-;",
	// "DIP;" is where MiSTer inserts the DIP-switch submenu it builds from
	// the loaded .mra's <switches>/<dip> entries. Changes arrive through
	// ioctl index 254 (dip_sw below) and MiSTer saves them itself to
	// config/dips/<mra>.dip, restored on the next load of that .mra.
	"DIP;",
	"-;",
	"R[0],Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire        direct_video;
wire  [1:0] buttons;
wire  [5:0] game_sel;      // runtime game select, from the .mra <switches> third byte (below)
wire        lowres;        // from the core: the 256-px lowres window (every game but gunnail)
// The vertical (ROT270) games: gunnail, macross, vandyke, acrobatm,
// tdragon/tdragon1, the Bombjack Twin sets (14-16), tharrier, vandykeb.
// The others are ROT0 and never rotated.
wire        game_vertical = (game_sel == 6'd0) | (game_sel == 6'd1) | (game_sel == 6'd5) | (game_sel == 6'd6) | (game_sel == 6'd8) | (game_sel == 6'd10) |
                            (game_sel == 6'd14) | (game_sel == 6'd15) | (game_sel == 6'd16) | (game_sel == 6'd20) | (game_sel == 6'd21) |
                            // Afega ROT270 sets: stagger1/redhawk(e/k/c), grdnstrmk/v/j/g, redfoxwp2/a, spec2k
                            (game_sel == 6'd23) | (game_sel == 6'd24) | (game_sel == 6'd31) | (game_sel == 6'd32) | (game_sel == 6'd33) |
                            (game_sel == 6'd35) | (game_sel == 6'd36) | (game_sel == 6'd41);
// MAME ORIENTATION_FLIP_Y sets (grdnstrm, grdnstrmau, firehawk, spec2kh): the
// board draws upside down for a monitor mounted that way; the picture is
// read out bottom-up (rd_y mirrored) so it displays upright, as MAME does.
wire        game_flip_y = (game_sel == 6'd30) | (game_sel == 6'd34) | (game_sel == 6'd40) | (game_sel == 6'd42);
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr_full;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire [15:0] ioctl_index;

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
	.status_menumask({1'b0, direct_video | ~game_vertical}), // [0] hides Orientation and Flip screen (both H0) for direct video and the horizontal games

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

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked;

// ------------------------------------------------------------------
// Player inputs — INPUT_PORTS_START(gunnail):
//   IN0: bit0=COIN1 bit1=COIN2 bit2=SERVICE1 bit3=START1 bit4=START2
//   IN1: bit0=P1_RIGHT bit1=P1_LEFT bit2=P1_DOWN bit3=P1_UP
//        bit4=P1_BUTTON1 bit5=P1_BUTTON2 bit6=unused, bits[14:8] P2
// Both active-low at the core. joystick_0/1: [0]=R [1]=L [2]=D [3]=U,
// then buttons in CONF_STR "J1" order from [4]: B1,B2,B3,Start,Coin —
// so Start is joystick[7] and Coin joystick[8] here.
//
// Keyboard: MAME's default key bindings, always active, ORed with the
// joysticks. hps_io's ps2_key is {toggle, pressed, extended, code}
// (PS/2 scan-code set 2; toggle flips on every event).
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
// Button 1 out = held & pattern.
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
wire p1_b1 = af1_en ? (p1_raw[4] & (af1_phase < af_on(af1_mode))) : p1_raw[4];
wire p2_b1 = af2_en ? (p2_raw[4] & (af2_phase < af_on(af2_mode))) : p2_raw[4];
wire [6:0] p1_btn = {p1_raw[6], p1_raw[5], p1_b1, p1_raw[3:0]};
wire [6:0] p2_btn = {p2_raw[6], p2_raw[5], p2_b1, p2_raw[3:0]};

wire [15:0] in1_i = ~{1'b0, p2_btn, 1'b0, p1_btn};

// ------------------------------------------------------------------
// DIP switches: the .mra <switches> block arrives on ioctl index 254
// (up to 8 raw bytes, byte 0 = DSW1, byte 1 = DSW2 — the order the core
// decodes them, sel_dsw1 at 0x080008 then sel_dsw2 at 0x08000A; byte 2 =
// the game id, see game_sel below). All ones (every switch off/idle-high)
// until the loader sends the block.
// The same transfer restarts at ioctl_addr 0, which is why the core's
// SDRAM write path is gated on ioctl_index == 0.
// ------------------------------------------------------------------
reg [7:0] dip_sw [0:7];
integer dip_i;
initial for (dip_i = 0; dip_i < 8; dip_i = dip_i + 1) dip_sw[dip_i] = 8'hFF;
always @(posedge clk_sys) begin
	if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
// gunnail has no service-mode DIP (DSW1 bit 0 is Flip Screen); MAME's
// F2 maps to nothing here, so the DIP bytes pass straight through.
// mustang and tharrier read ONE 16-bit DSW port at 0x080004 (SW2 in the
// low byte, SW1 in the high byte), so their second switch byte rides in
// dsw1's high half; every other board reads two byte-wide ports.
wire        game_mustang = (game_sel == 6'd3) | (game_sel == 6'd12) | (game_sel == 6'd20) | (game_sel == 6'd22) | (game_sel >= 6'd23); // mustang, mustangs, tharrier, mustangb3 and every Afega board: one 16-bit DSW port
wire [15:0] dsw1_i = {game_mustang ? dip_sw[1] : 8'hFF, dip_sw[0]};
wire [15:0] dsw2_i = {8'hFF, dip_sw[1]};
// Game select: the <switches> third byte (gunnail_core.sv's game table:
// 0 gunnail, 1 macross, 2 blkheart, 3 mustang, 4 bioship, 5 vandyke,
// 6 acrobatm, 7 strahl, 8 tdragon, 9 hachamf, 10 tdragon1, 11 hachamfp,
// 12 mustangs, 13 hachamfb, 14 bjtwin, 15 bjtwinp, 16 bjtwinpa,
// 17 sabotenb/nouryoku, 18 cactus, 19 nouryokup, 20 tharrier,
// 21 vandykeb). An .mra with only two switch bytes leaves it at the idle
// 0xFF, which is gunnail.
assign game_sel = (dip_sw[2] == 8'hFF) ? 6'd0 : dip_sw[2][5:0];

// ------------------------------------------------------------------
// SDRAM — single physical rtl/sdram.sv instance, 4 ports. The
// controller runs on the 96MHz clk_ram; every consumer stays on clk_sys
// and reaches it through rtl/sdram_req.sv's clock crossing.
// REFRESH_CYCLES=740 = 7.7us @ 96MHz, inside the JEDEC 7.8125us row
// refresh interval (see Macross2.sv / docs/hw-bringup.md).
// ------------------------------------------------------------------
wire [24:1] sd0_addr, sd1_addr, sd2_addr, sd3_addr;
wire        sd0_wrl, sd0_wrh, sd2_wrl, sd2_wrh;
wire [15:0] sd0_din, sd2_din;
wire [15:0] sd0_dout, sd1_dout, sd2_dout, sd3_dout;
wire [31:0] sd0_dout_pair, sd1_dout_pair, sd2_dout_pair, sd3_dout_pair;
wire        sd0_req, sd1_req, sd2_req, sd3_req;
wire        sd0_ack, sd1_ack, sd2_ack, sd3_ack;
wire        sdram_ready;

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
wire        ce_pix_core;
wire [9:0]  hcount_core, vcount_core;
wire signed [15:0] audio_l, audio_r;

// rd_x/rd_y are screen-relative (0..383/0..223, 0..255 lowres); the raw
// raster counters are blanking-inclusive, so subtract the active-window
// origin — 28 for gunnail's 384-px window, 92 for the lowres boards'
// 256-px one (the truncated subtraction underflows to >= the width during
// blanking, which video_macross2.sv's rd_in_range reads as "not visible").
wire [8:0] rd_x_screen = hcount_core[8:0] - (lowres ? 9'd92 : 9'd28);
wire [7:0] rd_y_raw    = vcount_core[7:0] - 8'd16;
wire [7:0] rd_y_screen = game_flip_y ? (8'd223 - rd_y_raw) : rd_y_raw; // out-of-range (blanking) values stay >= 224 either way

// VTIMING_FILE: nmk_irq.sv's V-PROMs are baked in at synthesis via
// $readmemh, not downloaded: a 1024-line file of four 256-byte tables —
// 0: 633ab1c9 (gunnail 9_82s135.u72; macross/mustang/acrobatm/hachamf),
// 1: 98ed1c97 (blkheart 9.bpr; bioship/vandyke), 2: e6ead349 (tdragon
// 91070.10), 3: de156d99 (mustangs 90058-10), 4-7: table 0 again — a
// 2048-line file. Generate it locally before quartus_map (ROM dump
// content, never committed): see docs/hw-bringup.md.
gunnail_core #(.HW_ROMS(1), .VTIMING_FILE("roms/gunnail_multi_vtiming.hex")) core
(
	.clk_sys(clk_sys), .reset(reset), .game_sel(game_sel),
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
	.dbg_nmk004_pc(), .dbg_nmk004_valid(), .dbg_nmk004_cen(), .dbg_nmk004_stall(),
	.dbg_nmk004_cen_total(), .dbg_nmk004_stall_total(),
	.dbg_host_cmd_we(), .dbg_host_cmd(), .dbg_mcu_reply_we(), .dbg_mcu_reply(),
	.dbg_prot_pc(), .dbg_prot_valid(), .dbg_halt_68k(), .dbg_prot_hl(), .dbg_prot_a(), .dbg_prot_de(), .dbg_prot_iy(),
	.dbg_prot_addr(), .dbg_prot_int_ram_at_hl(), .dbg_prot_bus_rd(), .dbg_prot_bus_wr(), .dbg_vt_vcount(),
	.dbg_nmk214_cfg_we(), .dbg_nmk214_cfg_data(),
	.dbg_ym_we(), .dbg_ym_cs(), .dbg_ym_chip_dout(), .dbg_ym_chip_irq_n(),
	.dbg_oki0_we(), .dbg_oki0_cs(), .dbg_oki0_chip_dout(), .dbg_oki1_we(), .dbg_oki1_cs(), .dbg_oki1_chip_dout(),
	.dbg_oki0_adpcm_total(), .dbg_oki0_adpcm_unserved(), .dbg_oki1_adpcm_total(), .dbg_oki1_adpcm_unserved(),
	.dbg_oki_cen_total(), .dbg_oki0_stall_cen(), .dbg_oki1_stall_cen(),
	.dbg_nmk004_a(), .dbg_nmk004_f(), .dbg_nmk004_hl(), .dbg_nmk004_ram_hl(),

	.rd_x(rd_x_screen), .rd_y(rd_y_screen), .rd_rgb(rd_rgb),
	.dbg_pal_addr('0), .dbg_pal_data(), .dbg_bgvram_addr('0), .dbg_bgvram_data(),
	.dbg_txvram_addr('0), .dbg_txvram_data(),
	.frame_done(),

	.audio_l(audio_l), .audio_r(audio_r),

	.ce_pix_o(ce_pix_core), .hcount_o(hcount_core), .vcount_o(vcount_core),
	.hblank_o(hblank_core), .vblank_o(vblank_core), .lowres_o(lowres),

	.in0_i(in0_i), .in1_i(in1_i), .dsw1_i(dsw1_i), .dsw2_i(dsw2_i)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

// ------------------------------------------------------------------
// Video output (2026-09-11): rtl/video_retime.sv re-clocks the core's
// 8 MHz-paced raster to the board's own pixel clock from a 48 MHz video
// PLL — 8 MHz (/6) for gunnail's 512-px line, 6 MHz (/8) for the lowres
// boards' 384-px line (3072 clk_vid per 64 us line either way) — and
// regenerates HS/VS/DE with the H/V Shift trims there. gunnail's
// placement is the former clk_sys one (hsync 440 wide 32, vsync row 264
// nominal); the lowres line has hsync at 20..43 of its 92-px leading
// blank (an 8 us back porch, as gunnail's 8.5 us; the 21 us lowres
// blanking cannot hold a pulse 3.5 us after the active end).
// H Shift: ±16 px in 2-px steps (status[21:18]); V Shift: ±20 lines
// (status[27:22]) — see CONF_STR.
// ------------------------------------------------------------------
wire  [3:0] hshift_sel = status[21:18];
wire  [5:0] vshift_sel = status[27:22];

wire clk_vid, pll_video_locked;
wire [23:0] retimed_rgb;
pll_video48 pll_video
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_vid),
	.locked(pll_video_locked)
);

video_retime #(
	.M0_X0(10'd28), .M0_HT(10'd512), .M0_HS(10'd440), .M0_HW(10'd32), .M0_AW(10'd384), .M0_DIV(4'd6),
	.M1_X0(10'd92), .M1_HT(10'd384), .M1_HS(10'd20),  .M1_HW(10'd24), .M1_AW(10'd256), .M1_DIV(4'd8),
	.LINE_CLKS(3072)
) video_retime (
	.clk_w(clk_sys), .reset_w(reset), .ce_w(ce_pix_core),
	.hcount_w(hcount_core), .vcount_w(vcount_core), .rgb_w(rd_rgb),
	.mode1(lowres), .hshift_sel(hshift_sel), .vshift_sel(vshift_sel),
	.clk_r(clk_vid),
	.ce_r(CE_PIXEL), .rgb_r(retimed_rgb), .hs_r(VGA_HS), .vs_r(VGA_VS), .de_r(VGA_DE)
);
assign CLK_VIDEO = clk_vid;
assign VGA_R  = retimed_rgb[23:16];
assign VGA_G  = retimed_rgb[15:8];
assign VGA_B  = retimed_rgb[7:0];

// ------------------------------------------------------------------
// Orientation (status[9:8], "Vert 270"/"Vert 90") and Flip screen
// (status[17]): the framework's screen_rotate (sys/arcade_video.v)
// copies the finished frame into a DDR3 framebuffer and hands it to
// the scaler (FB_EN). With Horz selected and Flip screen off,
// no_rotate holds FB_EN low and the scaler takes the direct VGA_*
// path — the core's own video pipeline is untouched either way. ROT270
// in MAME: the board's image is turned counter-clockwise to stand
// upright, which is screen_rotate's rotate_ccw=1 case ("Vert 270");
// "Vert 90" is rotate_ccw=0, the opposite quarter-turn, for cabinets
// whose vertical monitor is mounted the other way around. Flip screen
// only takes visible effect while Orientation is Horz (screen_rotate's
// own flip input is gated by no_rotate internally), giving a
// 180-degree upside-down image with no quarter-turn — for a horizontal
// monitor mounted upside-down, playing this game un-rotated.
// ------------------------------------------------------------------
wire  [1:0] orientation = status[9:8];
wire        flip_screen = status[17];
wire        video_rotated;
wire        no_rotate = (orientation == 2'd0) | direct_video | ~game_vertical;
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
