# Verilator build for the bioship system-level integration (the second
# Tier 2 NMK004-board game, after sim/rtl/mustang/'s own — see
# rtl/bioship/bioship_core.sv's header for what's different).
#
# Usage:
#   make rom       # (re)build the 68000 program ROM hex from mame_roms/bioship.zip
#   make ext-rom    # (re)build NMK004's own external program ROM
#   make oki-roms   # (re)build the OKIM6295 x2 sample ROMs
#   make vtiming-rom # (re)build the real V-timing PROM
#   make gfx-roms   # (re)build fgtile/bgtile/bg2tile/sprites/tilerom
#   make run        # build and run, produces nmk004_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
CORE_DIR := ../../../rtl/bioship
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := bioship_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_bioship.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/bioship.zip --hi 2.ic14 --lo 1.ic15 --out roms/bioship_maincpu.hex

# 6.ic120 is bioship's own NMK004 external program (the shared 8K
# internal boot ROM lives in sim/rtl/tlcs90/roms/nmk004_boot.hex already,
# same device ROM every NMK004-family game reuses — see
# bioship_core.sv's header).
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files 6.ic120 --out ../tlcs90/roms/bioship_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files sbs-g_04.ic139 --out roms/bioship_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files sbs-g_05.ic160 --out roms/bioship_oki2.hex

vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files 82s135.ic94 --out roms/bioship_vtiming.hex

# sbs-g_01/02/03 are bioship's real graphics ROMs (fgtile/bg2tile/sprites
# — see rtl/bioship/video_bioship.sv); "7" is fgtile (TX); 8.ic27/9.ic26
# interleaved is the ROM tile-INDEX map for BG0 (not graphics data).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files 7 --out roms/bioship_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files sbs-g_01.ic9 --out roms/bioship_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files sbs-g_02.ic4 --out roms/bioship_bg2tile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/bioship.zip --mode concat --files sbs-g_03.ic194 --out roms/bioship_sprites.hex
	# tilerom is a genuine ROM_LOAD16_BYTE hi/lo pair (16-bit tile-index
	# words, not a byte-addressed gfx_layout ROM) — mkrom.py, not
	# mkgfxrom.py --mode interleave16 (which stays byte-per-line even in
	# that mode — see tools/mkgfxrom.py's own docstring).
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/bioship.zip --hi 8.ic27 --lo 9.ic26 --out roms/bioship_tilerom.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_bioship.cpp $(FX68K_DIR)/fx68k.sv roms/bioship_maincpu.hex roms/bioship_oki1.hex roms/bioship_oki2.hex roms/bioship_vtiming.hex roms/bioship_fgtile.hex roms/bioship_bgtile.hex roms/bioship_bg2tile.hex roms/bioship_sprites.hex roms/bioship_tilerom.hex ../tlcs90/roms/bioship_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/bioship_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/bioship_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/bioship_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/bioship_oki2.hex\" \
		-GVTIMING_FILE=\"roms/bioship_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/bioship_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/bioship_bgtile.hex\" \
		-GBG2TILE_FILE=\"roms/bioship_bg2tile.hex\" \
		-GSPRITES_FILE=\"roms/bioship_sprites.hex\" \
		-GTILEROM_FILE=\"roms/bioship_tilerom.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_bioship.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
