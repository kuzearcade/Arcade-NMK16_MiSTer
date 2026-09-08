// N-way round-robin arbiter multiplexing several logical ROM/RAM
// consumers onto one physical rtl/sdram.sv port (via one internal
// sdram_req.sv instance). See docs/hw-bringup.md — this is how e.g.
// BG-tile/TX-tile/sprite-tile fetch (or OKI0/OKI1 sample fetch) share a
// single physical SDRAM port without each needing its own.
//
// Unlike a standalone sdram_req.sv (whose req is a one-cycle pulse,
// captured the instant it arrives), a channel here may have to wait an
// arbitrary number of cycles for its turn while another channel is
// being serviced — so the caller must HOLD req high continuously
// (addr/we/wrl/wrh/din stable throughout) until i_valid pulses for that
// same channel, not just for one cycle. A channel that never asserts
// req never affects any other channel's latency beyond normal
// round-robin sharing.
module sdram_arb #(
	parameter N = 3,
	// 0: round-robin (default, every existing consumer). 1: fixed
	// priority, lowest channel index first — used by video_macross2.sv's
	// tile/sprite arbiter so the real-time BG/TX prefetch streams (which
	// only get one word of slack per fetch) are never queued behind the
	// sprite compositing pass, an FSM that can afford to wait.
	parameter FIXED_PRIO = 0
) (
	input  clk,
	input  reset,

	input  [24:1] i_addr  [0:N-1],
	input         i_we    [0:N-1],
	input         i_wrl   [0:N-1],
	input         i_wrh   [0:N-1],
	input  [15:0] i_din   [0:N-1],
	input         i_req   [0:N-1],
	output        i_busy  [0:N-1],
	output reg    i_valid [0:N-1],
	output reg [15:0] i_dout [0:N-1],

	output [24:1] sdram_addr,
	output        sdram_wrl,
	output        sdram_wrh,
	output [15:0] sdram_din,
	input  [15:0] sdram_dout,
	output        sdram_req,
	input         sdram_ack
);

	localparam SEL_W = (N <= 1) ? 1 : $clog2(N);

	reg [SEL_W-1:0] rr_ptr;   // round-robin scan start, advances on every grant
	reg [SEL_W-1:0] gnt_ch;   // which channel currently owns the in-flight request
	reg             gnt_active;
	// A channel that was just served is ignored until its req has been
	// seen LOW once. Every hold-req-until-valid caller (rom_cache1.sv,
	// tile_prefetch_byte.sv) drops req one cycle AFTER i_valid, and this
	// arbiter re-scans in exactly that cycle — without this mask it
	// re-granted the still-high req as a duplicate transaction, and when
	// the caller then raised req for a NEW address, the duplicate's
	// completion was delivered as that new request's data. Found on real
	// hardware as a silent Z80 (corrupted program-ROM bytes) the moment
	// its ROM fetch moved from a direct sdram_req.sv — whose rising-edge
	// trigger never had this hazard — onto an arbitrated channel; it had
	// also been silently doubling every video-tile fetch until then.
	reg [N-1:0]     hold_off;

	reg [24:1] addr_r;
	reg        we_r, wrl_r, wrh_r;
	reg [15:0] din_r;
	reg        u_req;

	wire        u_busy, u_valid;
	wire [15:0] u_dout;

	genvar g;
	generate
		for (g = 0; g < N; g = g + 1) begin : busy_tie
			assign i_busy[g] = gnt_active;
		end
	endgenerate

	sdram_req u_req_inst (
		.clk(clk), .reset(reset),
		.addr(addr_r), .we(we_r), .wrl(wrl_r), .wrh(wrh_r), .din(din_r),
		.req(u_req), .busy(u_busy), .valid(u_valid), .dout(u_dout),
		.sdram_addr(sdram_addr), .sdram_wrl(sdram_wrl), .sdram_wrh(sdram_wrh),
		.sdram_din(sdram_din), .sdram_dout(sdram_dout), .sdram_req(sdram_req), .sdram_ack(sdram_ack)
	);

	integer k;
	reg found;
	integer idx;
	always @(posedge clk) begin
		u_req <= 1'b0;
		for (k = 0; k < N; k = k + 1) i_valid[k] <= 1'b0;

		for (k = 0; k < N; k = k + 1) if (!i_req[k]) hold_off[k] <= 1'b0;

		if (reset) begin
			gnt_active <= 1'b0;
			rr_ptr     <= '0;
			hold_off   <= '0;
		end else if (!gnt_active) begin
			found = 1'b0;
			for (k = 0; k < N; k = k + 1) begin
				idx = FIXED_PRIO ? k : (rr_ptr + k) % N;
				if (!found && i_req[idx] && !hold_off[idx]) begin
					found      = 1'b1;
					addr_r     <= i_addr[idx];
					we_r       <= i_we[idx];
					wrl_r      <= i_wrl[idx];
					wrh_r      <= i_wrh[idx];
					din_r      <= i_din[idx];
					u_req      <= 1'b1;
					gnt_active <= 1'b1;
					gnt_ch     <= idx[SEL_W-1:0];
					rr_ptr     <= ((idx + 1) % N);
`ifdef SDRAM_ARB_DEBUG
					$display("[%0t] ARB grant idx=%0d addr=%06x we=%0d din=%04x", $time, idx, i_addr[idx], i_we[idx], i_din[idx]);
`endif
				end
			end
		end else if (u_valid) begin
			i_dout[gnt_ch]   <= u_dout;
			i_valid[gnt_ch]  <= 1'b1;
			gnt_active       <= 1'b0;
			hold_off[gnt_ch] <= 1'b1;
`ifdef SDRAM_ARB_DEBUG
			$display("[%0t] ARB complete ch=%0d dout=%04x", $time, gnt_ch, u_dout);
`endif
		end
	end

endmodule
