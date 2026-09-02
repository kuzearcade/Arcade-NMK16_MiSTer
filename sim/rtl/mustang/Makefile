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
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
CORE_DIR := ../../../rtl/mustang
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := mustang_core

# video_timing.sv is reused unchanged from Tier 1's bjtwin — see
# mustang_core.sv's header for why the same "lowres" family constants
# apply here too. nmk_irq.sv is the real dual-PROM-driven interrupt state
# machine (rtl/nmk_irq/, shared across the whole nmk16 family, not
# bjtwin-specific) driven by mustang's own real V-PROM. jt03.v is jt12's
# own YM2203 top-level (see rtl/third_party/jt12/README.md's "Usage"
# table); its many internal jt12_*.v/jt49_*.v dependencies are resolved
# via -y directory search below rather than listed individually, matching
# every file's own module name (the same convention the upstream .qip
# file lists explicitly — jt12.vhd from that list is a VHDL-only
# component-declaration package, irrelevant to this Verilog-only build).
SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_mustang.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/mustang.zip --hi 2.bin --lo 3.bin --out roms/mustang_maincpu.hex

# 90058-5/90058-6 are mustang's real OKIM6295 x2 ADPCM sample ROMs (see
# mustang_core.sv's "Real jt6295 (OKIM6295 x2) integration").
oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --mode concat --files 90058-5 --out roms/mustang_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --mode concat --files 90058-6 --out roms/mustang_oki2.hex

# 10.bpr is mustang's real V-timing PROM (see rtl/nmk_irq/nmk_irq.sv).
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --mode concat --files 10.bpr --out roms/mustang_vtiming.hex

# 90058-1/4/8/9 are mustang's real graphics ROMs (see
# rtl/mustang/video_mustang.sv).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --mode concat --files 90058-1 --out roms/mustang_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --mode concat --files 90058-4 --out roms/mustang_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --mode interleave16 --hi 90058-8 --lo 90058-9 --out roms/mustang_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_mustang.cpp $(FX68K_DIR)/fx68k.sv roms/mustang_maincpu.hex roms/mustang_oki1.hex roms/mustang_oki2.hex roms/mustang_vtiming.hex roms/mustang_fgtile.hex roms/mustang_bgtile.hex roms/mustang_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/mustang_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/mustang_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/mustang_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/mustang_oki2.hex\" \
		-GVTIMING_FILE=\"roms/mustang_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/mustang_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/mustang_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/mustang_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_mustang.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
