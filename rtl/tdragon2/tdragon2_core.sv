// NMK16 MiSTerFPGA project — SHARED Family C system-level integration,
// serving BOTH tdragon2 and macross2 from one core (module name kept as
// "tdragon2_core" — tdragon2 was the pilot game and this file's own
// identity predates the merge; renaming would touch a wide, working blast
// radius of Makefiles/testbenches/Quartus sources for no functional gain).
// Game selection is a genuine RUNTIME input (game_macross2 below), not a
// synthesis-time parameter — see docs/hw-bringup.md: this is what lets one
// Macross2.rbf boot either game, selected by a hidden status[] bit each
// game's own .mra sets on load (see Macross2.sv's own header).
//
// This merge exists because `tdragon2()` and `macross2()`'s own machine
// configs (nmk16.cpp:5490-5533 / 5444-5488) are BYTE-FOR-BYTE IDENTICAL
// (same 68000/Z80 clocks, same macross2_sound_map/io_map — literally the
// same functions — same gfx_macross2/VIDEO_START_OVERRIDE(macross2), same
// NMK112/dual-OKI setup) except for exactly ONE genuine runtime behavior
// difference (mainram address-line swap, below) plus two things that
// turned out NOT to need per-game switching at all once checked directly
// against the reference rather than assumed:
//
//   - V-PROM content: tdragon2's own "10.bpr" and macross2's own
//     "mcrs2bpr.10" have IDENTICAL CRC32/SHA1 (e6ead349 /
//     6d81b1c0233580aa48f9718bade42d640e5ef3dd) — same physical PROM,
//     same board family, one shared VTIMING_FILE genuinely suffices for
//     both games (not just "close enough" — byte-identical).
//   - NMK112 ROM1_BYTES (oki2 chip sizing, rtl/nmk112/nmk112.sv): the
//     ONLY effect of this parameter is masking WRITTEN bank-select page
//     indices (`data & MASK1`, MASK1 = ROM1_BYTES/65536 - 1). tdragon2's
//     own oki2 is 0x200000 (MASK1=0x1F, 32 pages); macross2's own oki2 is
//     HALF that, 0x100000 (16 pages) — but using tdragon2's wider mask
//     for macross2 too is provably harmless: macross2's own game code
//     never writes a bank index beyond its own real chip's 16-page range
//     (there is nothing on that PCB to select), so the extra mask
//     headroom is simply never exercised. Kept at tdragon2's fixed
//     (wider) sizing unconditionally below — no runtime toggle needed.
//
// Difference (the one genuine runtime behavior split) — mainram
// address-line swap (nmk16.cpp:280-288,1100-1104): `tdragon2_map` is
// `macross2_map(map)` plus one override,
// `map(0x1f0000,0x1fffff).rw(mainram_swapped_r,mainram_swapped_w)`, which
// applies `bitswap<16>(offset,15,14,13,12,11,7,9,8,10,6,5,4,3,2,1,0)` to the
// WORD OFFSET before indexing m_mainram — verified independently (not
// trusted from the bit-list alone) that this swaps ONLY address bits 7 and
// 10 with each other; every other bit passes through unchanged. A real PCB
// address-line miswiring, faithfully replicated — NOT a data-bit scramble.
// macross2_map itself has no such override at all. Selected below by the
// game_macross2 runtime input (mainram_addr_cpu computation) — a single
// small mux, negligible LE cost, no separate core copy needed.
//
// CRITICAL: this swap applies ONLY to the 68000 CPU-facing bus handler
// (mainram_swapped_r/w, both directions) — it does NOT apply to MAME's own
// sprite-DMA snapshot mechanism. Confirmed directly: `sprite_dma()`
// (nmk16.cpp:4518-4524, the SAME shared function every game in this driver
// uses, including tdragon2 via nmk_irq's own sprite_dma_cb) does a raw C++
// `memcpy(m_spriteram_old.get(), m_mainram + m_sprdma_base/2, 0x1000)` —
// this bypasses MAME's own address_map dispatch entirely (it's a direct
// pointer read of the underlying array member, not a call through the
// swapped handler), so it reads the SAME raw, unswapped physical layout the
// CPU's own swapped writes actually land in. video_macross2.sv's own
// mainram_addr/mainram_data tap (used for exactly this sprite-snapshot
// mechanism, see that file's own header/body) therefore must stay
// UNSWAPPED for tdragon2, reading the SAME raw `mainram` array the
// CPU-facing accessor also indexes into — only the CPU-facing address
// computation below is swapped, and only for tdragon2 (game_macross2=0).
// For macross2 (game_macross2=1) there is no swap on EITHER path at all —
// both taps already compute the same way, so this asymmetry is naturally
// game_macross2-gated purely by the mainram_addr_cpu mux below; the video
// tap itself needs no separate per-game logic.
//
// Everything else — clock derivation, address decode, I/O register
// wiring, Z80 sound path, video pipeline instantiation, real V-PROM
// nmk_irq wiring, all HW_ROMS=1 SDRAM infrastructure — serves both games
// identically, unconditional on game_macross2.
module tdragon2_core #(
	parameter ROM_FILE       = "",
	parameter AUDIOCPU_FILE  = "",
	parameter OKI1_ROM_FILE  = "",
	parameter OKI2_ROM_FILE  = "",
	parameter VTIMING_FILE   = "",
	parameter FGTILE_FILE    = "",
	parameter BGTILE_FILE    = "",
	parameter SPRITES_FILE   = "",
	// DIAGNOSTIC ONLY — see ioctl_bucket_fail_o's own comment further
	// down. A 128-entry, one-16-bit-word-per-line $readmemh table of
	// known-good per-4096-byte-bucket checksums over the maincpu ROM's
	// own real content, computed host-side (not ROM-dump-derived, so
	// unlike every other *_FILE parameter above this one is safe to
	// commit directly — see tools/ for the generating script if it's
	// ever regenerated). Empty string (default): the bucket-fail always
	// block runs and produces an all-zero/meaningless ioctl_bucket_fail_o
	// (harmless, unread) exactly like every existing sim testbench
	// leaving VTIMING_FILE-style parameters at their own empty default.
	parameter IOCTL_BUCKET_REF_FILE = "",
	// DIAGNOSTIC ONLY — see rom_fetch_bucket_fail_o's own comment further
	// down. Two companion $readmemh tables (both NOT ROM-dump-derived,
	// safe to commit): ROM_FETCH_BUCKET_REF_FILE is 128 lines of the
	// known-good per-bucket rotate-XOR state a REFERENCE (sim) run's own
	// rom_fetch_bucket_state_o produced; ROM_FETCH_BUCKET_TOUCHED_FILE is
	// 128 lines of 0/1 marking which of those buckets that reference run
	// actually visited at all (see the comparison logic's own comment for
	// why this second table is needed). Empty string (default, every
	// existing sim testbench): skips loading, matching every other
	// diagnostic *_FILE parameter's own default-off behavior.
	parameter ROM_FETCH_BUCKET_REF_FILE     = "",
	parameter ROM_FETCH_BUCKET_TOUCHED_FILE = "",
	// DIAGNOSTIC ONLY — a zoomed-in companion to the pair above, same
	// purpose/mechanism, scoped to ONLY word addresses [0,2048) (i.e.
	// ROM_FETCH_BUCKET_REF_FILE's own bucket 0 — the one that showed a
	// real mismatch, see rom_fetch_fine_fail_o's own comment further
	// down) at 16-words/bucket instead of 2048-words/bucket — 128x finer,
	// to see whether the CPU's own reset vector (bytes 0-7) specifically,
	// or only later boot code within that same 4KB range, is corrupted.
	parameter ROM_FETCH_FINE_REF_FILE     = "",
	parameter ROM_FETCH_FINE_TOUCHED_FILE = "",
	// DIAGNOSTIC ONLY — TRUE per-word granularity, one more zoom level
	// past ROM_FETCH_FINE_*_FILE above: scoped to word addresses [0,16)
	// (fine bucket 0's own range, the only one that showed any real
	// traffic at all — see rom_fetch_word_fail_o's own comment). At
	// 1-word/bucket a rotate-XOR "checksum" over however many fetches
	// land in a bucket started from 0 is mathematically just that word's
	// own raw value when only ONE distinct address was ever fetched from
	// it, so this doubles as a direct per-word value readout, not just
	// pass/fail, when coverage turns out to be that sparse.
	parameter ROM_FETCH_WORD_REF_FILE     = "",
	parameter ROM_FETCH_WORD_TOUCHED_FILE = "",
	// See docs/hw-bringup.md. HW_ROMS=0 (default, every existing sim
	// testbench): behavior is completely unchanged from before this
	// parameter existed — $readmemh-loaded 0-latency arrays. HW_ROMS=1
	// (the real hardware top-level only): every ROM region instead reads
	// through rom_cache1/sdram_arb over the real rtl/sdram.sv controller,
	// loaded via ioctl_download rather than $readmemh.
	parameter HW_ROMS        = 0,
	// DIAGNOSTIC passthrough to video_macross2.sv — see its own comment.
	parameter DBG_MISS_PAINT = 0,
	// DIAGNOSTIC: paint four 8x8 live status blocks in the top-left corner
	// (visible in the MiSTer's native screenshots): OKI0 cache stall >1ms,
	// OKI1 cache stall >1ms, Z80 no opcode fetch for >10ms, Z80 held in
	// its ROM wait-state for >10ms. Green = condition false.
	parameter DBG_SND_PAINT  = 0,
	// HW_ROMS=0 sim array sizes only (video_macross2.sv): tdragon2/
	// macross2 4 MB sprites / 2 MB BG; a powerins sim passes 8 MB / 0x280000.
	parameter integer SPRITES_BYTES = 4194304,
	parameter integer BGTILE_BYTES  = 2097152
) (
	input clk_sys,        // 40 MHz (68000 bus clk_sys/4=10MHz; pixel/raster clk_sys/5=8MHz)
	input reset,            // async, active high

	// Runtime game select — 0=tdragon2, 1=macross2 (see this file's own
	// header). Every existing sim testbench that doesn't drive this port
	// leaves it floating at 0 (tdragon2 behavior), byte-for-byte
	// unchanged from before this port existed.
	input game_macross2,
	// Runtime game select, 1 = Power Instinct (powerins, 2026-09-11):
	// 12 MHz 68000 / 6 MHz Z80, powerins_map (palette 2048 entries at
	// 0x120000, bgvram 8192 words at 0x140000, mainram at 0x180000, no
	// soundlatch2 and no Z80 reset register), powerins_sound_map (flat
	// 48 KB ROM, soundlatch at E000, no banking), its own .mra SDRAM
	// layout (BASE_WORD_* below), its own V-PROM (nmk_irq table 1) and
	// video_macross2.sv's game_powerins mode. Never both selects at once.
	input game_powerins,

	// ------------------------------------------------------------------
	// Hardware-mode-only ports (HW_ROMS=1). Unused/unconnected at
	// HW_ROMS=0 — every existing sim testbench instantiates this module
	// without them, which Verilator/Quartus both accept (floating
	// inputs default to 0, unconnected outputs are simply unread).
	// ------------------------------------------------------------------
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0]  ioctl_addr,
	input      [7:0]  ioctl_dout,
	// ioctl_index: hps_io's own menu/file index for the CURRENT ioctl
	// transfer session. The MiSTer .mra loader sends MORE than one
	// transfer per game load — the <rom index="0"> data, then the
	// <switches> DIP block (index 254 by MiSTer convention) as a
	// SEPARATE session — and hps_io.sv resets ioctl_addr to 0 at the
	// start of EVERY session. Without gating on this, the DIP bytes land
	// in SDRAM at word address 0..N — exactly the 68000's own reset
	// vector — AFTER the ROM was correctly written there. Root cause of
	// this project's real-hardware "reset vector reads back mostly-zero
	// / wrong, write path verified clean" black-screen symptom: see
	// docs/hw-bringup.md. Sim testbenches stream only the ROM (one
	// session) and never reproduce it — tie to 16'd0 there.
	input     [15:0]  ioctl_index,
	// Real MiSTer hps_io.sv already has an ioctl_wait INPUT specifically
	// for this: each SDRAM write takes several clk_sys cycles to
	// complete, far more than one ioctl_wr pulse's own spacing, so the
	// downloader must be held off between bytes or most writes are
	// silently dropped (sdram_req.sv correctly ignores a new request
	// while the previous one is still in flight). This is not just a
	// testbench convenience — it's the real, required backpressure path.
	output            ioctl_wait,

	// SDRAM port 0: ioctl_download writes (whole address space) muxed
	// with maincpu program-ROM reads — mutually exclusive in time (the
	// core is held in reset for the whole download), so a plain mux on
	// ioctl_download, no arbitration needed.
	output     [24:1] sd0_addr,
	output            sd0_wrl,
	output            sd0_wrh,
	output     [15:0] sd0_din,
	input      [15:0] sd0_dout,
	input      [31:0] sd0_dout_pair, // see rtl/sdram.sv's doutN_pair
	output            sd0_req,
	input             sd0_ack,

	// SDRAM port 1: Z80 audiocpu program-ROM reads + OKI0/OKI1 sample
	// reads, 3-way arbitrated internally (all low-bandwidth).
	output     [24:1] sd1_addr,
	output            sd1_req,
	input      [15:0] sd1_dout,
	input      [31:0] sd1_dout_pair,
	input             sd1_ack,

	// SDRAM port 2: passed straight through to video_macross2.sv's own
	// HW_ROMS port A — the BG-tile prefetch stream alone.
	output     [24:1] sd2_addr,
	output            sd2_wrl,
	output            sd2_wrh,
	output     [15:0] sd2_din,
	input      [15:0] sd2_dout,
	input      [31:0] sd2_dout_pair,
	output            sd2_req,
	input             sd2_ack,

	// SDRAM port 3: passed straight through to video_macross2.sv's own
	// HW_ROMS port B — TX-tile prefetch + sprite fetch, 2-way arbitrated
	// there (TX first). Both real-time tile streams thus fetch on
	// separate physical ports, in parallel — see docs/hw-bringup.md.
	output     [24:1] sd3_addr,
	output            sd3_req,
	input      [15:0] sd3_dout,
	input      [31:0] sd3_dout_pair,
	input             sd3_ack,

	// debug/trace outputs for the Verilator testbench
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output [15:0] dbg_z80_pc,
	output        dbg_z80_m1_n,
	output        dbg_z80_mreq_n,
	output        dbg_z80_iorq_n,
	output        dbg_z80_int_n,
	output        dbg_z80_reset_n,
	output        dbg_z80_cen,

	output        dbg_ym_we,
	// per-source audio taps (sim level checks against MAME's routes)
	output signed [15:0] dbg_fm_snd,
	output        [9:0]  dbg_psg_snd,
	output signed [13:0] dbg_oki0_snd,
	output signed [13:0] dbg_oki1_snd,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_irq_n,

	output        dbg_oki0_we,
	output        dbg_oki1_we,
	output  [7:0] dbg_oki0_chip_dout,
	output  [7:0] dbg_oki1_chip_dout,
	// Simulation-only (Verilator) OKI sample-fetch audit — see g_oki_hw.
	output [31:0] dbg_oki0_adpcm_total,
	output [31:0] dbg_oki0_adpcm_unserved,
	output [31:0] dbg_oki1_adpcm_total,
	output [31:0] dbg_oki1_adpcm_unserved,
	output [31:0] dbg_oki_cen_total,     // oki_cen pulses
	output [31:0] dbg_oki0_stall_cen,    // of which withheld from chip 0 by its cache stall
	output [31:0] dbg_oki1_stall_cen,

	// pixel readback for the testbench (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [14:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done,

	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	// Real raster timing, for the hardware top-level's own video sync
	// generation — video_timing.sv lives inside this module (shared
	// with the CPU interrupt generator below), so this is the only way
	// a real top-level can derive HSync/VSync from the same counters
	// nmk_irq.sv itself uses. Unused by every existing sim testbench.
	output        ce_pix_o,
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,
	output        hblank_o,
	output        vblank_o,

	// Real inputs (HW_ROMS=1 top-level only — see the HW_ROMS-gated mux
	// below, which falls back to the exact same fixed 0xFFFF "idle"
	// constant every existing sim testbench already implicitly relies on
	// at HW_ROMS=0, so leaving these unconnected there is exactly
	// byte-for-byte unchanged; Verilator doesn't accept ANSI default
	// values on plain `input` ports in this module's own port-list
	// style, hence the explicit generate-gated fallback instead of a
	// port default). IN0 (nmk16.cpp tdragon2/macross2 INPUT_PORTS):
	// coin/start/service, active low, low byte only. IN1: 2-player
	// 8-way joystick + 2 buttons each, active low, full word.
	input  [15:0] in0_i,
	input  [15:0] in1_i,
	input  [15:0] dsw1_i,
	input  [15:0] dsw2_i,

	// HW_ROMS=1 real hardware top only: hold por_rst's own countdown at
	// 0 while this is asserted (Macross2.sv drives it with ~pll_locked
	// — see por_rst's own comment below for why). Every existing sim
	// testbench leaves this floating; Verilator/Quartus both default an
	// unconnected input to 0, which is "no extra hold" — por_rst's own
	// countdown then behaves exactly as it did before this port existed,
	// so this is a byte-for-byte no-op everywhere except Macross2.sv.
	input extra_por_hold,

	// DIAGNOSTIC ONLY — see rom_csum's own comment further down. Real
	// hardware top only; every existing sim testbench leaves these
	// unread.
	output [15:0] rom_csum_o,
	output [15:0] rom_csum_count_o,
	output        rom_csum_done_o,

	// DIAGNOSTIC ONLY — see rom_fetch_csum's own comment further down.
	// Same real-hardware-top-only / unread-elsewhere status as rom_csum_o
	// above. HW_ROMS=0 always outputs 0/0/0 (there is no cache-fetch
	// concept in the $readmemh sim path) — meaningful only when compared
	// between an HW_ROMS=1 Verilator sim reference run and real hardware,
	// same as rom_csum_o.
	output [15:0] rom_fetch_csum_o,
	output [15:0] rom_fetch_csum_count_o,
	output        rom_fetch_csum_done_o,

	// DIAGNOSTIC ONLY — see ioctl_csum's own comment further down. Same
	// real-hardware-top-only / unread-elsewhere status as rom_csum_o and
	// rom_fetch_csum_o above. Runs over the full 524288-byte maincpu ROM
	// region, so the count port is wide enough to hold that full range.
	output [15:0] ioctl_csum_o,
	output [19:0] ioctl_csum_count_o,
	output        ioctl_csum_done_o,

	// DIAGNOSTIC ONLY — see this port's own comment further down (next
	// to where it's driven). Real hardware top only; every existing sim
	// testbench leaves this unread. Bit i = 1 iff bucket i's own live
	// checksum (over ioctl_download bytes [i*4096, i*4096+4096)) did NOT
	// match IOCTL_BUCKET_REF_FILE's own entry i.
	output [0:127] ioctl_bucket_fail_o,

	// DIAGNOSTIC ONLY — see rom_fetch_bucket_fail_o's own comment further
	// down, next to where these are driven, for the full derivation.
	// dbg_bucket_sel_i/dbg_bucket_state_o/dbg_bucket_touched_o are a
	// small combinational read-mux (not a wide flat bus, to sidestep any
	// question of how a >64-bit port's bit layout maps into a Verilator
	// testbench's own C++ struct) a sim testbench can step through
	// 0..127 to read out every bucket's raw accumulator, ONCE, to
	// generate ROM_FETCH_BUCKET_REF_FILE/ROM_FETCH_BUCKET_TOUCHED_FILE's
	// own content; unread on real hardware (tied to a fixed 0 — real
	// hardware instead uses the loaded reference to compute
	// rom_fetch_bucket_fail_o itself, entirely on-chip).
	// rom_fetch_bucket_sim_touched_o echoes back
	// ROM_FETCH_BUCKET_TOUCHED_FILE's own loaded content, so a
	// real-hardware top can distinguish "never validated against sim at
	// all" from "checked, and matches/mismatches".
	input  [6:0]   dbg_bucket_sel_i,
	output [15:0]  dbg_bucket_state_o,
	output         dbg_bucket_touched_o,
	// rom_fetch_bucket_touched_o (unlike the narrow mux above): this
	// project's real hardware top itself, not a sim testbench, is the
	// reader — Macross2.sv's own overlay display needs every bucket's
	// live touched status at once (no C++/Verilator interop involved, so
	// no need for the narrow-mux workaround here).
	output [0:127] rom_fetch_bucket_touched_o,
	output [0:127] rom_fetch_bucket_sim_touched_o,
	output [0:127] rom_fetch_bucket_fail_o,

	// DIAGNOSTIC ONLY — see rom_fetch_fine_fail_o's own comment further
	// down for the full derivation. Shares dbg_bucket_sel_i above (both
	// are 128-entry tables) for the same sim-capture-only reason.
	output [15:0]  dbg_fine_state_o,
	output         dbg_fine_touched_o,
	output [0:127] rom_fetch_fine_touched_o,
	output [0:127] rom_fetch_fine_sim_touched_o,
	output [0:127] rom_fetch_fine_fail_o,

	// DIAGNOSTIC ONLY — see rom_fetch_word_fail_o's own comment further
	// down. Shares dbg_bucket_sel_i[3:0] for the sim-capture-only mux
	// (only entries 0-15 are meaningful for this 16-word-wide tier).
	output [15:0] dbg_word_state_o,
	output        dbg_word_touched_o,
	output [0:15] rom_fetch_word_touched_o,
	output [0:15] rom_fetch_word_sim_touched_o,
	output [0:15] rom_fetch_word_fail_o,

	// DIAGNOSTIC ONLY: unlike every other diagnostic port above (which
	// only report PASS/FAIL against a reference), these four expose the
	// ACTUAL raw value real hardware's own fetch_word_state_r[0..3]
	// holds — the reset vector's own 4 words (see rom_fetch_word_fail_o
	// above: word0/word1=initial SP, word2/word3=initial PC) — directly,
	// tied straight to those 4 specific array entries (no mux needed,
	// unlike dbg_word_state_o's own general-purpose sim-capture mux,
	// since these particular 4 indices are already known to matter).
	// Added after this project's own real-hardware bring-up work found
	// 3 of these 4 words mismatch a known-good reference (see
	// docs/hw-bringup.md) — the WRONG value itself, not just "it's
	// wrong", is the next diagnostic step: a recognizable pattern (stale
	// ioctl_download data, a shifted/aliased address, all-0s/all-1s)
	// would point directly at which real mechanism (rom_cache1,
	// sdram_arb, sdram_req) is at fault.
	output [15:0] rom_word0_raw_o,
	output [15:0] rom_word1_raw_o,
	output [15:0] rom_word2_raw_o,
	output [15:0] rom_word3_raw_o,

	// DIAGNOSTIC ONLY: see fetch_word_was_write_r's own comment further
	// down (next to where these are captured) for the full derivation —
	// tests whether each of the first 4 reset-vector words' own
	// cache_valid pulse actually belonged to a WRITE (the tail of
	// ioctl_download's own last byte racing against rom_cache1's first
	// real read on the same shared SDRAM port), not the genuine read it
	// was taken to be, and what address that transaction actually was
	// for either way.
	output        rom_word0_was_write_o,
	output        rom_word1_was_write_o,
	output        rom_word2_was_write_o,
	output        rom_word3_was_write_o,
	output [24:1] rom_word0_race_addr_o,
	output [24:1] rom_word1_race_addr_o,
	output [24:1] rom_word2_race_addr_o,
	output [24:1] rom_word3_race_addr_o,

	// DIAGNOSTIC ONLY: 1 iff that word's own race_addr above (the
	// LATCHED address of whichever sd0_inst transaction just completed)
	// equals the address rom_cache1 itself should have been fetching
	// (0/1/2/3 for these 4 slots) — a genuine read that was NOT a stale
	// write (rom_wordN_was_write_o=0) could still be wrong if it was a
	// genuine read of the WRONG address (a different bug class: e.g. a
	// stale/aliased request from earlier, not this project's own
	// sdram_arb.sv since sd0_inst is a plain sdram_req here — see
	// rom_word0_was_write_o's own comment for the was_write half of
	// this same two-part check).
	output rom_word0_addr_ok_o,
	output rom_word1_addr_ok_o,
	output rom_word2_addr_ok_o,
	output rom_word3_addr_ok_o,

	// DIAGNOSTIC ONLY: real ioctl_wr pulse-to-pulse timing/gap
	// instrumentation over an ACTUAL real-hardware .mra download — tests
	// whether real hps_io/ARM-side byte-delivery PACING (as opposed to
	// write granularity or the bare dual-requester mux structure, both
	// already ruled out via SdramTest.sv's own PHASE 3/3b synthetic
	// repros run purely in-FPGA — see docs/hw-bringup.md) has real,
	// irregular gaps large enough to interact with rtl/sdram.sv's own
	// refresh timer (REFRESH_CYCLES=240 clk_sys cycles @ 40MHz = 6us).
	// ioctl_wr_max_gap_o: the single largest clk_sys-cycle gap between
	// two consecutive real ioctl_wr pulses seen during the whole
	// download. ioctl_wr_over_refresh_count_o: how many of those pulses
	// were preceded by a gap >= REFRESH_CYCLES (240) — i.e. how often a
	// real refresh cycle had genuine room to interpose between two
	// consecutive real download bytes.
	output [23:0] ioctl_wr_max_gap_o,
	output [23:0] ioctl_wr_over_refresh_count_o,

	// DIAGNOSTIC ONLY: proof of the multi-session ioctl clobber — see
	// the ioctl_index port comment. ioctl_session_count_o: number of
	// ioctl_download rising edges since power-on. ioctl_last_index_o:
	// ioctl_index of the most recent session. ioctl_nonrom_word0_o: the
	// 16-bit word ({byte@addr1, byte@addr0}) the most recent NON-index-0
	// session tried to write at SDRAM word 0 — i.e. exactly what would
	// have overwritten the reset vector's own first word before the
	// ioctl_rom_wr gate existed.
	output [7:0]  ioctl_session_count_o,
	output [15:0] ioctl_last_index_o,
	output [15:0] ioctl_nonrom_word0_o
);

	// ------------------------------------------------------------------
	// HW_ROMS=1 only: a power-on-only reset for the SDRAM req/arb
	// instances (sd0/sd1/oki_arb below, and video_macross2.sv's own),
	// deliberately NOT the same as the `reset` port above. `reset` stays
	// asserted for the whole ioctl_download window (correctly, to keep
	// the CPU/game logic quiescent while its ROMs load) — but the SDRAM
	// path itself must keep working THROUGH that same window to actually
	// perform the download. Tying sdram_req.sv's own reset to the game
	// `reset` would hold it permanently reset for the entire download,
	// silently dropping every single write (found exactly this way: a
	// real hardware-mode test run showed 0 bytes ever landing, traced to
	// this). Real MiSTer cores make the same distinction — the SDRAM
	// controller resets once at FPGA configuration (or PLL lock), not on
	// every user-triggered "soft" game reset.
	//
	// extra_por_hold (real hardware only — see port declaration above):
	// this countdown's own 16 clk_sys cycles (400ns at 40MHz) can easily
	// complete before a real altpll has actually locked (lock time is
	// typically tens of microseconds) — por_rst has no dependency on
	// pll_locked at all otherwise, unlike the game-level `reset` input
	// (which Macross2.sv does gate with ~pll_locked), so this countdown
	// could complete on a not-yet-stable/wrong-frequency clock right
	// after FPGA configuration, latching sd0_inst/sd1_inst/oki_arb_inst
	// into a corrupted internal state that never gets a second chance to
	// reset once clk_sys later stabilizes (nothing else ever resets
	// them again). Holding the countdown at 0 while extra_por_hold is
	// asserted defers it until the clock is genuinely trustworthy.
	reg [3:0] por_cnt = 4'd0;
	reg       por_rst = 1'b1;
	always @(posedge clk_sys) begin
		if (extra_por_hold) begin
			por_cnt <= 4'd0;
			por_rst <= 1'b1;
		end else if (por_rst) begin
			if (por_cnt == 4'd15) por_rst <= 1'b0;
			else por_cnt <= por_cnt + 4'd1;
		end
	end

	// ------------------------------------------------------------------
	// Clock enables — identical to macross2_core.sv's own (see that
	// file's own header).
	// ------------------------------------------------------------------
	// 68000: 10 MHz (clk_sys/4) for tdragon2/macross2. powerins runs it at
	// XTAL(12 MHz): a 3/10 phase accumulator (40 MHz * 3/10), "wrap fires
	// enPhi1, enPhi2 the very next cycle" as raphero_core.sv's 14 MHz —
	// enPhi1 lands at ticks 4, 7, 10 (mod 10), never closer than 3 apart.
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	reg [3:0] cpu_acc = 4'd0;
	reg       cpu_acc_phi1 = 1'b0, cpu_acc_phi2 = 1'b0, cpu_acc_half = 1'b0;
	always @(posedge clk_sys) begin
		cpu_acc_phi1 <= 1'b0;
		cpu_acc_phi2 <= 1'b0;
		if (cpu_acc + 4'd3 >= 4'd10) begin
			cpu_acc      <= cpu_acc + 4'd3 - 4'd10;
			cpu_acc_phi1 <= 1'b1;
			cpu_acc_half <= 1'b1;
		end else begin
			cpu_acc <= cpu_acc + 4'd3;
			if (cpu_acc_half) begin
				cpu_acc_phi2 <= 1'b1;
				cpu_acc_half <= 1'b0;
			end
		end
	end
	wire enPhi1 = game_powerins ? cpu_acc_phi1 : (cpu_div == 2'd3);
	wire enPhi2 = game_powerins ? cpu_acc_phi2 : (cpu_div == 2'd1);

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// Z80: 4 MHz (clk_sys/10); powerins XTAL(12 MHz)/2 = 6 MHz via a 3/20
	// accumulator (T80s only needs a CEN pulse, not an even spacing).
	reg [3:0] z80_div = 4'd0;
	always @(posedge clk_sys) z80_div <= (z80_div == 4'd9) ? 4'd0 : z80_div + 4'd1;
	reg [4:0] z80_acc = 5'd0;
	reg       z80_acc_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (z80_acc + 5'd3 >= 5'd20) begin
			z80_acc     <= z80_acc + 5'd3 - 5'd20;
			z80_acc_cen <= 1'b1;
		end else begin
			z80_acc     <= z80_acc + 5'd3;
			z80_acc_cen <= 1'b0;
		end
	end
	wire z80_cen = game_powerins ? z80_acc_cen : (z80_div == 4'd9);

	reg [6:0] ym_cen_cnt = 7'd0;
	reg       ym_cen = 1'b0;
	always @(posedge clk_sys) begin
		if (ym_cen_cnt >= 7'd77) begin
			ym_cen_cnt <= ym_cen_cnt + 7'd3 - 7'd80;
			ym_cen <= 1'b1;
		end else begin
			ym_cen_cnt <= ym_cen_cnt + 7'd3;
			ym_cen <= 1'b0;
		end
	end

	// OKIM6295 clock enable: 4MHz = 40MHz/10. MAME clocks both OKIs at
	// XTAL(16MHz)/4 with pin 7 LOW (nmk16.cpp's macross2/tdragon2 config:
	// `OKIM6295(config, m_oki[n], XTAL(16'000'000) / 4, PIN7_LOW)`), i.e. a
	// 4MHz/165 = 24.24kHz sample rate, and jt6295's `cen` IS the chip
	// clock (its own header: "48 kHz sample output for a 1.000 MHz cen").
	// This used to be 1MHz (40MHz/40): every sample played four times too
	// slow and two octaves too low — the "muddled" drums, voices and
	// effects heard on real hardware; measured as the hardware spectrum
	// sitting ~4-6 dB below MAME's at 2-4kHz and above it below 250Hz.
	reg [3:0] oki_cen_cnt = 4'd0;
	wire      oki_cen = (oki_cen_cnt == 4'd9);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 4'd0 : oki_cen_cnt + 4'd1;

	// ------------------------------------------------------------------
	// fx68k
	// ------------------------------------------------------------------
	wire        eRWn, ASn, LDSn, UDSn, VMAn;
	wire        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
	wire [15:0] iEdb, oEdb;
	wire [23:1] eab;

	wire [2:0] ipl_level;
	wire       IPL0n = ~ipl_level[0];
	wire       IPL1n = ~ipl_level[1];
	wire       IPL2n = ~ipl_level[2];

	wire iack_cycle = FC0 & FC1 & FC2 & ~ASn;
	wire VPAn = ~iack_cycle;
	// HW_ROMS=1 only: hold DTACKn off while the maincpu ROM cache hasn't
	// yet produced data for the current address (see rom_cache1/sd0
	// wiring below), or while the mainram/bgvram registered read (see
	// g_mainram_read_hw/g_bgvram_read_hw below — needed for RAM
	// inference, same reasoning as the ROM cache) hasn't settled yet for
	// the current address — every other region stays real 0-wait on-chip
	// work RAM, unaffected. At HW_ROMS=0, rom_ready/mainram_ready/
	// bgvram_ready are all tied to 1'b1 (see each region's own g_*_sim
	// branch), so this composite reduces to the original DTACKn exactly,
	// byte-for-byte, for every existing sim testbench.
	wire rom_wait     = sel_rom     & cpu_read & ~rom_ready;
	wire mainram_wait = sel_mainram & cpu_read & ~mainram_ready;
	// Sprite DMA in progress: hold the CPU off main RAM (reads via DTACKn
	// here, writes via the gated write enables below), as the real
	// board's DMA bus request does — see video_macross2.sv's own
	// sprite_dma_busy port comment for what goes wrong otherwise.
	wire sprite_dma_busy;
	wire mainram_dma_wait = sel_mainram & ~ASn & sprite_dma_busy;
	wire bgvram_wait  = sel_bgvram  & cpu_read & ~bgvram_ready;
	wire palette_wait = sel_palette & cpu_read & ~palette_ready;
	wire txvram_wait  = sel_txvram  & cpu_read & ~txvram_ready;
	wire DTACKn = ASn | iack_cycle | rom_wait | mainram_wait | mainram_dma_wait | bgvram_wait | txvram_wait | palette_wait;

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(1'b1), // no protection MCU on this board
		.extReset(reset),
		.pwrUp(reset),
		.enPhi1(enPhi1),
		.enPhi2(enPhi2),

		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
		.E(), .VMAn(VMAn),

		.FC0(FC0), .FC1(FC1), .FC2(FC2),
		.BGn(BGn),
		.oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
		.DTACKn(DTACKn), .VPAn(VPAn),
		.BERRn(1'b1),
		.BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(IPL0n), .IPL1n(IPL1n), .IPL2n(IPL2n),
		.iEdb(iEdb), .oEdb(oEdb),
		.eab(eab)
	);

	wire [23:0] byte_addr = {eab, 1'b0};
	wire        cpu_write = ~eRWn & ~ASn;
	wire        cpu_read  = eRWn & ~ASn;

	// ------------------------------------------------------------------
	// Address decode (68000 side) — identical addresses to macross2_map's
	// own (see macross2_core.sv's header) except mainram, below.
	// ------------------------------------------------------------------
	// powerins_map differs (nmk16.cpp:1193): 1 MB ROM, palette 0x120000-
	// 0x120FFF (2048 entries), bgvram 0x140000-0x143FFF, mainram 0x180000-
	// 0x18FFFF, 0x100016 a plain nopw (no Z80 reset), no soundlatch2 read.
	wire sel_rom       = game_powerins ? (byte_addr <= 24'h0FFFFF) : (byte_addr <= 24'h07FFFF);
	wire sel_in0       = (byte_addr[23:1] == 23'h080000); // 100000/100001
	wire sel_in1       = (byte_addr[23:1] == 23'h080001); // 100002/100003
	wire sel_dsw1      = (byte_addr[23:1] == 23'h080004); // 100008/100009
	wire sel_dsw2      = (byte_addr[23:1] == 23'h080005); // 10000A/10000B
	wire sel_soundlatch2_r = ~game_powerins & (byte_addr[23:1] == 23'h080007); // 10000E/10000F word, byte reg at odd
	wire sel_flip      = (byte_addr[23:1] == 23'h08000A); // 100014/100015, LDS=low byte
	wire sel_sndreset  = ~game_powerins & (byte_addr[23:1] == 23'h08000B); // 100016/100017 word
	wire sel_tilebank  = (byte_addr[23:1] == 23'h08000C); // 100018/100019, LDS=low byte
	wire sel_soundlatch_w = (byte_addr[23:1] == 23'h08000F); // 10001E/10001F word, byte reg at odd
	wire sel_palette   = (byte_addr >= 24'h120000) && (byte_addr <= (game_powerins ? 24'h120FFF : 24'h1207FF));
	wire sel_scroll    = (byte_addr >= 24'h130000) && (byte_addr <= 24'h130007);
	wire sel_bgvram    = (byte_addr >= 24'h140000) && (byte_addr <= (game_powerins ? 24'h143FFF : 24'h14FFFF));
	wire sel_txvram    = (byte_addr >= 24'h170000) && (byte_addr <= 24'h171FFF);
	wire sel_mainram   = game_powerins ? ((byte_addr >= 24'h180000) && (byte_addr <= 24'h18FFFF))
	                                   : ((byte_addr >= 24'h1F0000) && (byte_addr <= 24'h1FFFFF));

	// ------------------------------------------------------------------
	// ROM (maincpu) — 0x80000 bytes = 262144 words. HW_ROMS=0: unchanged
	// $readmemh sim array, 0-latency. HW_ROMS=1: rom_cache1 over SDRAM
	// port 0 (base offset 0x000000 in the layout docs/hw-bringup.md
	// documents), shared with ioctl_download writes via a plain mux
	// (mutually exclusive in time — the core stays in reset for the
	// whole download). A real wait-state: DTACKn is held off (via
	// rom_wait below) until the cache reports ready for the current
	// address, unlike every other still-0-latency on-chip region.
	// ------------------------------------------------------------------
	wire [15:0] rom_dout;
	wire        rom_ready;
	wire [15:0] rom_fetch_csum;
	wire [15:0] rom_fetch_csum_count;
	wire        rom_fetch_csum_done;
	wire [15:0]   dbg_bucket_state;
	wire          dbg_bucket_touched;
	wire [0:127]  rom_fetch_bucket_touched;
	wire [0:127]  rom_fetch_bucket_sim_touched;
	wire [0:127]  rom_fetch_bucket_fail;
	wire [15:0]   dbg_fine_state;
	wire          dbg_fine_touched;
	wire [0:127]  rom_fetch_fine_touched;
	wire [0:127]  rom_fetch_fine_sim_touched;
	wire [0:127]  rom_fetch_fine_fail;
	wire [15:0]   dbg_word_state;
	wire          dbg_word_touched;
	wire [0:15]   rom_fetch_word_touched;
	wire [0:15]   rom_fetch_word_sim_touched;
	wire [0:15]   rom_fetch_word_fail;
	wire [15:0]   rom_word0_raw, rom_word1_raw, rom_word2_raw, rom_word3_raw;
	wire          rom_word0_was_write, rom_word1_was_write, rom_word2_was_write, rom_word3_was_write;
	wire [24:1]   rom_word0_race_addr, rom_word1_race_addr, rom_word2_race_addr, rom_word3_race_addr;
	generate
	if (!HW_ROMS) begin : g_rom_sim
		reg [15:0] rom [0:524287]; // 1 MB: powerins' two ROM_LOAD16_WORD_SWAP files; tdragon2/macross2 fill the low half
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
		assign rom_dout  = rom[byte_addr[19:1]];
		assign rom_ready = 1'b1;
		assign sd0_addr = 24'd0; assign sd0_wrl = 1'b0; assign sd0_wrh = 1'b0;
		assign sd0_din  = 16'd0; assign sd0_req = 1'b0;
		assign ioctl_wait = 1'b0;
		assign rom_fetch_csum = 16'd0; assign rom_fetch_csum_count = 16'd0; assign rom_fetch_csum_done = 1'b0;
		assign dbg_bucket_state = 16'd0; assign dbg_bucket_touched = 1'b0;
		assign rom_fetch_bucket_touched = 128'd0;
		assign rom_fetch_bucket_sim_touched = 128'd0; assign rom_fetch_bucket_fail = 128'd0;
		assign dbg_fine_state = 16'd0; assign dbg_fine_touched = 1'b0;
		assign rom_fetch_fine_touched = 128'd0;
		assign rom_fetch_fine_sim_touched = 128'd0; assign rom_fetch_fine_fail = 128'd0;
		assign dbg_word_state = 16'd0; assign dbg_word_touched = 1'b0;
		assign rom_fetch_word_touched = 16'd0;
		assign rom_fetch_word_sim_touched = 16'd0; assign rom_fetch_word_fail = 16'd0;
		assign rom_word0_raw = 16'd0; assign rom_word1_raw = 16'd0;
		assign rom_word2_raw = 16'd0; assign rom_word3_raw = 16'd0;
		assign rom_word0_was_write = 1'b0; assign rom_word1_was_write = 1'b0;
		assign rom_word2_was_write = 1'b0; assign rom_word3_was_write = 1'b0;
		assign rom_word0_race_addr = 24'd0; assign rom_word1_race_addr = 24'd0;
		assign rom_word2_race_addr = 24'd0; assign rom_word3_race_addr = 24'd0;
	end else begin : g_rom_hw
		wire        cache_busy, cache_valid;
		wire [15:0] cache_dout;
		wire [31:0] cache_dout_pair;
		wire [24:1] cache_sd_addr;
		wire        cache_sd_req;
		wire        sd0_dbg_we;
		wire [24:1] sd0_dbg_addr;

		// ioctl_rom_wr: only the <rom index="0"> session may write SDRAM.
		// Every other ioctl session (the .mra <switches> DIP block, index
		// 254, restarts at ioctl_addr 0) is deliberately IGNORED here —
		// see the ioctl_index port comment for why this is the real fix
		// for the reset-vector clobber.
		wire ioctl_rom_wr = ioctl_download && (ioctl_index == 16'd0);

		sdram_req sd0_inst (
			.clk(clk_sys), .reset(por_rst),
			.addr(ioctl_download ? ioctl_addr[24:1] : cache_sd_addr),
			.we(ioctl_rom_wr), .wrl(ioctl_rom_wr & ~ioctl_addr[0]), .wrh(ioctl_rom_wr & ioctl_addr[0]),
			.din({ioctl_dout, ioctl_dout}),
			.req(ioctl_download ? (ioctl_rom_wr & ioctl_wr) : cache_sd_req),
			.busy(cache_busy), .valid(cache_valid), .dout(cache_dout), .dout_pair(cache_dout_pair),
			.sdram_addr(sd0_addr), .sdram_wrl(sd0_wrl), .sdram_wrh(sd0_wrh), .sdram_din(sd0_din),
			.sdram_dout(sd0_dout), .sdram_dout_pair(sd0_dout_pair), .sdram_req(sd0_req), .sdram_ack(sd0_ack),
			.dbg_we_r_o(sd0_dbg_we), .dbg_addr_r_o(sd0_dbg_addr)
		);
		assign ioctl_wait = ioctl_download & cache_busy;

		// The cache only ever sees ROM addresses — see raphero_core.sv's
		// rom_addr_held and docs/hw-bringup.md: rom_cache1 refetches on any
		// address change, so the raw bus address made every RAM/VRAM access
		// start a speculative SDRAM read whose fill could overwrite the line
		// between the 68000's DTACK sample and its data latch. Never seen at
		// this core's 10 MHz, but the same race raphero hit at 14 MHz.
		reg [19:1] rom_addr_held;
		always @(posedge clk_sys) if (sel_rom) rom_addr_held <= byte_addr[19:1];
		wire [19:1] rom_cache_addr = sel_rom ? byte_addr[19:1] : rom_addr_held;
		// 16 pairs + next-pair prefetch instead of rom_cache1's single
		// pair: see rtl/rom_cache_n.sv (68000 slowdown vs MAME). LAST_PAIR
		// covers powerins' 1 MB program; for the 512 KB games a prefetch
		// past the end reads the audiocpu region into an unused line.
		rom_cache_n #(.LINES(16), .PREFETCH(1), .LAST_PAIR(22'h03FFFF)) rom_cache_inst (
			.clk(clk_sys), .reset(reset | ioctl_download),
			.addr(rom_cache_addr), .data(rom_dout), .ready(rom_ready),
			.sd_addr(cache_sd_addr), .sd_req(cache_sd_req),
			.sd_busy(cache_busy), .sd_valid(cache_valid), .sd_dout(cache_dout), .sd_dout_pair(cache_dout_pair)
		);

		// DIAGNOSTIC ONLY: a SECOND passive checksum, one tap stage
		// upstream of rom_csum above — gated on cache_valid (sd0_inst's
		// own one-cycle read-complete pulse feeding INTO rom_cache1, i.e.
		// the exact moment a fresh word lands in rom_cache1's single-entry
		// cache from real SDRAM), sampling cache_dout, rather than on
		// DTACKn/the CPU bus. Because rom_cache1 only ever issues a fetch
		// on a genuine cache miss (see its own addr_match logic), this
		// counts once per UNIQUE address ever fetched — a strict subset of
		// rom_csum's per-bus-cycle count, since a 68000 re-read of an
		// address still held in the 1-entry cache produces no new
		// cache_valid pulse at all. Safe to treat every cache_valid pulse
		// here as "a real ROM read completed" (as opposed to an
		// ioctl_download write also sharing this same sdram_req port)
		// because this always-block only starts counting after `reset`
		// deasserts, and ioctl_download is held for the whole download
		// while the core itself stays in reset (see this ROM region's own
		// header comment above) — so by the time reset is low here,
		// ioctl_download is guaranteed 0 and every cache_valid pulse sd0_inst
		// produces from then on is unambiguously a rom_cache_inst read.
		//
		// Purpose: isolate whether a real-vs-sim mismatch on rom_csum_o
		// (found via this project's own hardware bring-up work — see
		// docs/hw-bringup.md) traces back to the raw word stream SDRAM
		// actually delivers to rom_cache1 (this checksum), or instead to
		// something in rom_cache1's own cache-line replay logic / the
		// DTACKn wait-state glue between rom_cache1 and the CPU (which
		// would show as THIS checksum matching between real hardware and
		// simulation while rom_csum_o still does not).
		localparam [15:0] ROM_FETCH_CSUM_TARGET = 16'd4096;
		reg [15:0] fetch_csum_r;
		reg [15:0] fetch_csum_count_r;
		reg        fetch_csum_done_r;
		always @(posedge clk_sys) begin
			if (reset) begin
				fetch_csum_r       <= 16'd0;
				fetch_csum_count_r <= 16'd0;
				fetch_csum_done_r  <= 1'b0;
			end else if (cache_valid && !fetch_csum_done_r) begin
				fetch_csum_r       <= {fetch_csum_r[14:0], fetch_csum_r[15]} ^ cache_dout;
				fetch_csum_count_r <= fetch_csum_count_r + 16'd1;
				if (fetch_csum_count_r == ROM_FETCH_CSUM_TARGET - 16'd1) fetch_csum_done_r <= 1'b1;
			end
		end
		assign rom_fetch_csum       = fetch_csum_r;
		assign rom_fetch_csum_count = fetch_csum_count_r;
		assign rom_fetch_csum_done  = fetch_csum_done_r;

		// ------------------------------------------------------------------
		// DIAGNOSTIC ONLY: a SPATIAL companion to rom_fetch_csum above,
		// same purpose as ioctl_bucket_fail_o has for ioctl_csum_o —
		// localizing WHERE a real-vs-sim mismatch happens instead of only
		// knowing THAT one exists. Structurally different from
		// ioctl_bucket_fail_o's own bucketing, though: the ioctl write
		// stream visits every address exactly once, in strict monotonic
		// order, so "count crosses a multiple of N" cleanly marks a
		// bucket boundary. The CPU's own real ROM-fetch address stream
		// does neither — it revisits some addresses, skips others
		// entirely, and jumps around in whatever order the actual
		// program executes in — so this instead keys 128 INDEPENDENT
		// per-bucket accumulators directly by address (cache_sd_addr's
		// own word address, bucket = addr[17:11], 2048 words/bucket,
		// same 128-bucket granularity as ioctl_bucket_fail_o and
		// SdramTest.sv's own Phase 1, chosen for direct comparability),
		// each folding in every word fetched from its own address range
		// regardless of when/how many times that happens.
		//
		// Because coverage is inherently partial and run-dependent (real
		// hardware's own real-time interrupt-phase jitter can shift
		// EXACTLY which addresses get visited within a fixed fetch-count
		// budget — already observed directly: rom_fetch_csum_o itself
		// read 1 bit apart across two separate real-hardware reloads of
		// the byte-identical bitstream, see docs/hw-bringup.md), a
		// bucket's live state can only be meaningfully compared where
		// BOTH this run and the reference (sim) run actually touched it
		// — ROM_FETCH_BUCKET_TOUCHED_FILE (rom_fetch_bucket_sim_touched_o
		// below) records which buckets the reference run itself reached,
		// so a bucket the reference never visited displays as
		// "unvalidated" rather than a false FAIL.
		reg [15:0] fetch_bucket_state_r [0:127];
		reg        fetch_bucket_touched_r [0:127];
		integer    fbk_i;
		always @(posedge clk_sys) begin
			if (reset) begin
				for (fbk_i = 0; fbk_i < 128; fbk_i = fbk_i + 1) begin
					fetch_bucket_state_r[fbk_i]   <= 16'd0;
					fetch_bucket_touched_r[fbk_i] <= 1'b0;
				end
			end else if (cache_valid && !fetch_csum_done_r) begin
				fetch_bucket_state_r[cache_sd_addr[18:12]] <=
					{fetch_bucket_state_r[cache_sd_addr[18:12]][14:0], fetch_bucket_state_r[cache_sd_addr[18:12]][15]} ^ cache_dout;
				fetch_bucket_touched_r[cache_sd_addr[18:12]] <= 1'b1;
			end
		end

		reg [15:0] fetch_bucket_ref_r [0:127];
		reg        fetch_bucket_sim_touched_r [0:127];
		initial if (ROM_FETCH_BUCKET_REF_FILE != "") $readmemh(ROM_FETCH_BUCKET_REF_FILE, fetch_bucket_ref_r);
		initial if (ROM_FETCH_BUCKET_TOUCHED_FILE != "") $readmemh(ROM_FETCH_BUCKET_TOUCHED_FILE, fetch_bucket_sim_touched_r);

		genvar gb;
		for (gb = 0; gb < 128; gb = gb + 1) begin : g_fetch_bucket_pack
			assign rom_fetch_bucket_touched[gb]     = fetch_bucket_touched_r[gb];
			assign rom_fetch_bucket_sim_touched[gb] = fetch_bucket_sim_touched_r[gb];
			assign rom_fetch_bucket_fail[gb]        = fetch_bucket_touched_r[gb] && fetch_bucket_sim_touched_r[gb]
				&& (fetch_bucket_state_r[gb] != fetch_bucket_ref_r[gb]);
		end
		assign dbg_bucket_state   = fetch_bucket_state_r[dbg_bucket_sel_i];
		assign dbg_bucket_touched = fetch_bucket_touched_r[dbg_bucket_sel_i];

		// ------------------------------------------------------------------
		// DIAGNOSTIC ONLY: a ZOOMED-IN companion to the 128-bucket spatial
		// logic just above, scoped to ONLY word addresses [0,2048) — that
		// logic's own bucket 0, which this project's own real-hardware
		// bring-up work found DOES show a genuine mismatch (see
		// docs/hw-bringup.md) — at 16 words/bucket (128x finer) instead of
		// 2048 words/bucket, to see whether the CPU's own reset vector
		// (word addresses 0-3, byte 0-7 — the initial SP/PC the 68000
		// itself latches at power-on) is specifically corrupted, or only
		// later boot code within that same 4KB range. Same
		// touched/sim_touched/fail structure and same reasoning for it
		// (partial, run-dependent coverage) as the 2048-word-bucket
		// version above — just re-keyed to addr[10:4] (16-word buckets,
		// 2048/16=128) and gated to cache_sd_addr<2048 so it only ever
		// accumulates from within this one zoomed-in region.
		reg [15:0] fetch_fine_state_r [0:127];
		reg        fetch_fine_touched_r [0:127];
		integer    ffk_i;
		always @(posedge clk_sys) begin
			if (reset) begin
				for (ffk_i = 0; ffk_i < 128; ffk_i = ffk_i + 1) begin
					fetch_fine_state_r[ffk_i]   <= 16'd0;
					fetch_fine_touched_r[ffk_i] <= 1'b0;
				end
			end else if (cache_valid && !fetch_csum_done_r && (cache_sd_addr < 25'd2048)) begin
				fetch_fine_state_r[cache_sd_addr[11:5]] <=
					{fetch_fine_state_r[cache_sd_addr[11:5]][14:0], fetch_fine_state_r[cache_sd_addr[11:5]][15]} ^ cache_dout;
				fetch_fine_touched_r[cache_sd_addr[11:5]] <= 1'b1;
			end
		end

		reg [15:0] fetch_fine_ref_r [0:127];
		reg        fetch_fine_sim_touched_r [0:127];
		initial if (ROM_FETCH_FINE_REF_FILE != "") $readmemh(ROM_FETCH_FINE_REF_FILE, fetch_fine_ref_r);
		initial if (ROM_FETCH_FINE_TOUCHED_FILE != "") $readmemh(ROM_FETCH_FINE_TOUCHED_FILE, fetch_fine_sim_touched_r);

		genvar gf;
		for (gf = 0; gf < 128; gf = gf + 1) begin : g_fetch_fine_pack
			assign rom_fetch_fine_touched[gf]     = fetch_fine_touched_r[gf];
			assign rom_fetch_fine_sim_touched[gf] = fetch_fine_sim_touched_r[gf];
			assign rom_fetch_fine_fail[gf]        = fetch_fine_touched_r[gf] && fetch_fine_sim_touched_r[gf]
				&& (fetch_fine_state_r[gf] != fetch_fine_ref_r[gf]);
		end
		assign dbg_fine_state   = fetch_fine_state_r[dbg_bucket_sel_i];
		assign dbg_fine_touched = fetch_fine_touched_r[dbg_bucket_sel_i];

		// ------------------------------------------------------------------
		// DIAGNOSTIC ONLY: TRUE per-word granularity, scoped to word
		// addresses [0,16) — fetch_fine_state_r[0]'s own range above,
		// which this project's own real-hardware bring-up work found is
		// the ONLY one of the 128 fine buckets that showed any real
		// traffic at all (see docs/hw-bringup.md), meaning the entire
		// coarse-bucket-0 mismatch is concentrated somewhere in this one
		// 32-byte span. At 1-word/bucket, a rotate-XOR state starting
		// from 0 with only ONE distinct address ever landing in it is
		// mathematically just that word's own raw value (0 rol 1 = 0,
		// 0^word=word) — so fetch_word_state_r doubles as an exact
		// per-word value readout, not merely pass/fail, letting a mismatch
		// here directly show BOTH the wrong value real hardware read AND
		// the correct value it should have read.
		reg [15:0] fetch_word_state_r [0:15];
		reg        fetch_word_touched_r [0:15];
		// DIAGNOSTIC ONLY: captures sd0_inst's own dbg_we_r_o/dbg_addr_r_o
		// (see sdram_req.sv's own comment) at the exact cycle each of
		// these first 16 cache_valid pulses fires — testing the specific
		// race hypothesis this project's own real-hardware bring-up work
		// raised after finding words 0/1/3 of the reset vector read back
		// mostly-zero on real hardware (see docs/hw-bringup.md): was the
		// transaction that JUST completed actually a WRITE (the tail of
		// ioctl_download's own last byte, whose dout is meaningless —
		// see sdram_req.sv's own header comment), not the genuine read
		// rom_cache1 itself thinks just landed? was its own address even
		// the one rom_cache1 asked for?
		reg        fetch_word_was_write_r [0:15];
		reg [24:1] fetch_word_race_addr_r [0:15];
		integer    fwk_i;
		always @(posedge clk_sys) begin
			if (reset) begin
				for (fwk_i = 0; fwk_i < 16; fwk_i = fwk_i + 1) begin
					fetch_word_state_r[fwk_i]      <= 16'd0;
					fetch_word_touched_r[fwk_i]    <= 1'b0;
					fetch_word_was_write_r[fwk_i]  <= 1'b0;
					fetch_word_race_addr_r[fwk_i]  <= 24'd0;
				end
			end else if (cache_valid && !fetch_csum_done_r && (cache_sd_addr < 25'd16)) begin
				fetch_word_state_r[cache_sd_addr[4:1]] <=
					{fetch_word_state_r[cache_sd_addr[4:1]][14:0], fetch_word_state_r[cache_sd_addr[4:1]][15]} ^ cache_dout;
				fetch_word_touched_r[cache_sd_addr[4:1]]   <= 1'b1;
				fetch_word_was_write_r[cache_sd_addr[4:1]] <= sd0_dbg_we;
				fetch_word_race_addr_r[cache_sd_addr[4:1]] <= sd0_dbg_addr;
			end
		end

		reg [15:0] fetch_word_ref_r [0:15];
		reg        fetch_word_sim_touched_r [0:15];
		initial if (ROM_FETCH_WORD_REF_FILE != "") $readmemh(ROM_FETCH_WORD_REF_FILE, fetch_word_ref_r);
		initial if (ROM_FETCH_WORD_TOUCHED_FILE != "") $readmemh(ROM_FETCH_WORD_TOUCHED_FILE, fetch_word_sim_touched_r);

		genvar gw;
		for (gw = 0; gw < 16; gw = gw + 1) begin : g_fetch_word_pack
			assign rom_fetch_word_touched[gw]     = fetch_word_touched_r[gw];
			assign rom_fetch_word_sim_touched[gw] = fetch_word_sim_touched_r[gw];
			assign rom_fetch_word_fail[gw]        = fetch_word_touched_r[gw] && fetch_word_sim_touched_r[gw]
				&& (fetch_word_state_r[gw] != fetch_word_ref_r[gw]);
		end
		assign dbg_word_state   = fetch_word_state_r[dbg_bucket_sel_i[3:0]];
		assign dbg_word_touched = fetch_word_touched_r[dbg_bucket_sel_i[3:0]];

		assign rom_word0_raw = fetch_word_state_r[0];
		assign rom_word1_raw = fetch_word_state_r[1];
		assign rom_word2_raw = fetch_word_state_r[2];
		assign rom_word3_raw = fetch_word_state_r[3];

		assign rom_word0_was_write = fetch_word_was_write_r[0];
		assign rom_word1_was_write = fetch_word_was_write_r[1];
		assign rom_word2_was_write = fetch_word_was_write_r[2];
		assign rom_word3_was_write = fetch_word_was_write_r[3];
		assign rom_word0_race_addr = fetch_word_race_addr_r[0];
		assign rom_word1_race_addr = fetch_word_race_addr_r[1];
		assign rom_word2_race_addr = fetch_word_race_addr_r[2];
		assign rom_word3_race_addr = fetch_word_race_addr_r[3];
	end
	endgenerate
	assign rom_fetch_csum_o       = rom_fetch_csum;
	assign rom_fetch_csum_count_o = rom_fetch_csum_count;
	assign rom_fetch_csum_done_o  = rom_fetch_csum_done;
	assign dbg_bucket_state_o             = dbg_bucket_state;
	assign dbg_bucket_touched_o           = dbg_bucket_touched;
	assign rom_fetch_bucket_touched_o     = rom_fetch_bucket_touched;
	assign rom_fetch_bucket_sim_touched_o = rom_fetch_bucket_sim_touched;
	assign rom_fetch_bucket_fail_o        = rom_fetch_bucket_fail;
	assign dbg_fine_state_o               = dbg_fine_state;
	assign dbg_fine_touched_o             = dbg_fine_touched;
	assign rom_fetch_fine_touched_o       = rom_fetch_fine_touched;
	assign rom_fetch_fine_sim_touched_o   = rom_fetch_fine_sim_touched;
	assign rom_fetch_fine_fail_o          = rom_fetch_fine_fail;
	assign dbg_word_state_o               = dbg_word_state;
	assign dbg_word_touched_o             = dbg_word_touched;
	assign rom_fetch_word_touched_o       = rom_fetch_word_touched;
	assign rom_fetch_word_sim_touched_o   = rom_fetch_word_sim_touched;
	assign rom_fetch_word_fail_o          = rom_fetch_word_fail;
	assign rom_word0_raw_o = rom_word0_raw;
	assign rom_word1_raw_o = rom_word1_raw;
	assign rom_word2_raw_o = rom_word2_raw;
	assign rom_word3_raw_o = rom_word3_raw;
	assign rom_word0_was_write_o = rom_word0_was_write;
	assign rom_word1_was_write_o = rom_word1_was_write;
	assign rom_word2_was_write_o = rom_word2_was_write;
	assign rom_word3_was_write_o = rom_word3_was_write;
	assign rom_word0_race_addr_o = rom_word0_race_addr;
	assign rom_word1_race_addr_o = rom_word1_race_addr;
	assign rom_word2_race_addr_o = rom_word2_race_addr;
	assign rom_word3_race_addr_o = rom_word3_race_addr;
	assign rom_word0_addr_ok_o = (rom_word0_race_addr == 24'd0);
	assign rom_word1_addr_ok_o = (rom_word1_race_addr == 24'd1);
	assign rom_word2_addr_ok_o = (rom_word2_race_addr == 24'd2);
	assign rom_word3_addr_ok_o = (rom_word3_race_addr == 24'd3);

	// ------------------------------------------------------------------
	// DIAGNOSTIC ONLY: a THIRD passive checksum — the earliest possible
	// tap point in this whole ROM-loading data path: the raw
	// ioctl_download WRITE byte stream itself (ioctl_dout, one byte per
	// ioctl_wr pulse), gated to just the maincpu ROM region
	// (ioctl_addr < 0x080000, matching sel_rom's own range), BEFORE any
	// of it ever reaches rtl/sdram.sv. Both this project's real hardware
	// and its HW_ROMS=1 Verilator sim testbenches (see
	// sim/rtl/tdragon2_hw/tb_tdragon2_hw.cpp) are fed from a
	// byte-identical tools/mk_ioctl_stream.py-produced .bin file built
	// from the same source ROM dump, so this checksum SHOULD match
	// between a real-hardware run and a sim run if (and only if) the
	// bytes HPS actually sends over ioctl_download on real hardware
	// match what the ARM-side loader was given — a mismatch here would
	// mean real-hardware data corruption starts before the FPGA fabric
	// ever sees it, upstream of everything rom_csum_o/rom_fetch_csum_o
	// above can see; a MATCH here (while rom_fetch_csum_o still
	// mismatches) would instead point at rtl/sdram.sv's real write/
	// refresh/read-back behavior between write time (this download,
	// during boot) and read time (potentially minutes later, during
	// actual gameplay) — a real-time gap this project's own SdramTest
	// diagnostic core's write-then-immediately-readback pattern never
	// exercised.
	//
	// Uses por_rst (NOT this module's own `reset` input) to initialize,
	// same reasoning as sd0_inst/rom_cache_inst's own reset wiring just
	// above: `reset` stays asserted for the ENTIRE download (see this
	// ROM region's own header comment), so gating this accumulator's
	// reset on `reset` would clear it every single cycle throughout the
	// exact window it needs to observe and it would never accumulate
	// anything.
	//
	// Covers the full 524288-byte maincpu region (matching this
	// project's own SdramTest Phase 1 full-range approach — the whole
	// region really is written during a real download regardless of
	// sample size), not a small sample.
	localparam [19:0] IOCTL_CSUM_TARGET_BYTES = 20'd524288;
	reg [15:0] ioctl_csum_r;
	reg [19:0] ioctl_csum_count_r;
	reg        ioctl_csum_done_r;
	always @(posedge clk_sys) begin
		if (por_rst) begin
			ioctl_csum_r       <= 16'd0;
			ioctl_csum_count_r <= 20'd0;
			ioctl_csum_done_r  <= 1'b0;
		end else if (ioctl_download && (ioctl_index == 16'd0) && ioctl_wr && (ioctl_addr < 25'h080000) && !ioctl_csum_done_r) begin
			ioctl_csum_r       <= {ioctl_csum_r[14:0], ioctl_csum_r[15]} ^ {8'd0, ioctl_dout};
			ioctl_csum_count_r <= ioctl_csum_count_r + 20'd1;
			if (ioctl_csum_count_r == IOCTL_CSUM_TARGET_BYTES - 20'd1) ioctl_csum_done_r <= 1'b1;
		end
	end
	assign ioctl_csum_o       = ioctl_csum_r;
	assign ioctl_csum_count_o = ioctl_csum_count_r;
	assign ioctl_csum_done_o  = ioctl_csum_done_r;

	// ------------------------------------------------------------------
	// DIAGNOSTIC ONLY: a SPATIAL/bucketed companion to ioctl_csum_o just
	// above — that single aggregate checksum can prove real hardware's
	// write-side data differs from the known-good source, but can't say
	// WHERE. This splits the same 524288-byte maincpu region into 128
	// buckets of 4096 bytes each (matching this project's own
	// SdramTest.sv Phase 1 bucket layout/display convention exactly, for
	// the same reason: 128 buckets * 3px = 384 = the full screen width),
	// each with its OWN independent rotate-XOR checksum (reset to 0 at
	// the start of every bucket), compared live against
	// IOCTL_BUCKET_REF_FILE's own known-good per-bucket value — computed
	// host-side, directly from the exact same byte-identical
	// tools/mk_ioctl_stream.py-produced .bin file both sim and real
	// hardware are fed from, using this exact rotate-XOR algorithm
	// (cross-checked to reproduce ioctl_csum_o's own known-good aggregate
	// value, 0x620E, exactly, before being committed). A real-hardware
	// mismatch on any bucket here needs no separate sim run to interpret
	// — IOCTL_BUCKET_REF_FILE already IS the correct answer.
	//
	// Several reference buckets are legitimately 0x0000 (real, blank
	// all-0x00 stretches within the actual ROM dump content itself, not
	// a gap in this logic) — still meaningful checks, since a real
	// hardware SDRAM data-retention/refresh problem would show up most
	// obviously as exactly one of THESE buckets reading back non-zero.
	reg [15:0] ioctl_bucket_ref [0:127];
	initial if (IOCTL_BUCKET_REF_FILE != "") $readmemh(IOCTL_BUCKET_REF_FILE, ioctl_bucket_ref);

	reg [15:0] ioctl_bucket_state_r;
	reg [0:127] ioctl_bucket_fail_r;
	integer    ibf_i;
	always @(posedge clk_sys) begin
		if (por_rst) begin
			ioctl_bucket_state_r <= 16'd0;
			for (ibf_i = 0; ibf_i < 128; ibf_i = ibf_i + 1) ioctl_bucket_fail_r[ibf_i] <= 1'b0;
		end else if (ioctl_download && (ioctl_index == 16'd0) && ioctl_wr && (ioctl_addr < 25'h080000) && !ioctl_csum_done_r) begin
			if (ioctl_csum_count_r[11:0] == 12'hFFF) begin
				// last byte of this bucket: fold it in, compare, latch
				// pass/fail, then reset for the next bucket.
				ioctl_bucket_fail_r[ioctl_csum_count_r[18:12]] <=
					(({ioctl_bucket_state_r[14:0], ioctl_bucket_state_r[15]} ^ {8'd0, ioctl_dout})
						!= ioctl_bucket_ref[ioctl_csum_count_r[18:12]]);
				ioctl_bucket_state_r <= 16'd0;
			end else begin
				ioctl_bucket_state_r <= {ioctl_bucket_state_r[14:0], ioctl_bucket_state_r[15]} ^ {8'd0, ioctl_dout};
			end
		end
	end
	assign ioctl_bucket_fail_o = ioctl_bucket_fail_r;

	// ------------------------------------------------------------------
	// DIAGNOSTIC ONLY: real ioctl_wr pulse-to-pulse timing/gap
	// instrumentation over an ACTUAL real-hardware .mra download — see
	// ioctl_wr_max_gap_o's own comment at the port declaration for the
	// full rationale (testing real hps_io/ARM-side pacing irregularity,
	// after SdramTest.sv's own PHASE 3/3b synthetic repros — clean
	// full-word writes, then real byte-at-a-time writes, both run
	// purely in-FPGA at full back-to-back clk_sys speed — both passed
	// cleanly, ruling out write granularity and the bare dual-requester
	// mux structure on their own). Uses por_rst (not this module's own
	// `reset`), same reasoning as ioctl_csum_r's own reset wiring above
	// — `reset` stays asserted for the entire download.
	reg [23:0] wr_gap_cnt;
	reg [23:0] wr_max_gap;
	reg [23:0] wr_over_refresh_count;
	reg        wr_prev;
	always @(posedge clk_sys) begin
		if (por_rst) begin
			wr_gap_cnt            <= 24'd0;
			wr_max_gap            <= 24'd0;
			wr_over_refresh_count <= 24'd0;
			wr_prev               <= 1'b0;
		end else if (ioctl_download) begin
			wr_prev <= ioctl_wr;
			if (ioctl_wr && !wr_prev) begin
				if (wr_gap_cnt > wr_max_gap) wr_max_gap <= wr_gap_cnt;
				if (wr_gap_cnt >= 24'd240) wr_over_refresh_count <= wr_over_refresh_count + 24'd1;
				wr_gap_cnt <= 24'd0;
			end else begin
				wr_gap_cnt <= wr_gap_cnt + 24'd1;
			end
		end
	end
	assign ioctl_wr_max_gap_o            = wr_max_gap;
	assign ioctl_wr_over_refresh_count_o = wr_over_refresh_count;

	// DIAGNOSTIC ONLY: ioctl session tracking — see ioctl_session_count_o's
	// own port comment. por_rst-gated for the same reason as ioctl_csum_r.
	reg        dl_prev;
	reg [7:0]  dl_session_count;
	reg [15:0] dl_last_index;
	reg [15:0] dl_nonrom_word0;
	always @(posedge clk_sys) begin
		if (por_rst) begin
			dl_prev          <= 1'b0;
			dl_session_count <= 8'd0;
			dl_last_index    <= 16'd0;
			dl_nonrom_word0  <= 16'd0;
		end else begin
			dl_prev <= ioctl_download;
			if (ioctl_download && !dl_prev) begin
				dl_session_count <= dl_session_count + 8'd1;
				dl_last_index    <= ioctl_index;
			end
			if (ioctl_download && ioctl_wr && (ioctl_index != 16'd0)) begin
				if (ioctl_addr == 25'd0) dl_nonrom_word0[7:0]  <= ioctl_dout;
				if (ioctl_addr == 25'd1) dl_nonrom_word0[15:8] <= ioctl_dout;
			end
		end
	end
	assign ioctl_session_count_o = dl_session_count;
	assign ioctl_last_index_o    = dl_last_index;
	assign ioctl_nonrom_word0_o  = dl_nonrom_word0;

	// ------------------------------------------------------------------
	// DIAGNOSTIC ONLY (HW_ROMS=1): passive checksum over every REAL
	// 68000 maincpu-ROM read (rom_dout, via rom_cache1 — the exact same
	// data path the CPU itself relies on), used to verify on real
	// hardware that the ROM the CPU is actually executing loaded
	// correctly, without any risk of disturbing the CPU's own bus
	// timing — this taps rom_dout/DTACKn purely as an observer, issues
	// no requests of its own, and does not touch rom_ready/DTACKn/
	// cache_sd_addr at all. Added during this project's own real-
	// hardware black-screen investigation (see docs/hw-bringup.md).
	//
	// Counts a read exactly once per completed 68000 bus cycle — on the
	// cycle DTACKn transitions high-to-low, not "every cycle rom_ready
	// happens to be asserted" (which would double/triple-count a single
	// transaction across its own wait-state cycles, and worse, count a
	// DIFFERENT number of times in simulation vs. real hardware since
	// real SDRAM latency differs from the behavioral sdram_model.sv
	// timing this project's own sim testbenches use — defeating the
	// entire point of comparing a real-hardware checksum against a
	// simulated reference value).
	//
	// Freezes after ROM_CSUM_TARGET reads (a fixed transaction count,
	// not a fixed cycle count) rather than accumulating forever, so a
	// real-hardware run (unpredictable wall-clock pacing) and a fixed-
	// clk_sys-cycle-budget simulation run can both reach the identical,
	// comparison-ready frozen value as long as the CPU's
	// own instruction stream — deterministic from cold reset, since it
	// depends only on ROM content and register logic, not real-time
	// events — hasn't yet diverged between the two environments for any
	// OTHER reason (e.g. a real timing-dependent bug elsewhere).
	localparam [15:0] ROM_CSUM_TARGET = 16'd4096;
	reg        dtackn_prev;
	reg [15:0] rom_csum;
	reg [15:0] rom_csum_count;
	reg        rom_csum_done;
	always @(posedge clk_sys) begin
		dtackn_prev <= DTACKn;
		if (reset) begin
			rom_csum       <= 16'd0;
			rom_csum_count <= 16'd0;
			rom_csum_done  <= 1'b0;
		end else if (dtackn_prev && !DTACKn && sel_rom && cpu_read && !rom_csum_done) begin
			rom_csum       <= {rom_csum[14:0], rom_csum[15]} ^ rom_dout;
			rom_csum_count <= rom_csum_count + 16'd1;
			if (rom_csum_count == ROM_CSUM_TARGET - 16'd1) rom_csum_done <= 1'b1;
		end
	end
	assign rom_csum_o       = rom_csum;
	assign rom_csum_count_o = rom_csum_count;
	assign rom_csum_done_o  = rom_csum_done;

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16) — address-line-swapped for the CPU-facing
	// path ONLY, and ONLY for tdragon2 (game_macross2=0 — see header).
	// Swapped form: mainram_addr_cpu[10]<-byte_addr[11] and
	// mainram_addr_cpu[7]<-byte_addr[8] (word-address bits 10/7 swapped,
	// i.e. byte_addr bits 11/8 since word_addr[k]=byte_addr[k+1]); every
	// other bit passes straight through. macross2 (game_macross2=1) has
	// no swap at all — plain byte_addr[15:1], matching macross2_map's own
	// lack of any override on this range.
	// ------------------------------------------------------------------
	// Two 8-bit lane arrays, not one 16-bit array with lane writes
	// (2026-09-10, NMK-10): with the CPU port coded as a read/write port
	// whose read returns the byte being written (Quartus's true-dual-port
	// template, see g_mainram_cpu_hw) Quartus 17 infers ONE M10K set in
	// BIDIR_DUAL_PORT mode — CPU port A, video port B. The 16-bit form
	// below (its byte-enable story still applies) got a simple-dual-port
	// set PLUS a second full copy for the video read, because its old-data
	// read-during-write cannot be met on one port; the same on bgvram (64
	// extra M10K) and txvram (4). raphero_core.sv has the synthesis test.
	reg [7:0] mainram_hi [0:32767];
	reg [7:0] mainram_lo [0:32767];
	wire [14:0] mainram_addr_cpu = (game_macross2 | game_powerins) ? byte_addr[15:1] :
		{byte_addr[15:12], byte_addr[8], byte_addr[10:9], byte_addr[11], byte_addr[7:1]};
	reg [15:0] mainram_dout;
	reg        mainram_ready;
	// HW_ROMS=1 only: registered (synchronous) CPU-side read, write
	// folded into the same always block as that read (one port, one
	// address), AND — the actually load-bearing fix, isolated by direct
	// testing below — each byte-lane write expressed as its own
	// top-level ANDed `if`, not nested inside a shared
	// "if (sel_mainram & cpu_write) begin if(~UDSn)...if(~LDSn)... end".
	// The nested form silently defeats Quartus's byte-enable RAM
	// inference: no "uninferred" diagnostic, nothing, just an ~524K-
	// flip-flop fallback (32768 x 16). Confirmed directly with a minimal
	// isolated repro at this exact 32768 depth: nested ifs (regardless
	// of port count — even reduced to a single write+read port, matching
	// the working sprite_plane idiom otherwise byte-for-byte) still fell
	// back to flip-flops; flattening to top-level ANDed ifs alone (same
	// single port) was sufficient to get real block RAM. The write
	// folded into the read's own port (as below) isn't required either,
	// but keeps mainram within Cyclone V's 2-independent-port-per-M10K
	// limit (CPU port + video port = 2) rather than 3, which is good
	// practice regardless. mainram_ready holds DTACKn off for the one
	// extra clk_sys cycle the registered read needs, mirroring
	// rom_wait/rom_ready's own existing mechanism (see DTACKn below).
	// HW_ROMS=0 (every existing sim testbench, unchanged): stays fully
	// combinational/zero-latency — the write-side text below is
	// byte-for-byte identical to what a plain always block outside any
	// generate would have contained.
	generate
	if (!HW_ROMS) begin : g_mainram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_mainram & cpu_write & ~sprite_dma_busy) begin
				if (~UDSn) mainram_hi[mainram_addr_cpu] <= oEdb[15:8];
				if (~LDSn) mainram_lo[mainram_addr_cpu] <= oEdb[7:0];
			end
		end
		always @(*) mainram_dout  = {mainram_hi[mainram_addr_cpu], mainram_lo[mainram_addr_cpu]};
		always @(*) mainram_ready = 1'b1;
	end else begin : g_mainram_cpu_hw
		// Write conditions flattened to top-level ANDed ifs, not nested
		// inside a shared "if (sel_mainram & cpu_write) begin ... end" —
		// confirmed directly (isolated repro, both at this array's real
		// 32768-depth and a fast 256-entry version): the nested form is
		// what was actually blocking RAM inference all along, regardless
		// of port count. Nested: 0 RAM segments, ~939K logic cells, no
		// diagnostic at all. Flattened, otherwise identical: real block
		// RAM, done in ~1 minute instead of ~50.
		// True-dual-port template (NMK-10): on a write the read register
		// takes the written byte (never consumed — a 68000 bus cycle is
		// read OR write), otherwise the array. Keep this exact shape.
		reg [14:0] mainram_addr_cpu_r;
		wire       we_hi = sel_mainram & cpu_write & ~UDSn & ~sprite_dma_busy;
		wire       we_lo = sel_mainram & cpu_write & ~LDSn & ~sprite_dma_busy;
		always @(posedge clk_sys) begin
			if (we_hi) begin mainram_hi[mainram_addr_cpu] <= oEdb[15:8]; mainram_dout[15:8] <= oEdb[15:8]; end
			else       mainram_dout[15:8] <= mainram_hi[mainram_addr_cpu];
			if (we_lo) begin mainram_lo[mainram_addr_cpu] <= oEdb[7:0];  mainram_dout[7:0]  <= oEdb[7:0];  end
			else       mainram_dout[7:0]  <= mainram_lo[mainram_addr_cpu];
			mainram_addr_cpu_r <= mainram_addr_cpu;
		end
		// Combinational on the registered address, not a registered flag:
		// the registered form is stale-high for the first clk_sys after the
		// address changes, which the 12 MHz powerins 68000 (enPhi2 one
		// clk_sys after enPhi1) can sample as DTACK — raphero_core.sv's
		// mainram_ready has the 14 MHz story. Same for bgvram/txvram below.
		always @(*) mainram_ready = (mainram_addr_cpu_r == mainram_addr_cpu);
	end
	endgenerate

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16)
	// ------------------------------------------------------------------
	// HW_ROMS=1: every read of this array is registered (CPU port here,
	// the two video taps below) so it infers as block RAM — one M10K pair
	// per read port — instead of 16K flip-flops behind three 1024:1
	// asynchronous muxes (NMK-10; raphero_core.sv has the same block).
	// CPU reads take one DTACK wait (palette_wait), the bgvram pattern.
	reg [15:0] palette [0:2047]; // 2048 for powerins (gfx_powerins: BG 0x000, TX 0x200, sprites 0x400-0x7FF); the other games decode only 0x000-0x3FF
	wire [10:0] palette_addr = byte_addr[11:1];
	reg [15:0] palette_dout;
	wire       palette_ready;
	generate
	if (!HW_ROMS) begin : g_palette_sim
		always @(posedge clk_sys) begin
			if (sel_palette & cpu_write) begin
				if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
				if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
			end
		end
		always @(*) palette_dout = palette[palette_addr];
		assign palette_ready = 1'b1;
	end else begin : g_palette_hw
		// Combinational ready on the registered address (raphero_core.sv's
		// mainram_ready explains why not a registered flag).
		reg [10:0] palette_addr_r;
		always @(posedge clk_sys) begin
			if (sel_palette & cpu_write & ~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
			if (sel_palette & cpu_write & ~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
			palette_dout   <= palette[palette_addr];
			palette_addr_r <= palette_addr;
		end
		assign palette_ready = (palette_addr_r == palette_addr);
	end
	endgenerate

	// ------------------------------------------------------------------
	// BG tilemap VRAM (32768 x 16)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port CPU port, as mainram above (NMK-10).
	reg [7:0] bgvram_hi [0:32767];
	reg [7:0] bgvram_lo [0:32767];
	wire [14:0] bgvram_addr = byte_addr[15:1];
	// Same reasoning/mechanism as mainram above — CPU write folded into
	// the same always block as the CPU read, keeping bgvram within
	// Cyclone V's 2-independent-port-per-M10K limit (CPU port + video
	// port).
	wire [15:0] bgvram_dout;
	reg  [15:0] bgvram_dout_r;
	reg         bgvram_ready;
	generate
	if (!HW_ROMS) begin : g_bgvram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_bgvram & cpu_write) begin
				if (~UDSn) bgvram_hi[bgvram_addr] <= oEdb[15:8];
				if (~LDSn) bgvram_lo[bgvram_addr] <= oEdb[7:0];
			end
		end
		assign bgvram_dout = {bgvram_hi[bgvram_addr], bgvram_lo[bgvram_addr]};
		always @(*) bgvram_ready = 1'b1;
	end else begin : g_bgvram_cpu_hw
		// Same flattened-condition fix as mainram above — see its own
		// comment for the full story — in the true-dual-port shape.
		reg [14:0] bgvram_addr_r;
		wire       we_hi = sel_bgvram & cpu_write & ~UDSn;
		wire       we_lo = sel_bgvram & cpu_write & ~LDSn;
		always @(posedge clk_sys) begin
			if (we_hi) begin bgvram_hi[bgvram_addr] <= oEdb[15:8]; bgvram_dout_r[15:8] <= oEdb[15:8]; end
			else       bgvram_dout_r[15:8] <= bgvram_hi[bgvram_addr];
			if (we_lo) begin bgvram_lo[bgvram_addr] <= oEdb[7:0];  bgvram_dout_r[7:0]  <= oEdb[7:0];  end
			else       bgvram_dout_r[7:0]  <= bgvram_lo[bgvram_addr];
			bgvram_addr_r <= bgvram_addr;
		end
		always @(*) bgvram_ready = (bgvram_addr_r == bgvram_addr); // see mainram_ready
		assign bgvram_dout = bgvram_dout_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// TX tilemap VRAM (2048 x 16)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port CPU port, as mainram above (NMK-10).
	reg [7:0] txvram_hi [0:2047];
	reg [7:0] txvram_lo [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	// Despite its modest 32,768-bit storage, an asynchronous read of a
	// 2048-entry array still costs real logic: Quartus's own multiplexer
	// restructuring reported a bare "2048:1" mux for this exact
	// combinational read at 16,380 LEs — comparable to sprite_plane's
	// own footprint before ITS fix, just spent on read-select logic
	// instead of storage registers. Same fix, same reasoning as mainram/
	// bgvram above (registered read + write folded into the same
	// always block, flattened byte-enable ifs — see mainram's own
	// comment for the full byte-enable story).
	wire [15:0] txvram_dout;
	reg  [15:0] txvram_dout_r;
	reg         txvram_ready;
	generate
	if (!HW_ROMS) begin : g_txvram_cpu_sim
		always @(posedge clk_sys) begin
			if (sel_txvram & cpu_write) begin
				if (~UDSn) txvram_hi[txvram_addr] <= oEdb[15:8];
				if (~LDSn) txvram_lo[txvram_addr] <= oEdb[7:0];
			end
		end
		assign txvram_dout = {txvram_hi[txvram_addr], txvram_lo[txvram_addr]};
		always @(*) txvram_ready = 1'b1;
	end else begin : g_txvram_cpu_hw
		reg [10:0] txvram_addr_r;
		wire       we_hi = sel_txvram & cpu_write & ~UDSn;
		wire       we_lo = sel_txvram & cpu_write & ~LDSn;
		always @(posedge clk_sys) begin
			if (we_hi) begin txvram_hi[txvram_addr] <= oEdb[15:8]; txvram_dout_r[15:8] <= oEdb[15:8]; end
			else       txvram_dout_r[15:8] <= txvram_hi[txvram_addr];
			if (we_lo) begin txvram_lo[txvram_addr] <= oEdb[7:0];  txvram_dout_r[7:0]  <= oEdb[7:0];  end
			else       txvram_dout_r[7:0]  <= txvram_lo[txvram_addr];
			txvram_addr_r <= txvram_addr;
		end
		always @(*) txvram_ready = (txvram_addr_r == txvram_addr); // see mainram_ready
		assign txvram_dout = txvram_dout_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Dual-port video read taps (video_macross2.sv's own live reads).
	// vid_mainram_addr/dout is DELIBERATELY UNSWAPPED — see header
	// ("Difference 1"): it mirrors MAME's own raw sprite_dma() memcpy,
	// which bypasses the swapped bus handler entirely.
	// ------------------------------------------------------------------
	wire [14:0] vid_bgvram_addr;
	wire [15:0] vid_bgvram_dout;
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout;
	wire [10:0] vid_palette_addr;
	wire [15:0] vid_palette_dout;
	wire [10:0] vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout;
	generate
	if (!HW_ROMS) begin : g_vidpal_sim
		assign vid_palette_dout     = palette[vid_palette_addr];
		assign vid_spr_palette_dout = palette[vid_spr_palette_addr];
	end else begin : g_vidpal_hw
		// Registered reads — video_macross2.sv's HW_ROMS=1 palette-tap
		// contract (one clock behind the address); see the palette block.
		reg [15:0] vid_palette_dout_r, vid_spr_palette_dout_r;
		always @(posedge clk_sys) begin
			vid_palette_dout_r     <= palette[vid_palette_addr];
			vid_spr_palette_dout_r <= palette[vid_spr_palette_addr];
		end
		assign vid_palette_dout     = vid_palette_dout_r;
		assign vid_spr_palette_dout = vid_spr_palette_dout_r;
	end
	endgenerate
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout;
	wire        vid_mainram_ready;

	// HW_ROMS=1 only: registered (synchronous) reads on both video-side
	// dual-port taps, needed for the SAME RAM-inference reason as the
	// CPU-side ports above (both ports of a shared array must be
	// synchronous, or Quartus won't infer real block RAM for any of it).
	// bgvram_addr only changes once per 16-pixel tile column in
	// video_macross2.sv's own combinational chain, so the 1-cycle lag
	// this introduces self-resolves within that same tile — a rare,
	// single-pixel-at-the-tile-boundary artifact, the same class already
	// accepted (and documented) for external bgtile ROM cache misses, so
	// no further change is needed in video_macross2.sv itself for BG.
	// mainram, by contrast, is read every cycle by the sprite-snapshot
	// FSM (S_SNAP_REQ/S_SNAP_WAIT/S_SNAP_LATCH) with byte-exact
	// requirements — that FSM now blocks on vid_mainram_ready (mirrors
	// sprites_ready/S_SPR_WAIT) via video_macross2's own mainram_ready
	// port instead. txvram_addr is tile-quantized (once per 8-pixel TX
	// column) same as bgvram, same tolerance applies.
	generate
	if (!HW_ROMS) begin : g_vidram_read_sim
		assign vid_bgvram_dout  = {bgvram_hi[vid_bgvram_addr],   bgvram_lo[vid_bgvram_addr]};
		assign vid_txvram_dout  = {txvram_hi[vid_txvram_addr],   txvram_lo[vid_txvram_addr]};
		assign vid_mainram_dout = {mainram_hi[vid_mainram_addr], mainram_lo[vid_mainram_addr]};
		assign vid_mainram_ready = 1'b1;
	end else begin : g_vidram_read_hw
		reg [15:0] vid_bgvram_dout_r, vid_txvram_dout_r, vid_mainram_dout_r;
		reg [14:0] vid_mainram_addr_r;
		reg        vid_mainram_ready_r;
		always @(posedge clk_sys) begin
			vid_bgvram_dout_r   <= {bgvram_hi[vid_bgvram_addr],   bgvram_lo[vid_bgvram_addr]};
			vid_txvram_dout_r   <= {txvram_hi[vid_txvram_addr],   txvram_lo[vid_txvram_addr]};
			vid_mainram_dout_r  <= {mainram_hi[vid_mainram_addr], mainram_lo[vid_mainram_addr]};
			vid_mainram_addr_r  <= vid_mainram_addr;
			vid_mainram_ready_r <= (vid_mainram_addr_r == vid_mainram_addr);
		end
		assign vid_bgvram_dout   = vid_bgvram_dout_r;
		assign vid_txvram_dout   = vid_txvram_dout_r;
		assign vid_mainram_dout  = vid_mainram_dout_r;
		assign vid_mainram_ready = vid_mainram_ready_r;
	end
	endgenerate

	// dbg_* taps are a testbench-only third read port (TB_DUMP_VRAM) —
	// not wired to anything in the real hardware top (Macross2.sv), and
	// a third port would complicate dual-port RAM inference for no
	// benefit, so they're tied off at HW_ROMS=1 instead of adding real
	// read logic for them.
	generate
	if (!HW_ROMS) begin : g_dbgram_sim
		assign dbg_pal_data = palette[dbg_pal_addr];
		assign dbg_bgvram_data = {bgvram_hi[dbg_bgvram_addr[14:0]], bgvram_lo[dbg_bgvram_addr[14:0]]};
		assign dbg_txvram_data = {txvram_hi[dbg_txvram_addr], txvram_lo[dbg_txvram_addr]};
	end else begin : g_dbgram_hw
		assign dbg_pal_data = 16'd0;
		assign dbg_bgvram_data = 16'd0;
		assign dbg_txvram_data = 16'd0;
	end
	endgenerate

	// ------------------------------------------------------------------
	// I/O registers — identical to macross2_core.sv's own.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg        z80_reset_n_reg;

	reg [7:0] scroll_reg [0:3];
	wire [1:0] scroll_word_idx = byte_addr[2:1];
	wire [15:0] bg_xscroll = {scroll_reg[0], scroll_reg[1]};
	wire [15:0] bg_yscroll = {scroll_reg[2], scroll_reg[3]};

	reg [1:0] tilerambank_reg;
	wire sel_scroll_off0 = sel_scroll & (scroll_word_idx == 2'd0);

	integer si;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			z80_reset_n_reg <= 1'b0; // held in reset until the 68000 releases it
			tilerambank_reg <= 2'd0;
			for (si = 0; si < 4; si = si + 1) scroll_reg[si] <= 8'h00;
		end else if (cpu_write) begin
			if (sel_flip & ~LDSn)     flip_screen_reg <= oEdb[7:0];
			if (sel_tilebank & ~LDSn) bgbank_reg      <= oEdb[7:0];
			if (sel_scroll & ~LDSn) begin
				scroll_reg[scroll_word_idx] <= oEdb[7:0];
				if (sel_scroll_off0 & ~game_powerins) tilerambank_reg <= oEdb[5:4]; // powerins: plain scroll_w<0>, one 8192-word VRAM, no bank
			end
			if (sel_sndreset)         z80_reset_n_reg <= (oEdb != 16'h0000);
		end
	end


	// ------------------------------------------------------------------
	// soundlatch (68000->Z80, main2sub) / soundlatch2 (Z80->68000,
	// sub2main) — plain polling registers, no interrupt side effect.
	// ------------------------------------------------------------------
	reg [7:0] soundlatch_data;
	reg [7:0] soundlatch2_data;

	always @(posedge clk_sys) begin
		if (reset) soundlatch_data <= 8'h00;
		else if (sel_soundlatch_w & cpu_write & ~LDSn) soundlatch_data <= oEdb[7:0];
	end

	// ------------------------------------------------------------------
	// Z80 sound board: T80 + jt03 (YM2203) + NMK112 + jt6295 x2 (OKI)
	// ------------------------------------------------------------------
	wire [15:0] z80_a;
	wire [7:0]  z80_do;
	wire [7:0]  z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
	wire        z80_int_n;

	assign z80_int_n = ym_chip_irq_n;
	wire z80_reset_n = ~reset & (z80_reset_n_reg | game_powerins); // powerins: no 68000-driven Z80 reset (0x100016 is a nopw)

	T80s z80_cpu (
		.RESET_n(z80_reset_n),
		.CLK(clk_sys),
		.CEN(z80_cen),
		.WAIT_n(z80_wait_n),
		.INT_n(z80_int_n),
		.NMI_n(1'b1),
		.BUSRQ_n(1'b1),
		.OUT0(1'b0),
		.DI(z80_di),
		.M1_n(z80_m1_n),
		.MREQ_n(z80_mreq_n),
		.IORQ_n(z80_iorq_n),
		.RD_n(z80_rd_n),
		.WR_n(z80_wr_n),
		.RFSH_n(z80_rfsh_n),
		.HALT_n(z80_halt_n),
		.BUSAK_n(z80_busak_n),
		.A(z80_a),
		.DO(z80_do)
	);

	wire z80_mem_we = ~z80_mreq_n & ~z80_wr_n;
	wire z80_mem_re = ~z80_mreq_n & ~z80_rd_n;
	wire z80_io_we = ~z80_iorq_n & ~z80_wr_n;
	wire z80_io_re = ~z80_iorq_n & ~z80_rd_n;

	// powerins_sound_map (nmk16.cpp:1219): 0000-BFFF flat ROM (no bank
	// register, no A000 hole), C000-DFFF RAM, E000 soundlatch read; no
	// soundlatch2 and E001 is a nop (the driver writes it once).
	wire sel_z80_rom   = game_powerins ? (z80_a < 16'hC000) : (z80_a < 16'h8000);
	wire sel_z80_nopr  = ~game_powerins & (z80_a == 16'hA000);
	wire sel_z80_bank  = ~game_powerins & (z80_a >= 16'h8000) && (z80_a < 16'hC000) && !sel_z80_nopr;
	wire sel_z80_ram   = (z80_a >= 16'hC000) && (z80_a < 16'hE000);
	wire sel_z80_soundlatch2_w = ~game_powerins & z80_mem_we & (z80_a == 16'hF000);
	wire sel_z80_soundlatch_r  = (z80_a == (game_powerins ? 16'hE000 : 16'hF000));

	wire sel_mem_audiobank_w = ~game_powerins & z80_mem_we & (z80_a == 16'hE001);

	wire sel_io_ym_addr = (z80_a[7:0] == 8'h00);
	wire sel_io_ym_data = (z80_a[7:0] == 8'h01);
	wire sel_io_ym      = sel_io_ym_addr | sel_io_ym_data;
	wire sel_io_oki0    = (z80_a[7:0] == 8'h80);
	wire sel_io_oki1    = (z80_a[7:0] == 8'h88);
	wire sel_io_nmk112  = (z80_a[7:0] >= 8'h90) && (z80_a[7:0] <= 8'h97);

	// Absolute byte offsets within the shared 32MB SDRAM address space
	// this game's ioctl-download stream is laid out at — see
	// docs/hw-bringup.md's table. Word offset = byte offset / 2.
	// Byte offsets are 24-bit values: a 23-bit literal silently drops
	// bit 23, which put OKI2 (0x8C0000) at 0x0C0000 — the BG tile region —
	// so that chip decoded tile graphics as ADPCM in every build until
	// 2026-09-08 (docs/hw-bringup.md, "Sound effects corrupted").
	//
	// Two layouts, selected at runtime (the caches take their base as an
	// input since 2026-09-11):
	//   tdragon2/macross2: maincpu 0x000000 (512 KB), audiocpu 0x080000,
	//     fgtile 0x0A0000, bgtile 0x0C0000, sprites 0x2C0000 (4 MB),
	//     oki1 0x6C0000, oki2 0x8C0000 (2 MB each) — end 0xAC0000.
	//   powerins: maincpu 0x000000 (1 MB), audiocpu 0x100000 (128 KB),
	//     fgtile 0x120000 (128 KB), bgtile 0x140000 (0x280000),
	//     sprites 0x3C0000 (8 MB), oki1 0xBC0000, oki2 0xDC0000 (2 MB
	//     each) — end 0xFC0000. The .mra <part> order must match.
	wire [22:0] BASE_WORD_AUDIOCPU = game_powerins ? 23'h080000 : 23'h040000;
	wire [22:0] BASE_WORD_FGTILE   = game_powerins ? 23'h090000 : 23'h050000;
	wire [22:0] BASE_WORD_BGTILE   = game_powerins ? 23'h0A0000 : 23'h060000;
	wire [22:0] BASE_WORD_SPRITES  = game_powerins ? 23'h1E0000 : 23'h160000;
	wire [22:0] BASE_WORD_OKI1     = game_powerins ? 23'h5E0000 : 23'h360000;
	wire [22:0] BASE_WORD_OKI2     = game_powerins ? 23'h6E0000 : 23'h460000;

	wire [7:0] audiocpu_dout;
	wire       audiocpu_ready;
	// HW_ROMS=1 only: hold the Z80 with WAIT asserted while a real ROM
	// fetch is outstanding (audiocpu_ready tied to 1'b1 at HW_ROMS=0, so
	// this reduces to the original always-1 WAIT_n exactly).
	wire z80_wait_n = ~((sel_z80_rom | sel_z80_bank) & z80_mem_re & ~audiocpu_ready);
	// Same guard for the Z80's byte cache: only ROM/bank-window addresses
	// reach it (RAM/latch accesses used to start speculative fetches of
	// bank-window words that could land mid-fetch).
	wire        z80_rom_sel = sel_z80_rom | sel_z80_bank;
	wire [23:0] audiocpu_byte_addr_live = sel_z80_rom ? {8'd0, z80_a[15:0]} : {7'd0, z80_bank_phys[16:0]}; // sel_z80_rom implies a[15]=0 except in the powerins mode (flat 48 KB)
	reg  [23:0] audiocpu_byte_addr_held;
	always @(posedge clk_sys) if (z80_rom_sel) audiocpu_byte_addr_held <= audiocpu_byte_addr_live;
	wire [23:0] audiocpu_byte_addr = z80_rom_sel ? audiocpu_byte_addr_live : audiocpu_byte_addr_held;
	// SDRAM port 1 is shared three ways — Z80 program ROM (channel 0) and
	// the two OKI sample ROMs (channels 1-2, whose caches live in g_oki_hw
	// further down and reach the arbiter here through these module-level
	// arrays). All three are low-bandwidth. See the port comments above:
	// the OKIs used to own port 3, which the TX-tile/sprite fetch needs.
	wire        p1_busy [0:3];
	wire        p1_valid[0:3];
	wire [24:1] p1_addr [0:3];
	wire        p1_req  [0:3];
	wire [15:0] p1_dout [0:3];
	wire [31:0] p1_dout_pair [0:3];
	generate
	if (!HW_ROMS) begin : g_audiocpu_sim
		reg [7:0] audiocpu_rom [0:131071];
		initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, audiocpu_rom);
		assign audiocpu_dout  = audiocpu_rom[audiocpu_byte_addr[16:0]];
		assign audiocpu_ready = 1'b1;
		assign sd3_addr = 24'd0; assign sd3_req = 1'b0;
		assign p1_busy  = '{1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_valid = '{1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_dout  = '{16'd0, 16'd0, 16'd0, 16'd0};
		assign p1_dout_pair = '{32'd0, 32'd0, 32'd0, 32'd0};
		// channel 0 (TX prefetch) is driven by the video module's txc_* outputs
		assign p1_addr[1] = 24'd0; assign p1_addr[2] = 24'd0; assign p1_addr[3] = 24'd0;
		// channel 0 (TX prefetch) is driven by the video module's txc_* outputs
		assign p1_req[1] = 1'b0; assign p1_req[2] = 1'b0; assign p1_req[3] = 1'b0;
	end else begin : g_audiocpu_hw
		// Physical port 3: channel 0 is the video module's TX prefetch
		// stream (top priority, it is real-time), the sound consumers
		// follow. The sprite fetch has physical port 1 to itself (video
		// sd_b_*) — see video_macross2.sv TX_EXTERNAL.
		sdram_arb #(.N(4), .FIXED_PRIO(1)) p1_arb_inst (
			.clk(clk_sys), .reset(por_rst),
			.i_addr(p1_addr), .i_we('{1'b0, 1'b0, 1'b0, 1'b0}), .i_wrl('{1'b0, 1'b0, 1'b0, 1'b0}), .i_wrh('{1'b0, 1'b0, 1'b0, 1'b0}), .i_din('{16'd0, 16'd0, 16'd0, 16'd0}),
			.i_req(p1_req), .i_busy(p1_busy), .i_valid(p1_valid), .i_dout(p1_dout), .i_dout_pair(p1_dout_pair),
			.sdram_addr(sd3_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
			.sdram_dout(sd3_dout), .sdram_dout_pair(sd3_dout_pair), .sdram_req(sd3_req), .sdram_ack(sd3_ack)
		);
		rom_cache1_byte audiocpu_cache_inst (
			.base_word(BASE_WORD_AUDIOCPU),
			.clk(clk_sys), .reset(reset),
			.byte_addr(audiocpu_byte_addr), .data(audiocpu_dout), .ready(audiocpu_ready),
			.sd_addr(p1_addr[1]), .sd_req(p1_req[1]), .sd_busy(p1_busy[1]), .sd_valid(p1_valid[1]), .sd_dout(p1_dout[1]), .sd_dout_pair(p1_dout_pair[1])
		);
	end
	endgenerate

	reg [2:0] audiobank_reg;
	always @(posedge clk_sys) begin
		if (~z80_reset_n) audiobank_reg <= 3'd0;
		else if (sel_mem_audiobank_w) audiobank_reg <= z80_do[2:0]; // macross2_audiobank_w
	end

	reg [7:0] z80_ram [0:8191];
	always @(posedge clk_sys) if (sel_z80_ram & z80_mem_we) z80_ram[z80_a[12:0]] <= z80_do;

	wire [16:0] z80_bank_phys = {audiobank_reg, 14'd0} + {3'd0, z80_a[13:0]};

	always @(posedge clk_sys) begin
		if (~z80_reset_n) soundlatch2_data <= 8'h00;
		else if (sel_z80_soundlatch2_w) soundlatch2_data <= z80_do;
	end

	// ------------------------------------------------------------------
	// YM2203 — real jt03. Same write-stretch pattern as macross2_core.sv's
	// own (40-cycle hold, safely exceeding ym_cen's own 27-cycle worst-case
	// gap).
	// ------------------------------------------------------------------
	reg [7:0] ym_din_latch;
	reg       ym_addr_latch;
	reg [5:0] ym_wr_hold = 6'd0;
	reg       ym_we_prev = 1'b0;
	wire      ym_we_raw = z80_io_we & sel_io_ym;
	always @(posedge clk_sys) begin
		ym_we_prev <= ym_we_raw;
		if (ym_we_raw && !ym_we_prev) begin
			ym_din_latch  <= z80_do;
			ym_addr_latch <= sel_io_ym_data;
			ym_wr_hold    <= 6'd40;
		end else if (ym_wr_hold != 6'd0) begin
			ym_wr_hold <= ym_wr_hold - 6'd1;
		end
	end
	wire ym_wr_n = ~(ym_wr_hold != 6'd0);
	// jt03 has no separate read-strobe input — dout always reflects whatever
	// addr currently holds, so a status/busy read must see the live port
	// decode, not the write-only latch (which would still show the previous
	// write's offset, e.g. after a data-port write, breaking busy-flag polls).
	// Fall back to the latched value only while a write-stretch is in flight,
	// since ym_din_latch itself is only valid for that same window.
	wire ym_addr_sel = (ym_wr_hold != 6'd0) ? ym_addr_latch : sel_io_ym_data;

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	wire signed [15:0] ym_snd;
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_sel), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(dbg_fm_snd), .psg_snd(dbg_psg_snd), .snd(ym_snd), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// NMK112 — see rtl/nmk112/nmk112.sv's own header. ROM1_BYTES fixed at
	// tdragon2's own (larger) 0x200000 unconditionally, serving macross2
	// too (its own oki2 is half that, 0x100000, but the wider mask is
	// provably harmless — see this file's own header for the derivation;
	// no game_macross2 toggle needed here).
	// ------------------------------------------------------------------
	wire nmk112_we = z80_io_we & sel_io_nmk112;
	wire [17:0] oki0_rom_addr_raw, oki1_rom_addr_raw;
	wire [21:0] oki0_rom_addr, oki1_rom_addr;
	// "A gated OKI cen is passing this clock" — a bank write landing on
	// this edge would change the remapped address inside jt6295's
	// registered-cen latch window (rtl/nmk112.sv `hold`, NMK-15). Assigned
	// below, after the stall wires exist.
	wire nmk112_hold;

	nmk112 #(
		.ROM0_BYTES(2097152), // ww930916.4 / bp932an.a06, 0x200000 (oki1, same both games)
		.ROM1_BYTES(2097152)  // ww930915.3, 0x200000 (oki2 — macross2's own bp932an.a05 is half this; harmless, see header)
	) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(z80_a[2:0]), .reg_data(z80_do), .reg_we(nmk112_we), .hold(nmk112_hold),
		.rom0_addr_in(oki0_rom_addr_raw), .rom0_addr_out(oki0_rom_addr),
		.rom1_addr_in(oki1_rom_addr_raw), .rom1_addr_out(oki1_rom_addr)
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, driven by the Z80's own I/O bus through
	// NMK112. oki1_rom (chip 1 / MAME tag "oki2") is sized 0x200000/
	// 21-bit-addressed for both games (macross2's own real chip is half
	// that — harmless, see header); its own OKI2_ROM_FILE simply loads
	// into the low half when macross2's own smaller image is used.
	// ------------------------------------------------------------------
	// HW_ROMS=0: unchanged sim arrays (jt6295's own rom_ok tied to 1'b1
	// below, matching the original design exactly). HW_ROMS=1: both OKI
	// sample ROMs share SDRAM port 3 through a 2-way rom_cache1/
	// sdram_arb, with jt6295's own real rom_ok/rom_data wait-state
	// protocol driven for real (see docs/hw-bringup.md — verified this
	// is a genuine, effectively-unbounded wait, not a fixed few-cycle
	// deadline, by reading rtl/third_party/jt6295/hdl/jt6295_rom.v
	// directly: once its own internal wait2 counter saturates, it
	// re-samples rom_ok/rom_data every single cycle thereafter for as
	// long as its own ctrl_addr stays stable).
	wire [7:0] oki0_rom_data, oki1_rom_data;
	wire       oki0_rom_ok, oki1_rom_ok;
	wire       oki0_stall, oki1_stall;   // HW path: sample byte not resident yet — hold the chip's cen
	assign nmk112_hold = oki_cen & (~oki0_stall | ~oki1_stall);
	generate
	if (!HW_ROMS) begin : g_oki_sim
		reg [7:0] oki0_rom [0:2097151]; // ww930916.4 / bp932an.a06, 0x200000
		reg [7:0] oki1_rom [0:2097151]; // ww930915.3, 0x200000 (macross2's own bp932an.a05 is 0x100000 — loads into the low half)
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki0_rom);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki1_rom);
		reg [7:0] oki0_rom_data_r, oki1_rom_data_r;
		always @(posedge clk_sys) oki0_rom_data_r <= oki0_rom[oki0_rom_addr[20:0]];
		always @(posedge clk_sys) oki1_rom_data_r <= oki1_rom[oki1_rom_addr[20:0]];
		assign oki0_rom_data = oki0_rom_data_r;
		assign oki1_rom_data = oki1_rom_data_r;
		assign oki0_rom_ok = 1'b1;
		assign oki1_rom_ok = 1'b1;
		assign oki0_stall = 1'b0;
		assign oki1_stall = 1'b0;
		assign dbg_oki0_adpcm_total = 32'd0; assign dbg_oki0_adpcm_unserved = 32'd0;
		assign dbg_oki1_adpcm_total = 32'd0; assign dbg_oki1_adpcm_unserved = 32'd0;
		assign dbg_oki_cen_total = 32'd0; assign dbg_oki0_stall_cen = 32'd0; assign dbg_oki1_stall_cen = 32'd0;
	end else begin : g_oki_hw
		// Channels 1 and 2 of SDRAM port 1's arbiter (g_audiocpu_hw above).
		// oki_rom_cache, not rom_cache1_byte: jt6295's ADPCM fetch ignores
		// rom_ok, so the sample byte has to be resident when the chip
		// latches it (multi-line + sequential prefetch), and when it is
		// not, `stall` freezes the chip's cen until it is — see
		// rtl/oki_rom_cache.sv's header and docs/hw-bringup.md.
		oki_rom_cache oki0_cache_inst (
			.base_word(BASE_WORD_OKI1),
			.clk(clk_sys), .reset(reset),
			.byte_addr(oki0_rom_addr), .data(oki0_rom_data), .ready(oki0_rom_ok), .stall(oki0_stall),
			.sd_addr(p1_addr[2]), .sd_req(p1_req[2]), .sd_busy(p1_busy[2]), .sd_valid(p1_valid[2]), .sd_dout(p1_dout[2]), .sd_dout_pair(p1_dout_pair[2])
		);
		oki_rom_cache oki1_cache_inst (
			.base_word(BASE_WORD_OKI2),
			.clk(clk_sys), .reset(reset),
			.byte_addr(oki1_rom_addr), .data(oki1_rom_data), .ready(oki1_rom_ok), .stall(oki1_stall),
			.sd_addr(p1_addr[3]), .sd_req(p1_req[3]), .sd_busy(p1_busy[3]), .sd_valid(p1_valid[3]), .sd_dout(p1_dout[3]), .sd_dout_pair(p1_dout_pair[3])
		);
`ifdef VERILATOR
		// Audit of jt6295's ADPCM sample fetch, which (jt6295_rom.v) never
		// consults rom_ok: it presents adpcm_addr for two cen_sr32 slots
		// and keeps the value of rom_data seen on the last clock of the
		// second slot (st == 8'h02, cen32 about to advance it). Count how
		// often the cache had NOT yet delivered that byte at that instant —
		// each such event feeds the decoder a stale byte from the previous
		// line. Sim-only: hierarchical references into the vendored chip.
		reg [31:0] oki0_adpcm_total_r = 32'd0, oki0_adpcm_unserved_r = 32'd0;
		reg [31:0] oki1_adpcm_total_r = 32'd0, oki1_adpcm_unserved_r = 32'd0;
		reg [31:0] oki_cen_total_r = 32'd0, oki0_stall_cen_r = 32'd0, oki1_stall_cen_r = 32'd0;
		// Extra diagnostics printed via $display at the end of the run
		// (see tb): fetch/prefetch/miss-event counts and longest stall.
		// OKI_CACHE_DIAG is defined only by the HW-path sim Makefiles: the
		// hierarchical references into oki0_cache_inst below do not
		// elaborate in an HW_ROMS=0 build, where g_oki_hw does not exist.
`ifdef OKI_CACHE_DIAG
		reg [31:0] oki0_fetches = 32'd0, oki0_prefetches = 32'd0, oki0_miss_events = 32'd0, oki0_stall_len = 32'd0, oki0_stall_max = 32'd0;
		reg        oki0_pending_d = 1'b0, oki0_stall_d = 1'b0;
		reg [31:0] oki0_addr_changes = 32'd0;
		reg [21:0] oki0_addr_d = 22'd0;
		always @(posedge clk_sys) begin
			oki0_pending_d <= oki0_cache_inst.pending;
			oki0_stall_d   <= oki0_stall;
			oki0_addr_d    <= oki0_rom_addr;
			if (oki0_rom_addr != oki0_addr_d) oki0_addr_changes <= oki0_addr_changes + 32'd1;
			if (oki0_cache_inst.pending && !oki0_pending_d) begin
				oki0_fetches <= oki0_fetches + 32'd1;
				if (oki0_cache_inst.req_is_prefetch) oki0_prefetches <= oki0_prefetches + 32'd1;
			end
			if (oki0_stall && !oki0_stall_d) oki0_miss_events <= oki0_miss_events + 32'd1;
			if (oki0_stall) begin
				oki0_stall_len <= oki0_stall_len + 32'd1;
				if (oki0_stall_len + 32'd1 > oki0_stall_max) oki0_stall_max <= oki0_stall_len + 32'd1;
			end else oki0_stall_len <= 32'd0;
		end
		final $display("OKI0 cache diag: addr changes %0d, fetches %0d (prefetch %0d), miss events %0d, longest stall %0d clk",
			oki0_addr_changes, oki0_fetches, oki0_prefetches, oki0_miss_events, oki0_stall_max);
`endif
		// Golden-byte audit: when OKI1_ROM_FILE/OKI2_ROM_FILE are given to
		// an HW_ROMS=1 build (the tdragon2_hw top does), every sample byte
		// the chip latches is compared with the plain ROM image.
		reg [7:0] golden0 [0:2097151];
		reg [7:0] golden1 [0:2097151];
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, golden0);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, golden1);
		reg [31:0] oki0_bytes_wrong = 32'd0, oki1_bytes_wrong = 32'd0, oki0_bytes_checked = 32'd0;
		always @(posedge clk_sys) begin
			if (OKI1_ROM_FILE != "" && oki0_chip.u_rom.st == 8'h02 && oki0_chip.u_rom.cen32) begin
				oki0_bytes_checked <= oki0_bytes_checked + 32'd1;
				if (oki0_rom_data != golden0[oki0_rom_addr[20:0]]) oki0_bytes_wrong <= oki0_bytes_wrong + 32'd1;
			end
			if (OKI2_ROM_FILE != "" && oki1_chip.u_rom.st == 8'h02 && oki1_chip.u_rom.cen32) begin
				if (oki1_rom_data != golden1[oki1_rom_addr[20:0]]) begin
					oki1_bytes_wrong <= oki1_bytes_wrong + 32'd1;
					if (oki1_bytes_wrong < 32'd6 || oki1_bytes_wrong[16:0] == 17'd0)
						$display("[%0t] OKI1 wrong byte: addr=%06x raw=%05x got=%02x golden=%02x ready=%0d (count %0d)", $time,
							oki1_rom_addr, oki1_rom_addr_raw, oki1_rom_data, golden1[oki1_rom_addr[20:0]], oki1_rom_ok, oki1_bytes_wrong);
				end
			end
			if (OKI1_ROM_FILE != "" && oki0_chip.u_rom.st == 8'h02 && oki0_chip.u_rom.cen32 && oki0_bytes_checked[18:0] == 19'd0)
				$display("[%0t] OKI0 sample: addr=%06x got=%02x golden=%02x", $time, oki0_rom_addr, oki0_rom_data, golden0[oki0_rom_addr[20:0]]);
		end
		final $display("OKI golden-byte audit: %0d sample latches checked, wrong bytes oki0 %0d, oki1 %0d",
			oki0_bytes_checked, oki0_bytes_wrong, oki1_bytes_wrong);
		always @(posedge clk_sys) begin
			if (oki_cen) begin
				oki_cen_total_r <= oki_cen_total_r + 32'd1;
				if (oki0_stall) oki0_stall_cen_r <= oki0_stall_cen_r + 32'd1;
				if (oki1_stall) oki1_stall_cen_r <= oki1_stall_cen_r + 32'd1;
			end
			if (oki0_chip.u_rom.st == 8'h02 && oki0_chip.u_rom.cen32) begin
				oki0_adpcm_total_r <= oki0_adpcm_total_r + 32'd1;
				if (!oki0_rom_ok) oki0_adpcm_unserved_r <= oki0_adpcm_unserved_r + 32'd1;
			end
			if (oki1_chip.u_rom.st == 8'h02 && oki1_chip.u_rom.cen32) begin
				oki1_adpcm_total_r <= oki1_adpcm_total_r + 32'd1;
				if (!oki1_rom_ok) oki1_adpcm_unserved_r <= oki1_adpcm_unserved_r + 32'd1;
			end
		end
		assign dbg_oki0_adpcm_total = oki0_adpcm_total_r; assign dbg_oki0_adpcm_unserved = oki0_adpcm_unserved_r;
		assign dbg_oki1_adpcm_total = oki1_adpcm_total_r; assign dbg_oki1_adpcm_unserved = oki1_adpcm_unserved_r;
		assign dbg_oki_cen_total = oki_cen_total_r; assign dbg_oki0_stall_cen = oki0_stall_cen_r; assign dbg_oki1_stall_cen = oki1_stall_cen_r;
`else
		assign dbg_oki0_adpcm_total = 32'd0; assign dbg_oki0_adpcm_unserved = 32'd0;
		assign dbg_oki1_adpcm_total = 32'd0; assign dbg_oki1_adpcm_unserved = 32'd0;
		assign dbg_oki_cen_total = 32'd0; assign dbg_oki0_stall_cen = 32'd0; assign dbg_oki1_stall_cen = 32'd0;
`endif
	end
	endgenerate

	wire sel_oki0_we = z80_io_we & sel_io_oki0;
	wire sel_oki1_we = z80_io_we & sel_io_oki1;
	reg [7:0] oki0_din_latch, oki1_din_latch;
	reg [5:0] oki0_wr_hold = 6'd0, oki1_wr_hold = 6'd0;
	reg       oki0_we_prev = 1'b0, oki1_we_prev = 1'b0;
	always @(posedge clk_sys) begin
		oki0_we_prev <= sel_oki0_we;
		if (sel_oki0_we && !oki0_we_prev) begin
			oki0_din_latch <= z80_do;
			oki0_wr_hold   <= 6'd40;
		end else if (oki0_wr_hold != 6'd0) begin
			oki0_wr_hold <= oki0_wr_hold - 6'd1;
		end
	end
	always @(posedge clk_sys) begin
		oki1_we_prev <= sel_oki1_we;
		if (sel_oki1_we && !oki1_we_prev) begin
			oki1_din_latch <= z80_do;
			oki1_wr_hold   <= 6'd40;
		end else if (oki1_wr_hold != 6'd0) begin
			oki1_wr_hold <= oki1_wr_hold - 6'd1;
		end
	end
	wire oki0_wr_n = ~(oki0_wr_hold != 6'd0);
	wire oki1_wr_n = ~(oki1_wr_hold != 6'd0);

	wire [7:0] oki0_chip_dout, oki1_chip_dout;
	wire signed [13:0] oki0_snd, oki1_snd;
	jt6295 oki0_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki0_stall), .ss(1'b0),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki0_chip_dout),
		.rom_addr(oki0_rom_addr_raw), .rom_data(oki0_rom_data), .rom_ok(oki0_rom_ok),
		.sound(oki0_snd), .sample()
	);
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki1_stall), .ss(1'b0),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr_raw), .rom_data(oki1_rom_data), .rom_ok(oki1_rom_ok),
		.sound(oki1_snd), .sample()
	);

	// ------------------------------------------------------------------
	// Audio mix — mono (no separate panning info anywhere in this
	// driver): jt03's own already-mixed FM+PSG `snd` (16-bit) plus both
	// OKI chips' own 14-bit `sound`, summed in a wider accumulator then
	// saturated to 16 bits rather than allowed to silently wrap.
	//
	// Balance follows MAME's routing for these boards: FM at 1.20, each
	// OKI at 0.10 (nmk16.cpp macross2 config). MAME's OKI stream is a
	// 16-bit full-scale signal, i.e. jt6295's 14-bit `sound` x4, so the
	// OKI-to-FM ratio is (4 x 0.10) / 1.20 = 1/3 of the 14-bit value;
	// 3/8 below is the nearest cheap shift-add. The previous mix put each
	// OKI at x4 — full 16-bit scale next to the FM, ~12x louder than
	// MAME — which, together with the wrong OKI clock above, is what
	// swamped the music.
	// ------------------------------------------------------------------
	wire signed [17:0] oki0_ext = {{4{oki0_snd[13]}}, oki0_snd};
	wire signed [17:0] oki1_ext = {{4{oki1_snd[13]}}, oki1_snd};
	wire signed [17:0] oki0_g   = oki0_ext + (oki0_ext >>> 1); // x 3/2 (was 3/8 -- measured 8-13dB quiet vs MAME's real OKI:FM balance)
	wire signed [17:0] oki1_g   = oki1_ext + (oki1_ext >>> 1);
	wire signed [17:0] audio_sum = {{2{ym_snd[15]}}, ym_snd} + oki0_g + oki1_g;
	wire signed [15:0] audio_mix =
		(audio_sum > 18'sd32767)  ? 16'sd32767  :
		(audio_sum < -18'sd32768) ? -16'sd32768 :
		audio_sum[15:0];
	assign audio_l = audio_mix;
	assign audio_r = audio_mix;
	assign dbg_oki0_snd = oki0_snd;
	assign dbg_oki1_snd = oki1_snd;

	// ------------------------------------------------------------------
	// Z80 read-data mux
	// ------------------------------------------------------------------
	// Memory selects are address-only decodes, so they MUST be qualified
	// with the MREQ cycle here: on an I/O read (`in a,(n)`) the Z80 puts
	// register A on A15..A8, and an unqualified `sel_z80_rom` would hand
	// the CPU a program-ROM/bank/RAM byte instead of the chip status.
	// The sound driver's YM2203 busy-wait (ROM $0018: in a,($00); rlca;
	// jr c) did exactly that and could spin forever on ROM contents —
	// heard on hardware as the music dying at a music change until the
	// next Z80 reset. See docs/hw-bringup.md.
	reg [7:0] z80_rdata;
	always @(*) begin
		if (z80_mem_re & sel_z80_rom)        z80_rdata = audiocpu_dout;
		else if (z80_mem_re & sel_z80_bank)  z80_rdata = audiocpu_dout;
		else if (z80_mem_re & sel_z80_ram)   z80_rdata = z80_ram[z80_a[12:0]];
		else if (z80_mem_re & sel_z80_soundlatch_r) z80_rdata = soundlatch_data;
		else if (z80_io_re & sel_io_ym)   z80_rdata = ym_chip_dout;
		else if (z80_io_re & sel_io_oki0) z80_rdata = oki0_chip_dout;
		else if (z80_io_re & sel_io_oki1) z80_rdata = oki1_chip_dout;
		else                     z80_rdata = 8'hFF;
	end
	assign z80_di = z80_rdata;

	// ------------------------------------------------------------------
	// 68000 read-data mux
	// ------------------------------------------------------------------
	reg [15:0] rdata;
	always @(*) begin
		if (sel_rom)          rdata = rom_dout;
		else if (sel_mainram) rdata = mainram_dout;
		else if (sel_palette) rdata = palette_dout;
		else if (sel_bgvram)  rdata = bgvram_dout;
		else if (sel_txvram)  rdata = txvram_dout;
		else if (sel_soundlatch2_r) rdata = {8'h00, soundlatch2_data};
		else if (sel_in0)     rdata = HW_ROMS ? in0_i  : 16'hFFFF;
		else if (sel_in1)     rdata = HW_ROMS ? in1_i  : 16'hFFFF;
		else if (sel_dsw1)    rdata = HW_ROMS ? dsw1_i : 16'hFFFF;
		else if (sel_dsw2)    rdata = HW_ROMS ? dsw2_i : 16'hFFFF;
		else                  rdata = 16'hFFFF; // unmapped
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + REAL V-PROM interrupt generation (rtl/nmk_irq/
	// nmk_irq.sv).
	// ------------------------------------------------------------------
	wire [9:0] vt_hcount, vt_vcount;
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);
	assign ce_pix_o = ce_pix;
	assign hcount_o = vt_hcount;
	assign vcount_o = vt_vcount;
	assign hblank_o = vt_hblank;
	assign vblank_o = vt_vblank;

	wire sprite_dma_trigger;
	nmk_irq #(
		.VTIMING_FILE(VTIMING_FILE)
	) irq_gen (
		.clk_sys(clk_sys),
		.table_sel({2'b0, game_powerins}), // V-PROM table 1 = powerins' 21.u71 (Macross2.sv loads a 512-line file)
		.reset(reset),
		.line_start(vt_line_start),
		.vcount(vt_vcount),
		.iack_cycle(iack_cycle),
		.iack_level(eab[3:1]),
		.ipl_level(ipl_level),
		.sprite_dma_trigger(sprite_dma_trigger)
	);

	// ------------------------------------------------------------------
	// Video pipeline — rtl/macross2/video_macross2.sv, reused UNMODIFIED
	// (see this file's own header).
	// ------------------------------------------------------------------
	wire [23:0] rd_rgb_video;   // video's pixel; rd_rgb below may overlay DBG_SND_PAINT blocks
	video_macross2 #(
		.TX_EXTERNAL(1),
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.SPRITES_FILE(SPRITES_FILE),
		.SPRITES_BYTES(SPRITES_BYTES),
		.BGTILE_BYTES(BGTILE_BYTES),
		.HW_ROMS(HW_ROMS),
		.DBG_MISS_PAINT(DBG_MISS_PAINT)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.game_powerins(game_powerins),
		.lowres(1'b0), .raster_scroll(1'b1), .cfg_rt(1'b0), .bga_pal_base_i(11'd0), .bgb_pal_base_i(11'd0), .spr_pal_base_i(11'd0), .tx_pal_base_i(11'd0),
		.bga_code_mask_i(14'd0), .bgb_code_mask_i(14'd0), .spr_units_i(18'd0), .sprdma_word_base(15'h4000), .nmk214_en(1'b1),
		.bg2_en(1'b0), .bga_rom2(1'b0), .bgb_rom2(1'b0), .base_word_bgtile_b(23'd0), .bgvram_b_addr(), .bgvram_b_data(16'd0), .bgb_xscroll(16'd0), .bgb_yscroll(16'd0),
		.base_word_fgtile(BASE_WORD_FGTILE), .base_word_bgtile(BASE_WORD_BGTILE), .base_word_sprites(BASE_WORD_SPRITES),
		.sprite_dma_trigger(sprite_dma_trigger), .sprite_dma_busy(sprite_dma_busy),
		.bgvram_addr(vid_bgvram_addr), .bgvram_data(vid_bgvram_dout),
		.txvram_addr(vid_txvram_addr), .txvram_data(vid_txvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout), .mainram_ready(vid_mainram_ready),
		.bg_xscroll(bg_xscroll), .bg_yscroll(bg_yscroll),
		.scrollram_0(16'd0), .scrollramy_0(16'd0), .scroll_row_addr(), .scrollram_row(16'd0), .scrollramy_row(16'd0),
		.nmk214_cfg_we(1'b0), .nmk214_cfg_data(8'h00),
		.bg_bank(bgbank_reg),
		.tilerambank(tilerambank_reg),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb_video),
		.sd_addr(sd2_addr), .sd_wrl(sd2_wrl), .sd_wrh(sd2_wrh), .sd_din(sd2_din),
		.sd_dout(sd2_dout), .sd_dout_pair(sd2_dout_pair), .sd_req(sd2_req), .sd_ack(sd2_ack),
		.sd_b_addr(sd1_addr), .sd_b_req(sd1_req), .sd_b_dout(sd1_dout), .sd_b_dout_pair(sd1_dout_pair), .sd_b_ack(sd1_ack),
		.txc_addr(p1_addr[0]), .txc_req(p1_req[0]), .txc_busy(p1_busy[0]), .txc_valid(p1_valid[0]), .txc_dout(p1_dout[0]), .txc_dout_pair(p1_dout_pair[0])
	);

	generate
	if (DBG_SND_PAINT) begin : g_snd_paint
		reg [16:0] stall0_cnt = 17'd0, stall1_cnt = 17'd0;
		reg [19:0] m1_idle_cnt = 20'd0, wait_cnt = 20'd0;
		reg        m1_n_d = 1'b1;
		always @(posedge clk_sys) begin
			stall0_cnt <= oki0_stall ? (stall0_cnt == 17'h1FFFF ? stall0_cnt : stall0_cnt + 17'd1) : 17'd0;
			stall1_cnt <= oki1_stall ? (stall1_cnt == 17'h1FFFF ? stall1_cnt : stall1_cnt + 17'd1) : 17'd0;
			m1_n_d <= z80_m1_n;
			m1_idle_cnt <= (m1_n_d && !z80_m1_n) ? 20'd0 : (m1_idle_cnt == 20'hFFFFF ? m1_idle_cnt : m1_idle_cnt + 20'd1);
			wait_cnt <= z80_wait_n ? 20'd0 : (wait_cnt == 20'hFFFFF ? wait_cnt : wait_cnt + 20'd1);
		end
		wire f0 = stall0_cnt >= 17'd40000;     // 1 ms
		wire f1 = stall1_cnt >= 17'd40000;
		wire f2 = m1_idle_cnt >= 20'd400000;   // 10 ms without an opcode fetch
		wire f3 = wait_cnt >= 20'd400000;      // 10 ms in the ROM wait-state
		// Row 0 (y 0-7): the four flags. Row 1 (y 8-15): OKI0 busy[3:0]
		// then OKI1 busy[3:0] (white = busy). Row 2 (y 16-23): Z80 PC
		// bits 15..8, row 3 (y 24-31): PC bits 7..0 (white = 1), latched
		// at each opcode fetch. Row 4 (y 32-39): sound latch bits 7..0.
		reg [15:0] pc_latch = 16'd0;
		always @(posedge clk_sys) if (m1_n_d && !z80_m1_n) pc_latch <= z80_a;
		wire [7:0] busy_bits = {oki0_chip_dout[3:0], oki1_chip_dout[3:0]};
		// Self-describing layout, 6 rows of 8 px: x 0-7 = row marker
		// colour (red, green, blue, yellow, magenta, cyan), x 8-71 = 8 data
		// bits MSB first, on = white, off = dark blue 000080.
		//   row 0: {f0, f1, f2, f3, 1,0,1,0}   row 1: OKI0 busy[3:0], OKI1 busy[3:0]
		//   row 2: Z80 PC[15:8]  row 3: PC[7:0]  row 4: sound latch  row 5: 8'h5A
		wire [2:0] row = rd_y[5:3];
		wire [3:0] col = rd_x[6:3];          // 0 = marker, 1..8 = bits
		wire in_blk = (rd_y < 9'd48) && (rd_x < 9'd72);
		wire [23:0] marker = (row == 3'd0) ? 24'hFF0000 : (row == 3'd1) ? 24'h00FF00 : (row == 3'd2) ? 24'h0000FF :
		                     (row == 3'd3) ? 24'hFFFF00 : (row == 3'd4) ? 24'hFF00FF : 24'h00FFFF;
		wire [7:0] row_bits = (row == 3'd0) ? {f0, f1, f2, f3, 4'b1010} : (row == 3'd1) ? busy_bits :
		                      (row == 3'd2) ? pc_latch[15:8] : (row == 3'd3) ? pc_latch[7:0] :
		                      (row == 3'd4) ? soundlatch_data : 8'h5A;
		wire [2:0] bi = 3'd7 - (col[2:0] - 3'd1);   // col 1 -> bit 7 ... col 8 -> bit 0
		wire bit_on = row_bits[bi];
		assign rd_rgb = !in_blk ? rd_rgb_video : (col == 4'd0) ? marker : (bit_on ? 24'hFFFFFF : 24'h000080);
	end else begin : g_no_snd_paint
		assign rd_rgb = rd_rgb_video;
	end
	endgenerate

	reg frame_done_r;
	always @(posedge clk_sys) begin
		frame_done_r <= vt_line_start && (vt_vcount == 10'd0);
	end
	assign frame_done = frame_done_r;

	// ------------------------------------------------------------------
	// Debug/trace outputs
	// ------------------------------------------------------------------
	assign dbg_eab   = eab;
	assign dbg_data  = cpu_write ? oEdb : iEdb;
	assign dbg_write = cpu_write;
	assign dbg_as_n  = ASn;
	assign dbg_fc0   = FC0;
	assign dbg_fc1   = FC1;
	assign dbg_fc2   = FC2;

	assign dbg_z80_pc = z80_a;
	assign dbg_z80_m1_n = z80_m1_n;
	assign dbg_z80_mreq_n = z80_mreq_n;
	assign dbg_z80_iorq_n = z80_iorq_n;
	assign dbg_z80_int_n = z80_int_n;
	assign dbg_z80_reset_n = z80_reset_n;
	assign dbg_z80_cen = z80_cen;

	assign dbg_ym_we = ym_we_raw;
	assign dbg_ym_cs = sel_io_ym;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_irq_n = ym_chip_irq_n;

	assign dbg_oki0_we = sel_oki0_we;
	assign dbg_oki1_we = sel_oki1_we;
	assign dbg_oki0_chip_dout = oki0_chip_dout;
	assign dbg_oki1_chip_dout = oki1_chip_dout;

endmodule
