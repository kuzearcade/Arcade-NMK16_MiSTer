// Verilator test for rtl/crt_chain.sv (CRT Adjust, 2026-09-18).
//
// Drives a synthetic 96 MHz-clock raster with the Gunnail rbf's geometry
// (512 px lines at 12 clk per pixel, 278 lines, active 28..411 x 16..239,
// hsync at 440 width 32, vsync at row 264 width 3) through the chain and
// measures, on the output:
//   - the pixel enable period, HSync period and VSync period (line/frame
//     structure), the active-pixel and active-line counts,
//   - HSync rise relative to the DE start of the same line (H-Position),
//   - VSync rise relative to the first DE line of the frame (V-Shift),
//   - the DE width in clocks (H-Size: 384 * (48 + hsize) / 4),
//   - lines per frame and DE lines per frame (V-Size PVM / Cabinet),
// and, for Off and for On-with-everything-at-0, compares the whole output
// stream against the input delayed by a constant, which must be
// bit-identical (the chain's own promise).
//
//   ./Vcrt_chain <enable> <hsize> <hpos_raw> <vshift> <vsize_step> <vsmode> [mode1]
//     hsize -16..15, hpos_raw 0..96 (list code), vshift -16..15,
//     vsize_step -7..7 (VSIZE_MAX 7), vsmode 0 PVM / 1 Cabinet; mode1 0 (512 px) / 1 (384 px)
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vcrt_chain.h"
#include "verilated.h"

static int expect_pass = 0, failures = 0;
static void check(bool ok, const char *what, long got, long want) {
	if (ok) return;
	failures++;
	printf("  FAIL %s: got %ld want %ld\n", what, got, want);
}

