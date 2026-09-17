# NMK-29 probe scripts (ssmissin coins/audio)

MAME-side oracles matching the hardware debug overlays. All three need their
notifier/tap tokens held in GLOBALS or MAME garbage-collects them and the
callback silently stops firing.

    ss4.lua    deterministic coin control -- screen hash at fixed frames, with
               and without a coin, proving MAME does register it
    sssnd.lua  soundlatch writes (68000 0x0C001E-F) and OKI writes (Z80 0x9800)
    sspc.lua   ROM-region coverage: which 8 KB buckets of the 256 KB program
               ROM are touched, in windows -- the exact measurement the
               hardware overlay makes, so the two are directly comparable

Run e.g.:

    cd mame && ./mame ssmissin -rompath ../mame_roms \
      -autoboot_script ../sim/rtl/nmk29_probes/sspc.lua \
      -video none -sound none -seconds_to_run 16 -nothrottle -skip_gameinfo
