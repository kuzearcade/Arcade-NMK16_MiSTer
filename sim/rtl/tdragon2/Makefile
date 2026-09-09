# Verilator build for tdragon2 (Tier 3, Family C — second port, see
# rtl/tdragon2/tdragon2_core.sv's header). An unusually direct reuse of
# macross2's own infrastructure — see that port's own Makefile for the
# fuller commentary not repeated here.

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
MACROSS2_DIR := ../../../rtl/macross2
CORE_DIR := ../../../rtl/tdragon2
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := tdragon2_core
Z1 := $(ROMS_DIR)/tdragon2.zip

# video_macross2.sv and nmk112.sv are reused UNMODIFIED from Tier 3's
# macross2 (tdragon2()'s own machine config is byte-for-byte identical to
# macross2()'s own in every video/sound respect — see tdragon2_core.sv's
# own header). video_timing.sv/nmk_irq.sv/T80s.v/jt03 reused the same way
# macross2's own build already established.
SOURCES := $(CORE_DIR)/$(TOP).sv $(MACROSS2_DIR)/video_macross2.sv $(NMK112_DIR)/nmk112.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

.PHONY: all roms run clean

all: run

roms: rom audiocpu-rom oki-roms vtiming-rom gfx-roms

# maincpu: 6.rom, single ROM_LOAD16_WORD_SWAP file (nmk16.cpp:8333).
rom:
	python3 $(TOOLS_DIR)/mkrom_wordswap.py --zip $(Z1) --file 6.rom --out roms/tdragon2_maincpu.hex

# audiocpu: 5.bin — flat single-file load (nmk16.cpp:8335-8336), same
# shape as macross2's own.
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 5.bin --out roms/tdragon2_audiocpu.hex

# oki1 (ww930916.4, 0x200000) / oki2 (ww930915.3, 0x200000 — DOUBLE
# macross2's own oki2 size, see tdragon2_core.sv's header), both banked
# entirely through NMK112 (nmk16.cpp:8348-8352).
oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files ww930916.4 --out roms/tdragon2_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files ww930915.3 --out roms/tdragon2_oki2.hex

# nmk_irq's own real V-PROM (10.bpr, nmk16.cpp:8357-8358) — htiming
# (9.bpr) is not extracted, matching macross2's own Makefile (nmk_irq.sv
# never consumes it).
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 10.bpr --out roms/tdragon2_vtiming.hex

# fgtile (1.bin, 0x20000) / bgtile (ww930914.2, 0x200000) — plain concat,
# no descrambling. sprites (ww930917.7+ww930918.8, nmk16.cpp:8344-8346) —
# two ROM_LOAD16_WORD_SWAP files concatenated in region order.
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files 1.bin --out roms/tdragon2_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode concat --files ww930914.2 --out roms/tdragon2_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files ww930917.7 --out roms/tdragon2_sprites_p1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --mode word_swap --files ww930918.8 --out roms/tdragon2_sprites_p2.hex
	cat roms/tdragon2_sprites_p1.hex roms/tdragon2_sprites_p2.hex > roms/tdragon2_sprites.hex
	@n=$$(wc -l < roms/tdragon2_sprites.hex); \
	if [ "$$n" != "4194304" ]; then echo "error: tdragon2_sprites.hex has $$n lines, expected 4194304 (0x400000)"; exit 1; fi

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_tdragon2.cpp $(FX68K_DIR)/fx68k.sv \
	roms/tdragon2_maincpu.hex roms/tdragon2_audiocpu.hex roms/tdragon2_oki1.hex roms/tdragon2_oki2.hex \
	roms/tdragon2_vtiming.hex roms/tdragon2_fgtile.hex roms/tdragon2_bgtile.hex roms/tdragon2_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) $(EXTRA_VFLAGS) \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/tdragon2_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/tdragon2_audiocpu.hex\" \
		-GOKI1_ROM_FILE=\"roms/tdragon2_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/tdragon2_oki2.hex\" \
		-GVTIMING_FILE=\"roms/tdragon2_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/tdragon2_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/tdragon2_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/tdragon2_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_tdragon2.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) tdragon2_video.trace microrom.mem nanorom.mem
