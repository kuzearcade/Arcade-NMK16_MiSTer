# Verilator build for acrobatmbl (Tier 5, Family E — third Z80-based
# port, see rtl/acrobatmbl/acrobatmbl_core.sv's header).
#
# Usage:
#   make roms   # (re)build all ROM hex files from mame_roms/acrobatmbl.zip
#   make run    # build and run, produces acrobatmbl_video.trace + z80/m68k traces
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JTOPL_DIR := ../../../rtl/third_party/jtopl
JT6295_DIR := ../../../rtl/third_party/jt6295
BJTWIN_DIR := ../../../rtl/bjtwin
ACROBATM_DIR := ../../../rtl/acrobatm
SEIBU_DIR := ../../../rtl/seibu
CORE_DIR := ../../../rtl/acrobatmbl
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := acrobatmbl_core

# video_timing.sv + nmk_irq_hacky.sv reused unchanged from Tier 1's
# bjtwin (acrobatmbl's own timing PROMs are undumped too — MAME
# substitutes the same fixed-scanline table). video_acrobatm.sv reused
# unchanged from Tier 2's acrobatm (identical video/VRAM/scroll/tilebank
# register layout to acrobatmbl_map) — NOT acrobatm_core.sv's own 40MHz
# clock architecture, see acrobatmbl_core.sv's header. seibu_sound.sv +
# T80s.v reused unchanged from Tier 5's mustangb (byte-identical
# audiocpu ROM, same Seibu Sound System hardware).
SOURCES := $(CORE_DIR)/$(TOP).sv $(ACROBATM_DIR)/video_acrobatm.sv $(SEIBU_DIR)/seibu_sound.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv \
           $(T80_DIR)/T80s.v $(JTOPL_DIR)/hdl/jtopl2.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom patch-rom audiocpu-rom oki-rom gfx-roms

# maincpu: 4.10c (hi)/3.10f (lo), ROM_LOAD16_BYTE — see
# ROM_START(acrobatmbl), nmk16.cpp:7230-7231. Patched afterward (see
# patch-rom) — this game's own "PIC protection" is fully patched out by
# MAME itself (init_acrobatmbl(), nmk16.cpp:6238-6262) as 4 static word
# pokes, not a live circuit.
rom:
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/acrobatmbl.zip --hi 4.10c --lo 3.10f --out roms/acrobatmbl_maincpu.hex

patch-rom: rom
	python3 $(TOOLS_DIR)/patch_rom_words.py --in roms/acrobatmbl_maincpu.hex --out roms/acrobatmbl_maincpu.hex \
		--patch 0x364:0x0000 --patch 0x365:0x2d84 --patch 0x36a:0x0000 --patch 0x36b:0x3510

# audiocpu: 2.12w is byte-identical (CRC 99ee7505) to mustangb's own
# mustang.16 and tdragonb's own td_02.bin, same ROM_LOAD+ROM_CONTINUE+
# ROM_COPY layout (nmk16.cpp:7247-7250).
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatmbl.zip --mode segments \
		--files 2.12w \
		--segments 0x00000:0x00000:0x8000 --segments 0x10000:0x08000:0x8000 --segments 0x18000:0x00000:0x8000 \
		--out roms/acrobatmbl_audiocpu.hex

# oki: 1.14y — same CRC (f6f6c4bf) as mustangb's/tdragonb's own OKI ROM
# (see ROM_START(acrobatmbl), nmk16.cpp:7252-7253).
oki-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatmbl.zip --mode concat --files 1.14y --out roms/acrobatmbl_oki.hex

# fgtile (10m), bgtile (a.9x), and sprites part 1 (b.2k) are NOT present
# in acrobatmbl.zip itself — confirmed via `unzip -l` (only 1.14y/2.12w/
# 3.10f/4.10c/c.2m are there). acrobatmbl is a clone of acrobatm
# (GAME()'s parent field) and this local dump's split-romset convention
# omits files byte-identical to the parent set — BUT unlike mustangb's
# own parent/clone pair, the shared files are NOT stored under the same
# member name in both zips: 10m/a.9x/b.2k's own CRCs
# (d86c186e/7c12afed/5672bdaa) exactly match acrobatm.zip's own
# 3.ic79/am-03.ic8/am-01.ic42 (ROM_START(acrobatm), nmk16.cpp:7202-7209),
# a different filename per socket-label naming on that board. mkgfxrom.py's
# own --zip fallback only tries the SAME filename in each zip in turn
# (read_from_any(), plain per-zip `zip.read(filename)`, no CRC lookup),
# so this needs the parent zip's own actual member names, not
# acrobatmbl_map's.
#
# sprites (nmk16.cpp:7242-7245) has a real trap: b.2k (via acrobatm.zip's
# own am-01.ic42) loads in full (0x100000 bytes) at region offset 0, but
# c.2m (acrobatmbl.zip's own, unique to this bootleg — CRC a3f5a3e0, not
# shared with the parent) is a 0x100000-byte file of which only the
# FIRST HALF is used (ROM_IGNORE(0x080000) — "1ST AND 2ND HALF
# IDENTICAL"). Loading the full c.2m file would overflow the declared
# 0x180000-byte sprites region (0x100000+0x100000=0x200000).
# mkgfxrom.py's segments mode (single file, one segment) truncates c.2m
# to exactly its used first half; the two resulting hex files are then
# concatenated in ROM_START order.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files 3.ic79 --out roms/acrobatmbl_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files am-03.ic8 --out roms/acrobatmbl_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatm.zip --mode concat --files am-01.ic42 --out roms/acrobatmbl_sprites_p1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/acrobatmbl.zip --mode segments --files c.2m --segments 0x00000:0x00000:0x80000 --out roms/acrobatmbl_sprites_p2.hex
	cat roms/acrobatmbl_sprites_p1.hex roms/acrobatmbl_sprites_p2.hex > roms/acrobatmbl_sprites.hex
	@n=$$(wc -l < roms/acrobatmbl_sprites.hex); \
	if [ "$$n" != "1572864" ]; then echo "error: acrobatmbl_sprites.hex has $$n lines, expected 1572864 (0x180000)"; exit 1; fi

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_acrobatmbl.cpp $(FX68K_DIR)/fx68k.sv \
	roms/acrobatmbl_maincpu.hex roms/acrobatmbl_audiocpu.hex roms/acrobatmbl_oki.hex \
	roms/acrobatmbl_fgtile.hex roms/acrobatmbl_bgtile.hex roms/acrobatmbl_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(JTOPL_DIR)/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/acrobatmbl_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/acrobatmbl_audiocpu.hex\" \
		-GOKI_ROM_FILE=\"roms/acrobatmbl_oki.hex\" \
		-GFGTILE_FILE=\"roms/acrobatmbl_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/acrobatmbl_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/acrobatmbl_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_acrobatmbl.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) acrobatmbl_video.trace microrom.mem nanorom.mem
