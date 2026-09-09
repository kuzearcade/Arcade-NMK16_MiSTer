# Hardware-mode (HW_ROMS=1) verification build for raphero — see
# docs/hw-bringup.md. Same core RTL as sim/rtl/raphero/'s own reference
# build, plus the real SDRAM/rom-cache/sdram_arb path instead of
# $readmemh, fed by a real ioctl_download byte stream. Also serves
# arcadian/rapheroa (same machine config) — this Makefile targets
# raphero, whose split zip is completed from arcadian.zip.

FX68K_DIR := ../../../rtl/third_party/fx68k
TLCS90_DIR := ../../../rtl/tlcs90
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
MACROSS2_DIR := ../../../rtl/macross2
CORE_DIR := ../../../rtl/raphero
RTL_DIR := ../../../rtl
MODEL_DIR := ../../models
ROMS_DIR := ../../../mame_roms
OBJ_DIR := obj_dir
TOP := raphero_hw_top
Z1 := $(ROMS_DIR)/raphero.zip
Z2 := $(ROMS_DIR)/arcadian.zip

SOURCES := raphero_hw_top.sv $(CORE_DIR)/raphero_core.sv $(MACROSS2_DIR)/video_macross2.sv \
           $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv \
           $(NMK112_DIR)/nmk112.sv $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram.sv $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv \
           $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all roms run clean

all: run

roms: ioctl-rom vtiming-rom

# Same layout as raphero_core.sv's BASE_BYTE_* table and the .mra part
# order: rhp94099.6 appears ONCE, shared by oki2 (.5,.6 @ 0x8C0000) and
# oki1 (.6,.7 @ 0xAC0000).
ioctl-rom:
	python3 ../../../tools/mk_ioctl_stream.py --zip $(Z1) --zip $(Z2) \
		--region 0x000000:3 \
		--region 0x080000:rhp94099.2 \
		--region 0x0A0000:rhp94099.1 \
		--region 0x0C0000:rhp94099.4 \
		--region 0x2C0000:rhp94099.8,rhp94099.9,rhp94099.10 \
		--region 0x8C0000:rhp94099.5,rhp94099.6,rhp94099.7 \
		--out roms/raphero_ioctl.bin

# nmk_irq's V-PROM (prom2.u53) — always $readmemh, no HW_ROMS gating.
vtiming-rom:
	python3 ../../../tools/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files prom2.u53 --out roms/raphero_vtiming.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_raphero_hw.cpp $(FX68K_DIR)/fx68k.sv roms/raphero_ioctl.bin roms/raphero_vtiming.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		+define+SIMULATION +define+OKI_CACHE_DIAG \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_raphero_hw.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) microrom.mem nanorom.mem
