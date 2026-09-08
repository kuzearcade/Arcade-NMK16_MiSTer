//
// sdram.v
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram
#(
	// REFRESH_CYCLES: clk cycles between AUTO_REFRESH commands (see
	// the access-manager `rfs_cnt` counter below). The MT48LC16M16
	// this controller targets needs all 8192 rows refreshed within
	// 64ms (JEDEC spec), i.e. at most 64ms/8192 = 7.8125us between
	// refreshes of a given row — this parameter IS that interval,
	// expressed in `clk` cycles, so it must scale with whatever clock
	// rate `clk` actually runs at. Default (850) matches this file's
	// own original tuning, which line 80's own RASCAS_DELAY comment
	// ("2 cycles@96MHz") suggests targeted something in the ~96MHz+
	// range MiSTer's own sdram.sv is typically run at elsewhere in the
	// ecosystem — 850/96MHz=8.85us, already slightly over the 7.8125us
	// spec, but with real-world retention margin most chips have
	// beyond the strict worst-case JEDEC number. Confirmed by direct
	// real-hardware testing (a standalone SDRAM write/read-back test
	// core, see SdramTest.sv) that this default is UNSAFE at this
	// project's own 40MHz clk_sys: 850/40MHz=21.25us, a full 8192-row
	// refresh sweep of ~174ms, more than DOUBLE the 64ms spec —
	// produced real, reproducible read-back data corruption on actual
	// silicon (never visible in sim/models/sdram_model.sv, which does
	// not model DRAM charge decay at all). This project's own top
	// level(s) must override REFRESH_CYCLES for their actual clk_sys
	// rate; the default here is left as this file's own original value
	// rather than silently changed, since other MiSTer cores may
	// already rely on it at their own (faster) clock rate.
	parameter REFRESH_CYCLES = 10'd850,

	// RASCAS_DELAY: cycles between an ACTIVE (row-open) command and the
	// following READ/WRITE (column-access) command — tRCD. Default (2)
	// preserved for compatibility with any other consumer at their own
	// clock rate. This project's own real-hardware bring-up work found
	// that GENUINE CONCURRENT multi-port contention (several ports
	// continuously, simultaneously requesting — never exercised by any
	// single/dual-port isolated test) produces real, reproducible data
	// corruption that plain single-port operation at the same 40MHz
	// clk_sys never shows (see SdramTest.sv's own BACKGROUND LOAD test
	// and docs/hw-bringup.md) — being tested here as a real-hardware
	// timing-margin hypothesis, overridable per top-level the same way
	// REFRESH_CYCLES already is.
	parameter RASCAS_DELAY = 3'd2,

	// PRECHARGE_DELAY: extra STATE_IDLE cycles the access manager must
	// wait, after a transaction completes, before granting the NEXT
	// REFRESH or ACTIVE command (i.e. tRP — the completed transaction's
	// own auto-precharge, see this file's own STATE_CONT-time
	// SDRAM_A={dqm,2'b10,addr} column-command encoding, needs to finish
	// before the next row can open, whether that next row is in the
	// SAME bank or not). Default 0 preserves this file's own original
	// behavior exactly (grant immediately the same cycle STATE_IDLE is
	// entered) for any other consumer. Added as a second real-hardware
	// timing-margin hypothesis after RASCAS_DELAY alone (tRCD, the
	// ACTIVATE-to-column-access delay — see that parameter's own
	// comment) failed to fix the genuine concurrent-multi-port-
	// contention data corruption this project's own BACKGROUND LOAD
	// test in SdramTest.sv found (see docs/hw-bringup.md) — unlike
	// RASCAS_DELAY, the gap this covers (STATE_READY of one transaction
	// to STATE_START of the next) was previously fixed at exactly one
	// cycle regardless of any existing parameter.
	parameter PRECHARGE_DELAY = 3'd0,

	// SEPARATE_SDRAM_CLK: default 0 preserves this file's own original
	// behavior EXACTLY for every existing consumer — SDRAM_CLK generated
	// straight from `clk` (the same clock every internal state-machine
	// register runs on) via the altddio_out DDR output cell below, with
	// NO deliberate phase compensation for the real round-trip PCB trace
	// delay between the FPGA's own clock pin and the physical SDRAM
	// chip's own clock input (and back, for read-data setup/hold at this
	// controller's own sampling flip-flops) — a real, standard SDRAM
	// design concern this project's own rtl/pll.v never addressed, since
	// that file was hand-written from scratch without interactive
	// Quartus GUI access (see its own header comment) and only ever
	// implements ONE output clock. Set to 1 to instead drive the
	// altddio_out block's own `outclock` from a SEPARATE `clk_sdram`
	// input (typically a second, phase-shifted PLL output at the same
	// frequency as `clk`) — a real-hardware timing-margin hypothesis
	// this project's own BACKGROUND LOAD test in SdramTest.sv raised
	// after two DIGITAL-LOGIC-side fixes (RASCAS_DELAY, PRECHARGE_DELAY)
	// both failed to resolve genuine concurrent-multi-port-contention
	// data corruption (see docs/hw-bringup.md): unlike those two, a
	// clock-phase/trace-delay problem would plausibly (a) never show in
	// simulation (behavioral SDRAM models don't model clock-to-out or
	// trace delay at all), (b) be completely unaffected by any digital
	// state-machine cycle-count parameter, and (c) get worse
	// specifically under heavier concurrent bus switching (more
	// simultaneous data-bus transitions from different ports = worse
	// real electrical setup/hold margin at the physical pins exactly
	// when it matters most).
	parameter SEPARATE_SDRAM_CLK = 0
)
(

	// interface to the MT48LC16M16 chip
	inout      [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,
	output            ready,      // high when init complete (MODE_NORMAL)

	// cpu/chipset interface
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz
	// clk_sdram: only used when SEPARATE_SDRAM_CLK=1 (see that
	// parameter's own comment) — left unconnected by every existing
	// consumer, matching the file's own established default-off pattern.
	input             clk_sdram,
	input       [1:0] prio_mode,	// 00=RR over all 4 ports, 01=video first, 10=CPU first, 11=video 75%

	input      [24:1] addr0,
	input             wrl0,
	input             wrh0,
	input      [15:0] din0,
	output     [15:0] dout0,
	input             req0,
	output reg        ack0 = 0,
	
	input      [24:1] addr1,
	input             wrl1,
	input             wrh1,
	input      [15:0] din1,
	output     [15:0] dout1,
	input             req1,
	output reg        ack1 = 0,
	
	input      [24:1] addr2,
	input             wrl2,
	input             wrh2,
	input      [15:0] din2,
	output     [15:0] dout2,
	input             req2,
	output reg        ack2 = 0,

	input      [24:1] addr3,
	input             wrl3,
	input             wrh3,
	input      [15:0] din3,
	output     [15:0] dout3,
	input             req3,
	output reg        ack3 = 0
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam BURST_LENGTH   = 3'd0; // 0=1, 1=2, 2=4, 3=8, 7=full page
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd3; // 3 for robust timing on real hardware
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

// Declared 4'd0 (not 3'd0): every STATE_* below derives from this one
// via addition, and Verilog's own width-inference for an unsized
// localparam takes the MAX of its operands' widths at each step — with
// this at only 3 bits, STATE_READY (which grows with RASCAS_DELAY, see
// that parameter's own comment) could silently truncate/wrap for any
// override large enough to push it past 7, even with `state` itself
// already widened to 4 bits below. Widening the root here propagates a
// 4-bit-minimum width through the whole derivation chain.
localparam STATE_IDLE  = 4'd0;             // state to check the requests
localparam STATE_START = STATE_IDLE+1'd1;  // state in which a new command is started
localparam STATE_CONT  = STATE_START+RASCAS_DELAY;
localparam STATE_READY = STATE_CONT+CAS_LATENCY+1'd1;
localparam STATE_LAST  = STATE_READY;      // last state in cycle

// Widened from [2:0] (0-7) to [3:0] (0-15): STATE_READY = STATE_CONT +
// CAS_LATENCY + 1 grows with RASCAS_DELAY (see that parameter's own
// comment) — the original 3-bit width silently overflowed/wrapped for
// any override large enough to push STATE_READY past 7, corrupting the
// whole state machine. 4 bits covers RASCAS_DELAY up to 10 at the
// current CAS_LATENCY=3, comfortably more headroom than any real
// tRCD-margin experiment should need.
reg  [3:0] state = 0;
reg [22:1] a;
reg [15:0] data;
reg        we;

// Forward declarations needed for ModelSim
localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;
reg [1:0] mode = MODE_RESET;
reg [12:0] reset = 13'h1fff;
reg  [1:0] ba = 0;
reg  [1:0] dqm;
reg        active = 0;
reg  [3:0] ram_req = 0;
reg  [1:0] next_port = 0;  // round-robin: 0-3
reg  [3:0] idle_wait_cnt = 0; // PRECHARGE_DELAY countdown — see that parameter's own comment

// Clock-domain crossing. This controller may run on a faster clock than
// its consumers (this project: 96MHz here vs. a 40MHz clk_sys — see
// docs/hw-bringup.md's own "SDRAM bandwidth" section). The toggle-style
// req/ack protocol is CDC-safe by construction (a single-bit toggle plus
// a payload the consumer holds stable from its toggle until ack): each
// reqN is brought into this domain through a 2-flop synchronizer, and
// the consumer side (rtl/sdram_req.sv) synchronizes ackN the same way.
// Always on — in a single-clock configuration the synchronizers just
// add two cycles of latency, which no consumer's correctness depends on.
reg [1:0] req0_s = 0, req1_s = 0, req2_s = 0, req3_s = 0;
always @(posedge clk) begin
	req0_s <= {req0_s[0], req0};
	req1_s <= {req1_s[0], req1};
	req2_s <= {req2_s[0], req2};
	req3_s <= {req3_s[0], req3};
end
wire req0_i = req0_s[1];
wire req1_i = req1_s[1];
wire req2_i = req2_s[1];
wire req3_i = req3_s[1];

// Per-port read-data registers, each latched only by its own port's
// completing transaction. The original single shared `dout` was only
// safe because a same-clock consumer sampled it exactly one cycle after
// its ack; with synchronizer delay on the consumer side, another port's
// transaction could complete and overwrite it first.
reg [15:0] dout0_r = 0, dout1_r = 0, dout2_r = 0, dout3_r = 0;
reg [3:0]  done_port = 0; // one-hot: which port's read data landed in `dout` last cycle
wire [3:0] wr = {wrl3|wrh3,wrl2|wrh2,wrl1|wrh1,wrl0|wrh0};

reg [15:0] dout;


assign dout0 = dout0_r;
assign dout1 = dout1_r;
assign dout2 = dout2_r;
assign dout3 = dout3_r;


// access manager
always @(posedge clk) begin
	reg [9:0] rfs_cnt;
	reg rfs, rfs2;
	
	rfs_cnt <= rfs_cnt + 1'd1;
	if (rfs_cnt == REFRESH_CYCLES) begin
		rfs <= 1;
		rfs_cnt <= 0;
	end

	if (rfs_cnt == (REFRESH_CYCLES >> 1)) rfs2 <= 1;
	
	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		if (idle_wait_cnt < PRECHARGE_DELAY) begin
			idle_wait_cnt <= idle_wait_cnt + 1'd1;
		end
		else if (rfs) begin
			rfs <= 0;
			rfs2 <= 0;
			rfs_cnt <= 0;
			we <= 0;
			dqm <= 2'b00;
			active <= 0;
			state <= STATE_START;
			idle_wait_cnt <= 0;
		end
		else begin : rr_arb
			// Priority-selectable arbitration via prio_mode[1:0]
			reg p0, p1, p2, p3;
			reg granted;
			// A port whose read data is still being copied (done_port, see
			// the STATE_READY block) has NOT had its ack toggled yet, so it
			// would otherwise look pending for exactly one more cycle and
			// be re-granted as a duplicate transaction — whose completion
			// toggles ack a second time and desynchronizes the handshake.
			p0 = (ack0 != req0_i) && !done_port[0];
			p1 = (ack1 != req1_i) && !done_port[1];
			p2 = (ack2 != req2_i) && !done_port[2];
			p3 = (ack3 != req3_i) && !done_port[3];
			granted = 0;

			case (prio_mode)
			2'd0: begin
				// MODE 0: round-robin over ALL FOUR ports. (Originally ports 0-2
				// round-robin with port 3 served only when the others were idle.
				// This project runs the real-time TX-tile/sprite fetch on port 3
				// — see docs/hw-bringup.md's port table — which needs a fair
				// share; the former port-3 consumer, OKI sample fetch, is
				// low-bandwidth enough to share port 1 with the Z80 instead.)
				begin : rr4
					integer k;
					reg [1:0] idx;
					for (k = 0; k < 4; k = k + 1) begin
						idx = next_port + k;
						if (!granted) begin
							case (idx)
								2'd0: if (p0) begin {ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1; next_port <= 2'd1; granted = 1; end
								2'd1: if (p1) begin {ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1; next_port <= 2'd2; granted = 1; end
								2'd2: if (p2) begin {ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1; next_port <= 2'd3; granted = 1; end
								default: if (p3) begin {ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1; next_port <= 2'd0; granted = 1; end
							endcase
						end
					end
				end
			end

			2'd1: begin
				// MODE 1: Video first — port 0 always wins, then RR 1-2, port 3 last
				if (p0) begin
					{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
					granted = 1;
				end
				else if (p1) begin
					{ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1;
					granted = 1;
				end
				else if (p2) begin
					{ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1;
					granted = 1;
				end
				else if (p3) begin
					{ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1;
					granted = 1;
				end
			end

			2'd2: begin
				// MODE 2: CPU first — ports 1,2 priority, then port 0, port 3 last
				if (p1) begin
					{ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1;
					granted = 1;
				end
				else if (p2) begin
					{ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1;
					granted = 1;
				end
				else if (p0) begin
					{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
					granted = 1;
				end
				else if (p3) begin
					{ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1;
					granted = 1;
				end
			end

			2'd3: begin
				// MODE 3: Video 75% — port 0 gets 3 of every 4 slots, others share the 4th
				if (next_port != 2'd2 && p0) begin
					// Slots 0,1,2 of 4: video priority
					{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
					next_port <= (next_port == 2'd2) ? 2'd0 : next_port + 2'd1;
					granted = 1;
				end
				else begin
					// Slot 3 of 4 (or video idle): RR among ports 1,2,3
					if (p1) begin
						{ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1;
						granted = 1;
					end
					else if (p2) begin
						{ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1;
						granted = 1;
					end
					else if (p3) begin
						{ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1;
						granted = 1;
					end
					else if (p0) begin
						// Even in slot 3, serve video if nothing else wants it
						{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
						granted = 1;
					end
					next_port <= 2'd0;  // reset counter
				end
			end
			endcase

			if (granted) begin
				active <= 1; rfs <= rfs2; state <= STATE_START;
				idle_wait_cnt <= 0;
			end
		end
	end

	// SDRAM_DQ is captured by exactly ONE register, `dout`, so the fitter
	// can pack it into the pad's own fast input register (the QSF's
	// FAST_INPUT_REGISTER assignment on SDRAM_DQ[*]) — the only way the
	// read-data window at 96MHz (10.4ns) is met. Capturing SDRAM_DQ
	// directly into the four per-port registers instead fanned the pad
	// out to four registers, at most one of which can live in the I/O
	// cell; the rest sampled through unconstrained routing, and real
	// hardware read visibly corrupted graphics/sample data at 96MHz. So
	// the per-port copy and its ack happen one cycle later, from `dout`.
	done_port <= 4'b0000;
	if(state == STATE_READY && ram_req) begin
		dout <= SDRAM_DQ;
		done_port <= ram_req;
		active <= 0;
		ram_req <= 0;
	end
	// Copy into the completing port's own register and mirror the
	// SYNCHRONIZED req (the value that was actually granted) into its ack
	// — see the CDC comment above. The consumer cannot observe this ack
	// for at least two of ITS clock cycles (its own synchronizer), long
	// after this copy has landed.
	if (done_port[0]) begin dout0_r <= dout; ack0 <= req0_i; end
	if (done_port[1]) begin dout1_r <= dout; ack1 <= req1_i; end
	if (done_port[2]) begin dout2_r <= dout; ack2 <= req2_i; end
	if (done_port[3]) begin dout3_r <= dout; ack3 <= req3_i; end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
	end
end


// initialization
always @(posedge clk) begin
	reg init_old=0;
	init_old <= init;

	if(init_old & ~init) reset <= 13'd4800; // ~100us at 48MHz (4800 * 8 clk = 38400 cycles)
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 13'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

assign ready = (mode == MODE_NORMAL) && (reset == 0);

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

// SDRAM state machines
reg [15:0] sdram_dq_out;
reg        sdram_dq_oe;
assign SDRAM_DQ = sdram_dq_oe ? sdram_dq_out : 16'hZZZZ;

always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? ba : 2'b00;

	sdram_dq_oe <= 1'b0;
	casex({active,we,mode,state})
		{2'bXX, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= active ? CMD_ACTIVE : CMD_AUTO_REFRESH;
		{2'b11, MODE_NORMAL, STATE_CONT }: begin {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE; sdram_dq_out <= data; sdram_dq_oe <= 1'b1; end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	if(mode == MODE_NORMAL) begin
		casex(state)
			STATE_START: SDRAM_A <= a[13:1];
			STATE_CONT:  SDRAM_A <= {dqm, 2'b10, a[22:14]};
		endcase
	end
	else if(mode == MODE_LDM && state == STATE_START) SDRAM_A <= MODE;
	else if(mode == MODE_PRE && state == STATE_START) SDRAM_A <= 13'b0010000000000;
	else SDRAM_A <= 0;
end

`ifdef SIMULATION
assign SDRAM_CLK = ~clk;
`else
// ddr_outclock: SEPARATE_SDRAM_CLK's own compile-time constant selects
// between `clk` (default, this file's original behavior) and
// `clk_sdram` (a separate, typically phase-shifted clock) — see that
// parameter's own comment. Never toggles at runtime (SEPARATE_SDRAM_CLK
// is a parameter, fixed at elaboration), so this is a synthesis-time
// net selection ahead of the DDR output cell's own clock input, not a
// runtime clock mux.
wire ddr_outclock = SEPARATE_SDRAM_CLK ? clk_sdram : clk;
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(ddr_outclock),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);
`endif

endmodule
