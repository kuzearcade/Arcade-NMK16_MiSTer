# Arcade-NMK16_MiSTer

An FPGA implementation of the NMK16 family of arcade boards for the
[MiSTer FPGA](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform
(DE10-Nano, Cyclone V `5CSEBA6U23I7`).

The NMK16 family is the set of 68000-based boards made by NMK and reused
by UPL, Tecmo, Banpresto, Atlus, Comad and Afega between 1989 and 1997.
MAME groups them under one driver, `nmk16.cpp`, which covers 101
romsets: US AAF Mustang, Thunder Dragon, Macross, GunNail, Macross II,
Thunder Dragon 2, Rapid Hero, Bombjack Twin, Power Instinct and their
relatives.

## Goals

- Implement the hardware as RTL that behaves like the original boards:
  the 68000 bus, the NMK004 sound MCU (a Toshiba TLCS-90 running a fixed
  boot ROM), the NMK-215 protection MCU, tharrierb's MC68705R3, the
  NMK214 graphics descrambler, the NMK112 sample banker, the scanline interrupt
  generator, the tilemap and sprite engines.
- Cover every romset in `nmk16.cpp`, with one `.rbf` per distinct
  hardware family and one `.mra` per game. The full inventory and the
  planned family split are in `docs/game-inventory.md` and
  `docs/PLAN.md`.
- Verify against MAME as the golden reference before hardware
  bring-up: MAME Lua tracers dump bus cycles, frames and RAM state,
  and Verilator testbenches diff the RTL against them. Hardware is then
  compared to MAME with HDMI screenshots and audio captures.

MAME is used as a behavioural reference only. No MAME code is part of
the built core.

## Status

Four cores run on real hardware and match MAME frame by frame in the
scenes that can be compared. 97 game sets ship as `.mra` files under
`releases/` (the parent of each group at the top level, its clones
under `releases/_alternatives/_<parent>/`), one per MAME set.

Every core is named `NMK16_<family>`, and its bitstream ships as
`Arcade-NMK16_<family>_<date>.rbf` — the MiSTer loader prefix-matches a
`.mra`'s `<rbf>` tag against that filename. The prefix is what makes the
four sort and read as one family on an SD card shared with a few hundred
other arcade cores.

All four fit the DE10-Nano's Cyclone V `5CSEBA6U23I7` (41,910 ALMs,
553 M10K) with timing met, as built on 2026-09-14:

| Core | ALMs | M10K | Worst slack |
|---|---|---|---|
| `NMK16_Macross2` | 15,971 (38%) | 447 / 553 | +0.145 ns |
| `NMK16_Gunnail` | 27,392 (65%) | 427 / 553 | +0.245 ns |
| `NMK16_Raphero` | 20,190 (48%) | 421 / 553 | +0.195 ns |
| `NMK16_Afega` | 18,502 (44%) | 370 / 553 | +0.248 ns |

The Flip Screen DIP works on every core (`docs/known-issues.md` NMK-21):
the three NMK families take it from the 68000's flipscreen register, and
the Afega boards, which have no such register, read two independent flip
axes straight off the DIP bus as MAME's `afega_state::video_update` does.
One deliberate divergence there — MAME leaves Afega sprites unmirrored,
and this core mirrors the whole screen.

