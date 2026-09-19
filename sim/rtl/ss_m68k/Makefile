FX := ../../../rtl/third_party/fx68k
obj_dir/Vtop: top.sv tb.cpp
	cp $(FX)/microrom.mem $(FX)/nanorom.mem . 2>/dev/null || cp ../gunnail_hs/microrom.mem ../gunnail_hs/nanorom.mem .
	verilator --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-BLKANDNBLK -Wno-UNOPTFLAT --top-module top top.sv $(FX)/fx68k.sv $(FX)/fx68kAlu.sv $(FX)/uaddrPla.sv tb.cpp -o Vtop > build.log 2>&1 || { tail -30 build.log; false; }
run: obj_dir/Vtop
	./obj_dir/Vtop
clean:
	rm -rf obj_dir build.log microrom.mem nanorom.mem
.PHONY: run clean
