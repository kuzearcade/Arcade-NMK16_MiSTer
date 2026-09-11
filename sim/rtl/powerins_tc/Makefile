# Verilator build for Power Instinct (powerins) running through the SHARED
# Family C core, rtl/tdragon2/tdragon2_core.sv with game_powerins=1 (the
# same module Macross2.rbf ships; see its game_powerins port). HW_ROMS=0:
# zero-latency $readmemh ROMs — the reference sim for MAME frame
# comparisons. The ROM hex files are sim/rtl/powerins/roms/ (symlinked):
#   make -C ../powerins roms
# rebuilds them; roms/tdragon2_powerins_vtiming.hex is the 512-line
# two-table V-PROM file (tdragon2's 10.bpr + powerins' 21.u71) that
# Macross2.sv also synthesises with (table 1 is selected by game_powerins).
#
# Usage:
#   make run          # 300M clk_sys cycles; TB_DUMP_PPM=1 dumps every frame

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
MACROSS2_DIR := ../../../rtl/macross2
CORE_DIR := ../../../rtl/tdragon2
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := tdragon2_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(MACROSS2_DIR)/video_macross2.sv $(NMK112_DIR)/nmk112.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom audiocpu-rom oki-roms vtiming-rom gfx-roms

# maincpu: 6.rom, single ROM_LOAD16_WORD_SWAP file (nmk16.cpp:8333).

roms:
	$(MAKE) -C ../powerins roms
	cp ../../../roms/tdragon2_powerins_vtiming.hex roms/

.PHONY: all roms run clean

all: run

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_powerins_tc.cpp $(FX68K_DIR)/fx68k.sv \
	roms/powerins_maincpu.hex roms/powerins_audiocpu.hex roms/powerins_oki1.hex roms/powerins_oki2.hex \
	roms/tdragon2_powerins_vtiming.hex roms/powerins_fgtile.hex roms/powerins_bgtile.hex roms/powerins_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) $(EXTRA_VFLAGS) \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/powerins_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/powerins_audiocpu.hex\" \
		-GOKI1_ROM_FILE=\"roms/powerins_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/powerins_oki2.hex\" \
		-GVTIMING_FILE=\"roms/tdragon2_powerins_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/powerins_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/powerins_bgtile.hex\" \
		-GSPRITES_BYTES=8388608 -GBGTILE_BYTES=2621440 -GSPRITES_FILE=\"roms/powerins_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_powerins_tc.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) tdragon2_video.trace microrom.mem nanorom.mem
