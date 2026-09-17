// Drive video_mixer with the exact gunnail M0 raster and measure the output DE
// width per line. M0: 512 total / 384 active, X0=28, HS 440..471, 6 clk_vid per
// pixel at 48 MHz. Switchable to M1 (lowres): 384 total / 256 active, X0=92,
// HS 20..43, 8 clk per pixel -- the case that already works, as a control.
#include "Vvideo_mixer.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <map>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    bool m1   = getenv("M1") != nullptr;
    bool hq2x = getenv("NOHQ") == nullptr;
    int HT  = m1 ? 384 : 512, X0 = m1 ? 92 : 28, AW = m1 ? 256 : 384;
    int HS0 = m1 ? 20 : 440, HW = m1 ? 24 : 32, DIV = m1 ? 8 : 6;
    int VT = 264, VA = 224;

    Vvideo_mixer* t = new Vvideo_mixer;
    t->scandoubler = 1; t->hq2x = hq2x; t->HDMI_FREEZE = 0;
    t->gamma_bus = 0;

    int hc = 0, vc = 0, div = 0;
    long prev_de = 0; int de_run = 0;
    std::map<int,int> widths;   // output DE run length -> count

    for (long i = 0; i < 40000000L; i++) {
        // input raster at clk_vid, one ce_pix every DIV clocks
        int ce = (div == 0);
        t->ce_pix = ce;
        if (ce) {
            int hact = (hc >= X0) && (hc < X0 + AW);
            int vact = (vc < VA);
            t->HBlank = !hact; t->VBlank = !vact;
            t->HSync  = (hc >= HS0) && (hc < HS0 + HW);
            t->VSync  = (vc >= VA + 10) && (vc < VA + 13);
            t->R = hact ? (hc & 0xFF) : 0;
            t->G = hact ? (vc & 0xFF) : 0;
            t->B = hact ? 0x40 : 0;
        }
        t->CLK_VIDEO = 0; t->eval();
        t->CLK_VIDEO = 1; t->eval();

        if (t->CE_PIXEL) {
            if (t->VGA_DE) de_run++;
            else if (de_run) { widths[de_run]++; de_run = 0; }
        }
        if (ce) {
            if (++hc >= HT) { hc = 0; if (++vc >= VT) vc = 0; }
        }
        div = (div + 1) % DIV;
    }
    printf("mode=%s hq2x=%d  input active=%d\n", m1 ? "M1(256)" : "M0(384)", hq2x, AW);
    printf("output DE run lengths (length: count), top 6:\n");
    int n = 0;
    for (auto it = widths.rbegin(); it != widths.rend() && n < 6; ++it, ++n)
        printf("   %5d : %d\n", it->first, it->second);
    return 0;
}
