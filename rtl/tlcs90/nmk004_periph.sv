// TLCS-90 on-chip peripheral registers (0xffc0-0xffef in the reference's
// tmp90840_regs address map) — ports, timers 0-4, and the interrupt
// enable/flag registers. Built and verified against MAME's
// cpu/tlcs90/tlcs90.cpp reference model — see docs/tier2-tlcs90.md's
// "Peripheral registers" section for the full register map and which
// registers are confirmed exercised by the NMK004 boot ROM.
//
// Address decode is the caller's job: `reg_addr` is the register offset
// from 0xffc0 (i.e. addr[5:0] when addr[15:6]==10'b1111_1111_11), and
// `we`/`re` should only be asserted when the caller has already confirmed
// the full address falls in 0xffc0-0xffef.
//
// Scope (documented, not hidden):
//   - Ports (P1-P8 + their direction/function control registers) are
//     plain read/write latches, not real GPIO-pin models — per
//     docs/tier2-tlcs90.md, this core's external bus is implemented
//     directly (dedicated address/data/strobe signals), not through P1/P2
//     as literal multiplexed pins, so the port *values* real firmware
//     writes are preserved (in case anything reads them back) without
//     modeling direction-register masking, pin loopback, or any attached
//     device behavior. P4 bit 0 is exposed as `p4_bit0` for the future
//     NMK004 top-level wrapper to drive the 68000 host's reset line
//     (nmk004_device::port4_w in the reference) — not wired to anything
//     yet, since there's no 68000 in this design.
//   - Timers 0-3 (8-bit, or 16-bit paired per TMOD) and timer 4/5
//     (16-bit compare-match with independent TREG4/TREG5 match points)
//     are REAL counters, matching t90_timer_callback/t90_timer4_callback
//     exactly — this is the one part of the peripheral surface MAME
//     itself doesn't stub, so neither do we.
//   - INTEL/INTEH decode into `irq_mask` for the CPU core's irq_mask
//     input, in the same bit order the CPU expects (see tlcs90.sv's port
//     comment): bit0=INT0, bit1=T0, bit2=T1, bit3=T2, bit4=T3, bit5=T4,
//     bit6=INT1, bit7=T5, bit8=INT2, bit9=RX, bit10=TX.
//   - IRF-clear (0xffc3 write) is accepted but currently a no-op: our
//     only real IRQ sources (the timers) already auto-clear on take via
//     the CPU core's own dispatch logic (matching clear_irq() being
//     called from take_interrupt() for every source except INT0 in level
//     mode) — manual IRF clearing only matters for sources not modeled
//     yet (INT0/INT1/INT2/serial), so this is a real, narrow gap, not a
//     blanket stub.
//   - Watchdog (WDMOD/WDCR), serial (SCMOD/SCCR/SCBUF — not even mapped
//     for this specific TLCS-90 variant in the reference), ADC
//     (ADREG/ADMOD), stepping-motor mode (SMMOD's *functional* effect,
//     though the register itself is stored and read back correctly), and
//     DMA (DMAEH) are not implemented — matching the reference's own
//     reserved_r/reserved_w stub for these (reads return 0, writes are
//     discarded), since MAME itself doesn't implement them either.
//   - BX/BY are stored and read back (matching bx_r()/by_r()'s exact
//     `0xf0|nibble` format) via the `bx`/`by` outputs below, which the
//     caller wires into the CPU core's `ix_bank`/`iy_bank` inputs — IX/IY
//     bank extension itself (applying the nibble to IX/IY-based memory
//     addressing) is the CPU core's job, implemented there (see
//     tlcs90.sv's header and its `bank1`/`bank2` wires).
//   - **P5/P6 external-read override** (`p5_ext_en`/`p6_ext_en` +
//     `p5_ext_val`/`p6_ext_val`, plus `p6_we`/`p6_wdata` on the write
//     side): added for the TLCS-90 *protection-MCU* role (Tier 2's
//     Family D — see `rtl/tlcs90/nmk_prot_core.sv`), which installs its
//     own `port_read<5>`/`port_read<6>`/`port_write<6>` callbacks in the
//     reference (`tdragon_prot_state::mcu_port5_r`/`mcu_port6_r`/
//     `mcu_port6_w`) that *replace* the plain port-latch behavior
//     entirely — P5 reads return the current scanline (`screen.vpos()
//     >>2`), P6 reads return a toggling bus-status flag, and P6 writes
//     are inspected for 0x08/0x0B (68000 bus take/release) rather than
//     latched. This peripheral register map (`tmp90840_regs` in the
//     reference's own `cpu/tlcs90/tlcs90.cpp`) is identical between the
//     TMP90840 (NMK004's own role) and TMP91640 (the protection-MCU
//     role) — confirmed directly, not assumed — so one module serves
//     both; only the owning board wrapper differs (internal ROM/RAM
//     size, and now this override wiring). Every new input defaults to
//     inert when tied 0/0 (nmk004_core.sv's own instantiation does
//     exactly that), so this is purely additive: P5 still reads 0xFF
//     and P6 still reads 0x00 (its own prior default-case fallthrough,
//     preserved exactly rather than "fixed" to return the p6 latch,
//     since that latch was never faithfully modeled here either and
//     changing it now would be an unrelated, unverified behavior change
//     to an already-verified module) for every existing caller.
//   - **P7 external-read override** (`p7_ext_en`/`p7_ext_val`): added
//     for hachamf's own NMK-113 protection ROM, which is confirmed
//     (directly from `hachamf_prot()`) to be a *shared* firmware image
//     used by several different games, selecting its own per-game
//     codepath via `port_read<7>().set_constant(...)` — a fixed,
//     per-game hardwired value (0x0c for hachamf), not a real R/W port.
//     Same pattern as P5/P6: tied inert (0/0) for both NMK004's own
//     role and tdragon1's own protection role, where P7 stays a plain
//     read/write latch exactly as before.
module nmk004_periph (
	input        clk,
	input        reset,

	input  [5:0] reg_addr, // addr - 0xffc0
	input  [7:0] wdata,
	input        we,
	input        re,
	output reg [7:0] rdata,

	output [10:0] irq_mask, // to the CPU core's irq_mask input
	output [10:0] irq_req,  // to the CPU core's irq_req input (timer pulses)

	output [7:0] p4_latch,  // bit0 = future 68000-reset drive, see header
	output [3:0] bx, by,

	// P5/P6 external-read override + P6 write tap — see header. Tie
	// p5_ext_en/p6_ext_en low (NMK004's own role) to preserve every
	// prior behavior exactly.
	input        p5_ext_en,
	input  [7:0] p5_ext_val,
	input        p6_ext_en,
	input  [7:0] p6_ext_val,
	output       p6_we,
	output [7:0] p6_wdata,

	// P7 external-read override — see header. Tie p7_ext_en low to
	// preserve the plain read/write latch behavior exactly.
	input        p7_ext_en,
	input  [7:0] p7_ext_val
);

	// ------------------------------------------------------------------
	// Ports — plain latches, see header.
	// ------------------------------------------------------------------
	reg [7:0] p1, p2, p3, p4, p6, p7, p8;
	reg [7:0] p01cr, p2cr, p4cr, p67cr, p8cr;
	reg [7:0] smmod;
	assign p4_latch = p4;
	assign bx = bx_r[3:0];
	assign by = by_r[3:0];
	reg [7:0] bx_r, by_r;

	// ------------------------------------------------------------------
	// Timers 0-3: base tick every 8 clk cycles (matches the reference's
	// m_timer_period = 8 device-clock periods exactly, since this core's
	// `clk` already *is* the TLCS-90's own clock — see tlcs90.sv), then
	// per-timer prescale (1/16/256, from TCLK) or "clocked by the
	// preceding timer's match" (TCLK field == 0, odd timers only).
	// ------------------------------------------------------------------
	reg [7:0] tmod, tclk, trun;
	reg [7:0] treg [0:3];

	reg [2:0] base_div;
	wire base_tick = (base_div == 3'd7);
	always @(posedge clk) base_div <= reset ? 3'd0 : (base_tick ? 3'd0 : base_div + 3'd1);

	// Pair-level match mode (see header derivation in docs/tier2-tlcs90.md:
	// the reference's match-time mode lookup uses the *odd* member's own
	// TMOD field for both timers in a pair, regardless of the even
	// member's own field — confirmed equivalent to just using tmod[3:2]
	// for the {T0,T1} pair and tmod[5:4] for the {T2,T3} pair).
	wire [1:0] pair_mode_01 = tmod[3:2];
	wire [1:0] pair_mode_23 = tmod[5:4];

	// Prescale divisor-minus-1 per TCLK field, and whether that field
	// selects a real (non-chained/unsupported) prescale at all. Computed
	// as plain combinational case statements into wires rather than a
	// `function automatic` called from inside other continuous
	// assignments — found, via direct simulation debugging, that the
	// latter silently never evaluated true here (a different instance of
	// the same class of Verilator function-composition issue documented
	// in tlcs90.sv's former resolve_direct() — see that file's comment
	// for the full story). Not chasing the simulator bug twice; this
	// inline form is proven to work.
	reg [15:0] presc_m1_0, presc_m1_1, presc_m1_2, presc_m1_3;
	reg        presc_valid_0, presc_valid_1, presc_valid_2, presc_valid_3;
	wire [1:0] tclk0 = tclk[1:0], tclk1 = tclk[3:2], tclk2 = tclk[5:4], tclk3 = tclk[7:6];
	always @(*) begin
		case (tclk0)
			2'b01: begin presc_valid_0 = 1'b1; presc_m1_0 = 16'd0; end
			2'b10: begin presc_valid_0 = 1'b1; presc_m1_0 = 16'd15; end
			2'b11: begin presc_valid_0 = 1'b1; presc_m1_0 = 16'd255; end
			default: begin presc_valid_0 = 1'b0; presc_m1_0 = 16'd0; end
		endcase
		case (tclk1)
			2'b01: begin presc_valid_1 = 1'b1; presc_m1_1 = 16'd0; end
			2'b10: begin presc_valid_1 = 1'b1; presc_m1_1 = 16'd15; end
			2'b11: begin presc_valid_1 = 1'b1; presc_m1_1 = 16'd255; end
			default: begin presc_valid_1 = 1'b0; presc_m1_1 = 16'd0; end
		endcase
		case (tclk2)
			2'b01: begin presc_valid_2 = 1'b1; presc_m1_2 = 16'd0; end
			2'b10: begin presc_valid_2 = 1'b1; presc_m1_2 = 16'd15; end
			2'b11: begin presc_valid_2 = 1'b1; presc_m1_2 = 16'd255; end
			default: begin presc_valid_2 = 1'b0; presc_m1_2 = 16'd0; end
		endcase
		case (tclk3)
			2'b01: begin presc_valid_3 = 1'b1; presc_m1_3 = 16'd0; end
			2'b10: begin presc_valid_3 = 1'b1; presc_m1_3 = 16'd15; end
			2'b11: begin presc_valid_3 = 1'b1; presc_m1_3 = 16'd255; end
			default: begin presc_valid_3 = 1'b0; presc_m1_3 = 16'd0; end
		endcase
	end

	wire       en0 = trun[5] & trun[0], en1 = trun[5] & trun[1];
	wire       en2 = trun[5] & trun[2], en3 = trun[5] & trun[3];
	wire       chained1 = (tclk1 == 2'b00);
	wire       chained3 = (tclk3 == 2'b00);

	reg [15:0] presc0, presc1, presc2, presc3; // free-running, compared each base_tick
	wire tick0 = en0 && base_tick && presc_valid_0 && (presc0 == presc_m1_0);
	wire tick2 = en2 && base_tick && presc_valid_2 && (presc2 == presc_m1_2);
	wire tick3_self = en3 && !chained3 && base_tick && presc_valid_3 && (presc3 == presc_m1_3);

	reg [7:0] tval [0:3]; // m_timer_value[i]
	reg       fired0, fired1, fired2, fired3; // this-cycle match pulses, for chaining + irq_req

	// {T0,T1} pair
	wire pair01_16bit = (pair_mode_01 == 2'b01);
	wire tick1 = en1 && (chained1 ? fired0 : (base_tick && presc_valid_1 && (presc1 == presc_m1_1)));
	// {T2,T3} pair
	wire pair23_16bit = (pair_mode_23 == 2'b01);
	wire tick3 = tick3_self | (chained3 & fired2);

	always @(posedge clk) begin
		fired0 <= 1'b0; fired1 <= 1'b0; fired2 <= 1'b0; fired3 <= 1'b0;

		if (reset) begin
			presc0 <= 16'd0; presc1 <= 16'd0; presc2 <= 16'd0; presc3 <= 16'd0;
			tval[0] <= 8'd0; tval[1] <= 8'd0; tval[2] <= 8'd0; tval[3] <= 8'd0;
		end else begin
			// prescale counters (only the non-chained ones matter, but
			// harmless to run all four unconditionally)
			// Prescale counters hold at 0 while their timer is disabled
			// (not free-running) and start fresh from 0 the moment the
			// timer is (re-)enabled — matching t90_start_timer()'s own
			// m_timer_value/timer-phase reset on start. A free-running
			// prescaler that only gets zeroed *by* its own match (as
			// initially written) can sit well past the match point for
			// the entire time the timer is disabled, then have to count
			// all the way around before ever matching again once enabled
			// — a real bug found via direct simulation (tick0 never fired
			// even though TRUN/TMOD/TCLK/TREG were all confirmed correct).
			if (!en0) presc0 <= 16'd0;
			else if (base_tick) presc0 <= tick0 ? 16'd0 : presc0 + 16'd1;

			if (!en1 || chained1) presc1 <= 16'd0;
			else if (base_tick) presc1 <= tick1 ? 16'd0 : presc1 + 16'd1;

			if (!en2) presc2 <= 16'd0;
			else if (base_tick) presc2 <= tick2 ? 16'd0 : presc2 + 16'd1;

			if (!en3 || chained3) presc3 <= 16'd0;
			else if (base_tick) presc3 <= tick3_self ? 16'd0 : presc3 + 16'd1;

			// {T0,T1}
			if (!pair01_16bit) begin
				if (tick0) begin
					tval[0] <= tval[0] + 8'd1;
					if ((tval[0] + 8'd1) == treg[0]) begin tval[0] <= 8'd0; fired0 <= 1'b1; end
				end
				if (tick1) begin
					tval[1] <= tval[1] + 8'd1;
					if ((tval[1] + 8'd1) == treg[1]) begin tval[1] <= 8'd0; fired1 <= 1'b1; end
				end
			end else begin
				// 16-bit pair: only T0's own tick advances the combined
				// counter; T1 (per the reference's `if(i&1) break;`) never
				// ticks independently in this mode.
				if (tick0) begin
					tval[0] <= tval[0] + 8'd1;
					if ((tval[0] + 8'd1) == 8'd0) tval[1] <= tval[1] + 8'd1;
					if (((tval[0] + 8'd1) == treg[0]) &&
					    (((tval[0] + 8'd1) == 8'd0 ? tval[1] + 8'd1 : tval[1]) == treg[1])) begin
						tval[0] <= 8'd0; tval[1] <= 8'd0;
						fired0 <= 1'b1; fired1 <= 1'b1;
					end
				end
			end

			// {T2,T3}
			if (!pair23_16bit) begin
				if (tick2) begin
					tval[2] <= tval[2] + 8'd1;
					if ((tval[2] + 8'd1) == treg[2]) begin tval[2] <= 8'd0; fired2 <= 1'b1; end
				end
				if (tick3) begin
					tval[3] <= tval[3] + 8'd1;
					if ((tval[3] + 8'd1) == treg[3]) begin tval[3] <= 8'd0; fired3 <= 1'b1; end
				end
			end else begin
				if (tick2) begin
					tval[2] <= tval[2] + 8'd1;
					if ((tval[2] + 8'd1) == 8'd0) tval[3] <= tval[3] + 8'd1;
					if (((tval[2] + 8'd1) == treg[2]) &&
					    (((tval[2] + 8'd1) == 8'd0 ? tval[3] + 8'd1 : tval[3]) == treg[3])) begin
						tval[2] <= 8'd0; tval[3] <= 8'd0;
						fired2 <= 1'b1; fired3 <= 1'b1;
					end
				end
			end
		end
	end

	// ------------------------------------------------------------------
	// Timer 4/5: 16-bit free-running counter, two independent compare
	// points (TREG4 -> INTT4, TREG5 -> INTT5, TREG5 match optionally
	// resets the counter per T4MOD bit2), matching t90_timer4_callback.
	// ------------------------------------------------------------------
	reg [7:0] t4mod;
	reg [15:0] treg4, treg5;
	reg [15:0] tval4;
	reg        fired4, fired5;

	wire [1:0] t4clk = t4mod[1:0];
	wire       en4 = trun[5] & trun[4];
	reg [15:0] presc4;
	wire t4_prescale_valid = (t4clk == 2'b01) || (t4clk == 2'b10);
	wire [15:0] t4_prescale = (t4clk == 2'b10) ? 16'd16 : 16'd1;
	wire tick4 = en4 && t4_prescale_valid && base_tick && (presc4 == t4_prescale - 16'd1);

	always @(posedge clk) begin
		fired4 <= 1'b0; fired5 <= 1'b0;
		if (reset) begin
			presc4 <= 16'd0; tval4 <= 16'd0;
		end else begin
			if (!en4) presc4 <= 16'd0;
			else if (base_tick) presc4 <= tick4 ? 16'd0 : presc4 + 16'd1;
			if (tick4) begin
				tval4 <= tval4 + 16'd1;
				if ((tval4 + 16'd1) == treg4) fired4 <= 1'b1;
				if ((tval4 + 16'd1) == treg5) begin
					fired5 <= 1'b1;
					if (t4mod[2]) tval4 <= 16'd0;
				end
			end
		end
	end

	// ------------------------------------------------------------------
	// Interrupt enable (INTEL/INTEH) and request lines
	// ------------------------------------------------------------------
	reg [10:0] irq_mask_r;
	assign irq_mask = irq_mask_r;
	// bit order: 0=INT0 1=T0 2=T1 3=T2 4=T3 5=T4 6=INT1 7=T5 8=INT2 9=RX 10=TX
	// Explicit per-bit assignment rather than a concatenation — a
	// concatenation here was found, by hand-counting against the bit
	// order documented above, to be off by one (fired0/T0 landed on
	// bit2/T1's slot and so on down the line), a real bug that happened
	// to produce a plausible-looking interrupt anyway for the one mask
	// configuration tested so far (T1 enabled) purely by coincidence.
	reg [10:0] irq_req_r;
	assign irq_req = irq_req_r;
	always @(*) begin
		irq_req_r = 11'd0;
		irq_req_r[1] = fired0; // T0
		irq_req_r[2] = fired1; // T1
		irq_req_r[3] = fired2; // T2
		irq_req_r[4] = fired3; // T3
		irq_req_r[5] = fired4; // T4
		irq_req_r[7] = fired5; // T5
	end

	// P6 write tap — see header. Pure combinational pulse, independent of
	// the p6 latch itself (which still updates normally below).
	assign p6_we = we & (reg_addr == 6'h0c);
	assign p6_wdata = wdata;

	// ------------------------------------------------------------------
	// Register read mux
	// ------------------------------------------------------------------
	always @(*) begin
		case (reg_addr)
			6'h01: rdata = p1;
			6'h04: rdata = p2;
			6'h06: rdata = p3;
			6'h08: rdata = p4 & 8'h0f;
			6'h0a: rdata = p5_ext_en ? p5_ext_val : 8'hff; // P5 — see header
			6'h0b: rdata = 8'h88 | smmod;
			6'h0c: rdata = p6_ext_en ? p6_ext_val : 8'h00; // P6 — see header (0x00 preserves the prior default-case value)
			6'h0d: rdata = p7_ext_en ? p7_ext_val : p7; // P7 — see header
			6'h10: rdata = p8;
			6'h18: rdata = tclk;
			6'h1a: rdata = tmod;
			6'h1b: rdata = trun;
			6'h24: rdata = t4mod;
			6'h2c: rdata = 8'hf0 | {4'h0, bx_r[3:0]};
			6'h2d: rdata = 8'hf0 | {4'h0, by_r[3:0]};
			default: rdata = 8'h00; // reserved_r()
		endcase
	end

	// ------------------------------------------------------------------
	// Register writes
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (reset) begin
			p01cr <= 8'h00; p2cr <= 8'h00; p4cr <= 8'h00; p67cr <= 8'h00; p8cr <= 8'h00;
			smmod <= 8'h00; tmod <= 8'h00; tclk <= 8'h00; trun <= 8'h00; t4mod <= 8'h00;
			treg[0] <= 8'h00; treg[1] <= 8'h00; treg[2] <= 8'h00; treg[3] <= 8'h00;
			treg4 <= 16'h00; treg5 <= 16'h00;
			irq_mask_r <= 11'd0;
			bx_r <= 8'h00; by_r <= 8'h00;
			p1 <= 8'h00; p2 <= 8'h00; p3 <= 8'h00; p4 <= 8'h00; p6 <= 8'h00; p7 <= 8'h00; p8 <= 8'h00;
		end else if (we) begin
			case (reg_addr)
				6'h01: p1 <= wdata;
				6'h02: p01cr <= wdata;
				6'h03: ; // IRF clear — accepted, no-op, see header
				6'h04: p2 <= wdata;
				6'h05: p2cr <= wdata;
				6'h06: p3 <= wdata;
				6'h08: p4 <= wdata;
				6'h09: p4cr <= wdata;
				6'h0b: smmod <= wdata;
				6'h0c: p6 <= wdata;
				6'h0d: p7 <= wdata;
				6'h0e: p67cr <= wdata;
				6'h10: p8 <= wdata;
				6'h11: p8cr <= wdata;
				6'h14: treg[0] <= wdata;
				6'h15: treg[1] <= wdata;
				6'h16: treg[2] <= wdata;
				6'h17: treg[3] <= wdata;
				6'h18: tclk <= wdata;
				6'h1a: tmod <= wdata;
				6'h1b: trun <= wdata;
				6'h20: treg4[7:0]  <= wdata;
				6'h21: treg4[15:8] <= wdata;
				6'h22: treg5[7:0]  <= wdata;
				6'h23: treg5[15:8] <= wdata;
				6'h24: t4mod <= wdata;
				// INTEL: bit7->T2(mask[3]) bit6->T3(mask[4]) bit5->T4(mask[5])
				// bit4->INT1(mask[6]) bit3->T5(mask[7]) bit2->INT2(mask[8])
				// bit1->RX(mask[9]) bit0->TX(mask[10]); mask[2:0] (INT0/T0/T1,
				// owned by INTEH) untouched.
				6'h26: irq_mask_r <= {wdata[0], wdata[1], wdata[2], wdata[3],
					wdata[4], wdata[5], wdata[6], wdata[7], irq_mask_r[2:0]};
				// INTEH: bit2->INT0(mask[0]) bit1->T0(mask[1]) bit0->T1(mask[2]);
				// mask[10:3] (owned by INTEL) untouched.
				6'h27: irq_mask_r <= {irq_mask_r[10:3], wdata[0], wdata[1], wdata[2]};
				6'h2c: bx_r <= wdata;
				6'h2d: by_r <= wdata;
				default: ; // reserved_w() / write-only or read-only regs written elsewhere
			endcase
		end
	end

endmodule
