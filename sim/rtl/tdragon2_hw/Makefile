# Hardware-mode (HW_ROMS=1) verification build for tdragon2 — see
# docs/hw-bringup.md. Same core RTL as sim/rtl/tdragon2/'s own
# oracle-verified sim build, plus the real SDRAM/rom_cache1/sdram_arb
# path instead of $readmemh.

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
MACROSS2_DIR := ../../../rtl/macross2
CORE_DIR := ../../../rtl/tdragon2
RTL_DIR := ../../../rtl
MODEL_DIR := ../../models
ROMS_DIR := ../../../mame_roms
OBJ_DIR := obj_dir
TOP := tdragon2_hw_top
Z1 := $(ROMS_DIR)/tdragon2.zip

SOURCES := tdragon2_hw_top.sv $(CORE_DIR)/tdragon2_core.sv $(MACROSS2_DIR)/video_macross2.sv \
           $(NMK112_DIR)/nmk112.sv $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram.sv $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv \
           $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all roms run clean

all: run

roms: ioctl-rom vtiming-rom

ioctl-rom:
	python3 ../../../tools/mk_ioctl_stream.py --zip $(Z1) \
		--region 0x000000:6.rom \
		--region 0x080000:5.bin \
		--region 0x0A0000:1.bin \
		--region 0x0C0000:ww930914.2 \
		--region 0x2C0000:ww930917.7,ww930918.8 \
		--region 0x6C0000:ww930916.4 \
		--region 0x8C0000:ww930915.3 \
		--out roms/tdragon2_ioctl.bin

# nmk_irq's own real V-PROM (10.bpr) — has no HW_ROMS gating, always
# loaded via $readmemh regardless of the ioctl/SDRAM path above (see
# tdragon2_hw_top.sv's own instantiation).
vtiming-rom:
	python3 ../../../tools/mkgfxrom.py --zip $(Z1) --mode concat --files 10.bpr --out roms/tdragon2_vtiming.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_tdragon2_hw.cpp $(FX68K_DIR)/fx68k.sv roms/tdragon2_ioctl.bin roms/tdragon2_vtiming.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		+define+SIMULATION +define+OKI_CACHE_DIAG \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_tdragon2_hw.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) microrom.mem nanorom.mem
