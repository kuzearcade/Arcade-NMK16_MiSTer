# Hardware-mode (HW_ROMS=1) verification build for gunnail — see
# docs/hw-bringup.md. Same core RTL as sim/rtl/gunnail/'s own reference
# build, plus the real SDRAM/rom-cache/sdram_arb path instead of
# $readmemh, fed by a real ioctl_download byte stream (gunnail.zip plus
# the NMK004 boot ROM from nmk004.zip).

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
ROMS_DIR := ../../../mame_roms
OBJ_DIR := obj_dir
TOP := gunnail_hw_top
Z1 := $(ROMS_DIR)/gunnail.zip
Z2 := $(ROMS_DIR)/nmk004.zip

SOURCES := gunnail_hw_top.sv $(CORE_DIR)/gunnail_core.sv $(MACROSS2_DIR)/video_macross2.sv \
           $(TLCS90_DIR)/tlcs90.sv $(TLCS90_DIR)/nmk004_periph.sv $(TLCS90_DIR)/nmk004_core.sv $(TLCS90_DIR)/nmk_prot_core.sv $(NMK214_DIR)/nmk214.sv \
           $(NMK112_DIR)/nmk112.sv $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram.sv $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv \
           $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache_n.sv $(RTL_DIR)/rom_cache_n_byte.sv $(RTL_DIR)/rom_cache1_byte.sv $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all roms run clean

all: run

roms: ioctl-rom vtiming-rom

# Same layout as gunnail_core.sv's BASE_BYTE_* table and the .mra part
# order. maincpu is a ROM_LOAD16_BYTE pair: "3o.u133+3e.u131" interleaves
# them with the low-byte chip on even addresses. nmk004.bin comes from
# nmk004.zip (the .mra lists zip="gunnail.zip|nmk004.zip").
ioctl-rom:
	python3 ../../../tools/mk_ioctl_stream.py --zip $(Z1) --zip $(Z2) \
		--region 0x000000:3o.u133+3e.u131 \
		--region 0x080000:92077_2.u101 \
		--region 0x090000:nmk004.bin \
		--region 0x092000:nmk-215.bin \
		--region 0x094000:1.u21 \
		--region 0x0B4000:92077-4.u19 \
		--region 0x1B4000:92077-7.u134 \
		--region 0x3B4000:92077-5.u56 \
		--region 0x434000:92077-6.u57 \
		--out roms/gunnail_ioctl.bin

# nmk_irq's V-PROM (prom2.u53) — always $readmemh, no HW_ROMS gating.
vtiming-rom:
	python3 ../../../tools/mkgfxrom.py --zip $(Z1) --zip $(Z2) --mode concat --files 9_82s135.u72 --out roms/gunnail_vtiming.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_gunnail_hw.cpp $(FX68K_DIR)/fx68k.sv roms/gunnail_ioctl.bin roms/gunnail_vtiming.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		+define+SIMULATION +define+OKI_CACHE_DIAG \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_gunnail_hw.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) microrom.mem nanorom.mem
