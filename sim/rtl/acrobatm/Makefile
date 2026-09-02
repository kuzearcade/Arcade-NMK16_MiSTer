# Verilator build for the acrobatm system-level integration (the fifth
# Tier 2 NMK004-board game, after sim/rtl/mustang/, sim/rtl/bioship/,
# sim/rtl/blkheart/, and sim/rtl/strahl/'s own — see
# rtl/acrobatm/acrobatm_core.sv's header for what's different: a
# blkheart-family video pipeline with bioship's own 10MHz/8MHz clock
# ratio, and a genuinely different memory map).
#
# Usage:
#   make rom        # (re)build the 68000 program ROM hex from mame_roms/acrobatm.zip
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
CORE_DIR := ../../../rtl/acrobatm
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := acrobatm_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_acrobatm.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/acrobatm.zip --hi 2.ic100 --lo 1.ic101 --out roms/acrobatm_maincpu.hex

# 4.ic74 is acrobatm's own NMK004 external program (the shared 8K
# internal boot ROM lives in sim/rtl/tlcs90/roms/nmk004_boot.hex already
# — see acrobatm_core.sv's header).
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files 4.ic74 --out ../tlcs90/roms/acrobatm_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files am-05.ic54 --out roms/acrobatm_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files am-04.ic53 --out roms/acrobatm_oki2.hex

# 11.ic80 is acrobatm's own real V-timing PROM (see rtl/nmk_irq/nmk_irq.sv)
# — same CRC as mustang's own 10.bpr, genuinely shared PROM content.
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files 11.ic80 --out roms/acrobatm_vtiming.hex

# am-01.ic42+am-02.ic29 are a plain two-file concat (different sizes,
# 0x100000+0x080000 — no interleave/word-swap/segments needed).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files 3.ic79 --out roms/acrobatm_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files am-03.ic8 --out roms/acrobatm_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files am-01.ic42 am-02.ic29 --out roms/acrobatm_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_acrobatm.cpp $(FX68K_DIR)/fx68k.sv roms/acrobatm_maincpu.hex roms/acrobatm_oki1.hex roms/acrobatm_oki2.hex roms/acrobatm_vtiming.hex roms/acrobatm_fgtile.hex roms/acrobatm_bgtile.hex roms/acrobatm_sprites.hex ../tlcs90/roms/acrobatm_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/acrobatm_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/acrobatm_ext.hex\" \
		-GOKI1_ROM_FILE=\"roms/acrobatm_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/acrobatm_oki2.hex\" \
		-GVTIMING_FILE=\"roms/acrobatm_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/acrobatm_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/acrobatm_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/acrobatm_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_acrobatm.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace microrom.mem nanorom.mem
