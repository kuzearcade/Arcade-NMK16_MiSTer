# Verilator build for mustangb (Tier 5, Family E — first Z80-based port,
# see rtl/mustangb/mustangb_core.sv's header).
#
# Usage:
#   make roms   # (re)build all ROM hex files from mame_roms/mustangb.zip
#   make run    # build and run, produces mustangb_video.trace + z80/m68k traces
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JTOPL_DIR := ../../../rtl/third_party/jtopl
JT6295_DIR := ../../../rtl/third_party/jt6295
BJTWIN_DIR := ../../../rtl/bjtwin
MUSTANG_DIR := ../../../rtl/mustang
SEIBU_DIR := ../../../rtl/seibu
CORE_DIR := ../../../rtl/mustangb
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := mustangb_core

# video_timing.sv + nmk_irq_hacky.sv reused unchanged from Tier 1's
# bjtwin (mustangb's own timing PROMs are undumped — MAME substitutes the
# same fixed-scanline table cactus uses; see mustangb_core.sv's header).
# video_mustang.sv reused unchanged from Tier 2's mustang (identical
# screen_update_macross/gfx_macross video architecture). T80s.v is the
# GHDL-translated Verilog synthesis of the real vendored T80 VHDL Z80
# core (docs/t80-vhdl-toolchain.md). jtopl2.v is jtopl's own YM3812/OPL2
# top-level (see rtl/third_party/jtopl/hdl/jtopl2.v); its many internal
# jtopl_*.v dependencies are resolved via -y directory search below.
SOURCES := $(CORE_DIR)/$(TOP).sv $(MUSTANG_DIR)/video_mustang.sv $(SEIBU_DIR)/seibu_sound.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv \
           $(T80_DIR)/T80s.v $(JTOPL_DIR)/hdl/jtopl2.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

# maincpu: mustang.14 (hi)/mustang.13 (lo), ROM_LOAD16_BYTE — see
# ROM_START(mustangb), nmk16.cpp:7037-7039.
roms: rom audiocpu-rom oki-rom gfx-roms

rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/mustangb.zip --hi mustang.14 --lo mustang.13 --out roms/mustangb_maincpu.hex

# audiocpu: mustang.16 is a single 0x10000-byte file, ROM_LOAD'd as its
# own first half (0x8000 bytes) at region offset 0, ROM_CONTINUE'd as its
# own second half at region offset 0x10000, then ROM_COPY duplicates
# region 0x0-0x7FFF to region 0x18000-0x1FFFF (see mustangb_core.sv's
# header "Audiocpu ROM layout" for the full derivation) — the third
# segment below re-reads FILE offset 0 into region 0x18000, which is
# byte-identical to what ROM_COPY produces since ROM_COPY's own source is
# itself unmodified file content.
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustangb.zip --mode segments \
		--files mustang.16 \
		--segments 0x00000:0x00000:0x8000 --segments 0x10000:0x08000:0x8000 --segments 0x18000:0x00000:0x8000 \
		--out roms/mustangb_audiocpu.hex

# oki: mustang.17 (see ROM_START(mustangb), nmk16.cpp:7056-7057).
oki-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustangb.zip --mode concat --files mustang.17 --out roms/mustangb_oki.hex

# fgtile/bgtile/sprites — 90058-1/90058-4/90058-8+90058-9, byte-identical
# CRCs to mustang's own ROM_START entries (nmk16.cpp:7046-7054) confirm
# these are the same files; mustangb is a clone of mustang (GAME() parent
# field) so MAME's split-ROM convention stores them only in mustang.zip,
# not mustangb.zip — search both, parent first.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --zip $(ROMS_DIR)/mustangb.zip --mode concat --files 90058-1 --out roms/mustangb_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --zip $(ROMS_DIR)/mustangb.zip --mode concat --files 90058-4 --out roms/mustangb_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/mustang.zip --zip $(ROMS_DIR)/mustangb.zip --mode interleave16 --hi 90058-8 --lo 90058-9 --out roms/mustangb_sprites.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_mustangb.cpp $(FX68K_DIR)/fx68k.sv \
	roms/mustangb_maincpu.hex roms/mustangb_audiocpu.hex roms/mustangb_oki.hex \
	roms/mustangb_fgtile.hex roms/mustangb_bgtile.hex roms/mustangb_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(JTOPL_DIR)/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/mustangb_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/mustangb_audiocpu.hex\" \
		-GOKI_ROM_FILE=\"roms/mustangb_oki.hex\" \
		-GFGTILE_FILE=\"roms/mustangb_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/mustangb_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/mustangb_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_mustangb.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) mustangb_video.trace microrom.mem nanorom.mem
