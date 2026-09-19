// NMK16 MiSTerFPGA project — real hardware top-level for the
// "NMK16_Afega" RBF: the 27 Afega-hardware sets (Stagger I / Red Hawk,
// Guardian Storm / Hong Hu Zhanji II, Bubble 2000 / Hot Bubble, Pop's
// Pop's, Mang-Chi, Spectrum 2000, Fire Hawk), game ids 23-43 of
// rtl/gunnail/gunnail_core.sv. Split out of NMK16_Gunnail.rbf on 2026-09-13:
// identical framework wiring, but gunnail_core is built with
// INCLUDE_AFEGA(1)/INCLUDE_NMK(0), so the NMK004/protection TLCS-90
// cores, the YM2203 and the Seibu/YM3812 sound board are elaborated
// away and only the Afega games' own hardware is in the netlist.
// NMK16_Gunnail.rbf is the mirror image (INCLUDE_AFEGA(0)) and keeps ids
// 0-22 and 44-51. See docs/hw-bringup.md.
//
// (original NMK16_Gunnail.sv header follows)
// NMK16 MiSTerFPGA project — real hardware top-level for the "Gunnail"
// RBF: GunNail (gunnail, gunnailp — nmk16.cpp gunnail_prot()) and, since
// 2026-09-11, the nine lowres NMK004 boards (macross, blkheart, mustang,
// bioship, vandyke, acrobatm, strahl, tdragon/tdragon1, hachamf) as
// runtime game modes of rtl/gunnail/gunnail_core.sv (game_sel, from the
// .mra <switches> third byte). Cloned from NMK16_Raphero.sv: the same
// framework wiring (hps_io, SDRAM, MAME-style keyboard, P1/P2 autofire,
// framebuffer rotation, .mra DIP capture) plus NMK16_Macross2.sv's video
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
	"NMK16_Afega;SS3E000000:40000;",   // savestates: 4 x 256 KB slots at 0x3E000000 (rtl/savestate/)
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	// HQ2X / scanlines via sys/video_mixer.sv. The mixer sits between
	// video_retime and VGA_*, so screen_rotate (which measures its
	// framebuffer from the incoming DE) sees the scaled raster and sizes
	// itself accordingly. forced_scandoubler from hps_io still forces it on.
	// Hidden (HB, menumask bit 11) under direct video, where the bits are
	// also ignored (fx below) -- that path is the native 15 kHz stream.
	"HBO[3:1],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
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
	// Flip screen (180-degree upside-down, no quarter-turn), for a monitor
	// mounted upside-down. Done inside the core on every video path: the
	// core mirrors its own readback coordinates (osd_flip on the core
	// instance) -- the path the Flip Screen DIP already takes (NMK-21),
	// so it works for every set, the ones whose board ignores the DIP
	// included -- and it reaches the analog I/O board's VGA output and
	// direct video as well as the HDMI scaler, which the framework's
	// framebuffer flip (screen_rotate) never did. Composes with
	// Orientation over HDMI (Vert + Flip = the other Vert).
	"O[17],Flip screen,Off,On;",
	// CRT Adjust (rtl/crt_chain.sv around rmonic79's MiSTer-CRT-Adjust,
	// rtl/third_party/crt_adjust): analog-geometry controls for 15 kHz CRT
	// users on their own page, replacing the former H/V Shift sync trims.
	// Off = the native stream, bit for bit. H-Size stretches/shrinks the
	// picture by changing the DAC read rate in quarter-cycle steps while
	// HSync stays native; H-Position moves HSync by N pixels with the
	// content anchored (the old H Shift, wider); V-Shift moves VSync by N
	// lines (the old V Shift); V-Size is 3 lines per step, PVM retiming
	// the line rate (broadcast monitors) or Cabinet resampling at native
	// timing (arcade chassis). Ignored while the scandoubler/HQ2X or the
	// rotation framebuffer is active -- those paths keep the native
	// stream (crt_on below). Status bits as in the upstream reference glue.
	// Offered on every path: the analog I/O board takes VGA_* whether or
	// not the HDMI scaler is in use, and the core cannot tell which
	// monitor is watching, so only direct video's own menu items are
	// gated (Scandoubler Fx, Orientation), never this page.
	"P3,CRT Adjust;",
	"P3O[101],CRT Adjust,Off,On;",
	"P3O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[85:79],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[107:104],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[108],CRT V-Size Mode,PVM,Cabinet;",
	// Autofire on button 1: Off, or a frames-on/frames-off pattern
	// clocked by the game's own vblank (~56 Hz): 10Hz = 3/3, 12Hz = 2/3,
	// 15Hz = 2/2, 20Hz = 1/2, 30Hz = 1/1 (this game has no third button
	// to double as a plain fire).
	// Hidden (h1) unless the loaded .mra's own <switches> third byte sets
	// bit 6 (autofire_unlock below, same convention as game_sel) — off by
	// default for all 71+ sets on this rbf; a specific .mra opts in by
	// adding that bit to its own <switches default="..."> byte 2. The
	// options themselves still default to Off either way.
	"h1O[12:10],P1 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"h1O[15:13],P2 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"-;",
	// "DIP;" is where MiSTer inserts the DIP-switch submenu it builds from
	// the loaded .mra's <switches>/<dip> entries. Changes arrive through
	// ioctl index 254 (dip_sw below) and MiSTer saves them itself to
	// config/dips/<mra>.dip, restored on the next load of that .mra.
	"DIP;",
	"-;",
	"O[29],Pause,Off,On;",
	"P1,Scores;",
	"P1O[39],High Scores,Off,On;",
	"P1-;",
	"dAP1R[30],Save Scores;",
	"dAP1R[31],Reset Scores;",
	// Savestates (2026-09-18): the slot and the two buttons; F1-F4 / Alt+F1-F4
	// on a keyboard (rtl/savestate/).
	"P4,Savestates;",
	"P4O[41:40],Slot,1,2,3,4;",
	"P4-;",
	"P4R[42],Save state (Alt+F1-F4);",
	"P4R[43],Load state (F1-F4);",
	"P2,Cheats;",
	"P2-;",
	"h3P2O[32],Infinite Credits,Off,On;",
	"h4P2O[33],P1 Invincibility,Off,On;",
	"h5P2O[34],P2 Invincibility,Off,On;",
	"h6P2O[35],P1 Infinite Lives,Off,On;",
	"h7P2O[36],P2 Infinite Lives,Off,On;",
	"h8P2O[37],P1 Infinite Bombs,Off,On;",
	"h9P2O[38],P2 Infinite Bombs,Off,On;",
	"-;",
	"R[0],Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"I,",
	"Slot=F1-F4|Save=Alt+F1-F4,",
	"Active Slot 1,",
	"Active Slot 2,",
	"Active Slot 3,",
	"Active Slot 4,",
	"State 1 saved,",
	"State 2 saved,",
	"State 3 saved,",
	"State 4 saved,",
	"State 1 loaded,",
	"State 2 loaded,",
	"State 3 loaded,",
	"State 4 loaded,",
	"Savestate failed,",
	"Slot empty;",
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
                            (game_sel == 6'd35) | (game_sel == 6'd36) | (game_sel == 6'd41) |
                            // Family E ROT270 sets: acrobatmbl, tdragonb, tdragonb3, gunnailb
                            (game_sel == 6'd45) | (game_sel == 6'd47) | (game_sel == 6'd48) | (game_sel == 6'd50);
// MAME ORIENTATION_FLIP_Y sets (grdnstrm, grdnstrmau, firehawk, spec2kh): the
// board draws upside down for a monitor mounted that way; the picture is
// read out bottom-up (rd_y mirrored) so it displays upright, as MAME does.
wire        game_flip_y = (game_sel == 6'd30) | (game_sel == 6'd34) | (game_sel == 6'd40) | (game_sel == 6'd42);
wire        autofire_unlock; // hidden .mra flag, <switches> byte 2 bit 6 (below) — unhides P1/P2 Autofire
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
	.status_menumask({4'd0, direct_video, hs_enable, ch_avail, 1'b0, autofire_unlock, direct_video | ~game_vertical}), // [11] hides Scandoubler Fx (HB) under direct video; [10] greys Save/Reset Scores (dA) while High Scores is Off; [1] shows P1/P2 Autofire (h1) only when the .mra sets the hidden unlock bit, [0] hides Orientation (H0) for direct video and the horizontal games
	.status_in({status[127:42], ss_slot, status[39:0]}),
	.status_set(ss_status_update),
	.info_req(ss_info_req),
	.info(ss_info),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),
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

