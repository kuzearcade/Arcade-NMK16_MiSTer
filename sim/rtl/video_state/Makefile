# Video-only render of a MAME video-state dump — see video_state_top.sv.
# make DUMP=<dir/prefix> TILEBANK=<hex> OUT=<ppm>
MACROSS2_DIR := ../../../rtl/macross2
NMK214_DIR := ../../../rtl/nmk214
RTL_DIR := ../../../rtl
GROMS := ../gunnail/roms
DUMP ?= dump/f05395_
TILEBANK ?= 0
OUT ?= video_state.ppm
SOURCES := video_state_top.sv $(MACROSS2_DIR)/video_macross2.sv $(NMK214_DIR)/nmk214.sv \
           $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv \
           $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv
obj_dir/Vvideo_state_top: $(SOURCES) tb_video_state.cpp
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module video_state_top \
		-GFGTILE_FILE=\"$(GROMS)/gunnail_fgtile.hex\" -GBGTILE_FILE=\"$(GROMS)/gunnail_bgtile.hex\" -GSPRITES_FILE=\"$(GROMS)/gunnail_sprites.hex\" \
		-GSCROLLRAM_FILE=\"$(DUMP)scrollram.hex\" -GSCROLLRAMY_FILE=\"$(DUMP)scrollramy.hex\" -GBGVRAM_FILE=\"$(DUMP)bgvram.hex\" \
		-GTXVRAM_FILE=\"$(DUMP)txvram.hex\" -GPALETTE_FILE=\"$(DUMP)palette.hex\" -GSPRITERAM_FILE=\"$(DUMP)spriteram.hex\" \
		$(SOURCES) tb_video_state.cpp -o Vvideo_state_top
run: obj_dir/Vvideo_state_top
	./obj_dir/Vvideo_state_top $(TILEBANK) $(OUT)
clean:
	rm -rf obj_dir
