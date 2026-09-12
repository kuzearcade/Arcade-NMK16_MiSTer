# Verilator reference sims for the multi-game Gunnail core (2026-09-11):
# rtl/gunnail/gunnail_core.sv at HW_ROMS=0 with game_sel = one of the nine
# lowres NMK004 boards (or gunnail itself), ROM hex files from each game's
# own single-game sim directory (../<game>/roms, built by that Makefile's
# rom/gfx-roms/oki-roms targets) and the four-table V-PROM file
# roms/gunnail_multi_vtiming.hex at the repo root (Gunnail.sv's own).
#
#   make GAME=blkheart run            # build obj_dir_blkheart, run 300M cycles
#   make GAME=bioship CYCLES=60000000 run
#   TB_DUMP_PPM=1 make GAME=strahl run
# Games: macross blkheart mustang bioship vandyke acrobatm strahl tdragon hachamf tdragon1 gunnail
#        hachamfb bjtwin bjtwinp sabotenb nouryoku cactus nouryokup tharrier vandykeb

GAME   ?= blkheart
CYCLES ?= 300000000

FX68K_DIR := ../../../rtl/third_party/fx68k
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
TLCS90_DIR := ../../../rtl/tlcs90
BJTWIN_DIR := ../../../rtl/bjtwin
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK214_DIR := ../../../rtl/nmk214
CORE_DIR := ../../../rtl/gunnail
MACROSS2_DIR := ../../../rtl/macross2
RTL_DIR := ../../../rtl
TOP := gunnail_core
OBJ_DIR := obj_dir_$(GAME)
R := ../$(GAME)/roms/$(GAME)

SOURCES := $(CORE_DIR)/$(TOP).sv $(MACROSS2_DIR)/video_macross2.sv $(NMK214_DIR)/nmk214.sv \
           $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv $(TLCS90_DIR)/nmk_prot_core.sv \
           $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv \
           $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv $(RTL_DIR)/rom_cache_n.sv $(RTL_DIR)/rom_cache_n_byte.sv \
           $(RTL_DIR)/nmk112/nmk112.sv $(RTL_DIR)/third_party_gen/t80/T80s.v $(RTL_DIR)/third_party/jt51/hdl/jt51.v

