// TLCS-90 CPU core — from-scratch implementation, no prior open-source RTL
// exists for this ISA (confirmed by web search during project planning).
// Used as NMK004 (the NMK16 sound MCU, TMP90C840AF) and later reused as the
// NMK-110/113/215 protection MCU (Tier 4). Built and verified against MAME's
// `cpu/tlcs90/tlcs90.cpp` reference model — see docs/tier2-tlcs90.md for the
// full ISA reference, memory map, and verification plan this was derived
// from (register model, addressing-mode encodings, exact per-opcode flag
// formulas, interrupt model, peripheral register map).
//
// Architecture: decode() in the reference model fully parses one
// instruction (opcode + all extra bytes) before any execution happens.
// This core mirrors that: FETCH_OP -> DECODE (resolves op/modes from the
// opcode byte) -> zero or more extra-byte fetch states (mode1's byte(s)
// first, then mode2's) -> optional memory READ for whichever operand(s)
// are memory-typed -> single-cycle EXECUTE -> optional memory WRITE (or a
// dedicated PUSH/POP/CALL/RET sequence for stack-touching instructions).
//
// Bus protocol matches this project's established convention (see
// bjtwin_core.sv): reads are combinational (mem_rd + addr valid one cycle,
// din reflecting mem[addr] that same cycle, no wait states) — every read
// therefore takes exactly one extra cycle to *issue* the address and one
// more to *capture* the data, which is why the FSM below has separate
// "issue" and "wait/capture" states for each byte read.
//
// SCOPE OF THIS MILESTONE (documented, not hidden): the base (single
// opcode byte) instruction table — NOP/HALT/DI/EI/EX(register-only: DE,HL
// and AF,AF')/EXX/DAA/RCF/SCF/CCF/CPL/NEG/DJNZ(both forms)/JP/JR(cc)/CALL/
// RET/RETI/LD/PUSH/POP/ADD-family/INC/DEC/INCX/DECX/INCW/DECW/rotate-
// shift/BIT/SET/RES — plus all six "(gg)"/"(mn)"/"($FF00+n)" prefixed
// opcode groups (0xe0-0xe6, 0xe3, 0xe7, 0xe8-0xee, 0xeb, 0xef) that extend
// register-indirect and full-16-bit-direct/short-address addressing to
// every register, plus the `(ix+d)`/`(iy+d)`/`(sp+d)`/`(HL+A)` indexed
// groups (0xf0-0xf7) and the register-to-register group (0xf8-0xfe) —
// which turned out to be where plain `ADD A,r`-style register-register
// forms and a second `RET cc` encoding actually live, not anything
// implemented earlier; found only by tracing a real divergence back to
// its actual opcode rather than assuming which group it belonged to.
// This now covers real firmware execution all the way to the point where
// the NMK004 boot sequence legitimately blocks polling `($FB00)` for a
// byte only the real 68000 host would ever write (see
// docs/tier2-tlcs90.md's "Third verification result").
//
// Still deferred: block transfer (LDI*/CPI* family and RET cc's sibling
// forms, all only valid when the 0xf8-0xfe group's own opcode byte is
// exactly 0xfe — see the level-2 decode's PFX_G8 branch), RLD/RRD, LDAR,
// CALLR, MUL/DIV, SWI, `EX (gg)/(mn)/($FF00+n)/(ix+d)/(iy+d)/(HL+A),rr`
// (the memory-operand forms of EX — register-only EX is implemented),
// the TSET/LDA dead opcode space MAME's own reference model can't execute
// either, IX/IY bank extension via BX/BY (addresses through IX/IY are
// treated as plain 16-bit — exactly correct at boot, since the boot ROM
// zeroes both bank registers before doing anything else), and interrupt
// dispatch beyond a bare NMI input stub (peripheral-driven IRQs need the
// not-yet-built peripheral module first).
//
// The wide-register-to-register `ADD HL,rr` flag special-case documented
// in docs/tier2-tlcs90.md (only S/Z/V get *skipped*, and only for plain
// ADD, not ADC) IS reachable here — via the 0xf8-0xfe group's `ADD HL,gg`
// form (mode2==R16) — and is implemented as such in the OP_ADD/OP_ADC
// execute block below; every other 16-bit arithmetic addressing-mode
// combination, `ADC HL,gg` included, still recomputes S/Z/V fully.
module tlcs90 (
	input        clk,
	input        reset,       // async, active high

	input  [7:0] din,
	output reg [7:0] dout,
	output reg [15:0] addr,
	output reg   mem_rd,
	output reg   mem_wr,

	// Present for future use, not yet wired to any interrupt-dispatch
	// logic — see scope note above. A peripheral module (timers/ports/
	// INTEL/INTEH) providing INT0-INTTX and SWI is future work; this core
	// is validated standalone first per the project's methodology.
	input        nmi,

	// debug: pulses dbg_valid for one cycle at the start of each new
	// instruction with that instruction's own PC — the same point in time
	// MAME's `trace` debugger command reports from, directly diffable
	// against a captured disassembly oracle trace.
	output reg [15:0] dbg_pc,
	output reg        dbg_valid,
	output             dbg_halt
);

	// ------------------------------------------------------------------
	// Registers
	// ------------------------------------------------------------------
	reg [15:0] bc, de, hl, ix, iy, sp, pc;
	reg [15:0] bc2, de2, hl2;
	reg [7:0]  a, f;
	reg [7:0]  a2, f2;

	// Flag bit positions — NOT Z80-standard, see docs/tier2-tlcs90.md.
	localparam CF=0, NF=1, PF=2, XCF=3, HF=4, IFB=5, ZF=6, SF=7;

	reg halt_r;
	reg after_ei;
	assign dbg_halt = halt_r;

	// ------------------------------------------------------------------
	// Register-pair / register select codes (match the reference exactly)
	// ------------------------------------------------------------------
	localparam R8_B=0, R8_C=1, R8_D=2, R8_E=3, R8_H=4, R8_L=5, R8_A=6;
	localparam R16_BC=0, R16_DE=1, R16_HL=2, R16_IX=4, R16_IY=5, R16_SP=6, R16_AF=7, R16_AF2=8;

	function automatic [15:0] r16_read(input [3:0] sel);
		case (sel)
			R16_BC:  r16_read = bc;
			R16_DE:  r16_read = de;
			R16_HL:  r16_read = hl;
			R16_IX:  r16_read = ix;
			R16_IY:  r16_read = iy;
			R16_SP:  r16_read = sp;
			R16_AF:  r16_read = {a, f};
			R16_AF2: r16_read = {a2, (f2 & ~(8'd1 << IFB)) | (f & (8'd1 << IFB))}; // shared IF quirk, see docs
			default: r16_read = 16'h0000;
		endcase
	endfunction

	function automatic [7:0] r8_read(input [2:0] sel);
		case (sel)
			R8_A: r8_read = a;
			R8_B: r8_read = bc[15:8];
			R8_C: r8_read = bc[7:0];
			R8_D: r8_read = de[15:8];
			R8_E: r8_read = de[7:0];
			R8_H: r8_read = hl[15:8];
			R8_L: r8_read = hl[7:0];
			default: r8_read = 8'h00;
		endcase
	endfunction

	// PUSH/POP register-field remap: encoded slot 6 ("SP") means AF instead.
	function automatic [3:0] q16(input [3:0] sel);
		q16 = (sel == R16_SP) ? R16_AF : sel;
	endfunction

	// ------------------------------------------------------------------
	// Addressing-mode encoding for the two operand slots
	// ------------------------------------------------------------------
	localparam
		M_NONE = 0, M_BIT8 = 1, M_CC = 2, M_I8 = 3, M_D8 = 4,
		M_R8 = 5, M_I16 = 6, M_R16 = 7,
		M_MI16 = 8, // memory, direct 16-bit address (covers the $FF00+n short form too)
		M_MR16 = 9; // memory, indirect via a register pair ("(gg)" in the prefixed opcode groups)

	// Prefix-group kind, resolved from the opcode byte when it isn't part
	// of the base table (see the two-level decode below and
	// docs/tier2-tlcs90.md's addressing-mode table). SRC groups put the
	// external (gg/mn/ff) operand in the instruction's *source* position
	// (e.g. `LD r,(gg)`); DST groups put it in the *destination* position
	// (e.g. `LD (gg),r`) — except the JP/CALL forms living in the DST
	// opcode space, which use the external operand as a jump target, not a
	// destination (handled as a special case in the level-2 decode).
	// IXD groups ((ix+d)/(iy+d)/(sp+d) — same encoding trick the reference
	// uses: base register code = R16_IX + (opcode - group_base), and since
	// R16_IX=4, R16_IY=5, that arithmetic naturally lands on R16_SP=6 for
	// the third opcode in each group too, so (sp+d) comes along for free)
	// and HLA groups ((HL+A)) resolve their external operand's *address*
	// up front, the same way the MN/FF groups already resolve pfx_addr —
	// see the level-2 decode below, which needs no changes at all for
	// these four new prefix kinds beyond `pfx_is_src`.
	localparam
		PFX_NONE=0, PFX_GG_SRC=1, PFX_MN_SRC=2, PFX_FF_SRC=3,
		PFX_GG_DST=4, PFX_MN_DST=5, PFX_FF_DST=6,
		PFX_IXD_SRC=7, PFX_IXD_DST=8, PFX_HLA_SRC=9, PFX_HLA_DST=10,
		// 0xf8-0xfe: register-to-register forms (`g` = an 8-bit *or*
		// 16-bit register embedded in b0, reinterpreted per selector-byte
		// case — no memory operand at all, so this doesn't fit the
		// SRC/DST "external operand" framework above; handled as its own
		// level-2 branch). This is also where the *second* RET cc
		// encoding lives (only valid when b0==0xfe) and, at the very
		// bottom of decode(), where the block-transfer family
		// (LDI/LDIR/.../CPDR, also only when b0==0xfe) would live if
		// implemented — still deferred, see module header.
		PFX_G8=11;

	// ------------------------------------------------------------------
	// Semantic operations implemented this milestone
	// ------------------------------------------------------------------
	localparam
		OP_NOP=0, OP_EX=1, OP_EXX=2, OP_LD=3, OP_PUSH=4, OP_POP=5,
		OP_JP=6, OP_JR=7, OP_CALL=8, OP_RET=9, OP_RETI=10, OP_HALT=11,
		OP_DI=12, OP_EI=13, OP_DAA=14, OP_CPL=15, OP_NEG=16,
		OP_RCF=17, OP_SCF=18, OP_CCF=19, OP_BIT=20, OP_SET=21, OP_RES=22,
		OP_INC=23, OP_DEC=24, OP_INCX=25, OP_DECX=26, OP_INCW=27, OP_DECW=28,
		OP_ADD=29, OP_ADC=30, OP_SUB=31, OP_SBC=32, OP_AND=33, OP_XOR=34,
		OP_OR=35, OP_CP=36, OP_RLC=37, OP_RRC=38, OP_RL=39, OP_RR=40,
		OP_SLA=41, OP_SRA=42, OP_SLL=43, OP_SRL=44, OP_DJNZ=45,
		OP_UNKNOWN=63;

	// ------------------------------------------------------------------
	// Decode table: purely combinational function of the opcode byte,
	// driven directly by `din` while it's known-valid (during S_DECODE —
	// see the FSM below). Produces the semantic op, operand modes, any
	// register/CC/BIT8 value already embedded in the opcode byte, and how
	// many extra bytes each operand slot needs — mode1's byte(s) first,
	// then mode2's (matches every instruction in this scope).
	// ------------------------------------------------------------------
	reg [5:0] d_op;
	reg       d_wide;
	reg [3:0] d_mode1, d_mode2;
	reg [3:0] d_r1e, d_r2e;
	reg [1:0] d_m1bytes, d_m2bytes;
	reg [3:0] d_pfx;
	reg [3:0] d_gg;

	always @(*) begin
		d_op = OP_UNKNOWN; d_wide = 1'b0;
		d_mode1 = M_NONE; d_mode2 = M_NONE;
		d_r1e = 4'd0; d_r2e = 4'd0;
		d_m1bytes = 2'd0; d_m2bytes = 2'd0;
		d_pfx = PFX_NONE; d_gg = 4'd0;

		casez (din)
			8'h00: d_op = OP_NOP;
			8'h01: d_op = OP_HALT;
			8'h02: d_op = OP_DI;
			8'h03: d_op = OP_EI;

			8'h07: begin d_op = OP_INCX; d_mode1 = M_MI16; d_m1bytes = 2'd1; end
			8'h08: begin d_op = OP_EX; d_mode1 = M_R16; d_r1e = R16_DE; d_mode2 = M_R16; d_r2e = R16_HL; end
			8'h09: begin d_op = OP_EX; d_mode1 = M_R16; d_r1e = R16_AF; d_mode2 = M_R16; d_r2e = R16_AF2; end
			8'h0a: d_op = OP_EXX;
			8'h0b: d_op = OP_DAA;
			8'h0c: d_op = OP_RCF;
			8'h0d: d_op = OP_SCF;
			8'h0e: d_op = OP_CCF;
			8'h0f: begin d_op = OP_DECX; d_mode1 = M_MI16; d_m1bytes = 2'd1; end
			8'h10: d_op = OP_CPL;
			8'h11: d_op = OP_NEG;

			8'h18: begin d_op = OP_DJNZ; d_mode1 = M_D8; d_m1bytes = 2'd1; end
			8'h19: begin d_op = OP_DJNZ; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = R16_BC; d_mode2 = M_D8; d_m2bytes = 2'd1; end

			8'h1a: begin d_op = OP_JP; d_mode1 = M_CC; d_r1e = 4'h8; d_mode2 = M_I16; d_m2bytes = 2'd2; end
			8'h1c: begin d_op = OP_CALL; d_mode1 = M_CC; d_r1e = 4'h8; d_mode2 = M_I16; d_m2bytes = 2'd2; end
			8'h1e: begin d_op = OP_RET; d_mode1 = M_CC; d_r1e = 4'h8; end
			8'h1f: d_op = OP_RETI;

			8'h20,8'h21,8'h22,8'h23,8'h24,8'h25,8'h26: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = R8_A; d_mode2 = M_R8; d_r2e = din[3:0]; end
			8'h27: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = R8_A; d_mode2 = M_MI16; d_m2bytes = 2'd1; end
			8'h28,8'h29,8'h2a,8'h2b,8'h2c,8'h2d,8'h2e: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = 4'(din - 8'h28); d_mode2 = M_R8; d_r2e = R8_A; end
			8'h2f: begin d_op = OP_LD; d_mode1 = M_MI16; d_m1bytes = 2'd1; d_mode2 = M_R8; d_r2e = R8_A; end

			8'h30,8'h31,8'h32,8'h33,8'h34,8'h35,8'h36: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = 4'(din - 8'h30); d_mode2 = M_I8; d_m2bytes = 2'd1; end
			8'h37: begin d_op = OP_LD; d_mode1 = M_MI16; d_m1bytes = 2'd1; d_mode2 = M_I8; d_m2bytes = 2'd1; end
			8'h38,8'h39,8'h3a,8'h3c,8'h3d,8'h3e: begin d_op = OP_LD; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = 4'(din - 8'h38); d_mode2 = M_I16; d_m2bytes = 2'd2; end

			8'h40,8'h41,8'h42,8'h44,8'h45,8'h46: begin d_op = OP_LD; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = R16_HL; d_mode2 = M_R16; d_r2e = 4'(din - 8'h40); end
			8'h47: begin d_op = OP_LD; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = R16_HL; d_mode2 = M_MI16; d_m2bytes = 2'd1; end
			8'h48,8'h49,8'h4a,8'h4c,8'h4d,8'h4e: begin d_op = OP_LD; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = 4'(din - 8'h48); d_mode2 = M_R16; d_r2e = R16_HL; end
			8'h4f: begin d_op = OP_LD; d_wide = 1'b1; d_mode1 = M_MI16; d_m1bytes = 2'd1; d_mode2 = M_R16; d_r2e = R16_HL; end

			8'h50,8'h51,8'h52,8'h54,8'h55,8'h56: begin d_op = OP_PUSH; d_mode1 = M_R16; d_r1e = q16(4'(din - 8'h50)); end
			8'h58,8'h59,8'h5a,8'h5c,8'h5d,8'h5e: begin d_op = OP_POP; d_mode1 = M_R16; d_r1e = q16(4'(din - 8'h58)); end

			8'h60,8'h61,8'h62,8'h63,8'h64,8'h65,8'h66,8'h67: begin
				d_op = OP_ADD + {2'b0,din[2:0]}; d_mode1 = M_R8; d_r1e = R8_A; d_mode2 = M_MI16; d_m2bytes = 2'd1; end
			8'h68,8'h69,8'h6a,8'h6b,8'h6c,8'h6d,8'h6e,8'h6f: begin
				d_op = OP_ADD + {2'b0,din[2:0]}; d_mode1 = M_R8; d_r1e = R8_A; d_mode2 = M_I8; d_m2bytes = 2'd1; end
			8'h70,8'h71,8'h72,8'h73,8'h74,8'h75,8'h76,8'h77: begin
				d_op = OP_ADD + {2'b0,din[2:0]}; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = R16_HL; d_mode2 = M_MI16; d_m2bytes = 2'd1; end
			8'h78,8'h79,8'h7a,8'h7b,8'h7c,8'h7d,8'h7e,8'h7f: begin
				d_op = OP_ADD + {2'b0,din[2:0]}; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = R16_HL; d_mode2 = M_I16; d_m2bytes = 2'd2; end

			8'h80,8'h81,8'h82,8'h83,8'h84,8'h85,8'h86: begin d_op = OP_INC; d_mode1 = M_R8; d_r1e = 4'(din - 8'h80); end
			8'h87: begin d_op = OP_INC; d_mode1 = M_MI16; d_m1bytes = 2'd1; end
			8'h88,8'h89,8'h8a,8'h8b,8'h8c,8'h8d,8'h8e: begin d_op = OP_DEC; d_mode1 = M_R8; d_r1e = 4'(din - 8'h88); end
			8'h8f: begin d_op = OP_DEC; d_mode1 = M_MI16; d_m1bytes = 2'd1; end

			8'h90,8'h91,8'h92,8'h94,8'h95,8'h96: begin d_op = OP_INC; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = 4'(din - 8'h90); end
			8'h97: begin d_op = OP_INCW; d_wide = 1'b1; d_mode1 = M_MI16; d_m1bytes = 2'd1; end
			8'h98,8'h99,8'h9a,8'h9c,8'h9d,8'h9e: begin d_op = OP_DEC; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = 4'(din - 8'h98); end
			8'h9f: begin d_op = OP_DECW; d_wide = 1'b1; d_mode1 = M_MI16; d_m1bytes = 2'd1; end

			8'ha0,8'ha1,8'ha2,8'ha3,8'ha4,8'ha5,8'ha6,8'ha7: begin
				d_op = OP_RLC + {3'b0,din[2:0]}; d_mode1 = M_R8; d_r1e = R8_A; end
			8'ha8,8'ha9,8'haa,8'hab,8'hac,8'had,8'hae,8'haf: begin
				d_op = OP_BIT; d_mode1 = M_BIT8; d_r1e = din[3:0]; d_mode2 = M_MI16; d_m2bytes = 2'd1; end
			8'hb0,8'hb1,8'hb2,8'hb3,8'hb4,8'hb5,8'hb6,8'hb7: begin
				d_op = OP_RES; d_mode1 = M_BIT8; d_r1e = din[3:0]; d_mode2 = M_MI16; d_m2bytes = 2'd1; end
			8'hb8,8'hb9,8'hba,8'hbb,8'hbc,8'hbd,8'hbe,8'hbf: begin
				d_op = OP_SET; d_mode1 = M_BIT8; d_r1e = din[3:0]; d_mode2 = M_MI16; d_m2bytes = 2'd1; end

			8'hc?: begin d_op = OP_JR; d_mode1 = M_CC; d_r1e = din[3:0]; d_mode2 = M_D8; d_m2bytes = 2'd1; end

			// Prefixed opcode groups — see docs/tier2-tlcs90.md's addressing-
			// mode table. These don't resolve op/mode1/mode2 here (that needs
			// the operation-selector byte, which hasn't been fetched yet);
			// this level only recognizes the group and, for the gg-indirect
			// groups, the embedded register code. Level-2 decode (the
			// `always @(*)` block below keyed on `pfx` and the selector
			// byte) does the rest, once the FSM has fetched what it needs.
			8'he0,8'he1,8'he2,8'he4,8'he5,8'he6: begin d_pfx = PFX_GG_SRC; d_gg = 4'(din - 8'he0); end
			8'he3: d_pfx = PFX_MN_SRC;
			8'he7: d_pfx = PFX_FF_SRC;
			8'he8,8'he9,8'hea,8'hec,8'hed,8'hee: begin d_pfx = PFX_GG_DST; d_gg = 4'(din - 8'he8); end
			8'heb: d_pfx = PFX_MN_DST;
			8'hef: d_pfx = PFX_FF_DST;

			8'hf0,8'hf1,8'hf2: begin d_pfx = PFX_IXD_SRC; d_gg = R16_IX + 4'(din - 8'hf0); end
			8'hf3: d_pfx = PFX_HLA_SRC;
			8'hf4,8'hf5,8'hf6: begin d_pfx = PFX_IXD_DST; d_gg = R16_IX + 4'(din - 8'hf4); end
			8'hf7: d_pfx = PFX_HLA_DST;
			8'hf8,8'hf9,8'hfa,8'hfb,8'hfc,8'hfd,8'hfe: begin d_pfx = PFX_G8; d_gg = 4'(din - 8'hf8); end

			default: d_op = OP_UNKNOWN;
		endcase
	end

	// ------------------------------------------------------------------
	// Condition codes (Test(), exact copy of the reference's table)
	// ------------------------------------------------------------------
	function automatic test_cc(input [3:0] c, input [7:0] fl);
		reg s, v;
		begin
			s = fl[SF]; v = fl[PF];
			case (c)
				4'h0: test_cc = 1'b0;
				4'h1: test_cc = (s && !v) || (!s && v);
				4'h2: test_cc = fl[ZF] || (s && !v) || (!s && v);
				4'h3: test_cc = fl[CF] || fl[ZF];
				4'h4: test_cc = v;
				4'h5: test_cc = s;
				4'h6: test_cc = fl[ZF];
				4'h7: test_cc = fl[CF];
				4'h8: test_cc = 1'b1;
				4'h9: test_cc = (s && v) || (!s && !v);
				4'ha: test_cc = !(fl[ZF] || (s && !v) || (!s && v));
				4'hb: test_cc = !fl[CF] && !fl[ZF];
				4'hc: test_cc = !v;
				4'hd: test_cc = !s;
				4'he: test_cc = !fl[ZF];
				4'hf: test_cc = !fl[CF];
			endcase
		end
	endfunction

	// ------------------------------------------------------------------
	// Flag-formula helper functions, exact copies of the reference's
	// SZ/SZP/SZ_BIT/SZHV_inc/SZHV_dec table-init formulas, computed
	// on-demand instead of precomputed.
	// ------------------------------------------------------------------
	function automatic [7:0] sz8(input [7:0] v);
		sz8 = (v != 8'h00) ? (v & 8'h80) : (8'd1 << ZF);
	endfunction
	function automatic [7:0] sz_bit8(input [7:0] v);
		sz_bit8 = (v != 8'h00) ? (v & 8'h80) : ((8'd1 << ZF) | (8'd1 << PF));
	endfunction
	function automatic [7:0] szp8(input [7:0] v);
		szp8 = sz8(v) | (^v ? 8'h00 : (8'd1 << PF));
	endfunction
	function automatic [7:0] szhv_inc8(input [7:0] v);
		szhv_inc8 = sz8(v) | (v == 8'h80 ? (8'd1 << PF) : 8'h00) | (v[3:0] == 4'h0 ? (8'd1 << HF) : 8'h00);
	endfunction
	function automatic [7:0] szhv_dec8(input [7:0] v);
		szhv_dec8 = sz8(v) | (8'd1 << NF) | (v == 8'h7f ? (8'd1 << PF) : 8'h00) | (v[3:0] == 4'hf ? (8'd1 << HF) : 8'h00);
	endfunction

	// ------------------------------------------------------------------
	// Level-2 decode for the prefixed opcode groups: once the FSM has
	// fetched the operation-selector byte (the reference's "b1"/"b3" — the
	// byte after the gg register / after the mn address / after the ff
	// address, per group), this resolves it into the same op/mode/register
	// fields the base table produces directly, so the rest of the FSM
	// (S_PRE_READ1 onward) doesn't need to know or care whether an
	// instruction came from the base table or a prefix group.
	//
	// `pfx` (latched from d_pfx) selects between the two selector-byte
	// layouts: SRC groups (GG_SRC/MN_SRC/FF_SRC — `LD r,(x)` style, the
	// external operand is always a *source*) share one layout; DST groups
	// (GG_DST/MN_DST/FF_DST — `LD (x),r` style) share another, except the
	// JP/CALL forms living in DST opcode space, which use the external
	// operand as a jump target (mode2) rather than a destination.
	//
	// FF_SRC and FF_DST only support a strict subset of what GG/MN support
	// (per the reference: FF_SRC is LD/rotate only, FF_DST is LD/ADD-family
	// only — no INC/DEC/BIT/SET/RES/JP/CALL for either). This table doesn't
	// separately restrict those cases for FF — a selector byte outside
	// FF's real subset simply can't appear in any valid compiled TLCS-90
	// program (the reference's own decode() has no case for it there
	// either, so no real firmware ever emits it), so sharing one table
	// across all three SRC (or DST) prefixes is safe in practice.
	reg [5:0] d2_op;
	reg       d2_wide;
	reg [3:0] d2_mode1, d2_mode2;
	reg [3:0] d2_r1e, d2_r2e;
	reg [1:0] d2_mem_slot;  // 1 or 2: which slot (mode1/mode2) holds the external (gg/mn/ff) operand
	reg       d2_needs_i8;  // one more immediate byte follows the selector (DST-side ADD-family/LD-immediate/CP)

	reg [3:0] pfx;
	reg [3:0] gg;
	reg [15:0] pfx_addr;

	wire pfx_is_src = (pfx == PFX_GG_SRC) || (pfx == PFX_MN_SRC) || (pfx == PFX_FF_SRC) ||
	                  (pfx == PFX_IXD_SRC) || (pfx == PFX_HLA_SRC);
	// IXD/HLA groups resolve their external operand's address up front
	// into pfx_addr (same as MN/FF already do), so they fall under the
	// M_MI16 (already-resolved-address) side here, not M_MR16 (only the
	// gg groups defer resolution to read/execute time via a live register
	// read).
	wire [3:0] mem_mode = (pfx == PFX_GG_SRC || pfx == PFX_GG_DST) ? M_MR16 : M_MI16;
	// JP/CALL's external "operand" is a jump target, not a location to
	// dereference: for the gg-register groups that's the register's own
	// value (M_R16, e.g. `JP (HL)` means "jump to HL", not "read the word
	// at HL"); for every other group (mn/ff/ixd/hla) pfx_addr already IS
	// the resolved target address (a literal, M_I16), computed the same
	// way whether it'll end up read as a jump target here or dereferenced
	// as a memory address by every other op in that same prefix group.
	wire [3:0] jp_target_mode = (pfx == PFX_GG_DST) ? M_R16 : M_I16;

	always @(*) begin
		d2_op = OP_UNKNOWN; d2_wide = 1'b0;
		d2_mode1 = M_NONE; d2_mode2 = M_NONE;
		d2_r1e = 4'd0; d2_r2e = 4'd0;
		d2_mem_slot = 2'd2; d2_needs_i8 = 1'b0;

		if (pfx == PFX_G8) begin
			// Register-to-register forms: `gg` (from the b0 embedding, see
			// level-1 decode above) is a plain register-select code here —
			// R8 or R16 depending on the case, never a memory address —
			// filled into whichever slot d2_mem_slot picks by the same
			// S_PFX_SEL logic the other prefix groups already use (see the
			// PFX_G8 addition to that fill condition).
			casez (din)
				8'h30,8'h31,8'h32,8'h33,8'h34,8'h35,8'h36: begin
					d2_op = OP_LD; d2_mode1 = M_R8; d2_r1e = 4'(din - 8'h30); d2_mode2 = M_R8; d2_mem_slot = 2'd2; end
				8'h38,8'h39,8'h3a,8'h3c,8'h3d,8'h3e: begin
					d2_op = OP_LD; d2_wide = 1'b1; d2_mode1 = M_R16; d2_r1e = 4'(din - 8'h38); d2_mode2 = M_R16; d2_mem_slot = 2'd2; end
				8'h60,8'h61,8'h62,8'h63,8'h64,8'h65,8'h66,8'h67: begin
					d2_op = OP_ADD + {2'b0,din[2:0]}; d2_mode1 = M_R8; d2_r1e = R8_A; d2_mode2 = M_R8; d2_mem_slot = 2'd2; end
				8'h68,8'h69,8'h6a,8'h6b,8'h6c,8'h6d,8'h6e,8'h6f: begin
					d2_op = OP_ADD + {2'b0,din[2:0]}; d2_mode1 = M_R8; d2_mode2 = M_I8; d2_mem_slot = 2'd1; d2_needs_i8 = 1'b1; end
				8'h70,8'h71,8'h72,8'h73,8'h74,8'h75,8'h76,8'h77: begin
					d2_op = OP_ADD + {2'b0,din[2:0]}; d2_wide = 1'b1; d2_mode1 = M_R16; d2_r1e = R16_HL; d2_mode2 = M_R16; d2_mem_slot = 2'd2; end
				8'ha0,8'ha1,8'ha2,8'ha3,8'ha4,8'ha5,8'ha6,8'ha7: begin
					d2_op = OP_RLC + {3'b0,din[2:0]}; d2_mode1 = M_R8; d2_mem_slot = 2'd1; end
				8'ha8,8'ha9,8'haa,8'hab,8'hac,8'had,8'hae,8'haf: begin
					d2_op = OP_BIT; d2_mode1 = M_BIT8; d2_r1e = din[3:0]; d2_mode2 = M_R8; d2_mem_slot = 2'd2; end
				8'hb0,8'hb1,8'hb2,8'hb3,8'hb4,8'hb5,8'hb6,8'hb7: begin
					d2_op = OP_RES; d2_mode1 = M_BIT8; d2_r1e = din[3:0]; d2_mode2 = M_R8; d2_mem_slot = 2'd2; end
				8'hb8,8'hb9,8'hba,8'hbb,8'hbc,8'hbd,8'hbe,8'hbf: begin
					d2_op = OP_SET; d2_mode1 = M_BIT8; d2_r1e = din[3:0]; d2_mode2 = M_R8; d2_mem_slot = 2'd2; end
				// RET cc's *second* encoding — only a valid instruction when
				// b0==0xfe (i.e. gg==R16_SP==6, the same equivalence the
				// reference's own `if (b0==0xfe)` guard reduces to here,
				// since b0-0xf8 and gg are the same value). No external
				// operand at all (mode2 stays M_NONE, d2_mem_slot unused).
				8'hd0,8'hd1,8'hd2,8'hd3,8'hd4,8'hd5,8'hd6,8'hd7,
				8'hd8,8'hd9,8'hda,8'hdb,8'hdc,8'hdd,8'hde,8'hdf: begin
					if (gg == R16_SP) begin d2_op = OP_RET; d2_mode1 = M_CC; d2_r1e = din[3:0]; end
					else d2_op = OP_UNKNOWN;
				end
				default: d2_op = OP_UNKNOWN;
			endcase
		end else if (pfx_is_src) begin
			casez (din)
				8'h28,8'h29,8'h2a,8'h2b,8'h2c,8'h2d,8'h2e: begin
					d2_op = OP_LD; d2_mode1 = M_R8; d2_r1e = 4'(din - 8'h28); d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'h48,8'h49,8'h4a,8'h4c,8'h4d,8'h4e: begin
					d2_op = OP_LD; d2_wide = 1'b1; d2_mode1 = M_R16; d2_r1e = 4'(din - 8'h48); d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'h60,8'h61,8'h62,8'h63,8'h64,8'h65,8'h66,8'h67: begin
					d2_op = OP_ADD + {2'b0,din[2:0]}; d2_mode1 = M_R8; d2_r1e = R8_A; d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'h70,8'h71,8'h72,8'h73,8'h74,8'h75,8'h76,8'h77: begin
					d2_op = OP_ADD + {2'b0,din[2:0]}; d2_wide = 1'b1; d2_mode1 = M_R16; d2_r1e = R16_HL; d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'h87: begin d2_op = OP_INC; d2_mode1 = mem_mode; d2_mem_slot = 2'd1; end
				8'h8f: begin d2_op = OP_DEC; d2_mode1 = mem_mode; d2_mem_slot = 2'd1; end
				8'h97: begin d2_op = OP_INCW; d2_wide = 1'b1; d2_mode1 = mem_mode; d2_mem_slot = 2'd1; end
				8'h9f: begin d2_op = OP_DECW; d2_wide = 1'b1; d2_mode1 = mem_mode; d2_mem_slot = 2'd1; end
				8'ha0,8'ha1,8'ha2,8'ha3,8'ha4,8'ha5,8'ha6,8'ha7: begin
					d2_op = OP_RLC + {3'b0,din[2:0]}; d2_mode1 = mem_mode; d2_mem_slot = 2'd1; end
				8'ha8,8'ha9,8'haa,8'hab,8'hac,8'had,8'hae,8'haf: begin
					d2_op = OP_BIT; d2_mode1 = M_BIT8; d2_r1e = din[3:0]; d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'hb0,8'hb1,8'hb2,8'hb3,8'hb4,8'hb5,8'hb6,8'hb7: begin
					d2_op = OP_RES; d2_mode1 = M_BIT8; d2_r1e = din[3:0]; d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'hb8,8'hb9,8'hba,8'hbb,8'hbc,8'hbd,8'hbe,8'hbf: begin
					d2_op = OP_SET; d2_mode1 = M_BIT8; d2_r1e = din[3:0]; d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				default: d2_op = OP_UNKNOWN;
			endcase
		end else begin
			casez (din)
				8'h20,8'h21,8'h22,8'h23,8'h24,8'h25,8'h26: begin
					d2_op = OP_LD; d2_mode1 = mem_mode; d2_mode2 = M_R8; d2_r2e = din[3:0]; d2_mem_slot = 2'd1; end
				8'h37: begin d2_op = OP_LD; d2_mode1 = mem_mode; d2_mode2 = M_I8; d2_mem_slot = 2'd1; d2_needs_i8 = 1'b1; end
				8'h40,8'h41,8'h42,8'h44,8'h45,8'h46: begin
					d2_op = OP_LD; d2_wide = 1'b1; d2_mode1 = mem_mode; d2_mode2 = M_R16; d2_r2e = din[3:0]; d2_mem_slot = 2'd1; end
				8'h68,8'h69,8'h6a,8'h6b,8'h6c,8'h6d,8'h6e: begin
					d2_op = OP_ADD + {2'b0,din[2:0]}; d2_mode1 = mem_mode; d2_mode2 = M_I8; d2_mem_slot = 2'd1; d2_needs_i8 = 1'b1; end
				8'h6f: begin d2_op = OP_CP; d2_mode1 = mem_mode; d2_mode2 = M_I8; d2_mem_slot = 2'd1; d2_needs_i8 = 1'b1; end
				8'hc0,8'hc1,8'hc2,8'hc3,8'hc4,8'hc5,8'hc6,8'hc7,
				8'hc8,8'hc9,8'hca,8'hcb,8'hcc,8'hcd,8'hce,8'hcf: begin
					d2_op = OP_JP; d2_mode1 = M_CC; d2_r1e = din[3:0];
					d2_mode2 = jp_target_mode; d2_mem_slot = 2'd2; end
				8'hd0,8'hd1,8'hd2,8'hd3,8'hd4,8'hd5,8'hd6,8'hd7,
				8'hd8,8'hd9,8'hda,8'hdb,8'hdc,8'hdd,8'hde,8'hdf: begin
					d2_op = OP_CALL; d2_mode1 = M_CC; d2_r1e = din[3:0];
					d2_mode2 = jp_target_mode; d2_mem_slot = 2'd2; end
				default: d2_op = OP_UNKNOWN;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// FSM
	// ------------------------------------------------------------------
	localparam
		S_FETCH_OP = 0, S_DECODE = 1,
		S_M1_BYTE  = 2, S_M2_BYTE1 = 3, S_M2_BYTE2 = 4,
		S_PRE_READ1 = 5, S_READ1_LO = 6, S_READ1_HI = 7,
		S_PRE_READ2 = 8, S_READ2_LO = 9, S_READ2_HI = 10,
		S_EXECUTE  = 11,
		// single-byte memory writes (LD dest, INC/DEC/rotate dest, SET/RES)
		// are issued directly from S_EXECUTE and need no dedicated state —
		// the write signals stay valid for exactly the one cycle the
		// wrapper's synchronous-write memory needs, then S_FETCH_OP takes
		// over. Only the wide (2-byte) memory writeback (INCW/DECW) and the
		// stack sequences below need extra states.
		S_WRITE1_HI = 12,
		S_PUSH_HI  = 13,
		S_POP_LO   = 14, S_POP_HI = 15,
		// prefixed-opcode-group front end (see the level-2 decode above):
		// fetch whatever bytes the group needs (gg groups need only the
		// selector byte; mn groups need a 16-bit address then the selector;
		// ff groups need an address byte then the selector; ixd groups need
		// a displacement byte then the selector; hla groups need only the
		// selector, same as gg), resolve via level-2 decode, then rejoin
		// the common path at S_PRE_READ1.
		S_PFX_SEL     = 16,
		S_PFX_ADDR    = 17,
		S_PFX_ADDR_LO = 18, S_PFX_ADDR_HI = 19,
		S_PFX_I8      = 20,
		S_PFX_DISP    = 21;

	reg [4:0] state;
	reg [5:0] op;
	reg       wide;
	reg [3:0] mode1, mode2;
	reg [15:0] r1, r2;      // resolved register-select code / literal / short-address value / gg-code / mn-mode1-address-slot
	reg [15:0] val1, val2;  // operand values once read/resolved
	reg [1:0] m2bytes_left;
	reg [7:0] byte_lo;      // scratch for assembling a 2-byte little-endian value
	reg [15:0] wb_val;      // computed result awaiting writeback
	reg [15:0] push_val;
	reg [1:0]  pop_dest;    // 0=into r1 register (POP opcode), 1=into PC (RET), 2=into AF then chain to PC (RETI)

	// Effective bus address for a memory-mode operand: M_MI16 already
	// holds the resolved address directly in r1/r2 (short-address, direct
	// 16-bit, or the prefix-group's resolved mn/ff address); M_MR16 holds
	// a register-pair *code* instead, resolved through the register file
	// (IX/IY bank extension via BX/BY not yet implemented — see module
	// header — so this is a plain 16-bit register read, matching the
	// documented simplification already in place for the base table).
	wire [15:0] eff1 = (mode1 == M_MR16) ? r16_read(r1[3:0]) : r1;
	wire [15:0] eff2 = (mode2 == M_MR16) ? r16_read(r2[3:0]) : r2;

	function automatic mode_needs_read(input [3:0] m);
		mode_needs_read = (m == M_MI16) || (m == M_MR16);
	endfunction
	function automatic op_reads_m1(input [5:0] o);
		case (o)
			OP_LD, OP_JP, OP_JR, OP_CALL, OP_RET, OP_PUSH, OP_POP,
			OP_DJNZ, OP_BIT, OP_SET, OP_RES, OP_EX, OP_EXX, OP_NOP,
			OP_HALT, OP_DI, OP_EI, OP_RETI: op_reads_m1 = 1'b0;
			default: op_reads_m1 = 1'b1;
		endcase
	endfunction
	function automatic op_writes_m1_mem(input [5:0] o);
		// only relevant when mode1==M_MI16; register-mode1 writeback is
		// always handled directly in S_EXECUTE regardless of this table
		case (o)
			OP_INC, OP_DEC, OP_INCX, OP_DECX, OP_INCW, OP_DECW: op_writes_m1_mem = 1'b1;
			default: op_writes_m1_mem = 1'b0;
		endcase
	endfunction

	// Resolved register/immediate value for a non-memory mode (used once
	// we've established the operand doesn't need a bus read). This used to
	// be a `resolve_direct(m, rsel)` function wrapping a case over
	// r8_read()/r16_read() — found, via direct simulation comparison, to
	// silently return the WRONG value (0x0000 instead of the register's
	// real content) specifically when called from inside the ternary RHS
	// of a non-blocking assignment (`val1 <= cond ? resolve_direct(...) :
	// r1;`) — real, reproducible, confirmed by bypassing it with the exact
	// same logic inlined at the call site (which fixed it) while a
	// separately-exposed direct `r16_read()` debug signal, sampled the
	// same cycle, showed the *correct* value the whole time. Root cause
	// not pinned down further (looks like a Verilator quirk around
	// composing one `function automatic`'s case-dispatch return value
	// through another inside that specific expression position, not
	// anything wrong with r8_read()/r16_read() themselves) — the two call
	// sites below just inline the same three-way selection directly
	// instead, which measurably works, rather than chasing the simulator
	// bug further.

	always @(posedge clk) begin
		mem_rd <= 1'b0;
		mem_wr <= 1'b0;
		dbg_valid <= 1'b0;

		if (reset) begin
			state <= S_FETCH_OP;
			pc <= 16'h0000;
			f <= 8'h00;
			halt_r <= 1'b0;
			after_ei <= 1'b0;
		end else begin
			case (state)
				// ------------------------------------------------------
				S_FETCH_OP: begin
					if (op != OP_EI && after_ei) begin
						f[IFB] <= 1'b1;
						after_ei <= 1'b0;
					end
					if (halt_r) begin
						op <= OP_NOP; mode1 <= M_NONE; mode2 <= M_NONE;
						state <= S_EXECUTE;
					end else begin
						dbg_pc <= pc;
						dbg_valid <= 1'b1;
						addr <= pc;
						mem_rd <= 1'b1;
						pc <= pc + 16'd1;
						state <= S_DECODE;
					end
				end

				// din == the opcode byte just fetched; d_* (combinational,
				// driven directly by din) are valid now.
				S_DECODE: begin
					if (d_pfx == PFX_NONE) begin
						op <= d_op; wide <= d_wide;
						mode1 <= d_mode1; mode2 <= d_mode2;
						r1 <= {12'h0, d_r1e};
						r2 <= {12'h0, d_r2e};
						m2bytes_left <= d_m2bytes;
						if (d_m1bytes == 2'd1) begin
							addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
							state <= S_M1_BYTE;
						end else if (d_m2bytes != 2'd0) begin
							addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
							state <= S_M2_BYTE1;
						end else begin
							state <= S_PRE_READ1;
						end
					end else begin
						pfx <= d_pfx; gg <= d_gg;
						addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
						// HLA groups need no more bytes than the selector
						// (like GG), but their address doesn't depend on any
						// fetched byte, so it's safe to resolve right now.
						if (d_pfx == PFX_HLA_SRC || d_pfx == PFX_HLA_DST)
							pfx_addr <= hl + {{8{a[7]}}, a};
						case (d_pfx)
							PFX_FF_SRC, PFX_FF_DST:   state <= S_PFX_ADDR;
							PFX_MN_SRC, PFX_MN_DST:   state <= S_PFX_ADDR_LO;
							PFX_IXD_SRC, PFX_IXD_DST: state <= S_PFX_DISP;
							default:                  state <= S_PFX_SEL; // GG_SRC/GG_DST/HLA_SRC/HLA_DST: only the selector byte remains
						endcase
					end
				end

				S_M1_BYTE: begin
					r1 <= (mode1 == M_MI16) ? {8'hFF, din} : {8'h00, din};
					if (m2bytes_left != 2'd0) begin
						addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
						state <= S_M2_BYTE1;
					end else begin
						state <= S_PRE_READ1;
					end
				end

				S_M2_BYTE1: begin
					if (m2bytes_left == 2'd2) begin
						byte_lo <= din;
						addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
						state <= S_M2_BYTE2;
					end else begin
						r2 <= (mode2 == M_MI16) ? {8'hFF, din} : {8'h00, din};
						state <= S_PRE_READ1;
					end
				end
				S_M2_BYTE2: begin
					r2 <= {din, byte_lo};
					state <= S_PRE_READ1;
				end

				// ------------------------------------------------------
				// Prefixed opcode groups: fetch whatever's left (address
				// byte(s) for FF/MN groups, none for GG), then the
				// operation-selector byte, then resolve via level-2 decode.
				// ------------------------------------------------------
				S_PFX_ADDR: begin // FF_SRC/FF_DST: address low byte -> $FF00|byte
					pfx_addr <= {8'hFF, din};
					addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
					state <= S_PFX_SEL;
				end
				S_PFX_ADDR_LO: begin // MN_SRC/MN_DST: imm16 low byte
					byte_lo <= din;
					addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
					state <= S_PFX_ADDR_HI;
				end
				S_PFX_ADDR_HI: begin // MN_SRC/MN_DST: imm16 high byte
					pfx_addr <= {din, byte_lo};
					addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
					state <= S_PFX_SEL;
				end
				S_PFX_DISP: begin // IXD_SRC/IXD_DST: displacement byte -> base_reg + sign-extend(d)
					pfx_addr <= r16_read(gg) + {{8{din[7]}}, din};
					addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
					state <= S_PFX_SEL;
				end
				S_PFX_SEL: begin // din == the operation-selector byte; d2_* valid now
					op <= d2_op; wide <= d2_wide;
					mode1 <= d2_mode1; mode2 <= d2_mode2;
					if (d2_mem_slot == 2'd1) begin
						r1 <= (pfx == PFX_GG_SRC || pfx == PFX_GG_DST || pfx == PFX_G8) ? {12'h0, gg} : pfx_addr;
						r2 <= {12'h0, d2_r2e};
					end else begin
						r2 <= (pfx == PFX_GG_SRC || pfx == PFX_GG_DST || pfx == PFX_G8) ? {12'h0, gg} : pfx_addr;
						r1 <= {12'h0, d2_r1e};
					end
					if (d2_needs_i8) begin
						addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
						state <= S_PFX_I8;
					end else begin
						state <= S_PRE_READ1;
					end
				end
				S_PFX_I8: begin // trailing immediate byte for DST-side ADD-family/LD-imm/CP forms (mode2 always M_I8)
					r2 <= {8'h00, din};
					state <= S_PRE_READ1;
				end

				// ------------------------------------------------------
				// Resolve operand 1: memory read, or direct (no bus access)
				// ------------------------------------------------------
				S_PRE_READ1: begin
					if (op_reads_m1(op) && mode_needs_read(mode1)) begin
						addr <= eff1; mem_rd <= 1'b1;
						state <= S_READ1_LO;
					end else begin
						val1 <= !op_reads_m1(op) ? r1 : (mode1 == M_R8) ? {8'h00, r8_read(r1[2:0])} : (mode1 == M_R16) ? r16_read(r1[3:0]) : r1;
						state <= S_PRE_READ2;
					end
				end
				S_READ1_LO: begin
					if (wide) begin
						byte_lo <= din;
						addr <= eff1 + 16'd1; mem_rd <= 1'b1;
						state <= S_READ1_HI;
					end else begin
						val1 <= {8'h00, din};
						state <= S_PRE_READ2;
					end
				end
				S_READ1_HI: begin
					val1 <= {din, byte_lo};
					state <= S_PRE_READ2;
				end

				// ------------------------------------------------------
				// Resolve operand 2
				// ------------------------------------------------------
				S_PRE_READ2: begin
					if (mode2 != M_NONE && mode_needs_read(mode2)) begin
						addr <= eff2; mem_rd <= 1'b1;
						state <= S_READ2_LO;
					end else begin
						if (mode2 != M_NONE) val2 <= (mode2 == M_R8) ? {8'h00, r8_read(r2[2:0])} : (mode2 == M_R16) ? r16_read(r2[3:0]) : r2;
						state <= S_EXECUTE;
					end
				end
				S_READ2_LO: begin
					if (wide) begin
						byte_lo <= din;
						addr <= eff2 + 16'd1; mem_rd <= 1'b1;
						state <= S_READ2_HI;
					end else begin
						val2 <= {8'h00, din};
						state <= S_EXECUTE;
					end
				end
				S_READ2_HI: begin
					val2 <= {din, byte_lo};
					state <= S_EXECUTE;
				end

				// ------------------------------------------------------
				// Execute
				// ------------------------------------------------------
				S_EXECUTE: begin
					state <= S_FETCH_OP; // default; overridden below where needed
					case (op)
						OP_NOP: ;

						OP_EX: begin
							if (r1[3:0] == R16_DE) begin
								de <= hl; hl <= de;
							end else begin // AF <-> AF2
								{a, f} <= r16_read(R16_AF2);
								{a2, f2} <= {a, f};
							end
						end
						OP_EXX: begin
							bc <= bc2; bc2 <= bc;
							de <= de2; de2 <= de;
							hl <= hl2; hl2 <= hl;
						end

						OP_LD: begin
							if (mode1 == M_R8) a_or_r8_write(r1[2:0], val2[7:0]);
							else if (mode1 == M_R16) r16_write_reg(r1[3:0], wide ? val2 : {8'h00, val2[7:0]});
							else begin // M_MI16 or M_MR16
								wb_val <= val2;
								addr <= eff1; dout <= val2[7:0]; mem_wr <= 1'b1;
								state <= wide ? S_WRITE1_HI : S_FETCH_OP;
							end
						end

						OP_PUSH: begin
							push_val <= r16_read(r1[3:0]);
							sp <= sp - 16'd2;
							addr <= sp - 16'd2; dout <= r16_read(r1[3:0])[7:0]; mem_wr <= 1'b1;
							state <= S_PUSH_HI;
						end
						OP_POP: begin
							pop_dest <= 2'd0;
							addr <= sp; mem_rd <= 1'b1;
							state <= S_POP_LO;
						end

						OP_JP: if (test_cc(r1[3:0], f)) pc <= val2;
						OP_JR: if (test_cc(r1[3:0], f)) pc <= pc + {{8{val2[7]}}, val2[7:0]};
						OP_CALL: if (test_cc(r1[3:0], f)) begin
							push_val <= pc;
							sp <= sp - 16'd2;
							addr <= sp - 16'd2; dout <= pc[7:0]; mem_wr <= 1'b1;
							pc <= val2;
							state <= S_PUSH_HI;
						end
						OP_RET: if (test_cc(r1[3:0], f)) begin
							pop_dest <= 2'd1;
							addr <= sp; mem_rd <= 1'b1;
							state <= S_POP_LO;
						end
						OP_RETI: begin
							pop_dest <= 2'd2;
							addr <= sp; mem_rd <= 1'b1;
							state <= S_POP_LO;
						end

						OP_HALT: halt_r <= 1'b1;
						OP_DI: begin f[IFB] <= 1'b0; after_ei <= 1'b0; end
						OP_EI: after_ei <= ~f[IFB];

						OP_DJNZ: begin
							if (!wide) begin
								bc[15:8] <= bc[15:8] - 8'd1;
								if ((bc[15:8] - 8'd1) != 8'd0) pc <= pc + {{8{val1[7]}}, val1[7:0]};
							end else begin
								bc <= bc - 16'd1;
								if ((bc - 16'd1) != 16'd0) pc <= pc + {{8{val2[7]}}, val2[7:0]};
							end
						end

						OP_DAA: begin : daa_blk
							reg cf,nf,hf; reg [3:0] lo,hi; reg [7:0] diff, newa; reg [7:0] nf8;
							cf = f[CF]; nf = f[NF]; hf = f[HF];
							lo = a[3:0]; hi = a[7:4];
							if (cf) diff = ((lo <= 4'd9) && !hf) ? 8'h60 : 8'h66;
							else if (lo >= 4'd10) diff = (hi <= 4'd8) ? 8'h06 : 8'h66;
							else if (hi >= 4'd10) diff = hf ? 8'h66 : 8'h60;
							else diff = hf ? 8'h06 : 8'h00;
							newa = nf ? (a - diff) : (a + diff);
							nf8 = szp8(newa) | (f & ((8'd1<<IFB)|(8'd1<<NF)));
							if (cf || (lo <= 4'd9 ? hi >= 4'd10 : hi >= 4'd9)) nf8 = nf8 | (8'd1<<XCF) | (8'd1<<CF);
							if (nf ? (hf && lo <= 4'd5) : (lo >= 4'd10)) nf8 = nf8 | (8'd1<<HF);
							a <= newa; f <= nf8;
						end

						OP_CPL: begin a <= ~a; f <= f | (8'd1<<HF) | (8'd1<<NF); end
						OP_NEG: begin : neg_blk
							reg [8:0] d9; reg [7:0] r8v, nf8;
							d9 = {1'b0,8'd0} - {1'b0,a};
							r8v = d9[7:0];
							nf8 = (f & (8'd1<<IFB)) | sz8(r8v) | (8'd1<<NF);
							if (d9[8]) nf8 = nf8 | (8'd1<<CF) | (8'd1<<XCF);
							if ((8'd0 ^ r8v ^ a) & 8'h10) nf8 = nf8 | (8'd1<<HF);
							if ((a ^ 8'd0) & (8'd0 ^ r8v) & 8'h80) nf8 = nf8 | (8'd1<<PF);
							a <= r8v; f <= nf8;
						end

						OP_RCF: f <= f & ((8'd1<<SF)|(8'd1<<ZF)|(8'd1<<IFB)|(8'd1<<PF));
						OP_SCF: f <= (f & ((8'd1<<SF)|(8'd1<<ZF)|(8'd1<<IFB)|(8'd1<<PF))) | (8'd1<<XCF) | (8'd1<<CF);
						OP_CCF: f <= (f & ((8'd1<<SF)|(8'd1<<ZF)|(8'd1<<IFB)|(8'd1<<PF))) | (f[CF] ? (8'd1<<HF) : ((8'd1<<XCF)|(8'd1<<CF)));

						OP_BIT: f <= (f & ((8'd1<<IFB)|(8'd1<<CF))) | (8'd1<<HF) | sz_bit8(val2[7:0] & (8'd1 << r1[2:0]));
						OP_SET, OP_RES: begin
							wb_val <= op == OP_SET ? {8'h00, val2[7:0] | (8'd1 << r1[2:0])} : {8'h00, val2[7:0] & ~(8'd1 << r1[2:0])};
							addr <= eff2;
							dout <= op == OP_SET ? (val2[7:0] | (8'd1 << r1[2:0])) : (val2[7:0] & ~(8'd1 << r1[2:0]));
							mem_wr <= 1'b1;
							state <= S_FETCH_OP;
						end

						OP_INC: begin : inc_blk
							reg [15:0] r16v; reg [7:0] r8v, nf8;
							if (!wide) begin
								r8v = val1[7:0] + 8'd1;
								nf8 = (f & ((8'd1<<IFB)|(8'd1<<CF))) | szhv_inc8(r8v);
								if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
								else begin wb_val <= {8'h00,r8v}; addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
								f <= nf8;
							end else begin
								r16v = val1 + 16'd1;
								r16_write_reg(r1[3:0], r16v);
								f[XCF] <= (r16v == 16'd0);
							end
						end
						OP_DEC: begin : dec_blk
							reg [15:0] r16v; reg [7:0] r8v, nf8;
							if (!wide) begin
								r8v = val1[7:0] - 8'd1;
								nf8 = (f & ((8'd1<<IFB)|(8'd1<<CF))) | szhv_dec8(r8v);
								if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
								else begin wb_val <= {8'h00,r8v}; addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
								f <= nf8;
							end else begin
								r16v = val1 - 16'd1;
								r16_write_reg(r1[3:0], r16v);
								f[XCF] <= (r16v == 16'd0);
							end
						end
						OP_INCX: begin : incx_blk
							reg [7:0] r8v;
							if (f[XCF]) begin
								r8v = val1[7:0] + 8'd1;
								f <= (f & ((8'd1<<IFB)|(8'd1<<CF))) | szhv_inc8(r8v);
								addr <= eff1; dout <= r8v; mem_wr <= 1'b1;
							end
						end
						OP_DECX: begin : decx_blk
							reg [7:0] r8v;
							if (f[XCF]) begin
								r8v = val1[7:0] - 8'd1;
								f <= (f & ((8'd1<<IFB)|(8'd1<<CF))) | szhv_dec8(r8v);
								addr <= eff1; dout <= r8v; mem_wr <= 1'b1;
							end
						end
						OP_INCW: begin : incw_blk
							reg [16:0] sum17; reg [15:0] r16v; reg [7:0] nf8;
							sum17 = {1'b0,val1} + 17'd1;
							r16v = sum17[15:0];
							nf8 = f & ((8'd1<<IFB)|(8'd1<<CF));
							if (r16v == 16'd0) nf8 = nf8 | (8'd1<<ZF) | (8'd1<<XCF);
							if (r16v[15]) nf8 = nf8 | (8'd1<<SF);
							if ((val1 ^ 16'h8000) & r16v & 16'h8000) nf8 = nf8 | (8'd1<<PF);
							if ((val1 ^ r16v ^ 16'd1) & 16'h1000) nf8 = nf8 | (8'd1<<HF);
							f <= nf8;
							wb_val <= r16v;
							addr <= eff1; dout <= r16v[7:0]; mem_wr <= 1'b1;
							state <= S_WRITE1_HI;
						end
						OP_DECW: begin : decw_blk
							reg [15:0] r16v; reg [7:0] nf8;
							r16v = val1 - 16'd1;
							nf8 = (f & ((8'd1<<IFB)|(8'd1<<CF))) | (8'd1<<NF);
							if (r16v == 16'd0) nf8 = nf8 | (8'd1<<ZF) | (8'd1<<XCF);
							if (r16v[15]) nf8 = nf8 | (8'd1<<SF);
							if (val1 == 16'h8000) nf8 = nf8 | (8'd1<<PF);
							if ((val1 ^ r16v ^ 16'd1) & 16'h1000) nf8 = nf8 | (8'd1<<HF);
							f <= nf8;
							wb_val <= r16v;
							addr <= eff1; dout <= r16v[7:0]; mem_wr <= 1'b1;
							state <= S_WRITE1_HI;
						end

						OP_ADD, OP_ADC: begin : add_blk
							reg [7:0] a8,b8,r8v,nf8; reg [8:0] s9;
							reg [15:0] a16,b16,r16v; reg [16:0] s17; reg [7:0] nf16;
							if (!wide) begin
								a8 = val1[7:0]; b8 = val2[7:0];
								s9 = {1'b0,a8} + {1'b0,b8} + (op == OP_ADC ? {8'b0,f[CF]} : 9'd0);
								r8v = s9[7:0];
								nf8 = (f & (8'd1<<IFB)) | sz8(r8v);
								if (s9[8]) nf8 = nf8 | (8'd1<<CF) | (8'd1<<XCF);
								if ((a8 ^ r8v ^ b8) & 8'h10) nf8 = nf8 | (8'd1<<HF);
								if ((b8 ^ a8 ^ 8'h80) & (b8 ^ r8v) & 8'h80) nf8 = nf8 | (8'd1<<PF);
								f <= nf8;
								if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
							end else begin
								a16 = val1; b16 = val2;
								s17 = {1'b0,a16} + {1'b0,b16} + (op == OP_ADC ? {16'b0,f[CF]} : 17'd0);
								r16v = s17[15:0];
								// Register-to-register ADD HL,rr special case (see
								// docs/tier2-tlcs90.md): only plain ADD (not ADC)
								// with a register mode2 skips the S/Z/V recompute,
								// reachable via the 0xf8-0xfe group's "ADD HL,gg"
								// form — every other 16-bit arithmetic addressing
								// combination (including ADC HL,gg) recomputes them.
								if (op == OP_ADD && mode2 == M_R16) begin
									nf16 = f & ((8'd1<<SF)|(8'd1<<ZF)|(8'd1<<IFB)|(8'd1<<PF));
								end else begin
									nf16 = f & (8'd1<<IFB);
									if (r16v == 16'd0) nf16 = nf16 | (8'd1<<ZF);
									if (r16v[15]) nf16 = nf16 | (8'd1<<SF);
									if ((b16 ^ a16 ^ 16'h8000) & (b16 ^ r16v) & 16'h8000) nf16 = nf16 | (8'd1<<PF);
								end
								if (s17[16]) nf16 = nf16 | (8'd1<<CF) | (8'd1<<XCF);
								if ((a16 ^ r16v ^ b16) & 16'h1000) nf16 = nf16 | (8'd1<<HF);
								f <= nf16;
								r16_write_reg(r1[3:0], r16v);
							end
						end
						OP_SUB, OP_SBC, OP_CP: begin : sub_blk
							reg [7:0] a8,b8,r8v,nf8; reg [8:0] d9;
							reg [15:0] a16,b16,r16v; reg [16:0] d17; reg [7:0] nf16;
							if (!wide) begin
								a8 = val1[7:0]; b8 = val2[7:0];
								d9 = {1'b0,a8} - {1'b0,b8} - (op == OP_SBC ? {8'b0,f[CF]} : 9'd0);
								r8v = d9[7:0];
								nf8 = (f & (8'd1<<IFB)) | sz8(r8v) | (8'd1<<NF);
								if (d9[8]) nf8 = nf8 | (8'd1<<CF) | (8'd1<<XCF);
								if ((a8 ^ r8v ^ b8) & 8'h10) nf8 = nf8 | (8'd1<<HF);
								if ((b8 ^ a8) & (a8 ^ r8v) & 8'h80) nf8 = nf8 | (8'd1<<PF);
								f <= nf8;
								if (op != OP_CP) begin
									if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
									else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
								end
							end else begin
								a16 = val1; b16 = val2;
								d17 = {1'b0,a16} - {1'b0,b16} - (op == OP_SBC ? {16'b0,f[CF]} : 17'd0);
								r16v = d17[15:0];
								nf16 = (f & (8'd1<<IFB)) | (8'd1<<NF);
								if (r16v == 16'd0) nf16 = nf16 | (8'd1<<ZF);
								if (r16v[15]) nf16 = nf16 | (8'd1<<SF);
								if (d17[16]) nf16 = nf16 | (8'd1<<CF) | (8'd1<<XCF);
								if ((a16 ^ r16v ^ b16) & 16'h1000) nf16 = nf16 | (8'd1<<HF);
								if ((b16 ^ a16) & (a16 ^ r16v) & 16'h8000) nf16 = nf16 | (8'd1<<PF);
								f <= nf16;
								if (op != OP_CP) r16_write_reg(r1[3:0], r16v);
							end
						end
						OP_AND: begin : and_blk
							reg [7:0] r8v; reg [15:0] r16v;
							if (!wide) begin
								r8v = val1[7:0] & val2[7:0];
								f <= (f & (8'd1<<IFB)) | szp8(r8v) | (8'd1<<HF);
								if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
							end else begin
								r16v = val1 & val2;
								f <= (f & (8'd1<<IFB)) | (8'd1<<HF) | (r16v == 0 ? (8'd1<<ZF) : 8'h00) | (r16v[15] ? (8'd1<<SF) : 8'h00);
								r16_write_reg(r1[3:0], r16v);
							end
						end
						OP_XOR: begin : xor_blk
							reg [7:0] r8v; reg [15:0] r16v;
							if (!wide) begin
								r8v = val1[7:0] ^ val2[7:0];
								f <= (f & (8'd1<<IFB)) | szp8(r8v);
								if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
							end else begin
								r16v = val1 ^ val2;
								f <= (f & (8'd1<<IFB)) | (r16v == 0 ? (8'd1<<ZF) : 8'h00) | (r16v[15] ? (8'd1<<SF) : 8'h00);
								r16_write_reg(r1[3:0], r16v);
							end
						end
						OP_OR: begin : or_blk
							reg [7:0] r8v; reg [15:0] r16v;
							if (!wide) begin
								r8v = val1[7:0] | val2[7:0];
								f <= (f & (8'd1<<IFB)) | szp8(r8v);
								if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
							end else begin
								r16v = val1 | val2;
								f <= (f & (8'd1<<IFB)) | (r16v == 0 ? (8'd1<<ZF) : 8'h00) | (r16v[15] ? (8'd1<<SF) : 8'h00);
								r16_write_reg(r1[3:0], r16v);
							end
						end

						OP_RLC, OP_RRC, OP_RL, OP_RR, OP_SLA, OP_SRA, OP_SLL, OP_SRL: begin : rot_blk
							reg [7:0] a8, r8v; reg cflag; reg [7:0] nf8;
							a8 = val1[7:0];
							case (op)
								OP_RLC: begin r8v = {a8[6:0], a8[7]}; cflag = a8[7]; end
								OP_RRC: begin r8v = {a8[0], a8[7:1]}; cflag = a8[0]; end
								OP_RL:  begin r8v = {a8[6:0], f[CF]}; cflag = a8[7]; end
								OP_RR:  begin r8v = {f[CF], a8[7:1]}; cflag = a8[0]; end
								OP_SLA, OP_SLL: begin r8v = {a8[6:0], 1'b0}; cflag = a8[7]; end
								OP_SRA: begin r8v = {a8[7], a8[7:1]}; cflag = a8[0]; end
								OP_SRL: begin r8v = {1'b0, a8[7:1]}; cflag = a8[0]; end
								default: begin r8v = a8; cflag = 1'b0; end
							endcase
							if (mode1 == M_R8 && r1[2:0] == R8_A)
								nf8 = f & ((8'd1<<SF)|(8'd1<<ZF)|(8'd1<<IFB)|(8'd1<<PF));
							else
								nf8 = (f & (8'd1<<IFB)) | szp8(r8v);
							if (cflag) nf8 = nf8 | (8'd1<<CF) | (8'd1<<XCF);
							f <= nf8;
							if (mode1 == M_R8) a_or_r8_write(r1[2:0], r8v);
							else begin addr <= eff1; dout <= r8v; mem_wr <= 1'b1; end
						end

						default: ; // OP_UNKNOWN: no-op, treated as a bug marker for the testbench to catch via dbg_pc stall
					endcase
				end

				S_WRITE1_HI: begin
					addr <= eff1 + 16'd1; dout <= wb_val[15:8]; mem_wr <= 1'b1;
					state <= S_FETCH_OP;
				end

				S_PUSH_HI: begin
					addr <= sp + 16'd1; dout <= push_val[15:8]; mem_wr <= 1'b1;
					state <= S_FETCH_OP;
				end

				S_POP_LO: begin
					byte_lo <= din;
					addr <= sp + 16'd1; mem_rd <= 1'b1;
					sp <= sp + 16'd2;
					state <= S_POP_HI;
				end
				S_POP_HI: begin
					// din == high byte now; combine and dispatch by pop_dest
					case (pop_dest)
						2'd0: r16_write_reg(r1[3:0], {din, byte_lo});
						2'd1: pc <= {din, byte_lo};
						2'd2: {a, f} <= {din, byte_lo};
						default: ;
					endcase
					if (pop_dest == 2'd2) begin
						pop_dest <= 2'd1;
						addr <= sp; mem_rd <= 1'b1; // sp already advanced by the AF pop above
						state <= S_POP_LO;
					end else begin
						state <= S_FETCH_OP;
					end
				end

				default: state <= S_FETCH_OP;
			endcase
		end
	end

	// Register writeback helpers — implemented as automatic tasks so the
	// large EXECUTE case above can call a single writeback point per
	// destination kind instead of repeating the same case-on-register-code
	// logic in every arithmetic/logic op's branch.
	task automatic a_or_r8_write(input [2:0] sel, input [7:0] val);
		case (sel)
			R8_A: a <= val;
			R8_B: bc[15:8] <= val;
			R8_C: bc[7:0]  <= val;
			R8_D: de[15:8] <= val;
			R8_E: de[7:0]  <= val;
			R8_H: hl[15:8] <= val;
			R8_L: hl[7:0]  <= val;
			default: ;
		endcase
	endtask

	task automatic r16_write_reg(input [3:0] sel, input [15:0] val);
		case (sel)
			R16_BC:  bc <= val;
			R16_DE:  de <= val;
			R16_HL:  hl <= val;
			R16_IX:  ix <= val;
			R16_IY:  iy <= val;
			R16_SP:  sp <= val;
			R16_AF:  {a, f} <= val;
			R16_AF2: {a2, f2} <= val;
			default: ;
		endcase
	endtask

endmodule
