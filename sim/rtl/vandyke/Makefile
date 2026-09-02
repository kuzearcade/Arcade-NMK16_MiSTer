# Verilator build for the vandyke system-level integration (the seventh
# Tier 2 NMK004-board game — see rtl/vandyke/vandyke_core.sv's header
# for what's different: mustang's own memory-map style with three real
# targeted quirks, bioship's own 10MHz/8MHz clock architecture).
#
# Usage:
#   make rom        # (re)build the 68000 program ROM hex from mame_roms/vandyke.zip
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
CORE_DIR := ../../../rtl/vandyke
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := vandyke_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_vandyke.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/vandyke.zip --hi vdk-1.16 --lo vdk-2.15 --out roms/vandyke_maincpu.hex

# vdk-4.127 is vandyke's own NMK004 external program (the shared 8K
# internal boot ROM lives in sim/rtl/tlcs90/roms/nmk004_boot.hex already
# — see vandyke_core.sv's header).
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode concat --files vdk-4.127 --out ../tlcs90/roms/vandyke_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode concat --files vdk-02.126 --out roms/vandyke_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode concat --files vdk-03.165 --out roms/vandyke_oki2.hex

# ic100.bpr is vandyke's own real V-timing PROM (see rtl/nmk_irq/nmk_irq.sv)
# — same CRC as mustang's own 10.bpr, genuinely shared PROM content.
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode concat --files ic100.bpr --out roms/vandyke_vtiming.hex

# Sprites are TWO independent ROM_LOAD16_BYTE interleaved pairs
# concatenated (not a single interleave across all four files) — see
# vandyke_core.sv's own header. Extract each pair separately, then `cat`
# the two intermediate $readmemh text files (each already
# one-byte-per-line, so literal concatenation is correct).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode concat --files vdk-3.222 --out roms/vandyke_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode concat --files vdk-01.13 --out roms/vandyke_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode interleave16 --hi vdk-07.202 --lo vdk-06.203 --out /tmp/vandyke_sprites_p1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/vandyke.zip --mode interleave16 --hi vdk-04.2-1 --lo vdk-05.3-1 --out /tmp/vandyke_sprites_p2.hex
	cat /tmp/vandyke_sprites_p1.hex /tmp/vandyke_sprites_p2.hex > roms/vandyke_sprites.hex
	rm -f /tmp/vandyke_sprites_p1.hex /tmp/vandyke_sprites_p2.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_vandyke.cpp $(FX68K_DIR)/fx68k.sv roms/vandyke_maincpu.hex roms/vandyke_oki1.hex roms/vandyke_oki2.hex roms/vandyke_vtiming.hex roms/vandyke_fgtile.hex roms/vandyke_bgtile.hex roms/vandyke_sprites.hex ../tlcs90/roms/vandyke_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/vandyke_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/vandyke_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/vandyke_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/vandyke_oki2.hex\" \
		-GVTIMING_FILE=\"roms/vandyke_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/vandyke_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/vandyke_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/vandyke_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_vandyke.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