# Per-game table: game id (gunnail_core.sv G_*), NMK004 external program,
# protection ROM, second tile ROM, bioship's tilemap ROM.
SEL_gunnail  := 0
SEL_macross  := 1
SEL_blkheart := 2
SEL_mustang  := 3
SEL_bioship  := 4
SEL_vandyke  := 5
SEL_acrobatm := 6
SEL_strahl   := 7
SEL_tdragon  := 8
SEL_hachamf  := 9
SEL_tdragon1 := 10
SEL_hachamfb := 13
SEL_bjtwin   := 14
SEL_bjtwinp  := 15
SEL_sabotenb := 17
SEL_nouryoku := 17
SEL_cactus   := 18
SEL_nouryokup := 19
SEL_tharrier := 20
SEL_vandykeb := 21
SEL_mustangb3 := 22
# Afega (Family H): ids 23-43, see gunnail_core.sv; hex from `tools/gen_gunnail_mra.py --simroms <set> ../<set>/roms`
AFEGA_SETS := stagger1 redhawk redhawki redhawks redhawksa redhawkg redhawke redhawkk redhawkc redhawkb grdnstrm grdnstrmv grdnstrmj grdnstrmk redfoxwp2 redfoxwp2a grdnstrmg grdnstrmau bubl2000 bubl2000a hotbubl hotbubla popspops mangchi spec2k spec2kh firehawk
AFEGA_8BPP := grdnstrm grdnstrmv grdnstrmj grdnstrmk redfoxwp2 redfoxwp2a grdnstrmg grdnstrmau bubl2000 bubl2000a hotbubl hotbubla popspops mangchi spec2k spec2kh firehawk
SEL_stagger1 := 23
SEL_redhawke := 23
SEL_redhawkk := 23
SEL_redhawkc := 23
SEL_redhawk  := 24
SEL_redhawki := 25
SEL_redhawks := 26
SEL_redhawksa := 27
SEL_redhawkg := 28
SEL_redhawkb := 29
SEL_grdnstrm := 30
SEL_grdnstrmk := 31
SEL_grdnstrmv := 31
SEL_grdnstrmj := 32
SEL_grdnstrmg := 33
SEL_grdnstrmau := 34
SEL_redfoxwp2 := 35
SEL_redfoxwp2a := 36
SEL_popspops := 37
SEL_mangchi  := 38
SEL_bubl2000 := 39
SEL_bubl2000a := 39
SEL_hotbubl  := 39
SEL_firehawk := 40
SEL_spec2k   := 41
SEL_spec2kh  := 42
SEL_hotbubla := 43
SEL := $(SEL_$(GAME))
# ROM hex directory: sim/rtl/<game>/roms, except bjtwin and cactus (sim/rtl/bjtwin/roms)
ifneq ($(filter $(GAME),bjtwin cactus),)
R := ../bjtwin/roms/$(GAME)
endif
EXT := ../tlcs90/roms/$(GAME)_ext.hex
ifeq ($(GAME),tdragon1)
EXT := ../tlcs90/roms/tdragon_ext.hex
endif
ifeq ($(GAME),hachamfb)
EXT := ../tlcs90/roms/hachamf_ext.hex
endif
ifneq ($(filter $(GAME),bjtwin bjtwinp sabotenb nouryoku cactus nouryokup tharrier vandykeb mustangb3 $(AFEGA_SETS)),)
EXT :=
endif
AUDIOCPU :=
ifneq ($(filter $(GAME),tharrier mustangb3 $(AFEGA_SETS)),)
AUDIOCPU := $(R)_audiocpu.hex
endif
OKI2 := $(R)_oki2.hex
ifeq ($(GAME),vandykeb)
OKI2 :=
endif
PROT :=
ifneq ($(filter $(GAME),gunnail macross hachamf tdragon1 bjtwin sabotenb nouryoku),)
PROT := $(R)_prot.hex
endif
BG2 :=
ifneq ($(filter $(GAME),bioship strahl $(AFEGA_8BPP)),)
BG2 := $(R)_bg2tile.hex
endif
TILEROM :=
ifeq ($(GAME),bioship)
TILEROM := $(R)_tilerom.hex
endif
VTIMING := ../../../roms/gunnail_multi_vtiming.hex

.PHONY: all run clean

all: run

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_gc.cpp $(FX68K_DIR)/fx68k.sv
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		--Mdir $(OBJ_DIR) \
		-y $(FX68K_DIR) -y $(TLCS90_DIR) -y $(NMK214_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl -y $(RTL_DIR)/third_party/jt51/hdl \
		-GSIM_DSW=1 -GROM_FILE=\"$(R)_maincpu.hex\" \
		-GNMK004_BOOT_FILE=\"../tlcs90/roms/nmk004_boot.hex\" \
		-GNMK004_EXT_FILE=\"$(EXT)\" \
		-GPROT_BOOT_FILE=\"$(PROT)\" \
		-GOKI1_ROM_FILE=\"$(R)_oki1.hex\" \
		-GOKI2_ROM_FILE=\"$(OKI2)\" \
		-GAUDIOCPU_FILE=\"$(AUDIOCPU)\" \
		-GVTIMING_FILE=\"$(VTIMING)\" \
		-GFGTILE_FILE=\"$(R)_fgtile.hex\" \
		-GBGTILE_FILE=\"$(R)_bgtile.hex\" \
		-GBG2TILE_FILE=\"$(BG2)\" \
		-GTILEROM_FILE=\"$(TILEROM)\" \
		-GSPRITES_FILE=\"$(R)_sprites.hex\" \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_gc.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	TB_GAME_SEL=$(SEL) TB_PREFIX=$(GAME) ./$(OBJ_DIR)/V$(TOP) $(CYCLES)

clean:
	rm -rf obj_dir_* *_sys.trace *_cyc.trace *_68k.trace *_video.trace *_frame_*.ppm microrom.mem nanorom.mem
