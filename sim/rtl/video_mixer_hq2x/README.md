# video_mixer / HQ2X output-width harness (NMK-27)

Built to settle whether HQ2X was producing a short raster on 384-wide games.
It was not: the mixer and our wiring are correct, and the "597 px" reading was
an artifact of MiSTer's native screenshot for a scandoubled raster.

    tb.cpp   drives sys/video_mixer.sv directly with a synthetic raster
    top.sv   wires the REAL rtl/video_retime.sv into video_mixer, as the
             cores do, so the integration itself is under test
    tb2.cpp  drives top.sv

Results (both LINE_LENGTH 400 and 1024, identical):

    M0 (384 active): output DE = 768 x 30205 lines   correct 2x
    M1 (256 active): output DE = 512 x 30204 lines   correct 2x

## Building

Copy `sys/{video_mixer.sv,scandoubler.v,hq2x.sv,video_freezer.sv}` into a
scratch directory and build there -- do NOT edit `sys/`. Verilator rejects
`hq2x.sv`'s procedural assignment to the `Result` **wire** (Quartus accepts
it), so the copy needs `output [23:0] Result` -> `output reg [23:0] Result`.

    verilator --cc --exe --build -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
      --top-module vrtop top.sv video_mixer.sv scandoubler.v hq2x.sv \
      video_freezer.sv ../../../rtl/video_retime.sv tb2.cpp -o vrsim
    ./obj_dir/vrsim        # M0 (384-wide)
    M1=1 ./obj_dir/vrsim   # M1 (256-wide)

## Why this exists

Two hardware hypotheses were tested and disproven first, at ~20 minutes per
build: the CLK_VIDEO/(ce_pix*4) ratio (96 MHz PLL -- no change) and
LINE_LENGTH (400 -> 1024 -- no change). Simulating the mixer took less time
than either and gave the answer outright. When a measurement disagrees with
the code, check the instrument before rebuilding against a new guess.
