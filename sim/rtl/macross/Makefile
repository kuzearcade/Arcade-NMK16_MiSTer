# Verilator build for the macross system-level integration — the third
# Family D (TLCS-90 protection MCU) game, after tdragon1/hachamf, and
# the first with the dual-NMK214 GFX descrambler — see
# rtl/macross/macross_core.sv's header. macross.zip is fully
# self-contained (no split-zip parent dependency).
#
# Usage:
#   make rom           # (re)build the 68000 program ROM hex
#   make prot-rom       # (re)build the protection-MCU boot ROM hex
#   make ext-rom        # (re)build NMK004's own external program ROM
#   make oki-roms       # (re)build the OKIM6295 x2 sample ROMs
#   make vtiming-rom    # (re)build the real V-timing PROM
#   make gfx-roms       # (re)build fgtile/bgtile/sprites
#   make run            # build and run, produces nmk004_sys.trace/prot_sys.trace
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK214_DIR := ../../../rtl/nmk214
CORE_DIR := ../../../rtl/macross
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := macross_core
Z1 := $(ROMS_DIR)/macross.zip

SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_macross.sv $(NMK214_DIR)/nmk214.sv \
           $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv $(TLCS90_DIR)/nmk_prot_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all rom prot-rom ext-rom oki-roms vtiming-rom gfx-roms run clean

all: run

# 921a03 — a single ROM_LOAD16_WORD_SWAP file (ROM_GROUPWORD|ROM_REVERSE
# per romentry.h, same convention tools/mkgfxrom.py's own word_swap mode
# already handles for graphics ROMs), NOT the two-chip ROM_LOAD16_BYTE
# split mkrom.py's own --hi/--lo interface expects — the first maincpu
# ROM this project has needed to extract this way. Inline conversion
# (word-swap the raw dump, then emit one 16-bit word per line) rather
# than extending mkrom.py's own interface for a one-off case.
rom:
	python3 -c "\
import zipfile; \
z = zipfile.ZipFile('$(Z1)'); \
raw = bytearray(z.read('921a03')); \
raw[0::2], raw[1::2] = raw[1::2], raw[0::2]; \
f = open('roms/macross_maincpu.hex', 'w'); \
[f.write('%02x%02x\n' % (raw[i], raw[i+1])) for i in range(0, len(raw), 2)]; \
f.close(); \
print('wrote', len(raw)//2, 'words to roms/macross_maincpu.hex')"

# nmk-215.bin — the 8KB dedicated protection-MCU (TMP90840/NMK-215)
# boot ROM (not a shared multi-game firmware image like hachamf's own
# NMK-113 — see macross_core.sv's header).
prot-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files nmk-215.bin --out roms/macross_prot.hex

# 921a02 — macross's own NMK004 external program (64KB dump, used
# directly as EXT_ROM_FILE, same convention as every prior NMK004 port).
ext-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 921a02 --out ../tlcs90/roms/macross_ext.hex

oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 921a05 --out roms/macross_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 921a06 --out roms/macross_oki2.hex

# 921a09 — carries the shared vtiming CRC (633ab1c9) every other port's
# own V-PROM already carries (confirmed, not assumed).
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 921a09 --out roms/macross_vtiming.hex

# fgtile (921a01) — plain concat, NOT descrambled (see video_macross.sv's
# header). bgtile (921a04) — plain concat (single ROM_LOAD, no
# interleaving, confirmed from ROM_START(macross)), descrambled
# per-fetch at runtime via nmk214, not at extraction time. sprites
# (921a07) — ROM_LOAD16_WORD_SWAP, same word_swap mode as blkheart's/
# tdragon's own sprite ROMs, also descrambled per-fetch at runtime.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 921a01 --out roms/macross_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 921a04 --out roms/macross_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 921a07 --out roms/macross_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_macross.cpp $(FX68K_DIR)/fx68k.sv roms/macross_maincpu.hex roms/macross_prot.hex roms/macross_oki1.hex roms/macross_oki2.hex roms/macross_vtiming.hex roms/macross_fgtile.hex roms/macross_bgtile.hex roms/macross_sprites.hex ../tlcs90/roms/macross_ext.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(NMK214_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/macross_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"../tlcs90/roms/macross_ext.hex\" \
		-GPROT_BOOT_FILE=\"roms/macross_prot.hex\" \
		-GOKI1_ROM_FILE=\"roms/macross_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/macross_oki2.hex\" \
		-GVTIMING_FILE=\"roms/macross_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/macross_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/macross_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/macross_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_macross.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) nmk004_sys.trace prot_sys.trace microrom.mem nanorom.mem
