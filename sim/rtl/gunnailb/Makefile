# Verilator build for gunnailb (Tier 5, fifth port — architecturally
# different from mustangb/tdragonb/acrobatmbl/strahljbl, no Seibu Sound
# System — see rtl/gunnailb/gunnailb_core.sv's header).
#
# Usage:
#   make roms   # (re)build all ROM hex files from mame_roms/gunnailb.zip
#   make run    # build and run, produces gunnailb_video.trace + z80/m68k traces
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
BJTWIN_DIR := ../../../rtl/bjtwin
GUNNAIL_DIR := ../../../rtl/gunnail
CORE_DIR := ../../../rtl/gunnailb
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := gunnailb_core
Z1 := $(ROMS_DIR)/gunnailb.zip
# sprites (27c160.a9) is NOT present in gunnailb.zip itself — confirmed
# via `unzip -l` (only 27c010.3b/27c010.5g/27c020.1c/27c020.6d/27c020.6e/
# 27c160.k10 are there). gunnailb is a clone of gunnail (GAME()'s parent
# field); the sprites ROM is shared with the parent set but stored under a
# different member name there (board-specific chip label) — confirmed via
# CRC cross-check: gunnail.zip's own 92077-7.u134 has CRC d49169b3,
# exactly matching 27c160.a9's expected CRC in ROM_START(gunnailb).
Z2 := $(ROMS_DIR)/gunnail.zip

# video_timing.sv + nmk_irq_hacky.sv reused unchanged from Tier 1's
# bjtwin (gunnailb's own timing PROMs are undumped too — MAME substitutes
# the same fixed-scanline table). video_gunnailb.sv is a NEW derivative of
# Tier 4's video_gunnail.sv (nmk214 live-descramble stages removed — see
# its own header), NOT video_gunnail.sv itself. T80s.v reused unchanged
# from Tier 5's mustangb. jt03 (YM2203) + jt6295 (OKIM6295) reused
# unchanged from Tier 4's gunnail_core.sv own integration pattern (direct
# Z80/68000 wiring here instead of an NMK004 relay — see
# rtl/gunnailb/gunnailb_core.sv's own header).
SOURCES := $(CORE_DIR)/$(TOP).sv $(GUNNAIL_DIR)/video_gunnailb.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom audiocpu-rom oki-rom gfx-roms

# maincpu: 27c020.6d (hi)/27c020.6e (lo), ROM_LOAD16_BYTE — see
# ROM_START(gunnailb), nmk16.cpp:8221-8223. No decode/patch needed
# (only bgtile/sprites are touched by decode_gfx()).
rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(Z1) --hi 27c020.6d --lo 27c020.6e --out roms/gunnailb_maincpu.hex

# audiocpu: 27c010.3b — a flat single-file load (no ROM_CONTINUE/ROM_COPY,
# unlike every prior Tier 5 port's own Seibu-style layout — the comment in
# the reference notes this ROM "matches the one for Kaneko's Air Buster"
# (nmk16.cpp:8226), a completely unrelated game's Z80 sound program).
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 27c010.3b --out roms/gunnailb_audiocpu.hex

# oki1: 27c020.1c — no banking (nmk16.cpp:8237-8238).
oki-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 27c020.1c --out roms/gunnailb_oki.hex

# fgtile (27c010.5g) — plain concat, NOT touched by decode_gfx(). bgtile
# (27c160.k10, 0x200000 — DOUBLE gunnail's own 1MB, matching macross's own
# 2MB ROM/14-bit tile code, not gunnail's 13-bit one — see
# video_gunnailb.sv's own header) — concat, then the new offline bg
# descramble. sprites (27c160.a9) — ROM_LOAD16_WORD_SWAP (same mode
# gunnail's own sprite ROM uses), then the new offline sprite descramble.
# Both descrambles use tools/decode_gunnailb_gfx.py, NOT the live
# rtl/nmk214/nmk214.sv this project already has (see that tool's own
# header for why these are different mechanisms).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 27c010.5g --out roms/gunnailb_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 27c160.k10 --out roms/gunnailb_bgtile_raw.hex
	python3 $(TOOLS_DIR)/decode_gunnailb_gfx.py --mode bg --in roms/gunnailb_bgtile_raw.hex --out roms/gunnailb_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z2) --mode word_swap --files 92077-7.u134 --out roms/gunnailb_sprites_raw.hex
	python3 $(TOOLS_DIR)/decode_gunnailb_gfx.py --mode sprites --in roms/gunnailb_sprites_raw.hex --out roms/gunnailb_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_gunnailb.cpp $(FX68K_DIR)/fx68k.sv \
	roms/gunnailb_maincpu.hex roms/gunnailb_audiocpu.hex roms/gunnailb_oki.hex \
	roms/gunnailb_fgtile.hex roms/gunnailb_bgtile.hex roms/gunnailb_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/gunnailb_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/gunnailb_audiocpu.hex\" \
		-GOKI_ROM_FILE=\"roms/gunnailb_oki.hex\" \
		-GFGTILE_FILE=\"roms/gunnailb_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/gunnailb_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/gunnailb_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_gunnailb.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) gunnailb_video.trace microrom.mem nanorom.mem