int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	int enable = argc > 1 ? atoi(argv[1]) : 0;
	int hsize  = argc > 2 ? atoi(argv[2]) : 0;
	int hpos   = argc > 3 ? atoi(argv[3]) : 0;
	int vshift = argc > 4 ? atoi(argv[4]) : 0;
	int vstep  = argc > 5 ? atoi(argv[5]) : 0;
	int vsmode = argc > 6 ? atoi(argv[6]) : 0;
	int mode1  = argc > 7 ? atoi(argv[7]) : 0;
	int flat   = argc > 8 ? atoi(argv[8]) : 0;   // 1: every active pixel is 0x9A5C33 and every DE pixel out must equal it

	// geometry (Gunnail rbf: mode 0 = 512/12, mode 1 = 384/16 -- same 6144 clk line)
	const int HT   = mode1 ? 384 : 512;
	const int DIV  = mode1 ? 16 : 12;
	const int X0   = mode1 ? 92 : 28;
	const int AW   = mode1 ? 256 : 384;
	const int HS0  = mode1 ? 20 : 440, HSW = mode1 ? 24 : 32;
	const int VT = 278, Y0 = 16, AH = 224, VS0 = 264, VSW = 3;
	const int LINE_CLK = HT * DIV;   // 6144

	Vcrt_chain top{&ctx};
	top.clk = 0; top.ce_in = 0; top.rgb_in = 0; top.hs_in = 0; top.vs_in = 0; top.hb_in = 1; top.vb_in = 1;
	top.mode1 = mode1; top.enable = 0;
	top.hsize = hsize & 0x1f; top.hpos_raw = hpos & 0x7f; top.vshift = vshift & 0x1f;
	const int VSIZE_MAX = 7;   // must match the Makefile's -GVSIZE_MAX
	top.vsize_code = (vstep >= 0) ? vstep : vstep + (2 * VSIZE_MAX + 1);
	top.vsize_mode = vsmode;
	top.eval();

	// write-side raster
	int div = 0, hc = 0, vc = 0, frame = 0;
	// recording of in/out streams (per clk) for the identity check
	struct S { unsigned rgb; unsigned char ce, hs, vs, hb, vb; };
	std::vector<S> in_s, out_s;
	// output measurements
	long clk = 0;
	int o_ce_prev = 0, o_hs_prev = 0, o_vs_prev = 0, o_de_prev = 0;
	long last_ce = -1, last_hs = -1, last_vs = -1;
	long ce_period_sum = 0, ce_period_n = 0;
	long hs_period = 0, vs_period = 0;
	long de_start_clk = -1, de_width = 0, de_width_seen = 0;
	long hs_rel_de = -999999;     // hs rise clk - de start clk of that line
	int lines_in_frame = 0, de_lines = 0, de_lines_seen = 0, lines_seen = 0;
	long vs_line_rel = -999999;   // lines from the frame's first DE line to the vs rise
	int line_idx = 0, first_de_line = -1, last_de_line = -1, first_seen = -1, last_seen = -1;
	long frames_out = 0;
	int o_line_has_de = 0;
	long flat_bad = 0;
	// per-line trace (last frame): clocks with DE / hb low / vb low, chain output and stage 1
	struct LT { long de, hbl, vbl, zde, zvbl; };
	std::vector<LT> lt_out, lt_z, lf_out, lf_z; LT cur_o{0,0,0,0,0}, cur_z{0,0,0,0,0};
	bool trace_on = getenv("TB_TRACE") != nullptr;
	// stage-1 (crt_vsize) bookkeeping: DE lines and lines per frame at its output
	int z_hs_prev = 0, z_vs_prev = 0, z_de_prev = 0, z_line_has_de = 0, z_lines = 0, z_de_lines = 0, z_lines_seen = 0, z_de_lines_seen = 0, z_first = -1, z_last = -1, z_first_seen = -1, z_last_seen = -1, z_idx = 0;

	const long FRAMES = 14;        // crt_vsize needs 2 stable frames + the slew (1 line / frame)
	const long TOTAL = (long)LINE_CLK * VT * FRAMES;
	for (long t = 0; t < TOTAL; t++) {
		// ---- drive one clock ----
		top.clk = 0; top.eval();
		bool ce = (div == 0);
		bool hb = !(hc >= X0 && hc < X0 + AW);
		bool vb = !(vc >= Y0 && vc < Y0 + AH);
		bool hs = (hc >= HS0 && hc < HS0 + HSW);
		bool vs = (vc >= VS0 && vc < VS0 + VSW);
		// VBlank with its edges aligned to the sync pulse (video_retime's vb_hs_r):
		// where the pulse follows the active area (hires), from the hsync start on
		// it already reads as the NEXT line's blanking; where it precedes it
		// (lowres) it is the native VBlank.
		int vc_n = (hc >= X0 + AW) ? ((vc + 1) % VT) : vc;   // from the active end on: the next row's blanking
		bool vb_hs = !(vc_n >= Y0 && vc_n < Y0 + AH);
		unsigned rgb = (hb || vb) ? 0 : (flat ? 0x9A5C33u : (((((hc - X0) * 3 + (vc - Y0) * 7 + frame * 11) & 0xff) * 0x010101u) | 0x808080u));
		top.ce_in = ce; top.hb_in = hb; top.vb_in = vb; top.vb_hs_in = vb_hs; top.hs_in = hs; top.vs_in = vs; top.rgb_in = rgb;
		top.enable = (t > LINE_CLK * 2) ? enable : 0;
		top.clk = 1; top.eval();
		clk++;
		if (t >= LINE_CLK * VT * 2) in_s.push_back({rgb, (unsigned char)ce, (unsigned char)hs, (unsigned char)vs, (unsigned char)hb, (unsigned char)vb});
		if (t >= LINE_CLK * VT * 2) out_s.push_back({(unsigned)top.rgb_out, (unsigned char)top.ce_out, (unsigned char)top.hs_out, (unsigned char)top.vs_out, (unsigned char)top.hb_out, (unsigned char)top.vb_out});

		// ---- measure the output during the last 4 frames ----
		bool meas = t >= LINE_CLK * VT * (FRAMES - 4);
		int o_ce = top.ce_out, o_hs = top.hs_out, o_vs = top.vs_out;
		int o_de = !top.hb_out && !top.vb_out;   // a LEVEL (the blanks), not the ce pulse
		if (meas && flat && o_ce && o_de && (unsigned)top.rgb_out != 0x9A5C33u) { if (flat_bad < 5) printf("  flat-colour mismatch: out %06x at clk %ld\n", (unsigned)top.rgb_out, clk); flat_bad++; }
		if (meas) {
			if (o_ce) { if (last_ce >= 0) { ce_period_sum += clk - last_ce; ce_period_n++; } last_ce = clk; }
			// DE level: start / width of this line's active window
			if (o_de && !o_de_prev) { de_start_clk = clk; o_line_has_de = 1; }
			if (!o_de && o_de_prev) { de_width_seen = clk - de_start_clk; }
			// HSync rise ends the line in progress (index line_idx); its DE start
			// preceded it on the same line, so hs - de_start is measured here.
			if (o_hs && !o_hs_prev) {
				if (last_hs >= 0) hs_period = clk - last_hs;
				last_hs = clk;
				if (o_line_has_de) {
					de_lines++;
					if (first_de_line < 0) first_de_line = line_idx;
					last_de_line = line_idx;
					hs_rel_de = clk - de_start_clk;
				}
				o_line_has_de = 0;
				lines_in_frame++; line_idx++;
			}
			if (o_vs && !o_vs_prev) {
				if (last_vs >= 0) { vs_period = clk - last_vs; lines_seen = lines_in_frame; de_lines_seen = de_lines; frames_out++; first_seen = first_de_line; last_seen = last_de_line; }
				if (first_de_line >= 0) vs_line_rel = line_idx - first_de_line;
				last_vs = clk; lines_in_frame = 0; de_lines = 0; first_de_line = -1; last_de_line = -1; line_idx = 0;
			}
		}
		if (meas && trace_on) {
			cur_o.de += (!top.hb_out && !top.vb_out); cur_o.hbl += !top.hb_out; cur_o.vbl += !top.vb_out;
			cur_z.zde += top.dbg_vz_de; cur_z.zvbl += !top.dbg_vz_vb;
			if (o_hs && !o_hs_prev) { lt_out.push_back(cur_o); cur_o = LT{0,0,0,0,0}; }
			if (top.dbg_vz_hs && !z_hs_prev) { lt_z.push_back(cur_z); cur_z = LT{0,0,0,0,0}; }
			if (o_vs && !o_vs_prev) { if (lt_out.size() > 100) lf_out = lt_out; lt_out.clear(); }
			if (top.dbg_vz_vs && !z_vs_prev) { if (lt_z.size() > 100) lf_z = lt_z; lt_z.clear(); }
		}
		o_ce_prev = o_ce; o_hs_prev = o_hs; o_vs_prev = o_vs; o_de_prev = o_de;
		if (meas) {
			int z_de = top.dbg_vz_de;
			if (z_de && !z_de_prev) z_line_has_de = 1;
			if (top.dbg_vz_hs && !z_hs_prev) { if (z_line_has_de) { z_de_lines++; if (z_first < 0) z_first = z_idx; z_last = z_idx; } z_line_has_de = 0; z_lines++; z_idx++; }
			if (top.dbg_vz_vs && !z_vs_prev) { z_lines_seen = z_lines; z_de_lines_seen = z_de_lines; z_first_seen = z_first; z_last_seen = z_last; z_lines = 0; z_de_lines = 0; z_first = -1; z_last = -1; z_idx = 0; }
			z_hs_prev = top.dbg_vz_hs; z_vs_prev = top.dbg_vz_vs; z_de_prev = z_de;
		}

		// ---- advance the raster ----
		if (++div == DIV) { div = 0; if (++hc == HT) { hc = 0; if (++vc == VT) { vc = 0; frame++; } } }
	}

	// ---- expectations ----
	int base_q = 4 * DIV;
	const long HS_REL_NOM = (long)((HS0 - X0 + HT) % HT) * DIV;   // DE start -> next hsync rise
	// vs rise sits at pixel 0 of row VS0; counted in hsync-delimited intervals that is one
	// interval earlier when the sync pulse precedes the active area on its row (lowres)
	const long VS_REL_NOM = VS0 - Y0 - ((HS0 < X0) ? 1 : 0);
	int hpos_px = (hpos <= 48) ? hpos : hpos - 97;
	int vsize_lines = -3 * vstep;   // lines added to the frame (crt_vsize convention)
	double ce_period = ce_period_n ? (double)ce_period_sum / ce_period_n : 0;
	printf("enable=%d hsize=%d hpos=%d(%+d px) vshift=%d vsize_step=%d(%+d lines) mode=%s mode1=%d\n",
	       enable, hsize, hpos, hpos_px, vshift, vstep, vsize_lines, vsmode ? "Cabinet" : "PVM", mode1);
	printf("  out: ce period %.3f clk, hs period %ld clk, vs period %ld clk, lines/frame %d, DE lines %d, DE width %ld clk, hs rise - de start %ld clk, vs line - first DE line %ld\n",
	       ce_period, hs_period, vs_period, lines_seen, de_lines_seen, de_width_seen, hs_rel_de, vs_line_rel);
	printf("  DE lines span (line index after vs): first %d last %d\n", first_seen, last_seen);
	printf("  stage 1 (crt_vsize) output: lines/frame %d, DE lines %d, span first %d last %d\n", z_lines_seen, z_de_lines_seen, z_first_seen, z_last_seen);
	if (trace_on) {
		printf("  per-line trace (line: stage1 de/vbl clocks | out de/hbl/vbl clocks)\n");
		for (size_t i = 26; i < 36 && i < lf_out.size() && i < lf_z.size(); i++)
			printf("    %3zu: z de %5ld vbl %5ld | out de %5ld hbl %5ld vbl %5ld\n", i, lf_z[i].zde, lf_z[i].zvbl, lf_out[i].de, lf_out[i].hbl, lf_out[i].vbl);
		for (size_t i = 249; i < 257 && i < lf_out.size() && i < lf_z.size(); i++)
			printf("    %3zu: z de %5ld vbl %5ld | out de %5ld hbl %5ld vbl %5ld\n", i, lf_z[i].zde, lf_z[i].zvbl, lf_out[i].de, lf_out[i].hbl, lf_out[i].vbl);
	}

	// frame period never changes
	check(vs_period == (long)LINE_CLK * VT, "vs period", vs_period, (long)LINE_CLK * VT);
	if (!enable || (hsize == 0 && hpos_px == 0 && vshift == 0 && vstep == 0)) {
		// Off, or On at zero: identical geometry, uniform pixels
		check(hs_period == LINE_CLK, "hs period", hs_period, LINE_CLK);
		check(lines_seen == VT, "lines/frame", lines_seen, VT);
		check(de_lines_seen == AH, "DE lines", de_lines_seen, AH);
		check(de_width_seen == (long)AW * DIV, "DE width", de_width_seen, (long)AW * DIV);
		// On at zero: crt_adjust's registered read side places DE one native
		// pixel earlier relative to HSync than the native stream (a constant
		// the user's H-Position absorbs); Off must be exact.
		long hs_tol = enable ? DIV : 0;
		check(labs(hs_rel_de - HS_REL_NOM) <= hs_tol, "hs rise - de start", hs_rel_de, HS_REL_NOM);
		// On: the module re-times VSync onto an HSync rise, so the two edges
		// coincide and this interval count is +-1 ambiguous; Off must be exact.
		check(labs(vs_line_rel - VS_REL_NOM) <= (enable ? 1 : 0), "vs line - first DE line", vs_line_rel, VS_REL_NOM);
		// stream identity: find the constant lag that makes out == in
		// (On at zero: content and DE; the syncs carry the constant offset above)
		long best_lag = -1;
		for (long lag = 0; lag < 2 * LINE_CLK && best_lag < 0; lag++) {
			bool same = true;
			for (size_t i = 0; i + lag < in_s.size() && same; i += 1) {
				const S &a = in_s[i], &b = out_s[i + lag];
				if (a.ce != b.ce) { same = false; break; }
				// DE (the combined blank) rather than hb alone: while On the chain
				// hands on a combined HBlank; rgb only inside DE.
				bool ade = !(a.hb | a.vb), bde = !(b.hb | b.vb);
				if (a.ce && (ade != bde || (ade && a.rgb != b.rgb))) same = false;
				if (a.ce && !enable && (a.hs != b.hs || a.vs != b.vs || a.hb != b.hb || a.vb != b.vb)) same = false;
			}
			if (same) best_lag = lag;
		}
		if (best_lag < 0) {   // diagnose at the geometric lag: first mismatching sample
			long lag = enable ? LINE_CLK + 3 * DIV + 1 : 0;
			for (size_t i = 0; i + lag < in_s.size(); i++) {
				const S &a = in_s[i], &b = out_s[i + lag];
				if (!a.ce) continue;
				bool ade = !(a.hb | a.vb), bde = !(b.hb | b.vb);
				if (a.ce != b.ce || ade != bde || (ade && a.rgb != b.rgb)) {
					long px = i / DIV, line = (px / HT) % VT, x = px % HT;
					printf("  first mismatch at lag %ld: in line %ld x %ld: ce %d/%d de %d/%d rgb %06x/%06x\n", lag, line, x, a.ce, b.ce, ade, bde, a.rgb, b.rgb);
					break;
				}
			}
		}
		printf("  stream identity vs input: %s (lag %ld clk)\n", best_lag >= 0 ? "IDENTICAL" : "DIFFERENT", best_lag);
		check(best_lag >= 0, "stream identity", best_lag, 0);
	} else {
		if (vstep == 0) {
			check(hs_period == LINE_CLK, "hs period", hs_period, LINE_CLK);
			check(lines_seen == VT, "lines/frame", lines_seen, VT);
			check(de_lines_seen == AH, "DE lines", de_lines_seen, AH);
		}
		// H-Position: "+" = picture right = the sync pulse N native pixels
		// EARLIER, content anchored -> the next hsync rise after a DE start
		// comes N px sooner, and the read engine's line starts N px earlier
		// so the active window sits N px further from it.
		long hb1 = (X0 - HS0 + HT) % HT + hpos_px;   // read ticks from the engine's line start to the DE start
		long hb0 = hb1 + AW;
		// H-Size: pixel period (base_q + hsize) / 4 clk; the active window is
		// cut where it runs past the next sync pulse (the line period is native).
		double p = (base_q + hsize) / 4.0;
		long want_start = (long)(hb1 * p), want_end = (long)(hb0 * p);
		if (want_end > (long)HT * DIV) want_end = (long)HT * DIV;
		long want_w = want_end - want_start;
		// exact to the pixel: a V-Size ring exactly as wide as the line once lost the last column
		check(labs(de_width_seen - want_w) <= (hsize ? 2 * DIV : 2), "DE width (H-Size, truncated at the next sync)", de_width_seen, want_w);
		long want_hs = (long)HT * DIV - want_start;
		if (vstep == 0) check(labs(hs_rel_de - want_hs) <= 2 * DIV, "hs rise - de start (H-Position)", hs_rel_de, want_hs);
		// V-Shift: "+" = picture down = VSync N lines EARLIER
		if (vstep == 0) check(labs(vs_line_rel - (VS_REL_NOM - vshift)) <= 1, "vs line - first DE line (V-Shift)", vs_line_rel, VS_REL_NOM - vshift);
		// V-Size
		if (vstep != 0) {
			if (vsmode == 0) {   // PVM: lines per frame change, frame period does not
				check(lines_seen == VT + vsize_lines, "lines/frame (V-Size PVM)", lines_seen, VT + vsize_lines);
				check(de_lines_seen == AH, "DE lines (PVM keeps every line)", de_lines_seen, AH);
				long want_hs_period = (long)LINE_CLK * VT / (VT + vsize_lines);
				// crt_adjust re-times HSync onto its pixel-enable grid, so a period measured
				// on the chain output can differ from the retimer's ideal by one pixel period
				check(labs(hs_period - want_hs_period) <= DIV + 1, "hs period (PVM)", hs_period, want_hs_period);
			} else {             // Cabinet: native timing, active lines change
				check(hs_period == LINE_CLK, "hs period (Cabinet native)", hs_period, LINE_CLK);
				check(lines_seen == VT, "lines/frame (Cabinet native)", lines_seen, VT);
				check(de_lines_seen == AH - vsize_lines, "DE lines (Cabinet)", de_lines_seen, AH - vsize_lines);
			}
		}
	}
	if (flat) { printf("  flat colour: %ld DE pixels wrong\n", flat_bad); check(flat_bad == 0, "flat colour pixels", flat_bad, 0); }
	printf("%s\n", failures ? "FAIL" : "PASS");
	return failures ? 1 : 0;
}
