T80 := ../../../rtl/third_party_gen/t80/T80s.v
obj_dir/Vtop: top.sv tb.cpp
	verilator --cc --exe --build -Wno-fatal -Wno-WIDTH --top-module top top.sv $(T80) tb.cpp -o Vtop > build.log 2>&1 || { tail -20 build.log; false; }
run: obj_dir/Vtop
	./obj_dir/Vtop
clean:
	rm -rf obj_dir build.log
.PHONY: run clean
