# Standalone verification of rtl/rom_cache1.sv — see docs/hw-bringup.md.

RTL_DIR := ../../../rtl
MODEL_DIR := ../../models
OBJ_DIR := obj_dir
TOP := rom_cache1_test_top

SOURCES := $(TOP).sv $(RTL_DIR)/sdram.sv $(RTL_DIR)/sdram_req.sv $(RTL_DIR)/rom_cache1.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all run clean

all: run

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_rom_cache1_test.cpp
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-BLKANDNBLK --top-module $(TOP) \
		+define+SIMULATION \
		$(SOURCES) tb_rom_cache1_test.cpp \
		-o V$(TOP)

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR)
