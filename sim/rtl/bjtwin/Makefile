# Verilator build for the bjtwin-family CPU+memory milestone (Tier 1).
# See docs/PLAN.md and tb_bjtwin.cpp for what this proves.
#
# Usage:
#   make rom     # (re)build sim/rtl/bjtwin/roms/cactus_maincpu.hex from mame_roms/cactus.zip
#   make run     # build and run, produces cactus_rtl.trace
#   make check   # run, then diff cactus_rtl.trace against the real MAME oracle trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
CORE_DIR := ../../../rtl/bjtwin
OBJ_DIR := obj_dir
TOP := bjtwin_core

.PHONY: all rom run check clean

all: run

rom:
	python3 ../../../tools/mkrom.py --zip ../../../mame_roms/cactus.zip --hi 02.bin --lo 01.bin --out roms/cactus_maincpu.hex

$(OBJ_DIR)/V$(TOP): $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/nmk_irq_hacky.sv tb_bjtwin.cpp ../common/nmktrace.h $(FX68K_DIR)/fx68k.sv
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(CORE_DIR) \
		-GROM_FILE=\"roms/cactus_maincpu.hex\" \
		$(CORE_DIR)/$(TOP).sv $(CORE_DIR)/nmk_irq_hacky.sv $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_bjtwin.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

check: run
	python3 ../../../sim/compare/oracle_diff.py ../../../sim/oracle/traces/cactus_io.trace cactus_rtl.trace --cycle-tolerance 100000

clean:
	rm -rf $(OBJ_DIR) cactus_rtl.trace microrom.mem nanorom.mem
