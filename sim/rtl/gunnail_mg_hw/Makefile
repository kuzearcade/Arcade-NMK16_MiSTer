# Hardware-mode (HW_ROMS=1) sims of the multi-game Gunnail core (2026-09-11):
# sim/rtl/gunnail_hw's harness with the game selected per build — real
# rtl/sdram.sv + sdram_model, loaded by the game's ioctl stream in the
# .mra layout (tools/gen_gunnail_mra.py --ioctl <set> lists the regions).
#   make GAME=bioship run          # obj_dir_bioship, roms/bioship_ioctl.bin
#   TB_DUMP_PPM=1 make GAME=strahl run
GAME   ?= bioship
CYCLES ?=

FX68K_DIR := ../../../rtl/third_party/fx68k
TLCS90_DIR := ../../../rtl/tlcs90
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
MACROSS2_DIR := ../../../rtl/macross2
CORE_DIR := ../../../rtl/gunnail
NMK214_DIR := ../../../rtl/nmk214
RTL_DIR := ../../../rtl
MODEL_DIR := ../../models
OBJ_DIR := obj_dir_$(GAME)
TOP := gunnail_mg_hw_top
R := ../$(GAME)/roms/$(GAME)

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
SEL := $(SEL_$(GAME))

SOURCES := $(TOP).sv $(CORE_DIR)/gunnail_core.sv $(MACROSS2_DIR)/video_macross2.sv \
           $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv $(TLCS90_DIR)/nmk_prot_core.sv $(NMK214_DIR)/nmk214.sv \
           $(NMK112_DIR)/nmk112.sv $(BJTWIN_DIR)/video_timing.sv $(BJTWIN_DIR)/nmk_irq_hacky.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram.sv $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv \
           $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache_n.sv $(RTL_DIR)/rom_cache_n_byte.sv $(RTL_DIR)/rom_cache1_byte.sv $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all roms run clean

all: run

roms/$(GAME)_ioctl.bin:
	cd ../../.. && python3 tools/mk_ioctl_stream.py $$(python3 tools/gen_gunnail_mra.py --ioctl $(GAME)) --out sim/rtl/gunnail_mg_hw/roms/$(GAME)_ioctl.bin

roms: roms/$(GAME)_ioctl.bin

# ROM_FILE/OKI*_ROM_FILE only feed the golden audits of the HW-path caches.
$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_gunnail_mg_hw.cpp $(FX68K_DIR)/fx68k.sv roms/$(GAME)_ioctl.bin
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		--Mdir $(OBJ_DIR) +define+SIMULATION +define+OKI_CACHE_DIAG \
		-GGAME_SEL=$(SEL) -GVTIMING_FILE=\"../../../roms/gunnail_multi_vtiming.hex\" \
		-GROM_FILE=\"$(R)_maincpu.hex\" -GOKI1_ROM_FILE=\"$(R)_oki1.hex\" -GOKI2_ROM_FILE=\"$(R)_oki2.hex\" \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_gunnail_mg_hw.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	TB_PREFIX=$(GAME) ./$(OBJ_DIR)/V$(TOP) $(CYCLES)

clean:
	rm -rf obj_dir_* roms/*_ioctl.bin *_hw_68k.trace *_hw_frame_*.ppm microrom.mem nanorom.mem
