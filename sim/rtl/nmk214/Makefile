# Standalone verification for rtl/nmk214/nmk214.sv — see tb_nmk214.cpp's
# own header for what this checks.
CORE_DIR := ../../../rtl/nmk214
OBJ_DIR  := obj_dir

.PHONY: all run clean

all: $(OBJ_DIR)/Vnmk214_tb_top

$(OBJ_DIR)/Vnmk214_tb_top: $(CORE_DIR)/nmk214.sv nmk214_tb_top.sv tb_nmk214.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module nmk214_tb_top \
		-y $(CORE_DIR) \
		$(CORE_DIR)/nmk214.sv \
		nmk214_tb_top.sv \
		tb_nmk214.cpp \
		-o Vnmk214_tb_top \
		--Mdir $(OBJ_DIR)

run: $(OBJ_DIR)/Vnmk214_tb_top
	./$(OBJ_DIR)/Vnmk214_tb_top

clean:
	rm -rf $(OBJ_DIR)
