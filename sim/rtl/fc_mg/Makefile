# Family C multi-game reference sim (2026-09-12): rtl/tdragon2/tdragon2_core.sv
# (the Macross2.rbf core) at HW_ROMS=0 for the clone modes —
#   make GAME=tdragon3h|powerinsa|powerinsb|powerinsc roms run
# TB_GAME_BYTE is the .mra <switches> third byte (see tb_fc_mg.cpp);
# TB_DUMP_PPM=1 dumps every frame as <game>_frame_NN.ppm for
# $SP/mg_cmp.py against MAME exact-frame snapshots (320 px wide for the
# powerins sets, 384 for tdragon3h). ROM hex files go to ../<game>/roms.
GAME ?= tdragon3h

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
MACROSS2_DIR := ../../../rtl/macross2
CORE_DIR := ../../../rtl/tdragon2
TOOLS_DIR := ../../../tools
ROMS_DIR := ../../../mame_roms
OBJ_DIR := obj_dir_$(GAME)
TOP := tdragon2_core
R := ../$(GAME)/roms/$(GAME)
CYCLES ?= 300000000

SOURCES := $(CORE_DIR)/$(TOP).sv $(MACROSS2_DIR)/video_macross2.sv $(NMK112_DIR)/nmk112.sv \
           $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v

GB_tdragon3h := 04
GB_powerinsa := 1A
GB_powerinsb := 0A
GB_powerinsc := 2A
GAME_BYTE := $(GB_$(GAME))

# Sim array sizes (video_macross2.sv HW_ROMS=0): tdragon2's 4 MB / 2 MB,
# powerins' 8 MB / 0x280000 (powerinsc's BG region is 0x300000).
SPR_BYTES := 8388608
BG_BYTES := 2621440
ifeq ($(GAME),tdragon3h)
SPR_BYTES := 4194304
BG_BYTES := 2097152
endif
ifeq ($(GAME),powerinsc)
BG_BYTES := 3145728
endif
AUDIOCPU := $(R)_audiocpu.hex
OKI1 := $(R)_oki1.hex
OKI2 := $(R)_oki2.hex
ifeq ($(GAME),tdragon3h)
OKI1 :=
endif
ifeq ($(GAME),powerinsa)
AUDIOCPU :=
OKI2 :=
endif
VTIMING := ../powerins_tc/roms/tdragon2_powerins_vtiming.hex

.PHONY: all roms run clean

all: run

# ROM hex per set, transcribed from nmk16.cpp's ROM_START blocks. Files a
# split clone set shares with its parent come from the parent zip.
roms:
ifeq ($(GAME),tdragon3h)
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/tdragon3h.zip --hi h.27c2001 --lo l.27c020 --out $(R)_maincpu.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon2.zip --mode concat --files 5.bin --out $(R)_audiocpu.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon3h.zip --mode concat --files 12.27c1000 --out $(R)_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon3h.zip --mode concat --files conny.3 conny.4 --out $(R)_bgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon3h.zip --mode interleave16 --hi conny.2 --lo conny.1 --out $(R)_sprites_a.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon2.zip --mode word_swap --files ww930918.8 --out $(R)_sprites_b.hex
	cat $(R)_sprites_a.hex $(R)_sprites_b.hex > $(R)_sprites.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/tdragon3h.zip --mode concat --files conny.6 conny.7 --out $(R)_oki2.hex
endif
ifeq ($(GAME),powerinsa)
	python3 $(TOOLS_DIR)/mkrom_wordswap.py --zip $(ROMS_DIR)/powerinsa.zip --file rom1 --out $(R)_maincpu_a.hex
	python3 $(TOOLS_DIR)/mkrom_wordswap.py --zip $(ROMS_DIR)/powerins.zip --file 93095-4.u109 --out $(R)_maincpu_b.hex
	cat $(R)_maincpu_a.hex $(R)_maincpu_b.hex > $(R)_maincpu.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerins.zip --mode concat --files 93095-1.u15 --out $(R)_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsa.zip --zip $(ROMS_DIR)/powerins.zip --mode concat --files rom6 93095-7.u18 --out $(R)_bgtile.hex
	for f in rom10 rom9 rom8 rom7; do python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsa.zip --mode word_swap --files $$f --out $(R)_sprites_$$f.hex; done
	cat $(R)_sprites_rom10.hex $(R)_sprites_rom9.hex $(R)_sprites_rom8.hex $(R)_sprites_rom7.hex > $(R)_sprites.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsa.zip --mode concat --files rom5 --out $(R)_oki1.hex
