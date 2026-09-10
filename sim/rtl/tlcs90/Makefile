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
#   make run-banktest # standalone CPU core + synthetic banked memory model:
#                      # proves IX/IY bank extension (BX/BY -> ix_bank/iy_bank)
#                      # end-to-end, since no currently-known game exercises a
#                      # nonzero bank (see docs/tier2-tlcs90.md)
#   make run-blocktest # standalone CPU core + synthetic program: proves
#                      # LDI/LDIR/LDD/LDDR/CPI/CPIR/CPD/CPDR end-to-end,
#                      # since no currently-known game's boot trace reaches
#                      # these opcodes (see docs/tier2-tlcs90.md)
#   make run-rldtest  # standalone CPU core + synthetic program: proves
#                      # RLD/RRD end-to-end via two different addressing
#                      # forms (see docs/tier2-tlcs90.md)
#   make run-muldivtest # standalone CPU core + synthetic program: proves
#                      # MUL/DIV end-to-end, including the divide-by-zero
#                      # special case (see docs/tier2-tlcs90.md)
#   make run-ldarcallrtest # standalone CPU core + synthetic program:
#                      # proves LDAR/CALLR and the 16-bit JR form
#                      # end-to-end (see docs/tier2-tlcs90.md)
#   make run-switest  # standalone CPU core + synthetic program: proves
#                      # SWI end-to-end, including that it's genuinely
#                      # non-maskable (see docs/tier2-tlcs90.md)
#   make run-extest   # standalone CPU core + synthetic program: proves
#                      # the memory-operand forms of EX end-to-end via two
#                      # different addressing forms (see docs/tier2-tlcs90.md)
#   make clean

CORE_DIR := ../../../rtl/tlcs90
OBJ_DIR := obj_dir

.PHONY: all run run-nmk004 run-irqtest run-banktest run-blocktest run-rldtest run-muldivtest run-ldarcallrtest run-switest run-extest clean

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

BANKTEST_DIR := obj_dir_banktest

$(BANKTEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_banktest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_banktest.cpp \
		-o Vtlcs90 \
		--Mdir $(BANKTEST_DIR)

run-banktest: $(BANKTEST_DIR)/Vtlcs90
	./$(BANKTEST_DIR)/Vtlcs90

BLOCKTEST_DIR := obj_dir_blocktest

$(BLOCKTEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_blocktest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_blocktest.cpp \
		-o Vtlcs90 \
		--Mdir $(BLOCKTEST_DIR)

run-blocktest: $(BLOCKTEST_DIR)/Vtlcs90
	./$(BLOCKTEST_DIR)/Vtlcs90

RLDTEST_DIR := obj_dir_rldtest

$(RLDTEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_rldtest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_rldtest.cpp \
		-o Vtlcs90 \
		--Mdir $(RLDTEST_DIR)

run-rldtest: $(RLDTEST_DIR)/Vtlcs90
	./$(RLDTEST_DIR)/Vtlcs90

MULDIVTEST_DIR := obj_dir_muldivtest

$(MULDIVTEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_muldivtest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_muldivtest.cpp \
		-o Vtlcs90 \
		--Mdir $(MULDIVTEST_DIR)

run-muldivtest: $(MULDIVTEST_DIR)/Vtlcs90
	./$(MULDIVTEST_DIR)/Vtlcs90

LDARCALLRTEST_DIR := obj_dir_ldarcallrtest

$(LDARCALLRTEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_ldarcallrtest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_ldarcallrtest.cpp \
		-o Vtlcs90 \
		--Mdir $(LDARCALLRTEST_DIR)

run-ldarcallrtest: $(LDARCALLRTEST_DIR)/Vtlcs90
	./$(LDARCALLRTEST_DIR)/Vtlcs90

SWITEST_DIR := obj_dir_switest

$(SWITEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_switest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_switest.cpp \
		-o Vtlcs90 \
		--Mdir $(SWITEST_DIR)

run-switest: $(SWITEST_DIR)/Vtlcs90
	./$(SWITEST_DIR)/Vtlcs90

EXTEST_DIR := obj_dir_extest

$(EXTEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_extest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_extest.cpp \
		-o Vtlcs90 \
		--Mdir $(EXTEST_DIR)

run-extest: $(EXTEST_DIR)/Vtlcs90
	./$(EXTEST_DIR)/Vtlcs90

# XCF on 8-bit INC/DEC, INCX/DECX chaining, SET/RES b,g register
# writeback — the regression gate for the GunNail sequencer CPU fixes
# (docs/known-issues.md NMK-5; gen_flagtest_rom.py for the derivation).
FLAGTEST_DIR := obj_dir_flagtest

$(FLAGTEST_DIR)/Vtlcs90: $(CORE_DIR)/tlcs90.sv tb_flagtest.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module tlcs90 \
		-y $(CORE_DIR) \
		$(CORE_DIR)/tlcs90.sv \
		tb_flagtest.cpp \
		-o Vtlcs90 \
		--Mdir $(FLAGTEST_DIR)

run-flagtest: $(FLAGTEST_DIR)/Vtlcs90
	./$(FLAGTEST_DIR)/Vtlcs90

# Every standalone self-test in one go (the wrapper-based run-irqtest /
# run-nmk004 are trace generators, not pass/fail, and are left out).
run-selftests: run run-banktest run-blocktest run-rldtest run-muldivtest run-ldarcallrtest run-switest run-extest run-flagtest

clean:
	rm -rf $(OBJ_DIR) $(IRQTEST_DIR) $(BANKTEST_DIR) $(BLOCKTEST_DIR) $(RLDTEST_DIR) $(MULDIVTEST_DIR) $(LDARCALLRTEST_DIR) $(SWITEST_DIR) $(EXTEST_DIR) $(FLAGTEST_DIR) tlcs90_rtl.trace nmk004_rtl.trace irqtest.trace
