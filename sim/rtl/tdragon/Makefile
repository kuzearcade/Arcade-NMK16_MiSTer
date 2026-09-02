# Verilator build for the tdragon system-level integration (the sixth
# Tier 2 NMK004-board game, after sim/rtl/mustang/, sim/rtl/bioship/,
# sim/rtl/blkheart/, sim/rtl/strahl/, and sim/rtl/acrobatm/'s own — see
# rtl/tdragon/tdragon_core.sv's header for what's different: blkheart's
# own video/clock/sprite-ROM architecture, but a genuinely different
# memory map with real address mirroring, and a different V-PROM).
#
# Usage:
#   make rom        # (re)build the 68000 program ROM hex from mame_roms/tdragon.zip
#   make ext-rom     # (re)build NMK004's own external program ROM
#   make oki-roms    # (re)build the OKIM6295 x2 sample ROMs
#   make vtiming-rom # (re)build the real V-timing PROM
#   make gfx-roms    # (re)build fgtile/bgtile/sprites
#   make run         # build and run, produces nmk004_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
CORE_DIR := ../../../rtl/tdragon
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := tdragon_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_tdragon.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/tdragon.zip --hi 91070_68k.8 --lo 91070_68k.7 --out roms/tdragon_maincpu.hex

# 91070.1 is tdragon's own NMK004 external program (the shared 8K
# internal boot ROM lives in sim/rtl/tlcs90/roms/nmk004_boot.hex already
# — see tdragon_core.sv's header).
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.1 --out ../tlcs90/roms/tdragon_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.3 --out roms/tdragon_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.2 --out roms/tdragon_oki2.hex

# 91070.10 is tdragon's own real V-timing PROM (see rtl/nmk_irq/nmk_irq.sv)
# — a genuinely DIFFERENT CRC from every prior port's own dumped copy.
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.10 --out roms/tdragon_vtiming.hex

# 91070.4 is ROM_LOAD16_WORD_SWAP (see tools/mkgfxrom.py's own
# word_swap mode and tdragon_core.sv's header — same convention as
# blkheart's own sprite ROM).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.6 --out roms/tdragon_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.5 --out roms/tdragon_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode word_swap --files 91070.4 --out roms/tdragon_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_tdragon.cpp $(FX68K_DIR)/fx68k.sv roms/tdragon_maincpu.hex roms/tdragon_oki1.hex roms/tdragon_oki2.hex roms/tdragon_vtiming.hex roms/tdragon_fgtile.hex roms/tdragon_bgtile.hex roms/tdragon_sprites.hex ../tlcs90/roms/tdragon_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/tdragon_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/tdragon_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/tdragon_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/tdragon_oki2.hex\" \
		-GVTIMING_FILE=\"roms/tdragon_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/tdragon_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/tdragon_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/tdragon_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_tdragon.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
