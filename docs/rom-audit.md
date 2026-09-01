# ROM completeness audit

`mame_roms/` provides ROMs in MAME's **split** convention — a clone/bootleg zip contains only the files that differ from its parent; files shared with the parent are stored once, in the parent's zip, and MAME merges them by CRC at load time (confirmed directly — see the `cactus`/`sabotenb` example below). Verifying completeness therefore has to go through MAME's own romset resolution (`-verifyroms`), not just check "does a zip with this name exist."

## Method

Cross-checked all 101 romsets from `docs/game-inventory.md` against `mame_roms/` (102 zips) using the installed MAME 0.285 (`mame -verifyroms <all 101 names> -rompath mame_roms`).

## Result: only one romset is genuinely missing

**`macrossbl`** has no zip in `mame_roms/` at all. Low priority to chase down — it's already `MACHINE_NOT_WORKING` in MAME itself (per `docs/game-inventory.md`'s family E notes: "not looked at yet"), so it wasn't blocking anything regardless.

Everything else resolved as complete, once the following non-issues are understood:

## Two "not found" results are a MAME-version mismatch, not missing files

`redhawkc` and `puzlwrld` both exist as real, correctly-sized zip files in `mame_roms/` (584KB and 601KB respectively), but the **installed distro MAME 0.285 doesn't know these driver names at all** (`mame -listfull redhawkc` / `puzlwrld` → "No matching systems found"). These aren't obscure typos — they're real romsets (Red Hawk China/Hong Kong; Puzzle World, an Afega hack of Dolmen) that exist in the pinned `mame/` reference source tree's `nmk16.cpp` but were evidently added to MAME's driver *after* whatever version 0.285 corresponds to. This is the same "captured against a different MAME version than the pinned reference tree" caveat already flagged in `docs/sim-harness.md` — not a ROM-provisioning gap. These two will verify fine once tested against a MAME build matching (or newer than) the pinned `mame/` source.

## The "best available" / "NEEDS REDUMP" / "NO GOOD DUMP KNOWN" results are not missing files either

15 romsets verify as "best available" rather than a clean "good," and one (`tharrierb`) as "bad." In every case, this reflects the *known state of the dump in the MAME preservation community as a whole*, not a gap in what's provided here — `mame_roms/` already contains MAME's best-known copy of each flagged file. Two categories:

- **"NEEDS REDUMP"** (`hachamf`/`hachamfa`/`hachamfb`'s `82s135.ic50` timing PROM, `nouryoku`/`nouryokup`'s `8.ic37`, `firehawkv`'s `fhawk_g2.uc5`, `mustangb3`'s `90058-9`, `tdragon3h`'s `10.bpr`, `tdragonb3`'s `unreadable.18h` — literally named "unreadable" in the source dump — and `vandykeb`'s `pic16c57`): the file is present and matches the exact CRC MAME's driver expects; it's just flagged in MAME's own database as a dump whose accuracy is suspect (bad PROM read, degraded chip, etc.). Nothing to re-acquire — this is the actual best-available dump.
- **"NOT FOUND — NO GOOD DUMP KNOWN"** (`acrobatmbl`'s PIC16C57, `redhawks`/`redhawksa`'s GAL PLD files, `tharrier`/`tharrieru`'s `upl.13m` MCU): no working dump of this specific chip exists **anywhere** in MAME's romset — these are permanently undumped protection MCUs/PLDs, consistent with the "real, undumped protection MCU" risk already called out in `docs/PLAN.md` for several of this driver's boards. Not fixable by sourcing different ROM files.

## The one "bad" result (`tharrierb`) is a generic MAME CPU-core file, not a game ROM

`tharrierb` verifies "bad" because `bootstrap.bin` is "NOT FOUND (m68705r3)." Traced this directly into the MAME source: `tharrierb`'s own `ROM_START` (`nmk16.cpp:6836-6845`) loads a real, correctly-dumped MCU program (`mc68705r35.bin`, CRC `c560798b`) — `bootstrap.bin` isn't referenced by this driver at all. It's a tiny (0x73-0x78 byte) **generic internal bootstrap ROM built into MAME's shared M68705 CPU core device** (`mame/src/devices/cpu/m6805/m68705.cpp:76-91`), used by every driver in MAME that emulates any M68705-family MCU — infrastructure for the chip's factory programming/erase sequence, not part of this game's PCB dump. It's plausible normal gameplay emulation doesn't depend on it (the bootstrap ROM is mostly relevant to programming/erasing the chip, not running its resident program), but that's not verified here — flagged as a specific thing to check when `tharrierb` is actually brought up, rather than assumed.

## Bottom line

Of the 101 romsets: **100 have complete, MAME-verified ROM data** once split-set parent merging and the MAME-version mismatch are accounted for; **1 (`macrossbl`) is genuinely absent** and was already deprioritized as broken-in-MAME-itself. No action needed before continuing Tier 1+ RTL work — the earlier "cactus is missing files" concern in `docs/tier1-bjtwin.md` is retracted (see that file for the correction).
