// Savestate prototype for the Z80 (T80): the testbench owns memory, the NMI
// monitor overlay and the park handshake; the CPU is the vendored netlist.
module top (
	input         clk,
	input         reset_n,
	input         cen,
	input         int_n,
	input         nmi_n,
	output [15:0] a,
	output  [7:0] dout,
	input   [7:0] din,
	output        m1_n, mreq_n, iorq_n, rd_n, wr_n
);
	T80s cpu (.RESET_n(reset_n), .CLK(clk), .CEN(cen), .WAIT_n(1'b1), .INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1), .OUT0(1'b0),
	          .DI(din), .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(), .HALT_n(), .BUSAK_n(), .A(a), .DO(dout));
endmodule
