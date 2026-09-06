// Generic single-port synchronous-request wrapper around one of
// rtl/sdram.sv's four toggle-style req/ack ports. Hides the toggle
// protocol behind a simple pulse-in/pulse-out interface: assert `req`
// for one cycle with `addr`/`we`/`din` valid, then wait for `valid` to
// pulse with `dout` holding the read result (or, for a write, simply
// confirming the write landed — `dout` is meaningless for a write).
//
// See docs/hw-bringup.md for why every ROM region in this project's
// hardware bring-up work goes through SDRAM via one of these, rather
// than the $readmemh-loaded 0-latency arrays every sim-only core uses
// today.
module sdram_req
(
	input         clk,
	input         reset,

	// consumer side
	input  [24:1] addr,   // word address (byte address >> 1)
	input         we,     // 1=write, 0=read — sampled only when req is asserted
	input         wrl,    // low-byte write enable (we=1 only)
	input         wrh,    // high-byte write enable (we=1 only)
	input  [15:0] din,
	input         req,    // one-cycle pulse: start a new transaction
	output        busy,   // high from req until valid — caller must not issue req while busy
	output reg    valid,  // one-cycle pulse: dout (read) or write-complete (write)
	output [15:0] dout,

	// rtl/sdram.sv port side (one of its four addr/wr/din/dout/req/ack sets)
	output [24:1] sdram_addr,
	output        sdram_wrl,
	output        sdram_wrh,
	output [15:0] sdram_din,
	input  [15:0] sdram_dout,
	output reg    sdram_req,
	input         sdram_ack
);

	reg        pending;
	reg [24:1] addr_r;
	reg        we_r, wrl_r, wrh_r;
	reg [15:0] din_r;
	reg        req_prev;

	assign busy       = pending;
	assign sdram_addr = addr_r;
	assign sdram_wrl  = we_r & wrl_r;
	assign sdram_wrh  = we_r & wrh_r;
	assign sdram_din  = din_r;
	assign dout       = sdram_dout;

	always @(posedge clk) begin
		valid    <= 1'b0;
		req_prev <= req;
		if (reset) begin
			pending   <= 1'b0;
			sdram_req <= 1'b0;
			req_prev  <= 1'b0;
		// Rising-edge trigger, not level: a caller may legitimately hold
		// `req` high continuously across the whole transaction (as
		// rom_cache1.sv does, since it clears its own request the same
		// cycle it sees `valid`, one cycle after `pending` here already
		// dropped — a level check would misread that still-high tail as
		// a brand-new request and start a spurious duplicate fetch of the
		// stale address). A one-cycle pulse (sdram_arb.sv's own internal
		// usage) still triggers exactly once, so this is fully backward
		// compatible with a pulse-style caller.
		end else if (req && !req_prev && !pending) begin
			addr_r    <= addr;
			we_r      <= we;
			wrl_r     <= wrl;
			wrh_r     <= wrh;
			din_r     <= din;
			sdram_req <= ~sdram_req;
			pending   <= 1'b1;
		end else if (pending && (sdram_ack == sdram_req)) begin
			pending <= 1'b0;
			valid   <= 1'b1;
		end
	end

endmodule
