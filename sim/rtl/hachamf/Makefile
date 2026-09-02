# Verilator build for the hachamf system-level integration — the
# second Family D (TLCS-90 protection MCU) game, after tdragon1 — see
# rtl/hachamf/hachamf_core.sv's header. hachamf.zip is fully
# self-contained (no split-zip parent dependency, unlike hachamfb/
# tdragon1).
#
# Usage:
#   make rom          # (re)build the 68000 program ROM hex
#   make prot-rom      # (re)build the protection-MCU boot ROM hex
#   make ext-rom       # (re)build NMK004's own external program ROM
#   make oki-roms      # (re)build the OKIM6295 x2 sample ROMs
#   make vtiming-rom   # (re)build the real V-timing PROM
#   make gfx-roms      # (re)build fgtile/bgtile/sprites
#   make run           # build and run, produces nmk004_sys.trace/prot_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
CORE_DIR := ../../../rtl/hachamf
HACHAMFB_CORE_DIR := ../../../rtl/hachamfb
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := hachamf_core
Z1 := $(ROMS_DIR)/hachamf.zip

SOURCES := $(CORE_DIR)/$(TOP).sv $(HACHAMFB_CORE_DIR)/video_hachamfb.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv $(TLCS90_DIR)/nmk_prot_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom prot-rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(Z1) --hi 7.93 --lo 6.94 --out roms/hachamf_maincpu.hex

# nmk-113.bin — the 16KB shared-firmware protection-MCU boot ROM (see
# rtl/hachamf/hachamf_core.sv's header — hachamf selects its own
# codepath within it via a fixed port-7 constant, not via ROM content).
prot-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files nmk-113.bin --out roms/hachamf_prot.hex

# 1.70 is hachamf's own NMK004 external program.
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 1.70 --out ../tlcs90/roms/hachamf_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 91076-2.46 --out roms/hachamf_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 91076-3.45 --out roms/hachamf_oki2.hex

# 82s135.ic50 carries the same shared vtiming CRC (633ab1c9) every
# other port's own V-PROM already carries.
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 82s135.ic50 --out roms/hachamf_vtiming.hex

# 91076-8.57 is ROM_LOAD16_WORD_SWAP (same convention as blkheart's/
# tdragon's/hachamfb's own sprite ROMs).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 5.95 --out roms/hachamf_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 91076-4.101 --out roms/hachamf_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 91076-8.57 --out roms/hachamf_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_hachamf.cpp $(FX68K_DIR)/fx68k.sv roms/hachamf_maincpu.hex roms/hachamf_prot.hex roms/hachamf_oki1.hex roms/hachamf_oki2.hex roms/hachamf_vtiming.hex roms/hachamf_fgtile.hex roms/hachamf_bgtile.hex roms/hachamf_sprites.hex ../tlcs90/roms/hachamf_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/hachamf_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/hachamf_ext.hex\" \
		-GPROT_BOOT_FILE=\"roms/hachamf_prot.hex\" \
		-GOKI1_ROM_FILE=\"roms/hachamf_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/hachamf_oki2.hex\" \
		-GVTIMING_FILE=\"roms/hachamf_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/hachamf_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/hachamf_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/hachamf_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_hachamf.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace prot_sys.trace microrom.mem nanorom.mem
