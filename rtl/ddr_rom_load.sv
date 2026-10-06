// DDR3 ROM loading ("fast loading") in front of the core's download logic.
//
// With `address="0x30000000"` on the .mra's <rom index="0">, Main_MiSTer
// assembles the ROM image straight into DDR3 at that address and only frames
// it with a download on index 0: ioctl_download rises with ioctl_addr = the
// image's length and no ioctl_wr at all, then falls. Sent the usual way, the
// image crosses the HPS bridge at about 1 MB/s (2 MB/s on a 16-bit hps_io);
// from DDR3 it costs a memory copy.
//
// This module sits between hps_io and the core:
//   * a streamed download (ioctl_wr seen) passes straight through, both ways
//     (the .mra without `address=` keeps working);
//   * a download on index 0 that ends with no write and a non-zero length is
//     a DDR3 load: the image is read back from DDR3 and replayed to the core
//     as the download it replaces -- the same index, addresses and data, one
//     write at a time, each at least GAP clocks after the last and never
//     while the core holds ioctl_wait (its loaders raise it the clock after a
//     write they cannot take another behind). The core sees one download,
//     from the first rise until the last replayed byte, so its reset and
//     settling logic span the replay;
//   * hps_io's later downloads (the <switches>, the hiscore config, the
//     .nvm) are held off with ioctl_wait until the replay is done; a write
//     that still arrives is kept and delivered first after it.
//
// DDR side: one 64-bit read at a time on clk_ddr, issued only while the
// framebuffer writer is idle (`hold`) and the bus is not busy (the savestate
// engine's protocol; that engine is idle during a download). One word is
// prefetched while the other is replayed. The sys side asks with a toggle
// and the DDR side answers with one; the data is stable from before the
// answer until the next question.
module ddr_rom_load #(
	parameter        DW       = 8,                 // hps_io data width: 8, or 16 (WIDE)
	parameter [28:0] DDR_BASE = 29'h0600_0000,     // 0x3000_0000 >> 3
	parameter        GAP      = 8                  // minimum clocks between replayed writes
) (
	input             clk,
	// from hps_io
	input             h_download,
	input      [15:0] h_index,
	input             h_wr,
	input      [26:0] h_addr,
	input    [DW-1:0] h_dout,
	output            h_wait,
	// to the core
	output            c_download,
	output     [15:0] c_index,
	output            c_wr,
	output     [26:0] c_addr,
	output   [DW-1:0] c_dout,
	input             c_wait,
	output            active,          // replaying from DDR3
	// DDR3 (clk_ddr)
	input             clk_ddr,
	input             ddr_busy,
	input             hold,            // another client owns the bus this cycle
	output            ddr_rd,
	output            ddr_pending,     // a read is waiting to issue or to return
	output     [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready
);
	localparam integer STEP = DW / 8;              // bytes per write
	localparam [26:0]  STEP27 = STEP[26:0];
	localparam [2:0]   LAST   = 3'd7 - (STEP[2:0] - 3'd1);   // a word's last lane

	// ------------------------------------------------------------------
	// Detection
	// ------------------------------------------------------------------
	wire       h_dl0 = h_download && (h_index == 16'd0);
	reg        h_dl0_d = 1'b0;
	reg        wr_seen = 1'b0;
	reg [26:0] len = 27'd0;
	always @(posedge clk) begin
		h_dl0_d <= h_dl0;
		if (h_dl0 && !h_dl0_d) wr_seen <= 1'b0;
		if (h_dl0 && h_wr)     wr_seen <= 1'b1;
		if (h_dl0)             len <= h_addr;
	end
	wire ddr_end = h_dl0_d && !h_dl0 && !wr_seen && (len != 27'd0);

	// ------------------------------------------------------------------
	// Replay (clk)
	// ------------------------------------------------------------------
	reg        act = 1'b0;
	reg [26:0] pos;                  // next byte address to replay
	reg [23:0] rq_idx;               // next word to ask for
	reg        rq_out = 1'b0;        // a question is outstanding
	reg        req_tog = 1'b0;
	reg [23:0] req_idx;
	wire       ack_tog;
	reg  [2:0] ack_sync = 3'b000;
	always @(posedge clk) ack_sync <= {ack_sync[1:0], ack_tog};
	wire       ack_now = ack_sync[2] ^ ack_sync[1];
	reg [63:0] d_rdata;              // clk_ddr's answer, stable while read here
	reg [63:0] cur, nxt;
	reg        cur_v = 1'b0, nxt_v = 1'b0;
	reg  [7:0] gap = 8'd0;
	reg        r_wr = 1'b0;
	reg [26:0] r_addr;
	reg [DW-1:0] r_dout;
	// a hps_io write that arrives during the replay, kept for after it
	reg        pend = 1'b0;
	reg [26:0] p_addr;
	reg [DW-1:0] p_dout;
	reg        p_go = 1'b0;          // delivering it this clock

	wire [2:0] lane    = pos[2:0];
	wire       last_ln = (lane == LAST);
	wire       done    = (pos >= len);
	wire [DW-1:0] lane_data = cur[{lane, 3'b000} +: DW];

	// the write this clock, and whether it uses up cur
	wire emit    = act && !done && cur_v && gap == 8'd0 && !c_wait && !r_wr;
	wire consume = emit && last_ln;
	always @(posedge clk) begin
		r_wr <= 1'b0;
		p_go <= 1'b0;
		if (gap != 8'd0) gap <= gap - 8'd1;
		if (ddr_end) begin
			act <= 1'b1; pos <= 27'd0; rq_idx <= 24'd0; rq_out <= 1'b0;
			cur_v <= 1'b0; nxt_v <= 1'b0; gap <= 8'd0;
		end else if (act) begin
			if (done) act <= 1'b0;
			if (emit) begin
				r_wr <= 1'b1; r_addr <= pos; r_dout <= lane_data;
				pos <= pos + STEP27; gap <= GAP[7:0];
			end
			// the two-word queue: cur is its head; a pop when cur is used
			// up, a push when an answer arrives
			if (ack_now) rq_out <= 1'b0;
			case ({consume, ack_now})
				2'b10: begin cur <= nxt; cur_v <= nxt_v; nxt_v <= 1'b0; end
				2'b01: if (!cur_v) begin cur <= d_rdata; cur_v <= 1'b1; end
				       else        begin nxt <= d_rdata; nxt_v <= 1'b1; end
				2'b11: if (nxt_v) begin cur <= nxt; nxt <= d_rdata; end
				       else       begin cur <= d_rdata; end
				default: ;
			endcase
			// ask for the next word: one question at a time, never more
			// words than the queue holds
			if (!rq_out && !ack_now && !(cur_v && nxt_v) && ({rq_idx, 3'b000} < len)) begin
				rq_out <= 1'b1; req_idx <= rq_idx; req_tog <= ~req_tog; rq_idx <= rq_idx + 24'd1;
			end
		end
		// hps_io's own write during the replay: keep it
		if (act && h_wr && !pend) begin pend <= 1'b1; p_addr <= h_addr; p_dout <= h_dout; end
		if (!act && pend && !c_wait) begin pend <= 1'b0; p_go <= 1'b1; end
	end
	assign active = act;

	// ------------------------------------------------------------------
	// The core's view
	// ------------------------------------------------------------------
	wire in_rp = act | ddr_end;
	assign c_download = h_download | in_rp;
	assign c_index    = in_rp ? 16'd0 : h_index;
	assign c_wr       = act ? r_wr : (p_go | (h_wr & !pend));
	assign c_addr     = act ? r_addr : (p_go ? p_addr : h_addr);
	assign c_dout     = act ? r_dout : (p_go ? p_dout : h_dout);
	assign h_wait     = in_rp | pend | p_go | c_wait;

	// ------------------------------------------------------------------
	// DDR side (clk_ddr)
	// ------------------------------------------------------------------
	reg  [1:0] req_sync = 2'b00;
	reg        req_seen = 1'b0;
	reg        ack_r = 1'b0;
	reg        d_rd = 1'b0, d_wait = 1'b0;
	reg [28:0] d_addr;
	assign ack_tog = ack_r;
	always @(posedge clk_ddr) begin
		req_sync <= {req_sync[0], req_tog};
		if (d_wait) begin
			if (ddr_dout_ready) begin d_rdata <= ddr_dout; d_wait <= 1'b0; ack_r <= ~ack_r; end
		end else if (d_rd) begin
			if (!hold && !ddr_busy) begin d_rd <= 1'b0; d_wait <= 1'b1; end   // accepted this cycle
		end else if (req_sync[1] != req_seen) begin
			req_seen <= req_sync[1];
			d_addr <= DDR_BASE + {5'd0, req_idx};
			d_rd <= 1'b1;
		end
	end
	assign ddr_rd   = d_rd & !hold;
	assign ddr_pending = d_rd | d_wait;
	assign ddr_addr = d_addr;
endmodule
