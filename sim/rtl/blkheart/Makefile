# Verilator build for the blkheart system-level integration (the third
# Tier 2 NMK004-board game, after sim/rtl/mustang/'s and
# sim/rtl/bioship/'s own — see rtl/blkheart/blkheart_core.sv's header
# for what's different).
#
# Usage:
#   make rom        # (re)build the 68000 program ROM hex from mame_roms/blkheart.zip
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
CORE_DIR := ../../../rtl/blkheart
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := blkheart_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_blkheart.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/blkheart.zip --hi blkhrt.7 --lo blkhrt.6 --out roms/blkheart_maincpu.hex

# 4.bin is blkheart's own NMK004 external program (the shared 8K
# internal boot ROM lives in sim/rtl/tlcs90/roms/nmk004_boot.hex already
# — see blkheart_core.sv's header).
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/blkheart.zip --mode concat --files 4.bin --out ../tlcs90/roms/blkheart_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/blkheart.zip --mode concat --files 90068-2.bin --out roms/blkheart_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/blkheart.zip --mode concat --files 90068-1.bin --out roms/blkheart_oki2.hex

vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/blkheart.zip --mode concat --files 9.bpr --out roms/blkheart_vtiming.hex

# 90068-8.bin is ROM_LOAD16_WORD_SWAP (see tools/mkgfxrom.py's own
# word_swap mode and blkheart_core.sv's header for the derivation).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/blkheart.zip --mode concat --files 3.bin --out roms/blkheart_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/blkheart.zip --mode concat --files 90068-5.bin --out roms/blkheart_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/blkheart.zip --mode word_swap --files 90068-8.bin --out roms/blkheart_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_blkheart.cpp $(FX68K_DIR)/fx68k.sv roms/blkheart_maincpu.hex roms/blkheart_oki1.hex roms/blkheart_oki2.hex roms/blkheart_vtiming.hex roms/blkheart_fgtile.hex roms/blkheart_bgtile.hex roms/blkheart_sprites.hex ../tlcs90/roms/blkheart_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/blkheart_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/blkheart_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/blkheart_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/blkheart_oki2.hex\" \
		-GVTIMING_FILE=\"roms/blkheart_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/blkheart_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/blkheart_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/blkheart_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_blkheart.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
