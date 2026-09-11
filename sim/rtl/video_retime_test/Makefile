# Two-clock unit test for rtl/video_retime.sv (docs/known-issues.md NMK-18).
#   make run        # both modes (8 MHz / 7 MHz), with and without H/V Shift
OBJ_DIR := obj_dir
TOP := video_retime

$(OBJ_DIR)/V$(TOP): ../../../rtl/video_retime.sv tb_video_retime.cpp
	verilator --cc --exe --build -Wall -Wno-fatal --top-module $(TOP) ../../../rtl/video_retime.sv tb_video_retime.cpp -o V$(TOP)

run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP) 0 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0
	./$(OBJ_DIR)/V$(TOP) 0 3 20
	./$(OBJ_DIR)/V$(TOP) 1 12 30

clean:
	rm -rf $(OBJ_DIR)

.PHONY: run clean
