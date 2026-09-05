# Verilator build for macross2 (Tier 3, Family C — first Z80-direct-sound
# hi-res port, see rtl/macross2/macross2_core.sv's header).
#
# Usage:
#   make roms   # (re)build all ROM hex files from mame_roms/macross2.zip
#   make run    # build and run, produces macross2_video.trace + z80/m68k traces
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
CORE_DIR := ../../../rtl/macross2
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := macross2_core
Z1 := $(ROMS_DIR)/macross2.zip

# video_timing.sv reused unchanged from Tier 1's bjtwin (this project's
# single shared 8MHz/512-wide raster model regardless of lowres/hires
# screen config). rtl/nmk_irq/nmk_irq.sv is the REAL V-PROM-driven
# interrupt generator (already built for Tier 2's mustang/Tier 4's
# gunnail) — the first newly-built port this session using it, NOT the
# hacky fixed-scanline substitute every Tier 5 port used. rtl/nmk112/
# nmk112.sv is a new, reusable OKI bank-switcher device (see its own
# header). T80s.v reused unchanged from Tier 5's mustangb. jt03 (YM2203)
# reused from Tier 4's gunnail/Tier 5's gunnailb own integration pattern.
SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_macross2.sv $(NMK112_DIR)/nmk112.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom audiocpu-rom oki-roms vtiming-rom gfx-roms

# maincpu: mcrs2j.3, single ROM_LOAD16_WORD_SWAP file (nmk16.cpp:8242) —
# NOT the usual two-chip ROM_LOAD16_BYTE pair, see tools/mkrom_wordswap.py.
rom:
	python3 $(TOOLS_DIR)/mkrom_wordswap.py --zip $(Z1) --file mcrs2j.3 --out roms/macross2_maincpu.hex

# audiocpu: mcrs2j.2 — flat single-file load (no ROM_CONTINUE/ROM_COPY),
# same shape as gunnailb's own (nmk16.cpp:8245-8246).
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files mcrs2j.2 --out roms/macross2_audiocpu.hex

# oki1 (bp932an.a06, 0x200000) / oki2 (bp932an.a05, 0x100000), both
# banked entirely through NMK112 (nmk16.cpp:8261-8262).
oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files bp932an.a06 --out roms/macross2_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files bp932an.a05 --out roms/macross2_oki2.hex

# nmk_irq's own real V-PROM (mcrs2bpr.10, nmk16.cpp:8267-8268) — htiming
# (mcrs2bpr.9) is NOT extracted, matching rtl/nmk_irq/nmk_irq.sv's own
# header note that MAME's own nmk_irq_device never consumes the H-timing
# PROM at all.
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files mcrs2bpr.10 --out roms/macross2_vtiming.hex

# fgtile (mcrs2j.1, 0x20000) / bgtile (bp932an.a04, 0x200000) — plain
# concat, no descrambling (macross2 has no protection MCU). sprites
# (bp932an.a07+a08, nmk16.cpp:8254-8256) — TWO ROM_LOAD16_WORD_SWAP files
# concatenated in region order; mkgfxrom.py's own word_swap mode only
# takes one file at a time, so extract each half separately and cat them.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files mcrs2j.1 --out roms/macross2_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files bp932an.a04 --out roms/macross2_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files bp932an.a07 --out roms/macross2_sprites_p1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files bp932an.a08 --out roms/macross2_sprites_p2.hex
	cat roms/macross2_sprites_p1.hex roms/macross2_sprites_p2.hex > roms/macross2_sprites.hex
	@n=$$(wc -l < roms/macross2_sprites.hex); \
	if [ "$$n" != "4194304" ]; then echo "error: macross2_sprites.hex has $$n lines, expected 4194304 (0x400000)"; exit 1; fi

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_macross2.cpp $(FX68K_DIR)/fx68k.sv \
	roms/macross2_maincpu.hex roms/macross2_audiocpu.hex roms/macross2_oki1.hex roms/macross2_oki2.hex \
	roms/macross2_vtiming.hex roms/macross2_fgtile.hex roms/macross2_bgtile.hex roms/macross2_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/macross2_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/macross2_audiocpu.hex\" \
		-GOKI1_ROM_FILE=\"roms/macross2_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/macross2_oki2.hex\" \
		-GVTIMING_FILE=\"roms/macross2_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/macross2_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/macross2_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/macross2_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_macross2.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) macross2_video.trace microrom.mem nanorom.mem
