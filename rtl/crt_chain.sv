// rtl/crt_chain.sv -- "CRT Adjust" for the NMK16 rbfs (2026-09-18).
//
// Glue around rmonic79's MiSTer-CRT-Adjust (rtl/third_party/crt_adjust,
// GPL-3.0-or-later, pinned in deps.lock), placed between video_retime and
// sys/video_mixer.sv, i.e. on the board's own 15 kHz raster BEFORE the
// HQ2X/scandoubler stage and the rotation framebuffer:
//
//     video_retime -> crt_vsize -> crt_adjust -> video_mixer -> VGA_* / screen_rotate
//
// The chain replaces the former "H Shift" / "V Shift" OSD trims, which moved
// the sync pulses inside video_retime. It gives the analog/CRT user:
//   CRT H-Size     -16..+15 : the DAC read rate, in quarter clk_vid cycles
//                             per pixel, so the picture stretches or shrinks
//                             while HSync stays native
//   CRT H-Position -48..+48 : HSync moved by N pixels (the module's
//                             HPOS_SYNCSHIFT), content anchored. "+" =
//                             picture RIGHT = sync EARLIER, this project's
//                             convention since the old H Shift and the
//                             physics of a CRT sweep (the beam position of
//                             a pixel is its distance from the retrace;
//                             a later sync puts it further left). The
//                             upstream module labels the opposite way
//                             (its +N delays the pulse), so both offsets
//                             are negated on the way in.
//   CRT V-Shift    -16..+15 : VSync moved by N lines, "+" = picture DOWN =
//                             sync earlier, same convention
//   CRT V-Size  -MAX..+MAX  : 3 lines per step; PVM (line retimer, the
//                             HSync rate moves) or Cabinet (native timing,
//                             photometric resampling) mode. VSIZE_MAX is
//                             per core: 7 where the M10K budget allows the
//                             46-line ring, 4 (28 lines) on NMK16_Macross2,
//                             which is 539/553 blocks with the 52-line ring
//                             and at that point Quartus silently turns the
//                             framework's own hq2x/ascal/shadowmask RAMs
//                             into 20k flip-flops (found 2026-09-18).
//
// H-Size enlarge has a geometry limit the module cannot lift: the read
// engine restarts on the sync pulse, so the stretched active window must
// end before the NEXT pulse or its right edge is cut. Hires lines put the
// pulse only 28 px after the active area (active 28..411, sync 440 of
// 512), which leaves room for +2 quarter-cycles (about +4 %); lowres
// lines (sync 20, active 92..347 of 384) take about +10 (+15 %). Shrink
// is unbounded. Moving the picture LEFT (H-Position -) buys enlarge room,
// moving it right spends it. sim/rtl/crt_chain models the truncation.
//
// Why HPOS_SYNCSHIFT: every game here is narrow and side-anchored on its
// line (384 active of 512 with a 28/100 split, 256 of 384 with 92/36, 320
// of 448 with 60/68), exactly the case the module's own notes reserve the
// sync-shift mechanism for -- content-shifting would run the picture out
// of the line buffer and paint a black block at the edge. It also keeps
// VGA_DE native, so the OSD, which centres on the DE rising edge, stays
// put without the de_osd glue the content-shift mode needs.
//
// The one thing the modules cannot know: the line length changes with
// the game mode (512 or 384/448 pixels) while crt_adjust's HTOTAL is a
// parameter that sizes its HSync shift register and computes a NEGATIVE
// offset as HTOTAL - |N|. The register is built for the LONGER line and
// a negative offset on the shorter one is corrected by the difference,
// so "advance by N" lands N pixels early on either line length.
//
// Everything downstream must see the modules' OWN regenerated blanks
// (crt_vsize extends the vertical window; crt_adjust regenerates hb from
// its buffer window), never the native ones -- feeding a native vblank
// past crt_vsize blacks out the rows V-Size adds. When `enable` is low
// the OUTPUTS ARE THE INPUTS, wire for wire: the two modules do have a
// registered bypass, but it costs three pixel enables of latency and
// crt_vsize only regenerates a COMBINED blank, so an "Off" routed through
// them would hand the mixer's scandoubler a different HBlank on vblank
// lines. Off must be bit-identical to the native stream, so it is. The
// caller drops `enable` whenever the scandoubler/HQ2X or the rotation
// framebuffer is in use -- the chain is a 15 kHz analog feature and the
// doubled/rotated paths keep their native stream. While On, the HBlank
// handed on is the combined blank (asserted for whole vblank lines),
// which is all the mixer's passthrough path needs.
module crt_chain #(
	parameter [9:0]   HTOTAL0    = 10'd512,   // line length in pixels, mode 0
	parameter [9:0]   HTOTAL1    = 10'd384,   // line length in pixels, mode 1
	parameter [4:0]   DIV0       = 5'd12,     // clk per pixel, mode 0 (video_retime M0_DIV)
	parameter [4:0]   DIV1       = 5'd16,     // clk per pixel, mode 1 (M1_DIV)
	parameter integer VTOTAL     = 278,       // lines per frame (VSync shift register)
	parameter integer LINE_PX    = 400,       // V-Size ring slots per line: MORE than the widest
	                                          // active line (384). crt_vsize's per-line pixel
	                                          // counter saturates at LINE_PX-1, so a ring exactly
	                                          // as wide as the line records 383 of 384 pixels and
	                                          // the V-Size modes lose the last column (seen on the
	                                          // board as 383x230 native frames, 2026-09-18).
	parameter integer VSIZE_MAX  = 7          // V-Size steps each way (3 lines per step); the OSD
	                                          // list must be "0,+1..+MAX,-MAX..-1" (2*MAX+1 entries)
) (
	input               clk,        // clk_vid
	input               ce_in,      // uniform native pixel enable (video_retime ce_r)
	input        [23:0] rgb_in,
	input               hs_in,
	input               vs_in,
	input               hb_in,
	input               vb_in,      // TRUE vertical blank (the Off path hands it on)
	input               vb_hs_in,   // the same with its edges on the hsync start
	                                // (video_retime's vb_hs_r): what the modules
	                                // sample at each HSync rise for the active
	                                // window that FOLLOWS the pulse
	input               mode1,      // 1: the HTOTAL1/DIV1 geometry
	input               enable,     // CRT Adjust On, already gated by the caller

	input  signed [4:0] hsize,      // OSD, -16..+15
	input         [6:0] hpos_raw,   // OSD list code: 0..48 = +0..+48, 49..96 = -48..-1
	input  signed [4:0] vshift,     // OSD, -16..+15 lines
	input         [3:0] vsize_code, // OSD list code: 0..MAX = +0..+MAX, MAX+1..2*MAX = -MAX..-1
	input               vsize_mode, // 0 = PVM (retimer), 1 = Cabinet (photometric)

	output              ce_out,
	output       [23:0] rgb_out,
	output              hs_out,
	output              vs_out,
	output              hb_out,
	output              vb_out
`ifdef VERILATOR
	, output            dbg_vz_ce,  // stage-1 (crt_vsize) outputs, for sim/rtl/crt_chain
	  output            dbg_vz_hs,
	  output            dbg_vz_vs,
	  output            dbg_vz_de,
	  output            dbg_vz_vb
`endif
);

	// ------------------------------------------------------------------
	// OSD decode, registered on the pixel enable like the reference glue.
	// ------------------------------------------------------------------
	reg               on_q = 1'b0;
	reg signed  [4:0] hsize_q = 5'sd0;
	reg         [6:0] hpos_q = 7'd0;
	reg signed  [5:0] vshift_q = 6'sd0;
	reg signed  [5:0] vsize_q = 6'sd0;
	// V-Size ring: PVM reads start RING/2 lines after VSync and drift by up
	// to |vsize| = 3*MAX lines, so RING >= 2*3*MAX + 4.
	localparam integer RING_LINES = 6 * VSIZE_MAX + 4;
	// list code -> signed step
	wire signed [4:0] vsize_step = (vsize_code <= 4'(VSIZE_MAX)) ? $signed({1'b0, vsize_code})
	                                                        : $signed({1'b0, vsize_code}) - 5'(2 * VSIZE_MAX + 1);
	reg               vsmode_q = 1'b0;
	always @(posedge clk) if (ce_in) begin
		on_q     <= enable;
		hsize_q  <= hsize;
		hpos_q   <= hpos_raw;
		// "+" = picture down = VSync EARLIER; the module's +N delays it.
		vshift_q <= -$signed({vshift[4], vshift});
		// crt_vsize counts lines ADDED to the frame (+ = shorter); the OSD
		// "+" means taller, so the step is negated: -3 * step.
		vsize_q  <= -($signed({vsize_step[4], vsize_step}) + ($signed({vsize_step[4], vsize_step}) <<< 1));
		vsmode_q <= vsize_mode;
	end

	// H-Position: the OSD list is "0,+1..+48,-48..-1" -- 97 entries, so
	// codes 0..48 are +0..+48 and codes 49..96 are -48..-1 (code - 97).
	// (The upstream glue decodes a 128-wrap instead; its README and snippet
	// disagree by one on where the negatives start, so this project keeps
	// the list and the decode together here.)
	// Then negated: "+" = picture right = HSync EARLIER; the module's +N
	// delays the pulse (see the header).
	wire signed [8:0] hpos_osd = (hpos_q <= 7'd48) ? $signed({2'b0, hpos_q})
	                                               : $signed({2'b0, hpos_q}) - 9'sd97;
	wire signed [8:0] hpos_s   = -hpos_osd;
	// The module's HSync shift register is HTOTAL_MAX long and computes a
	// negative offset as HTOTAL_MAX + hoffset. On the shorter line that
	// must become HTOTAL_line + hoffset, so subtract the difference.
	localparam [9:0] HTOTAL_MAX = (HTOTAL0 >= HTOTAL1) ? HTOTAL0 : HTOTAL1;
	wire        [9:0]  ht_line    = mode1 ? HTOTAL1 : HTOTAL0;
	wire signed [10:0] ht_corr11  = $signed({1'b0, HTOTAL_MAX}) - $signed({1'b0, ht_line});
	wire signed [10:0] hpos_s11   = {{2{hpos_s[8]}}, hpos_s};
	/* verilator lint_off UNUSEDSIGNAL */
	wire signed [10:0] hpos_eff11 = hpos_s[8] ? (hpos_s11 - ht_corr11) : hpos_s11;
	/* verilator lint_on UNUSEDSIGNAL */
	// Range -(48 + 128) = -176 .. +48: the module's signed 9-bit port holds it.
	// Registered: the value is static, and the decode above plus the module's
	// own tap subtract and 512:1 sync-tap mux was -0.23 ns in one 96 MHz
	// cycle when fed combinationally.
	reg  signed [8:0]  hpos_eff = 9'sd0;
	always @(posedge clk) hpos_eff <= hpos_eff11[8:0];

	// ------------------------------------------------------------------
	// Stage 1: V-Size (before crt_adjust, which composes per line).
	// de_in is the combined active-pixel window; vb_in the TRUE vblank.
	// ------------------------------------------------------------------
	wire [23:0] vz_rgb;
	wire        vz_hs, vz_vs, vz_de, vz_vb, vz_ce;
`ifdef VERILATOR
	assign dbg_vz_ce = vz_ce; assign dbg_vz_hs = vz_hs; assign dbg_vz_vs = vz_vs;
	assign dbg_vz_de = vz_de; assign dbg_vz_vb = vz_vb;
`endif
	crt_vsize #(
		.RING_LINES(RING_LINES),
		.LINE_PX   (LINE_PX)
	) u_vsize (
		.clk      (clk),
		.pxl_cen  (ce_in),
		.active   (on_q),
		.tube_mode(vsmode_q),
		.vsize    (vsize_q),
		.r_in     (rgb_in[23:16]), .g_in(rgb_in[15:8]), .b_in(rgb_in[7:0]),
		.hs_in    (hs_in),
		.vs_in    (vs_in),
		.de_in    (~(hb_in | vb_in)),
		.vb_in    (vb_hs_in),
		.r_out    (vz_rgb[23:16]), .g_out(vz_rgb[15:8]), .b_out(vz_rgb[7:0]),
		.hs_out   (vz_hs),
		.vs_out   (vz_vs),
		.de_out   (vz_de),
		.vb_out   (vz_vb),
		.ce_out   (vz_ce)
	);

	// ------------------------------------------------------------------
	// Read-rate generator for H-Size: one DAC pixel every (4*DIV + hsize)
	// quarter cycles of clk, reset on the rise of the module's hs_ref_out
	// (the shifted HSync in SYNCSHIFT) -- never on the raw HSync, or the
	// read rate and the module's read counter drift apart frame to frame.
	// ------------------------------------------------------------------
	wire       hs_ref;
	reg        hs_ref_d = 1'b0;
	always @(posedge clk) hs_ref_d <= hs_ref;
	wire       hs_ref_rise = hs_ref & ~hs_ref_d;

	wire [7:0] base_q    = {1'b0, (mode1 ? DIV1 : DIV0), 2'b00};   // 4 * DIV
	wire [7:0] rd_period = base_q + {{3{hsize_q[4]}}, hsize_q};
	reg  [7:0] rd_acc = 8'd0;
	wire       rd_tick = (rd_acc + 8'd4) >= rd_period;
	always @(posedge clk) begin
		if      (hs_ref_rise) rd_acc <= 8'd0;
		else if (rd_tick)     rd_acc <= rd_acc + 8'd4 - rd_period;
		else                  rd_acc <= rd_acc + 8'd4;
	end
	wire       rd_ce = on_q ? rd_tick : vz_ce;

	// ------------------------------------------------------------------
	// Stage 2: H-Size / H-Position / V-Shift, fed entirely from stage 1.
	// ------------------------------------------------------------------
	wire [23:0] adj_rgb;
	wire        adj_hs, adj_vs, adj_hb;
	/* verilator lint_off UNUSEDSIGNAL */
	wire        adj_vb;
	/* verilator lint_on UNUSEDSIGNAL */
	crt_adjust #(
		.VTOTAL   (VTOTAL),
		.HTOTAL   (HTOTAL_MAX),
		.HPOS_MODE(0)               // HPOS_SYNCSHIFT (the literal: crt_adjust.sv's
		                            // `define is not visible unless that file
		                            // happens to be compiled first)
	) u_adjust (
		.clk       (clk),
		.pxl_cen   (vz_ce),
		.pxl2_cen  (rd_ce),
		.active    (on_q),
		.hsize     (hsize_q),
		.hoffset   (hpos_eff),
		.voffset   (vshift_q),
		.r_in      (vz_rgb[23:16]), .g_in(vz_rgb[15:8]), .b_in(vz_rgb[7:0]),
		.hs_in     (vz_hs),
		.vs_in     (vz_vs),
		.hb_in     (~vz_de),
		.vb_in     (vz_vb),
		.r_out     (adj_rgb[23:16]), .g_out(adj_rgb[15:8]), .b_out(adj_rgb[7:0]),
		.hs_out    (adj_hs),
		.vs_out    (adj_vs),
		.hb_out    (adj_hb),
		.vb_out    (adj_vb),        // unused: see the VBlank note below
		.hs_ref_out(hs_ref)
	);

	// ------------------------------------------------------------------
	// VBlank for the mixer while On. crt_adjust emits each line one line
	// AFTER it was written (ping-pong buffer) but passes vb_in through
	// undelayed, so the last active row would be emitted under an
	// already-asserted VBlank and the mixer would blank it. Rebuild the
	// module's own gate here -- VBlank sampled at each stage-1 HSync rise
	// and applied one line later -- and hand THAT on; it is what the
	// module's hb_out already embodies, and it moves the VBlank edges
	// onto the emitted-line timeline. (The upstream glue avoids the issue
	// by never deriving DE from vb_out; this core's mixer needs a VBlank.)
	// ------------------------------------------------------------------
	// Sampled one pixel enable AFTER the rise: crt_vsize (PVM) drops its
	// vb_out on the second clock of an output line, the same clock as that
	// line's first pixel enable, so a sample taken right at the rise still
	// reads the previous line's value (crt_adjust's own sampler is one
	// enable later for the same reason).
	reg vz_hs_d = 1'b0, vz_rise_q = 1'b0, vb_line_a = 1'b1, vb_line_b = 1'b1;
	always @(posedge clk) if (vz_ce) begin
		vz_hs_d   <= vz_hs;
		vz_rise_q <= vz_hs & ~vz_hs_d;
		if (vz_rise_q) begin
			vb_line_a <= vz_vb;
			vb_line_b <= vb_line_a;
		end
	end

	// ------------------------------------------------------------------
	// Off = the native stream itself (see the header).
	// ------------------------------------------------------------------
	assign ce_out  = on_q ? rd_ce     : ce_in;
	assign rgb_out = on_q ? adj_rgb   : rgb_in;
	assign hs_out  = on_q ? adj_hs    : hs_in;
	assign vs_out  = on_q ? adj_vs    : vs_in;
	assign hb_out  = on_q ? adj_hb    : hb_in;
	assign vb_out  = on_q ? vb_line_b : vb_in;

endmodule
