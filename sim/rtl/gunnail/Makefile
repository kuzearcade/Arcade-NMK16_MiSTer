# Verilator build for the gunnail system-level integration — the third
# Family D (TLCS-90 protection MCU) game, macross's own sibling (same
# NMK-215/TMP90840/dual-NMK214 mechanism, byte-identical protection
# ROM) — see rtl/gunnail/gunnail_core.sv's header. gunnail.zip is fully
# self-contained (no split-zip parent dependency).
#
# Usage:
#   make rom            # (re)build the 68000 program ROM hex (byte-interleaved pair)
#   make prot-rom        # (re)build the protection-MCU boot ROM hex
#   make ext-rom         # (re)build NMK004's own external program ROM
#   make oki-roms        # (re)build the OKIM6295 x2 sample ROMs
#   make vtiming-rom     # (re)build the real V-timing PROM
#   make gfx-roms        # (re)build fgtile/bgtile/sprites
#   make run             # build and run, produces nmk004_sys.trace/prot_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK214_DIR := ../../../rtl/nmk214
CORE_DIR := ../../../rtl/gunnail
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := gunnail_core
Z1 := $(ROMS_DIR)/gunnail.zip

MACROSS2_DIR := ../../../rtl/macross2
RTL_DIR := ../../../rtl
# Video is rtl/macross2/video_macross2.sv (gfx_macross parameters,
# RASTER_SCROLL, NMK214 descramble) — the hardware-ready module, so the
# reference sim and Gunnail.rbf share one video path. The SDRAM/cache
# modules are listed so their HW_ROMS=1 generate branches resolve.
SOURCES := $(CORE_DIR)/$(TOP).sv $(MACROSS2_DIR)/video_macross2.sv $(NMK214_DIR)/nmk214.sv \
           $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv $(TLCS90_DIR)/nmk_prot_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv \
           $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv

.PHONY: all rom prot-rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

# 3e.u131/3o.u133 — a genuine ROM_LOAD16_BYTE pair (unlike macross's own
# single ROM_LOAD16_WORD_SWAP file), same byte-interleave convention
# mkrom.py's own --hi/--lo interface already handles for blkheart/
# acrobatm/bioship's own maincpu ROMs.
rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(Z1) --hi 3e.u131 --lo 3o.u133 --out roms/gunnail_maincpu.hex

# nmk-215.bin — byte-identical to macross's own protection ROM (same
# CRC, confirmed from ROM_START(gunnail) directly).
prot-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files nmk-215.bin --out roms/gunnail_prot.hex

# 92077_2.u101 — gunnail's own NMK004 external program.
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 92077_2.u101 --out ../tlcs90/roms/gunnail_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 92077-5.u56 --out roms/gunnail_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 92077-6.u57 --out roms/gunnail_oki2.hex

vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 9_82s135.u72 --out roms/gunnail_vtiming.hex

# fgtile (1.u21) — plain concat, NOT descrambled. bgtile (92077-4.u19,
# 0x100000 — HALF macross's own 2MB) — plain concat, descrambled
# per-fetch at runtime via nmk214 (see video_gunnail.sv's header).
# sprites (92077-7.u134) — ROM_LOAD16_WORD_SWAP, same word_swap mode as
# macross's own sprite ROM, also descrambled per-fetch at runtime.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 1.u21 --out roms/gunnail_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 92077-4.u19 --out roms/gunnail_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 92077-7.u134 --out roms/gunnail_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_gunnail.cpp $(FX68K_DIR)/fx68k.sv roms/gunnail_maincpu.hex roms/gunnail_prot.hex roms/gunnail_oki1.hex roms/gunnail_oki2.hex roms/gunnail_vtiming.hex roms/gunnail_fgtile.hex roms/gunnail_bgtile.hex roms/gunnail_sprites.hex ../tlcs90/roms/gunnail_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(NMK214_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/gunnail_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/gunnail_ext.hex\" \
		-GPROT_BOOT_FILE=\"roms/gunnail_prot.hex\" \
		-GOKI1_ROM_FILE=\"roms/gunnail_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/gunnail_oki2.hex\" \
		-GVTIMING_FILE=\"roms/gunnail_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/gunnail_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/gunnail_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/gunnail_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_gunnail.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace prot_sys.trace microrom.mem nanorom.mem
