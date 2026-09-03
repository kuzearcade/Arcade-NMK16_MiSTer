# Verilator build for tdragonb (Tier 5, Family E — second Z80-based
# port, see rtl/tdragonb/tdragonb_core.sv's header).
#
# Usage:
#   make roms   # (re)build all ROM hex files from mame_roms/tdragonb.zip
#   make run    # build and run, produces tdragonb_video.trace + z80/m68k traces
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JTOPL_DIR := ../../../rtl/third_party/jtopl
JT6295_DIR := ../../../rtl/third_party/jt6295
BJTWIN_DIR := ../../../rtl/bjtwin
TDRAGON_DIR := ../../../rtl/tdragon
SEIBU_DIR := ../../../rtl/seibu
CORE_DIR := ../../../rtl/tdragonb
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := tdragonb_core

# video_timing.sv + nmk_irq_hacky.sv reused unchanged from Tier 1's
# bjtwin (tdragonb's own timing PROMs are undumped too — MAME
# substitutes the same fixed-scanline table). video_tdragon.sv reused
# unchanged from Tier 2's tdragon (identical video/VRAM/scroll/tilebank
# register layout to tdragonb_map). seibu_sound.sv + T80s.v reused
# unchanged from Tier 5's mustangb (byte-identical audiocpu ROM, same
# Seibu Sound System hardware). See rtl/tdragonb/tdragonb_core.sv's
# header for the full derivation.
SOURCES := $(CORE_DIR)/$(TOP).sv $(TDRAGON_DIR)/video_tdragon.sv $(SEIBU_DIR)/seibu_sound.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv \
           $(T80_DIR)/T80s.v $(JTOPL_DIR)/hdl/jtopl2.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom decode-rom audiocpu-rom oki-rom gfx-roms

# maincpu: td_04.bin (hi)/td_03.bin (lo), ROM_LOAD16_BYTE — see
# ROM_START(tdragonb), nmk16.cpp:7578-7580. Decrypted afterward (see
# decode-rom) — this game's maincpu ROM is scrambled via a static,
# one-time bit-permutation (decode_tdragonb(), nmk16.cpp:6082-6125),
# NOT a live hardware descrambler.
rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/tdragonb.zip --hi td_04.bin --lo td_03.bin --out roms/tdragonb_maincpu.hex

decode-rom: rom
	python3 $(TOOLS_DIR)/decode_tdragonb.py --mode word --in roms/tdragonb_maincpu.hex --out roms/tdragonb_maincpu.hex

# audiocpu: td_02.bin is byte-identical (CRC 99ee7505) to mustangb's own
# mustang.16, same ROM_LOAD+ROM_CONTINUE+ROM_COPY layout (nmk16.cpp:7582-7585).
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragonb.zip --mode segments \
		--files td_02.bin \
		--segments 0x00000:0x00000:0x8000 --segments 0x10000:0x08000:0x8000 --segments 0x18000:0x00000:0x8000 \
		--out roms/tdragonb_audiocpu.hex

# oki: td_01.bin (see ROM_START(tdragonb), nmk16.cpp:7598-7599). Not
# touched by decode_tdragonb().
oki-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragonb.zip --mode concat --files td_01.bin --out roms/tdragonb_oki.hex

# fgtile (td_08.bin, not decoded), bgtile (td_06.bin+td_07.bin concat,
# THEN decoded — decode_tdragonb() operates on the fully-assembled
# region), sprites (td_10.bin hi/td_09.bin lo interleaved, THEN decoded)
# — see ROM_START(tdragonb), nmk16.cpp:7587-7596.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragonb.zip --mode concat --files td_08.bin --out roms/tdragonb_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragonb.zip --mode concat --files td_06.bin td_07.bin --out roms/tdragonb_bgtile.hex
	python3 $(TOOLS_DIR)/decode_tdragonb.py --mode byte --in roms/tdragonb_bgtile.hex --out roms/tdragonb_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragonb.zip --mode interleave16 --hi td_10.bin --lo td_09.bin --out roms/tdragonb_sprites.hex
	python3 $(TOOLS_DIR)/decode_tdragonb.py --mode byte --in roms/tdragonb_sprites.hex --out roms/tdragonb_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_tdragonb.cpp $(FX68K_DIR)/fx68k.sv \
	roms/tdragonb_maincpu.hex roms/tdragonb_audiocpu.hex roms/tdragonb_oki.hex \
	roms/tdragonb_fgtile.hex roms/tdragonb_bgtile.hex roms/tdragonb_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(JTOPL_DIR)/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/tdragonb_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/tdragonb_audiocpu.hex\" \
		-GOKI_ROM_FILE=\"roms/tdragonb_oki.hex\" \
		-GFGTILE_FILE=\"roms/tdragonb_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/tdragonb_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/tdragonb_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_tdragonb.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) tdragonb_video.trace microrom.mem nanorom.mem
