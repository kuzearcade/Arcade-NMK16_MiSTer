# NMK16 Game Inventory — Milestone 0

Full enumeration of every `GAME()`/`GAMEL()` entry in `mame/src/mame/nmk/nmk16.cpp`, grouped by hardware family (A–I, per `docs/PLAN.md`). **Correction to the plan: there are 101 romsets, not 85** (`grep -c "^GAME(" nmk16.cpp` = 101; the original 85-count from earlier research undercounted).

Columns: Short name · Description · Year · Manufacturer · Parent (— = is itself the parent) · Machine-config function (from the `GAME()` macro's 4th field) · State class (5th field, C++ driver class) · Orientation (from the macro's actual `ROT0`/`ROT270`/`ORIENTATION_FLIP_Y` flag — ROT0/ORIENTATION_FLIP_Y = horizontal cabinet, ROT270/ROT90 = vertical/tate) · Notes/quirks.

Screen resolution class (low/mid/hi) is at the **family** level per prior research (confirmed via the screen-timing source read for families A–G; not yet re-derived per-game from `MACHINE_CONFIG` blocks in this pass — flagged `TBD` where genuinely unconfirmed). Afega (family H) uses its own screen setup, not the NMK low/mid/hi classes.

## Family A — no sound CPU, no protection MCU (hi-res)

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| cactus | Cactus (bootleg of Saboten Bombers) | 1992 | bootleg | sabotenb | `cactus` | nmk16_state | horizontal | Also drops `nmk_irq`; no title screen |
| bjtwinp | Bombjack Twin (prototype?, set 1) | 1993 | NMK | bjtwin | `bjtwin` | nmk16_state | vertical | "GFX aren't encrypted"; cheap PCB but genuine NMK |
| nouryokup | Nouryoku Koujou Iinkai (prototype) | 1995 | Tecmo | nouryoku | `bjtwin` | nmk16_state | horizontal | "GFX aren't encrypted" |

## Family B — NMK004 (TLCS-90) sound MCU, low-res

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| mustang | US AAF Mustang (25th May 1990) | 1990 | UPL | — | `mustang` | nmk16_state | horizontal | |
| mustangs | US AAF Mustang (Seoul Trading) | 1990 | UPL (Seoul Trading) | mustang | `mustang` | nmk16_state | horizontal | |
| bioship | Bio-ship Paladin | 1990 | UPL (American Sammy) | — | `bioship` | nmk16_state | horizontal | 3-layer video (unique in family B) |
| sbsgomo | Space Battle Ship Gomorrah (Japan) | 1990 | UPL | bioship | `bioship` | nmk16_state | horizontal | 3-layer video |
| vandyke | Vandyke (Japan) | 1990 | UPL | — | `vandyke` | nmk16_state | vertical | |
| vandykejal | Vandyke (Jaleco, set 1) | 1990 | UPL (Jaleco) | vandyke | `vandyke` | nmk16_state | vertical | |
| vandykejal2 | Vandyke (Jaleco, set 2) | 1990 | UPL (Jaleco) | vandyke | `vandyke` | nmk16_state | vertical | |
| blkheart | Black Heart | 1991 | UPL | — | `blkheart` | nmk16_state | horizontal | |
| blkheartj | Black Heart (Japan) | 1991 | UPL | blkheart | `blkheart` | nmk16_state | horizontal | |
| acrobatm | Acrobat Mission | 1991 | UPL (Taito license) | — | `acrobatm` | nmk16_state | vertical | |
| strahl | Koutetsu Yousai Strahl (World) | 1992 | UPL | — | `strahl` | nmk16_state | horizontal | 2-layer video |
| strahlj | Strahl (Japan set 1) | 1992 | UPL | strahl | `strahl` | nmk16_state | horizontal | 2-layer video |
| strahlja | Strahl (Japan set 2) | 1992 | UPL | strahl | `strahl` | nmk16_state | horizontal | 2-layer video |
| tdragon | Thunder Dragon (unprotected) | 1991 | NMK (Tecmo license) | — | `tdragon` | nmk16_state | vertical | Unprotected board revision |
| hachamfb | Hacha Mecha Fighter (unprotected bootleg) | 1991 | bootleg | hachamf | `hachamfb` | nmk16_state | horizontal | "Appears to be a Thunder Dragon conversion" |
| hachamfp | Hacha Mecha Fighter (location test proto) | 1991 | NMK | hachamf | `hachamfp` | nmk16_state | horizontal | Hand-written date labels |

