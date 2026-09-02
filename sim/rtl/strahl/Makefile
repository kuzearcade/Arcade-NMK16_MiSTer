# Verilator build for the strahl system-level integration (the fourth
# Tier 2 NMK004-board game, after sim/rtl/mustang/'s, sim/rtl/bioship/'s,
# and sim/rtl/blkheart/'s own — see rtl/strahl/strahl_core.sv's header
# for what's different, including why this game uses
# rtl/bjtwin/nmk_irq_hacky.sv instead of rtl/nmk_irq/nmk_irq.sv: no real
# V-PROM exists for strahl at all, MAME itself uses a fixed-scanline
# substitute for this game).
#
# Usage:
#   make rom        # (re)build the 68000 program ROM hex from mame_roms/strahl.zip
#   make ext-rom     # (re)build NMK004's own external program ROM
#   make oki-roms    # (re)build the OKIM6295 x2 sample ROMs (segments mode — see header)
#   make gfx-roms    # (re)build fgtile/bgtile/bg2tile/sprites
#   make run         # build and run, produces nmk004_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
CORE_DIR := ../../../rtl/strahl
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := strahl_core

# nmk_irq_hacky.sv (NOT nmk_irq.sv — see header) + video_timing.sv are
# both reused unchanged from Tier 1's bjtwin.
SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_strahl.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom ext-rom oki-roms gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/strahl.zip --hi strahl-02.ic82 --lo strahl-01.ic83 --out roms/strahl_maincpu.hex

# strahl-4.66 is strahl's own NMK004 external program (the shared 8K
# internal boot ROM lives in sim/rtl/tlcs90/roms/nmk004_boot.hex already
# — see strahl_core.sv's header).
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files strahl-4.66 --out ../tlcs90/roms/strahl_ext.hex

# str8pmw1.540/str9pew1.639 are ROM_CONTINUE-scrambled (see
# tools/mkgfxrom.py's own segments mode and strahl_core.sv's header for
# the exact REGION:FILE:LEN triples, taken directly from ROM_START).
oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode segments --files str8pmw1.540 \
		--segments 0x00000:0x00000:0x20000 --segments 0x60000:0x20000:0x20000 \
		--segments 0x40000:0x40000:0x20000 --segments 0x20000:0x60000:0x20000 \
		--out roms/strahl_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode segments --files str9pew1.639 \
		--segments 0x00000:0x00000:0x20000 --segments 0x60000:0x20000:0x20000 \
		--segments 0x40000:0x40000:0x20000 --segments 0x20000:0x60000:0x20000 \
		--out roms/strahl_oki2.hex

gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files strahl-3.73 --out roms/strahl_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files str7b2r0.275 --out roms/strahl_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files str6b1w1.776 --out roms/strahl_bg2tile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files strl3-01.32 strl4-02.57 strl5-03.58 --out roms/strahl_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_strahl.cpp $(FX68K_DIR)/fx68k.sv roms/strahl_maincpu.hex roms/strahl_oki1.hex roms/strahl_oki2.hex roms/strahl_fgtile.hex roms/strahl_bgtile.hex roms/strahl_bg2tile.hex roms/strahl_sprites.hex ../tlcs90/roms/strahl_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/strahl_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/strahl_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/strahl_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/strahl_oki2.hex\" \
		-GFGTILE_FILE=\"roms/strahl_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/strahl_bgtile.hex\" \
		-GBG2TILE_FILE=\"roms/strahl_bg2tile.hex\" \
		-GSPRITES_FILE=\"roms/strahl_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_strahl.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
