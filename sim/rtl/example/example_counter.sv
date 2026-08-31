// Trivial smoke-test DUT for the Verilator harness plumbing — NOT part of
// the NMK16 core itself. Its only job is to prove tb_example.cpp, the
// Makefile, and NmkTraceWriter/Crc32 work end to end before any real DUT
// (fx68k wrapper, TLCS-90 core, etc.) is wired in during Tier 1+.
//
// Behavior: a free-running address counter with synchronous read data
// data = addr ^ last_written, and a write-strobe input that the testbench
// toggles to exercise both the "B ... r ..." and "B ... w ..." trace paths.
// last_written actually gates read_data (rather than being a dead input)
// so Verilator's UNUSEDSIGNAL lint has something real to check.
module example_counter (
	input  logic        clk,
	input  logic        reset,
	input  logic        write_en,
	input  logic [7:0]  write_data,
	output logic [7:0]  addr,
	output logic [7:0]  read_data,
	output logic        write_ack
);

	logic [7:0] last_written;

	always_ff @(posedge clk) begin
		if (reset) begin
			addr         <= 8'h00;
			write_ack    <= 1'b0;
			last_written <= 8'hA5;
		end else begin
			write_ack <= write_en;
			addr      <= addr + 8'h01;
			if (write_en)
				last_written <= write_data;
		end
	end

	assign read_data = addr ^ last_written;

endmodule