## Family C — Z80-direct sound, hi/mid-res

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| macross2 | Macross II | 1993 | Banpresto | — | `macross2` | nmk16_state | horizontal | |
| macross2g | Macross II (Gamest review build) | 1993 | Banpresto | macross2 | `macross2` | nmk16_state | horizontal | Service switch pauses game |
| macross2k | Macross II (Korea) | 1993 | Banpresto | macross2 | `macross2` | nmk16_state | horizontal | |
| tdragon2 | Thunder Dragon 2 (9th Nov 1993) | 1993 | NMK | — | `tdragon2` | nmk16_state | vertical | |
| tdragon2a | Thunder Dragon 2 (1st Oct 1993) | 1993 | NMK | tdragon2 | `tdragon2` | nmk16_state | vertical | |
| bigbang | Big Bang (set 1) | 1993 | NMK | tdragon2 | `tdragon2` | nmk16_state | vertical | |
| bigbanga | Big Bang (set 2) | 1993 | NMK | tdragon2 | `tdragon2` | nmk16_state | vertical | |
| tdragon3h | Thunder Dragon 3 (bootleg of TD2) | 1996 | bootleg (Conny) | tdragon2 | `tdragon3h` | nmk16_state | vertical | MACHINE_NO_SOUND; needs sim of missing YM2203 IRQ mechanism |
| arcadian | Arcadia (NMK) | 1994 | NMK | — | `raphero` | nmk16_state | vertical | bare `tmp90c841` TLCS-90 wiring, no NMK004 relay |
| raphero | Rapid Hero (NMK) | 1994 | NMK | arcadian | `raphero` | nmk16_state | vertical | |
| rapheroa | Rapid Hero (Media Trading) | 1994 | NMK (Media Trading) | arcadian | `raphero` | nmk16_state | vertical | |
| powerins | Power Instinct (USA) | 1993 | Atlus | — | `powerins` | nmk16_state | horizontal | mid-res; MACHINE_SUPPORTS_SAVE |
| powerinsj | Gouketsuji Ichizoku (Japan) | 1993 | Atlus | powerins | `powerins` | nmk16_state | horizontal | mid-res |
| powerinspu | Power Instinct (USA, prototype) | 1993 | Atlus | powerins | `powerins` | nmk16_state | horizontal | mid-res |
| powerinspj | Gouketsuji Ichizoku (Japan, proto) | 1993 | Atlus | powerins | `powerins` | nmk16_state | horizontal | mid-res |
| powerinsa | Power Instinct (bootleg set 1) | 1993 | bootleg | powerins | `powerinsa` | nmk16_state | horizontal | mid-res; distinct machine-config |
| powerinsb | Power Instinct (bootleg set 2) | 1993 | bootleg | powerins | `powerinsb` | nmk16_state | horizontal | mid-res; distinct machine-config |
| powerinsc | Power Instinct (bootleg set 3) | 1993 | bootleg (Electronic Devices) | powerins | `powerinsc` | nmk16_state | horizontal | **MACHINE_NOT_WORKING in MAME itself** — different sprite format not implemented even by MAME; recommend deprioritizing/excluding |

