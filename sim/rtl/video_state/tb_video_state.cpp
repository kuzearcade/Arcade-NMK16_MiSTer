// Render one frame from a MAME video-state dump and write it as PPM.
// argv[1] = tilebank (hex), argv[2] = output ppm
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include "Vvideo_state_top.h"
#include "verilated.h"
int main(int argc, char **argv) {
	VerilatedContext ctx; ctx.commandArgs(argc, argv);
	Vvideo_state_top top{&ctx};
	unsigned tilebank = argc > 1 ? strtoul(argv[1], nullptr, 16) : 0;
	const char *out = argc > 2 ? argv[2] : "video_state.ppm";
	auto tick = [&]() { top.clk_sys = 0; top.eval(); top.clk_sys = 1; top.eval(); };
	top.reset = 1; top.bg_bank = tilebank; top.tilerambank = 0; top.sprite_dma_trigger = 0; top.rd_x = 0; top.rd_y = 0;
	for (int i = 0; i < 20; i++) tick();
	top.reset = 0;
	for (int i = 0; i < 400000; i++) tick();           // sprite plane clear
	// The drawn plane is shown after the NEXT trigger (the swap happens at
	// the following frame's DMA), so pulse twice: draw, then swap.
	for (int k = 0; k < 2; k++) {
		top.sprite_dma_trigger = 1; tick(); top.sprite_dma_trigger = 0;
		for (int i = 0; i < 2500000; i++) tick();      // snapshot + draw pass (well past one frame)
	}
	FILE *f = fopen(out, "wb"); fprintf(f, "P6\n384 224\n255\n");
	for (int y = 0; y < 224; y++) for (int x = 0; x < 384; x++) {
		top.rd_x = x; top.rd_y = y; top.eval();
		uint32_t rgb = top.rd_rgb; uint8_t px[3] = {(uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb}; fwrite(px, 1, 3, f);
	}
	fclose(f); printf("wrote %s\n", out); return 0;
}