| Core (`releases/*.rbf`) | Hardware | Games (MAME set names) |
|---|---|---|
| `NMK16_Macross2` | 68000 + Z80 sound, YM2203, 2x OKIM6295 with NMK112 banking; hi-res and Power Instinct's 320-px board as runtime modes, plus the bootleg boards' variants (vblank-only interrupts, a Z80 without its YM2203, a 68000-driven OKI, nibble-swapped tiles) | Thunder Dragon 2 (tdragon2, tdragon2a), Big Bang (bigbang, bigbanga), Thunder Dragon 3 (tdragon3h — plays tdragon2's soundtrack, which MAME leaves silent), Super Spacefortress Macross II (macross2, macross2g, macross2k), Power Instinct / Gouketsuji Ichizoku (powerins, powerinsj, powerinspu, powerinspj, powerinsa, powerinsb) |
| `NMK16_Raphero` | Bare TLCS-90 sound CPU, 14 MHz 68000 | Rapid Hero (raphero, rapheroa), Arcadia (arcadian) |
| `NMK16_Gunnail` | NMK004 sound MCU, YM2203, 2x OKIM6295; NMK-215/113/110 protection MCUs with dual NMK214; hi-res per-line scroll (GunNail), the nine lowres NMK004 boards, the Bombjack Twin boards (no sound CPU, 68000-driven OKIs with NMK112, one 8x8 two-ROM tile layer), Task Force Harrier's Z80 + YM2203 sound board — with MAME's MCU simulation for the parent and a real MC68705R3 for the Lettering bootleg — and the Raiden-sound bootlegs (the Seibu Sound System: Z80 + YM3812 + OKI with its interrupt-vector arbitration; tdragonb's program/GFX bitswaps decoded per fetch) plus the gunnailb/tomagic banked-Z80 boards and Comad's ssmissin/airattck board (Z80 + a single OKI, no FM; decode_ssmissin's gfx bitswap applied per fetch) plus the Afega-published Mustang hacks that reuse it, Many Block's 256x240 screen with its own scroll RAM and scanline interrupt table, all as runtime game modes | GunNail (gunnail, gunnailp), Super Spacefortress Macross (macross), Black Heart (blkheart, blkheartj), US AAF Mustang (mustang, mustangs, mustangb3), Bio-ship Paladin / Space Battle Ship Gomorrah (bioship, sbsgomo), Vandyke (vandyke, vandykejal, vandykejal2, vandykeb), Acrobat Mission (acrobatm), Koutetsu Yousai Strahl (strahl, strahlj, strahlja), Thunder Dragon (tdragon, tdragon1), Hacha Mecha Fighter (hachamf, hachamfa, hachamfp, hachamfb), Bombjack Twin (bjtwin, bjtwina, bjtwinp, bjtwinpa), Saboten Bombers / Cactus (sabotenb, sabotenba, cactus), Nouryoku Koujou Iinkai (nouryoku, nouryokup), Task Force Harrier (tharrier, tharrieru, tharrierb — the Lettering bootleg runs its real, fully dumped MC68705R3), Many Block (manybloc), US AAF Mustang bootlegs (mustangb, mustangb2), Acrobat Mission bootleg (acrobatmbl), Hacha Mecha Fighter bootleg (hachamfb2), Thunder Dragon bootlegs (tdragonb, tdragonb3), Koutetsu Yousai Strahl bootleg (strahljbl), GunNail bootleg (gunnailb), Tom Tom Magic (tomagic), S.S. Mission (ssmissin), Air Attack (airattck, airattcka), Twin Action (twinactn), Dolmen (dolmen, dolmenk), Puzzle World (puzlwrld) |
| `NMK16_Afega` | The Afega derivative boards: 12 MHz 68000 with address-scrambled program ROMs decoded per fetch, Z80 + YM2151 + OKI or twin-OKI sound, an 8bpp background layer. Split out of `NMK16_Gunnail` on 2026-09-13 — the same `rtl/gunnail/gunnail_core.sv` built with `INCLUDE_AFEGA(1)`/`INCLUDE_NMK(0)`, so the NMK004/protection TLCS-90 cores, the YM2203 and the Seibu/YM3812 board are left out of the netlist — 18,502 ALMs against 27,392 for `NMK16_Gunnail` (see the fit table above) | Stagger I / Red Hawk (stagger1, redhawk, redhawki, redhawks, redhawksa, redhawkg, redhawke, redhawkk, redhawkc, redhawkb), Guardian Storm / Hong Hu Zhanji II (grdnstrm, grdnstrmv, grdnstrmj, grdnstrmk, grdnstrmg, grdnstrmau, redfoxwp2, redfoxwp2a), Bubble 2000 / Hot Bubble (bubl2000, bubl2000a, hotbubl, hotbubla), Pop's Pop's (popspops), Mang-Chi (mangchi), Spectrum 2000 (spec2k, spec2kh), Fire Hawk (firehawk) |

Every parent set has been loaded on a DE10-Nano through its `.mra`,
drawn its title and attract sequence in native screenshots and played
sound; the clones share their parent's hardware and differ only in ROM
contents (hachamfa, strahlja, vandykejal2, bjtwina, sabotenba and the
Afega clone sets other than the eleven configurations listed in
`docs/hw-bringup.md` have not been run on the board yet). Each core is pixel-identical to MAME in simulation for the
whole attract sequence that timing allows, and pixel-identical in
hardware screenshots of static scenes (`docs/hw-bringup.md` has the
per-game results). Audio is compared band by band against MAME
captures. `tools/SdramTest.mra` is a hardware diagnostic, not a game,
and is not one of the 97.

The single-game reference ports under `rtl/<game>/` with a matching
testbench under `sim/rtl/<game>/` (the Family E bootlegs mustangb,
tdragonb, acrobatmbl, strahljbl, gunnailb; powerins) remain as
zero-latency register references; every one of those games ships on a
shared rbf as a runtime mode (see docs/hw-bringup.md).

Family B (the lowres NMK004 boards) and the NMK004 half of Family D
went to hardware on 2026-09-11, Family A (Bombjack Twin) and Family G
(Task Force Harrier, the Vandyke bootleg) on 2026-09-12, all as runtime
game modes of the NMK16_Gunnail rbf (`rtl/gunnail/gunnail_core.sv`'s game
table; their original single-game sims under `rtl/<game>/` remain as
register references).
Family H (the 27 Afega-hardware sets) went to hardware on 2026-09-13,
also as NMK16_Gunnail-rbf game modes, with jotego's jt51 (YM2151) vendored for
their sound board. The hardware path (SDRAM ROM caches, clock-domain
crossing, wait states, OKI fetch stalls, the `.mra` loader layout) is
shared, so bringing the remaining games to hardware is mostly wiring
and verification rather than new design. Family E (the nine
Raiden-sound bootlegs, gunnailb and tomagic) followed on 2026-09-14,
with jotego's jtopl (YM3812) and the project's Seibu Sound System glue
joining the NMK16_Gunnail rbf, then the Comad boards (ssmissin, airattck), the
Afega hacks of Mustang (twinactn, dolmen, dolmenk, puzlwrld) and Many
Block, all the same day. Many Block is the one board here whose screen
is not one of MAME's three shared NMK16 timings — 256x240 from raster
line 8 rather than 256x224 from line 16 — so `video_timing.sv`,
`video_retime.sv` and `video_macross2.sv` take a `tall240` mode; its
4 KB scroll RAM is a synchronous-read M10K block whose two scroll words
(0x82/0xc2) are latched into registers on write, an async read there
having cost 98K logic cells in an earlier attempt. tharrierb followed the same
day on a real MC68705R3 — jotego's jt6805 under this project's own
peripheral wrapper, verified against MAME's m6805 for 960,794
instructions and 13 interrupts with zero mismatches (see
`docs/tier7-tharrierb.md`).

`nmk16.cpp` declares 101 romsets and 97 of them ship. **All four that
do not are `MACHINE_NOT_WORKING` in MAME itself**, for reasons MAME
states on its own `GAME` lines:

| Set | MAME's reason | Here |
|---|---|---|
| `powerinsc` | *"different sprites' format not implemented"* | Ported and boots; sprites draw wrong exactly as they do in MAME, so its `.mra` is generated into the gitignored `.non-working/` instead of `releases/` and is never shipped or deployed. `tools/gen_family_c_mra.py`'s `NON_WORKING` set routes it there. |
| `macrossbl` | *"not looked at yet"* | Not attempted — MAME has not characterised this bootleg at all, so there is nothing to port against. |
| `tdragonb2` | *"runs too quickly, Oki sounds terrible (IRQ problems?)"* | Not attempted — it would mean diverging from MAME's own known-broken timing. |
| `firehawkv` | *"incomplete dump, vertical mode gfx not dumped"* | Not attempted — three `NO_DUMP` ROMs and a `BAD_DUMP` stand-in. |

That count is checked rather than carried: parse every `GAME`/`GAMEL`
line out of `nmk16.cpp` and diff the setnames against `<setname>` in
`releases/*.mra` and `releases/_alternatives/*/*.mra`. Make the parser
assert its own completeness against a plain `grep -c '^GAME('` first —
one entry is dated `199?` rather than a four-digit year, and a regex
that assumes `\d{4}` drops it without a word.

`docs/known-issues.md` is the tracked list of open bugs, limitations
and verification gaps in the released cores (stable IDs, status per
item). `docs/hw-bringup.md` records every hardware problem found and how it
was resolved, and `docs/tier2-system.md` holds the per-game simulation
verification results.

## Using the cores

1. Copy the `.rbf` from `releases/` to `_Arcade/cores/` on the MiSTer
   SD card and the matching `.mra` file(s) to `_Arcade/`. Each parent
   `.mra` sits directly under `releases/`; its clone sets (alternate
   regions, bootlegs, revisions) are one level down, under
   `releases/_alternatives/_<parent name>/` — grab those too if you
   want a specific clone rather than the parent set.
2. Place the MAME romset zips under `games/mame/`. The `.mra` files
   name the exact zips and the checksums they were generated from. ROMs
   are not included in this repository.
3. DIP switches are exposed in the OSD. Player inputs follow MAME's
   default key layout. Vertical games have an orientation option. A
   game's own Flip Screen DIP works too, and is separate from the OSD's
   Flip screen option: the DIP is the PCB's own cocktail-cabinet
   setting that the game program acts on, the OSD one rotates the
   finished picture in the framework's scaler.

## Building

The project needs Quartus Prime Lite 17.0 for the hardware build and
Verilator, g++ and Python 3 for the simulations. `sys/` and the
build-required part of `rtl/third_party/` are committed, so no fetch step
and no network access are needed:

```
python3 tools/mkgfxrom.py --zip mame_roms/tdragon2.zip --mode concat \
        --files 10.bpr --out roms/tdragon2_vtiming.hex   # see below
quartus_sh --flow compile NMK16_Gunnail   # or NMK16_Macross2, NMK16_Raphero, NMK16_Afega
```

**One thing a clone does not carry: `roms/*_vtiming.hex`.** Each core's
scanline-interrupt V-PROM (`10.bpr` and friends) is read by
`$readmemh` at synthesis and baked into the bitstream rather than streamed
by the `.mra` at runtime, because `nmk_irq.sv` needs it before any ROM
download happens. That content is copyrighted dump data, so it is never
committed — generate it from your own MAME romsets first, exactly as the
simulation Makefiles do. Each core's `.sv` names the file it wants and the
command that builds it. Without it the PROM initialises to zeros and frame
IRQ and sprite-DMA timing break on hardware after a clean compile.

`tools/bootstrap.sh` is only needed to change a pinned commit, or to pull
a dependency's full upstream tree (datasheets, testbenches, other-toolchain
projects) back down after deleting its directory — those parts are
deliberately not committed.

Each project writes to its own `output_files_nmk16_<family>/`, so the
four can be built side by side. `clean.bat` is Template_MiSTer's scratch
cleaner, kept verbatim as the MiSTer core-contribution guidelines expect
— note it clears the template's `output_files`, not those per-core
directories.

`deps.lock` pins every vendored dependency by commit and records its
licence. The T80 core is VHDL, which Verilator cannot read, so a
Verilog translation made with GHDL and Yosys is committed under
`rtl/third_party_gen/t80/` for simulation only; the Quartus build uses
the original VHDL. See `docs/t80-vhdl-toolchain.md`.

Simulations are run per game, for example:

```
make -C sim/rtl/gunnail run                    # reference sim, zero-latency ROMs
make -C sim/rtl/gunnail_hw run                 # hardware sim, SDRAM model and caches
make -C sim/rtl/gunnail_mg GAME=bioship run    # any NMK16_Gunnail-rbf game on the shared core
make -C sim/rtl/gunnail_mg_hw GAME=strahl run  # ... on the hardware path
```

The simulations read ROM images built from the MAME zips with the
scripts in `tools/`. `docs/sim-harness.md` describes the trace format
and the comparison tools.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/<game>/` | Per-game core top and video module |
| `rtl/tlcs90/` | TLCS-90 CPU core, NMK004 wrapper, NMK-215 protection wrapper |
| `rtl/m68705/` | MC68705R3 wrapper around the vendored jt6805, plus its microcode ROM (`tharrierb`) |
| `rtl/nmk214/`, `rtl/nmk112/`, `rtl/nmk_irq/`, `rtl/seibu/` | Shared NMK and Seibu custom logic |
| `rtl/sdram*.sv`, `rtl/rom_cache1*.sv`, `rtl/oki_rom_cache.sv`, `rtl/tile_prefetch_byte.sv` | SDRAM controller, arbiter and ROM caches for the hardware path |
| `rtl/third_party/` | Vendored cores (gitignored, fetched by `tools/bootstrap.sh`) |
| `sys/` | MiSTer framework (gitignored, fetched by `tools/bootstrap.sh`) |
| `NMK16_<family>.sv`, `.qsf`, `.sdc`, `.qpf`, `.srf`, `files_nmk16_<family>.qip` | **The four real Quartus projects**, one per hardware family. These are what `quartus_sh --flow compile` builds |
| `Template.*`, `files.qip` | Template_MiSTer's skeleton, unmodified and unused — kept only so the repo carries the file set the MiSTer core-contribution guidelines list. `files.qip` is the template's own demo source list, not this project's; the real ones are `files_nmk16_<family>.qip` |
| `SdramTest.*` | A standalone SDRAM diagnostic project, not a game core — `tools/SdramTest.mra` loads it (see Status) |
| `clean.bat` | Template_MiSTer's Quartus scratch-cleaning script, verbatim (it removes `output_files`, not this project's per-core `output_files_nmk16_<family>`) |
| `sim/rtl/` | Verilator testbenches, one per game plus unit tests |
| `sim/oracle/`, `sim/compare/` | MAME Lua tracer and trace comparison |
| `tools/` | ROM builders, `.mra` generators, audio comparison, MiSTer key injection |
| `releases/` | Current `.rbf` bitstreams and `.mra` files |
| `.non-working/` | Gitignored: `.mra` files for sets that cannot work (see Status) |
| `docs/` | Plan, game inventory, verification and bring-up notes |

## Third-party projects and attribution

This core would not exist without the following projects. Each is
vendored at the commit recorded in `deps.lock`, unmodified. Committed here
is the subset the build needs — the HDL the `.qip` files reference, plus
each project's own `LICENSE` — with two further exceptions, both noted
under the table:
`rtl/sdram.sv`, which is a modified fork, and `rtl/third_party_gen/t80/`,
a mechanical GHDL/Yosys translation of T80's VHDL used only by the
simulations.

| Component | Project | Author | Licence |
|---|---|---|---|
| MiSTer framework (`sys/`), project template | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | Sorgelig and the MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later per file |
| Motorola 68000 | [ijor/fx68k](https://github.com/ijor/fx68k) | Jorge Cwik | GPL-3.0 |
| Z80 (T80) | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) | Daniel Wallner, MikeJ (fpgaarcade), Sorgelig | BSD-style, per file header |
| YM2203 (jt12 / jt03), and its nested AY-3-8910 (jt49) for the chip's SSG half | [jotego/jt12](https://github.com/jotego/jt12), submodule [jotego/jt49](https://github.com/jotego/jt49) | Jose Tejada | GPL-3.0-or-later |
| OKIM6295 ADPCM (jt6295) | [jotego/jt6295](https://github.com/jotego/jt6295) | Jose Tejada | GPL-3.0-or-later |
| YM3812 (jtopl) | [jotego/jtopl](https://github.com/jotego/jtopl) | Jose Tejada | GPL-3.0-or-later |
| YM2151 (jt51) | [jotego/jt51](https://github.com/jotego/jt51) | Jose Tejada | GPL-3.0-or-later |
| MC68705R3 / 6805 CPU (jt6805) | [jotego/jtcores](https://github.com/jotego/jtcores), `modules/jt680x/hdl` | Jose Tejada | GPL-3.0-or-later |
| SDRAM controller (`rtl/sdram.sv`) | copied from [rmonic79/Arcade-Darius_MiSTer](https://github.com/rmonic79/Arcade-Darius_MiSTer) | Sorgelig | GPL-3.0-or-later |

There is no standalone `jotego/jt680x` repository — jt6805 is a module of
the **jtcores** monorepo, so `deps.lock` fetches it with a `subdir` kind:
a blob-filtered, sparse, depth-1 fetch of `modules/jt680x/hdl` at one
commit, about 1 MB rather than a full clone. The four vendored files are
byte-identical to jtcores `3278a82`, which is the most recent commit
touching any of them and is after jotego's own *"jt6805: fixed ASR, which
had wrong MSB"*, so this copy has that fix.

jt6805 is a **microcoded** design, and the control store is not jotego's.
`rtl/m68705/6805.uc` (4096 x 39 bits) and the `6805.vh` /
`6805_param.vh` headers that decode it were written for this project;
jotego's own source for the same thing is upstream at
`modules/jt680x/ucode/6805.yaml`, but neither it nor the `jtframe ucode`
generator that consumes it is vendored here, so ours is validated against
MAME's `m6805` instead — 960,794 instructions with zero mismatches.
`tools/uc6805.py` disassembles and reassembles that control store.
`rtl/m68705/m68705_core.sv` — the MC68705R3 peripheral wrapper around
jt6805 (ports A-D and their DDRs, timer, MISC/PCR/ACR/ARR, RAM and ROM,
and the edge-latched external interrupt) — is also this project's own
work. Only `tharrierb` uses any of it; see `docs/tier7-tharrierb.md`.

**`rtl/sdram.sv` is a modified copy, not a vendored one**, and unlike
every other third-party tree it is committed here. It was seeded from
the Arcade-Darius copy of Sorgelig's controller and then given a
`REFRESH_CYCLES` parameter, a `prio_mode` port (round-robin /
video-first / CPU-first / video-75%) and `dout*_pair`, which returns two
words per read transaction. It stays GPL-3.0-or-later under Sorgelig's copyright;
`deps.lock` records the original blob and the commits that changed it.

`rtl/third_party_gen/t80/T80s.v` is the other committed third-party file:
Verilator cannot read VHDL, so T80's `T80s.vhd` and its dependencies were
translated once with GHDL and Yosys (the `ghdl-compat.patch` beside it is
the input fix-up) and the result committed for the simulations only. The
Quartus build compiles the original VHDL, so nothing shipped in a `.rbf`
comes from the translation. It carries T80's own licensing.

The behavioural reference is [MAME](https://github.com/mamedev/mame),
in particular `src/mame/nmk/nmk16.cpp`, `nmk16_v.cpp`, `nmk16spr.cpp`,
`nmk214.cpp`, `nmk004.cpp`, `nmk_irq.cpp`, `cpu/tlcs90/tlcs90.cpp` and
`cpu/m6805/m6805.cpp` + `m68705.cpp`,
by the MAME team and the contributors credited in those files. The
TLCS-90 core, the NMK004 and NMK-215 wrappers, the NMK214 descrambler
and the sprite and tilemap engines in this repository were written
from scratch against that reference.

The project structure and the simulate-against-MAME methodology follow
[kaneko16-mister](https://github.com/alphanu1/kaneko16-mister) and the
MiSTer-devel arcade cores.

## Licence

Copyright (C) 2026 kuzearcade.

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version. See [LICENSE](LICENSE) for the full text.

The vendored components keep their own licences, listed above. All of
them are compatible with distributing the combined work under
GPL-3.0-or-later. The MAME source tree and the arcade ROM images are
not part of this repository and are not covered by this licence.
