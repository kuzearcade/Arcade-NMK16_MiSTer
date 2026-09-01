# Verilator build for the TLCS-90 CPU core and full NMK004 board wrapper.
# See docs/tier2-tlcs90.md for what these prove and what's still missing.
#
# Usage:
#   make run          # standalone CPU core + generic-RAM stub (tlcs90_rtl.trace)
#   make run-nmk004   # full board wrapper: CPU + real peripherals/timers (nmk004_rtl.trace)
#   make run-irqtest  # full board wrapper + synthetic boot ROM: proves timer/IRQ
#                      # dispatch end-to-end (EI/RETI), since the real boot ROM
#                      # never reaches EI in this CPU-only-with-stub-host testbench
#                      # (see docs/tier2-tlcs90.md "Interrupt self-test")
#   make clean

CORE_DIR := ../../../rtl/tlcs90
OBJ_DIR := obj_dir

.PHONY: all run run-nmk004 run-irqtest clean

all: run

$(OBJ_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_tlcs90.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_tlcs90.cpp \
		-o Vtlcs90

run: $(OBJ_DIR)/Vtlcs90
	./$(OBJ_DIR)/Vtlcs90

$(OBJ_DIR)/Vnmk004_core: $(CORE_DIR)/tlcs90.sv $(CORE_DIR)/nmk004_periph.sv $(CORE_DIR)/nmk004_core.sv tb_nmk004.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module nmk004_core \
		-y $(CORE_DIR) \
		-GBOOT_ROM_FILE=\"roms/nmk004_boot.hex\" \
		-GEXT_ROM_FILE=\"roms/mustang_ext.hex\" \
		$(CORE_DIR)/tlcs90.sv $(CORE_DIR)/nmk004_periph.sv $(CORE_DIR)/nmk004_core.sv \
		tb_nmk004.cpp \
		-o Vnmk004_core

run-nmk004: $(OBJ_DIR)/Vnmk004_core
	./$(OBJ_DIR)/Vnmk004_core

IRQTEST_DIR := obj_dir_irqtest

roms/irqtest_boot.hex: gen_irqtest_rom.py
	python3 gen_irqtest_rom.py

$(IRQTEST_DIR)/Vnmk004_irqtest: $(CORE_DIR)/tlcs90.sv $(CORE_DIR)/nmk004_periph.sv $(CORE_DIR)/nmk004_core.sv tb_nmk004.cpp roms/irqtest_boot.hex
	verilator --cc --exe --build -Wall -Wno-fatal --top-module nmk004_core \
		-y $(CORE_DIR) \
		-GBOOT_ROM_FILE=\"roms/irqtest_boot.hex\" \
		-GEXT_ROM_FILE=\"\" \
		$(CORE_DIR)/tlcs90.sv $(CORE_DIR)/nmk004_periph.sv $(CORE_DIR)/nmk004_core.sv \
		tb_nmk004.cpp \
		-o Vnmk004_irqtest \
		--Mdir $(IRQTEST_DIR)

run-irqtest: $(IRQTEST_DIR)/Vnmk004_irqtest
	./$(IRQTEST_DIR)/Vnmk004_irqtest irqtest.trace

clean:
	rm -rf $(OBJ_DIR) $(IRQTEST_DIR) tlcs90_rtl.trace nmk004_rtl.trace irqtest.trace
