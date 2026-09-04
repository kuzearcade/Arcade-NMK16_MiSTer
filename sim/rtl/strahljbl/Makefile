# Verilator build for strahljbl (Tier 5, Family E — fourth Z80-based
# port, see rtl/strahljbl/strahljbl_core.sv's header).
#
# Usage:
#   make roms   # (re)build all ROM hex files from mame_roms/strahljbl.zip (+ strahl.zip)
#   make run    # build and run, produces strahljbl_video.trace + z80/m68k traces
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JTOPL_DIR := ../../../rtl/third_party/jtopl
JT6295_DIR := ../../../rtl/third_party/jt6295
BJTWIN_DIR := ../../../rtl/bjtwin
STRAHL_DIR := ../../../rtl/strahl
SEIBU_DIR := ../../../rtl/seibu
CORE_DIR := ../../../rtl/strahljbl
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := strahljbl_core

# video_timing.sv + nmk_irq_hacky.sv reused unchanged from Tier 1's
# bjtwin (strahljbl's own timing PROMs are undumped too — MAME
# substitutes the same fixed-scanline table). video_strahl.sv reused
# unchanged from Tier 2's strahl (identical video/VRAM/scroll register
# layout to strahljbl_map, dual BG0/BG1 layers). seibu_sound.sv + T80s.v
# reused unchanged from Tier 5's mustangb (byte-identical audiocpu ROM,
# same Seibu Sound System hardware). See rtl/strahljbl/strahljbl_core.sv's
# header for the full derivation.
SOURCES := $(CORE_DIR)/$(TOP).sv $(STRAHL_DIR)/video_strahl.sv $(SEIBU_DIR)/seibu_sound.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv \
           $(T80_DIR)/T80s.v $(JTOPL_DIR)/hdl/jtopl2.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom audiocpu-rom oki-rom gfx-roms

# maincpu: a7.u3 (hi)/a8.u2 (lo), ROM_LOAD16_BYTE — see
# ROM_START(strahljbl), nmk16.cpp:7876-7878. No decode/patch needed
# (strahljbl uses empty_init()).
rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/strahljbl.zip --hi a7.u3 --lo a8.u2 --out roms/strahljbl_maincpu.hex

# audiocpu: a6.u417 is byte-identical (CRC 99ee7505) to every prior Tier
# 5 port's own audiocpu ROM, same ROM_LOAD+ROM_CONTINUE+ROM_COPY layout
# (nmk16.cpp:7893-7896).
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahljbl.zip --mode segments \
		--files a6.u417 \
		--segments 0x00000:0x00000:0x8000 --segments 0x10000:0x08000:0x8000 --segments 0x18000:0x00000:0x8000 \
		--out roms/strahljbl_audiocpu.hex

# oki: a5.u304 — same CRC (f6f6c4bf) as every prior Tier 5 port's own
# OKI ROM (nmk16.cpp:7898-7899).
oki-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahljbl.zip --mode concat --files a5.u304 --out roms/strahljbl_oki.hex

# fgtile/bgtile/bg2tile, and half of sprites, are NOT present in
# strahljbl.zip itself — confirmed via `unzip -l` (only 129.u28/a5.u304/
# a6.u417/a7.u3/a8.u2/d.8m are there). strahljbl is a clone of strahl
# (GAME()'s parent field) and these are shared with the parent set, but
# — like acrobatmbl's own case, unlike mustangb's own — stored under
# DIFFERENT member names in the parent zip (board-specific chip labels),
# confirmed via CRC cross-check against ROM_START(strahl)
# (nmk16.cpp:7764-7799):
#   cha.38  (fgtile,  CRC 2273b33e) == strahl.zip's strahl-3.73
#   6.2m    (bgtile,  CRC 5769e3e1) == strahl.zip's str7b2r0.275
#   4.4m    (bg2tile, CRC bb1bb155) == strahl.zip's str6b1w1.776
#   5.4m    (sprites part 2, CRC a0e7d210) == strahl.zip's strl5-03.58
#     (strahl's own THIRD sprite chip — the bootleg's d.8m combines what
#     were strahl's own first two 0x80000 chips into one 0x100000 chip,
#     "same as original, just a bigger ROM" per the reference's own
#     comment, but reuses strahl's own third chip unmodified)
# sprites (nmk16.cpp:7886-7888): d.8m (0x100000 bytes) IS present
# directly in strahljbl.zip, loaded at region offset 0; 5.4m/strl5-03.58
# (0x80000 bytes) loads at region offset 0x100000. No ROM_IGNORE this
# time (unlike acrobatmbl's own sprites) — both pieces load in full,
# total exactly 0x180000, still guarded by a line-count assertion below
# since a wrong file/offset here would otherwise fail silently.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files strahl-3.73 --out roms/strahljbl_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files str7b2r0.275 --out roms/strahljbl_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files str6b1w1.776 --out roms/strahljbl_bg2tile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahljbl.zip --mode concat --files d.8m --out roms/strahljbl_sprites_p1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/strahl.zip --mode concat --files strl5-03.58 --out roms/strahljbl_sprites_p2.hex
	cat roms/strahljbl_sprites_p1.hex roms/strahljbl_sprites_p2.hex > roms/strahljbl_sprites.hex
	@n=$$(wc -l < roms/strahljbl_sprites.hex); \
	if [ "$$n" != "1572864" ]; then echo "error: strahljbl_sprites.hex has $$n lines, expected 1572864 (0x180000)"; exit 1; fi

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_strahljbl.cpp $(FX68K_DIR)/fx68k.sv \
	roms/strahljbl_maincpu.hex roms/strahljbl_audiocpu.hex roms/strahljbl_oki.hex \
	roms/strahljbl_fgtile.hex roms/strahljbl_bgtile.hex roms/strahljbl_bg2tile.hex roms/strahljbl_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(JTOPL_DIR)/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/strahljbl_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/strahljbl_audiocpu.hex\" \
		-GOKI_ROM_FILE=\"roms/strahljbl_oki.hex\" \
		-GFGTILE_FILE=\"roms/strahljbl_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/strahljbl_bgtile.hex\" \
		-GBG2TILE_FILE=\"roms/strahljbl_bg2tile.hex\" \
		-GSPRITES_FILE=\"roms/strahljbl_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_strahljbl.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) strahljbl_video.trace microrom.mem nanorom.mem
