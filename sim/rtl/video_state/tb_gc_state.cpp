// Render one frame from a MAME video-state dump through the FULL
// rtl/gunnail/gunnail_core.sv (HW_ROMS=0, VIDEO_ONLY=1), so every per-game
// mux is the shipping one rather than a hand-mirrored standalone
// video_macross2. The state is injected by the core's own STATE_* params;
// the 68000 is held in reset so nothing overwrites it.
//   argv[1] = output ppm     env VS_WIDTH (default 256), VS_FRAMES
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include "Vgunnail_core.h"
#include "verilated.h"
int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	Vgunnail_core top{&ctx};
	const char *out = argc > 1 ? argv[1] : "gc_state.ppm";
	const unsigned width  = std::getenv("VS_WIDTH")  ? atoi(std::getenv("VS_WIDTH"))  : 256;
	const unsigned frames = std::getenv("VS_FRAMES") ? atoi(std::getenv("VS_FRAMES")) : 6;
	auto tick = [&]() { top.clk_sys = 0; top.eval(); top.clk_sys = 1; top.eval(); };
	top.reset = 1;
	top.game_sel = std::getenv("VS_GAME_SEL") ? atoi(std::getenv("VS_GAME_SEL")) : 52;
	top.ioctl_download = 0; top.ioctl_wr = 0; top.ioctl_addr = 0; top.ioctl_dout = 0; top.ioctl_index = 0;
	top.in0_i = 0xFFFF; top.in1_i = 0xFFFF; top.dsw1_i = 0xFFFF; top.dsw2_i = 0xFFFF;
	top.sd0_dout = 0; top.sd0_dout_pair = 0; top.sd0_ack = 0;
	top.sd1_dout = 0; top.sd1_dout_pair = 0; top.sd1_ack = 0;
	top.sd2_dout = 0; top.sd2_dout_pair = 0; top.sd2_ack = 0;
	top.sd3_dout = 0; top.sd3_dout_pair = 0; top.sd3_ack = 0;
	top.rd_x = 0; top.rd_y = 0;
	for (int i = 0; i < 64; i++) tick();
	top.reset = 0;
	// let the video timing run: each frame is ~711k clk_sys cycles, and the
	// sprite plane is only shown after the following frame's DMA swap.
	for (unsigned f = 0; f < frames; f++)
		for (int i = 0; i < 720000; i++) tick();
	FILE *fp = fopen(out, "wb"); fprintf(fp, "P6\n%u 224\n255\n", width);
	for (int y = 0; y < 224; y++) for (unsigned x = 0; x < width; x++) {
		top.rd_x = x; top.rd_y = y; top.eval();
		uint32_t rgb = top.rd_rgb;
		uint8_t px[3] = {(uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb};
		fwrite(px, 1, 3, fp);
	}
	fclose(fp); printf("wrote %s (%ux224)\n", out, width); return 0;
}
