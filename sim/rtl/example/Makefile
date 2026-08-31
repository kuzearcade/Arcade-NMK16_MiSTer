# Smoke-test build for the Verilator harness plumbing. See tb_example.cpp
# for what this actually proves (and does not yet prove — untested in the
# authoring environment, see docs/sim-harness.md).
#
# Usage:
#   make            # build and run, produces ./example.trace
#   make check      # also self-diff example.trace against itself via
#                    # sim/compare/oracle_diff.py, as a sanity check that a
#                    # trace file this toolchain writes is also one it can
#                    # read back and compare cleanly
#   make clean

TOP := example_counter
OBJ_DIR := obj_dir

.PHONY: all check clean

all: $(OBJ_DIR)/V$(TOP)
	./$(OBJ_DIR)/V$(TOP)

$(OBJ_DIR)/V$(TOP): $(TOP).sv tb_example.cpp ../common/nmktrace.h ../common/crc32.h
	verilator --cc --exe --build -Wall --top-module $(TOP) \
		$(TOP).sv tb_example.cpp \
		-o V$(TOP)

check: all
	python3 ../../compare/oracle_diff.py example.trace example.trace

clean:
	rm -rf $(OBJ_DIR) example.trace
