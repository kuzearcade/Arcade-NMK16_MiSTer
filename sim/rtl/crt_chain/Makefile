# Verilator test for rtl/crt_chain.sv (CRT Adjust, 2026-09-18).
#   make run    # Off / On-at-zero identity, then each control, both line lengths
#
# crt_vsize_sim.sv is a SIM-ONLY copy of the vendored crt_vsize.sv with its
# line_base() calls inlined -- Verilator 5.032 crashes ("Multiple Write refs
# on LHS of NBA") on a function call inside an NBA index. Regenerate it after
# any upstream bump with:
#   sed '/function/!s/line_base(\([^)]*\))/((\1) * LINE_PX)/g' \
#       ../../../rtl/third_party/crt_adjust/rtl/crt_vsize.sv > crt_vsize_sim.sv
# (and put the header comment back). Quartus compiles the real file.
OBJ_DIR := obj_dir
TOP := crt_chain
SRC := ../../../rtl/crt_chain.sv ../../../rtl/third_party/crt_adjust/rtl/crt_adjust.sv crt_vsize_sim.sv

$(OBJ_DIR)/V$(TOP): $(SRC) tb_crt_chain.cpp
	verilator --cc --exe --build -Wno-fatal -Wno-WIDTH -GVSIZE_MAX=7 --top-module $(TOP) $(SRC) tb_crt_chain.cpp -o V$(TOP) > build.log 2>&1 || { tail -20 build.log; false; }

# args: enable hsize hpos_raw vshift vsize_step vsmode [mode1]
run: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP) 0 0 0 0 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 0 0
	./$(OBJ_DIR)/V$(TOP) 0 0 0 0 0 0 1
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 0 0 1
	./$(OBJ_DIR)/V$(TOP) 1 4 0 0 0 0
	./$(OBJ_DIR)/V$(TOP) 1 -6 0 0 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 20 0 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 60 0 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 60 0 0 0 1
	./$(OBJ_DIR)/V$(TOP) 1 0 0 5 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0 -9 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 2 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 -3 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 2 1
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 -3 1
	./$(OBJ_DIR)/V$(TOP) 1 3 20 4 0 0
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 2 1 0 1
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 -3 1 0 1
	./$(OBJ_DIR)/V$(TOP) 1 0 0 0 2 0 0 1
	./$(OBJ_DIR)/V$(TOP) 1 2 10 3 0 0 0 1

clean:
	rm -rf $(OBJ_DIR) build.log

.PHONY: run clean
