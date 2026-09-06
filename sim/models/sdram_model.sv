// Minimal behavioral MT48LC16M16A2-style SDR SDRAM model, simulation-only.
// Implements just enough of the real JEDEC command protocol (ACTIVE,
// READ, WRITE, PRECHARGE, AUTO REFRESH, LOAD MODE REGISTER) for
// rtl/sdram.sv's own controller to work against in Verilator — no real
// timing-violation checking (tRC/tRAS/etc.), no refresh-loss modeling,
// just correct read-after-write data and the same CAS-latency-relative
// output timing a real chip presents, which is what rtl/sdram.sv's own
// fixed-cycle-count state machine assumes.
//
// Address space: {BA[1:0], ROW[12:0], COL[8:0]} = 24 bits = 16M words
// (32MB byte-addressable), matching rtl/sdram.sv's own addr[24:1] reach
// exactly.
module sdram_model
(
	input             SDRAM_CLK,
	input      [12:0] SDRAM_A,
	input      [1:0]  SDRAM_BA,
	inout      [15:0] SDRAM_DQ,
	input             SDRAM_DQML,
	input             SDRAM_DQMH,
	input             SDRAM_nCS,
	input             SDRAM_nCAS,
	input             SDRAM_nRAS,
	input             SDRAM_nWE,
	input             SDRAM_CKE
);

	localparam CAS_LATENCY = 3;

	// 16M x 16-bit = 32MB, flat, matches {ba,row,col} = 24 bits exactly.
	reg [15:0] mem [0:16*1024*1024-1];

	reg [12:0] open_row [0:3];

	// Command decode (active-low {nRAS,nCAS,nWE}), standard JEDEC SDR encoding.
	wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
	localparam CMD_ACTIVE = 3'b011;
	localparam CMD_READ   = 3'b101;
	localparam CMD_WRITE  = 3'b100;

	// CAS-latency-delayed read pipeline: on a READ command, schedule the
	// output CAS_LATENCY cycles later, same convention rtl/sdram.sv itself
	// assumes for real hardware.
	reg [15:0] rd_pipe_data [0:CAS_LATENCY-1];
	reg        rd_pipe_val  [0:CAS_LATENCY-1];
	reg        dq_oe;
	reg [15:0] dq_out;
	integer i;

	assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

	always @(posedge SDRAM_CLK) begin
		dq_oe <= 1'b0;

		// shift the read pipeline
		for (i = 0; i < CAS_LATENCY-1; i = i + 1) begin
			rd_pipe_data[i] <= rd_pipe_data[i+1];
			rd_pipe_val[i]  <= rd_pipe_val[i+1];
		end
		rd_pipe_val[CAS_LATENCY-1] <= 1'b0;

		if (rd_pipe_val[0]) begin
			dq_out <= rd_pipe_data[0];
			dq_oe  <= 1'b1;
		end

		if (SDRAM_CKE && !SDRAM_nCS) begin
			case (cmd)
				CMD_ACTIVE: begin
					open_row[SDRAM_BA] <= SDRAM_A;
`ifdef SDRAM_MODEL_DEBUG
					$display("[%0t] MODEL ACTIVE ba=%0d row=%04x", $time, SDRAM_BA, SDRAM_A);
`endif
				end
				CMD_READ: begin
					rd_pipe_val[CAS_LATENCY-1]  <= 1'b1;
					rd_pipe_data[CAS_LATENCY-1] <= mem[{SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0]}];
`ifdef SDRAM_MODEL_DEBUG
					$display("[%0t] MODEL READ ba=%0d row=%04x col=%03x -> data=%04x", $time, SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0], mem[{SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0]}]);
`endif
				end
				CMD_WRITE: begin
					if (!SDRAM_DQML) mem[{SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0]}][7:0]  <= SDRAM_DQ[7:0];
					if (!SDRAM_DQMH) mem[{SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0]}][15:8] <= SDRAM_DQ[15:8];
`ifdef SDRAM_MODEL_DEBUG
					$display("[%0t] MODEL WRITE ba=%0d row=%04x col=%03x <- data=%04x", $time, SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[8:0], SDRAM_DQ);
`endif
				end
				default: ; // PRECHARGE/AUTO_REFRESH/LOAD_MODE/NOP — no-op for this functional model
			endcase
		end
	end

endmodule
