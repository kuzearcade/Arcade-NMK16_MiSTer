# Two-clock unit test for rtl/video_retime.sv (docs/known-issues.md NMK-18).
#   make run        # both modes (8 MHz / 7 MHz), with and without H/V Shift
OBJ_DIR := obj_dir
TOP := video_retime

$(OBJ_DIR)/V$(TOP): ../../../rtl/video_retime.sv tb_video_retime.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module $(TOP) ../../../rtl/video_retime.sv tb_video_retime.cpp -o V$(TOP)

# The Gunnail rbf's 48 MHz parameter set (Gunnail.sv): 512 px / 6 and 384 px / 8.
$(OBJ_DIR)48/V$(TOP): ../../../rtl/video_retime.sv tb_video_retime.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module $(TOP) --Mdir $(OBJ_DIR)48 \
		-GM0_DIV=6 -GM1_X0=92 -GM1_HT=384 -GM1_HS=20 -GM1_HW=24 -GM1_AW=256 -GM1_DIV=8 -GLINE_CLKS=3072 \
		../../../rtl/video_retime.sv tb_video_retime.cpp -o V$(TOP)

run: $(OBJ_DIR)/V$(TOP) $(OBJ_DIR)48/V$(TOP)
	./$(OBJ_DIR)/V$(TOP) 0 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0
	./$(OBJ_DIR)/V$(TOP) 0 3 20
	./$(OBJ_DIR)/V$(TOP) 1 12 30
	./$(OBJ_DIR)48/V$(TOP) 0 0 0 1
	./$(OBJ_DIR)48/V$(TOP) 1 0 0 1
	./$(OBJ_DIR)48/V$(TOP) 0 3 20 1
	./$(OBJ_DIR)48/V$(TOP) 1 12 30 1

clean:
	rm -rf $(OBJ_DIR) $(OBJ_DIR)48

.PHONY: run clean