// "Reset Scores". Two different hold times from one counter, because the two
// things being reset need different windows: the CORE only needs a normal
// reset pulse, while the hiscore MODULE has to stay in reset right through
// the game's boot and work-RAM test, or it will simply restore the saved dump
// again and nothing will have been reset. Held down, the module never
// restores, the game rebuilds its own default table, and the first OSD open
// after release extracts those defaults and autosaves them over the old .nvm.
reg [28:0] hs_rst_cnt = 29'd0;
always @(posedge clk_sys) begin
	if (status[31])          hs_rst_cnt <= 29'd240000000;   // ~6 s at 40 MHz
	else if (|hs_rst_cnt)    hs_rst_cnt <= hs_rst_cnt - 1'b1;
end
wire hs_hold     = |hs_rst_cnt;                        // module in reset
wire hs_core_rst = (hs_rst_cnt > 29'd236000000);       // core reset, first ~0.1 s

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked | hs_core_rst;

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
wire        game_mustang = (game_sel == 6'd3) | (game_sel == 6'd12) | (game_sel == 6'd20) | (game_sel == 6'd22) | ((game_sel >= 6'd23) & (game_sel <= 6'd44)); // mustang, mustangs, tharrier, mustangb3, every Afega board and mustangb: one 16-bit DSW port
// acrobatmbl reads its DSW1 word with SW1 in the HIGH byte ("changed from move.w to move.b"), DSW2 as acrobatm
wire        game_dsw1_hi = (game_sel == 6'd45);
wire [15:0] dsw1_i = game_dsw1_hi ? {dip_sw[0], 8'hFF} : {game_mustang ? dip_sw[1] : 8'hFF, dip_sw[0]};
wire [15:0] dsw2_i = {8'hFF, dip_sw[1]};
// Game select: the <switches> third byte (gunnail_core.sv's game table:
// 0 gunnail, 1 macross, 2 blkheart, 3 mustang, 4 bioship, 5 vandyke,
// 6 acrobatm, 7 strahl, 8 tdragon, 9 hachamf, 10 tdragon1, 11 hachamfp,
// 12 mustangs, 13 hachamfb, 14 bjtwin, 15 bjtwinp, 16 bjtwinpa,
// 17 sabotenb/nouryoku, 18 cactus, 19 nouryokup, 20 tharrier,
// 21 vandykeb). An .mra with only two switch bytes leaves it at the idle
// 0xFF, which is gunnail.
// game_sel is STATIC for a session: the .mra sets it once at load and it
// never changes afterwards. It nevertheless fans out combinationally into
// every per-game decode mux in gunnail_core/video_macross2, which makes
// dip_sw[2] -> ... -> video_macross2's sprite_plane altsyncram write
// enable one of the design's longest paths, and one that grows with every
// game id added. Measured 2026-09-13 on a branch carrying five more ids:
// that path went critical at -0.208 ns (the build stopped meeting timing)
// and only 1 of 8 fitter seeds recovered it; registering game_sel took the
// same seed to +0.568 ns. Registering costs nothing here — a static value
// reaching the core one cycle after load — so it is kept as headroom for
// future ids even though this tree currently closes at +0.382 ns.
wire [5:0] game_sel_comb = (dip_sw[2] == 8'hFF) ? 6'd0 : dip_sw[2][5:0];
reg  [5:0] game_sel_r = 6'd0;
always @(posedge clk_sys) game_sel_r <= game_sel_comb;
assign game_sel = game_sel_r;
// Byte 2 bit 6: hidden "unlock P1/P2 Autofire menu" flag — see the
// status_menumask/CONF_STR h1 wiring above. Off (hidden) for every
// current .mra, since none of them set it, and for the idle-0xFF
// two-byte-switches case above (gunnail.mra's own fallback path).
assign autofire_unlock = (dip_sw[2] == 8'hFF) ? 1'b0 : dip_sw[2][6];

// ------------------------------------------------------------------
// SDRAM — single physical rtl/sdram.sv instance, 4 ports. The
// controller runs on the 96MHz clk_ram; every consumer stays on clk_sys
// and reaches it through rtl/sdram_req.sv's clock crossing.
// REFRESH_CYCLES=740 = 7.7us @ 96MHz, inside the JEDEC 7.8125us row
// refresh interval (see NMK16_Macross2.sv / docs/hw-bringup.md).
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

// ---------------------------------------------------------------------------
// High score save/load (2026-09-15) — rtl/third_party/hiscore/hiscore.v,
// MAME hiscore.dat format. The .mra supplies the per-game entry table as
// <rom index="3"> and the saved dump rides <nvram index="4">.
//
// The module owns the game-RAM port only while it has the CPU paused, so no
// third read port is added to main RAM — that would duplicate the M10K
// (NMK-10). hs_pause is OR'd with the OSD Pause bit into the core.
//
// autosave is tied high so scores persist without the user thinking about it.
// The module only extracts-and-saves on a RISING edge of its OSD_STATUS
// input, so "Save Scores" forces one by driving that input low for a few
// cycles and letting it go high again — the module has no native "save now".
// "Reset Scores" suppresses the next dump load and resets the core, so the
// game rebuilds its own default table, which is then saved over the old one.
// ---------------------------------------------------------------------------
wire [23:0] hs_addr;
wire  [7:0] hs_din, hs_dout;
wire        hs_write, hs_access, hs_configured;
// NMK-24: hiscore.v has NO synchronous reset -- `reset` appears only as
// reset_last (falling-edge detect) and a `reset == 0` guard, so holding
// the module in reset does NOT clear pause_cpu. Without this gate, a user
// who switches High Scores on, hits the NMK-24 freeze and switches it off
// again stays frozen until the core is reloaded. Gate the output, not just
// the module's reset, so turning the option off always releases the CPU.
wire        hs_enable = status[39];   // "High Scores" -- OFF by default (NMK-24)
wire        hs_pause_raw;
wire        hs_pause = hs_pause_raw & hs_enable;
wire [23:0] hi_addr;
wire  [7:0] hi_din;
wire        hi_write;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire        hs_upload_req_raw;     // hiscore.v's own request, gated below
wire  [7:0] ioctl_din;
wire        ioctl_rd;

reg  [7:0]  hs_save_sr  = 8'd0;    // "Save Scores" -> synthetic OSD edge
always @(posedge clk_sys) begin
	hs_save_sr <= {hs_save_sr[6:0], 1'b0};
	if (status[30]) hs_save_sr <= 8'hFF;
end
wire hs_saving = |hs_save_sr;
// Both gated by the option (and the Reset Scores hold): hiscore.v's OSD-open
// extraction and its autosave upload run whenever a config has been loaded,
// with NO regard for its reset input. With High Scores Off the module is held
// in reset and never owns the RAM port, so an OSD open made it "extract" bus
// noise, find it "changed" and request an upload -- and the firmware wrote
// that over the saved .nvm (seen on the board: a tdragon2 .nvm full of
// 00/01 bytes, rewritten by the savestate info popups). The option must be
// able to sit Off without destroying scores saved while it was On.
wire hs_active = hs_enable & ~hs_hold;
wire hs_osd = OSD_STATUS & ~hs_saving & hs_active;   // drop low during a Save to force the edge
assign ioctl_upload_req = hs_upload_req_raw & hs_active;


hiscore #(
	.HS_ADDRESSWIDTH(24),
	.HS_SCOREWIDTH(13),      // 5504 bytes is the largest table here (macross2)
	.CFG_ADDRESSWIDTH(4),    // 13 entries is the most any of our sets uses
	.CFG_LENGTHWIDTH(2)
) hi (
	.clk(clk_sys),
	.reset(reset | hs_hold | ~hs_enable),
	.paused(hs_pause_raw),
	.autosave(1'b1),
	.OSD_STATUS(hs_osd),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(hs_upload_req_raw),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_index(ioctl_index[7:0]),
	.data_from_hps(ioctl_dout),
	.data_to_hps(ioctl_din),
	.data_from_ram(hs_dout),
	.data_to_ram(hi_din),
	.ram_address(hi_addr),
	.ram_write(hi_write),
	.ram_intent_read(),
	.ram_intent_write(),
	.pause_cpu(hs_pause_raw),
	.configured(hs_configured)
);


// ---------------------------------------------------------------------------
// Cheats (rtl/cheats.sv) — Pugsy's MAME cheat database, seven fixed slots with
// this game's addresses supplied by the .mra as <rom index="5">. Slots the
// loaded game has no entry for are hidden from the OSD via status_menumask
// bits 3..9 (the h3..h9 flags on the CONF_STR lines above).
//
// It shares the hiscore module's work-RAM port rather than adding one: both
// only drive it while they have the CPU paused, and hiscore wins if they ever
// collide (it runs on OSD open, cheats on vblank, so in practice they do not).
// ---------------------------------------------------------------------------
wire [23:0] ch_addr;
wire  [7:0] ch_din;
wire        ch_write, ch_access, ch_pause;
wire  [6:0] ch_avail;

cheats ch (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_index(ioctl_index), .ioctl_dout(ioctl_dout),
	.enable(status[38:32]),
	.available(ch_avail),
	.vblank(vblank_core),
	.ram_addr(ch_addr), .ram_din(ch_din), .ram_write(ch_write),
	.ram_access(ch_access), .pause_cpu(ch_pause)
);

// hiscore has priority on the shared port
assign hs_addr   = hs_pause ? hi_addr  : ch_addr;
assign hs_din    = hs_pause ? hi_din   : ch_din;
assign hs_write  = hs_pause ? hi_write : ch_write;
assign hs_access = hs_pause ? 1'b1     : ch_access;

// ---------------------------------------------------------------------------
// Savestates (2026-09-18) -- rtl/savestate/savestate.sv: parks every CPU
// (rtl/savestate/ss_m68k_park.sv, ss_z80_park.sv, the TLCS-90's own
// freeze), streams the core's state image to the slot in DDR3 (CONF_STR
// "SS3E000000:40000", the firmware writes it to disk) and back. The
// engine's DDR side shares the DDRAM port with screen_rotate (below) and
// yields to it cycle by cycle, on the video clock. The core's pause is
// masked while an operation runs, since the CPUs must execute to park.
// ---------------------------------------------------------------------------
wire  [1:0] ss_slot;
wire  [7:0] ss_info;
wire        ss_save, ss_load, ss_info_req, ss_status_update;
wire        ss_busy, ss_done_ok, ss_done_fail, ss_was_load;
wire  [1:0] ss_fail_code;
wire        ss_freeze, ss_frozen, ss_parked, ss_resume, ss_active, ss_wr, ss_replay, ss_replay_done;
wire [19:0] ss_addr;
wire [15:0] ss_rdata, ss_wdata;
wire        eng_we, eng_rd;
wire [28:0] eng_addr;
wire [63:0] eng_din;

savestate_ui savestate_ui (
	.clk(clk_sys), .ps2_key(ps2_key), .allow_ss(~reset),
	.status_slot(status[41:40]), .OSD_saveload(status[43:42]),
	.done_ok(ss_done_ok), .done_fail(ss_done_fail), .fail_code(ss_fail_code), .was_load(ss_was_load),
	.ss_save(ss_save), .ss_load(ss_load), .ss_info_req(ss_info_req), .ss_info(ss_info),
	.statusUpdate(ss_status_update), .selected_slot(ss_slot)
);

savestate #(.SS_WORDS(65536), .DDR_BASE(29'h07C00000), .SLOT_STRIDE(29'h00008000)) savestate (
	.clk(clk_sys), .reset(reset),
	.save_req(ss_save), .load_req(ss_load), .slot(ss_slot), .vblank(vblank_core), .allow(~ioctl_download),
	.ss_freeze(ss_freeze), .ss_frozen(ss_frozen), .ss_parked(ss_parked), .ss_resume(ss_resume), .ss_active(ss_active),
	.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
	.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
	.busy(ss_busy), .done_ok(ss_done_ok), .done_fail(ss_done_fail), .fail_code(ss_fail_code), .was_load(ss_was_load),
	.clk_ddr(CLK_VIDEO), .ddr_busy(DDRAM_BUSY), .rot_we(rot_we),
	.ddr_we(eng_we), .ddr_rd(eng_rd), .ddr_addr(eng_addr), .ddr_din(eng_din),
	.ddr_dout(DDRAM_DOUT), .ddr_dout_ready(DDRAM_DOUT_READY)
);

gunnail_core #(.HW_ROMS(1), .INCLUDE_AFEGA(1), .INCLUDE_NMK(0)) core
(
	.clk_sys(clk_sys), .reset(reset), .pause((status[29] | hs_pause | ch_pause) & ~ss_busy), .hs_addr(hs_addr), .hs_din(hs_din), .hs_dout(hs_dout), .hs_write(hs_write), .hs_access(hs_access), .game_sel(game_sel),
	.ss_freeze(ss_freeze), .ss_resume(ss_resume), .ss_active(ss_active), .ss_frozen(ss_frozen), .ss_parked(ss_parked),
	.ss_addr(ss_addr), .ss_rdata(ss_rdata), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
	.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
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

	.in0_i(in0_i), .in1_i(in1_i), .dsw1_i(dsw1_i), .dsw2_i(dsw2_i),
	// OSD Flip screen, every video path: mirrored inside the core (the
	// DIP's path), so the I/O board's VGA output and direct video get it
	// too; screen_rotate's own flip input (below) is no longer used.
	.osd_flip(status[17])
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

// ------------------------------------------------------------------
// Video output (2026-09-11): rtl/video_retime.sv re-clocks the core's
// 8 MHz-paced raster to the board's own pixel clock from a 96 MHz video
// PLL — 8 MHz (/12) for gunnail's 512-px line, 6 MHz (/16) for the lowres
// boards' 384-px line (6144 clk_vid per 64 us line either way) — and
// regenerates HS/VS/DE there. gunnail's
// placement is the former clk_sys one (hsync 440 wide 32, vsync row 264
// nominal); the lowres line has hsync at 20..43 of its 92-px leading
// blank (an 8 us back porch, as gunnail's 8.5 us; the 21 us lowres
// blanking cannot hold a pulse 3.5 us after the active end).
// The former H/V Shift sync trims are gone (2026-09-18): the CRT
// Adjust chain (rtl/crt_chain.sv, below the mixer's enables) shifts
// sync downstream of the retimer instead.
// ------------------------------------------------------------------

wire clk_vid, pll_video_locked;
wire [23:0] retimed_rgb;
wire [23:0] rt_rgb;
wire        rt_ce, rt_hs, rt_vs, rt_hb, rt_vb, rt_vb_hs;
wire vm_ce_pix, vm_hs, vm_vs, vm_hb, vm_vb;
wire [21:0] vm_gamma_bus;
pll_video96 pll_video
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_vid),
	.locked(pll_video_locked)
);

video_retime #(
	.M0_X0(10'd28), .M0_HT(10'd512), .M0_HS(10'd440), .M0_HW(10'd32), .M0_AW(10'd384), .M0_DIV(5'd12),
	.M1_X0(10'd92), .M1_HT(10'd384), .M1_HS(10'd20),  .M1_HW(10'd24), .M1_AW(10'd256), .M1_DIV(5'd16),
	.LINE_CLKS(6144)
) video_retime (
	.clk_w(clk_sys), .reset_w(reset), .ce_w(ce_pix_core),
	.hcount_w(hcount_core), .vcount_w(vcount_core), .rgb_w(rd_rgb),
	.mode1(lowres), .tall240(1'b0),
	.clk_r(clk_vid),
	.ce_r(rt_ce), .rgb_r(rt_rgb), .hs_r(rt_hs), .vs_r(rt_vs), .de_r(),
	.hb_r(rt_hb), .vb_r(rt_vb), .vb_hs_r(rt_vb_hs)
);
assign CLK_VIDEO = clk_vid;
// HQ2X / scandoubler / scanlines. fx==0 leaves the raster untouched unless
// hps_io asks for a forced scandoubler; fx==1 is HQ2X; 2..4 are CRT scanlines,
// which the mixer applies via VGA_SL.
// NMK-28: the scandoubler MUST be off whenever the rotation framebuffer is
// active. sys/arcade_video.v's screen_rotate has NO backpressure -- it asserts
// ram_wr on every CE_PIXEL & VGA_DE and never looks at DDRAM_BUSY -- so at the
// doubled pixel rate it writes 4x the pixels per frame with no flow control,
// DDR writes are dropped and the picture comes out cut off. Scanlines are moot
// there in any case: sys/sys_top.v:364 does `sl_r <= FB_EN ? 2'b00 : scanlines`,
// i.e. the framework force-disables them in framebuffer mode. So "Scandoubler
// Fx" has no effect while Orientation is Vert. (Flip screen is done in
// the core since 2026-09-19 and no longer needs the framebuffer.)
// Under direct video the option is hidden (HB) and its bits ignored here,
// so a setting made on the HDMI path cannot linger unseen; the
// framework's own forced_scandoubler still applies.
wire       fb_rotating = ~((status[9:8] == 2'd0) | direct_video | ~game_vertical);
wire [2:0] fx = direct_video ? 3'd0 : status[3:1];
wire       scandoubler_en = ((fx != 3'd0) || forced_scandoubler) && ~fb_rotating;
wire [1:0] sl = fx[2:1];
assign VGA_SL = sl;

// ------------------------------------------------------------------
// CRT Adjust (rtl/crt_chain.sv): V-Size, then H-Size / H-Position /
// V-Shift, on the 15 kHz retimed raster ahead of the mixer. Off -- or
// while the scandoubler/HQ2X or the rotation framebuffer is in use --
// it is a registered passthrough with every signal delayed alike.
// Active on every path (the I/O board's VGA output is this same stream
// whether or not the HDMI scaler is watching it too).
// ------------------------------------------------------------------
wire        crt_on = status[101] & ~scandoubler_en & ~fb_rotating;
crt_chain #(
	.HTOTAL0(10'd512), .HTOTAL1(10'd384), .DIV0(5'd12), .DIV1(5'd16),
	.VTOTAL(278), .LINE_PX(400), .VSIZE_MAX(7)
) crt_chain (
	.clk(clk_vid), .ce_in(rt_ce), .rgb_in(rt_rgb),
	.hs_in(rt_hs), .vs_in(rt_vs), .hb_in(rt_hb), .vb_in(rt_vb), .vb_hs_in(rt_vb_hs),
	.mode1(lowres), .enable(crt_on),
	.hsize($signed(status[100:96])), .hpos_raw(status[85:79]),
	.vshift($signed(status[78:74])), .vsize_code(status[107:104]),
	.vsize_mode(status[108]),
	.ce_out(vm_ce_pix), .rgb_out(retimed_rgb),
	.hs_out(vm_hs), .vs_out(vm_vs), .hb_out(vm_hb), .vb_out(vm_vb)
);

video_mixer #(.LINE_LENGTH(400), .HALF_DEPTH(0), .GAMMA(0)) video_mixer (
	.CLK_VIDEO(CLK_VIDEO),
	.ce_pix(vm_ce_pix),
	.CE_PIXEL(CE_PIXEL),
	.scandoubler(scandoubler_en),
	.hq2x(fx == 3'd1),
	.gamma_bus(vm_gamma_bus),
	.R(retimed_rgb[23:16]), .G(retimed_rgb[15:8]), .B(retimed_rgb[7:0]),
	.HSync(vm_hs), .VSync(vm_vs), .HBlank(vm_hb), .VBlank(vm_vb),
	.HDMI_FREEZE(1'b0), .freeze_sync(),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

// ------------------------------------------------------------------
// Orientation (status[9:8], "Vert 270"/"Vert 90"): the framework's
// screen_rotate (sys/arcade_video.v) copies the finished frame into a
// DDR3 framebuffer and hands it to the scaler (FB_EN). With Horz
// selected, no_rotate holds FB_EN low and the scaler takes the direct
// VGA_* path — the core's own video pipeline is untouched either way.
// ROT270 in MAME: the board's image is turned counter-clockwise to
// stand upright, which is screen_rotate's rotate_ccw=1 case ("Vert
// 270"); "Vert 90" is rotate_ccw=0, the opposite quarter-turn, for
// cabinets whose vertical monitor is mounted the other way around.
// Flip screen (status[17]) no longer goes through here: it is the
// core's own readback-coordinate mirror (osd_flip on the core instance
// above, the Flip Screen DIP's path, NMK-21), which reaches the analog
// I/O board's VGA output and direct video as well as the scaler.
// screen_rotate's flip input is tied off.
// ------------------------------------------------------------------
wire  [1:0] orientation = status[9:8];
wire        video_rotated;
wire        no_rotate = (orientation == 2'd0) | direct_video | ~game_vertical;
wire        rotate_ccw = orientation != 2'd2;
wire        flip = 1'b0;
// The DDRAM port is shared with the savestate engine: screen_rotate's write
// wins any cycle it appears on (it has no backpressure of its own), the
// engine fills the gaps. Both run on CLK_VIDEO (screen_rotate's DDRAM_CLK).
wire        rot_we;
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
screen_rotate screen_rotate (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(flip), .video_rotated(video_rotated),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(), .DDRAM_ADDR(rot_addr),
	.DDRAM_DIN(rot_din), .DDRAM_BE(rot_be), .DDRAM_WE(rot_we), .DDRAM_RD()
);
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_ADDR     = rot_we ? rot_addr : eng_addr;
assign DDRAM_DIN      = rot_we ? rot_din  : eng_din;
assign DDRAM_BE       = rot_we ? rot_be   : 8'hFF;
assign DDRAM_WE       = rot_we | eng_we;
assign DDRAM_RD       = eng_rd;
assign FB_FORCE_BLANK = 1'b0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
