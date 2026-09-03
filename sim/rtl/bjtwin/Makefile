# Verilator build for the bjtwin-family Tier 1 core (CPU/memory + video).
# See docs/PLAN.md and docs/tier1-bjtwin.md for what this proves.
#
# Usage:
#   make rom       # (re)build the 68000 program ROM hex from mame_roms/cactus.zip
#   make gfxrom    # (re)build fgtile/bgtile/sprites ROM hexes (fgtile needs
#                    the sabotenb.zip parent set, see docs/rom-audit.md)
#   make run       # build and run, produces cactus_rtl.trace (B + F lines)
#   make check     # run, then diff cactus_rtl.trace against the real MAME oracle trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
TLCS90_DIR := ../../../rtl/tlcs90
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK214_DIR := ../../../rtl/nmk214
CORE_DIR := ../../../rtl/bjtwin
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := bjtwin_core

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/nmk_irq_hacky.sv $(CORE_DIR)/video_timing.sv $(CORE_DIR)/video_bjtwin.sv

# --- bjtwin_prot (Family D, NMK-215/TMP90840 + dual-NMK214, third
# sub-group after macross/gunnail) — protected `bjtwin` romset. See
# bjtwin_prot_core.sv's own header. ---
PROT_TOP := bjtwin_prot_core
Z2 := $(ROMS_DIR)/bjtwin.zip
PROT_SOURCES := $(CORE_DIR)/$(PROT_TOP).sv $(CORE_DIR)/video_bjtwin_prot.sv $(CORE_DIR)/video_timing.sv \
                $(NMK214_DIR)/nmk214.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
                $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk_prot_core.sv

.PHONY: all rom gfxrom run check clean prot-rom prot-prot-rom prot-vtiming-rom prot-gfx-roms run-prot clean-prot

all: run

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/cactus.zip --hi 02.bin --lo 01.bin --out roms/cactus_maincpu.hex

gfxrom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/cactus.zip --zip $(ROMS_DIR)/sabotenb.zip --mode concat --files ic35.sb3 --out roms/cactus_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/cactus.zip --mode concat --files s-05.bin s-06.bin --out roms/cactus_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/cactus.zip --mode interleave16 --hi s-04.bin --lo s-03.bin --out roms/cactus_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_bjtwin.cpp ../common/nmktrace.h ../common/crc32.h $(FX68K_DIR)/fx68k.sv
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(CORE_DIR) \
		-GROM_FILE=\"roms/cactus_maincpu.hex\" \
		-GFGTILE_FILE=\"roms/cactus_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/cactus_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/cactus_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_bjtwin.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

check: run
	python3 ../../../sim/compare/oracle_diff.py ../../../sim/oracle/traces/cactus_io.trace cactus_rtl.trace --cycle-tolerance 100000

clean:
	rm -rf $(OBJ_DIR) cactus_rtl.trace microrom.mem nanorom.mem

# --- bjtwin_prot targets ---
# Sound (nmk112 + 2x OKIM6295) is stubbed, same as bjtwin_core.sv's own
# unprotected build — no oki/nmk112 ROM extraction needed here.

prot-rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(Z2) --hi 93087-1.bin --lo 93087-2.bin --out roms/bjtwin_maincpu.hex

prot-prot-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z2) --mode concat --files nmk-215.bin --out roms/bjtwin_prot.hex

prot-vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z2) --mode concat --files 8.ic37 --out roms/bjtwin_vtiming.hex

prot-gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z2) --mode concat --files 93087-3.bin --out roms/bjtwin_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z2) --mode concat --files 93087-4.bin --out roms/bjtwin_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z2) --mode word_swap --files 93087-5.bin --out roms/bjtwin_sprites.hex

$(OBJ_DIR)/V$(PROT_TOP): $(PROT_SOURCES) tb_bjtwin_prot.cpp ../common/nmktrace.h ../common/crc32.h $(FX68K_DIR)/fx68k.sv \
                         roms/bjtwin_maincpu.hex roms/bjtwin_prot.hex roms/bjtwin_vtiming.hex \
                         roms/bjtwin_fgtile.hex roms/bjtwin_bgtile.hex roms/bjtwin_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(PROT_TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(NMK214_DIR) -y $(NMK_IRQ_DIR) -y $(CORE_DIR) \
		-GROM_FILE=\"roms/bjtwin_maincpu.hex\" \
		-GPROT_BOOT_FILE=\"roms/bjtwin_prot.hex\" \
		-GVTIMING_FILE=\"roms/bjtwin_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/bjtwin_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/bjtwin_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/bjtwin_sprites.hex\" \
		$(PROT_SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_bjtwin_prot.cpp \
		-o V$(PROT_TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run-prot: $(OBJ_DIR)/V$(PROT_TOP)
	./$(OBJ_DIR)/V$(PROT_TOP)

clean-prot:
	rm -rf $(OBJ_DIR)/*$(PROT_TOP)* $(OBJ_DIR)/V$(PROT_TOP) prot_sys.trace prot_cyc.trace prot_regs.trace \
		bjtwin_prot_68k.trace m68k_cyc.trace bjtwin_prot_video.trace microrom.mem nanorom.mem
