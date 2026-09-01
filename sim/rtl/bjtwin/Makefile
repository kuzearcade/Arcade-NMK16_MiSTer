# Verilator build for the bjtwin-family Tier 1 core (CPU/memory + video).
# See docs/PLAN.md and docs/tier1-bjtwin.md for what this proves.
#
# Usage:
#   make rom       # (re)build the 68000 program ROM hex from mame_roms/cactus.zip
#   make gfxrom    # (re)build fgtile/bgtile/sprites ROM hexes (fgtile needs
#                    the sabotenb.zip parent set, see docs/rom-audit.md)
#   make run       # build and run, produces cactus_rtl.trace (B + F lines)
#   make check     # run, then diff cactus_rtl.trace against the real MAME oracle trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
CORE_DIR := ../../../rtl/bjtwin
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := bjtwin_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/nmk_irq_hacky.sv $(CORE_DIR)/video_timing.sv $(CORE_DIR)/video_bjtwin.sv

.PHONY: all rom gfxrom run check clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/cactus.zip --hi 02.bin --lo 01.bin --out roms/cactus_maincpu.hex

gfxrom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/cactus.zip --zip $(ROMS_DIR)/sabotenb.zip --mode concat --files ic35.sb3 --out roms/cactus_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/cactus.zip --mode concat --files s-05.bin s-06.bin --out roms/cactus_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/cactus.zip --mode interleave16 --hi s-04.bin --lo s-03.bin --out roms/cactus_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_bjtwin.cpp ../common/nmktrace.h ../common/crc32.h $(FX68K_DIR)/fx68k.sv
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(CORE_DIR) \
		-GROM_FILE=\"roms/cactus_maincpu.hex\" \
		-GFGTILE_FILE=\"roms/cactus_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/cactus_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/cactus_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_bjtwin.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

check: run
	python3 ../../../sim/compare/oracle_diff.py ../../../sim/oracle/traces/cactus_io.trace cactus_rtl.trace --cycle-tolerance 100000

clean:
	rm -rf $(OBJ_DIR) cactus_rtl.trace microrom.mem nanorom.mem
