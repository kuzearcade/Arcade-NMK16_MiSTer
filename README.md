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
  boot ROM), the NMK-215 protection MCU, the NMK214 graphics
  descrambler, the NMK112 sample banker, the scanline interrupt
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

Three cores run on real hardware and match MAME frame by frame in the
scenes that can be compared. 35 game sets ship as `releases/*.mra`
files, one per MAME set:

| Core (`releases/*.rbf`) | Hardware | Games (MAME set names) |
|---|---|---|
| `Macross2` | 68000 + Z80 sound, YM2203, 2x OKIM6295 with NMK112 banking; hi-res and Power Instinct's 320-px board as runtime modes | Thunder Dragon 2 (tdragon2, tdragon2a), Big Bang (bigbang, bigbanga), Super Spacefortress Macross II (macross2, macross2g, macross2k), Power Instinct / Gouketsuji Ichizoku (powerins, powerinsj, powerinspu, powerinspj) |
| `Raphero` | Bare TLCS-90 sound CPU, 14 MHz 68000 | Rapid Hero (raphero, rapheroa), Arcadia (arcadian) |
| `Gunnail` | NMK004 sound MCU, YM2203, 2x OKIM6295; NMK-215/113/110 protection MCUs with dual NMK214; hi-res per-line scroll (GunNail) and the nine lowres NMK004 boards as runtime game modes (two BG layers, Bio-ship's ROM tilemap) | GunNail (gunnail, gunnailp), Super Spacefortress Macross (macross), Black Heart (blkheart, blkheartj), US AAF Mustang (mustang, mustangs), Bio-ship Paladin / Space Battle Ship Gomorrah (bioship, sbsgomo), Vandyke (vandyke, vandykejal, vandykejal2), Acrobat Mission (acrobatm), Koutetsu Yousai Strahl (strahl, strahlj, strahlja), Thunder Dragon (tdragon, tdragon1), Hacha Mecha Fighter (hachamf, hachamfa, hachamfp) |

Every parent set has been loaded on a DE10-Nano through its `.mra`,
drawn its title and attract sequence in native screenshots and played
sound; the clones share their parent's hardware and differ only in ROM
contents (hachamfa, strahlja and vandykejal2 have not been run on the
board yet). Each core is pixel-identical to MAME in simulation for the
whole attract sequence that timing allows, and pixel-identical in
hardware screenshots of static scenes (`docs/hw-bringup.md` has the
per-game results). Audio is compared band by band against MAME
captures. `SdramTest` is a hardware diagnostic, not a game.

A further set of games is ported and verified in Verilator against MAME
traces but has not yet been built for hardware. Their RTL lives under
`rtl/<game>/` with a matching testbench under `sim/rtl/<game>/`:

- Family D (NMK-215 protection, no NMK004): hachamfb, bjtwin
- Family E (Seibu-style Z80 + YM3812 bootlegs): mustangb, tdragonb,
  acrobatmbl, strahljbl, gunnailb
- Family C (Z80 direct sound): powerins (its own zero-latency reference
  port; the game ships on the Macross2 rbf through the shared
  tdragon2_core's `game_powerins` mode — see docs/hw-bringup.md)
- Family A (no sound CPU): cactus / bjtwin prototypes

Family B (the lowres NMK004 boards) and the NMK004 half of Family D
went to hardware on 2026-09-11 as runtime game modes of the Gunnail
rbf (`rtl/gunnail/gunnail_core.sv`'s game table; their original
single-game sims under `rtl/<game>/` remain as register references).
The hardware path (SDRAM ROM caches, clock-domain crossing, wait
states, OKI fetch stalls, the `.mra` loader layout) is shared, so
bringing the remaining games to hardware is mostly wiring and
verification rather than new design. The Afega derivatives (Family H)
and the early boards (Family G) are not started.

`docs/known-issues.md` is the tracked list of open bugs, limitations
and verification gaps in the released cores (stable IDs, status per
item). `docs/hw-bringup.md` records every hardware problem found and how it
was resolved, and `docs/tier2-system.md` holds the per-game simulation
verification results.

## Using the cores

1. Copy the `.rbf` from `releases/` to `_Arcade/cores/` on the MiSTer
   SD card and the matching `.mra` files to `_Arcade/`.
2. Place the MAME romset zips under `games/mame/`. The `.mra` files
   name the exact zips and the checksums they were generated from. ROMs
   are not included in this repository.
3. DIP switches are exposed in the OSD. Player inputs follow MAME's
   default key layout. Vertical games have an orientation option.

## Building

The project needs Quartus Prime Lite 17.0 for the hardware build and
Verilator, g++ and Python 3 for the simulations. Third-party cores are
not committed; fetch them at their pinned commits first:

```
tools/bootstrap.sh
quartus_sh --flow compile Gunnail     # or Macross2, Raphero
```

`deps.lock` pins every vendored dependency by commit and records its
licence. The T80 core is VHDL, which Verilator cannot read, so a
Verilog translation made with GHDL and Yosys is committed under
`rtl/third_party_gen/t80/` for simulation only; the Quartus build uses
the original VHDL. See `docs/t80-vhdl-toolchain.md`.

Simulations are run per game, for example:

```
make -C sim/rtl/gunnail run                    # reference sim, zero-latency ROMs
make -C sim/rtl/gunnail_hw run                 # hardware sim, SDRAM model and caches
make -C sim/rtl/gunnail_mg GAME=bioship run    # any Gunnail-rbf game on the shared core
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
| `rtl/nmk214/`, `rtl/nmk112/`, `rtl/nmk_irq/`, `rtl/seibu/` | Shared NMK and Seibu custom logic |
| `rtl/sdram*.sv`, `rtl/rom_cache1*.sv`, `rtl/oki_rom_cache.sv`, `rtl/tile_prefetch_byte.sv` | SDRAM controller, arbiter and ROM caches for the hardware path |
| `rtl/third_party/` | Vendored cores (gitignored, fetched by `tools/bootstrap.sh`) |
| `sys/` | MiSTer framework (gitignored, fetched by `tools/bootstrap.sh`) |
| `<Core>.sv`, `<Core>.qsf`, `<Core>.sdc`, `files_<core>.qip` | Quartus project per hardware family |
| `sim/rtl/` | Verilator testbenches, one per game plus unit tests |
| `sim/oracle/`, `sim/compare/` | MAME Lua tracer and trace comparison |
| `tools/` | ROM builders, `.mra` generators, audio comparison, MiSTer key injection |
| `releases/` | Current `.rbf` bitstreams and `.mra` files |
| `docs/` | Plan, game inventory, verification and bring-up notes |

## Third-party projects and attribution

This core would not exist without the following projects. Each is
fetched unmodified at the commit recorded in `deps.lock`.

| Component | Project | Author | Licence |
|---|---|---|---|
| MiSTer framework (`sys/`), project template | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | Sorgelig and the MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later per file |
| Motorola 68000 | [ijor/fx68k](https://github.com/ijor/fx68k) | Jorge Cwik | GPL-3.0 |
| Z80 (T80) | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) | Daniel Wallner, MikeJ (fpgaarcade), Sorgelig | BSD-style, per file header |
| YM2203 (jt12 / jt03) | [jotego/jt12](https://github.com/jotego/jt12) | Jose Tejada | GPL-3.0 |
| YM3812 (jtopl) | [jotego/jtopl](https://github.com/jotego/jtopl) | Jose Tejada | GPL-3.0 |
| OKIM6295 (jt6295) | [jotego/jt6295](https://github.com/jotego/jt6295) | Jose Tejada | GPL-3.0 |
| SDRAM controller (`rtl/sdram.sv`) | copied from [rmonic79/Arcade-Darius_MiSTer](https://github.com/rmonic79/Arcade-Darius_MiSTer) | Sorgelig | GPL-3.0 |

The behavioural reference is [MAME](https://github.com/mamedev/mame),
in particular `src/mame/nmk/nmk16.cpp`, `nmk16_v.cpp`, `nmk16spr.cpp`,
`nmk214.cpp`, `nmk004.cpp`, `nmk_irq.cpp` and `cpu/tlcs90/tlcs90.cpp`,
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
