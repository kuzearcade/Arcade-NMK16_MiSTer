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
- Cover every romset in `nmk16.cpp` that MAME itself marks as working,
  with one `.rbf` per distinct hardware family and one `.mra` per game.
  Sets MAME flags `MACHINE_NOT_WORKING` are out of scope until MAME
  can run them. The full inventory and the family split are in
  `docs/game-inventory.md` and `docs/PLAN.md`.
- Verify against MAME as the golden reference before hardware
  bring-up: MAME Lua tracers dump bus cycles, frames and RAM state,
  and Verilator testbenches diff the RTL against them. Hardware is then
  compared to MAME with HDMI screenshots and audio captures.

MAME is used as a behavioural reference only. No MAME code is part of
the built core.

## Status

Four cores, 97 game sets. Every set that MAME marks as working ships as
a `.mra` under `releases/` (the parent of each group at the top level,
its clones under `releases/_alternatives/_<parent>/`), one per MAME set,
and every one of the 97 has been loaded on a DE10-Nano through its
`.mra`, coined up, started and captured in play (the 2026-09-17 sweep in
`docs/hw-bringup.md`).

Every core is named `NMK16_<family>` and its bitstream ships as
`Arcade-NMK16_<family>_<date>.rbf`; the MiSTer loader prefix-matches a
`.mra`'s `<rbf>` tag against that filename, so the four sort and read as
one family on an SD card shared with other arcade cores.

All four fit the DE10-Nano's Cyclone V `5CSEBA6U23I7` (41,910 ALMs,
553 M10K) with timing met, as built on 2026-09-19
(`Arcade-NMK16_*_20260919.rbf`; the CRT Adjust chain
and its 96 / 112 MHz video clocks added about 1,500 ALMs and 40–60 M10K
per core over the day before; the savestate engine, the two CPU park
monitors and the FM register shadow another ~800–1,200 ALMs and 2–5 M10K;
Macross2's 112 MHz clock still needs a seed pick after any logic change --
seed 11 for this build, where seeds 1, 3, 5 and 7 all missed by 0.05–0.5 ns):

| Core | ALMs | M10K | Worst slack |
|---|---|---|---|
| `NMK16_Macross2` | 20,596 (49%) | 534 / 553 | +0.152 ns |
| `NMK16_Gunnail` | 31,405 (75%) | 525 / 553 | +0.552 ns |
| `NMK16_Raphero` | 25,324 (60%) | 520 / 553 | +0.480 ns |
| `NMK16_Afega` | 23,369 (56%) | 468 / 553 | +0.551 ns |