endif
ifeq ($(GAME),powerinsb)
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/powerinsb.zip --hi 2q.bin --lo 2r.bin --out $(R)_maincpu.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerins.zip --mode concat --files 93095-2.u90 --out $(R)_audiocpu.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerins.zip --mode concat --files 93095-1.u15 --out $(R)_fgtile.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsb.zip --zip $(ROMS_DIR)/powerins.zip --mode concat --files 13k.bin 13l.bin 13o.bin 13q.bin 93095-7.u18 --out $(R)_bgtile.hex
	for p in 11g:14g 11i:13g 11j:12g 11k:14m 11l:14n 11o:14p 11p:13p 11q:12p; do e=$${p%:*}; o=$${p#*:}; python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsb.zip --mode interleave16 --hi $$e.bin --lo $$o.bin --out $(R)_sprites_$$e.hex; done
	cat $(R)_sprites_11g.hex $(R)_sprites_11i.hex $(R)_sprites_11j.hex $(R)_sprites_11k.hex $(R)_sprites_11l.hex $(R)_sprites_11o.hex $(R)_sprites_11p.hex $(R)_sprites_11q.hex > $(R)_sprites.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsb.zip --mode concat --files 4a.bin 4b.bin 4c.bin 4d.bin --out $(R)_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsb.zip --mode concat --files 5a.bin 5b.bin 5c.bin 5d.bin --out $(R)_oki2.hex
endif
ifeq ($(GAME),powerinsc)
	python3 $(TOOLS_DIR)/mkrom.py --zip $(ROMS_DIR)/powerinsc.zip --hi 10.040.u41 --lo 11.040.u39 --out $(R)_maincpu.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerins.zip --mode concat --files 93095-2.u90 --out $(R)_audiocpu.hex
	for p in 33.040.u99:22.040.u97 32.040.u100:21.040.u98 31.040.u102:20.040.u101; do e=$${p%:*}; o=$${p#*:}; python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsc.zip --mode interleave16 --hi $$e --lo $$o --out $(R)_bgtile_$$e.hex; done
	cat $(R)_bgtile_33.040.u99.hex $(R)_bgtile_32.040.u100.hex $(R)_bgtile_31.040.u102.hex > $(R)_bgtile.hex
	sed -n '2621441,2752512p' $(R)_bgtile.hex > $(R)_fgtile.hex
	for p in 30.040.u82:19.040.u91 29.040.u85:18.040.u84 28.040.u88:17.040.u87 27.040.u91:16.040.u90 26.040.u93:15.040.u81 25.040.u94:14.040.u96 24.040.u95:13.040.u89 23.040.u96:12.040.u92; do e=$${p%:*}; o=$${p#*:}; python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsc.zip --mode interleave16 --hi $$e --lo $$o --out $(R)_sprites_$$e.hex; done
	cat $(R)_sprites_30.040.u82.hex $(R)_sprites_29.040.u85.hex $(R)_sprites_28.040.u88.hex $(R)_sprites_27.040.u91.hex $(R)_sprites_26.040.u93.hex $(R)_sprites_25.040.u94.hex $(R)_sprites_24.040.u95.hex $(R)_sprites_23.040.u96.hex > $(R)_sprites.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsc.zip --mode concat --files 9.040.u32 8.040.u30 7.040.u33 6.040.u31 --out $(R)_oki1.hex
	python3 $(TOOLS_DIR)/mkgfxrom.py --zip $(ROMS_DIR)/powerinsc.zip --mode concat --files 5.040.u36 4.040.u34 3.040.u37 2.040.u35 --out $(R)_oki2.hex
endif

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_fc_mg.cpp $(FX68K_DIR)/fx68k.sv
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module $(TOP) $(EXTRA_VFLAGS) \
		-Mdir $(OBJ_DIR) \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		-GROM_FILE=\"$(R)_maincpu.hex\" \
		-GAUDIOCPU_FILE=\"$(AUDIOCPU)\" \
		-GOKI1_ROM_FILE=\"$(OKI1)\" \
		-GOKI2_ROM_FILE=\"$(OKI2)\" \
		-GVTIMING_FILE=\"$(VTIMING)\" \
		-GFGTILE_FILE=\"$(R)_fgtile.hex\" \
		-GBGTILE_FILE=\"$(R)_bgtile.hex\" \
		-GSPRITES_BYTES=$(SPR_BYTES) -GBGTILE_BYTES=$(BG_BYTES) -GSPRITES_FILE=\"$(R)_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_fc_mg.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	TB_GAME_BYTE=$(GAME_BYTE) TB_PREFIX=$(GAME) ./$(OBJ_DIR)/V$(TOP) $(CYCLES)

clean:
	rm -rf obj_dir_* *.trace microrom.mem nanorom.mem *_frame_*.ppm
