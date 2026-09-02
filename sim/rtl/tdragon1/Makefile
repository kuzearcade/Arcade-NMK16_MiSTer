# Verilator build for the tdragon1 system-level integration — the
# first Family D (TLCS-90 protection MCU) game, see
# rtl/tdragon1/tdragon1_core.sv's header. tdragon1's own romset
# (tdragon1.zip) supplies only the maincpu program (thund.7/thund.8)
# and the protection-MCU boot ROM (nmk-110-tdragon.bin); every other
# region is pulled from the parent tdragon.zip (same split-zip pattern
# already used for hachamfb/hachamf — see mkgfxrom.py's multi-zip
# search).
#
# Usage:
#   make rom          # (re)build the 68000 program ROM hex from mame_roms/tdragon1.zip
#   make prot-rom      # (re)build the protection-MCU boot ROM hex
#   make ext-rom       # (re)build NMK004's own external program ROM (from tdragon.zip)
#   make oki-roms      # (re)build the OKIM6295 x2 sample ROMs (from tdragon.zip)
#   make vtiming-rom   # (re)build the real V-timing PROM (from tdragon.zip)
#   make gfx-roms      # (re)build fgtile/bgtile/sprites (from tdragon.zip)
#   make run           # build and run, produces nmk004_sys.trace/prot_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
CORE_DIR := ../../../rtl/tdragon1
TDRAGON_CORE_DIR := ../../../rtl/tdragon
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := tdragon1_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(TDRAGON_CORE_DIR)/video_tdragon.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv $(TLCS90_DIR)/nmk_prot_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom prot-rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

# thund.7/thund.8 — a different maincpu program from tdragon's own
# 91070_68k.7/.8, despite the identical ROM_LOAD16_WORD_SWAP-free plain
# hi/lo convention (see tdragon1_core.sv's header).
rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/tdragon1.zip --hi thund.8 --lo thund.7 --out roms/tdragon1_maincpu.hex

# nmk-110-tdragon.bin — the 16KB protection-MCU boot ROM (see
# rtl/tlcs90/nmk_prot_core.sv's header).
prot-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon1.zip --mode concat --files nmk-110-tdragon.bin --out roms/tdragon1_prot.hex

# 91070.1 — tdragon's own NMK004 external program, byte-for-byte
# identical for tdragon1 (confirmed via unzip -l, see header); pulled
# from the parent tdragon.zip.
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.1 --out ../tlcs90/roms/tdragon_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.3 --out roms/tdragon1_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.2 --out roms/tdragon1_oki2.hex

vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.10 --out roms/tdragon1_vtiming.hex

gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.6 --out roms/tdragon1_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode concat --files 91070.5 --out roms/tdragon1_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon.zip --mode word_swap --files 91070.4 --out roms/tdragon1_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_tdragon1.cpp $(FX68K_DIR)/fx68k.sv roms/tdragon1_maincpu.hex roms/tdragon1_prot.hex roms/tdragon1_oki1.hex roms/tdragon1_oki2.hex roms/tdragon1_vtiming.hex roms/tdragon1_fgtile.hex roms/tdragon1_bgtile.hex roms/tdragon1_sprites.hex ../tlcs90/roms/tdragon_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/tdragon1_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/tdragon_ext.hex\" \
		-GPROT_BOOT_FILE=\"roms/tdragon1_prot.hex\" \
		-GOKI1_ROM_FILE=\"roms/tdragon1_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/tdragon1_oki2.hex\" \
		-GVTIMING_FILE=\"roms/tdragon1_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/tdragon1_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/tdragon1_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/tdragon1_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_tdragon1.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace prot_sys.trace microrom.mem nanorom.mem
