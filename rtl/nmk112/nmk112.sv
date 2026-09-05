// NMK112 — NMK custom IC for bank-switching the sample ROMs of a pair of
// OKIM6295 chips. Ported directly from mame/src/devices/machine/nmk112.cpp
// (131 lines, read in full before implementing — every detail below is
// confirmed against that source, not assumed).
//
// Register interface: 8 write-only bank-select registers, addressed
// offset 0-7 (`okibank_w(offset,data)`, nmk112.cpp:86-98). `chip =
// BIT(offset,2)` (0 or 1, selects which OKIM6295), `banknum = offset & 3`
// (0-3). `data` sets that chip+banknum's own currently-selected 64KB
// page index into the chip's own full sample ROM.
//
// Address remap: PURE address-range decode, no awareness of which of
// jt6295's own 4 internal ADPCM channels issued a given fetch — confirmed
// directly from nmk112.cpp's own `oki_map()`/`oki_bank` (nmk112.cpp:
// 105-130): each OKI's own logical 0x00000-0x3FFFF address space is
// split into four fixed 0x10000-byte (64KB) windows, window N reading
// from `samplebank[chip][N]`'s own currently-selected page. This "window
// = voice N's own bank" mapping is purely a matter of how the ORIGINAL
// game's own ROM data happens to be organized (each voice's own samples
// conventionally live within a consistent quarter of the pre-remap
// address space) — the hardware itself (both the real NMK112 and this
// remap) never needs to know which internal ADPCM channel a fetch
// belongs to, only which address range it falls in. Confirmed by reading
// jt6295's own internal channel round-robin (`rtl/third_party/jt6295/
// hdl/jt6295_serial.v`'s own `ch` register) — it is NOT exposed on
// jt6295's own top-level port list, and (per the address-only nature of
// nmk112.cpp's own C++ model above) does not need to be: this module
// intercepts jt6295's own flat `rom_addr` output unmodified, no vendored
// third-party file touched.
//
// Paged mode ("sample address table" independent per-voice banking,
// nmk112.cpp:6-9's own header comment): `is_paged(chip) =
// BIT(m_page_mask,chip)`, and the device's own default constructor value
// is `m_page_mask(0xff)` — since none of this project's own consuming
// machine configs (macross2() included, nmk16.cpp:5477-5479) call
// `set_page_mask()`, BOTH chips default to paged. In paged mode, the
// FIRST 0x400 bytes of the chip's own ENTIRE logical address space (not
// per-window — confirmed: `map(0x00000,0x000ff)`..`map(0x00300,0x003ff)`
// are absolute, not offset by any bank window) are overlaid: sub-range
// N*0x100..N*0x100+0xFF reads from `tablebank[chip][N]`, which
// `device_start()`'s own `configure_entry` call (nmk112.cpp:46-59) points
// at `tablebase = pagebase | (N<<8)` — i.e. the SAME 64KB page samplebank
// selects for that same index N, just read starting N*0x100 bytes in.
// Combined with that override's own 0x100-byte-wide window, this is
// exactly equivalent to reading page*0x10000+addr directly for addr in
// this range (no separate offset arithmetic needed — verified by hand:
// tablebase + (addr - N*0x100) = page*0x10000 + N*0x100 + addr - N*0x100
// = page*0x10000 + addr). Since one register write sets both bank[chip]
// [N]'s own samplebank AND tablebank entries to the identical value
// (`okibank_w`'s own two calls, same `data`), a single register file
// serves both purposes here — no separate storage needed.
//
// Ported once, used by every family reusing this chip pair (macross2 and
// onward per docs/PLAN.md's own component inventory) — a real, reusable
// device, not baked into any one game's own core.sv.
module nmk112 #(
	parameter ROM0_BYTES = 0, // used to clamp written page indices (see mask0/mask1 below); 0 = no clamp
	parameter ROM1_BYTES = 0
) (
	input clk_sys,
	input reset,

	// register writes: reg_sel[2]=chip, reg_sel[1:0]=banknum — matches
	// okibank_w's own offset decode exactly (see header). One write sets
	// both the sample-bank and table-bank entry for that chip+banknum.
	input  [2:0] reg_sel,
	input  [7:0] reg_data,
	input        reg_we,

	// Chip 0 (rom0/"oki1") address remap.
	input  [17:0] rom0_addr_in,
	output [21:0] rom0_addr_out,
	// Chip 1 (rom1/"oki2") address remap.
	input  [17:0] rom1_addr_in,
	output [21:0] rom1_addr_out
);

	reg [7:0] bank [0:1][0:3];

	// nmk112.cpp:93/96 mask every written page index with `data &
	// m_bankmask[chip]` before storing it (m_bankmask is size-1 for a
	// power-of-two page count, which every real OKI ROM in this hardware
	// family is — 0x80000/0x100000/0x200000/0x400000 all divide evenly
	// into a power-of-two count of 64KB pages). Replicated here as a
	// simple bitmask from each ROM's own byte-size parameter; ROM*_BYTES=0
	// (parameter not supplied) falls back to no masking, same as before.
	localparam [7:0] MASK0 = (ROM0_BYTES == 0) ? 8'hFF : (ROM0_BYTES / 65536) - 1;
	localparam [7:0] MASK1 = (ROM1_BYTES == 0) ? 8'hFF : (ROM1_BYTES / 65536) - 1;

	integer ci, bi;
	always @(posedge clk_sys) begin
		if (reset) begin
			for (ci = 0; ci < 2; ci = ci + 1)
				for (bi = 0; bi < 4; bi = bi + 1)
					bank[ci][bi] <= 8'd0;
		end else if (reg_we) begin
			bank[reg_sel[2]][reg_sel[1:0]] <= reg_sel[2] ? (reg_data & MASK1) : (reg_data & MASK0);
		end
	end

	// addr<0x400: paged table-bank override, sub-window selected by
	// addr[9:8] (see header — equivalent to page*0x10000+addr directly).
	// addr>=0x400: plain 64KB-window sample-bank decode, window selected
	// by addr[17:16].
	function automatic [21:0] remap(input [17:0] addr, input [7:0] b0, input [7:0] b1, input [7:0] b2, input [7:0] b3);
		reg [7:0] page;
		begin
			page = (addr < 18'h400) ?
				(addr[9:8] == 2'd0 ? b0 : addr[9:8] == 2'd1 ? b1 : addr[9:8] == 2'd2 ? b2 : b3) :
				(addr[17:16] == 2'd0 ? b0 : addr[17:16] == 2'd1 ? b1 : addr[17:16] == 2'd2 ? b2 : b3);
			remap = ({14'd0, page} << 16) | {6'd0, addr[15:0]};
		end
	endfunction

	assign rom0_addr_out = remap(rom0_addr_in, bank[0][0], bank[0][1], bank[0][2], bank[0][3]);
	assign rom1_addr_out = remap(rom1_addr_in, bank[1][0], bank[1][1], bank[1][2], bank[1][3]);

endmodule
