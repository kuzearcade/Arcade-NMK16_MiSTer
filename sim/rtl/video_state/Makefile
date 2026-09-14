# Video-only render of a MAME video-state dump — see video_state_top.sv.
#
#   make GAME=gunnail  DUMP=dump/f05395_ TILEBANK=0 OUT=g.ppm run
#   make GAME=ssmissin DUMP=dump/ssm_    run            # + VS_BGX/VS_BGY
#
# The per-game parameter blocks mirror what rtl/gunnail/gunnail_core.sv
# passes to video_macross2 for that game_sel; keep them in step with it.
MACROSS2_DIR := ../../../rtl/macross2
NMK214_DIR := ../../../rtl/nmk214
RTL_DIR := ../../../rtl
GAME ?= gunnail
GROMS := ../$(GAME)/roms
DUMP ?= dump/f05395_
TILEBANK ?= 0
OUT ?= video_state_$(GAME).ppm
OBJ := obj_dir_$(GAME)

# gunnail (the original use): per-line scroll tables, hires, NMK214 on,
# parameter-derived palette bases (cfg_rt=0).
ifeq ($(GAME),gunnail)
GPARM := -GRASTER=1 -GLOWRES=0 -GNMK214=1 -GNMK214_EN=1 -GCFG_RT=0
VS_WIDTH ?= 384
endif

# ssmissin (Comad Family F, game_sel 52): four scroll registers, lowres,
# no NMK214, cfg_rt=1 with gfx_macross's own palette bases and an
# 8192-tile BG mask / 8192 sprite units.
ifeq ($(GAME),ssmissin)
GPARM := -GRASTER=0 -GLOWRES=1 -GNMK214=1 -GNMK214_EN=0 -GSPR_SWAP=1 -GCFG_RT=1 \
         -GBGA_PAL_I=0 -GBGB_PAL_I=0 -GSPR_PAL_I=256 -GTX_PAL_I=512 \
         -GBGA_MASK_I=8191 -GBGB_MASK_I=4095 -GSPR_UNITS_I=8192 -GSPRDMA_WORD=16384 \
         -GBG_CODE_BITS=13 -GSPRITES_BYTES=2097152
VS_WIDTH ?= 256
endif

SOURCES := video_state_top.sv $(MACROSS2_DIR)/video_macross2.sv $(NMK214_DIR)/nmk214.sv \
           $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv \
           $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv
$(OBJ)/Vvideo_state_top: $(SOURCES) tb_video_state.cpp
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module video_state_top \
		--Mdir $(OBJ) $(GPARM) \
		-GFGTILE_FILE=\"$(GROMS)/$(GAME)_fgtile.hex\" -GBGTILE_FILE=\"$(GROMS)/$(GAME)_bgtile.hex\" -GSPRITES_FILE=\"$(GROMS)/$(GAME)_sprites.hex\" \
		-GSCROLLRAM_FILE=\"$(DUMP)scrollram.hex\" -GSCROLLRAMY_FILE=\"$(DUMP)scrollramy.hex\" -GBGVRAM_FILE=\"$(DUMP)bgvram.hex\" \
		-GTXVRAM_FILE=\"$(DUMP)txvram.hex\" -GPALETTE_FILE=\"$(DUMP)palette.hex\" -GSPRITERAM_FILE=\"$(DUMP)spriteram.hex\" \
		$(SOURCES) tb_video_state.cpp -o Vvideo_state_top
run: $(OBJ)/Vvideo_state_top
	VS_WIDTH=$(VS_WIDTH) ./$(OBJ)/Vvideo_state_top $(TILEBANK) $(OUT)
clean:
	rm -rf obj_dir obj_dir_*

