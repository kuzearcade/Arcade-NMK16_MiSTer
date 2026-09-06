# Standalone verification of rtl/sdram.sv + rtl/sdram_req.sv against
# sim/models/sdram_model.sv — see docs/hw-bringup.md.

SDRAM_DIR := ../../../rtl
MODEL_DIR := ../../models
OBJ_DIR := obj_dir
TOP := sdram_test_top

SOURCES := $(TOP).sv $(SDRAM_DIR)/sdram.sv $(SDRAM_DIR)/sdram_req.sv $(MODEL_DIR)/sdram_model.sv

.PHONY: all run clean

all: run

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_sdram_test.cpp
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-BLKANDNBLK --top-module $(TOP) \
		+define+SIMULATION \
		$(SOURCES) tb_sdram_test.cpp \
		-o V$(TOP)

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR)