## Family D — TLCS-90 protection MCU (NMK-110/113/215)

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| tdragon1 | Thunder Dragon (protected, 4th Jun 1991) | 1991 | NMK (Tecmo license) | tdragon | `tdragon_prot` | tdragon_prot_state | vertical | low-res |
| hachamf | Hacha Mecha Fighter (protected, set 1) | 1991 | NMK | — | `hachamf_prot` | tdragon_prot_state | horizontal | low-res |
| hachamfa | Hacha Mecha Fighter (protected, set 2) | 1991 | NMK | hachamf | `hachamf_prot` | tdragon_prot_state | horizontal | low-res |
| macross | Super Spacefortress Macross | 1992 | Banpresto | — | `macross_prot` | macross_prot_state | vertical | low-res; dual nmk214 |
| gunnail | GunNail (28th May 1992) | 1993 | NMK / Tecmo | — | `gunnail_prot` | macross_prot_state | vertical | hi-res; dual nmk214; per-scanline raster scroll |
| gunnailp | GunNail (location test) | 1992 | NMK | gunnail | `gunnail_prot` | macross_prot_state | vertical | hi-res |
| sabotenb | Saboten Bombers (set 1) | 1992 | NMK / Tecmo | — | `bjtwin_prot` | macross_prot_state | horizontal | hi-res; COL-scan single-layer video |
| sabotenba | Saboten Bombers (set 2) | 1992 | NMK / Tecmo | sabotenb | `bjtwin_prot` | macross_prot_state | horizontal | hi-res |
| bjtwin | Bombjack Twin (set 1) | 1993 | NMK | — | `bjtwin_prot` | macross_prot_state | vertical | hi-res; COL-scan single-layer video |
| bjtwina | Bombjack Twin (set 2) | 1993 | NMK | bjtwin | `bjtwin_prot` | macross_prot_state | vertical | hi-res |
| bjtwinpa | Bombjack Twin (proto, set 2) | 1993 | NMK | bjtwin | `bjtwin_prot` | macross_prot_state | vertical | hi-res; GFX encrypted (unlike bjtwinp) |
| nouryoku | Nouryoku Koujou Iinkai | 1995 | Tecmo | — | `bjtwin_prot` | macross_prot_state | horizontal | hi-res |

**Family D hardware split**: at least 3 genuinely distinct video/CPU configs share this protection mechanism: (1) tdragon1/hachamf/hachamfa — low-res, single-layer; (2) macross (low-res) / gunnail+gunnailp (hi-res, raster scroll) — page-mapped multi-source tilemap; (3) sabotenb+bjtwin family — hi-res, COL-scan single-layer. These need separate `.rbf` builds despite sharing the TLCS-90 protection mechanism.

## Family E — Raiden-style bootleg sound hardware (YM3812) + tomagic

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| mustangb | US AAF Mustang (bootleg, set 1) | 1990 | bootleg | mustang | `mustangb` | nmk16_state | horizontal | low-res |
| mustangb2 | US AAF Mustang (TAB Austria bootleg) | 1990 | bootleg (TAB Austria) | mustang | `mustangb` | nmk16_state | horizontal | low-res |
| mustangb3 | US AAF Mustang (Lettering bootleg) | 1990 | bootleg (Lettering) | mustang | `mustangb3` | nmk16_state | horizontal | low-res; distinct machine-config from mustangb |
| acrobatmbl | Acrobat Mission (bootleg, Raiden sounds) | 1991 | bootleg | acrobatm | `acrobatmbl` | nmk16_state | vertical | low-res |
| hachamfb2 | Hacha Mecha Fighter (bootleg, Raiden sounds) | 1991 | bootleg | hachamf | `hachamfb2` | nmk16_state | horizontal | low-res |
| tdragonb | Thunder Dragon (bootleg, Raiden, encrypted) | 1991 | bootleg | tdragon | `tdragonb` | nmk16_state | vertical | low-res |
| tdragonb3 | Thunder Dragon (bootleg, Raiden, unencrypted) | 1991 | bootleg | tdragon | `tdragonb3` | nmk16_state | vertical | low-res; distinct machine-config |
| tdragonb2 | Thunder Dragon (bootleg, reduced sound system) | 1991 | bootleg | tdragon | `tdragonb2` | nmk16_state | vertical | low-res; **MACHINE_IMPERFECT_SOUND \| MACHINE_NOT_WORKING** — "runs too quickly, IRQ problems"; distinct machine-config, likely needs its own hw variant |
| strahljbl | Koutetsu Yousai Strahl (Japan, bootleg) | 1992 | bootleg | strahl | `strahljbl` | nmk16_state | horizontal | low-res, 2-layer |
| macrossbl | Macross (bootleg, Raiden sounds) | 199? | bootleg | macross | `macrossbl` | nmk16_state | vertical | low-res; **MACHINE_NOT_WORKING** — "not looked at yet" in MAME |
| gunnailb | GunNail (bootleg) | 1992 | bootleg | gunnail | `gunnailb` | nmk16_state | vertical | hi-res; MACHINE_IMPERFECT_SOUND, "crappy sound" |
| tomagic | Tom Tom Magic | 1997 | Hobbitron T.K.Trading | — | `tomagic` | nmk16_tomagic_state | horizontal | Resolution class **TBD** — distinct state class, not a bootleg of an nmk16 game, needs dedicated read of its `MACHINE_CONFIG` |

