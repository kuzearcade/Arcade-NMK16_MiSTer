// Savestate support (2026-09-18): park a running T80 (Z80) at an instruction
// boundary without touching the vendored CPU, and get every register out.
//
// Mechanism (proven in sim/rtl/ss_z80 before it was wired into a core):
//   1. park_req pulls NMI low. The CPU finishes its instruction, pushes PC
//      and jumps to 0x0066. From that fetch on -- and only from then, so the
//      game's own code at 0x0066.. is never overlaid while it might be
//      executing there -- a 93-byte monitor is served from a bus overlay
//      (sel_mon / mon_data override the Z80 read-data mux).
//   2. The monitor pushes AF/BC/DE/HL/IX/IY, the alternate set and I/R on
//      the game's own stack (so they land in the sound-RAM image), records
//      IFF2 (LD A,I -> P/V) on the stack too, stores SP in the state
//      register at 0x00D0/D1, writes 1 to DONE (0xD2) and spins on RESUME
//      (0xD3). The interrupt mode is not readable by software: it is
//      tracked here by snooping the M1 fetches for ED 46/4E/66/6E (IM 0),
//      56/76 (IM 1) and 5E/7E (IM 2), and handed to the monitor at 0xD4.
//   3. On RESUME the monitor reloads SP from 0xD0, re-selects IM from 0xD4,
//      pops everything, re-arms EI/DI from the saved IFF2 and RETNs.
//
// State registers on the word bus: 0 = SP, 1 = {14'b0, IM}.
module ss_z80_park (
	input             clk,
	input             cen,          // the Z80's own clock enable
	input             reset_n,      // the Z80's RESET_n (low: no CPU to park, `parked` reads 1)

	input             park_req,
	output            parked,
	input             resume,

	// Z80 bus (T80 names)
	input      [15:0] a,
	input             m1_n, mreq_n, iorq_n, rd_n, wr_n,
	input             wait_n,
	input       [7:0] dout,         // CPU -> bus
	input       [7:0] din_bus,      // what the bus would return (for the IM snoop)

	output            nmi_park,     // AND its inverse into the core's NMI_n
	output            sel_mon,
	output reg  [7:0] mon_data,

	input             ss_sel,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output reg [15:0] ss_rdata
);
	localparam [15:0] MON_START = 16'h0066, MON_END = 16'h00C3;   // 93 bytes: 0x66..0xC2

	wire fetch = ~m1_n & ~mreq_n & ~rd_n & wait_n;   // opcode byte on the bus
	wire mem_wr = ~mreq_n & ~wr_n;
	wire mem_rd = ~mreq_n & ~rd_n;

	// interrupt-mode snoop (one sample per M1 cycle)
	reg       fetch_d = 1'b0;
	reg [7:0] prev_op = 8'h00;
	reg [1:0] im = 2'd0;
	always @(posedge clk) begin
		if (!reset_n) begin
			fetch_d <= 1'b0; prev_op <= 8'h00; im <= 2'd0;
		end else if (cen) begin
			fetch_d <= fetch;
			if (fetch & ~fetch_d) begin
				if (prev_op == 8'hED) begin
					case (din_bus)
						8'h46, 8'h4E, 8'h66, 8'h6E: im <= 2'd0;
						8'h56, 8'h76:               im <= 2'd1;
						8'h5E, 8'h7E:               im <= 2'd2;
						default: ;
					endcase
				end
				prev_op <= din_bus;
			end
		end
		if (ss_wr & ss_sel) im <= ss_wdata[1:0];
	end

	// overlay: armed by the NMI entry fetch, held until the RETN has been
	// fetched. The overlay is switched off only once the RETN's second
	// M1 cycle has ENDED (mreq_n high again): T80 latches DI late in the
	// cycle, and turning the overlay off on the first cen that saw the
	// fetch handed it the game's own byte at 0xC2 instead of 0x45 (the
	// 68000 side had the identical defect, see ss_m68k_park.sv).
	reg mon_active = 1'b0;
	reg done_r = 1'b0;
	reg left = 1'b0;      // the RETN has been fetched: overlay off, CPU back in the game
	reg retn_seen = 1'b0; // the RETN's second-byte M1 cycle is in progress
	wire entry = fetch & (a == MON_START) & ~left;
	always @(posedge clk) begin
		if (!reset_n | ~park_req) begin
			mon_active <= 1'b0; done_r <= 1'b0; left <= 1'b0; retn_seen <= 1'b0;
		end else if (cen) begin
			if (entry) mon_active <= 1'b1;
			if (mem_wr & mon_active & (a == 16'h00D2)) done_r <= dout[0];
			if (resume & fetch & mon_active & (a == MON_END - 16'd1)) retn_seen <= 1'b1;
			if (retn_seen & mreq_n) begin retn_seen <= 1'b0; mon_active <= 1'b0; done_r <= 1'b0; left <= 1'b1; end
		end
	end
	assign nmi_park = park_req & ~mon_active & ~done_r & ~left;
	assign parked   = ~reset_n | done_r;
	wire   in_mon   = park_req & (mon_active | entry);
	wire   sel_code = in_mon & (a >= MON_START) & (a < MON_END);
	wire   sel_regs = in_mon & (a[15:3] == 13'h001A);   // 0x00D0-0x00D7
	assign sel_mon  = mem_rd & (sel_code | sel_regs);

	reg [15:0] sp_reg = 16'h0000;
	always @(posedge clk) begin
		if (ss_wr & ~ss_sel) sp_reg <= ss_wdata;
		else if (cen & mem_wr & mon_active) begin
			if (a == 16'h00D0) sp_reg[7:0]  <= dout;
			if (a == 16'h00D1) sp_reg[15:8] <= dout;
		end
	end
	always @(*) ss_rdata = ss_sel ? {14'd0, im} : sp_reg;

	// the monitor (sim/rtl/ss_z80/monz80_d0.bin, verified against T80)
	reg [7:0] mon;
	always @(*) begin
		case (a[7:0])
			8'h66: mon = 8'hf5; 8'h67: mon = 8'hc5; 8'h68: mon = 8'hd5; 8'h69: mon = 8'he5;   // push af,bc,de,hl
			8'h6a: mon = 8'hdd; 8'h6b: mon = 8'he5; 8'h6c: mon = 8'hfd; 8'h6d: mon = 8'he5;   // push ix,iy
			8'h6e: mon = 8'h08; 8'h6f: mon = 8'hd9;                                           // ex af,af' / exx
			8'h70: mon = 8'hf5; 8'h71: mon = 8'hc5; 8'h72: mon = 8'hd5; 8'h73: mon = 8'he5;   // push af',bc',de',hl'
			8'h74: mon = 8'hd9; 8'h75: mon = 8'h08;                                           // exx / ex af,af'
			8'h76: mon = 8'hed; 8'h77: mon = 8'h57; 8'h78: mon = 8'hf5;                       // ld a,i ; push af (P/V = IFF2)
			8'h79: mon = 8'hed; 8'h7a: mon = 8'h5f; 8'h7b: mon = 8'hf5;                       // ld a,r ; push af
			8'h7c: mon = 8'hed; 8'h7d: mon = 8'h73; 8'h7e: mon = 8'hd0; 8'h7f: mon = 8'h00;   // ld (00D0h),sp
			8'h80: mon = 8'h3e; 8'h81: mon = 8'h01; 8'h82: mon = 8'h32; 8'h83: mon = 8'hd2; 8'h84: mon = 8'h00; // ld a,1 ; ld (00D2h),a
			8'h85: mon = 8'h3a; 8'h86: mon = 8'hd3; 8'h87: mon = 8'h00;                       // loop: ld a,(00D3h)
			8'h88: mon = 8'hb7; 8'h89: mon = 8'h28; 8'h8a: mon = 8'hfa;                       // or a ; jr z,loop
			8'h8b: mon = 8'hed; 8'h8c: mon = 8'h7b; 8'h8d: mon = 8'hd0; 8'h8e: mon = 8'h00;   // ld sp,(00D0h)
			8'h8f: mon = 8'hf1; 8'h90: mon = 8'hed; 8'h91: mon = 8'h4f;                       // pop af ; ld r,a
			8'h92: mon = 8'hf1; 8'h93: mon = 8'hed; 8'h94: mon = 8'h47;                       // pop af ; ld i,a
			8'h95: mon = 8'hea; 8'h96: mon = 8'h9b; 8'h97: mon = 8'h00;                       // jp pe,009Bh (IFF2 was set)
			8'h98: mon = 8'hf3; 8'h99: mon = 8'h18; 8'h9a: mon = 8'h01;                       // di ; jr +1
			8'h9b: mon = 8'hfb;                                                               // ei
			8'h9c: mon = 8'h3a; 8'h9d: mon = 8'hd4; 8'h9e: mon = 8'h00;                       // ld a,(00D4h)
			8'h9f: mon = 8'hfe; 8'ha0: mon = 8'h01; 8'ha1: mon = 8'h28; 8'ha2: mon = 8'h08;   // cp 1 ; jr z,im1
			8'ha3: mon = 8'hfe; 8'ha4: mon = 8'h02; 8'ha5: mon = 8'h28; 8'ha6: mon = 8'h08;   // cp 2 ; jr z,im2
			8'ha7: mon = 8'hed; 8'ha8: mon = 8'h46; 8'ha9: mon = 8'h18; 8'haa: mon = 8'h06;   // im 0 ; jr pops
			8'hab: mon = 8'hed; 8'hac: mon = 8'h56; 8'had: mon = 8'h18; 8'hae: mon = 8'h02;   // im1: im 1 ; jr pops
			8'haf: mon = 8'hed; 8'hb0: mon = 8'h5e;                                           // im2: im 2
			8'hb1: mon = 8'h08; 8'hb2: mon = 8'hd9;                                           // pops: ex af,af' / exx
			8'hb3: mon = 8'he1; 8'hb4: mon = 8'hd1; 8'hb5: mon = 8'hc1; 8'hb6: mon = 8'hf1;   // pop hl',de',bc',af'
			8'hb7: mon = 8'hd9; 8'hb8: mon = 8'h08;                                           // exx / ex af,af'
			8'hb9: mon = 8'hfd; 8'hba: mon = 8'he1; 8'hbb: mon = 8'hdd; 8'hbc: mon = 8'he1;   // pop iy,ix
			8'hbd: mon = 8'he1; 8'hbe: mon = 8'hd1; 8'hbf: mon = 8'hc1; 8'hc0: mon = 8'hf1;   // pop hl,de,bc,af
			8'hc1: mon = 8'hed; 8'hc2: mon = 8'h45;                                           // retn
			default: mon = 8'h00;   // nop
		endcase
	end
	always @(*) begin
		if (sel_code) mon_data = mon;
		else case (a[2:0])
			3'd0: mon_data = sp_reg[7:0];
			3'd1: mon_data = sp_reg[15:8];
			3'd2: mon_data = {7'd0, done_r};
			3'd3: mon_data = {7'd0, resume};
			3'd4: mon_data = {6'd0, im};
			default: mon_data = 8'h00;
		endcase
	end
endmodule
