# Standalone verification of rtl/sdram_arb.sv — see docs/hw-bringup.md.

SDRAM_DIR := ../../../rtl
MODEL_DIR := ../../models
OBJ_DIR := obj_dir
TOP := sdram_arb_test_top

SOURCES := $(TOP).sv $(SDRAM_DIR)/sdram.sv $(SDRAM_DIR)/sdram_req.sv $(SDRAM_DIR)/sdram_arb.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all run clean

all: run

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_sdram_arb_test.cpp
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-BLKANDNBLK --top-module $(TOP) \
		+define+SIMULATION \
		$(SOURCES) tb_sdram_arb_test.cpp \
		-o V$(TOP)

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR)
