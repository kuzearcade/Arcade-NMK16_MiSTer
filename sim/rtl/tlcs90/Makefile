# Verilator build for the standalone TLCS-90 CPU core smoke test.
# See docs/tier2-tlcs90.md for what this proves and what's still missing.
#
# Usage:
#   make run     # build and run, produces tlcs90_rtl.trace (PC per instruction)
#   make clean

CORE_DIR := ../../../rtl/tlcs90
OBJ_DIR := obj_dir
TOP := tlcs90

.PHONY: all run clean

all: run

$(OBJ_DIR)/V$(TOP): $(CORE_DIR)/$(TOP).sv tb_tlcs90.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module $(TOP) \
		-y $(CORE_DIR) \
		$(CORE_DIR)/$(TOP).sv \
		tb_tlcs90.cpp \
		-o V$(TOP)

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR) tlcs90_rtl.trace
