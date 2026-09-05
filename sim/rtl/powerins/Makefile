# Verilator build for powerins (Tier 3, Family C — fourth and final
# currently-known port, see rtl/powerins/powerins_core.sv's own header).
#
# Usage:
#   make roms   # (re)build all ROM hex files from mame_roms/powerins.zip
#   make run    # build and run, produces powerins_video.trace + z80/m68k traces
#   make clean

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
CORE_DIR := ../../../rtl/powerins
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := powerins_core
Z1 := $(ROMS_DIR)/powerins.zip

# video_timing.sv reused unchanged from Tier 1's bjtwin (see
# powerins_core.sv's own header for this port's own "is this really
# game-agnostic" re-derivation). rtl/nmk_irq/nmk_irq.sv is the real
# V-PROM-driven interrupt generator. rtl/nmk112/nmk112.sv is the reusable
# OKI bank-switcher. T80s.v reused unchanged. jt03 (YM2203)/jt6295 (OKI)
# reused unchanged. video_powerins.sv is this port's own new file (see its
# own header for the full derivation — no tilerambank, 11-bit BG code,
# 6-bit sprite colour, genuinely new sprite horizontal-flip logic).
SOURCES := $(CORE_DIR)/$(TOP).sv $(CORE_DIR)/video_powerins.sv $(NMK112_DIR)/nmk112.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom audiocpu-rom oki-roms vtiming-rom gfx-roms

# maincpu: TWO ROM_LOAD16_WORD_SWAP files at consecutive offsets
# (93095-3a.u108@0x00000, 93095-4.u109@0x80000, nmk16.cpp:8994-8998) —
# mkrom_wordswap.py's own --file is now action="append" (extended for
# this port), concatenating each file's word-swapped output in order.
rom:
	python3 $(TOOLS_DIR)/mkrom_wordswap.py --zip $(Z1) --file 93095-3a.u108 --file 93095-4.u109 --out roms/powerins_maincpu.hex

# audiocpu: 93095-2.u90, 0x20000 flat image (nmk16.cpp:9000-9001) — only
# the first 0xC000 bytes are ever mapped (powerins_sound_map has no
# banking at all, see powerins_core.sv's own header).
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 93095-2.u90 --out roms/powerins_audiocpu.hex

# oki1 (93095-10.u48+93095-11.u49, 0x200000, nmk16.cpp:9027-9028) / oki2
# (93095-8.u46+93095-9.u47, 0x200000, nmk16.cpp:9029-9030) — both banked
# entirely through NMK112. Distinct CRCs throughout, no shared-file trap.
oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 93095-10.u48 93095-11.u49 --out roms/powerins_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 93095-8.u46 93095-9.u47 --out roms/powerins_oki2.hex

# nmk_irq's own real V-PROM (21.u71, nmk16.cpp:9032-9033) — htiming
# (20.u54) is NOT extracted, matching rtl/nmk_irq/nmk_irq.sv's own header
# note that MAME's own nmk_irq_device never consumes the H-timing PROM.
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 21.u71 --out roms/powerins_vtiming.hex

# fgtile (93095-1.u15, 0x100000) / bgtile (93095-5.u16+93095-6.u17+93095-7.u18,
# 0x280000 concat) — plain concat, no descrambling (no protection MCU on
# this board). sprites (93095-12.u116..93095-19.u123, nmk16.cpp:9010-9018)
# — EIGHT ROM_LOAD16_WORD_SWAP files concatenated in region order
# (0x800000 total, double raphero's own 0x600000).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 93095-1.u15 --out roms/powerins_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 93095-5.u16 93095-6.u17 93095-7.u18 --out roms/powerins_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-12.u116 --out roms/powerins_sprites_p1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-13.u117 --out roms/powerins_sprites_p2.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-14.u118 --out roms/powerins_sprites_p3.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-15.u119 --out roms/powerins_sprites_p4.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-16.u120 --out roms/powerins_sprites_p5.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-17.u121 --out roms/powerins_sprites_p6.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-18.u122 --out roms/powerins_sprites_p7.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files 93095-19.u123 --out roms/powerins_sprites_p8.hex
	cat roms/powerins_sprites_p1.hex roms/powerins_sprites_p2.hex roms/powerins_sprites_p3.hex roms/powerins_sprites_p4.hex \
	    roms/powerins_sprites_p5.hex roms/powerins_sprites_p6.hex roms/powerins_sprites_p7.hex roms/powerins_sprites_p8.hex \
	    > roms/powerins_sprites.hex
	@n=$$(wc -l < roms/powerins_sprites.hex); \
	if [ "$$n" != "8388608" ]; then echo "error: powerins_sprites.hex has $$n lines, expected 8388608 (0x800000)"; exit 1; fi

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_powerins.cpp $(FX68K_DIR)/fx68k.sv \
	roms/powerins_maincpu.hex roms/powerins_audiocpu.hex roms/powerins_oki1.hex roms/powerins_oki2.hex \
	roms/powerins_vtiming.hex roms/powerins_fgtile.hex roms/powerins_bgtile.hex roms/powerins_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/powerins_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/powerins_audiocpu.hex\" \
		-GOKI1_ROM_FILE=\"roms/powerins_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/powerins_oki2.hex\" \
		-GVTIMING_FILE=\"roms/powerins_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/powerins_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/powerins_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/powerins_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_powerins.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) powerins_video.trace microrom.mem nanorom.mem