## Family F — Comad OKI-only hacks (no FM chip), hi-res

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| ssmissin | S.S. Mission | 1991 | Comad | — | `ssmissin` | nmk16_state | vertical | Hack of Thunder Dragon 2 board |
| airattck | Air Attack (set 1) | 1996 | Comad | — | `ssmissin` | nmk16_state | vertical | |
| airattcka | Air Attack (set 2) | 1996 | Comad | airattck | `ssmissin` | nmk16_state | vertical | |

## Family G — early-board / real-silicon-MCU bootlegs, low-res

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| tharrier | Task Force Harrier | 1989 | UPL | — | `tharrier` | nmk16_state | vertical | Earliest board, predates NMK004; MACHINE_NO_COCKTAIL |
| tharrieru | Task Force Harrier (US) | 1989 | UPL (American Sammy) | tharrier | `tharrier` | nmk16_state | vertical | MACHINE_NO_COCKTAIL |
| tharrierb | Task Force Harrier (Lettering bootleg) | 1989 | bootleg (Lettering) | tharrier | `tharrierb` | **tharrierb_state** | vertical | Real M68705R3 MCU protection (simulated in MAME) |
| vandykeb | Vandyke (bootleg with PIC16c57) | 1990 | bootleg | vandyke | `vandykeb` | nmk16_state | vertical | MACHINE_NO_SOUND; PIC protection patched/disabled in MAME |
| manybloc | Many Block | 1991 | Bee-Oh | — | `manybloc` | nmk16_state | vertical | **Reclassified from family B during Tier 2 bring-up** (this survey's own original "NMK004" listing was wrong — confirmed by reading `nmk16.cpp:5884` directly: real Z80 audio CPU + YM2203 via `tharrier_sound_map`, `gfx_tharrier` GFXDECODE, `set_periodic_int`+scanline-callback IRQs, 256x256 screen — no NMK004 device instantiated at all). MACHINE_IMPERFECT_SOUND |

## Family H — Afega derivative hardware (own screen/scroll scheme)

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| stagger1 | Stagger I (Japan) | 1998 | Afega | — | `stagger1` | afega_state | vertical | Flip-screen doesn't work on sprites |
| redhawk | Red Hawk (USA/Canada/S.America) | 1997 | Afega (New Vision Ent.) | stagger1 | `stagger1` | afega_state | vertical | |
| redhawki | Red Hawk (horizontal, Italy) | 1997 | Afega (Hae Dong Corp) | stagger1 | `redhawki` | afega_state | horizontal | "bootleg? strange scroll regs"; distinct machine-config |
| redhawks | Red Hawk (horizontal, Spain, set 1) | 1997 | Afega (Hae Dong Corp) | stagger1 | `redhawki` | afega_state | horizontal | |
| redhawksa | Red Hawk (horizontal, Spain, set 2) | 1997 | Afega (Hae Dong Corp) | stagger1 | `redhawki` | afega_state | horizontal | |
| redhawkg | Red Hawk (horizontal, Greece) | 1997 | Afega | stagger1 | `redhawki` | afega_state | horizontal | |
| redhawke | Red Hawk (Excellent Co.) | 1997 | Afega (Excellent Co.) | stagger1 | `stagger1` | afega_state | vertical | Different logo/font revision |
| redhawkk | Red Hawk (Korea) | 1997 | Afega | stagger1 | `stagger1` | afega_state | vertical | |
| redhawkc | Red Hawk (China & Hong Kong) | 1997 | Afega (Zhuojia Co.) | stagger1 | `stagger1` | afega_state | vertical | |
| redhawkb | Red Hawk (horizontal, bootleg) | 1997 | bootleg (Vince) | stagger1 | `redhawkb` | afega_state | horizontal | Distinct machine-config |
| grdnstrm | Guardian Storm (horizontal, unencrypted) | 1998 | Afega (Apples Industries) | — | `grdnstrm` | afega_state | horizontal (Y-flip) | 8bpp tilemap variant |
| grdnstrmv | Guardian Storm (vertical) | 1998 | Afega (Apples Industries) | grdnstrm | `grdnstrmk` | afega_state | vertical | Distinct machine-config from grdnstrm |
| grdnstrmj | Sen Jing - Guardian Storm (Japan) | 1998 | Afega | grdnstrm | `grdnstrmk` | afega_state | vertical | |
| grdnstrmk | Jeon Sin - Guardian Storm (Korea) | 1998 | Afega | grdnstrm | `grdnstrmk` | afega_state | vertical | |
| redfoxwp2 | Hong Hu Zhanji II (China, set 1) | 1998 | Afega | grdnstrm | `grdnstrmk` | afega_state | vertical | |
| redfoxwp2a | Hong Hu Zhanji II (China, set 2) | 1998 | Afega | grdnstrm | `grdnstrmk` | afega_state | vertical | |
| grdnstrmg | Guardian Storm (Germany) | 1998 | Afega | grdnstrm | `grdnstrmk` | afega_state | vertical | |
| grdnstrmau | Guardian Storm (horizontal, Australia) | 1998 | Afega | grdnstrm | `grdnstrm` | afega_state | horizontal (Y-flip) | |
| bubl2000 | Bubble 2000 | 1998 | Afega (Tuning license) | — | `popspops` | afega_state | horizontal | Demo Sound DSW; "tuning board" |
| bubl2000a | Bubble 2000 V1.2 | 1998 | Afega (Tuning license) | bubl2000 | `popspops` | afega_state | horizontal | No Demo Sounds |
| hotbubl | Hot Bubble (Korea, adult pictures) | 1998 | Afega (Pandora license) | bubl2000 | `popspops` | afega_state | horizontal | "afega board" |
| hotbubla | Hot Bubble (Korea) | 1998 | Afega (Pandora license) | bubl2000 | `popspops` | afega_state | horizontal | |
| popspops | Pop's Pop's | 1999 | Afega | — | `popspops` | afega_state | horizontal | |
| mangchi | Mang-Chi | 2000 | Afega | — | `popspops` | afega_state | horizontal | |
| spec2k | Spectrum 2000 (vertical, Korea) | 2000 | Yona Tech | — | `spec2k` | afega_state | vertical | MACHINE_IMPERFECT_GRAPHICS |
| spec2kh | Spectrum 2000 (horizontal, buggy, Europe) | 2000 | Yona Tech | spec2k | `spec2k` | afega_state | horizontal (Y-flip) | "odd bugs even on real hardware" |
| firehawk | Fire Hawk (World/China, horizontal) | 2001 | ESD | spec2k | `firehawk` | afega_state | horizontal (Y-flip) | 2×OKI direct, no NMK004; distinct machine-config |
| firehawkv | Fire Hawk (switchable orientation) | 2001 | ESD | spec2k | `firehawk` | afega_state | horizontal (Y-flip) | **MACHINE_NOT_WORKING** — incomplete dump, vertical-mode GFX not dumped |

**Family H hardware split — major correction to the plan**: the plan assumed "the one or two Afega `.rbf` variants." The source shows **at least 8 distinct machine-config functions** in this family alone: `stagger1`, `redhawki`, `redhawkb`, `grdnstrm`, `grdnstrmk`, `popspops`, `spec2k`, `firehawk`. Family H will need on the order of 6–8 `.rbf` builds, not 1–2 — the largest revision to the `.rbf` count estimate in the whole plan.

## Family I — Afega hacks of Mustang, low-res

| Short name | Description | Year | Manufacturer | Parent | Machine-config | State class | Orientation | Notes |
|---|---|---|---|---|---|---|---|---|
| twinactn | Twin Action | 1995 | Afega | — | `twinactn` | nmk16_state | horizontal | "hacked from USSAF Mustang" |
| dolmen | Dolmen | 1995 | Afega | — | `twinactn` | nmk16_state | horizontal | |
| dolmenk | Goindol (Afega) | 1995 | Afega | dolmen | `twinactn` | nmk16_state | horizontal | |
| puzlwrld | Puzzle World | 1996 | Afega | — | `twinactn` | nmk16_state | horizontal | parent field lists `dolmen` |

## Summary — games per family

| Family | Count |
|---|---|
| A | 3 |
| B | 17 |
| C | 20 |
| D | 12 |
| E | 12 |
| F | 3 |
| G | 4 |
| H | 27 |
| I | 4 |
| **Total** | **102*** |

\* Sums to 102 against the true total of 101 — `puzlwrld`'s parent field points to `dolmen` rather than `twinactn` in the source (likely a MAME data quirk, not a hardware difference) but it's counted once under family I; recheck this arithmetic against `/tmp/nmkwork/games.txt`-style raw grep during Tier 0 RTL work — not a blocker for this inventory.

## Revised `.rbf` build estimate

Prior plan estimate: ~14–18 `.rbf` builds. Revised based on actually distinct `MACHINE_CONFIG` functions found per family:

- Family A: 1 build (all three share `cactus`/`bjtwin` config, effectively identical minus GFX bank note)
- Family B: **3 builds** (standard 1-layer / bioship 3-layer / strahl 2-layer) — matches plan's flagged item
- Family C: **4-5 builds** (macross2/tdragon2/raphero share one; tdragon3h likely needs its own due to missing-YM2203-IRQ simulation; powerins official builds share one; powerinsa/powerinsb are bootleg variants with their own configs — may share or may not, TBD; powerinsc recommend excluding as MAME itself doesn't fully emulate it)
- Family D: **3 builds** (tdragon1/hachamf low-res / macross+gunnail page-mapped / bjtwin+sabotenb COL-scan)
- Family E: **4-5 builds** (mustangb+mustangb2 share one, mustangb3 separate; acrobatmbl/hachamfb2/tdragonb/tdragonb3/strahljbl/macrossbl/gunnailb likely share a common "Raiden-sound-bolted-onto-parent-board" template but each has a distinct machine-config function so needs verification; tdragonb2 likely needs its own due to the noted IRQ/timing bug; tomagic is definitely separate)
- Family F: 1 build
- Family G: **2 builds** (tharrier/tharrieru vs tharrierb's M68705 protection; vandykeb likely a 3rd)
- Family H: **6-8 builds** (see correction above)
- Family I: 1 build

**Revised total estimate: ~26–30 `.rbf` builds**, roughly double the plan's original ~14–18 estimate — driven mainly by family H's actual config-function count and the several bootleg families (C, E) having more per-variant machine-config functions than initially assumed. This should be corrected in `docs/PLAN.md`.
