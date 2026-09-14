# Standalone M68705R3 (jt6805 + rtl/m68705 wrapper) reference sim.
#
#   make run                 # diff against the MAME trace in roms/
#   make run TB_MAX=900      # just the deterministic pre-interrupt prefix
#   make dis                 # readable dump of the microcode ROM
#
# roms/ holds the tharrierb MCU image and the MAME oracle (PC list, Port B
# read sequence, interrupt instruction indices) — see tb_m68705.cpp.

RTL      := ../../../rtl
JT680X   := $(RTL)/third_party/jt680x/hdl
CORE_DIR := $(RTL)/m68705
TOP      := m68705_core
OBJ_DIR  := obj_dir

SOURCES := $(CORE_DIR)/$(TOP).sv $(JT680X)/jt6805.v $(JT680X)/jt6805_ctrl.v \
           $(JT680X)/jt6805_alu.v $(JT680X)/jt6805_regs.v

ROM := roms/tharrierb_mcu.hex

.PHONY: all run dis clean

all: run

$(OBJ_DIR)/V$(TOP): $(SOURCES) tb_m68705.cpp $(CORE_DIR)/6805.uc $(CORE_DIR)/6805.vh $(CORE_DIR)/6805_param.vh
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-UNUSED -Wno-UNOPTFLAT \
		-Wno-DECLFILENAME -Wno-PINCONNECTEMPTY --public-flat-rw \
		--top-module $(TOP) --Mdir $(OBJ_DIR) \
		-I$(CORE_DIR) -y $(JT680X) \
		-GROM_FILE=\"$(ROM)\" -GHW_ROMS=0 \
		$(SOURCES) tb_m68705.cpp -o V$(TOP)
	cp $(CORE_DIR)/6805.uc .

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

dis:
	python3 ../../../tools/uc6805.py dis $(CORE_DIR)/6805.uc

clean:
	rm -rf $(OBJ_DIR) 6805.uc *.trace
