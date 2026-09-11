# Hardware-mode (HW_ROMS=1) verification build for Power Instinct through
# the shared Family C core (tdragon2_core.sv, game_powerins=1) — see
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
TOP := powerins_hw_top
Z1 := $(ROMS_DIR)/powerins.zip

SOURCES := powerins_hw_top.sv $(CORE_DIR)/tdragon2_core.sv $(MACROSS2_DIR)/video_macross2.sv \
           $(NMK112_DIR)/nmk112.sv $(BJTWIN_DIR)/video_timing.sv $(NMK_IRQ_DIR)/nmk_irq.sv \
           $(T80_DIR)/T80s.v $(JT12_DIR)/hdl/jt03.v $(JT6295_DIR)/hdl/jt6295.v \
           $(RTL_DIR)/sdram.sv $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/sdram_arb.sv \
           $(RTL_DIR)/rom_cache1.sv $(RTL_DIR)/rom_cache_n.sv $(RTL_DIR)/rom_cache_n_byte.sv $(RTL_DIR)/rom_cache1_byte.sv $(RTL_DIR)/oki_rom_cache.sv $(RTL_DIR)/tile_prefetch_byte.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all roms run clean

all: run

roms: ioctl-rom vtiming-rom

# Absolute SDRAM byte offsets of powerins' regions — the layout
# tdragon2_core.sv's BASE_WORD_* take when game_powerins=1 and the order
# releases/Power Instinct (USA).mra streams its <part>s in.
ioctl-rom:
	python3 ../../../tools/mk_ioctl_stream.py --zip $(Z1) \
		--region 0x000000:93095-3a.u108,93095-4.u109 \
		--region 0x100000:93095-2.u90 \
		--region 0x120000:93095-1.u15 \
		--region 0x140000:93095-5.u16,93095-6.u17,93095-7.u18 \
		--region 0x3C0000:93095-12.u116,93095-13.u117,93095-14.u118,93095-15.u119,93095-16.u120,93095-17.u121,93095-18.u122,93095-19.u123 \
		--region 0xBC0000:93095-10.u48,93095-11.u49 \
		--region 0xDC0000:93095-8.u46,93095-9.u47 \
		--out roms/powerins_ioctl.bin

# Two-table V-PROM file (see Macross2.sv): tdragon2's 10.bpr + powerins' 21.u71.
vtiming-rom:
	python3 ../../../tools/mkgfxrom.py --zip ../../../mame_roms/tdragon2.zip --mode concat --files 10.bpr --out roms/t2_vtiming.hex
	python3 ../../../tools/mkgfxrom.py --zip $(Z1) --mode concat --files 21.u71 --out roms/pi_vtiming.hex
	cat roms/t2_vtiming.hex roms/pi_vtiming.hex > roms/tdragon2_powerins_vtiming.hex

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_powerins_hw.cpp $(FX68K_DIR)/fx68k.sv roms/powerins_ioctl.bin roms/tdragon2_powerins_vtiming.hex
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module $(TOP) $(EXTRA_VFLAGS) \
		+define+SIMULATION +define+OKI_CACHE_DIAG \
		-y $(FX68K_DIR) -y $(JT12_DIR)/hdl -y $(JT12_DIR)/jt49/hdl -y $(JT6295_DIR)/hdl \
		$(SOURCES) $(FX68K_DIR)/fx68k.sv $(FX68K_DIR)/fx68kAlu.sv $(FX68K_DIR)/uaddrPla.sv \
		tb_powerins_hw.cpp \
		-o V$(TOP)
	cp $(FX68K_DIR)/microrom.mem $(FX68K_DIR)/nanorom.mem .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) microrom.mem nanorom.mem
