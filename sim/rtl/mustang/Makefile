# Verilator build for the mustang system-level integration milestone
# (rtl/mustang/mustang_core.sv). See that module's header and
# docs/tier2-tlcs90.md for what this proves and what's still missing.
#
# Usage:
#   make rom    # (re)build the 68000 program ROM hex from mame_roms/mustang.zip
#   make run    # build and run, produces nmk004_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
TLCS90_DIR := ../../../rtl/tlcs90
CORE_DIR := ../../../rtl/mustang
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := mustang_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv

.PHONY: all rom run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/mustang.zip --hi 2.bin --lo 3.bin --out roms/mustang_maincpu.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_mustang.cpp $(FX68K_DIR)/fx68k.sv roms/mustang_maincpu.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) \
		-GROM_FILE=\"roms/mustang_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/mustang_ext.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_mustang.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