# ---------------------------------------------------------------------------
# Same-scene render through the FULL gunnail_core (2026-09-14). Preferred over
# the standalone video_macross2 targets above: it uses the shipping per-game
# configuration instead of ~20 hand-mirrored parameters, so a mismatch is
# evidence about the core rather than about the harness.
#   make GCGAME=ssmissin GCSEL=52 GCDUMP=<dir>/ssm_ gcrun
# ---------------------------------------------------------------------------
GCGAME ?= ssmissin
GCSEL  ?= 52
GCDUMP ?= dump/ssm_
GCOUT  ?= gc_state_$(GCGAME).ppm
GCW    ?= 256
GCOBJ  := obj_dir_gc_$(GCGAME)
GR     := ../$(GCGAME)/roms/$(GCGAME)
TL     := ../../../rtl/tlcs90
GCSRC  := ../../../rtl/gunnail/gunnail_core.sv $(MACROSS2_DIR)/video_macross2.sv $(NMK214_DIR)/nmk214.sv \
          $(TL)/tlcs90.sv $(TL)/nmk004_periph.sv $(TL)/nmk004_core.sv $(TL)/nmk_prot_core.sv \
          ../../../rtl/bjtwin/video_timing.sv ../../../rtl/bjtwin/nmk_irq_hacky.sv ../../../rtl/nmk_irq/nmk_irq.sv \
          ../../../rtl/third_party/jt12/hdl/jt03.v ../../../rtl/third_party/jt6295/hdl/jt6295.v \
          $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv \
          $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv $(RTL_DIR)/rom_cache_n.sv $(RTL_DIR)/rom_cache_n_byte.sv \
          $(RTL_DIR)/nmk112/nmk112.sv $(RTL_DIR)/third_party_gen/t80/T80s.v $(RTL_DIR)/third_party/jt51/hdl/jt51.v \
          $(RTL_DIR)/seibu/seibu_sound.sv $(RTL_DIR)/third_party/jtopl/hdl/jtopl2.v

$(GCOBJ)/Vgunnail_core: $(GCSRC) tb_gc_state.cpp
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY \
		--top-module gunnail_core --Mdir $(GCOBJ) +define+SIMULATION \
		-y ../../../rtl/third_party/fx68k -y $(TL) -y $(NMK214_DIR) \
		-y ../../../rtl/third_party/jt12/hdl -y ../../../rtl/third_party/jt12/jt49/hdl \
		-y ../../../rtl/third_party/jt6295/hdl -y $(RTL_DIR)/third_party/jt51/hdl -y $(RTL_DIR)/third_party/jtopl/hdl \
		-GVIDEO_ONLY=1 -GSIM_DSW=1 \
		-GSTATE_BGVRAM_FILE=\"$(GCDUMP)bgvram.hex\" -GSTATE_TXVRAM_FILE=\"$(GCDUMP)txvram.hex\" \
		-GSTATE_PALETTE_FILE=\"$(GCDUMP)palette.hex\" -GSTATE_SPRITERAM_FILE=\"$(GCDUMP)spriteram.hex\" \
		-GROM_FILE=\"$(GR)_maincpu.hex\" -GFGTILE_FILE=\"$(GR)_fgtile.hex\" -GBGTILE_FILE=\"$(GR)_bgtile.hex\" \
		-GSPRITES_FILE=\"$(GR)_sprites.hex\" -GOKI1_ROM_FILE=\"$(GR)_oki1.hex\" \
		-GVTIMING_FILE=\"../../../roms/gunnail_multi_vtiming.hex\" \
		$(GCSRC) ../../../rtl/third_party/fx68k/fx68k.sv ../../../rtl/third_party/fx68k/fx68kAlu.sv ../../../rtl/third_party/fx68k/uaddrPla.sv \
		tb_gc_state.cpp -o Vgunnail_core
	cp ../../../rtl/third_party/fx68k/microrom.mem ../../../rtl/third_party/fx68k/nanorom.mem .

gcrun: $(GCOBJ)/Vgunnail_core
	VS_WIDTH=$(GCW) VS_GAME_SEL=$(GCSEL) ./$(GCOBJ)/Vgunnail_core $(GCOUT)
