// NMK16 MiSTerFPGA project — the "Gunnail" rbf's system-level
// integration, hardware-ready: GunNail (gunnail, gunnailp) and, since
// 2026-09-11, the nine lowres NMK004 boards as runtime game modes of the
// same core (game_sel): Super Spacefortress Macross, Black Heart, US AAF
// Mustang, Bio-ship Paladin, Vandyke, Acrobat Mission, Koutetsu Yousai
// Strahl, Thunder Dragon (unprotected and NMK-110 protected) and Hacha
// Mecha Fighter. Built on raphero_core.sv's HW_ROMS machinery (every ROM
// through caches over rtl/sdram.sv, loaded by ioctl_download; registered
// on-chip RAMs; sprite-DMA CPU stall; audio mix; real inputs) and
// rtl/macross2/video_macross2.sv with the gfx_macross parameters (4-bit
// sprite colour, TX palette at 0x200, 13-bit BG code), RASTER_SCROLL=1
// and the two NMK214 descramblers. See docs/hw-bringup.md.
//
// What the boards are (nmk16.cpp, cross-checked per game):
//   - gunnail: 68000 at 10 MHz, gunnail_map: I/O at 0x080000, palette
//     0x088000, gunnail_scrollram/scrollramy at 0x08C000/0x08C200
//     (write-only, 256 words each), BG VRAM 0x090000 (8192 words), TX
//     VRAM 0x09C000 mirrored at +0x1000, main RAM 0x0F0000 (plain).
//     set_screen_hires, VIDEO_START gunnail (64x32 TX + per-line scroll),
//     NMK-215 + dual NMK214, V-PROM 633ab1c9.
//   - The nine others: set_screen_lowres (384 x 278 at 6 MHz, visible
//     92..347 — the same 64 us line as the 512 x 8 MHz raster, so this
//     core keeps its raster and draws a 256-px window at hcount 92..347),
//     32x32 TX tilemap, frame-constant scroll registers in four formats
//     (byte-sequenced scroll_w<Layer> on the low or the high byte,
//     vandyke's four words, mustang's one selector word), screen_update
//     _macross (BG, TX, sprites) or _strahl (two BG layers: bioship's
//     bottom layer is a ROM tilemap — "tilerom", 8 banks of 8192 tile
//     indices selected by bioship_bank_w — under its VRAM layer; strahl
//     has two VRAM layers), gfx_macross / gfx_bioship / gfx_strahl palette
//     bases, 8/10/12 MHz 68000s, three V-PROMs (strahl: none dumped —
//     MAME's fixed-scanline set_hacky_interrupt_timing, nmk_irq_hacky.sv),
//     m_sprdma_base 0xF000 for strahl, bioship's inverted NMI level,
//     mainram_strange_w (byte writes store the replicated byte in both
//     halves — the 68000 puts the byte on both bus halves) on the
//     macross_map boards, strahl's 0xA0000-byte OKI ROMs, hachamf's
//     NMK-113 (TMP91640, 16 KB ROM, port 7 = 0x0C) and tdragon1's NMK-110
//     protection MCUs on the same shared-bus mechanism as the NMK-215.
//     The game table below (g_* / the case blocks) lists every value.
//   - NMK004 sound MCU (TLCS-90 TMP90C840, rtl/tlcs90/nmk004_core.sv) at
//     8 MHz on every board: 8 KB internal boot ROM (nmk004.bin) + the
//     game's 64 KB external program, YM2203 at 1.5 MHz, two OKIM6295 at
//     4 MHz pin 7 low whose upper 128 KB window the NMK004 banks
//     (oki1_map/oki2_map + nmk004's fc01/fc02 bank writes). The NMK004's
//     P4 bit 0 resets the 68000; 0x080016 bit 0 drives its NMI (a
//     watchdog kick). Both MCUs run on clk_sys with clock enables here
//     (tlcs90.sv's cen): the NMK004's 8 MHz enable is withheld while its
//     program-ROM cache misses (0.1% of pulses in the raphero sim, same
//     mechanism), the protection MCU's 4 MHz enable while a shared-bus
//     access waits for its RAM port.
//   - NMK-215 protection MCU (TMP90840, nmk_prot_core.sv, 8 KB ROM
//     nmk-215.bin, byte-identical between gunnail and macross) at 4 MHz:
//     it only loads the two NMK214 descrambler configs at boot through
//     its port 3/port 7 (a MAME Lua trace over 30 s of attract mode
//     shows no 68000-bus access at all, and its port 6 writes are
//     0x03/0x0B — never the 0x08 "halt the 68000" the NMK-110/113
//     firmware uses). The shared-bus path is wired (RAM-port steal with
//     the 68000 held off by DTACK, own ROM cache) and IS used by the
//     NMK-110/113 firmware (tdragon1/hachamf). One nmk_prot_core instance
//     serves both parts: 16 KB ROM / 512 B RAM at 0xFDC0 (the TMP91640
//     sizes, a superset of the TMP90840's 8 KB / 256 B at 0xFEC0 —
//     verified against the single-game sims' protection traces), the
//     firmware written into it from the ioctl stream, held in reset on
//     the boards without one.
//
// SDRAM layout (bytes; word offset = byte offset / 2): per game, see the
// BASE_BYTE_* case block — the regions are always maincpu, NMK004
// external program (0x10000), NMK004 boot ROM (0x2000, nmk004.zip),
// [protection MCU ROM], fgtile, bgtile, [bg2tile], [tilerom], sprites,
// oki1, oki2, in that order, each exactly its ROM_START file total and
// CONTIGUOUS: the MiSTer .mra loader streams the <part>s back to back
// with no way to place one at an offset, so any gap in this table shifts
// every later ROM (the first hardware build had a 0xC000 gap after the
// protection ROM and drew scrambled BG tiles and sprites from the shifted
// data while the text layer happened to survive). gunnail's own:
//   0x000000 maincpu  0x080000 (3o.u133 even / 3e.u131 odd bytes — the
//                     .mra <interleave> puts the LOW-byte chip on even
//                     ioctl addresses, which the parity rebuild makes the
//                     word's low byte; gunnailp's single WORD_SWAP file
//                     gives the same order)
//   0x080000 nmk004 external program 0x010000 (92077_2.u101; 0x0000-
//                     0x1FFF of it is hidden by the internal ROM)
//   0x090000 nmk004 boot ROM 0x002000 (nmk004.bin, from nmk004.zip)
//   0x092000 protection MCU ROM 0x002000 (nmk-215.bin) — also copied
//                     into the MCU's on-chip array during the download
//   0x094000 fgtile   0x020000
//   0x0B4000 bgtile   0x100000
//   0x1B4000 sprites  0x200000 (ROM_LOAD16_WORD_SWAP)
//   0x3B4000 oki1     0x080000
//   0x434000 oki2     0x080000, image ends 0x4B4000
module gunnail_core #(
	parameter ROM_FILE          = "",
	parameter NMK004_BOOT_FILE  = "",
	parameter NMK004_EXT_FILE   = "",
	parameter PROT_BOOT_FILE    = "",
	parameter OKI1_ROM_FILE     = "",
	parameter OKI2_ROM_FILE     = "",
	parameter VTIMING_FILE      = "",
	parameter FGTILE_FILE       = "",
	parameter BGTILE_FILE       = "",
	parameter BG2TILE_FILE      = "",  // bioship/strahl second tile ROM (sim)
	parameter TILEROM_FILE      = "",  // bioship ROM tilemap indices, 16-bit words (sim)
	parameter SPRITES_FILE      = "",
	parameter AUDIOCPU_FILE     = "",  // tharrier's Z80 program (sim)
	// HW_ROMS=0 (reference sim): $readmemh 0-latency arrays. HW_ROMS=1
	// (Gunnail.sv and the gunnail_hw sim): every ROM through a cache over
	// rtl/sdram.sv, loaded via ioctl_download.
	parameter HW_ROMS           = 0,
	parameter DBG_MISS_PAINT    = 0,
	// cactus: the NMK214 configs the NMK-215 sends sabotenb (see the
	// cactus block; verified against the sabotenb reference sim's trace)
	parameter [7:0] CACTUS_CFG_SPR = 8'h02,
	parameter [7:0] CACTUS_CFG_BG  = 8'h0E,
	// HW_ROMS=0 only: 1 = the DIP switches come from dsw1_i/dsw2_i (the
	// testbench drives the .mra defaults, so the MAME comparison covers
	// language/demo-sound dependent screens); 0 = 0xFFFF as before.
	parameter SIM_DSW           = 0
) (
	input clk_sys,        // 40 MHz (68000 clk_sys/4 = 10 MHz, /5 = 8 MHz, 3/10 = 12 MHz; NMK004/pixel clk_sys/5 = 8 MHz; protection MCU clk_sys/10 = 4 MHz)
	input reset,          // async, active high

	// Game select (2026-09-11) — see the game table below. Static for a
	// session (from the .mra <switches> third byte in Gunnail.sv).
	input [4:0] game_sel,

	// Hardware-mode-only ports (HW_ROMS=1) — see tdragon2_core.sv.
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input      [7:0]  ioctl_dout,
	input     [15:0]  ioctl_index,
	output            ioctl_wait,

	// SDRAM port 0: ioctl_download writes muxed with maincpu ROM reads.
	output     [24:1] sd0_addr,
	output            sd0_wrl,
	output            sd0_wrh,
	output     [15:0] sd0_din,
	input      [15:0] sd0_dout,
	input      [31:0] sd0_dout_pair,
	output            sd0_req,
	input             sd0_ack,
	// SDRAM port 1: sprite fetch (+ BG layer B's prefetch stream).
	output     [24:1] sd1_addr,
	output            sd1_req,
	input      [15:0] sd1_dout,
	input      [31:0] sd1_dout_pair,
	input             sd1_ack,
	// SDRAM port 2: video_macross2.sv's BG-tile prefetch stream.
	output     [24:1] sd2_addr,
	output            sd2_wrl,
	output            sd2_wrh,
	output     [15:0] sd2_din,
	input      [15:0] sd2_dout,
	input      [31:0] sd2_dout_pair,
	output            sd2_req,
	input             sd2_ack,
	// SDRAM port 3: TX-tile prefetch, NMK004 program ROM, OKI0/OKI1
	// samples, protection MCU ROM, bioship tilemap DMA — arbitrated.
	output     [24:1] sd3_addr,
	output            sd3_req,
	input      [15:0] sd3_dout,
	input      [31:0] sd3_dout_pair,
	input             sd3_ack,

	// debug/trace outputs for the Verilator testbenches
	output [23:1] dbg_eab,
	output [15:0] dbg_data,
	output        dbg_write,
	output        dbg_as_n,
	output        dbg_fc0,
	output        dbg_fc1,
	output        dbg_fc2,

	output [15:0] dbg_nmk004_pc,
	output        dbg_nmk004_valid,
	output        dbg_nmk004_cen,
	output        dbg_nmk004_stall,
	output [31:0] dbg_nmk004_cen_total,   // sim only
	output [31:0] dbg_nmk004_stall_total, // sim only
	// 68000 <-> NMK004 latch traffic (for the boot-handshake trace)
	output        dbg_host_cmd_we,
	output [7:0]  dbg_host_cmd,
	output        dbg_mcu_reply_we,
	output [7:0]  dbg_mcu_reply,

	output [15:0] dbg_prot_pc,
	output        dbg_prot_valid,
	output        dbg_halt_68k,
	output [15:0] dbg_prot_hl,
	output  [7:0] dbg_prot_a,
	output [15:0] dbg_prot_de,
	output [15:0] dbg_prot_iy,
	output [19:0] dbg_prot_addr,
	output  [7:0] dbg_prot_int_ram_at_hl,
	output        dbg_prot_bus_rd,
	output        dbg_prot_bus_wr,
	output [9:0]  dbg_vt_vcount,
	output        dbg_nmk214_cfg_we,
	output [7:0]  dbg_nmk214_cfg_data,

	output        dbg_ym_we,
	// per-source audio taps (sim level checks against MAME's routes)
	output signed [15:0] dbg_fm_snd,
	output        [9:0]  dbg_psg_snd,
	output signed [13:0] dbg_oki0_snd,
	output signed [13:0] dbg_oki1_snd,
	output        dbg_ym_cs,
	output  [7:0] dbg_ym_chip_dout,
	output        dbg_ym_chip_irq_n,
	output  [7:0] dbg_ym_wdata,   // data the sound CPU writes to the YM2203
	output        dbg_ym_waddr,   // 0 = register select, 1 = data

	output        dbg_oki0_we,
	output        dbg_oki0_cs,
	output  [7:0] dbg_oki0_chip_dout,
	output        dbg_oki1_we,
	output        dbg_oki1_cs,
	output  [7:0] dbg_oki1_chip_dout,
	output [31:0] dbg_oki0_adpcm_total,
	output [31:0] dbg_oki0_adpcm_unserved,
	output [31:0] dbg_oki1_adpcm_total,
	output [31:0] dbg_oki1_adpcm_unserved,
	output [31:0] dbg_oki_cen_total,
	output [31:0] dbg_oki0_stall_cen,
	output [31:0] dbg_oki1_stall_cen,

	output [7:0]  dbg_nmk004_a,
	output [7:0]  dbg_nmk004_f,
	output [15:0] dbg_nmk004_hl,
	output [7:0]  dbg_nmk004_ram_hl,
	output [15:0] dbg_nmk004_de,
	output [15:0] dbg_nmk004_bc,
	output [15:0] dbg_nmk004_ix,
	output [15:0] dbg_nmk004_iy,
	output [15:0] dbg_nmk004_sp,

	// pixel readback (mirrors MAME's screen:pixel(x,y))
	input  [8:0]  rd_x,
	input  [7:0]  rd_y,
	output [23:0] rd_rgb,
	input  [9:0]  dbg_pal_addr,
	output [15:0] dbg_pal_data,
	input  [13:0] dbg_bgvram_addr,
	output [15:0] dbg_bgvram_data,
	input  [10:0] dbg_txvram_addr,
	output [15:0] dbg_txvram_data,
	output        frame_done,

	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	output        ce_pix_o,
	output [9:0]  hcount_o,
	output [9:0]  vcount_o,
	output        hblank_o,
	output        vblank_o,
	output        lowres_o,   // 1 = 256-px window at hcount 92..347 (every game but gunnail)

	// Real inputs (HW_ROMS=1 only; the sim path reads 0xFFFF = idle).
	input  [15:0] in0_i,
	input  [15:0] in1_i,
	input  [15:0] dsw1_i,
	input  [15:0] dsw2_i,

	input extra_por_hold
);

	// ------------------------------------------------------------------
	// Game table (2026-09-11). Every per-game difference is a function of
	// game_sel; the values are transcribed from nmk16.cpp's machine
	// configs, memory maps, GFXDECODE tables and ROM_START blocks (see the
	// header). The ids are the .mra <switches> third byte.
	// ------------------------------------------------------------------
	localparam [3:0] G_GUNNAIL  = 4'd0,
	                 G_MACROSS  = 4'd1,
	                 G_BLKHEART = 4'd2,
	                 G_MUSTANG  = 4'd3,
	                 G_BIOSHIP  = 4'd4,
	                 G_VANDYKE  = 4'd5,
	                 G_ACROBATM = 4'd6,
	                 G_STRAHL   = 4'd7,
	                 G_TDRAGON  = 4'd8,
	                 G_HACHAMF  = 4'd9,
	                 G_TDRAGON1 = 4'd10,
	                 G_HACHAMFP = 4'd11,   // hachamf location-test prototype: no protection MCU (plain hachamf()), ROM_LOAD16_BYTE sprites
	                 G_MUSTANGS = 4'd12;   // mustang (Seoul Trading): its own V-PROM (90058-10, de156d99)
	// 2026-09-12: the unprotected hachamf bootleg, the Bombjack Twin family
	// (no sound CPU: 68000-driven OKIs with NMK112 banking, one 8x8 tile
	// layer with two ROMs, single-buffered sprites) and Family G
	// (Task Force Harrier's Z80 + YM2203 sound board and MCU protection
	// simulation, the sound-less Vandyke bootleg). Five-bit ids.
	localparam [4:0] G_HACHAMFB = 5'd13,   // hachamf() without the MCU, hachamf ROM layout
	                 G_BJTWIN   = 5'd14,   // bjtwin, bjtwina: NMK-215, 0x40000 maincpu, 1 MB bgtile, 1 MB WORD_SWAP sprites
	                 G_BJTWINP  = 5'd15,   // bjtwinp: no MCU (plain GFX), 0x180000 bgtile, byte-pair sprites
	                 G_BJTWINPA = 5'd16,   // bjtwinpa: NMK-215, 0x180000 bgtile, byte-pair sprites
	                 G_SABOTENB = 5'd17,   // sabotenb, sabotenba, nouryoku: NMK-215, 0x80000 maincpu, 2 MB bgtile, 2 MB WORD_SWAP sprites
	                 G_CACTUS   = 5'd18,   // cactus: sabotenb's ROM data on a board without the MCU (init_nmk decode = the NMK214s with the NMK-215's config), pair sprites, fixed-scanline IRQs
	                 G_NOURYOKUP = 5'd19,  // nouryokup: no MCU, plain GFX, 2 MB bgtile (4 files), pair sprites
	                 G_THARRIER = 5'd20,   // tharrier, tharrieru
	                 G_VANDYKEB = 5'd21,   // vandykeb: no sound, PIC scroll registers, fixed-scanline IRQs
	                 G_MUSTANGB3 = 5'd22;  // mustangb3 (Lettering bootleg): mustang's video/map on an 8 MHz 68000, tharrier's Z80+YM2203 sound board (unbanked 0x20000 OKI ROMs), fixed-scanline IRQs, a PC-keyed read at 0x080006
	wire g_gunnail  = (game_sel == G_GUNNAIL) || (game_sel > G_MUSTANGB3); // unknown ids fall back to gunnail
	wire g_macross  = (game_sel == G_MACROSS);
	wire g_blkheart = (game_sel == G_BLKHEART);
	wire g_mustangb3 = (game_sel == G_MUSTANGB3);
	wire g_mustang  = (game_sel == G_MUSTANG) || (game_sel == G_MUSTANGS) || g_mustangb3; // mustang's map, scroll register and video for all three
	wire g_bioship  = (game_sel == G_BIOSHIP);
	wire g_vandyke  = (game_sel == G_VANDYKE);
	wire g_acrobatm = (game_sel == G_ACROBATM);
	wire g_strahl   = (game_sel == G_STRAHL);
	wire g_tdragon  = (game_sel == G_TDRAGON);
	wire g_hachamf  = (game_sel == G_HACHAMF) || (game_sel == G_HACHAMFP);
	wire g_hachamfp = (game_sel == G_HACHAMFP);
	wire g_tdragon1 = (game_sel == G_TDRAGON1);
	wire g_mustangs = (game_sel == G_MUSTANGS);
	wire g_hachamfb = (game_sel == G_HACHAMFB);
	wire g_bjtwin_prot = (game_sel == G_BJTWIN) || (game_sel == G_BJTWINPA) || (game_sel == G_SABOTENB);
	wire g_cactus   = (game_sel == G_CACTUS);
	wire g_bjtwin   = g_bjtwin_prot || g_cactus || (game_sel == G_BJTWINP) || (game_sel == G_NOURYOKUP); // the whole family
	wire g_tharrier = (game_sel == G_THARRIER);
	wire g_vandykeb = (game_sel == G_VANDYKEB);
	wire g_z80snd   = g_tharrier | g_mustangb3;                          // the Z80 + YM2203 sound board (tharrier_sound_map)
	wire has_nmk004 = ~(g_bjtwin | g_z80snd | g_vandykeb);             // else the NMK004 is held in reset

	wire lowres          = ~(g_gunnail | g_bjtwin);                      // set_screen_lowres (gunnail and bjtwin are hires)
	wire cpu_8mhz        = g_blkheart | g_mustang | g_tdragon | g_tdragon1; // mustangb3: XTAL(8 MHz) verified on PCB
	wire cpu_12mhz       = g_strahl;                                     // "12 MHz ?"
	wire has_prot        = g_gunnail | g_macross | (g_hachamf & ~g_hachamfp) | g_tdragon1 | g_bjtwin_prot; // NMK-215 / NMK-113 / NMK-110 (hachamfp/hachamfb: none)
	wire has_214         = g_gunnail | g_macross | g_bjtwin_prot | g_cactus; // base_nmk214_215: bgtile + sprites scrambled (cactus: same data, config injected below)
	wire prot_rom_16k    = g_hachamf | g_tdragon1;                       // TMP91640 (NMK-110/113): 16 KB firmware
	wire nmi_invert      = g_bioship;                                    // nmk004_bioship_x0016_w
	wire mainram_strange = g_macross | g_blkheart | g_mustang | g_bioship | g_vandyke | g_tharrier | g_vandykeb; // macross_map/mustang_map/bioship_map/vandyke_map/tharrier_map mainram_strange_w
	wire bg2             = g_bioship | g_strahl;                         // screen_update_strahl: two BG layers
	wire irq_hacky       = g_strahl | g_cactus | g_vandykeb | g_mustangb3; // set_hacky_interrupt_timing (no V-PROM)
	wire spr_plain       = g_bioship | g_strahl | g_acrobatm;            // sprite ROMs are plain ROM_LOAD byte files (the rest: WORD_SWAP / odd-first byte pairs), see video_macross2 spr_swap
	wire [2:0] vprom_sel = (g_blkheart | g_bioship | g_vandyke) ? 3'd1 : // 98ed1c97
	                       (g_tdragon | g_tdragon1)             ? 3'd2 : // e6ead349
	                       g_mustangs                           ? 3'd3 : // de156d99
	                       g_tharrier                           ? 3'd4 : // fcd5efea
	                                                              3'd0;  // 633ab1c9 (gunnail, macross, mustang, acrobatm, hachamf, bjtwin family)
	// Memory maps (nmk16.cpp): the decode function below keys on these.
	localparam [3:0] M_GUNNAIL = 4'd0, M_MACROSS = 4'd1, M_MUSTANG = 4'd2, M_BIOSHIP = 4'd3,
	                 M_VANDYKE = 4'd4, M_ACROBATM = 4'd5, M_STRAHL = 4'd6, M_TDRAGON = 4'd7,
	                 M_BJTWIN = 4'd8, M_THARRIER = 4'd9, M_VANDYKEB = 4'd10;
	wire [3:0] map_id = g_gunnail  ? M_GUNNAIL :
	                    g_bjtwin   ? M_BJTWIN :
	                    g_tharrier ? M_THARRIER :
	                    g_vandykeb ? M_VANDYKEB :
	                    g_mustang  ? M_MUSTANG :
	                    g_bioship  ? M_BIOSHIP :
	                    g_vandyke  ? M_VANDYKE :
	                    g_acrobatm ? M_ACROBATM :
	                    g_strahl   ? M_STRAHL :
	                    (g_tdragon | g_tdragon1) ? M_TDRAGON : M_MACROSS; // macross, blkheart, hachamf
	wire [23:0] rom_max = (g_gunnail | g_macross | g_blkheart | g_bjtwin) ? 24'h07FFFF : 24'h03FFFF;

	// Video configuration (GFXDECODE bases; ROM tile counts - 1 as code
	// masks; sprite ROM bytes / 128; m_sprdma_base / 2).
	reg [10:0] cfg_bga_pal, cfg_bgb_pal, cfg_spr_pal, cfg_tx_pal;
	reg [13:0] cfg_bga_mask, cfg_bgb_mask;
	reg [17:0] cfg_spr_units;
	always @(*) begin
		cfg_bga_pal = 11'h000; cfg_bgb_pal = 11'h000; cfg_spr_pal = 11'h100; cfg_tx_pal = 11'h200; // gfx_macross
		cfg_bga_mask = 14'h1FFF; cfg_bgb_mask = 14'h0FFF; cfg_spr_units = 18'd16384;
		case (game_sel)
			G_MACROSS:  begin cfg_bga_mask = 14'h3FFF; end                                  // bgtile 0x200000
			G_BLKHEART: begin cfg_spr_units = 18'd8192; end
			G_MUSTANG, G_MUSTANGB3: begin cfg_bga_mask = 14'h0FFF; cfg_spr_units = 18'd8192; end // bgtile 0x80000
			G_BIOSHIP:  begin // gfx_bioship: TX 0x300, bgtile (VRAM layer, gfx1) 0x100, sprites 0x200, bg2tile (ROM tilemap, gfx3) 0x000
			            cfg_bga_pal = 11'h000; cfg_bgb_pal = 11'h100; cfg_spr_pal = 11'h200; cfg_tx_pal = 11'h300;
			            cfg_bga_mask = 14'h0FFF; cfg_bgb_mask = 14'h0FFF; cfg_spr_units = 18'd4096; end
			G_VANDYKE:  begin cfg_bga_mask = 14'h0FFF; end                                  // bgtile 0x80000, sprites 0x200000
			G_ACROBATM: begin cfg_spr_units = 18'd12288; end                                // sprites 0x180000
			G_STRAHL:   begin // gfx_strahl: TX 0x000, bgtile (bgvram0, gfx1) 0x300, sprites 0x100, bg2tile (bgvram1, gfx3) 0x200
			            cfg_bga_pal = 11'h300; cfg_bgb_pal = 11'h200; cfg_spr_pal = 11'h100; cfg_tx_pal = 11'h000;
			            cfg_bga_mask = 14'h07FF; cfg_bgb_mask = 14'h0FFF; cfg_spr_units = 18'd12288; end // bgtile 0x40000, bg2tile 0x80000
			G_TDRAGON, G_TDRAGON1, G_HACHAMF, G_HACHAMFP, G_HACHAMFB: begin cfg_spr_units = 18'd8192; end
			G_MUSTANGS: begin cfg_bga_mask = 14'h0FFF; cfg_spr_units = 18'd8192; end
			// gfx_bjtwin: fgtile and bgtile (both 8x8) at 0x000, sprites at 0x100; the 16x16 layer is unused
			G_BJTWIN, G_BJTWINP, G_BJTWINPA: begin cfg_tx_pal = 11'h000; cfg_spr_units = 18'd8192; end   // sprites 0x100000
			G_SABOTENB, G_CACTUS, G_NOURYOKUP: begin cfg_tx_pal = 11'h000; cfg_spr_units = 18'd16384; end // sprites 0x200000
			// gfx_tharrier: fgtile 0x000, bgtile 0x000, sprites 0x100; bgtile 0x80000, sprites 0x100000
			G_THARRIER: begin cfg_tx_pal = 11'h000; cfg_bga_mask = 14'h0FFF; cfg_spr_units = 18'd8192; end
			G_VANDYKEB: begin cfg_bga_mask = 14'h0FFF; cfg_spr_units = 18'd12288; end                     // bgtile 0x80000, sprites 0x180000 of the 0x200000 region
			default: ;
		endcase
	end
	wire [14:0] cfg_sprdma_word = g_strahl ? 15'h7800 : 15'h4000;

	// ------------------------------------------------------------------
	// Power-on-only reset for the SDRAM req/arb instances (see
	// tdragon2_core.sv's por_rst).
	// ------------------------------------------------------------------
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
	// Clock enables
	// ------------------------------------------------------------------
	// 68000: 10 MHz = clk_sys/4 (phases 2 apart); 8 MHz = clk_sys/5
	// (phases at counts 4 and 2); 12 MHz = a 3/10 accumulator as
	// tdragon2_core.sv's powerins mode (enPhi1 at ticks 4, 7, 10 mod 10,
	// enPhi2 on the tick after the one following each — never adjacent
	// to the next enPhi1; the RAM ready flags below are combinational
	// compares, which that spacing requires).
	reg [1:0] cpu_div = 2'd0;
	always @(posedge clk_sys) cpu_div <= cpu_div + 2'd1;
	reg [2:0] cpu_div5 = 3'd0;
	always @(posedge clk_sys) cpu_div5 <= (cpu_div5 == 3'd4) ? 3'd0 : cpu_div5 + 3'd1;
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
	wire enPhi1 = cpu_12mhz ? cpu_acc_phi1 : cpu_8mhz ? (cpu_div5 == 3'd4) : (cpu_div == 2'd3);
	wire enPhi2 = cpu_12mhz ? cpu_acc_phi2 : cpu_8mhz ? (cpu_div5 == 3'd2) : (cpu_div == 2'd1);

	reg [2:0] pix_div = 3'd0;
	wire ce_pix = (pix_div == 3'd4);
	always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

	// NMK004: 8 MHz enable, withheld while its ROM cache misses (never
	// in reset — the core samples reset on cen edges).
	reg [2:0] snd_div = 3'd0;
	always @(posedge clk_sys) snd_div <= (snd_div == 3'd4) ? 3'd0 : snd_div + 3'd1;
	wire nmk004_rom_stall;
	wire snd_stall = nmk004_rom_stall & ~reset;
	wire snd_cen   = (snd_div == 3'd4) & ~snd_stall;

	// Protection MCU: 4 MHz enable, withheld while a shared-bus access
	// (or its own ROM fetch on the hardware path) is not yet served.
	reg [3:0] prot_div = 4'd0;
	always @(posedge clk_sys) prot_div <= (prot_div == 4'd9) ? 4'd0 : prot_div + 4'd1;
	wire prot_stall;
	wire prot_cen = (prot_div == 4'd9) & ~(prot_stall & ~reset);

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

	// OKIM6295 x2 at XTAL(16 MHz)/4 = 4 MHz, pin 7 low: clk_sys/10.
	reg [3:0] oki_cen_cnt = 4'd0;
	wire      oki_cen = (oki_cen_cnt == 4'd9);
	always @(posedge clk_sys) oki_cen_cnt <= oki_cen ? 4'd0 : oki_cen_cnt + 4'd1;

	// ------------------------------------------------------------------
	// fx68k — HALTn from the protection MCU, extReset also from the
	// NMK004's P4 bit 0 (nmk004_device reset_cb, the watchdog).
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
	wire rom_wait     = sel_rom     & cpu_read & ~rom_ready;
	wire mainram_wait = sel_mainram & cpu_read & ~mainram_ready;
	wire sprite_dma_busy;
	wire mainram_dma_wait = sel_mainram & ~ASn & sprite_dma_busy;
	wire palette_wait = sel_palette & cpu_read & ~palette_ready;
	wire bgvram_wait  = sel_bgvram  & cpu_read & ~bgvram_ready;
	wire bgvram2_wait = sel_bgvram2 & cpu_read & ~bgvram2_ready;
	wire txvram_wait  = sel_txvram  & cpu_read & ~txvram_ready;
	wire DTACKn = ASn | iack_cycle | rom_wait | mainram_wait | mainram_dma_wait | palette_wait | bgvram_wait | bgvram2_wait | txvram_wait;

	wire [7:0] nmk004_p4;
	wire m68k_extReset = reset | (nmk004_p4[0] & has_nmk004) | prot_loading; // prot_loading: see the protection firmware loader

	wire halt_68k;
	assign dbg_halt_68k = halt_68k;

	fx68k fx68k_inst (
		.clk(clk_sys),
		.HALTn(~halt_68k),
		.extReset(m68k_extReset),
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
	// Address decode — one function for the 68000 and the protection
	// MCU's shared bus (the MCU sees the 68000's map), keyed on map_id.
	// Bit positions of the returned select vector:
	// ------------------------------------------------------------------
	localparam S_ROM = 0, S_IN0 = 1, S_IN1 = 2, S_DSW1 = 3, S_DSW2 = 4, S_NMK004_R = 5,
	           S_FLIP = 6, S_NMI = 7, S_TILEBANK = 8, S_NMK004_W = 9, S_PALETTE = 10,
	           S_SCROLLA = 11, S_SCROLLB = 12, S_SCROLLRAM = 13, S_SCROLLRAMY = 14,
	           S_BGVRAM = 15, S_BGVRAM2 = 16, S_TXVRAM = 17, S_MAINRAM = 18, S_BG0BANK = 19,
	           S_OKI0 = 20, S_OKI1 = 21, S_NMK112 = 22, S_IN2 = 23,
	           S_N = 24;
	function automatic [S_N-1:0] decode(input [23:0] a, input [3:0] m, input [23:0] romtop);
		reg io;          // the 32-byte I/O block
		reg [3:0] r;     // word offset within it
		begin
			decode = {S_N{1'b0}};
			decode[S_ROM] = (a <= romtop);
			case (m)
				M_ACROBATM: io = (a[23:5] == 19'h06000);                            // 0x0C0000
				M_TDRAGON:  io = (a[23:5] == 19'h06000) || (a[23:5] == 19'h07000);  // 0x0C0000 mirror 0x020000
				default:    io = (a[23:5] == 19'h04000);                            // 0x080000
			endcase
			r = a[4:1];
			decode[S_IN0]      = io && (r == 4'h0);
			decode[S_IN1]      = io && (r == 4'h1);
			decode[S_DSW1]     = io && (r == ((m == M_MUSTANG || m == M_THARRIER) ? 4'h2 : 4'h4));   // mustang/tharrier: one 16-bit DSW port at +4, no DSW2
			decode[S_DSW2]     = io && (r == 4'h5) && (m != M_MUSTANG) && (m != M_THARRIER);
			decode[S_NMK004_R] = io && (r == 4'h7);                                                     // tharrier: soundlatch2 read; vandykeb: reads 0
			decode[S_FLIP]     = io && (r == 4'hA) && (m != M_THARRIER);
			decode[S_NMI]      = io && (r == 4'hB);
			decode[S_TILEBANK] = io && (r == 4'hC) && (m != M_MUSTANG) && (m != M_BIOSHIP) && (m != M_STRAHL) && (m != M_THARRIER) && (m != M_BJTWIN);
			decode[S_NMK004_W] = io && (r == 4'hF);                                                     // tharrier: soundlatch write
			case (m)
				M_ACROBATM: begin
					decode[S_PALETTE] = (a >= 24'h0C4000) && (a <= 24'h0C45FF);
					decode[S_SCROLLA] = (a >= 24'h0C8000) && (a <= 24'h0C8007);
					decode[S_BGVRAM]  = (a >= 24'h0CC000) && (a <= 24'h0CFFFF);
					decode[S_TXVRAM]  = (a >= 24'h0D4000) && (a <= 24'h0D47FF);
					decode[S_MAINRAM] = (a >= 24'h080000) && (a <= 24'h08FFFF);
				end
				M_TDRAGON: begin
					decode[S_PALETTE] = (a >= 24'h0C8000) && (a <= 24'h0C87FF);
					decode[S_SCROLLA] = (a >= 24'h0C4000) && (a <= 24'h0C4007);
					decode[S_BGVRAM]  = (a >= 24'h0CC000) && (a <= 24'h0CFFFF);
					decode[S_TXVRAM]  = (a >= 24'h0D0000) && (a <= 24'h0D07FF);
					decode[S_MAINRAM] = (a[23:18] == 6'b000010);                    // 0x080000-0x08FFFF mirror 0x030000
				end
				M_STRAHL: begin
					decode[S_PALETTE] = (a >= 24'h08C000) && (a <= 24'h08C7FF);
					decode[S_SCROLLA] = (a >= 24'h084000) && (a <= 24'h084007);      // scroll_w<0>
					decode[S_SCROLLB] = (a >= 24'h088000) && (a <= 24'h088007);      // scroll_w<1>
					decode[S_BGVRAM]  = (a >= 24'h090000) && (a <= 24'h093FFF);      // bgvideoram0
					decode[S_BGVRAM2] = (a >= 24'h094000) && (a <= 24'h097FFF);      // bgvideoram1
					decode[S_TXVRAM]  = (a >= 24'h09C000) && (a <= 24'h09C7FF);
					decode[S_MAINRAM] = (a >= 24'h0F0000) && (a <= 24'h0FFFFF);
				end
				M_BJTWIN: begin // bjtwin_map: the OKIs and the NMK112 on the 68000 bus, the 8x8 layer's VRAM at 0x09C000 (mirror 0x1000)
					decode[S_OKI0]    = (a[23:1] == 23'h042000);                     // 0x084001
					decode[S_OKI1]    = (a[23:1] == 23'h042008);                     // 0x084011
					decode[S_NMK112]  = (a >= 24'h084020) && (a <= 24'h08402F);
					decode[S_PALETTE] = (a >= 24'h088000) && (a <= 24'h0887FF);
					decode[S_TILEBANK] = (a[23:1] == 23'h04A000);                    // 0x094001 tilebank_w
					decode[S_SCROLLA] = (a[23:1] == 23'h04A001);                     // 0x094003 bjtwin_scroll_w
					decode[S_TXVRAM]  = (a >= 24'h09C000) && (a <= 24'h09DFFF);
					decode[S_MAINRAM] = (a >= 24'h0F0000) && (a <= 24'h0FFFFF);
				end
				M_THARRIER: begin // tharrier_map
					decode[S_IN2]     = (a[23:1] == 23'h040101);                     // 0x080202
					decode[S_PALETTE] = (a >= 24'h088000) && (a <= 24'h0883FF);
					decode[S_BGVRAM]  = (a >= 24'h090000) && (a <= 24'h093FFF);
					decode[S_BGVRAM2] = (a >= 24'h09C000) && (a <= 24'h09C7FF);      // "unused txvideoram area", plain RAM
					decode[S_TXVRAM]  = (a >= 24'h09D000) && (a <= 24'h09D7FF);
					decode[S_MAINRAM] = (a >= 24'h0F0000) && (a <= 24'h0FFFFF);
				end
				M_VANDYKEB: begin // vandykeb_map: vandyke's with the PIC's scroll words at 0x080010/12/1A/1C
					decode[S_SCROLLA] = io && ((r == 4'h8) || (r == 4'h9) || (r == 4'hD) || (r == 4'hE));
					decode[S_PALETTE] = (a >= 24'h088000) && (a <= 24'h0887FF);
					decode[S_BGVRAM]  = (a >= 24'h090000) && (a <= 24'h093FFF);
					decode[S_BGVRAM2] = (a >= 24'h094000) && (a <= 24'h097FFF);
					decode[S_TXVRAM]  = (a >= 24'h09D000) && (a <= 24'h09D7FF);
					decode[S_MAINRAM] = (a >= 24'h0F0000) && (a <= 24'h0FFFFF);
				end
				M_GUNNAIL: begin
					decode[S_PALETTE]    = (a >= 24'h088000) && (a <= 24'h0887FF);
					decode[S_SCROLLRAM]  = (a >= 24'h08C000) && (a <= 24'h08C1FF);
					decode[S_SCROLLRAMY] = (a >= 24'h08C200) && (a <= 24'h08C3FF);
					decode[S_BGVRAM]     = (a >= 24'h090000) && (a <= 24'h093FFF);
					decode[S_TXVRAM]     = (a >= 24'h09C000) && (a <= 24'h09DFFF);   // mirror bit 12 ignored
					decode[S_MAINRAM]    = (a >= 24'h0F0000) && (a <= 24'h0FFFFF);
				end
				default: begin // M_MACROSS, M_MUSTANG, M_BIOSHIP, M_VANDYKE
					decode[S_PALETTE] = (a >= 24'h088000) && (a <= 24'h0887FF);
					decode[S_SCROLLA] = (m == M_MUSTANG) ? (a[23:1] == 23'h046000) :                // mustang_scroll_w, one word
					                    (m == M_BIOSHIP) ? ((a >= 24'h08C010) && (a <= 24'h08C017)) : // scroll_w<0> (the ROM tilemap)
					                                       ((a >= 24'h08C000) && (a <= 24'h08C007));  // scroll_w<0> / vandyke_scroll_w
					decode[S_SCROLLB] = (m == M_BIOSHIP) && (a >= 24'h08C000) && (a <= 24'h08C007);  // scroll_w<1> (the VRAM layer)
					decode[S_BGVRAM]  = (a >= 24'h090000) && (a <= 24'h093FFF);
					decode[S_BGVRAM2] = (m == M_VANDYKE) && (a >= 24'h094000) && (a <= 24'h097FFF);  // "what is this?" RAM
					decode[S_TXVRAM]  = (m == M_VANDYKE) ? ((a >= 24'h09D000) && (a <= 24'h09D7FF))
					                                     : ((a >= 24'h09C000) && (a <= 24'h09C7FF));
					decode[S_MAINRAM] = (a >= 24'h0F0000) && (a <= 24'h0FFFFF);
					decode[S_BG0BANK] = (m == M_BIOSHIP) && (a[23:1] == 23'h042000);                  // bioship_bank_w, 0x084001
				end
			endcase
		end
	endfunction

	wire [S_N-1:0] sel = decode(byte_addr, map_id, rom_max);
	wire sel_rom        = sel[S_ROM];
	wire sel_in0        = sel[S_IN0];
	wire sel_in1        = sel[S_IN1];
	wire sel_dsw1       = sel[S_DSW1];
	wire sel_dsw2       = sel[S_DSW2];
	wire sel_nmk004_r   = sel[S_NMK004_R];
	wire sel_flip       = sel[S_FLIP];
	wire sel_nmi        = sel[S_NMI];
	wire sel_tilebank   = sel[S_TILEBANK];
	wire sel_nmk004_w   = sel[S_NMK004_W];
	wire sel_palette    = sel[S_PALETTE];
	wire sel_scrolla    = sel[S_SCROLLA];
	wire sel_scrollb    = sel[S_SCROLLB];
	wire sel_scrollram  = sel[S_SCROLLRAM];
	wire sel_scrollramy = sel[S_SCROLLRAMY];
	wire sel_bgvram     = sel[S_BGVRAM];
	wire sel_bgvram2    = sel[S_BGVRAM2];
	wire sel_txvram     = sel[S_TXVRAM];
	wire sel_mainram    = sel[S_MAINRAM];
	wire sel_bg0bank    = sel[S_BG0BANK];
	wire sel_oki0       = sel[S_OKI0];
	wire sel_oki1       = sel[S_OKI1];
	wire sel_nmk112     = sel[S_NMK112];
	wire sel_in2        = sel[S_IN2];

	// ------------------------------------------------------------------
	// Protection MCU shared-bus decode (20-bit byte address, same map)
	// ------------------------------------------------------------------
	wire [19:0] prot_addr;
	assign dbg_prot_addr = prot_addr;
	wire        prot_rd, prot_wr;
	wire [7:0]  prot_wdata;
	wire [7:0]  prot_rdata;
	assign dbg_prot_bus_rd = prot_rd;
	assign dbg_prot_bus_wr = prot_wr;

	wire [S_N-1:0] psel = decode({4'd0, prot_addr}, map_id, rom_max);
	wire prot_sel_rom        = psel[S_ROM];
	wire prot_sel_in0        = psel[S_IN0];
	wire prot_sel_in1        = psel[S_IN1];
	wire prot_sel_dsw1       = psel[S_DSW1];
	wire prot_sel_dsw2       = psel[S_DSW2];
	wire prot_sel_nmk004_r   = psel[S_NMK004_R];
	wire prot_sel_flip       = psel[S_FLIP];
	wire prot_sel_nmi        = psel[S_NMI];
	wire prot_sel_tilebank   = psel[S_TILEBANK];
	wire prot_sel_nmk004_w   = psel[S_NMK004_W];
	wire prot_sel_palette    = psel[S_PALETTE];
	wire prot_sel_scrolla    = psel[S_SCROLLA];
	wire prot_sel_scrollram  = psel[S_SCROLLRAM];
	wire prot_sel_scrollramy = psel[S_SCROLLRAMY];
	wire prot_sel_bgvram     = psel[S_BGVRAM];
	wire prot_sel_txvram     = psel[S_TXVRAM];
	wire prot_sel_mainram    = psel[S_MAINRAM];

	// ------------------------------------------------------------------
	// SDRAM image offsets — see header. Per game, contiguous, in .mra
	// part order; every size is the ROM_START file total.
	// ------------------------------------------------------------------
	reg [23:0] BASE_BYTE_NMK004_EXT, BASE_BYTE_PROT, BASE_BYTE_FGTILE, BASE_BYTE_BGTILE,
	           BASE_BYTE_BG2TILE, BASE_BYTE_TILEROM, BASE_BYTE_SPRITES, BASE_BYTE_OKI1, BASE_BYTE_OKI2;
	reg [13:0] PROT_ROM_BYTES_M1; // protection ROM size - 1 (0x1FFF / 0x3FFF)
	always @(*) begin
		PROT_ROM_BYTES_M1 = prot_rom_16k ? 14'h3FFF : 14'h1FFF;
		BASE_BYTE_BG2TILE = 24'h000000; BASE_BYTE_TILEROM = 24'h000000; BASE_BYTE_PROT = 24'h000000;
		case (game_sel)
			G_MACROSS: begin // maincpu 0x80000, ext, boot, nmk-215 0x2000, fg 0x20000, bg 0x200000, spr 0x200000, oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h080000; BASE_BYTE_PROT = 24'h092000; BASE_BYTE_FGTILE = 24'h094000;
				BASE_BYTE_BGTILE = 24'h0B4000; BASE_BYTE_SPRITES = 24'h2B4000; BASE_BYTE_OKI1 = 24'h4B4000; BASE_BYTE_OKI2 = 24'h534000;
			end
			G_BLKHEART, G_TDRAGON, G_HACHAMFP, G_HACHAMFB: begin // maincpu 0x40000, ext, boot, fg 0x20000, bg 0x100000, spr 0x100000, oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h052000;
				BASE_BYTE_BGTILE = 24'h072000; BASE_BYTE_SPRITES = 24'h172000; BASE_BYTE_OKI1 = 24'h272000; BASE_BYTE_OKI2 = 24'h2F2000;
			end
			G_MUSTANG, G_MUSTANGS: begin // maincpu 0x40000, ext, boot, fg 0x20000, bg 0x80000, spr 0x100000 (pair), oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h052000;
				BASE_BYTE_BGTILE = 24'h072000; BASE_BYTE_SPRITES = 24'h0F2000; BASE_BYTE_OKI1 = 24'h1F2000; BASE_BYTE_OKI2 = 24'h272000;
			end
			G_BIOSHIP: begin // maincpu 0x40000, ext, boot, fg 0x10000, bg 0x80000, bg2 0x80000, tilerom 0x20000 (pair), spr 0x80000, oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h052000; BASE_BYTE_BGTILE = 24'h062000;
				BASE_BYTE_BG2TILE = 24'h0E2000; BASE_BYTE_TILEROM = 24'h162000; BASE_BYTE_SPRITES = 24'h182000;
				BASE_BYTE_OKI1 = 24'h202000; BASE_BYTE_OKI2 = 24'h282000;
			end
			G_VANDYKE: begin // maincpu 0x40000, ext, boot, fg 0x10000, bg 0x80000, spr 0x200000 (2 pairs), oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h052000;
				BASE_BYTE_BGTILE = 24'h062000; BASE_BYTE_SPRITES = 24'h0E2000; BASE_BYTE_OKI1 = 24'h2E2000; BASE_BYTE_OKI2 = 24'h362000;
			end
			G_ACROBATM: begin // maincpu 0x40000, ext, boot, fg 0x10000, bg 0x100000, spr 0x180000, oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h052000;
				BASE_BYTE_BGTILE = 24'h062000; BASE_BYTE_SPRITES = 24'h162000; BASE_BYTE_OKI1 = 24'h2E2000; BASE_BYTE_OKI2 = 24'h362000;
			end
			G_STRAHL: begin // maincpu 0x40000, ext, boot, fg 0x10000, bg 0x40000, bg2 0x80000, spr 0x180000, oki 0xA0000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h052000; BASE_BYTE_BGTILE = 24'h062000;
				BASE_BYTE_BG2TILE = 24'h0A2000; BASE_BYTE_SPRITES = 24'h122000; BASE_BYTE_OKI1 = 24'h2A2000; BASE_BYTE_OKI2 = 24'h342000;
			end
			G_HACHAMF, G_TDRAGON1: begin // maincpu 0x40000, ext, boot, nmk-113/110 0x4000, fg 0x20000, bg 0x100000, spr 0x100000, oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_PROT = 24'h052000; BASE_BYTE_FGTILE = 24'h056000;
				BASE_BYTE_BGTILE = 24'h076000; BASE_BYTE_SPRITES = 24'h176000; BASE_BYTE_OKI1 = 24'h276000; BASE_BYTE_OKI2 = 24'h2F6000;
			end
			// Bombjack Twin family: no NMK004 parts; fgtile directly before bgtile (the 8x8 layer's second ROM, see tx_bank_off)
			G_BJTWIN: begin // maincpu 0x40000, nmk-215 0x2000, fg 0x10000, bg 0x100000, spr 0x100000, oki 0x100000 x2
				BASE_BYTE_NMK004_EXT = 24'h000000; BASE_BYTE_PROT = 24'h040000; BASE_BYTE_FGTILE = 24'h042000;
				BASE_BYTE_BGTILE = 24'h052000; BASE_BYTE_SPRITES = 24'h152000; BASE_BYTE_OKI1 = 24'h252000; BASE_BYTE_OKI2 = 24'h352000;
			end
			G_BJTWINP: begin // maincpu 0x40000, fg 0x10000, bg 0x180000, spr 0x100000, oki 0x100000 x2
				BASE_BYTE_NMK004_EXT = 24'h000000; BASE_BYTE_FGTILE = 24'h040000;
				BASE_BYTE_BGTILE = 24'h050000; BASE_BYTE_SPRITES = 24'h1D0000; BASE_BYTE_OKI1 = 24'h2D0000; BASE_BYTE_OKI2 = 24'h3D0000;
			end
			G_BJTWINPA: begin // maincpu 0x40000, nmk-215, fg 0x10000, bg 0x180000, spr 0x100000, oki 0x100000 x2
				BASE_BYTE_NMK004_EXT = 24'h000000; BASE_BYTE_PROT = 24'h040000; BASE_BYTE_FGTILE = 24'h042000;
				BASE_BYTE_BGTILE = 24'h052000; BASE_BYTE_SPRITES = 24'h1D2000; BASE_BYTE_OKI1 = 24'h2D2000; BASE_BYTE_OKI2 = 24'h3D2000;
			end
			G_SABOTENB: begin // maincpu 0x80000, nmk-215, fg 0x10000, bg 0x200000, spr 0x200000, oki 0x100000 x2
				BASE_BYTE_NMK004_EXT = 24'h000000; BASE_BYTE_PROT = 24'h080000; BASE_BYTE_FGTILE = 24'h082000;
				BASE_BYTE_BGTILE = 24'h092000; BASE_BYTE_SPRITES = 24'h292000; BASE_BYTE_OKI1 = 24'h492000; BASE_BYTE_OKI2 = 24'h592000;
			end
			G_CACTUS, G_NOURYOKUP: begin // maincpu 0x80000, fg 0x10000, bg 0x200000, spr 0x200000, oki 0x100000 x2
				BASE_BYTE_NMK004_EXT = 24'h000000; BASE_BYTE_FGTILE = 24'h080000;
				BASE_BYTE_BGTILE = 24'h090000; BASE_BYTE_SPRITES = 24'h290000; BASE_BYTE_OKI1 = 24'h490000; BASE_BYTE_OKI2 = 24'h590000;
			end
			G_THARRIER: begin // maincpu 0x40000, audiocpu 0x10000 (in the NMK004 ext slot), fg 0x10000, bg 0x80000, spr 0x100000 (pair), oki 0x80000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h050000;
				BASE_BYTE_BGTILE = 24'h060000; BASE_BYTE_SPRITES = 24'h0E0000; BASE_BYTE_OKI1 = 24'h1E0000; BASE_BYTE_OKI2 = 24'h260000;
			end
			G_VANDYKEB: begin // maincpu 0x40000, fg 0x10000, bg 0x80000, spr 0x180000 (4 pairs), oki1 0x80000 (4 files)
				BASE_BYTE_NMK004_EXT = 24'h000000; BASE_BYTE_FGTILE = 24'h040000;
				BASE_BYTE_BGTILE = 24'h050000; BASE_BYTE_SPRITES = 24'h0D0000; BASE_BYTE_OKI1 = 24'h250000; BASE_BYTE_OKI2 = 24'h250000;
			end
			G_MUSTANGB3: begin // maincpu 0x40000, Z80 0x10000 (the NMK004 ext slot), mustang's fg 0x20000 / bg 0x80000 / spr 0x100000 (pair), oki 0x20000 x2
				BASE_BYTE_NMK004_EXT = 24'h040000; BASE_BYTE_FGTILE = 24'h050000;
				BASE_BYTE_BGTILE = 24'h070000; BASE_BYTE_SPRITES = 24'h0F0000; BASE_BYTE_OKI1 = 24'h1F0000; BASE_BYTE_OKI2 = 24'h210000;
			end
			default: begin // gunnail
				BASE_BYTE_NMK004_EXT = 24'h080000; BASE_BYTE_PROT = 24'h092000; BASE_BYTE_FGTILE = 24'h094000;
				BASE_BYTE_BGTILE = 24'h0B4000; BASE_BYTE_SPRITES = 24'h1B4000; BASE_BYTE_OKI1 = 24'h3B4000; BASE_BYTE_OKI2 = 24'h434000;
			end
		endcase
	end
	wire [22:0] BASE_WORD_NMK004  = BASE_BYTE_NMK004_EXT[23:1]; // boot at +0x10000 bytes, see nmk004_cache_addr
	wire [22:0] BASE_WORD_FGTILE  = BASE_BYTE_FGTILE[23:1];
	wire [22:0] BASE_WORD_BGTILE  = BASE_BYTE_BGTILE[23:1];
	wire [22:0] BASE_WORD_BG2TILE = BASE_BYTE_BG2TILE[23:1];
	wire [22:0] BASE_WORD_TILEROM = BASE_BYTE_TILEROM[23:1];
	wire [22:0] BASE_WORD_SPRITES = BASE_BYTE_SPRITES[23:1];
	wire [22:0] BASE_WORD_OKI1    = BASE_BYTE_OKI1[23:1];
	wire [22:0] BASE_WORD_OKI2    = BASE_BYTE_OKI2[23:1];
	// Layer A draws bioship's ROM tilemap from bg2tile (gfx3), its VRAM
	// layer (B) from bgtile (gfx1); strahl's bgvram0 (A) is gfx1 and
	// bgvram1 (B) gfx3 — see video_macross2.sv's BG2_LAYER.
	wire [22:0] BASE_WORD_BGTILE_A = g_bioship ? BASE_WORD_BG2TILE : BASE_WORD_BGTILE;
	wire [22:0] BASE_WORD_BGTILE_B = g_strahl  ? BASE_WORD_BG2TILE : BASE_WORD_BGTILE;
	wire [23:0] cfg_tx_bank_off = BASE_BYTE_BGTILE - BASE_BYTE_FGTILE; // bjtwin: the 8x8 layer's bank-1 ROM, relative to fgtile

	// ------------------------------------------------------------------
	// ROM (maincpu), up to 0x80000 bytes. HW_ROMS=1: rom_cache_n over
	// SDRAM port 0, shared with the ioctl_download writes; the cache only
	// sees ROM addresses (see raphero_core.sv's rom_addr_held).
	// ------------------------------------------------------------------
	wire [15:0] rom_dout;
	wire        rom_ready;
	wire        ioctl_rom_wr = ioctl_download && (ioctl_index == 16'd0);
	generate
	if (!HW_ROMS) begin : g_rom_sim
		reg [15:0] rom [0:262143];
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
		assign rom_dout  = rom[byte_addr[18:1]];
		assign rom_ready = 1'b1;
		assign prot_rom_word = rom[prot_addr[18:1]];
		assign sd0_addr = 24'd0; assign sd0_wrl = 1'b0; assign sd0_wrh = 1'b0;
		assign sd0_din  = 16'd0; assign sd0_req = 1'b0;
		assign ioctl_wait = 1'b0;
	end else begin : g_rom_hw
		wire        cache_busy, cache_valid;
		wire [15:0] cache_dout;
		wire [31:0] cache_dout_pair;
		wire [24:1] cache_sd_addr;
		wire        cache_sd_req;

		sdram_req sd0_inst (
			.clk(clk_sys), .reset(por_rst),
			.addr(ioctl_download ? ioctl_addr[24:1] : cache_sd_addr),
			.we(ioctl_rom_wr), .wrl(ioctl_rom_wr & ~ioctl_addr[0]), .wrh(ioctl_rom_wr & ioctl_addr[0]),
			.din({ioctl_dout, ioctl_dout}),
			.req(ioctl_download ? (ioctl_rom_wr & ioctl_wr) : cache_sd_req),
			.busy(cache_busy), .valid(cache_valid), .dout(cache_dout), .dout_pair(cache_dout_pair),
			.sdram_addr(sd0_addr), .sdram_wrl(sd0_wrl), .sdram_wrh(sd0_wrh), .sdram_din(sd0_din),
			.sdram_dout(sd0_dout), .sdram_dout_pair(sd0_dout_pair), .sdram_req(sd0_req), .sdram_ack(sd0_ack),
			.dbg_we_r_o(), .dbg_addr_r_o()
		);
		assign ioctl_wait = ioctl_download & cache_busy;
		assign prot_rom_word = {prot_rom_din, prot_rom_din}; // byte cache: the wanted byte at both positions

		reg [18:1] rom_addr_held;
		always @(posedge clk_sys) if (sel_rom) rom_addr_held <= byte_addr[18:1];
		wire [18:1] rom_cache_addr = sel_rom ? byte_addr[18:1] : rom_addr_held;
		// 16 pairs + next-pair prefetch instead of rom_cache1's single
		// pair: see rtl/rom_cache_n.sv (68000 slowdown vs MAME).
		rom_cache_n #(.LINES(16), .PREFETCH(1), .LAST_PAIR(22'h01FFFF)) rom_cache_inst (
			.clk(clk_sys), .reset(reset | ioctl_download),
			.addr(rom_cache_addr), .data(rom_dout), .ready(rom_ready),
			.sd_addr(cache_sd_addr), .sd_req(cache_sd_req),
			.sd_busy(cache_busy), .sd_valid(cache_valid), .sd_dout(cache_dout), .sd_dout_pair(cache_dout_pair)
		);
`ifdef VERILATOR
		reg [15:0] golden_rom [0:262143];
		initial if (ROM_FILE != "") $readmemh(ROM_FILE, golden_rom);
		reg [31:0] rom_words_checked = 32'd0, rom_words_wrong = 32'd0;
		reg        dtackn_d = 1'b1;
		always @(posedge clk_sys) begin
			dtackn_d <= DTACKn;
			if (ROM_FILE != "" && dtackn_d && !DTACKn && sel_rom && cpu_read) begin
				rom_words_checked <= rom_words_checked + 32'd1;
				if (rom_dout != golden_rom[byte_addr[18:1]]) begin
					rom_words_wrong <= rom_words_wrong + 32'd1;
					if (rom_words_wrong < 32'd10)
						$display("[%0t] ROM wrong word: addr=%06x got=%04x golden=%04x", $time, byte_addr, rom_dout, golden_rom[byte_addr[18:1]]);
				end
			end
		end
		final $display("ROM golden-word audit: %0d words checked, %0d wrong", rom_words_checked, rom_words_wrong);
`endif
	end
	endgenerate

	// ------------------------------------------------------------------
	// Protection-MCU shared-bus arbitration onto the RAM ports (HW_ROMS=1).
	// Each on-chip RAM has one CPU-side port (read + write, registered
	// read for block-RAM inference) and one video-side port. The
	// protection MCU steals the CPU-side port for a cycle whenever the
	// 68000 is not mid-cycle on that RAM; the 68000's own combinational
	// ready flag (registered address == its address AND the last read was
	// its own) then holds DTACK for the one clock it lost. The MCU's cen
	// is withheld until its read has been served (prot_rd_ready) or its
	// write performed once (prot_wr_done).
	// ------------------------------------------------------------------
	wire prot_acc = prot_rd | prot_wr;
	reg  prot_wr_done;
	wire prot_reg_w = prot_wr & (HW_ROMS ? ~prot_wr_done : prot_cen); // an MCU register/scroll write this clock (once per bus cycle)
	wire mainram_prot_grant, palette_prot_grant, bgvram_prot_grant, txvram_prot_grant; // 1 = the MCU owns that RAM's CPU-side port this clock
	wire [15:0] prot_rom_word;

	// ------------------------------------------------------------------
	// Main work RAM (32768 x 16, plain — no address swap on these boards)
	// ------------------------------------------------------------------
	// Two 8-bit lane arrays with the shared 68000/MCU port coded as a
	// true-dual-port read/write port (its read register takes the byte
	// being written, otherwise the array): Quartus 17 then infers ONE
	// M10K set in BIDIR_DUAL_PORT mode (port A here, port B the video
	// read) instead of a simple-dual-port set plus a second full copy
	// for the video read, which the old-data read-during-write of a
	// 16-bit array with lane writes forced on every dual-read RAM (NMK-10;
	// raphero_core.sv has the isolated synthesis test's story).
	// mainram_strange (macross_map & co.): a 68000 byte write stores the
	// byte in BOTH lanes (mainram_strange_w — the 68000 replicates the
	// byte on both halves of its data bus, and this board's RAM takes
	// both), so UDS/LDS are ignored there.
	reg [7:0] mainram_hi [0:32767];
	reg [7:0] mainram_lo [0:32767];
	// tharrier's MCU-read simulation returns mainram word 0x9064 (see the
	// MCU block): during that I/O read the RAM port is free, so point it there.
	wire [14:0] mainram_addr_cpu = (g_tharrier & sel_in1) ? 15'h4832 : byte_addr[15:1];
	wire        mr_uds = ~UDSn | mainram_strange;
	wire        mr_lds = ~LDSn | mainram_strange;
	reg  [15:0] mainram_dout;
	wire        mainram_ready;
	wire        prot_mainram_ready;
	wire [15:0] prot_mainram_dout;
	generate
	if (!HW_ROMS) begin : g_mainram_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_mainram & prot_cen) begin
				if (~prot_addr[0]) mainram_hi[prot_addr[15:1]] <= prot_wdata;
				else                mainram_lo[prot_addr[15:1]] <= prot_wdata;
			end else if (sel_mainram & cpu_write & ~sprite_dma_busy) begin
				if (mr_uds) mainram_hi[mainram_addr_cpu] <= oEdb[15:8];
				if (mr_lds) mainram_lo[mainram_addr_cpu] <= oEdb[7:0];
			end
		end
		always @(*) mainram_dout = {mainram_hi[mainram_addr_cpu], mainram_lo[mainram_addr_cpu]};
		assign mainram_ready      = 1'b1;
		assign prot_mainram_dout  = {mainram_hi[prot_addr[15:1]], mainram_lo[prot_addr[15:1]]};
		assign prot_mainram_ready = 1'b1;
		assign mainram_prot_grant = 1'b1;
	end else begin : g_mainram_hw
		wire        grant = prot_acc & prot_sel_mainram & ~(sel_mainram & ~ASn) & ~sprite_dma_busy;
		wire [14:0] port_addr = grant ? prot_addr[15:1] : mainram_addr_cpu;
		reg  [14:0] port_addr_r;
		reg         port_src_r;
		wire        prot_w = grant & prot_wr & ~prot_wr_done;
		wire        we_hi = (prot_w & ~prot_addr[0]) | (~grant & sel_mainram & cpu_write & mr_uds & ~sprite_dma_busy);
		wire        we_lo = (prot_w &  prot_addr[0]) | (~grant & sel_mainram & cpu_write & mr_lds & ~sprite_dma_busy);
		wire [7:0]  wd_hi = prot_w ? prot_wdata : oEdb[15:8];
		wire [7:0]  wd_lo = prot_w ? prot_wdata : oEdb[7:0];
		always @(posedge clk_sys) begin
			if (we_hi) begin mainram_hi[port_addr] <= wd_hi; mainram_dout[15:8] <= wd_hi; end
			else       mainram_dout[15:8] <= mainram_hi[port_addr];
			if (we_lo) begin mainram_lo[port_addr] <= wd_lo; mainram_dout[7:0]  <= wd_lo; end
			else       mainram_dout[7:0]  <= mainram_lo[port_addr];
			port_addr_r  <= port_addr;
			port_src_r   <= grant;
		end
		assign mainram_ready      = ~port_src_r & (port_addr_r == mainram_addr_cpu);
		assign prot_mainram_dout  = mainram_dout;
		assign prot_mainram_ready = port_src_r & (port_addr_r == prot_addr[15:1]);
		assign mainram_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Palette RAM (1024 x 16)
	// ------------------------------------------------------------------
	reg [15:0] palette [0:1023];
	wire [9:0] palette_addr = byte_addr[10:1];
	reg  [15:0] palette_dout;
	wire        palette_ready;
	wire        prot_palette_ready;
	wire [15:0] prot_palette_dout;
	generate
	if (!HW_ROMS) begin : g_palette_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_palette & prot_cen) begin
				if (~prot_addr[0]) palette[prot_addr[10:1]][15:8] <= prot_wdata;
				else                palette[prot_addr[10:1]][7:0]  <= prot_wdata;
			end else if (sel_palette & cpu_write) begin
				if (~UDSn) palette[palette_addr][15:8] <= oEdb[15:8];
				if (~LDSn) palette[palette_addr][7:0]  <= oEdb[7:0];
			end
		end
		always @(*) palette_dout = palette[palette_addr];
		assign palette_ready      = 1'b1;
		assign prot_palette_dout  = palette[prot_addr[10:1]];
		assign prot_palette_ready = 1'b1;
		assign palette_prot_grant = 1'b1;
	end else begin : g_palette_hw
		wire       grant = prot_acc & prot_sel_palette & ~(sel_palette & ~ASn);
		wire [9:0] port_addr = grant ? prot_addr[10:1] : palette_addr;
		reg  [9:0] port_addr_r;
		reg        port_src_r;
		wire       prot_w = grant & prot_wr & ~prot_wr_done;
		always @(posedge clk_sys) begin
			if ((prot_w & ~prot_addr[0]) | (~grant & sel_palette & cpu_write & ~UDSn)) palette[port_addr][15:8] <= prot_w ? prot_wdata : oEdb[15:8];
			if ((prot_w &  prot_addr[0]) | (~grant & sel_palette & cpu_write & ~LDSn)) palette[port_addr][7:0]  <= prot_w ? prot_wdata : oEdb[7:0];
			palette_dout <= palette[port_addr];
			port_addr_r  <= port_addr;
			port_src_r   <= grant;
		end
		assign palette_ready      = ~port_src_r & (port_addr_r == palette_addr);
		assign prot_palette_dout  = palette_dout;
		assign prot_palette_ready = port_src_r & (port_addr_r == prot_addr[10:1]);
		assign palette_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// BG tilemap VRAM (8192 x 16) — bgvideoram0 (bioship: bgvideoram1,
	// its VRAM layer; the video-side mux below routes it to layer B there)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port shared port, as mainram above (NMK-10).
	reg [7:0] bgvram_hi [0:8191];
	reg [7:0] bgvram_lo [0:8191];
	wire [12:0] bgvram_addr = byte_addr[13:1];
	reg  [15:0] bgvram_dout;
	wire        bgvram_ready;
	wire        prot_bgvram_ready;
	wire [15:0] prot_bgvram_dout;
	generate
	if (!HW_ROMS) begin : g_bgvram_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_bgvram & prot_cen) begin
				if (~prot_addr[0]) bgvram_hi[prot_addr[13:1]] <= prot_wdata;
				else                bgvram_lo[prot_addr[13:1]] <= prot_wdata;
			end else if (sel_bgvram & cpu_write) begin
				if (~UDSn) bgvram_hi[bgvram_addr] <= oEdb[15:8];
				if (~LDSn) bgvram_lo[bgvram_addr] <= oEdb[7:0];
			end
		end
		always @(*) bgvram_dout = {bgvram_hi[bgvram_addr], bgvram_lo[bgvram_addr]};
		assign bgvram_ready      = 1'b1;
		assign prot_bgvram_dout  = {bgvram_hi[prot_addr[13:1]], bgvram_lo[prot_addr[13:1]]};
		assign prot_bgvram_ready = 1'b1;
		assign bgvram_prot_grant = 1'b1;
	end else begin : g_bgvram_hw
		wire        grant = prot_acc & prot_sel_bgvram & ~(sel_bgvram & ~ASn);
		wire [12:0] port_addr = grant ? prot_addr[13:1] : bgvram_addr;
		reg  [12:0] port_addr_r;
		reg         port_src_r;
		wire        prot_w = grant & prot_wr & ~prot_wr_done;
		wire        we_hi = (prot_w & ~prot_addr[0]) | (~grant & sel_bgvram & cpu_write & ~UDSn);
		wire        we_lo = (prot_w &  prot_addr[0]) | (~grant & sel_bgvram & cpu_write & ~LDSn);
		wire [7:0]  wd_hi = prot_w ? prot_wdata : oEdb[15:8];
		wire [7:0]  wd_lo = prot_w ? prot_wdata : oEdb[7:0];
		always @(posedge clk_sys) begin
			if (we_hi) begin bgvram_hi[port_addr] <= wd_hi; bgvram_dout[15:8] <= wd_hi; end
			else       bgvram_dout[15:8] <= bgvram_hi[port_addr];
			if (we_lo) begin bgvram_lo[port_addr] <= wd_lo; bgvram_dout[7:0]  <= wd_lo; end
			else       bgvram_dout[7:0]  <= bgvram_lo[port_addr];
			port_addr_r <= port_addr;
			port_src_r  <= grant;
		end
		assign bgvram_ready      = ~port_src_r & (port_addr_r == bgvram_addr);
		assign prot_bgvram_dout  = bgvram_dout;
		assign prot_bgvram_ready = port_src_r & (port_addr_r == prot_addr[13:1]);
		assign bgvram_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Second BG VRAM (8192 x 16, 2026-09-11): strahl's bgvideoram1
	// (0x094000, layer B), vandyke's unknown RAM at 0x094000 (plain
	// read/write, never drawn), and bioship's ROM tilemap page — filled
	// by the DMA engine below from the "tilerom" region (8 x 8192 words,
	// bioship_bank_w selects the page) and drawn as layer A. No
	// protection-MCU port (none of these boards has an MCU).
	// ------------------------------------------------------------------
	reg [7:0] bgvram2_hi [0:8191];
	reg [7:0] bgvram2_lo [0:8191];
	wire [12:0] bgvram2_addr_cpu = byte_addr[13:1];
	reg  [15:0] bgvram2_dout;
	wire        bgvram2_ready;
	wire        dma_active;   // the tilemap DMA owns the CPU-side port
	wire        dma_we;
	wire [12:0] dma_addr;
	wire [15:0] dma_wdata;
	generate
	if (!HW_ROMS) begin : g_bgvram2_sim
		always @(posedge clk_sys) begin
			if (dma_we) begin
				bgvram2_hi[dma_addr] <= dma_wdata[15:8];
				bgvram2_lo[dma_addr] <= dma_wdata[7:0];
			end else if (sel_bgvram2 & cpu_write) begin
				if (~UDSn) bgvram2_hi[bgvram2_addr_cpu] <= oEdb[15:8];
				if (~LDSn) bgvram2_lo[bgvram2_addr_cpu] <= oEdb[7:0];
			end
		end
		always @(*) bgvram2_dout = {bgvram2_hi[bgvram2_addr_cpu], bgvram2_lo[bgvram2_addr_cpu]};
		assign bgvram2_ready = 1'b1;
	end else begin : g_bgvram2_hw
		wire [12:0] port_addr = dma_active ? dma_addr : bgvram2_addr_cpu;
		reg  [12:0] port_addr_r;
		reg         port_src_r;
		wire        we_hi = dma_we | (~dma_active & sel_bgvram2 & cpu_write & ~UDSn);
		wire        we_lo = dma_we | (~dma_active & sel_bgvram2 & cpu_write & ~LDSn);
		wire [7:0]  wd_hi = dma_active ? dma_wdata[15:8] : oEdb[15:8];
		wire [7:0]  wd_lo = dma_active ? dma_wdata[7:0]  : oEdb[7:0];
		always @(posedge clk_sys) begin
			if (we_hi) begin bgvram2_hi[port_addr] <= wd_hi; bgvram2_dout[15:8] <= wd_hi; end
			else       bgvram2_dout[15:8] <= bgvram2_hi[port_addr];
			if (we_lo) begin bgvram2_lo[port_addr] <= wd_lo; bgvram2_dout[7:0]  <= wd_lo; end
			else       bgvram2_dout[7:0]  <= bgvram2_lo[port_addr];
			port_addr_r <= port_addr;
			port_src_r  <= dma_active;
		end
		assign bgvram2_ready = ~port_src_r & (port_addr_r == bgvram2_addr_cpu);
	end
	endgenerate

	// ------------------------------------------------------------------
	// TX tilemap VRAM (2048 x 16; the lowres boards use the first 1024)
	// ------------------------------------------------------------------
	// Lane arrays + true-dual-port shared port, as mainram above (NMK-10).
	reg [7:0] txvram_hi [0:2047];
	reg [7:0] txvram_lo [0:2047];
	wire [10:0] txvram_addr = byte_addr[11:1];
	reg  [15:0] txvram_dout;
	wire        txvram_ready;
	wire        prot_txvram_ready;
	wire [15:0] prot_txvram_dout;
	generate
	if (!HW_ROMS) begin : g_txvram_sim
		always @(posedge clk_sys) begin
			if (prot_wr & prot_sel_txvram & prot_cen) begin
				if (~prot_addr[0]) txvram_hi[prot_addr[11:1]] <= prot_wdata;
				else                txvram_lo[prot_addr[11:1]] <= prot_wdata;
			end else if (sel_txvram & cpu_write) begin
				if (~UDSn) txvram_hi[txvram_addr] <= oEdb[15:8];
				if (~LDSn) txvram_lo[txvram_addr] <= oEdb[7:0];
			end
		end
		always @(*) txvram_dout = {txvram_hi[txvram_addr], txvram_lo[txvram_addr]};
		assign txvram_ready      = 1'b1;
		assign prot_txvram_dout  = {txvram_hi[prot_addr[11:1]], txvram_lo[prot_addr[11:1]]};
		assign prot_txvram_ready = 1'b1;
		assign txvram_prot_grant = 1'b1;
	end else begin : g_txvram_hw
		wire        grant = prot_acc & prot_sel_txvram & ~(sel_txvram & ~ASn);
		wire [10:0] port_addr = grant ? prot_addr[11:1] : txvram_addr;
		reg  [10:0] port_addr_r;
		reg         port_src_r;
		wire        prot_w = grant & prot_wr & ~prot_wr_done;
		wire        we_hi = (prot_w & ~prot_addr[0]) | (~grant & sel_txvram & cpu_write & ~UDSn);
		wire        we_lo = (prot_w &  prot_addr[0]) | (~grant & sel_txvram & cpu_write & ~LDSn);
		wire [7:0]  wd_hi = prot_w ? prot_wdata : oEdb[15:8];
		wire [7:0]  wd_lo = prot_w ? prot_wdata : oEdb[7:0];
		always @(posedge clk_sys) begin
			if (we_hi) begin txvram_hi[port_addr] <= wd_hi; txvram_dout[15:8] <= wd_hi; end
			else       txvram_dout[15:8] <= txvram_hi[port_addr];
			if (we_lo) begin txvram_lo[port_addr] <= wd_lo; txvram_dout[7:0]  <= wd_lo; end
			else       txvram_dout[7:0]  <= txvram_lo[port_addr];
			port_addr_r <= port_addr;
			port_src_r  <= grant;
		end
		assign txvram_ready      = ~port_src_r & (port_addr_r == txvram_addr);
		assign prot_txvram_dout  = txvram_dout;
		assign prot_txvram_ready = port_src_r & (port_addr_r == prot_addr[11:1]);
		assign txvram_prot_grant = grant;
	end
	endgenerate

	// ------------------------------------------------------------------
	// gunnail_scrollram / gunnail_scrollramy (256 x 16 each, write-only
	// for the 68000 — reads fall through to the unmapped 0xFFFF). One
	// 512 x 16 array: [0:255] X table, [256:511] Y table. Word 0 of each
	// is mirrored in a register for the video's scrollram_0/scrollramy_0
	// taps; the rows are read through the video port (registered, two
	// rows on alternate cycles). gunnail only.
	// ------------------------------------------------------------------
	reg [15:0] scrollmem [0:511];
	wire       sel_scrollmem      = sel_scrollram | sel_scrollramy;
	wire       prot_sel_scrollmem = prot_sel_scrollram | prot_sel_scrollramy;
	wire [8:0] scroll_addr_cpu  = {sel_scrollramy, byte_addr[8:1]};
	wire [8:0] scroll_addr_prot = {prot_sel_scrollramy, prot_addr[8:1]};
	reg [15:0] scrollram0_reg, scrollramy0_reg;
	wire [7:0]  vid_scroll_row_addr;
	wire [15:0] vid_scrollram_row, vid_scrollramy_row;
	// Write port: the protection MCU's byte write wins the cycle (it is
	// also the rarer one); the 68000 write is byte-enabled.
	wire        scroll_prot_w = prot_wr & prot_sel_scrollmem & (HW_ROMS ? ~prot_wr_done : prot_cen);
	wire [8:0]  scroll_waddr  = scroll_prot_w ? scroll_addr_prot : scroll_addr_cpu;
	wire        scroll_cpu_w  = sel_scrollmem & cpu_write & ~scroll_prot_w;
	wire        scroll_w_hi   = (scroll_prot_w & ~prot_addr[0]) | (scroll_cpu_w & ~UDSn);
	wire        scroll_w_lo   = (scroll_prot_w &  prot_addr[0]) | (scroll_cpu_w & ~LDSn);
	wire [7:0]  scroll_w_hi_d = scroll_prot_w ? prot_wdata : oEdb[15:8];
	wire [7:0]  scroll_w_lo_d = scroll_prot_w ? prot_wdata : oEdb[7:0];
	always @(posedge clk_sys) begin
		if (reset) begin
			scrollram0_reg  <= 16'h0000;
			scrollramy0_reg <= 16'h0000;
		end else begin
			if (scroll_waddr == 9'd0) begin
				if (scroll_w_hi) scrollram0_reg[15:8] <= scroll_w_hi_d;
				if (scroll_w_lo) scrollram0_reg[7:0]  <= scroll_w_lo_d;
			end
			if (scroll_waddr == 9'd256) begin
				if (scroll_w_hi) scrollramy0_reg[15:8] <= scroll_w_hi_d;
				if (scroll_w_lo) scrollramy0_reg[7:0]  <= scroll_w_lo_d;
			end
		end
	end
	generate
	if (!HW_ROMS) begin : g_scrollmem_sim
		always @(posedge clk_sys) begin
			if (scroll_w_hi) scrollmem[scroll_waddr][15:8] <= scroll_w_hi_d;
			if (scroll_w_lo) scrollmem[scroll_waddr][7:0]  <= scroll_w_lo_d;
		end
		assign vid_scrollram_row  = scrollmem[{1'b0, vid_scroll_row_addr}];
		assign vid_scrollramy_row = scrollmem[{1'b1, vid_scroll_row_addr}];
	end else begin : g_scrollmem_hw
		reg        vid_scroll_phase = 1'b0, vid_scroll_phase_d;
		reg [15:0] vid_scroll_q, vid_scrollram_row_r, vid_scrollramy_row_r;
		always @(posedge clk_sys) begin
			if (scroll_w_hi) scrollmem[scroll_waddr][15:8] <= scroll_w_hi_d;
			if (scroll_w_lo) scrollmem[scroll_waddr][7:0]  <= scroll_w_lo_d;
			vid_scroll_phase   <= ~vid_scroll_phase;
			vid_scroll_phase_d <= vid_scroll_phase;
			vid_scroll_q       <= scrollmem[{vid_scroll_phase, vid_scroll_row_addr}];
			if (vid_scroll_phase_d) vid_scrollramy_row_r <= vid_scroll_q;
			else                    vid_scrollram_row_r  <= vid_scroll_q;
		end
		assign vid_scrollram_row  = vid_scrollram_row_r;
		assign vid_scrollramy_row = vid_scrollramy_row_r;
	end
	endgenerate

	// ------------------------------------------------------------------
	// Frame-constant scroll registers (every game but gunnail), in the
	// board's own format (nmk16_v.cpp):
	//   scroll_w<Layer> (macross_map/acrobatm/tdragon/hachamf/strahl on
	//     the LOW byte of words 0x...0/2/4/6; bioship on the HIGH byte —
	//     umask16(0xff00)): bytes [Xhi, Xlo, Yhi, Ylo]
	//   vandyke_scroll_w: four words, x = v0*256 + (v1>>8), y = v2*256 + (v3>>8)
	//   mustang_scroll_w: one word, data[15:8] selects: 0 = x high byte,
	//     1 = x low byte, 2/3 = ignored; no y scroll
	// The protection MCU's byte writes reach scroll_w<0> too (odd
	// addresses on the low-byte boards).
	// ------------------------------------------------------------------
	reg [7:0]  scr_a [0:3];
	reg [7:0]  scr_b [0:3];
	reg [15:0] vsc   [0:3];
	reg [15:0] must_x;
	wire [1:0] scr_idx = byte_addr[2:1];
	// vandykeb_scroll_w: word offsets 0,1,5,6 of 0x080010 -> m_vscroll[3],[2],[1],[0]
	wire [1:0] vsc_idx = g_vandykeb ? (byte_addr[4:1] == 4'h8 ? 2'd3 : byte_addr[4:1] == 4'h9 ? 2'd2 : byte_addr[4:1] == 4'hD ? 2'd1 : 2'd0) : scr_idx;
	wire       scr_hi_byte = g_bioship; // the register byte travels on the high half
	integer si;
	always @(posedge clk_sys) begin
		if (reset) begin
			for (si = 0; si < 4; si = si + 1) begin scr_a[si] <= 8'h00; scr_b[si] <= 8'h00; vsc[si] <= 16'h0000; end
			must_x <= 16'h0000;
		end else begin
			if (prot_reg_w & prot_sel_scrolla & prot_addr[0] & ~g_vandyke & ~g_mustang & ~g_bioship)
				scr_a[prot_addr[2:1]] <= prot_wdata;
			else if (sel_scrolla & cpu_write) begin
				if (g_vandyke | g_vandykeb) begin
					if (~UDSn) vsc[vsc_idx][15:8] <= oEdb[15:8];
					if (~LDSn) vsc[vsc_idx][7:0]  <= oEdb[7:0];
				end else if (g_mustang) begin
					case (oEdb[15:8])
						8'h00: must_x[15:8] <= oEdb[7:0];
						8'h01: must_x[7:0]  <= oEdb[7:0];
						default: ;
					endcase
				end else if (scr_hi_byte) begin
					if (~UDSn) scr_a[scr_idx] <= oEdb[15:8];
				end else begin
					if (~LDSn) scr_a[scr_idx] <= oEdb[7:0];
				end
			end
			if (sel_scrollb & cpu_write) begin
				if (scr_hi_byte) begin
					if (~UDSn) scr_b[scr_idx] <= oEdb[15:8];
				end else begin
					if (~LDSn) scr_b[scr_idx] <= oEdb[7:0];
				end
			end
		end
	end
	// tharrier: screen_update_tharrier takes the BG X scroll from main RAM
	// word 0x9F00 ("the protection device probably copies this to the
	// regs") — snooped from the 68000's writes here.
	reg [15:0] th_scroll;
	always @(posedge clk_sys) begin
		if (reset) th_scroll <= 16'h0000;
		else if (sel_mainram & cpu_write & ~sprite_dma_busy & (byte_addr[15:1] == 15'h4F80)) begin
			if (mr_uds) th_scroll[15:8] <= oEdb[15:8];
			if (mr_lds) th_scroll[7:0]  <= oEdb[7:0];
		end
	end
	wire [15:0] bga_xscroll = (g_vandyke | g_vandykeb) ? {vsc[0][7:0], vsc[1][15:8]} : g_mustang ? must_x : g_tharrier ? th_scroll : {scr_a[0], scr_a[1]};
	wire [15:0] bga_yscroll = (g_vandyke | g_vandykeb) ? {vsc[2][7:0], vsc[3][15:8]} : (g_mustang | g_tharrier) ? 16'h0000 : {scr_a[2], scr_a[3]};
	wire [15:0] bgb_xscroll = {scr_b[0], scr_b[1]};
	wire [15:0] bgb_yscroll = {scr_b[2], scr_b[3]};

	// ------------------------------------------------------------------
	// Dual-port video read taps
	// ------------------------------------------------------------------
	wire [14:0] vid_bgvram_addr;     // layer A (bit 14:13 = tilerambank, always 0 here)
	wire [15:0] vid_bgvram_dout;
	wire [12:0] vid_bgvram_b_addr;   // layer B
	wire [15:0] vid_bgvram_b_dout;
	wire [10:0] vid_txvram_addr;
	wire [15:0] vid_txvram_dout;
	wire [10:0] vid_palette_addr;     // 11 bits: video_macross2.sv's port; bit 10 is only set in its powerins mode
	wire [15:0] vid_palette_dout;
	wire [10:0] vid_spr_palette_addr;
	wire [15:0] vid_spr_palette_dout;
	generate
	if (!HW_ROMS) begin : g_vidpal_sim
		assign vid_palette_dout     = palette[vid_palette_addr[9:0]];
		assign vid_spr_palette_dout = palette[vid_spr_palette_addr[9:0]];
	end else begin : g_vidpal_hw
		// Registered reads — video_macross2.sv's HW_ROMS=1 palette-tap
		// contract (one clock behind the address), so the palette infers
		// as block RAM on every port (NMK-10; the CPU/MCU port above
		// already was).
		reg [15:0] vid_palette_dout_r, vid_spr_palette_dout_r;
		always @(posedge clk_sys) begin
			vid_palette_dout_r     <= palette[vid_palette_addr[9:0]];
			vid_spr_palette_dout_r <= palette[vid_spr_palette_addr[9:0]];
		end
		assign vid_palette_dout     = vid_palette_dout_r;
		assign vid_spr_palette_dout = vid_spr_palette_dout_r;
	end
	endgenerate
	// Layer A draws bgvram (the 68000's BG VRAM) except on bioship, where
	// it draws the DMA-filled ROM tilemap page in bgvram2 and layer B
	// draws bgvram; strahl's layer B draws bgvram2 (its bgvideoram1).
	wire [12:0] vid_arr1_addr = g_bioship ? vid_bgvram_b_addr : vid_bgvram_addr[12:0];
	wire [12:0] vid_arr2_addr = g_bioship ? vid_bgvram_addr[12:0] : vid_bgvram_b_addr;
	wire [15:0] vid_arr1_dout, vid_arr2_dout;
	assign vid_bgvram_dout   = g_bioship ? vid_arr2_dout : vid_arr1_dout;
	assign vid_bgvram_b_dout = g_bioship ? vid_arr1_dout : vid_arr2_dout;
	wire [14:0] vid_mainram_addr;
	wire [15:0] vid_mainram_dout;
	wire        vid_mainram_ready;
	generate
	if (!HW_ROMS) begin : g_vidram_read_sim
		assign vid_arr1_dout    = {bgvram_hi[vid_arr1_addr],   bgvram_lo[vid_arr1_addr]};
		assign vid_arr2_dout    = {bgvram2_hi[vid_arr2_addr],  bgvram2_lo[vid_arr2_addr]};
		assign vid_txvram_dout  = {txvram_hi[vid_txvram_addr],  txvram_lo[vid_txvram_addr]};
		assign vid_mainram_dout = {mainram_hi[vid_mainram_addr], mainram_lo[vid_mainram_addr]};
		assign vid_mainram_ready = 1'b1;
	end else begin : g_vidram_read_hw
		reg [15:0] vid_arr1_dout_r, vid_arr2_dout_r, vid_txvram_dout_r, vid_mainram_dout_r;
		reg [14:0] vid_mainram_addr_r;
		always @(posedge clk_sys) begin
			vid_arr1_dout_r    <= {bgvram_hi[vid_arr1_addr],   bgvram_lo[vid_arr1_addr]};
			vid_arr2_dout_r    <= {bgvram2_hi[vid_arr2_addr],  bgvram2_lo[vid_arr2_addr]};
			vid_txvram_dout_r  <= {txvram_hi[vid_txvram_addr],  txvram_lo[vid_txvram_addr]};
			vid_mainram_dout_r <= {mainram_hi[vid_mainram_addr], mainram_lo[vid_mainram_addr]};
			vid_mainram_addr_r <= vid_mainram_addr;
		end
		assign vid_arr1_dout     = vid_arr1_dout_r;
		assign vid_arr2_dout     = vid_arr2_dout_r;
		assign vid_txvram_dout   = vid_txvram_dout_r;
		assign vid_mainram_dout  = vid_mainram_dout_r;
		assign vid_mainram_ready = (vid_mainram_addr_r == vid_mainram_addr);
	end
	endgenerate

	generate
	if (!HW_ROMS) begin : g_dbgram_sim
		assign dbg_pal_data = palette[dbg_pal_addr];
		assign dbg_bgvram_data = {bgvram_hi[dbg_bgvram_addr[12:0]], bgvram_lo[dbg_bgvram_addr[12:0]]};
		assign dbg_txvram_data = {txvram_hi[dbg_txvram_addr], txvram_lo[dbg_txvram_addr]};
	end else begin : g_dbgram_hw
		assign dbg_pal_data = 16'd0;
		assign dbg_bgvram_data = 16'd0;
		assign dbg_txvram_data = 16'd0;
	end
	endgenerate

	// ------------------------------------------------------------------
	// I/O registers — protection MCU write wins a same-cycle conflict.
	// ------------------------------------------------------------------
	reg [7:0]  flip_screen_reg;
	reg [7:0]  bgbank_reg;
	reg [7:0]  bg0bank_reg;   // bioship_bank_w: the ROM tilemap's page
	reg [7:0]  tx_scroll_reg; // bjtwin_scroll_w
	reg        nmi_level;
	always @(posedge clk_sys) begin
		if (reset) begin
			flip_screen_reg <= 8'h00;
			bgbank_reg      <= 8'h00;
			bg0bank_reg     <= 8'h00;
			tx_scroll_reg   <= 8'h00;
			nmi_level       <= 1'b0;
		end else begin
			if (prot_reg_w & prot_sel_flip)           flip_screen_reg <= prot_wdata;
			else if (sel_flip & cpu_write & ~LDSn)     flip_screen_reg <= oEdb[7:0];

			if (prot_reg_w & prot_sel_tilebank)       bgbank_reg <= prot_wdata;
			else if (sel_tilebank & cpu_write & ~LDSn) bgbank_reg <= oEdb[7:0];

			if (sel_bg0bank & cpu_write & ~LDSn)       bg0bank_reg <= oEdb[7:0];
			if (g_bjtwin & sel_scrolla & cpu_write & ~LDSn) tx_scroll_reg <= oEdb[7:0]; // bjtwin_scroll_w: scrolly = -data

			// nmk004_x0016_w: NMI level = bit 0; bioship's own inverts it
			// ("otherwise bioship doesn't hit the NMI enough").
			if (prot_reg_w & prot_sel_nmi)            nmi_level <= prot_wdata[0] ^ nmi_invert;
			else if (sel_nmi & cpu_write)              nmi_level <= oEdb[0] ^ nmi_invert;
		end
	end

	// ------------------------------------------------------------------
	// bioship ROM-tilemap DMA (2026-09-11): MAME's bioship_get_bg_tile_info
	// reads the tile index from the "tilerom" region at (bank << 13) |
	// tile_index on every tile fetch. The hardware path cannot afford a
	// second real-time index stream from SDRAM, so the selected 8192-word
	// page is copied into bgvram2 instead — at reset and whenever
	// bioship_bank_w changes the page (about 100k clk_sys = 2.5 ms per
	// copy through the port-3 arbiter; the game changes the page between
	// stages). HW_ROMS=0 copies from the TILEROM_FILE array the same way,
	// one word per clock.
	// ------------------------------------------------------------------
	reg        dma_run = 1'b0;
	reg [12:0] dma_idx;
	reg [2:0]  dma_bank;
	reg [3:0]  dma_bank_loaded;  // 4'hF = nothing loaded yet
	reg        dma_req;
	reg        dma_gap;          // one idle clock between transactions (the arbiter samples req low)
	wire [15:0] dma_word;
	wire        dma_word_valid;
	assign dma_active = dma_run;
	assign dma_addr   = dma_idx;
	assign dma_wdata  = dma_word;
	assign dma_we     = dma_run & dma_req & dma_word_valid;
	always @(posedge clk_sys) begin
		if (reset) begin
			dma_run <= 1'b0; dma_req <= 1'b0; dma_gap <= 1'b0; dma_idx <= 13'd0; dma_bank <= 3'd0;
			dma_bank_loaded <= 4'hF;
		end else if (!dma_run) begin
			if (g_bioship && (dma_bank_loaded != {1'b0, bg0bank_reg[2:0]})) begin
				dma_run  <= 1'b1;
				dma_idx  <= 13'd0;
				dma_bank <= bg0bank_reg[2:0];
				dma_req  <= 1'b1;
				dma_gap  <= 1'b0;
			end
		end else if (dma_gap) begin
			dma_gap <= 1'b0;
			dma_req <= 1'b1;
		end else if (dma_req & dma_word_valid) begin
			dma_req <= 1'b0;
			if (dma_idx == 13'd8191) begin
				dma_run <= 1'b0;
				dma_bank_loaded <= {1'b0, dma_bank};
			end else begin
				dma_idx <= dma_idx + 13'd1;
				dma_gap <= 1'b1;
			end
		end
	end

	// ------------------------------------------------------------------
	// NMK004 host latches (nmk004_device::read/write)
	// ------------------------------------------------------------------
	wire [7:0] nmk004_mcu_to_host;
	wire       nmk004_mcu_to_host_we;
	reg  [7:0] nmk004_host_to_mcu = 8'hFF;
	wire       host_cmd_we = (prot_reg_w & prot_sel_nmk004_w) | (cpu_write & sel_nmk004_w & ~LDSn);
	wire [7:0] host_cmd    = (prot_reg_w & prot_sel_nmk004_w) ? prot_wdata : oEdb[7:0];
	always @(posedge clk_sys) if (host_cmd_we) nmk004_host_to_mcu <= host_cmd;
	assign dbg_host_cmd_we = host_cmd_we;
	assign dbg_host_cmd    = host_cmd;

	reg [7:0] nmk004_to_host_latch = 8'hFF;
	always @(posedge clk_sys) begin
		if (g_z80snd) begin
			if (~z80_reset_n) nmk004_to_host_latch <= 8'h00;
			else if (z80_mem_we & sel_z80_latch) nmk004_to_host_latch <= z80_do; // tharrier: soundlatch2 (Z80 -> 68000)
		end else if (nmk004_mcu_to_host_we & snd_cen) nmk004_to_host_latch <= nmk004_mcu_to_host;
	end
	assign dbg_mcu_reply_we = nmk004_mcu_to_host_we & snd_cen;
	assign dbg_mcu_reply    = nmk004_mcu_to_host;

	// ------------------------------------------------------------------
	// NMK004 sound MCU — nmk004_core.sv on clk_sys + snd_cen. Program
	// ROM: $readmemh at HW_ROMS=0; at HW_ROMS=1 one oki_rom_cache over
	// SDRAM port 3 serving both the boot ROM and the external program
	// (see the layout in the header), with the cen withheld on a miss.
	// ------------------------------------------------------------------
	wire       ym_cs, ym_we, ym_addr_sel;
	wire [7:0] ym_dout;
	wire       oki0_cs, oki0_we, oki1_cs, oki1_we;
	wire [7:0] oki0_dout, oki1_dout;
	wire       oki0_bank_we, oki1_bank_we;
	wire [7:0] oki0_bank, oki1_bank;

	wire [15:0] nmk004_rom_addr;
	wire        nmk004_rom_rd;
	wire [7:0]  nmk004_rom_din;
	wire        nmk004_rom_ready;
	// boot ROM 0x0000-0x1FFF lives at BASE_BYTE_NMK004_BOOT = ext base +
	// 0x10000, so relative to BASE_WORD_NMK004: boot at byte 0x10000+a,
	// program at byte a.
	wire [21:0] nmk004_cache_addr = (nmk004_rom_addr < 16'h2000) ? {5'd0, 1'b1, nmk004_rom_addr} : {6'd0, nmk004_rom_addr};

	wire [7:0] ym_chip_dout;
	wire       ym_chip_irq_n;
	wire [7:0] oki1_chip_dout, oki2_chip_dout;

	nmk004_core #(
		.BOOT_ROM_FILE(NMK004_BOOT_FILE),
		.EXT_ROM_FILE(NMK004_EXT_FILE),
		.USE_CEN(1),
		.ROM_EXTERNAL(HW_ROMS)
	) nmk004 (
		.clk(clk_sys), .cen(snd_cen), .reset(reset | ~has_nmk004),
		.rom_addr(nmk004_rom_addr), .rom_rd(nmk004_rom_rd), .rom_din(nmk004_rom_din), .rom_ready(nmk004_rom_ready), .rom_stall(nmk004_rom_stall),
		.nmi(nmi_level),
		.ym_cs(ym_cs), .ym_we(ym_we), .ym_addr_sel(ym_addr_sel),
		.ym_dout(ym_dout), .ym_din(ym_chip_dout), .ym_irq_n(ym_chip_irq_n),
		.oki0_cs(oki0_cs), .oki0_we(oki0_we), .oki0_dout(oki0_dout), .oki0_din(oki1_chip_dout),
		.oki1_cs(oki1_cs), .oki1_we(oki1_we), .oki1_dout(oki1_dout), .oki1_din(oki2_chip_dout),
		.oki0_bank_we(oki0_bank_we), .oki0_bank(oki0_bank),
		.oki1_bank_we(oki1_bank_we), .oki1_bank(oki1_bank),
		.host_to_mcu(nmk004_host_to_mcu),
		.mcu_to_host(nmk004_mcu_to_host), .mcu_to_host_we(nmk004_mcu_to_host_we),
		.dbg_pc(dbg_nmk004_pc), .dbg_valid(dbg_nmk004_valid),
		.dbg_a(dbg_nmk004_a), .dbg_f(dbg_nmk004_f), .dbg_hl(dbg_nmk004_hl),
		.dbg_ram_hl(dbg_nmk004_ram_hl),
		.dbg_de(dbg_nmk004_de), .dbg_bc(dbg_nmk004_bc), .dbg_ix(dbg_nmk004_ix),
		.dbg_iy(dbg_nmk004_iy), .dbg_sp(dbg_nmk004_sp),
		.p4(nmk004_p4), .bx(), .by()
	);
	assign dbg_nmk004_cen   = snd_cen;
	assign dbg_nmk004_stall = snd_stall;

	// SDRAM port 3, eight channels: TX prefetch, NMK004 ROM, OKI0, OKI1,
	// protection ROM reads, bioship tilemap DMA, protection firmware load,
	// tharrier's Z80 program ROM.
	wire        p1_busy [0:7];
	wire        p1_valid[0:7];
	wire [24:1] p1_addr [0:7];
	wire        p1_req  [0:7];
	wire [15:0] p1_dout [0:7];
	wire [31:0] p1_dout_pair [0:7];
	wire [7:0]  prot_rom_din;
	wire        prot_rom_ready;
	generate
	if (!HW_ROMS) begin : g_p1_sim
		assign nmk004_rom_din   = 8'h00;
		assign nmk004_rom_ready = 1'b1;
		assign prot_rom_din     = 8'h00;
		assign prot_rom_ready   = 1'b1;
		assign sd3_addr = 24'd0; assign sd3_req = 1'b0;
		assign p1_busy  = '{1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_valid = '{1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0};
		assign p1_dout  = '{16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0};
		assign p1_dout_pair = '{32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0};
		// channel 0 (TX prefetch) is driven by the video module's txc_* outputs
		assign p1_addr[1] = 24'd0; assign p1_addr[2] = 24'd0; assign p1_addr[3] = 24'd0; assign p1_addr[4] = 24'd0; assign p1_addr[5] = 24'd0; assign p1_addr[6] = 24'd0;
		assign p1_req[1] = 1'b0; assign p1_req[2] = 1'b0; assign p1_req[3] = 1'b0; assign p1_req[4] = 1'b0; assign p1_req[5] = 1'b0; assign p1_req[6] = 1'b0;
		assign pl_word = 16'd0; assign pl_word_valid = 1'b0;
		// tilemap DMA source: the sim array, served the same clock
		reg [15:0] tilerom [0:65535];
		initial if (TILEROM_FILE != "") $readmemh(TILEROM_FILE, tilerom);
		assign dma_word       = tilerom[{dma_bank, dma_idx}];
		assign dma_word_valid = 1'b1;
	end else begin : g_p1_hw
		// Physical port 3: channel 0 is the video module's TX prefetch
		// stream (top priority, it is real-time), the sound consumers
		// follow, the tilemap DMA last. The sprite fetch has physical
		// port 1 (video sd_b_*) — see video_macross2.sv TX_EXTERNAL.
		sdram_arb #(.N(8), .FIXED_PRIO(1)) p1_arb_inst (
			.clk(clk_sys), .reset(por_rst),
			.i_addr(p1_addr), .i_we('{1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0}), .i_wrl('{1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0}), .i_wrh('{1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0}), .i_din('{16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0}),
			.i_req(p1_req), .i_busy(p1_busy), .i_valid(p1_valid), .i_dout(p1_dout), .i_dout_pair(p1_dout_pair),
			.sdram_addr(sd3_addr), .sdram_wrl(), .sdram_wrh(), .sdram_din(),
			.sdram_dout(sd3_dout), .sdram_dout_pair(sd3_dout_pair), .sdram_req(sd3_req), .sdram_ack(sd3_ack)
		);
		oki_rom_cache nmk004_cache_inst (
			.base_word(BASE_WORD_NMK004),
			.clk(clk_sys), .reset(reset),
			.byte_addr(nmk004_cache_addr), .data(nmk004_rom_din), .ready(nmk004_rom_ready), .stall(),
			.sd_addr(p1_addr[1]), .sd_req(p1_req[1]), .sd_busy(p1_busy[1]), .sd_valid(p1_valid[1]), .sd_dout(p1_dout[1]), .sd_dout_pair(p1_dout_pair[1])
		);
		// Protection MCU reads of the 68000 ROM (none in the NMK-215
		// firmware, real for the NMK-110/113): its own 1-line byte cache.
		// Address bit 0 inverted: the SDRAM word is {odd stream byte, even
		// stream byte} and the .mra puts the 68000's LOW-byte chip on even
		// stream addresses, so the 68000's byte at an even address is the
		// word's HIGH byte — the same ^1 the sprite cache applies. Without
		// it the NMK-110/113 read every ROM byte pair swapped and tdragon1/
		// hachamf sat black on the board while the reference sim (a plain
		// word array) played (2026-09-11).
		rom_cache1_byte prot_rom_cache_inst (
			.base_word(23'd0),
			.clk(clk_sys), .reset(reset),
			.byte_addr({5'd0, prot_addr[18:0] ^ 19'd1}), .data(prot_rom_din), .word(), .ready(prot_rom_ready),
			.sd_addr(p1_addr[4]), .sd_req(p1_req[4]), .sd_busy(p1_busy[4]), .sd_valid(p1_valid[4]), .sd_dout(p1_dout[4]), .sd_dout_pair(p1_dout_pair[4])
		);
		// Tilemap DMA: one word per transaction (see the engine above).
		assign p1_addr[5]     = {1'b0, BASE_WORD_TILEROM} + {8'd0, dma_bank, dma_idx};
		assign p1_req[5]      = dma_req;
		// Protection firmware load: one word per transaction (see the loader below).
		assign p1_addr[6]     = {1'b0, BASE_BYTE_PROT[23:1]} + {11'd0, pl_idx};
		assign p1_req[6]      = pl_req;
		assign pl_word        = p1_dout[6];
		assign pl_word_valid  = p1_valid[6];
		assign dma_word       = p1_dout[5];
		assign dma_word_valid = p1_valid[5];
	end
	endgenerate

	// ------------------------------------------------------------------
	// YM2203 — jt03, 40-cycle write stretch from the NMK004's write strobe.
	// ------------------------------------------------------------------
	reg [7:0] ym_din_latch;
	reg       ym_addr_latch;
	reg [5:0] ym_wr_hold = 6'd0;
	reg       ym_we_prev = 1'b0;
	// Write source: the NMK004, or tharrier's Z80 (I/O ports 0/1).
	wire       ym_we_src   = g_z80snd ? (z80_io_we & sel_io_ym) : ym_we;
	wire [7:0] ym_dout_src = g_z80snd ? z80_do : ym_dout;
	wire       ym_addr_src = g_z80snd ? z80_a[0] : ym_addr_sel;
	always @(posedge clk_sys) begin
		ym_we_prev <= ym_we_src;
		if (ym_we_src && !ym_we_prev) begin
			ym_din_latch  <= ym_dout_src;
			ym_addr_latch <= ym_addr_src;
			ym_wr_hold    <= 6'd40;
		end else if (ym_wr_hold != 6'd0) begin
			ym_wr_hold <= ym_wr_hold - 6'd1;
		end
	end
	wire ym_wr_n = ~(ym_wr_hold != 6'd0);
	// Live port decode for reads (status polls), the latch only while a
	// write stretch is in flight — see tdragon2_core.sv.
	wire ym_addr_eff = (ym_wr_hold != 6'd0) ? ym_addr_latch : ym_addr_src;

	wire signed [15:0] ym_snd;
	jt03 ym_chip (
		.rst(reset), .clk(clk_sys), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_eff), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_chip_dout), .irq_n(ym_chip_irq_n),
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(dbg_fm_snd), .psg_snd(dbg_psg_snd), .snd(ym_snd), .snd_sample(),
		.debug_view()
	);

	// ------------------------------------------------------------------
	// OKIM6295 x2 — jt6295, NMK004-driven banking: 0x00000-0x1FFFF fixed,
	// 0x20000-0x3FFFF = bank (n+1) x 0x20000 of the ROM (oki1_map/oki2_map
	// + nmk004_device's okibank entries). 20-bit physical address: strahl's
	// regions are 0xA0000 bytes (bank 3 = 0x80000-0x9FFFF).
	// ------------------------------------------------------------------
	reg [1:0] oki1_bank_r = 2'd0, oki2_bank_r = 2'd0;
	always @(posedge clk_sys) begin
		if (g_tharrier) begin
			// tharrier_okibank_w (Z80 0xF600/0xF700): entries 0-3 of the
			// 0x20000 pages from +0x20000; a write of 3 is ignored
			if (z80_mem_we & sel_z80_okibank0 & (z80_do[1:0] != 2'd3)) oki1_bank_r <= z80_do[1:0];
			if (z80_mem_we & sel_z80_okibank1 & (z80_do[1:0] != 2'd3)) oki2_bank_r <= z80_do[1:0];
		end else begin
			if (oki0_bank_we & snd_cen) oki1_bank_r <= oki0_bank[1:0];
			if (oki1_bank_we & snd_cen) oki2_bank_r <= oki1_bank[1:0];
		end
	end

	function automatic [19:0] oki_phys_addr(input [17:0] rom_addr, input [1:0] bank);
		reg [2:0] bank_p1;
		begin
			bank_p1 = {1'b0, bank} + 3'd1;
			oki_phys_addr = rom_addr[17] ? ({bank_p1, 17'd0} + {3'd0, rom_addr[16:0]}) : {3'd0, rom_addr[16:0]};
		end
	endfunction

	wire [17:0] oki1_rom_addr, oki2_rom_addr;
	// Bombjack Twin family: the NMK112 remaps both chips' addresses (four
	// 0x10000 pages each, sample-table page fix-up) — 1 MB ROMs.
	wire [21:0] oki1_n112, oki2_n112;
	wire        nmk112_hold;
	nmk112 #(.ROM0_BYTES(1048576), .ROM1_BYTES(1048576)) nmk112_inst (
		.clk_sys(clk_sys), .reset(reset),
		.reg_sel(byte_addr[3:1]), .reg_data(oEdb[7:0]), .reg_we(g_bjtwin & sel_nmk112 & cpu_write & ~LDSn), .hold(nmk112_hold),
		.rom0_addr_in(oki1_rom_addr), .rom0_addr_out(oki1_n112),
		.rom1_addr_in(oki2_rom_addr), .rom1_addr_out(oki2_n112)
	);
	wire [19:0] oki1_phys = g_bjtwin ? oki1_n112[19:0] : oki_phys_addr(oki1_rom_addr, oki1_bank_r);
	wire [19:0] oki2_phys = g_bjtwin ? oki2_n112[19:0] : oki_phys_addr(oki2_rom_addr, oki2_bank_r);

	wire [7:0] oki1_rom_data, oki2_rom_data;
	wire       oki1_rom_ok, oki2_rom_ok;
	wire       oki1_stall, oki2_stall;
	generate
	if (!HW_ROMS) begin : g_oki_sim
		reg [7:0] oki1_rom [0:1048575];
		reg [7:0] oki2_rom [0:1048575];
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, oki1_rom);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, oki2_rom);
		reg [7:0] oki1_rom_data_r, oki2_rom_data_r;
		always @(posedge clk_sys) oki1_rom_data_r <= oki1_rom[oki1_phys];
		always @(posedge clk_sys) oki2_rom_data_r <= oki2_rom[oki2_phys];
		assign oki1_rom_data = oki1_rom_data_r;
		assign oki2_rom_data = oki2_rom_data_r;
		assign oki1_rom_ok = 1'b1;
		assign oki2_rom_ok = 1'b1;
		assign oki1_stall = 1'b0;
		assign oki2_stall = 1'b0;
		assign dbg_oki0_adpcm_total = 32'd0; assign dbg_oki0_adpcm_unserved = 32'd0;
		assign dbg_oki1_adpcm_total = 32'd0; assign dbg_oki1_adpcm_unserved = 32'd0;
		assign dbg_oki_cen_total = 32'd0; assign dbg_oki0_stall_cen = 32'd0; assign dbg_oki1_stall_cen = 32'd0;
	end else begin : g_oki_hw
		oki_rom_cache oki1_cache_inst (
			.base_word(BASE_WORD_OKI1),
			.clk(clk_sys), .reset(reset),
			.byte_addr({2'd0, oki1_phys}), .data(oki1_rom_data), .ready(oki1_rom_ok), .stall(oki1_stall),
			.sd_addr(p1_addr[2]), .sd_req(p1_req[2]), .sd_busy(p1_busy[2]), .sd_valid(p1_valid[2]), .sd_dout(p1_dout[2]), .sd_dout_pair(p1_dout_pair[2])
		);
		oki_rom_cache oki2_cache_inst (
			.base_word(BASE_WORD_OKI2),
			.clk(clk_sys), .reset(reset),
			.byte_addr({2'd0, oki2_phys}), .data(oki2_rom_data), .ready(oki2_rom_ok), .stall(oki2_stall),
			.sd_addr(p1_addr[3]), .sd_req(p1_req[3]), .sd_busy(p1_busy[3]), .sd_valid(p1_valid[3]), .sd_dout(p1_dout[3]), .sd_dout_pair(p1_dout_pair[3])
		);
`ifdef VERILATOR
		reg [31:0] oki0_adpcm_total_r = 32'd0, oki0_adpcm_unserved_r = 32'd0;
		reg [31:0] oki1_adpcm_total_r = 32'd0, oki1_adpcm_unserved_r = 32'd0;
		reg [31:0] oki_cen_total_r = 32'd0, oki0_stall_cen_r = 32'd0, oki1_stall_cen_r = 32'd0;
		reg [7:0] golden0 [0:1048575];
		reg [7:0] golden1 [0:1048575];
		initial if (OKI1_ROM_FILE != "") $readmemh(OKI1_ROM_FILE, golden0);
		initial if (OKI2_ROM_FILE != "") $readmemh(OKI2_ROM_FILE, golden1);
		reg [31:0] oki0_bytes_wrong = 32'd0, oki1_bytes_wrong = 32'd0, oki0_bytes_checked = 32'd0, oki1_bytes_checked = 32'd0;
		always @(posedge clk_sys) begin
			if (oki_cen) begin
				oki_cen_total_r <= oki_cen_total_r + 32'd1;
				if (oki1_stall) oki0_stall_cen_r <= oki0_stall_cen_r + 32'd1;
				if (oki2_stall) oki1_stall_cen_r <= oki1_stall_cen_r + 32'd1;
			end
			if (oki1_chip.u_rom.st == 8'h02 && oki1_chip.u_rom.cen32) begin
				oki0_adpcm_total_r <= oki0_adpcm_total_r + 32'd1;
				if (!oki1_rom_ok) oki0_adpcm_unserved_r <= oki0_adpcm_unserved_r + 32'd1;
				if (OKI1_ROM_FILE != "") begin
					oki0_bytes_checked <= oki0_bytes_checked + 32'd1;
					if (oki1_rom_data != golden0[oki1_phys]) begin
						oki0_bytes_wrong <= oki0_bytes_wrong + 32'd1;
						if (oki0_bytes_wrong < 32'd8) $display("[%0t] OKI0 wrong byte: phys=%05x raw=%05x got=%02x golden=%02x ok=%0d", $time, oki1_phys, oki1_rom_addr, oki1_rom_data, golden0[oki1_phys], oki1_rom_ok);
					end
				end
			end
			if (oki2_chip.u_rom.st == 8'h02 && oki2_chip.u_rom.cen32) begin
				oki1_adpcm_total_r <= oki1_adpcm_total_r + 32'd1;
				if (!oki2_rom_ok) oki1_adpcm_unserved_r <= oki1_adpcm_unserved_r + 32'd1;
				if (OKI2_ROM_FILE != "") begin
					oki1_bytes_checked <= oki1_bytes_checked + 32'd1;
					if (oki2_rom_data != golden1[oki2_phys]) oki1_bytes_wrong <= oki1_bytes_wrong + 32'd1;
				end
			end
		end
		final $display("OKI golden-byte audit: oki0 %0d latches / %0d wrong, oki1 %0d latches / %0d wrong",
			oki0_bytes_checked, oki0_bytes_wrong, oki1_bytes_checked, oki1_bytes_wrong);
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
	assign nmk112_hold = oki_cen & (~oki1_stall | ~oki2_stall);

`ifdef VERILATOR
	reg [31:0] snd_cen_total_r = 32'd0, snd_stall_total_r = 32'd0;
	always @(posedge clk_sys) if (snd_div == 3'd4) begin
		if (snd_stall) snd_stall_total_r <= snd_stall_total_r + 32'd1;
		else           snd_cen_total_r   <= snd_cen_total_r + 32'd1;
	end
	assign dbg_nmk004_cen_total   = snd_cen_total_r;
	assign dbg_nmk004_stall_total = snd_stall_total_r;
`else
	assign dbg_nmk004_cen_total   = 32'd0;
	assign dbg_nmk004_stall_total = 32'd0;
`endif

	reg [7:0] oki0_din_latch, oki1_din_latch;
	reg [5:0] oki0_wr_hold = 6'd0, oki1_wr_hold = 6'd0;
	reg       oki0_we_prev = 1'b0, oki1_we_prev = 1'b0;
	wire       oki0_we_src = g_bjtwin ? (sel_oki0 & cpu_write & ~LDSn) : g_z80snd ? (z80_mem_we & sel_z80_oki0) : oki0_we;
	wire       oki1_we_src = g_bjtwin ? (sel_oki1 & cpu_write & ~LDSn) : g_z80snd ? (z80_mem_we & sel_z80_oki1) : oki1_we;
	wire [7:0] oki_d_src   = g_bjtwin ? oEdb[7:0] : z80_do;
	wire [7:0] oki0_dout_src = (g_bjtwin | g_z80snd) ? oki_d_src : oki0_dout;
	wire [7:0] oki1_dout_src = (g_bjtwin | g_z80snd) ? oki_d_src : oki1_dout;
	always @(posedge clk_sys) begin
		oki0_we_prev <= oki0_we_src;
		if (oki0_we_src && !oki0_we_prev) begin
			oki0_din_latch <= oki0_dout_src;
			oki0_wr_hold   <= 6'd40;
		end else if (oki0_wr_hold != 6'd0) begin
			oki0_wr_hold <= oki0_wr_hold - 6'd1;
		end
	end
	always @(posedge clk_sys) begin
		oki1_we_prev <= oki1_we_src;
		if (oki1_we_src && !oki1_we_prev) begin
			oki1_din_latch <= oki1_dout_src;
			oki1_wr_hold   <= 6'd40;
		end else if (oki1_wr_hold != 6'd0) begin
			oki1_wr_hold <= oki1_wr_hold - 6'd1;
		end
	end
	wire oki0_wr_n = ~(oki0_wr_hold != 6'd0);
	wire oki1_wr_n = ~(oki1_wr_hold != 6'd0);

	wire signed [13:0] oki1_snd, oki2_snd;
	jt6295 oki1_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki1_stall), .ss(1'b0),
		.wrn(oki0_wr_n), .din(oki0_din_latch), .dout(oki1_chip_dout),
		.rom_addr(oki1_rom_addr), .rom_data(oki1_rom_data), .rom_ok(oki1_rom_ok),
		.sound(oki1_snd), .sample()
	);
	jt6295 oki2_chip (
		.rst(reset), .clk(clk_sys), .cen(oki_cen & ~oki2_stall), .ss(1'b0),
		.wrn(oki1_wr_n), .din(oki1_din_latch), .dout(oki2_chip_dout),
		.rom_addr(oki2_rom_addr), .rom_data(oki2_rom_data), .rom_ok(oki2_rom_ok),
		.sound(oki2_snd), .sample()
	);

	// Audio mix — same routes on every board (FM 1.20, PSG 0.50 x3,
	// each OKI 0.10): jt03's mixed snd + each OKI x 3/2, saturated.
	wire signed [17:0] oki0_ext = {{4{oki1_snd[13]}}, oki1_snd};
	wire signed [17:0] oki1_ext = {{4{oki2_snd[13]}}, oki2_snd};
	wire signed [17:0] oki0_g   = oki0_ext + (oki0_ext >>> 1); // x 3/2 (was 3/8 -- measured 8-13dB quiet vs MAME's real OKI:FM balance)
	wire signed [17:0] oki1_g   = oki1_ext + (oki1_ext >>> 1);
	wire signed [17:0] audio_sum = {{2{ym_snd[15]}}, ym_snd} + oki0_g + oki1_g;
	wire signed [15:0] audio_mix =
		(audio_sum > 18'sd32767)  ? 16'sd32767  :
		(audio_sum < -18'sd32768) ? -16'sd32768 :
		audio_sum[15:0];
	assign audio_l = audio_mix;
	assign audio_r = audio_mix;
	assign dbg_oki0_snd = oki1_snd;
	assign dbg_oki1_snd = oki2_snd;

	// ------------------------------------------------------------------
	// Protection MCU (NMK-215/TMP90840, NMK-110/113/TMP91640) —
	// nmk_prot_core.sv on clk_sys + prot_cen. Boot ROM: $readmemh at
	// HW_ROMS=0; at HW_ROMS=1 written into its on-chip array from the
	// ioctl stream (the 8 or 16 KB at BASE_BYTE_PROT) while the core is
	// in reset. Held in reset on the boards without one.
	// ------------------------------------------------------------------
	wire nmk214_cfg_we;
	wire [7:0] nmk214_cfg_data;
	assign dbg_nmk214_cfg_we   = nmk214_cfg_we;
	assign dbg_nmk214_cfg_data = nmk214_cfg_data;

	// Protection firmware load (2026-09-11). The firmware used to be copied
	// into the MCU's on-chip array straight from the ioctl stream, keyed on
	// game_sel's BASE_BYTE_PROT — but on the board game_sel is not known
	// yet while the ROM streams in (the .mra <switches> block, ioctl index
	// 254, arrives separately), so tdragon1/hachamf got their firmware
	// copied from gunnail's offset (a slice of their BG tiles) and sat
	// black and silent while the hardware sim, whose game id is a build
	// parameter, played. The firmware is now read back from SDRAM after
	// reset — 8/16 KB over the port-3 arbiter, ~2.5 ms at most — with the
	// 68000 and the MCU held in reset until it is in; the NMK004 boots
	// meanwhile and just waits for its first command, as it does in MAME
	// when the 68000 is slower to start.
	reg        pl_run = 1'b0, pl_done = 1'b0, pl_req = 1'b0, pl_gap = 1'b0;
	reg [12:0] pl_idx;
	reg        pl_lo_written;
	wire [15:0] pl_word;
	wire        pl_word_valid;
	wire        prot_loading = HW_ROMS && has_prot && !pl_done;
	wire        pl_last = (pl_idx == PROT_ROM_BYTES_M1[13:1]);
	always @(posedge clk_sys) begin
		if (reset) begin
			pl_run <= 1'b0; pl_done <= 1'b0; pl_req <= 1'b0; pl_gap <= 1'b0; pl_idx <= 13'd0; pl_lo_written <= 1'b0;
		end else if (!pl_done && !pl_run) begin
			pl_run <= 1'b1; pl_idx <= 13'd0; pl_req <= 1'b1; pl_gap <= 1'b0; pl_lo_written <= 1'b0;
		end else if (pl_run) begin
			if (pl_gap) begin
				pl_gap <= 1'b0; pl_req <= 1'b1;
			end else if (pl_req & pl_word_valid) begin
				// two byte writes per word: the low stream byte (even
				// offset) now, the high one (odd) on the next clock — the
				// arbiter's registered i_dout holds the word meanwhile
				pl_req <= 1'b0; pl_lo_written <= 1'b1;
			end else if (pl_lo_written) begin
				pl_lo_written <= 1'b0;
				if (pl_last) begin pl_run <= 1'b0; pl_done <= 1'b1; end
				else begin pl_idx <= pl_idx + 13'd1; pl_gap <= 1'b1; end
			end
		end
	end
	wire        prot_rom_we    = HW_ROMS && pl_run && ((pl_req & pl_word_valid) | pl_lo_written);
	wire [13:0] prot_rom_waddr = {pl_idx, pl_lo_written};
	wire [7:0]  prot_rom_wdata = pl_lo_written ? pl_word[15:8] : pl_word[7:0];

	wire [9:0] vt_hcount, vt_vcount;
	wire prot_halt_raw;
	nmk_prot_core #(
		.BOOT_ROM_FILE(PROT_BOOT_FILE),
		.ROM_SIZE(16384), .RAM_BASE(16'hfdc0), .RAM_SIZE(512),
		.USE_CEN(1)
	) prot_mcu (
		.clk(clk_sys), .cen(prot_cen), .reset(reset | ~has_prot | prot_loading),
		.p7_ext_en_i(g_hachamf), .p7_ext_val_i(8'h0C), // NMK-113 selects its Hacha Mecha Fighter codepath by this port-7 constant
		.rom_we(prot_rom_we), .rom_waddr(prot_rom_waddr), .rom_wdata(prot_rom_wdata),
		.bus_addr(prot_addr), .bus_rd(prot_rd), .bus_wr(prot_wr),
		.bus_wdata(prot_wdata), .bus_rdata(prot_rdata),
		.vpos_div4(vt_vcount[9:2]),
		.halt_68k(prot_halt_raw),
		.nmk214_cfg_we(nmk214_cfg_we), .nmk214_cfg_data(nmk214_cfg_data),
		.dbg_pc(dbg_prot_pc), .dbg_valid(dbg_prot_valid),
		.dbg_hl(dbg_prot_hl), .dbg_a(dbg_prot_a), .dbg_de(dbg_prot_de), .dbg_iy(dbg_prot_iy),
		.dbg_int_ram_at_hl(dbg_prot_int_ram_at_hl)
	);
	assign halt_68k = prot_halt_raw & has_prot;

	// Shared-bus read mux (byte) and the ready/stall logic.
	reg [15:0] prot_rdata16;
	always @(*) begin
		if (prot_sel_rom)          prot_rdata16 = prot_rom_word;
		else if (prot_sel_mainram) prot_rdata16 = prot_mainram_dout;
		else if (prot_sel_palette) prot_rdata16 = prot_palette_dout;
		else if (prot_sel_bgvram)  prot_rdata16 = prot_bgvram_dout;
		else if (prot_sel_txvram)  prot_rdata16 = prot_txvram_dout;
		else if (prot_sel_nmk004_r) prot_rdata16 = {8'h00, nmk004_to_host_latch};
		else if (prot_sel_in0)     prot_rdata16 = HW_ROMS ? in0_i  : 16'hFFFF;
		else if (prot_sel_in1)     prot_rdata16 = HW_ROMS ? in1_i  : 16'hFFFF;
		else if (prot_sel_dsw1)    prot_rdata16 = (HW_ROMS || (SIM_DSW != 0)) ? dsw1_i : 16'hFFFF;
		else if (prot_sel_dsw2)    prot_rdata16 = (HW_ROMS || (SIM_DSW != 0)) ? dsw2_i : 16'hFFFF;
		else                       prot_rdata16 = 16'hFFFF;
	end
	assign prot_rdata = prot_addr[0] ? prot_rdata16[7:0] : prot_rdata16[15:8];

	wire prot_rd_ready =
		prot_sel_rom     ? prot_rom_ready :
		prot_sel_mainram ? prot_mainram_ready :
		prot_sel_palette ? prot_palette_ready :
		prot_sel_bgvram  ? prot_bgvram_ready :
		prot_sel_txvram  ? prot_txvram_ready : 1'b1;
	// A write is "done" once the granted RAM-port write (or a register
	// write, always granted) has happened in this CPU cycle.
	wire prot_wr_granted_now =
		prot_sel_mainram ? mainram_prot_grant :
		prot_sel_palette ? palette_prot_grant :
		prot_sel_bgvram  ? bgvram_prot_grant :
		prot_sel_txvram  ? txvram_prot_grant : 1'b1;
	always @(posedge clk_sys) begin
		if (reset | prot_cen) prot_wr_done <= 1'b0;
		else if (prot_wr & prot_wr_granted_now) prot_wr_done <= 1'b1;
	end
	assign prot_stall = HW_ROMS ? ((prot_rd & ~prot_rd_ready) | (prot_wr & ~prot_wr_done & ~prot_wr_granted_now)) : 1'b0;

	// ------------------------------------------------------------------
	// Task Force Harrier (2026-09-12): inputs and the MCU simulation.
	// tharrier_map reads IN0 active HIGH, IN1 through the (undumped) MCU
	// — word reads return ~IN1 (start/coin bits, active high on the
	// bus), byte reads of the upper byte return a 15-entry sequence
	// (tharrier_mcu_r), except at two program counters (the move.b
	// $080002,d1 at 0x8A4 and 0x8C8 — MAME keys on the PC after the
	// instruction, 0x8AA/0x8CE) where they return main RAM word 0x9064
	// ORed with 0x20/0x60 and leave the sequence alone — and IN2 at
	// 0x080202 (active high joysticks/buttons). The core's inputs use
	// the family's standard active-low layout; the three ports are
	// rebuilt from them here.
	// ------------------------------------------------------------------
	wire [15:0] in0_eff = HW_ROMS ? in0_i : 16'hFFFF;
	wire [15:0] in1_eff = HW_ROMS ? in1_i : 16'hFFFF;
	wire [15:0] th_in0 = {1'b1, 10'd0, ~in0_eff[4:0]};                            // bit 15 "MCU status" (IPT_CUSTOM, active low: idle 1 — the boot loop at 0x88E waits for it), coin1, coin2, service, start1, start2
	wire [15:0] th_in1 = {7'd0, ~in0_eff[4], 1'b0, ~in0_eff[0], 1'b0, ~in0_eff[1], 3'd0, ~in0_eff[4], ~in0_eff[3]};
	wire [15:0] th_in2 = {1'b0, ~in1_eff[11], ~in1_eff[10], ~in1_eff[9], ~in1_eff[8], ~in1_eff[13], ~in1_eff[12], 1'b0,
	                      ~in1_eff[6], ~in1_eff[3], ~in1_eff[2], ~in1_eff[1], ~in1_eff[0], ~in1_eff[5], ~in1_eff[4], 1'b0};
	reg  [23:0] last_fetch_pc;
	always @(posedge clk_sys) if (cpu_read & FC1 & ~FC0) last_fetch_pc <= byte_addr;   // the most recent instruction-fetch address
	// mustangb3_map's 0x080006 ("gross hack. Protection?"): MAME keys on
	// m_maincpu->pc() == 0x416 / 0x64E — the address AFTER the reading
	// instruction (move.w $80006,D0 at 0x410 / 0x648, six bytes each; the
	// boot loops there until the word equals ROM $640 = 0x9000, then ROM
	// $3E7C = 0x548D); a third loop at 0x666 wants 0, which is the default.
	// The windows include the following opcode word (0x416 / 0x64E): the
	// 68000 prefetches it before the data read, so last_fetch_pc is that
	// address at read time (the tharrier windows have the same shape; a
	// window ending at 0x416 left the boot spinning at 0x410-0x41C).
	wire sel_mb3_prot = g_mustangb3 & (byte_addr[23:1] == 23'h040003);
	wire [15:0] mb3_prot_val = ((last_fetch_pc >= 24'h000410) && (last_fetch_pc < 24'h000418)) ? 16'h9000 :
	                           ((last_fetch_pc >= 24'h000648) && (last_fetch_pc < 24'h000650)) ? 16'h548D : 16'h0000;
	wire th_pc_8aa = (last_fetch_pc >= 24'h0008A4) && (last_fetch_pc < 24'h0008AC);
	wire th_pc_8ce = (last_fetch_pc >= 24'h0008C8) && (last_fetch_pc < 24'h0008D0);
	reg  [3:0]  th_prot_count;
	function automatic [7:0] th_to_main(input [3:0] i);
		case (i)
			4'd0: th_to_main = 8'h82; 4'd1: th_to_main = 8'hc7; 4'd2: th_to_main = 8'h00; 4'd3: th_to_main = 8'h2c;
			4'd4: th_to_main = 8'h6c; 4'd5: th_to_main = 8'h00; 4'd6: th_to_main = 8'h9f; 4'd7: th_to_main = 8'hc7;
			4'd8: th_to_main = 8'h00; 4'd9: th_to_main = 8'h29; 4'd10: th_to_main = 8'h69; 4'd11: th_to_main = 8'h00;
			4'd12: th_to_main = 8'h8b; 4'd13: th_to_main = 8'hc7; default: th_to_main = 8'h00;
		endcase
	endfunction
	wire [7:0] th_mcu_val = th_pc_8aa ? (mainram_dout[7:0] | 8'h20) :
	                        th_pc_8ce ? (mainram_dout[7:0] | 8'h60) : th_to_main(th_prot_count);
	wire th_mcu_rd = g_tharrier & sel_in1 & cpu_read & ~UDSn & LDSn;
	reg  th_mcu_rd_d;
	always @(posedge clk_sys) begin
		th_mcu_rd_d <= th_mcu_rd;
		if (reset) th_prot_count <= 4'd0;
		else if (th_mcu_rd_d & ~th_mcu_rd & ~th_pc_8aa & ~th_pc_8ce) th_prot_count <= (th_prot_count == 4'd14) ? 4'd0 : th_prot_count + 4'd1;
	end

	// ------------------------------------------------------------------
	// Task Force Harrier's Z80 sound board: T80 at 4.9152 MHz, program
	// ROM 0x0000-0xBFFF (the NMK004-program slot of the SDRAM image,
	// through its own byte cache), RAM 0xC000-0xC7FF, 0xF000 soundlatch
	// (read) / soundlatch2 (write), OKIs at 0xF400/0xF500, their bank
	// registers at 0xF600/0xF700, the YM2203 on I/O ports 0/1 (its IRQ
	// is the Z80's INT). Held in reset on every other board.
	// ------------------------------------------------------------------
	reg [16:0] z80_acc = 17'd0;
	reg        z80_cen = 1'b0;
	wire [16:0] z80_inc = g_mustangb3 ? 17'd8949 : 17'd12288; // mustangb3: 14.31818/4 = 3.5795 MHz; tharrier 4.9152 MHz (/40 MHz, per 100000)
	always @(posedge clk_sys) begin
		if (z80_acc + z80_inc >= 17'd100000) begin z80_acc <= z80_acc + z80_inc - 17'd100000; z80_cen <= 1'b1; end
		else begin z80_acc <= z80_acc + z80_inc; z80_cen <= 1'b0; end
	end
	wire [15:0] z80_a;
	wire [7:0]  z80_do;
	reg  [7:0]  z80_di;
	wire        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
	wire        z80_reset_n = ~reset & g_z80snd;
	wire        z80_mem_we = ~z80_mreq_n & ~z80_wr_n;
	wire        z80_mem_re = ~z80_mreq_n & ~z80_rd_n;
	wire        z80_io_we  = ~z80_iorq_n & ~z80_wr_n;
	wire        sel_z80_rom      = (z80_a < 16'hC000);
	wire        sel_z80_ram      = (z80_a >= 16'hC000) && (z80_a < 16'hC800);
	wire        sel_z80_latch    = (z80_a == 16'hF000);
	wire        sel_z80_oki0     = (z80_a == 16'hF400);
	wire        sel_z80_oki1     = (z80_a == 16'hF500);
	wire        sel_z80_okibank0 = (z80_a == 16'hF600);
	wire        sel_z80_okibank1 = (z80_a == 16'hF700);
	wire        sel_io_ym        = (z80_a[7:1] == 7'd0);
	wire [7:0]  z80_rom_dout;
	wire        z80_rom_ready;
	wire        z80_wait_n = ~(sel_z80_rom & z80_mem_re & ~z80_rom_ready);
	T80s z80_cpu (
		.RESET_n(z80_reset_n), .CLK(clk_sys), .CEN(z80_cen), .WAIT_n(z80_wait_n),
		.INT_n(ym_chip_irq_n), .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0),
		.DI(z80_di), .M1_n(), .MREQ_n(z80_mreq_n), .IORQ_n(z80_iorq_n), .RD_n(z80_rd_n), .WR_n(z80_wr_n),
		.RFSH_n(), .HALT_n(), .BUSAK_n(), .A(z80_a), .DO(z80_do)
	);
	reg [7:0] z80_ram [0:2047];
	reg [7:0] z80_ram_q;
	always @(posedge clk_sys) begin
		if (z80_mem_we & sel_z80_ram) z80_ram[z80_a[10:0]] <= z80_do;
		z80_ram_q <= z80_ram[z80_a[10:0]];
	end
	reg [7:0] soundlatch_data; // 68000 -> Z80 (tharrier: 0x08001F)
	always @(posedge clk_sys) begin
		if (reset) soundlatch_data <= 8'h00;
		else if (g_z80snd & sel_nmk004_w & cpu_write & ~LDSn) soundlatch_data <= oEdb[7:0];
	end
	always @(*) begin
		if (~z80_iorq_n)        z80_di = ym_chip_dout;
		else if (sel_z80_rom)   z80_di = z80_rom_dout;
		else if (sel_z80_ram)   z80_di = z80_ram_q;
		else if (sel_z80_latch) z80_di = soundlatch_data;
		else if (sel_z80_oki0)  z80_di = oki1_chip_dout;
		else if (sel_z80_oki1)  z80_di = oki2_chip_dout;
		else                    z80_di = 8'hFF;
	end
	generate
	if (!HW_ROMS) begin : g_z80_rom_sim
		reg [7:0] z80_rom [0:65535];
		initial if (AUDIOCPU_FILE != "") $readmemh(AUDIOCPU_FILE, z80_rom);
		assign z80_rom_dout  = z80_rom[z80_a];
		assign z80_rom_ready = 1'b1;
		assign p1_addr[7] = 24'd0; assign p1_req[7] = 1'b0;
	end else begin : g_z80_rom_hw
		oki_rom_cache z80_cache_inst (
			.base_word(BASE_WORD_NMK004),
			.clk(clk_sys), .reset(reset),
			.byte_addr({6'd0, z80_a}), .data(z80_rom_dout), .ready(z80_rom_ready), .stall(),
			.sd_addr(p1_addr[7]), .sd_req(p1_req[7]), .sd_busy(p1_busy[7]), .sd_valid(p1_valid[7]), .sd_dout(p1_dout[7]), .sd_dout_pair(p1_dout_pair[7])
		);
	end
	endgenerate

	// ------------------------------------------------------------------
	// cactus (2026-09-12): sabotenb's scrambled ROM data on a board with
	// no NMK-215 — MAME's init_nmk table decode is the NMK214 scheme with
	// the configs the NMK-215 sends sabotenb; they are written here after
	// reset instead (the same two-byte sequence the MCU produces).
	// ------------------------------------------------------------------
	reg [2:0] cac_cnt;
	reg       cac_we;
	reg [7:0] cac_data;
	always @(posedge clk_sys) begin
		cac_we <= 1'b0;
		if (reset) cac_cnt <= 3'd0;
		else if (cac_cnt != 3'd7) begin
			cac_cnt <= cac_cnt + 3'd1;
			if (cac_cnt == 3'd2) begin cac_we <= 1'b1; cac_data <= CACTUS_CFG_SPR; end
			if (cac_cnt == 3'd5) begin cac_we <= 1'b1; cac_data <= CACTUS_CFG_BG; end
		end
	end
	wire       vid_cfg_we   = g_cactus ? cac_we   : (nmk214_cfg_we & has_214);
	wire [7:0] vid_cfg_data = g_cactus ? cac_data : nmk214_cfg_data;

	// ------------------------------------------------------------------
	// 68000 read-data mux
	// ------------------------------------------------------------------
	reg [15:0] rdata;
	always @(*) begin
		if (sel_rom)          rdata = rom_dout;
		else if (sel_mainram) rdata = mainram_dout;
		else if (sel_palette) rdata = palette_dout;
		else if (sel_bgvram)  rdata = bgvram_dout;
		else if (sel_bgvram2) rdata = bgvram2_dout;
		else if (sel_txvram)  rdata = txvram_dout;
		else if (sel_nmk004_r) rdata = g_vandykeb ? 16'h0000 : {8'h00, nmk004_to_host_latch}; // vandykeb_r: 0; tharrier: soundlatch2
		else if (sel_oki0)    rdata = {8'h00, oki1_chip_dout};
		else if (sel_oki1)    rdata = {8'h00, oki2_chip_dout};
		else if (sel_mb3_prot) rdata = mb3_prot_val;
		else if (sel_in0)     rdata = g_tharrier ? th_in0 : (in0_eff & ~{9'd0, g_vandykeb, 6'd0}); // vandykeb: IN0 bit 6 is IP_ACTIVE_HIGH "tested on boot" — reading it 1 drops the game into its service-mode test loop (WRAM check / tile / grid screens)
		else if (sel_in1)     rdata = g_tharrier ? (LDSn ? {th_mcu_val, 8'h00} : th_in1) : (HW_ROMS ? in1_i : 16'hFFFF); // tharrier: upper-byte-only reads = the MCU
		else if (sel_in2)     rdata = th_in2;
		else if (sel_dsw1)    rdata = (HW_ROMS || (SIM_DSW != 0)) ? dsw1_i : 16'hFFFF;
		else if (sel_dsw2)    rdata = (HW_ROMS || (SIM_DSW != 0)) ? dsw2_i : 16'hFFFF;
		else                  rdata = 16'hFFFF; // unmapped (incl. the write-only scroll registers)
	end
	assign iEdb = rdata;

	// ------------------------------------------------------------------
	// Raster timing + interrupt generation: the V-PROM state machine
	// (three PROM tables, vprom_sel) or MAME's fixed-scanline substitute
	// for strahl (irq_hacky). Both run; the selected one's outputs count.
	// ------------------------------------------------------------------
	wire vt_line_start, vt_hblank, vt_vblank;
	video_timing vtiming (
		.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
		.hcount(vt_hcount), .vcount(vt_vcount),
		.line_start(vt_line_start), .hblank(vt_hblank), .vblank(vt_vblank)
	);
	assign dbg_vt_vcount = vt_vcount;
	assign ce_pix_o = ce_pix;
	assign hcount_o = vt_hcount;
	assign vcount_o = vt_vcount;
	assign hblank_o = vt_hblank;
	assign vblank_o = vt_vblank;
	assign lowres_o = lowres;

	wire sprite_dma_trigger;
	wire [2:0] ipl_prom, ipl_hacky;
	wire       sprdma_prom, sprdma_hacky;
	nmk_irq #(
		.VTIMING_FILE(VTIMING_FILE)
	) irq_gen (
		.clk_sys(clk_sys),
		.table_sel(vprom_sel),
		.reset(reset),
		.line_start(vt_line_start),
		.vcount(vt_vcount),
		.iack_cycle(iack_cycle),
		.iack_level(eab[3:1]),
		.ipl_level(ipl_prom),
		.sprite_dma_trigger(sprdma_prom)
	);
	nmk_irq_hacky irq_gen_hacky (
		.clk_sys(clk_sys),
		.reset(reset),
		.line_start(vt_line_start),
		.vcount(vt_vcount),
		.iack_cycle(iack_cycle),
		.iack_level(eab[3:1]),
		.ipl_level(ipl_hacky),
		.sprite_dma_trigger(sprdma_hacky)
	);
	assign ipl_level          = irq_hacky ? ipl_hacky    : ipl_prom;
	assign sprite_dma_trigger = irq_hacky ? sprdma_hacky : sprdma_prom;

	// ------------------------------------------------------------------
	// Video — video_macross2.sv, gfx_macross parameters + per-line scroll
	// + NMK214 descramble, with the runtime layer configuration above.
	// ------------------------------------------------------------------
	video_macross2 #(
		.TX_EXTERNAL(1),
		.FGTILE_FILE(FGTILE_FILE),
		.BGTILE_FILE(BGTILE_FILE),
		.BG2TILE_FILE(BG2TILE_FILE),
		.SPRITES_FILE(SPRITES_FILE),
		.HW_ROMS(HW_ROMS),
		.DBG_MISS_PAINT(DBG_MISS_PAINT),
		.RASTER_SCROLL(1),
		.SPRITES_BYTES(2097152),
		.BGTILE_BYTES(2097152),
		.BG2TILE_BYTES(524288),
		.SPR_COLOUR_BITS(4),
		.TX_PAL_BASE_P(10'h200),
		.BG_CODE_BITS(13),
		.NMK214(1),
		.BG2_LAYER(1)
	) video (
		.clk_sys(clk_sys), .reset(reset),
		.lowres(lowres), .raster_scroll(g_gunnail), .cfg_rt(1'b1),
		.bga_pal_base_i(cfg_bga_pal), .bgb_pal_base_i(cfg_bgb_pal), .spr_pal_base_i(cfg_spr_pal), .tx_pal_base_i(cfg_tx_pal),
		.bga_code_mask_i(cfg_bga_mask), .bgb_code_mask_i(cfg_bgb_mask), .spr_units_i(cfg_spr_units),
		.sprdma_word_base(cfg_sprdma_word), .nmk214_en(has_214), .spr_swap(~spr_plain),
		.bg2_en(bg2), .bga_rom2(g_bioship), .bgb_rom2(g_strahl), .base_word_bgtile_b(BASE_WORD_BGTILE_B),
		.bgvram_b_addr(vid_bgvram_b_addr), .bgvram_b_data(vid_bgvram_b_dout),
		.bgb_xscroll(bgb_xscroll), .bgb_yscroll(bgb_yscroll),
		.sprite_dma_trigger(sprite_dma_trigger), .sprite_dma_busy(sprite_dma_busy),
		.bgvram_addr(vid_bgvram_addr), .bgvram_data(vid_bgvram_dout),
		.txvram_addr(vid_txvram_addr), .txvram_data(vid_txvram_dout),
		.palette_addr(vid_palette_addr), .palette_data(vid_palette_dout),
		.spr_palette_addr(vid_spr_palette_addr), .spr_palette_data(vid_spr_palette_dout),
		.mainram_addr(vid_mainram_addr), .mainram_data(vid_mainram_dout), .mainram_ready(vid_mainram_ready),
		.bg_xscroll(bga_xscroll), .bg_yscroll(bga_yscroll),
		.scrollram_0(scrollram0_reg), .scrollramy_0(scrollramy0_reg),
		.scroll_row_addr(vid_scroll_row_addr),
		.scrollram_row(vid_scrollram_row), .scrollramy_row(vid_scrollramy_row),
		.nmk214_cfg_we(vid_cfg_we), .nmk214_cfg_data(vid_cfg_data),
		.tx_bg_mode(g_bjtwin), .tx_yscroll(8'd0 - tx_scroll_reg), .tx_bank_off(cfg_tx_bank_off),
		.spr_flip_en(g_tharrier), .spr_lag1(g_bjtwin), .vis_start(vt_line_start & (vt_vcount == 10'd16)),
		.bg_bank(bgbank_reg),
		.game_powerins(1'b0), .tile_lsb(1'b0), .base_word_fgtile(BASE_WORD_FGTILE), .base_word_bgtile(BASE_WORD_BGTILE_A), .base_word_sprites(BASE_WORD_SPRITES),
		.tilerambank(2'd0),
		.rd_x(rd_x), .rd_y(rd_y), .rd_rgb(rd_rgb),
		.sd_addr(sd2_addr), .sd_wrl(sd2_wrl), .sd_wrh(sd2_wrh), .sd_din(sd2_din),
		.sd_dout(sd2_dout), .sd_dout_pair(sd2_dout_pair), .sd_req(sd2_req), .sd_ack(sd2_ack),
		.sd_b_addr(sd1_addr), .sd_b_req(sd1_req), .sd_b_dout(sd1_dout), .sd_b_dout_pair(sd1_dout_pair), .sd_b_ack(sd1_ack),
		.txc_addr(p1_addr[0]), .txc_req(p1_req[0]), .txc_busy(p1_busy[0]), .txc_valid(p1_valid[0]), .txc_dout(p1_dout[0]), .txc_dout_pair(p1_dout_pair[0])
	);

	reg frame_done_r;
	always @(posedge clk_sys) frame_done_r <= vt_line_start && (vt_vcount == 10'd0);
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
	assign dbg_ym_we = ym_we;
	assign dbg_ym_cs = ym_cs;
	assign dbg_ym_chip_dout = ym_chip_dout;
	assign dbg_ym_chip_irq_n = ym_chip_irq_n;
	assign dbg_ym_wdata = ym_dout;
	assign dbg_ym_waddr = ym_addr_sel;
	assign dbg_oki0_we = oki0_we;
	assign dbg_oki0_cs = oki0_cs;
	assign dbg_oki0_chip_dout = oki1_chip_dout;
	assign dbg_oki1_we = oki1_we;
	assign dbg_oki1_cs = oki1_cs;
	assign dbg_oki1_chip_dout = oki2_chip_dout;

endmodule
