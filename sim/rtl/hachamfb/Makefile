# Verilator build for the hachamfb system-level integration (the eighth
# Tier 2 NMK004-board game — see rtl/hachamfb/hachamfb_core.sv's header
# for what's different: a genuine composite of mustang's own memory-map
# base addresses, blkheart's own scroll_w<0>/tilebank_w/sprite-ROM
# convention, and bioship's own 10MHz/8MHz clock architecture — no new
# technique needed at all, but confirmed genuinely unprotected before
# any RTL was written, since this romset shares the "hachamf" name with
# a real-TLCS-90-MCU-protected family).
#
# hachamfb's own ROMs are split across two zips: hachamfb.zip itself
# (just the 68000 program) and its parent hachamf.zip (everything
# else) — every rule below passes both --zip flags, letting
# tools/mkgfxrom.py's own multi-zip search resolve each file.
#
# Usage:
#   make rom        # (re)build the 68000 program ROM hex
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
CORE_DIR := ../../../rtl/hachamfb
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := hachamfb_core
Z1 := $(ROMS_DIR)/hachamfb.zip
Z2 := $(ROMS_DIR)/hachamf.zip

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_hachamfb.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(Z1) --hi 8.bin --lo 7.bin --out roms/hachamfb_maincpu.hex

# 1.70 is hachamfb's own NMK004 external program (the shared 8K
# internal boot ROM lives in sim/rtl/tlcs90/roms/nmk004_boot.hex already
# — see hachamfb_core.sv's header). Lives in the parent zip.
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files 1.70 --out ../tlcs90/roms/hachamfb_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files 91076-2.46 --out roms/hachamfb_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files 91076-3.45 --out roms/hachamfb_oki2.hex

# 82s135.ic50 is marked BAD_DUMP in the reference itself (borrowed from
# hachamfp's own dump) but its content is the same shared vtiming CRC
# every other port's own V-PROM already carries — see
# hachamfb_core.sv's header.
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files 82s135.ic50 --out roms/hachamfb_vtiming.hex

# 91076-8.57 is ROM_LOAD16_WORD_SWAP (see tools/mkgfxrom.py's own
# word_swap mode — same convention as blkheart's/tdragon's own sprite ROMs).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files 5.95 --out roms/hachamfb_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files 91076-4.101 --out roms/hachamfb_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode word_swap --files 91076-8.57 --out roms/hachamfb_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_hachamfb.cpp $(FX68K_DIR)/fx68k.sv roms/hachamfb_maincpu.hex roms/hachamfb_oki1.hex roms/hachamfb_oki2.hex roms/hachamfb_vtiming.hex roms/hachamfb_fgtile.hex roms/hachamfb_bgtile.hex roms/hachamfb_sprites.hex ../tlcs90/roms/hachamfb_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/hachamfb_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/hachamfb_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/hachamfb_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/hachamfb_oki2.hex\" \
		-GVTIMING_FILE=\"roms/hachamfb_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/hachamfb_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/hachamfb_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/hachamfb_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_hachamfb.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
