# Verilator build for raphero (Tier 3, Family C — third port). See
# rtl/raphero/raphero_core.sv's own header for the fuller commentary not
# repeated here (TLCS-90 sound CPU + nmk004_periph.sv reuse; genuine
# hybrid video). arcadian/raphero/rapheroa all share the identical
# raphero() machine config — this Makefile targets `raphero` itself.
#
# ROM sourcing: raphero is a CLONE (GAME()'s parent field is `arcadian`,
# nmk16.cpp:10747) and this local dump's split-romset convention omits
# every file byte-identical to the parent set — confirmed via `unzip -l`:
# raphero.zip itself has only "3" (maincpu) and "rhp94099.1" (fgtile);
# every other region (audiocpu, bgtile, sprites x3, oki1/oki2's four
# files, both real PROMs) lives in arcadian.zip under the SAME member
# names raphero's own ROM_START(raphero) already lists (unlike
# acrobatmbl's own parent pair, no renamed-socket-label case here — see
# that port's own Makefile if this ever needs to change). mkgfxrom.py's
# own --zip is `action="append"`, tried in order per filename
# (read_from_any(), no CRC lookup) — so every gfx-rom rule passes BOTH
# zips, raphero.zip first.
FX68K_DIR := ../../../rtl/third_party/fx68k
TLCS90_DIR := ../../../rtl/tlcs90
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
CORE_DIR := ../../../rtl/raphero
MACROSS2_DIR := ../../../rtl/macross2
RTL_DIR := ../../../rtl
ROMS_DIR := ../../../mame_roms
TOOLS_DIR := ../../../tools
OBJ_DIR := obj_dir
TOP := raphero_core
Z1 := $(ROMS_DIR)/raphero.zip
Z2 := $(ROMS_DIR)/arcadian.zip

# Video is rtl/macross2/video_macross2.sv with RASTER_SCROLL=1 (per-line
# scroll taps) and SPRITES_BYTES=0x600000 — the hardware-ready module,
# so the reference sim and Raphero.rbf share one video path. The SDRAM/
# cache modules are listed so their (unelaborated at HW_ROMS=0) generate
# branches resolve. tlcs90.sv/nmk004_periph.sv run on clk_sys with an
# 8 MHz clock enable here (see raphero_core.sv's header).
SOURCES := $(CORE_DIR)/$(TOP).sv $(MACROSS2_DIR)/video_macross2.sv $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv \
           $(NMK112_DIR)/nmk112.sv $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv \
           $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv

.PHONY: all roms run clean

all: run

roms: rom audiocpu-rom oki-roms vtiming-rom gfx-roms

# maincpu: "3", single ROM_LOAD16_WORD_SWAP file (nmk16.cpp:8584),
# present in raphero.zip itself — no parent fallback needed.
rom:
	python3 $(TOOLS_DIR)/mkrom_wordswap.py --zip $(Z1) --file 3 --out roms/raphero_maincpu.hex

# audiocpu: rhp94099.2, 0x20000 flat image (nmk16.cpp:8586-8587) — parent
# zip only (not in raphero.zip).
audiocpu-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files rhp94099.2 --out roms/raphero_audiocpu.hex

# oki1 (rhp94099.6+rhp94099.7, nmk16.cpp:8598-8600) / oki2
# (rhp94099.5+rhp94099.6, nmk16.cpp:8602-8604) — TRAP: rhp94099.6 is
# byte-identical (same CRC f1a80e5a) between oki1's own FIRST file and
# oki2's own SECOND file. Extracted independently per its own ROM_START
# listing below (each region reads it once, in its own region's own
# offset order) — do NOT try to deduplicate.
oki-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files rhp94099.6 rhp94099.7 --out roms/raphero_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files rhp94099.5 rhp94099.6 --out roms/raphero_oki2.hex

# nmk_irq's own real V-PROM (prom2.u53, nmk16.cpp:8608-8609) — htiming
# (prom1.u19) is not extracted (nmk_irq.sv never consumes it, same as
# every prior port); "color" (prom3.u60) is skipped entirely (zero
# consumers in the emulation, confirmed via grep, same as prior ports).
vtiming-rom:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files prom2.u53 --out roms/raphero_vtiming.hex

# fgtile (rhp94099.1, 0x20000 — present in raphero.zip itself) / bgtile
# (rhp94099.4, 0x200000 — parent zip only), plain concat, no
# descrambling. sprites (rhp94099.8+9+10, nmk16.cpp:8595-8597) — THREE
# ROM_LOAD16_WORD_SWAP files concatenated in region order (0x600000
# total, bigger than any prior port's own sprite ROM).
gfx-roms:
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files rhp94099.1 --out roms/raphero_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files rhp94099.4 --out roms/raphero_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode word_swap --files rhp94099.8 --out roms/raphero_sprites_p1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode word_swap --files rhp94099.9 --out roms/raphero_sprites_p2.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode word_swap --files rhp94099.10 --out roms/raphero_sprites_p3.hex
	cat roms/raphero_sprites_p1.hex roms/raphero_sprites_p2.hex roms/raphero_sprites_p3.hex > roms/raphero_sprites.hex
	@n=$$(wc -l < roms/raphero_sprites.hex); \
	if [ "$$n" != "6291456" ]; then echo "error: raphero_sprites.hex has $$n lines, expected 6291456 (0x600000)"; exit 1; fi

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_raphero.cpp $(FX68K_DIR)/fx68k.sv \
	roms/raphero_maincpu.hex roms/raphero_audiocpu.hex roms/raphero_oki1.hex roms/raphero_oki2.hex \
	roms/raphero_vtiming.hex roms/raphero_fgtile.hex roms/raphero_bgtile.hex roms/raphero_sprites.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"roms/raphero_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"roms/raphero_audiocpu.hex\" \
		-GOKI1_ROM_FILE=\"roms/raphero_oki1.hex\" \
		-GOKI2_ROM_FILE=\"roms/raphero_oki2.hex\" \
		-GVTIMING_FILE=\"roms/raphero_vtiming.hex\" \
		-GFGTILE_FILE=\"roms/raphero_fgtile.hex\" \
		-GBGTILE_FILE=\"roms/raphero_bgtile.hex\" \
		-GSPRITES_FILE=\"roms/raphero_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_raphero.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) raphero_video.trace microrom.mem nanorom.mem
