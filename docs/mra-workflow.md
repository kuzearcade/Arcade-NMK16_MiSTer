# .mra authoring workflow

## Format (verified against the MiSTer-devel wiki)

Each `.mra` is an XML file wrapped in `<misterromdescription>`. Fields relevant to this project:

- `<name>`, `<setname>`, `<year>`, `<manufacturer>`, `<category>` — taken directly from each game's `GAME()` macro in `nmk16.cpp`.
- `<rbf>` — the core filename (no path/extension) for the **hardware family** this game belongs to (see `docs/PLAN.md` families A–I) — this is the field that implements "one `.rbf` per family, one `.mra` per game."
- `<rom index="0" zip="..." md5="...">` with nested `<part crc="..." name="..."/>` (and `<interleave output="N">`/`<patch offset="...">` where a game's ROMs must be byte-interleaved or patched to match what the core's memory map expects) — this must mirror each game's `ROM_START(...)` block in `nmk16.cpp` byte-for-byte: same regions, same load order, same interleave.
- `<switches default="...">` with `<dip bits="..." name="..." ids="..." values="..."/>` — mirrors each game's `PORT_DIPSWITCH` definitions (a straightforward but tedious mechanical translation per game).
- `<buttons names="..." default="..."/>` — mirrors each game's `PORT_BUTTON` inputs.
- `<nvram index="..." size="..."/>` — not needed for this driver (confirmed in Milestone research: no NVRAM/backup RAM in nmk16.cpp).

Minimal worked template kept at `tools/mra-template.xml` (see below).

## Decision: hand-authored per-family template + generation script

Per `docs/PLAN.md`, given MAME's `ROM_START` regions map fairly mechanically to `romstruct`/`<rom>` entries:

1. For each hardware family (A–I), hand-author **one worked example `.mra`** (the family's parent/flagship game) by directly transcribing its `ROM_START` block, DIP switches, and inputs from `nmk16.cpp`. This is the accuracy checkpoint — it's checked by hand against the source once per family, not once per romset.
2. Write a small Python generator (`tools/gen_mra.py`, not yet implemented) that parses the family's `ROM_START` blocks + `PORT_DIPSWITCH`/`PORT_BUTTON` definitions directly out of `nmk16.cpp` for every clone/bootleg sharing that family's `.rbf`, and emits the remaining `.mra` files from the hand-verified template — substituting ROM file names/CRCs/regions and DIP tables per romset. This keeps the 85-file volume from being 85 independent manual-transcription tasks while keeping a human-verified reference per family.
3. Every generated `.mra` still gets spot-checked against MAME's own `-listxml` output for that romset (`mame nmk16 -listxml <setname>`, once a MAME binary is available) as a mechanical cross-check on ROM region sizes/CRCs.

## Reference: full example .mra (Donkey Kong, from the MiSTer-devel wiki)

```xml
<misterromdescription>
  <name>Donkey Kong (US set 1)</name>
  <mratimestamp>201911270000</mratimestamp>
  <mameversion>0216</mameversion>
  <setname>dkong</setname>
  <year>1981</year>
  <manufacturer>Nintendo of America</manufacturer>
  <category>Maze / Monkeys</category>
  <rbf>DonkeyKong</rbf>
  <switches default="FF,FF,C9">
    <dip bits="15" name="Cabinet" ids="Cocktail,Upright"/>
  </switches>
  <buttons names="Jump,Start 1P,Start 2P,Coin" default="A,Start,Select,R"/>
  <rom index="1">
    <part>0A</part>
  </rom>
  <rom index="0" zip="dkong.zip" md5="05fb1dd1ce6a786c538275d5776b1db1">
    <part crc="ba70b88b" name="c_5et_g.bin"/>
    <part crc="d6412358" name="c-2j.bpr"/>
  </rom>
</misterromdescription>
```