| Core (`releases/*.rbf`) | Hardware | Games (MAME set names) |
|---|---|---|
| `NMK16_Macross2` | 68000 + Z80 sound, YM2203, 2x OKIM6295 with NMK112 banking; hi-res and Power Instinct's 320-px board as runtime modes, plus the bootleg boards' variants (vblank-only interrupts, a Z80 without its YM2203, a 68000-driven OKI, nibble-swapped tiles) | Thunder Dragon 2 (tdragon2, tdragon2a), Big Bang (bigbang, bigbanga), Thunder Dragon 3 (tdragon3h — plays tdragon2's soundtrack, which MAME leaves silent), Super Spacefortress Macross II (macross2, macross2g, macross2k), Power Instinct / Gouketsuji Ichizoku (powerins, powerinsj, powerinspu, powerinspj, powerinsa, powerinsb) |
| `NMK16_Raphero` | Bare TLCS-90 sound CPU, 14 MHz 68000 | Rapid Hero (raphero, rapheroa), Arcadia (arcadian) |
| `NMK16_Gunnail` | NMK004 sound MCU, YM2203, 2x OKIM6295; NMK-215/113/110 protection MCUs with dual NMK214; hi-res per-line scroll (GunNail), the nine lowres NMK004 boards, the Bombjack Twin boards (no sound CPU, 68000-driven OKIs with NMK112, one 8x8 two-ROM tile layer), Task Force Harrier's Z80 + YM2203 sound board — with MAME's MCU simulation for the parent and a real MC68705R3 for the Lettering bootleg — the Raiden-sound bootlegs (the Seibu Sound System: Z80 + YM3812 + OKI with its interrupt-vector arbitration; tdragonb's program/GFX bitswaps decoded per fetch), the gunnailb/tomagic banked-Z80 boards, Comad's ssmissin/airattck board (Z80 + a single OKI, no FM; decode_ssmissin's gfx bitswap applied per fetch) and the Afega-published Mustang hacks that reuse it, and Many Block's 256x240 screen with its own scroll RAM and scanline interrupt table, all as runtime game modes | GunNail (gunnail, gunnailp), Super Spacefortress Macross (macross), Black Heart (blkheart, blkheartj), US AAF Mustang (mustang, mustangs, mustangb3), Bio-ship Paladin / Space Battle Ship Gomorrah (bioship, sbsgomo), Vandyke (vandyke, vandykejal, vandykejal2, vandykeb), Acrobat Mission (acrobatm), Koutetsu Yousai Strahl (strahl, strahlj, strahlja), Thunder Dragon (tdragon, tdragon1), Hacha Mecha Fighter (hachamf, hachamfa, hachamfp, hachamfb), Bombjack Twin (bjtwin, bjtwina, bjtwinp, bjtwinpa), Saboten Bombers / Cactus (sabotenb, sabotenba, cactus), Nouryoku Koujou Iinkai (nouryoku, nouryokup), Task Force Harrier (tharrier, tharrieru, tharrierb — the Lettering bootleg runs its real, fully dumped MC68705R3), Many Block (manybloc), US AAF Mustang bootlegs (mustangb, mustangb2), Acrobat Mission bootleg (acrobatmbl), Hacha Mecha Fighter bootleg (hachamfb2), Thunder Dragon bootlegs (tdragonb, tdragonb3), Koutetsu Yousai Strahl bootleg (strahljbl), GunNail bootleg (gunnailb), Tom Tom Magic (tomagic), S.S. Mission (ssmissin), Air Attack (airattck, airattcka), Twin Action (twinactn), Dolmen (dolmen, dolmenk), Puzzle World (puzlwrld) |
| `NMK16_Afega` | The Afega derivative boards: 12 MHz 68000 with address-scrambled program ROMs decoded per fetch, Z80 + YM2151 + OKI or twin-OKI sound, an 8bpp background layer. The same `rtl/gunnail/gunnail_core.sv` built with `INCLUDE_AFEGA(1)`/`INCLUDE_NMK(0)`, which leaves the NMK004/protection TLCS-90 cores, the YM2203 and the Seibu/YM3812 board out of the netlist | Stagger I / Red Hawk (stagger1, redhawk, redhawki, redhawks, redhawksa, redhawkg, redhawke, redhawkk, redhawkc, redhawkb), Guardian Storm / Hong Hu Zhanji II (grdnstrm, grdnstrmv, grdnstrmj, grdnstrmk, grdnstrmg, grdnstrmau, redfoxwp2, redfoxwp2a), Bubble 2000 / Hot Bubble (bubl2000, bubl2000a, hotbubl, hotbubla), Pop's Pop's (popspops), Mang-Chi (mangchi), Spectrum 2000 (spec2k, spec2kh), Fire Hawk (firehawk) |

Each core is pixel-identical to MAME in simulation for the whole attract
sequence that timing allows, and pixel-identical in hardware screenshots
of static scenes (`docs/hw-bringup.md` has the per-game results). Audio is
compared band by band against MAME captures. `tools/SdramTest.mra` is a
hardware diagnostic, not a game, and is not one of the 97.

The single-game reference ports under `rtl/<game>/` with a matching
testbench under `sim/rtl/<game>/` (the Family E bootlegs mustangb,
tdragonb, acrobatmbl, strahljbl, gunnailb; powerins) remain as
zero-latency register references; every one of those games ships on a
shared rbf as a runtime mode (see `docs/hw-bringup.md`).

`nmk16.cpp` declares 101 romsets. The four that do not ship are all
`MACHINE_NOT_WORKING` in MAME itself, for reasons MAME states on its
own `GAME` lines, and are outside this project's goal until MAME can
run them:

| Set | MAME's reason | Here |
|---|---|---|
| `powerinsc` | *"different sprites' format not implemented"* | Ported and boots; sprites draw wrong exactly as they do in MAME, so its `.mra` is generated into the gitignored `.non-working/` instead of `releases/` and is never shipped or deployed. `tools/gen_family_c_mra.py`'s `NON_WORKING` set routes it there. |
| `macrossbl` | *"not looked at yet"* | Not attempted — MAME has not characterised this bootleg at all, so there is nothing to port against. |
| `tdragonb2` | *"runs too quickly, Oki sounds terrible (IRQ problems?)"* | Not attempted — it would mean diverging from MAME's own known-broken timing. |
| `firehawkv` | *"incomplete dump, vertical mode gfx not dumped"* | Not attempted — three `NO_DUMP` ROMs and a `BAD_DUMP` stand-in. |

That count is checked rather than carried: parse every `GAME`/`GAMEL`
line out of `nmk16.cpp` and diff the setnames against `<setname>` in
`releases/*.mra` and `releases/_alternatives/*/*.mra`, asserting the
parser's own completeness against a plain `grep -c '^GAME('` first (one
entry is dated `199?`, and a regex that assumes `\d{4}` drops it).

`docs/known-issues.md` is the tracked list of open bugs, limitations
and verification gaps in the released cores (stable IDs, status per
item). `docs/hw-bringup.md` records every hardware problem found and how
it was resolved, and `docs/tier2-system.md` holds the per-game simulation
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
   default key layout. Vertical games have an Orientation option on the
   HDMI/scaler path. **Flip screen** (a 180-degree turn) is offered for
   every game and works on every output — HDMI, the analog I/O board's
   VGA and direct video (`direct_video=1` in MiSTer.ini) — because the
   core mirrors its own picture, the same path the games' Flip Screen
   DIP takes, so it also works for sets whose board ignores that DIP
   (Task Force Harrier). A game's own Flip Screen DIP stays separate: it
   is the PCB's cocktail-cabinet setting the game program acts on, and
   the two compose. Under direct video the Scandoubler Fx and
   Orientation options are hidden, since neither path exists there.
   The P1/P2 Autofire options stay hidden unless the loaded `.mra`
   opts in (its `<switches>` third byte, bit 6); the shipped files do
   not, and `tools/gen_autofire_mra.py` writes a git-ignored
   `autofire_releases/` mirror of `releases/` with that bit set for the
   shoot-'em-up sets, same layout and file names. One MiSTer caveat: a
   game whose DIP switches were ever changed in the OSD has a
   `config/dips/<mra name>.dip` file, and the firmware loads that whole
   value over the `.mra` default, third byte included, so Autofire stays
   hidden for that game until the file is deleted or the OSD's "Reset
   settings" restores the defaults.
4. Analog/CRT users have a **CRT Adjust** page in the OSD (H-Size,
   H-Position, V-Shift, V-Size with PVM and Cabinet modes), on every
   output — the I/O board's VGA carries the same stream the scaler sees,
   so the page is never hidden. Off outputs the native stream unchanged;
   the chain is bypassed while the scandoubler/HQ2X or a Vert orientation
   is active. Limits and sign convention in `docs/known-issues.md` NMK-31.
5. **High scores** (Scores page) are saved and restored through MAME's
   hiscore.dat tables, but the option is **Off by default**: turn "High
   Scores" On and the scores are restored at boot and saved whenever the
   OSD is opened (Save Scores forces one). Save Scores and Reset Scores
   are greyed out while the option is Off. A saved file that fails the
   table's own start/end checks is ignored rather than restored.
   `docs/known-issues.md` NMK-24 and NMK-33.
6. **Savestates**: every core has a Savestates page in the OSD (Slot
   1-4, Save state, Load state); on a keyboard F1-F4 load slot 1-4 and
   Alt+F1-F4 save. States go to the SD card through the MiSTer
   savestate framework (`savestates/<core>/<game>_<slot>.ss`) and are
   reloaded on the next launch. The whole machine is saved (both CPUs,
   the MCUs, all RAM, the video registers, the FM register file); what
   is not: a sample the OKI chips were playing at the save (silent after
   a load), and notes the FM chips were holding (they resume at the next
   key-on). Not offered on `tharrierb` (its MC68705 is not captured).
   Details in `docs/hw-bringup.md` "Savestates" and `docs/known-issues.md`
   NMK-32.

## Building

The project needs Quartus Prime Lite 17.0 for the hardware build and
Verilator, g++ and Python 3 for the simulations. A clone builds as-is:
`sys/` and the build-required part of `rtl/third_party/` are committed, no
fetch step, no network access, and **no ROM data of any kind**:

```
quartus_sh --flow compile NMK16_Gunnail   # or NMK16_Macross2, NMK16_Raphero, NMK16_Afega
```

The scanline-interrupt V-PROM each board carries (`10.bpr` and friends) used
to be an exception — read by `$readmemh` at synthesis, which put arcade PROM
content in the shipped `.rbf` and made the build depend on locally generated
`roms/*_vtiming.hex`. Since 2026-09-15 each `.mra` streams it as its own
`<rom index="1">` region and `nmk_irq.sv` takes it over `ioctl_download`
like every other ROM, so nothing copyrighted is compiled in.

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
vendored at the commit recorded in `deps.lock`. Committed here is the
subset the build needs — the HDL the `.qip` files reference, plus each
project's own `LICENSE`. Four pieces are modified forks, each documented in
its file header and in `deps.lock`: `rtl/sdram.sv`; `hiscore.v`'s
`dpram_hs` (rewritten so Quartus 17 infers block RAM at the table size
these games need); `crt_vsize.sv` (pipeline registers on the ring RAM's
read and write paths for the 112 MHz video clock); and
`rtl/third_party_gen/t80/`, a mechanical GHDL/Yosys translation of T80's
VHDL used only by the simulations.

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
| High score save/load (`hiscore.v`, MAME hiscore.dat tables) | [MiSTer-devel/Hiscores_MiSTer](https://github.com/MiSTer-devel/Hiscores_MiSTer) | Alan Steremberg, Jim Gregory | GPL-3.0-or-later |
| CRT Adjust: analog picture offset (H-Position, V-Shift) and size (H-Size, V-Size with PVM / Cabinet modes) on the 15 kHz output, `crt_adjust.sv` and `crt_vsize.sv` | [rmonic79/MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust) | Umberto Parisi (rmonic79), with Andrea Bogazzi | GPL-3.0-or-later |

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
