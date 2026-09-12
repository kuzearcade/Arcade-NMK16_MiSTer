// NMK16 MiSTerFPGA project — Seibu Sound System v1.02 glue device.
//
// Ported directly from `seibu_sound_device` (mame/src/mame/shared/
// seibusound.{h,cpp}), the Z80 sound-board peripheral used by
// mustangb/tdragonb/acrobatmbl/strahljbl (Tier 5, Family E — "Raiden
// sound" bootlegs of NMK16-family games that otherwise use NMK004 or
// direct-Z80 sound). Owns: the Z80-side register block at 0x4000-0x401B
// (seibu_sound_map, seibusound.cpp:333-350), the IM0 interrupt-vector
// arbitration between the YM3812 (RST10) and the 68000 (RST18)
// (update_irq_lines/im0_vector_cb, seibusound.cpp:137-204), and ROM bank
// selection (bank_w, seibusound.cpp:240-244).
//
// What this module does NOT own (mustangb_core.sv, the system top-level,
// owns these directly, matching the reference's own separate memory-map
// entries):
//   - The Z80 program ROM (0000-1FFF), work RAM (2000-27FF), banked ROM
//     window (8000-FFFF) — plain memory, no device semantics.
//   - OKIM6295 (Z80 address 0x6000) — mapped directly to "oki" in the
//     reference's seibu_sound_map, bypassing seibu_sound_device entirely.
//   - YM3812's own register/data ports and audio synthesis (jtopl2) —
//     this module only arbitrates cs/we/addr_sel and passes data through,
//     exactly matching ym_r/ym_w's own pure pass-through implementation
//     (seibusound.cpp:230-238).
//
// Main-CPU-side interface: mustangb (unlike the "full" Seibu games this
// device was originally written for) only ever exercises
// `main_mustb_w` — a single word write at 0x08001E/0x08001F on the
// 68000 side (main_mustb_w, seibusound.cpp:319-329) that latches both
// main2sub bytes and unconditionally asserts RST18. Confirmed directly
// against `mustangb_map` (nmk16.cpp:682-698): there is no read of
// main_r/soundlatch/pending anywhere in that map, so this module does
// NOT implement `main_r`'s own offset switch (the 68000-side readback
// of sub2main0/1/main2sub_pending/coin_r) at all — only main_mustb_w
// (in) and the Z80-side register block below (out) exist. A later
// Family E game whose main map does read `main_r` will need that path
// added.
//
// IRQ vectoring: RST10 (YM3812, vector 0xD7) and RST18 (main CPU,
// vector 0xDF) are both IM0-mode Z80 interrupts, where the vector BYTE
// itself is what's driven onto the data bus during the CPU's
// interrupt-acknowledge cycle (M1_n & IORQ_n both low, no MREQ_n
// involved — distinct from a normal M1 opcode fetch, which is M1_n low
// with MREQ_n low). RST18 takes priority when both are pending
// (im0_vector_cb, seibusound.cpp:184-204) — replicated exactly via the
// same VECTOR_INIT/RST10_*/RST18_* state machine the reference uses
// (update_irq_lines, seibusound.cpp:137-181), so a simultaneous RST10+
// RST18 can't corrupt the vector byte the same way the reference's own
// header comment describes real hardware needing to avoid.
module seibu_sound (
	input        clk_sys,
	input        reset,

	// ------------------------------------------------------------
	// Z80-side bus (mustangb_core.sv owns ROM/RAM/bank-window/OKI
	// decode directly; this module only reacts when z80_addr falls in
	// its own 0x4000-0x401B register block, indicated by z80_sel)
	// ------------------------------------------------------------
	input  [15:0] z80_addr,
	input  [7:0]  z80_dout,      // Z80 DO (write data)
	input         z80_sel,       // z80_addr in 0x4000-0x401F (caller's address decode)
	input         z80_we,        // raw write strobe (~mreq_n & ~wr_n); this module
	                              // gates every register write with z80_sel itself
	input         z80_re,        // raw read strobe (~mreq_n & ~rd_n); z80_din is
	                              // computed unconditionally off z80_addr[4:0] below —
	                              // harmless, since the caller only muxes it onto the
	                              // Z80 data bus when it has independently decoded
	                              // z80_sel & read as the active cycle
	output reg [7:0] z80_din,    // valid only when z80_sel & read
	input         z80_m1_n,
	input         z80_iorq_n,
	output [7:0] z80_iack_vector, // valid only when z80_iack_active
	output        z80_iack_active,
	output        z80_int_n,

	// ------------------------------------------------------------
	// 68000-side handshake (main_mustb_w only — see header)
	// ------------------------------------------------------------
	input         m68k_mustb_we,   // pulse: 68000 wrote 0x08001E/F
	input  [15:0] m68k_mustb_data,
	input         m68k_mustb_lds,  // byte lanes of that write (mem_mask): low byte -> main2sub0, high -> main2sub1
	input         m68k_mustb_uds,

	// ------------------------------------------------------------
	// YM3812 (jtopl2) pass-through — 0x4008=addr0, 0x4009=addr1
	// ------------------------------------------------------------
	output        ym_cs,
	output        ym_we,
	output        ym_addr_sel,
	output [7:0]  ym_wdata,
	input  [7:0]  ym_rdata,
	input         ym_irq_n,   // YM3812's own irq_n output (fm_irqhandler source)

	// ------------------------------------------------------------
	// ROM bank select (bank_w — BIT(data,0), seibusound.cpp:242-243)
	// ------------------------------------------------------------
	output reg    bank_sel
);

	// ------------------------------------------------------------
	// IRQ arbitration state — mirrors m_rst10_irq/m_rst10_service/
	// m_rst18_irq/m_rst18_service exactly (seibusound.cpp update_irq_lines,
	// state names kept for direct traceability against the reference).
	// ------------------------------------------------------------
	reg rst10_irq, rst10_service;
	reg rst18_irq, rst18_service;

	assign z80_int_n = ~((rst10_irq & ~rst10_service) | (rst18_irq & ~rst18_service));

	// ------------------------------------------------------------
	// IM0 interrupt-acknowledge cycle: M1_n & IORQ_n both low (T80's own
	// IACK indication — distinct from an M1 opcode fetch, which pairs
	// M1_n with MREQ_n instead). RST18 wins over RST10 when both pending
	// (im0_vector_cb, seibusound.cpp:186-197).
	// ------------------------------------------------------------
	wire iack_cycle = ~z80_m1_n & ~z80_iorq_n;
	wire iack_rst18 = rst18_irq & ~rst18_service;
	wire iack_rst10 = ~iack_rst18 & rst10_irq & ~rst10_service;

	// The acknowledge state below changes on the FIRST clk_sys of the
	// cycle, but a clock-enabled Z80 samples its data bus many clk_sys
	// later — so the vector chosen at the cycle's start is latched and
	// driven for the whole cycle (2026-09-14: before this the bus had
	// already fallen back to 0xFF / RST 38h when T80 read it, and no
	// Seibu-board interrupt was ever serviced).
	reg       iack_d = 1'b0;
	reg [7:0] iack_vec_r = 8'h00;
	reg       iack_valid_r = 1'b0;
	wire      iack_start = iack_cycle & ~iack_d;
	always @(posedge clk_sys) begin
		iack_d <= iack_cycle;
		if (iack_start) begin
			iack_vec_r   <= iack_rst18 ? 8'hDF : iack_rst10 ? 8'hD7 : 8'h00;
			iack_valid_r <= iack_rst18 | iack_rst10;
		end
	end
	assign z80_iack_active = iack_cycle & (iack_d ? iack_valid_r : (iack_rst18 | iack_rst10));
	assign z80_iack_vector = iack_d ? iack_vec_r : (iack_rst18 ? 8'hDF : iack_rst10 ? 8'hD7 : 8'h00);

	// ------------------------------------------------------------
	// main2sub / sub2main latches (soundlatch_r offset 0/1, main_data_w
	// offset 0/1 — seibusound.cpp:257-270,295-329)
	// ------------------------------------------------------------
	reg [7:0] main2sub0, main2sub1;
	reg [7:0] sub2main0, sub2main1;
	reg       main2sub_pending, sub2main_pending;

	// One-cycle-delayed edge detect for the IACK acknowledge state
	// updates below — matches the reference's own synchronize()-deferred
	// (but same-effective-cycle, since MAME's scheduler.synchronize with
	// no delay runs "now") state transitions: RST10/RST18 service flags
	// only change on the actual IACK cycle, not speculatively.
	always @(posedge clk_sys) begin
		if (reset) begin
			rst10_irq     <= 1'b0;
			rst10_service <= 1'b0;
			rst18_irq     <= 1'b0;
			rst18_service <= 1'b0;
			main2sub0 <= 8'h00; main2sub1 <= 8'h00;
			sub2main0 <= 8'h00; sub2main1 <= 8'h00;
			main2sub_pending <= 1'b0;
			sub2main_pending <= 1'b0;
			bank_sel  <= 1'b0;
		end else begin
			// RST10 (YM3812) assert/clear tracks the chip's own irq_n
			// level directly (fm_irqhandler, seibusound.cpp:225-228).
			rst10_irq <= ~ym_irq_n;

			// RST18 assert: main_mustb_w always asserts, unconditionally
			// (seibusound.cpp:328).
			if (m68k_mustb_we) begin
				if (m68k_mustb_lds) main2sub0 <= m68k_mustb_data[7:0];
				if (m68k_mustb_uds) main2sub1 <= m68k_mustb_data[15:8];
				rst18_irq <= 1'b1;
			end

			// IACK: acknowledge the vector actually driven this cycle
			// (RST10_ACKNOWLEDGE / RST18_ACKNOWLEDGE — note RST18's own
			// acknowledge ALSO clears rst18_irq immediately, matching
			// seibusound.cpp:171-174 exactly; RST10's ack only raises
			// rst10_service, cleared later by an explicit rst10_ack_w).
			if (iack_start) begin
				if (iack_rst18) begin
					rst18_service <= 1'b1;
					rst18_irq     <= 1'b0;
				end else if (iack_rst10) begin
					rst10_service <= 1'b1;
				end
			end

			if (z80_sel & z80_we) begin
				case (z80_addr[4:0])
					5'h00: begin // pending_w (0x4000) — "just a guess" per reference
						main2sub_pending <= 1'b0;
						sub2main_pending <= 1'b1;
					end
					5'h01: rst18_service <= 1'b0; // irq_clear_w -> RST18_EOI
					5'h02: rst10_service <= 1'b0; // rst10_ack_w -> RST10_EOI
					5'h03: rst18_service <= 1'b0; // rst18_ack_w -> RST18_EOI
					5'h07: bank_sel <= z80_dout[0]; // bank_w
					5'h18: sub2main0 <= z80_dout;   // main_data_w offset 0
					5'h19: sub2main1 <= z80_dout;   // main_data_w offset 1
					default: ;
				endcase
			end
		end
	end

	// ------------------------------------------------------------
	// Z80-side register reads (main_r-equivalent offsets folded in:
	// soundlatch_r=0x4010/11, main_data_pending_r=0x4012,
	// coin_r=0x4013 hardwired 0xFF per mustangb's own machine config
	// (coin_io_callback().set_constant(0xff), nmk16.cpp:4668))
	// ------------------------------------------------------------
	always @(*) begin
		case (z80_addr[4:0])
			5'h10:   z80_din = main2sub0;
			5'h11:   z80_din = main2sub1;
			5'h12:   z80_din = {7'h00, sub2main_pending}; // main_data_pending_r reads m_sub2main_pending, not m_main2sub_pending (seibusound.cpp:262-265)
			5'h13:   z80_din = 8'hFF; // coin_r, hardwired per machine config
			5'h08,
			5'h09:   z80_din = ym_rdata;
			default: z80_din = 8'hFF;
		endcase
	end

	// ------------------------------------------------------------
	// YM3812 pass-through (ym_r/ym_w, seibusound.cpp:230-238)
	// ------------------------------------------------------------
	assign ym_cs      = z80_sel & (z80_addr[4:1] == 4'h4); // 0x4008/0x4009
	assign ym_we      = ym_cs & z80_we;
	assign ym_addr_sel = z80_addr[0];
	assign ym_wdata    = z80_dout;

endmodule
