# Hardware-mode (HW_ROMS=1) verification build for macross2 — see
# docs/hw-bringup.md. Same core RTL as sim/rtl/macross2/'s own sim
# build, plus the real SDRAM/rom_cache1/sdram_arb path instead of
# $readmemh. Mirrors sim/rtl/tdragon2_hw/'s own Makefile exactly.

FX68K_DIR := ../../../rtl/third_party/fx68k
T80_DIR := ../../../rtl/third_party_gen/t80
JT12_DIR := ../../../rtl/third_party/jt12
JT6295_DIR := ../../../rtl/third_party/jt6295
NMK_IRQ_DIR := ../../../rtl/nmk_irq
NMK112_DIR := ../../../rtl/nmk112
BJTWIN_DIR := ../../../rtl/bjtwin
MACROSS2_DIR := ../../../rtl/macross2
CORE_DIR := ../../../rtl/macross2
RTL_DIR := ../../../rtl
MODEL_DIR := ../../models
ROMS_DIR := ../../../mame_roms
OBJ_DIR := obj_dir
TOP := macross2_hw_top
Z1 := $(ROMS_DIR)/macross2.zip

SOURCES := macross2_hw_top.sv $(CORE_DIR)/macross2_core.sv $(MACROSS2_DIR)/video_macross2.sv \
           $(NMK112_DIR)/nmk112.sv $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram.sv $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv \
           $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache1_byte.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all roms run clean

all: run

roms: ioctl-rom vtiming-rom

ioctl-rom:
	python3 ../../../tools/mk_ioctl_stream.py --zip $(Z1) \
		--region 0x000000:mcrs2j.3 \
		--region 0x080000:mcrs2j.2 \
		--region 0x0A0000:mcrs2j.1 \
		--region 0x0C0000:bp932an.a04 \
		--region 0x2C0000:bp932an.a07,bp932an.a08 \
		--region 0x6C0000:bp932an.a06 \
		--region 0x8C0000:bp932an.a05 \
		--out roms/macross2_ioctl.bin

# nmk_irq's own real V-PROM (mcrs2bpr.10) — has no HW_ROMS gating, always
# loaded via $readmemh regardless of the ioctl/SDRAM path above (see
# macross2_hw_top.sv's own instantiation).
vtiming-rom:
	python3 ../../../tools/mkgfxrom.py --zip $(Z1) --mode concat --files mcrs2bpr.10 --out roms/macross2_vtiming.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_macross2_hw.cpp $(FX68K_DIR)/fx68k.sv roms/macross2_ioctl.bin roms/macross2_vtiming.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) \
		+define+SIMULATION \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_macross2_hw.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) microrom.mem nanorom.mem
