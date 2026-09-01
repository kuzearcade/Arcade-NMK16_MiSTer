# Verilator build for the mustang system-level integration milestone
# (rtl/mustang/mustang_core.sv). See that module's header and
# docs/tier2-tlcs90.md for what this proves and what's still missing.
#
# Usage:
#   make rom    # (re)build the 68000 program ROM hex from mame_roms/mustang.zip
#   make run    # build and run, produces nmk004_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
CORE_DIR := ../../../rtl/mustang
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := mustang_core

# video_timing.sv/nmk_irq_hacky.sv are reused unchanged from Tier 1's
# bjtwin — see mustang_core.sv's header for why the same "lowres" family
# constants and fixed-scanline IRQ table apply here too. jt03.v is jt12's
# own YM2203 top-level (see rtl/third_party/jt12/README.md's "Usage"
# table); its many internal jt12_*.v/jt49_*.v dependencies are resolved
# via -y directory search below rather than listed individually, matching
# every file's own module name (the same convention the upstream .qip
# file lists explicitly — jt12.vhd from that list is a VHDL-only
# component-declaration package, irrelevant to this Verilog-only build).
SOURCES := $(CORE_DIR)/$(TOP).sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv \
           $(JT12_DIR)/hdl/jt03.v

.PHONY: all rom run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/mustang.zip --hi 2.bin --lo 3.bin --out roms/mustang_maincpu.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_mustang.cpp $(FX68K_DIR)/fx68k.sv roms/mustang_maincpu.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl \
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
