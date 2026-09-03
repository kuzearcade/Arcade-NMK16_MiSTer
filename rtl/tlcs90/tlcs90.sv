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
// Still deferred: the TSET/LDA dead opcode space MAME's own reference
// model can't execute either — this is the CPU core's entire real opcode
// table, complete.
//
// Block transfer (LDI/LDIR/LDD/LDDR/CPI/CPIR/CPD/CPDR) and RET cc's second
// encoding ARE implemented — both only valid when the 0xf8-0xfe group's own
// opcode byte is exactly 0xfe (gg==R16_SP), see the level-2 decode's
// PFX_G8 branch. LDI*/CPI* reuse the normal M_MR16/r1=R16_HL read pipeline
// to fetch RM8(HL) for free, then LDI* writes it straight to (DE) and
// CPI* compares it against A, both directly in S_EXECUTE (see the
// OP_LDI*/OP_CPI* execute blocks); the *IR/*DR repeat forms are a literal
// `pc -= 2` re-fetch of the same 2-byte instruction when their loop
// condition holds, mirroring the reference's own `m_pc.w.l -= 2` exactly
// rather than looping internally.
//
// RLD/RRD ARE implemented too — reachable via every SRC prefix group's own
// selector byte 0x10/0x11 (never the base table), see the pfx_is_src
// level-2 decode branch. Rotate the 12-bit {A_lo,M_hi,M_lo} unit one
// nibble left (RLD) or right (RRD); A isn't a decoded operand slot in
// this group's own encoding, so EXECUTE reads/writes it directly, the
// same reasoning LDI*/CPI* already established for DE.
//
// MUL/DIV ARE implemented too — 0xf8-0xfe group, selector byte 0x12/0x13,
// valid for any b0 (unlike block-transfer/RET-cc-2, no gg==R16_SP gate).
// mode1 is always R16(HL) (constant, never gg-derived — matching the
// reference's own hardcoded m_hl access); mode2 is R8(g) where g==gg,
// filled automatically by the same PFX_G8 r2<-gg logic the ADD-family
// arms already rely on. Pure register-register ops, no memory access at
// all. MUL touches no flags whatsoever (confirmed by direct reading, not
// an oversight); DIV only ever touches PF/VF (`F |= VF`/`F &= ~VF`, never
// a full reassignment) — see the OP_MUL/OP_DIV execute blocks for the
// divide-by-zero special case.
//
// LDAR/CALLR ARE implemented too — base-table opcodes 0x17/0x1d, both using
// a new M_D16 addressing mode (a 16-bit relative/PC-relative constant that
// reads as raw-1 at EXECUTE time — an intentional off-by-one in the real
// ISA, distinct from a genuine M_I16 immediate; shares M_I16's 2-byte
// little-endian fetch machinery, so no new FSM states were needed). LDAR
// writes `HL = PC + (raw-1)` directly, no bus access, no flags. CALLR is
// an unconditional push+jump identical to CALL's mechanics except the
// target is PC-relative. The base table's own 16-bit-relative JR form
// (0x1b, unconditional) reuses OP_JR rather than adding a new op — `wide`
// (set only by this one opcode) picks the M_D16 raw-1 arithmetic over the
// existing 8-bit sign-extended-displacement form the 0xc0-0xcf opcodes
// use, in the same execute case.
//
// SWI IS implemented too — base-table opcode 0xff, the last byte outside
// the PFX_G8 group (which only covers 0xf8-0xfe). A synchronous software
// interrupt: reuses the *exact same* push-PC-then-AF/clear-IF-after/
// vector-jump chain the S_FETCH_OP interrupt dispatch already builds for
// maskable IRQs and NMI (irq_taking gates S_PUSH_HI into chaining onward
// to push AF too), just triggered directly from EXECUTE instead of the
// per-instruction dispatch check, with the vector fixed at INTSWI's own
// 0x0010. Genuinely non-maskable (unlike NMI in this model — see the
// interrupt-model doc): nothing about reaching this EXECUTE case checks
// IF at all, matching the reference calling take_interrupt() directly
// rather than going through check_interrupts()'s `if (!(F&IF)) return;`
// gate.
//
// The memory-operand forms of EX ARE implemented too — reachable via
// every SRC prefix group's own selector byte 0x50-0x56 (skipping 0x53,
// same register-code-skip pattern as every other rr-selecting range in
// this table), unlike every other pfx_is_src entry the memory operand
// sits in slot 1 here (mem_slot=1), matching the reference's own
// MR16(1,...)/R16(2,...) ordering — a genuine 16-bit swap has no natural
// "source"/"destination" side to match LD's convention. OP_EX was
// removed from op_reads_m1's exclusion list (harmless for the existing
// base-table register-only forms, since mode_needs_read() already gates
// M_R16 out regardless) so the new form's memory word gets read before
// being overwritten — the swap can't happen otherwise. See the OP_EX
// execute block's mode1==M_R16 branch (unchanged, base-table forms) vs.
// its else branch (new, reusing OP_LD's own wb_val/S_WRITE1_HI
// wide-memory-write chain for the memory side, with the register side
// written the same cycle via r16_write_reg).
//
// IX/IY bank extension via BX/BY (`ix_bank`/`iy_bank` inputs, driven from a
// peripheral module's BX/BY registers) IS implemented — see `bank1`/`bank2`
// below — matching the reference's RX8/RX16/WX8/WX16 exactly: the bank
// nibble is bitwise-OR'd (not added) into address bits 19:16, and ONLY for
// the `MR16`/`MR16D8` addressing forms (register-indirect or +displacement
// through IX or IY specifically — never SP, never BC/DE/HL, never the
// `(HL+A)` form, and never a direct/short-address operand) — mirroring the
// reference's own per-addressing-mode dispatch (`Read/WriteN_8/16`'s
// `case e_mode::MR16`/`MR16D8` switching on the base register). A 16-bit
// offset wraparound within one operand (e.g. the low/high byte of a 16-bit
// access straddling 0xFFFF) never carries into the bank, matching
// `(a+1) & 0xffff` in the reference — this core's `addr` stays a plain
// 16-bit offset per access; only `addr_bank` carries the OR'd-in nibble.
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
	// Bank nibble (address bits 19:16) for the current `addr`, OR'd in by
	// the caller to form the real 20-bit bus address — see the module
	// header's "IX/IY bank extension" note. 0 for every access except an
	// IX/IY-based MR16/MR16D8 operand, matching the reference exactly
	// (BC/DE/HL/SP-based accesses, direct/short-address operands, PC
	// fetches, and SP-relative push/pop are always bank 0).
	output reg [3:0] addr_bank,
	output reg   mem_rd,
	output reg   mem_wr,

	// Interrupt inputs. `nmi` is edge-detected internally (pulse or level,
	// either works — only the rising edge matters), matching the
	// reference's execute_input_edge_triggered/raise_irq behavior for
	// INTNMI. `irq_req`/`irq_mask` are the 11 maskable sources in
	// reference priority order (bit0=highest): INT0, T0, T1, T2, T3, T4,
	// INT1, T5, INT2, RX, TX — matching INTSWI+3..INTSWI+13's scan order.
	// `irq_req` is level-sensitive-but-internally-latched (a pulse is
	// enough; the request stays pending until taken, mirroring
	// raise_irq()'s m_irq_state bit staying set until clear_irq()).
	// `irq_mask` should be driven combinationally from a peripheral
	// module's INTEL/INTEH registers (this core owns none of that state).
	// SWI is a synchronous opcode, not modeled as an external request —
	// see the module's opcode-scope note above (still deferred).
	input        nmi,
	input [10:0] irq_req,
	input [10:0] irq_mask,

	// BX/BY's low nibble (0xffec/0xffed in a peripheral module), applied to
	// IX/IY-based memory addressing only — see `addr_bank` above and the
	// module header.
	input  [3:0] ix_bank,
	input  [3:0] iy_bank,

	// debug: pulses dbg_valid for one cycle at the start of each new
	// instruction with that instruction's own PC — the same point in time
	// MAME's `trace` debugger command reports from, directly diffable
	// against a captured disassembly oracle trace.
	output reg [15:0] dbg_pc,
	output reg        dbg_valid,
	output             dbg_halt,

	// debug: live register state, sampled alongside dbg_pc/dbg_valid —
	// purely additive, for root-causing oracle divergences against MAME's
	// own debugger register readout (A/HL/F match MAME's TLCS-90 debug
	// state symbols of the same name).
	output      [7:0]  dbg_a,
	output      [7:0]  dbg_f,
	output      [15:0] dbg_hl,
	output      [15:0] dbg_de,
	output      [15:0] dbg_iy
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
	assign dbg_a  = a;
	assign dbg_f  = f;
	assign dbg_hl = hl;
	assign dbg_de = de;
	assign dbg_iy = iy;

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
		M_MR16 = 9, // memory, indirect via a register pair ("(gg)" in the prefixed opcode groups)
		// 16-bit relative/PC-relative constant, used only by LDAR/CALLR/the
		// 16-bit JR form (opcodes 0x17/0x1d/0x1b) — same 2-byte
		// little-endian fetch as M_I16 (mode_needs_read/mode2 byte-fetch
		// share that machinery, no special-casing needed there), but reads
		// as raw-1 at EXECUTE time (an intentional off-by-one in the real
		// ISA), unlike a genuine M_I16 immediate. Distinct from M_D8
		// (JR/DJNZ's 8-bit sign-extended form, no -1 quirk).
		M_D16 = 10;

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
		// Block transfer/compare family (0xf8-0xfe group, selector byte
		// 0x58-0x5f, only valid when b0==0xfe — see the PFX_G8 decode
		// branch below). Contiguous like ADD/RLC's own op-plus-offset
		// groups, mirroring the reference's own `LDI+b1-0x58` formula.
		OP_LDI=46, OP_LDIR=47, OP_LDD=48, OP_LDDR=49,
		OP_CPI=50, OP_CPIR=51, OP_CPD=52, OP_CPDR=53,
		// RLD/RRD: reachable via every SRC prefix group's own selector
		// byte 0x10/0x11 (not the base table) — see the pfx_is_src level-2
		// decode branch below.
		OP_RLD=54, OP_RRD=55,
		// MUL/DIV: 0xf8-0xfe group, selector byte 0x12/0x13, any b0 (unlike
		// block-transfer/RET-cc-2, not gated to b0==0xfe) — mode1 is always
		// R16(HL), mode2 is R8(g) where g = the base opcode's own embedded
		// register code (gg). See the PFX_G8 decode branch below.
		OP_MUL=56, OP_DIV=57,
		// LDAR/CALLR: base-table opcodes 0x17/0x1d, both M_D16-operand
		// ops (see M_D16's own comment above). OP_JR is reused (not a new
		// op) for the base table's own 16-bit-relative form at 0x1b —
		// `wide` distinguishes it from the existing 8-bit-displacement JR
		// opcodes (0xc0-0xcf) in the same OP_JR execute case.
		OP_LDAR=58, OP_CALLR=59,
		// SWI: base-table opcode 0xff, a synchronous software interrupt —
		// pushes PC then AF and jumps to the fixed INTSWI vector (0x0010)
		// exactly like a real maskable-interrupt/NMI dispatch, but entered
		// directly from EXECUTE (this is what the opcode itself does, not
		// a request that gets arbitrated). Genuinely non-maskable, unlike
		// NMI in this model (see the interrupt-model doc/header note) —
		// bypasses the IF gate entirely by construction, since nothing
		// about reaching this EXECUTE case depends on IF at all.
		OP_SWI=60,
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

			// MUL/DIV HL,n (8-bit immediate). Same OP_MUL/OP_DIV the
			// PFX_G8 register-operand form already uses (reference:
			// tlcs90.cpp:367-370, "case 0x12: case 0x13: OP(MUL+b0-0x12,16)
			// R16(1,HL) I8(2,READ8())") — missing here entirely, same
			// silent-OP_NOP-fallthrough class as the ADD ix,mn gap above.
			8'h12: begin d_op = OP_MUL; d_mode1 = M_R16; d_r1e = R16_HL; d_mode2 = M_I8; d_m2bytes = 2'd1; end
			8'h13: begin d_op = OP_DIV; d_mode1 = M_R16; d_r1e = R16_HL; d_mode2 = M_I8; d_m2bytes = 2'd1; end

			// ADD ix,mn (ix = IX/IY/SP, register selected by the opcode
			// byte itself — R16_IX + (opcode-0x14), landing on R16_IX(4)/
			// R16_IY(5)/R16_SP(6) for 0x14/0x15/0x16 respectively, same
			// arithmetic already documented above for the (gg)-indexed
			// groups). Confirmed directly against the reference
			// (cpu/tlcs90/tlcs90.cpp:372-373, "case 0x14: case 0x15: case
			// 0x16: OP16(ADD,6) R16(1,IX+b0-0x14) I16(2,READ16())") — this
			// specific base (unprefixed) form was missing from this table
			// entirely (the cycle-cost table above already had an entry
			// for it, "8'h14, 8'h15, 8'h16: cyc = 6'd12" under PFX_NONE,
			// but nothing here ever produced a non-default d_op for these
			// three opcodes, so they silently executed as OP_NOP — found
			// via tdragon1's own protection-MCU firmware, the first ROM
			// in this project to ever execute "ADD IY,#imm16": IY never
			// advanced through a 16-entry table-scan loop, causing every
			// iteration to re-read the same table entry).
			8'h14, 8'h15, 8'h16: begin
				d_op = OP_ADD; d_wide = 1'b1;
				d_mode1 = M_R16; d_r1e = R16_IX + 4'(din - 8'h14);
				d_mode2 = M_I16; d_m2bytes = 2'd2;
			end

			// LDAR HL,+cd: HL = PC + (raw D16 value - 1). No memory
			// access, no flags touched (confirmed by the reference — no
			// F=... line for this op either) — see the OP_LDAR execute
			// block. mode1 stays M_NONE (the reference tags this R16(HL)
			// only to name the write destination; nothing ever reads it
			// through the operand pipeline, so there's nothing to decode
			// there).
			8'h17: begin d_op = OP_LDAR; d_mode2 = M_D16; d_m2bytes = 2'd2; end

			8'h18: begin d_op = OP_DJNZ; d_mode1 = M_D8; d_m1bytes = 2'd1; end
			8'h19: begin d_op = OP_DJNZ; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = R16_BC; d_mode2 = M_D8; d_m2bytes = 2'd1; end

			8'h1a: begin d_op = OP_JP; d_mode1 = M_CC; d_r1e = 4'h8; d_mode2 = M_I16; d_m2bytes = 2'd2; end
			// JR T,+cd (16-bit relative, unconditional — CC=T is baked
			// into this specific opcode, same 4'h8 encoding 0x1a/0x1c
			// already use). Reuses OP_JR (not a new op): `d_wide` is what
			// distinguishes this from the 8-bit-displacement JR opcodes
			// (0xc0-0xcf) sharing the same execute case.
			8'h1b: begin d_op = OP_JR; d_wide = 1'b1; d_mode1 = M_CC; d_r1e = 4'h8; d_mode2 = M_D16; d_m2bytes = 2'd2; end
			8'h1c: begin d_op = OP_CALL; d_mode1 = M_CC; d_r1e = 4'h8; d_mode2 = M_I16; d_m2bytes = 2'd2; end
			// CALLR +cd: unconditional (no CC gate at all in the
			// reference — always pushes PC and jumps). mode1 stays
			// M_NONE, same reasoning as LDAR above.
			8'h1d: begin d_op = OP_CALLR; d_mode2 = M_D16; d_m2bytes = 2'd2; end
			8'h1e: begin d_op = OP_RET; d_mode1 = M_CC; d_r1e = 4'h8; end
			8'h1f: d_op = OP_RETI;

			8'h20,8'h21,8'h22,8'h23,8'h24,8'h25,8'h26: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = R8_A; d_mode2 = M_R8; d_r2e = din[3:0]; end
			8'h27: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = R8_A; d_mode2 = M_MI16; d_m2bytes = 2'd1; end
			8'h28,8'h29,8'h2a,8'h2b,8'h2c,8'h2d,8'h2e: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = 4'(din - 8'h28); d_mode2 = M_R8; d_r2e = R8_A; end
			8'h2f: begin d_op = OP_LD; d_mode1 = M_MI16; d_m1bytes = 2'd1; d_mode2 = M_R8; d_r2e = R8_A; end

			8'h30,8'h31,8'h32,8'h33,8'h34,8'h35,8'h36: begin d_op = OP_LD; d_mode1 = M_R8; d_r1e = 4'(din - 8'h30); d_mode2 = M_I8; d_m2bytes = 2'd1; end
			8'h37: begin d_op = OP_LD; d_mode1 = M_MI16; d_m1bytes = 2'd1; d_mode2 = M_I8; d_m2bytes = 2'd1; end
			8'h38,8'h39,8'h3a,8'h3c,8'h3d,8'h3e: begin d_op = OP_LD; d_wide = 1'b1; d_mode1 = M_R16; d_r1e = 4'(din - 8'h38); d_mode2 = M_I16; d_m2bytes = 2'd2; end
			// LDW ($FF00+w),mn — reuses OP_LD (MAME's own execute() merges
			// "case LDW:" and "case LD|OP_16:" into the identical
			// Write1_16(Read2_16()) path, tlcs90.cpp:1497-1499, so no new
			// opcode is needed). mode1 mirrors DECX/0x0f's own ($FF00+n)
			// M_MI16/m1bytes=1 encoding. Missing here entirely (reference:
			// tlcs90.cpp:419-420) — same silent-fallthrough class as above.
			8'h3f: begin d_op = OP_LD; d_wide = 1'b1; d_mode1 = M_MI16; d_m1bytes = 2'd1; d_mode2 = M_I16; d_m2bytes = 2'd2; end

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

			// SWI: the base table's own last byte, 0xff — not part of the
			// PFX_G8 group above (that's only 0xf8-0xfe). No operands
			// (mode1/mode2 stay M_NONE); see the OP_SWI execute block for
			// the dispatch itself.
			8'hff: d_op = OP_SWI;

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
	// Real per-instruction cycle cost — see docs/tier2-tlcs90.md's
	// "TLCS-90 cycle-timing fix" for the full derivation. Table
	// extracted directly from mame/src/devices/cpu/tlcs90/tlcs90.cpp's
	// own OP()/OPCC()/OP16()/OPCC16() macro table (CT*2 = real clock
	// cycles; conditional entries use the branch-taken result via the
	// same test_cc() the EXECUTE stage itself uses).
	//
	// DJNZ's own not-taken cost (0x18/0x19 below) is a deliberate
	// exception to "look it up in this table": the reference's own
	// `OP(DJNZ,10)` (tlcs90.cpp:379/381) only ever sets `m_cyc_t` —
	// `m_cyc_f` (the not-taken cost `Cyc_f()` charges when the branch
	// isn't taken, tlcs90.cpp:2023-2029) is genuinely STATEFUL: it's
	// whatever the most recently-executed `OPCC`-class instruction
	// (any conditional/unconditional JP/CALL/RET/JR-cc form, or INCX/
	// DECX/the LDI-family) last set it to, since `m_cyc_t`/`m_cyc_f`
	// are reset to 0 exactly once at machine reset
	// (tlcs90.cpp:3025) and never per-instruction otherwise. `cyc_f_in`
	// (the FSM's own `cyc_f_reg`, updated at every `OPCC`-class decode
	// — see `is_opcc` below and its two update sites in the FSM) is
	// this same stateful value, threaded in here so DJNZ's own table
	// entry can borrow it exactly like the reference does. Found via
	// macross's own protection-MCU firmware: a hot 3-instruction poll
	// loop whose preceding `JR cc,+d` leaves a small `m_cyc_f` that a
	// trailing `DJNZ`'s own not-taken exit then reused — this project's
	// RTL previously charged a flat, always-taken-shaped cost instead,
	// a genuine but previously low-impact gap (already flagged as a
	// known residual in the original TLCS-90 cycle-timing fix) that
	// compounded heavily in that specific hot loop.
	// ------------------------------------------------------------------
	function automatic is_opcc(input [3:0] p, input [7:0] s);
		is_opcc = (s[7:4] == 4'hc) || (s[7:4] == 4'hd)
		        || (p == PFX_NONE && (s == 8'h07 || s == 8'h0f || s == 8'h1a || s == 8'h1b || s == 8'h1c || s == 8'h1e))
		        || (p == PFX_G8   && s[7:3] == 5'b01011); // 0x58-0x5f, LDI-family
	endfunction

	function automatic [5:0] instr_cycles(input [3:0] p, input [7:0] s, input taken, input [5:0] cyc_f_in);
		reg [5:0] cyc;
		begin
			cyc = 6'd4; // fallback for any (pfx,selector) combination not in the table below
			case (p)
				PFX_NONE: casez (s)
				8'h00: cyc = 6'd4;
				8'h01: cyc = 6'd8;
				8'h02: cyc = 6'd4;
				8'h03: cyc = 6'd4;
				8'h07: cyc = taken ? 6'd20 : 6'd12;
				8'h08: cyc = 6'd4;
				8'h09: cyc = 6'd4;
				8'h0a: cyc = 6'd4;
				8'h0b: cyc = 6'd4;
				8'h0c: cyc = 6'd4;
				8'h0d: cyc = 6'd4;
				8'h0e: cyc = 6'd4;
				8'h0f: cyc = taken ? 6'd20 : 6'd12;
				8'h10: cyc = 6'd4;
				8'h11: cyc = 6'd4;
				8'h12, 8'h13: cyc = 6'd32;
				8'h14, 8'h15, 8'h16: cyc = 6'd12;
				8'h17: cyc = 6'd16;
				8'h18: cyc = taken ? 6'd20 : cyc_f_in;
				8'h19: cyc = taken ? 6'd20 : cyc_f_in;
				8'h1a: cyc = 6'd16;
				8'h1b: cyc = 6'd20;
				8'h1c: cyc = 6'd28;
				8'h1d: cyc = 6'd32;
				8'h1e: cyc = 6'd20;
				8'h1f: cyc = 6'd28;
				8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26: cyc = 6'd4;
				8'h27: cyc = 6'd16;
				8'h28, 8'h29, 8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2e: cyc = 6'd4;
				8'h2f: cyc = 6'd16;
				8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36: cyc = 6'd8;
				8'h37: cyc = 6'd20;
				8'h38, 8'h39, 8'h3a, 8'h3c, 8'h3d, 8'h3e: cyc = 6'd12;
				8'h3f: cyc = 6'd28;
				8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46: cyc = 6'd8;
				8'h47: cyc = 6'd20;
				8'h48, 8'h49, 8'h4a, 8'h4c, 8'h4d, 8'h4e: cyc = 6'd8;
				8'h4f: cyc = 6'd20;
				8'h50, 8'h51, 8'h52, 8'h54, 8'h55, 8'h56: cyc = 6'd16;
				8'h58, 8'h59, 8'h5a, 8'h5c, 8'h5d, 8'h5e: cyc = 6'd20;
				8'h60, 8'h61, 8'h62, 8'h63, 8'h64, 8'h65, 8'h66, 8'h67: cyc = 6'd16;
				8'h68, 8'h69, 8'h6a, 8'h6b, 8'h6c, 8'h6d, 8'h6e, 8'h6f: cyc = 6'd8;
				8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77: cyc = 6'd20;
				8'h78, 8'h79, 8'h7a, 8'h7b, 8'h7c, 8'h7d, 8'h7e, 8'h7f: cyc = 6'd12;
				8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h85, 8'h86: cyc = 6'd4;
				8'h87: cyc = 6'd20;
				8'h88, 8'h89, 8'h8a, 8'h8b, 8'h8c, 8'h8d, 8'h8e: cyc = 6'd4;
				8'h8f: cyc = 6'd20;
				8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96: cyc = 6'd8;
				8'h97: cyc = 6'd28;
				8'h98, 8'h99, 8'h9a, 8'h9b, 8'h9c, 8'h9d, 8'h9e: cyc = 6'd8;
				8'h9f: cyc = 6'd28;
				8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7: cyc = 6'd4;
				8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had, 8'hae, 8'haf: cyc = 6'd16;
				8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5, 8'hb6, 8'hb7: cyc = 6'd24;
				8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd, 8'hbe, 8'hbf: cyc = 6'd24;
				8'hc0, 8'hc1, 8'hc2, 8'hc3, 8'hc4, 8'hc5, 8'hc6, 8'hc7, 8'hc8, 8'hc9, 8'hca, 8'hcb, 8'hcc, 8'hcd, 8'hce, 8'hcf: cyc = taken ? 6'd16 : 6'd8;
				8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5, 8'hd6, 8'hd7, 8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd, 8'hde, 8'hdf: cyc = taken ? 6'd28 : 6'd12;
				8'hff: cyc = 6'd40;
					default: ;
				endcase
				PFX_GG_SRC: casez (s)
				8'h10, 8'h11: cyc = 6'd24;
				8'h12, 8'h13: cyc = 6'd36;
				8'h14, 8'h15, 8'h16: cyc = 6'd16;
				8'h28, 8'h29, 8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2e: cyc = 6'd12;
				8'h48, 8'h49, 8'h4a, 8'h4c, 8'h4d, 8'h4e: cyc = 6'd16;
				8'h50, 8'h51, 8'h52, 8'h54, 8'h55, 8'h56: cyc = 6'd28;
				8'h60, 8'h61, 8'h62, 8'h63, 8'h64, 8'h65, 8'h66, 8'h67: cyc = 6'd12;
				8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77: cyc = 6'd16;
				8'h87: cyc = 6'd16;
				8'h8f: cyc = 6'd16;
				8'h97: cyc = 6'd24;
				8'h9f: cyc = 6'd24;
				8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7: cyc = 6'd16;
				8'h18, 8'h19, 8'h1a, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f: cyc = 6'd24;
				8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had, 8'hae, 8'haf: cyc = 6'd12;
				8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5, 8'hb6, 8'hb7: cyc = 6'd20;
				8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd, 8'hbe, 8'hbf: cyc = 6'd20;
					default: ;
				endcase
				PFX_MN_SRC: casez (s)
				8'h10, 8'h11: cyc = 6'd32;
				8'h12, 8'h13: cyc = 6'd44;
				8'h14, 8'h15, 8'h16: cyc = 6'd24;
				8'h28, 8'h29, 8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2e: cyc = 6'd20;
				8'h48, 8'h49, 8'h4a, 8'h4c, 8'h4d, 8'h4e: cyc = 6'd24;
				8'h50, 8'h51, 8'h52, 8'h54, 8'h55, 8'h56: cyc = 6'd36;
				8'h60, 8'h61, 8'h62, 8'h63, 8'h64, 8'h65, 8'h66, 8'h67: cyc = 6'd20;
				8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77: cyc = 6'd24;
				8'h87: cyc = 6'd24;
				8'h8f: cyc = 6'd24;
				8'h97: cyc = 6'd32;
				8'h9f: cyc = 6'd32;
				8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7: cyc = 6'd24;
				8'h18, 8'h19, 8'h1a, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f: cyc = 6'd32;
				8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had, 8'hae, 8'haf: cyc = 6'd20;
				8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5, 8'hb6, 8'hb7: cyc = 6'd28;
				8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd, 8'hbe, 8'hbf: cyc = 6'd28;
					default: ;
				endcase
				PFX_FF_SRC: casez (s)
				8'h10, 8'h11: cyc = 6'd28;
				8'h12, 8'h13: cyc = 6'd40;
				8'h14, 8'h15, 8'h16: cyc = 6'd20;
				8'h18, 8'h19, 8'h1a, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f: cyc = 6'd28;
				8'h28, 8'h29, 8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2e: cyc = 6'd16;
				8'h48, 8'h49, 8'h4a, 8'h4c, 8'h4d, 8'h4e: cyc = 6'd20;
				8'h50, 8'h51, 8'h52, 8'h54, 8'h55, 8'h56: cyc = 6'd32;
				8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7: cyc = 6'd20;
					default: ;
				endcase
				PFX_GG_DST: casez (s)
				8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26: cyc = 6'd12;
				8'h37: cyc = 6'd16;
				8'h3f: cyc = 6'd24;
				8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46: cyc = 6'd16;
				8'h68, 8'h69, 8'h6a, 8'h6b, 8'h6c, 8'h6d, 8'h6e: cyc = 6'd20;
				8'h6f: cyc = 6'd16;
				8'hc0, 8'hc1, 8'hc2, 8'hc3, 8'hc4, 8'hc5, 8'hc6, 8'hc7, 8'hc8, 8'hc9, 8'hca, 8'hcb, 8'hcc, 8'hcd, 8'hce, 8'hcf: cyc = taken ? 6'd16 : 6'd12;
				8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5, 8'hd6, 8'hd7, 8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd, 8'hde, 8'hdf: cyc = taken ? 6'd28 : 6'd12;
					default: ;
				endcase
				PFX_MN_DST: casez (s)
				8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26: cyc = 6'd20;
				8'h37: cyc = 6'd24;
				8'h3f: cyc = 6'd32;
				8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46: cyc = 6'd24;
				8'h68, 8'h69, 8'h6a, 8'h6b, 8'h6c, 8'h6d, 8'h6e: cyc = 6'd28;
				8'h6f: cyc = 6'd24;
				8'hc0, 8'hc1, 8'hc2, 8'hc3, 8'hc4, 8'hc5, 8'hc6, 8'hc7, 8'hc8, 8'hc9, 8'hca, 8'hcb, 8'hcc, 8'hcd, 8'hce, 8'hcf: cyc = taken ? 6'd24 : 6'd20;
				8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5, 8'hd6, 8'hd7, 8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd, 8'hde, 8'hdf: cyc = taken ? 6'd36 : 6'd20;
					default: ;
				endcase
				PFX_FF_DST: casez (s)
				8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26: cyc = 6'd16;
				8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46: cyc = 6'd20;
				8'h68, 8'h69, 8'h6a, 8'h6b, 8'h6c, 8'h6d, 8'h6e: cyc = 6'd24;
				8'h6f: cyc = 6'd20;
					default: ;
				endcase
				PFX_IXD_SRC: casez (s)
				8'h10, 8'h11: cyc = 6'd32;
				8'h12, 8'h13: cyc = 6'd44;
				8'h14, 8'h15, 8'h16: cyc = 6'd24;
				8'h28, 8'h29, 8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2e: cyc = 6'd20;
				8'h48, 8'h49, 8'h4a, 8'h4c, 8'h4d, 8'h4e: cyc = 6'd24;
				8'h50, 8'h51, 8'h52, 8'h54, 8'h55, 8'h56: cyc = 6'd36;
				8'h60, 8'h61, 8'h62, 8'h63, 8'h64, 8'h65, 8'h66, 8'h67: cyc = 6'd20;
				8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77: cyc = 6'd24;
				8'h87: cyc = 6'd24;
				8'h8f: cyc = 6'd24;
				8'h97: cyc = 6'd32;
				8'h9f: cyc = 6'd32;
				8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7: cyc = 6'd24;
				8'h18, 8'h19, 8'h1a, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f: cyc = 6'd32;
				8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had, 8'hae, 8'haf: cyc = 6'd20;
				8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5, 8'hb6, 8'hb7: cyc = 6'd28;
				8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd, 8'hbe, 8'hbf: cyc = 6'd28;
					default: ;
				endcase
				PFX_HLA_SRC: casez (s)
				8'h10, 8'h11: cyc = 6'd40;
				8'h12, 8'h13: cyc = 6'd52;
				8'h14, 8'h15, 8'h16: cyc = 6'd32;
				8'h28, 8'h29, 8'h2a, 8'h2b, 8'h2c, 8'h2d, 8'h2e: cyc = 6'd28;
				8'h48, 8'h49, 8'h4a, 8'h4c, 8'h4d, 8'h4e: cyc = 6'd32;
				8'h50, 8'h51, 8'h52, 8'h54, 8'h55, 8'h56: cyc = 6'd44;
				8'h60, 8'h61, 8'h62, 8'h63, 8'h64, 8'h65, 8'h66, 8'h67: cyc = 6'd28;
				8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77: cyc = 6'd32;
				8'h87: cyc = 6'd32;
				8'h8f: cyc = 6'd32;
				8'h97: cyc = 6'd40;
				8'h9f: cyc = 6'd40;
				8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7: cyc = 6'd32;
				8'h18, 8'h19, 8'h1a, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f: cyc = 6'd40;
				8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had, 8'hae, 8'haf: cyc = 6'd28;
				8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5, 8'hb6, 8'hb7: cyc = 6'd36;
				8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd, 8'hbe, 8'hbf: cyc = 6'd36;
					default: ;
				endcase
				PFX_IXD_DST: casez (s)
				8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26: cyc = 6'd20;
				8'h37: cyc = 6'd24;
				8'h38, 8'h39, 8'h3a, 8'h3b, 8'h3c, 8'h3d, 8'h3e: cyc = 6'd20;
				8'h3f: cyc = 6'd32;
				8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46: cyc = 6'd24;
				8'h68, 8'h69, 8'h6a, 8'h6b, 8'h6c, 8'h6d, 8'h6e: cyc = 6'd28;
				8'h6f: cyc = 6'd24;
				8'hc0, 8'hc1, 8'hc2, 8'hc3, 8'hc4, 8'hc5, 8'hc6, 8'hc7, 8'hc8, 8'hc9, 8'hca, 8'hcb, 8'hcc, 8'hcd, 8'hce, 8'hcf: cyc = taken ? 6'd24 : 6'd20;
				8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5, 8'hd6, 8'hd7, 8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd, 8'hde, 8'hdf: cyc = taken ? 6'd36 : 6'd20;
					default: ;
				endcase
				PFX_HLA_DST: casez (s)
				8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26: cyc = 6'd28;
				8'h37: cyc = 6'd32;
				8'h38, 8'h39, 8'h3a, 8'h3b, 8'h3c, 8'h3d, 8'h3e: cyc = 6'd28;
				8'h3f: cyc = 6'd40;
				8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46: cyc = 6'd32;
				8'h68, 8'h69, 8'h6a, 8'h6b, 8'h6c, 8'h6d, 8'h6e: cyc = 6'd36;
				8'h6f: cyc = 6'd32;
				8'hc0, 8'hc1, 8'hc2, 8'hc3, 8'hc4, 8'hc5, 8'hc6, 8'hc7, 8'hc8, 8'hc9, 8'hca, 8'hcb, 8'hcc, 8'hcd, 8'hce, 8'hcf: cyc = taken ? 6'd32 : 6'd28;
				8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5, 8'hd6, 8'hd7, 8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd, 8'hde, 8'hdf: cyc = taken ? 6'd44 : 6'd28;
					default: ;
				endcase
				PFX_G8: casez (s)
				8'h12, 8'h13: cyc = 6'd36;
				8'h14, 8'h15, 8'h16: cyc = 6'd16;
				8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36: cyc = 6'd8;
				8'h38, 8'h39, 8'h3a, 8'h3c, 8'h3d, 8'h3e: cyc = 6'd12;
				8'h58, 8'h59, 8'h5a, 8'h5b, 8'h5c, 8'h5d, 8'h5e, 8'h5f: cyc = taken ? 6'd36 : 6'd28;
				8'h60, 8'h61, 8'h62, 8'h63, 8'h64, 8'h65, 8'h66, 8'h67: cyc = 6'd8;
				8'h68, 8'h69, 8'h6a, 8'h6b, 8'h6c, 8'h6d, 8'h6e, 8'h6f: cyc = 6'd12;
				8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77: cyc = 6'd16;
				8'ha0, 8'ha1, 8'ha2, 8'ha3, 8'ha4, 8'ha5, 8'ha6, 8'ha7: cyc = 6'd8;
				8'h18, 8'h19, 8'h1a, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f: cyc = 6'd16;
				8'ha8, 8'ha9, 8'haa, 8'hab, 8'hac, 8'had, 8'hae, 8'haf: cyc = 6'd8;
				8'hb0, 8'hb1, 8'hb2, 8'hb3, 8'hb4, 8'hb5, 8'hb6, 8'hb7: cyc = 6'd8;
				8'hb8, 8'hb9, 8'hba, 8'hbb, 8'hbc, 8'hbd, 8'hbe, 8'hbf: cyc = 6'd8;
				8'hd0, 8'hd1, 8'hd2, 8'hd3, 8'hd4, 8'hd5, 8'hd6, 8'hd7, 8'hd8, 8'hd9, 8'hda, 8'hdb, 8'hdc, 8'hdd, 8'hde, 8'hdf: cyc = taken ? 6'd28 : 6'd12;
					default: ;
				endcase
				default: ;
			endcase
			instr_cycles = cyc;
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
	reg       d2_needs_i16; // two more immediate bytes follow the selector (DST-side LDW (mem),mn)

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
		d2_mem_slot = 2'd2; d2_needs_i8 = 1'b0; d2_needs_i16 = 1'b0;

		if (pfx == PFX_G8) begin
			// Register-to-register forms: `gg` (from the b0 embedding, see
			// level-1 decode above) is a plain register-select code here —
			// R8 or R16 depending on the case, never a memory address —
			// filled into whichever slot d2_mem_slot picks by the same
			// S_PFX_SEL logic the other prefix groups already use (see the
			// PFX_G8 addition to that fill condition).
			casez (din)
				// MUL/DIV — mode1 is always R16(HL) (constant, not
				// gg-derived), mode2 is R8(g) where g==gg (the base
				// opcode's own embedded register code), filled in
				// automatically by the same PFX_G8 r2<-gg fill logic
				// mem_slot=2 already triggers for the ADD-family/LD
				// arms below (no d2_r2e needed). Valid for any b0
				// (unlike the block-transfer/RET-cc-2 arms further
				// down, which require b0==0xfe specifically).
				8'h12: begin d2_op = OP_MUL; d2_mode1 = M_R16; d2_r1e = R16_HL; d2_mode2 = M_R8; d2_mem_slot = 2'd2; end
				8'h13: begin d2_op = OP_DIV; d2_mode1 = M_R16; d2_r1e = R16_HL; d2_mode2 = M_R8; d2_mem_slot = 2'd2; end
				// ADD ix,gg — register-register form (mode2=R16(gg) filled
				// automatically by the same mem_slot=2 fill logic MUL/DIV
				// above already rely on). Confirmed used directly by
				// tdragon1's own protection-MCU firmware (found via a ROM
				// byte-pattern scan after the base-level ADD ix,mn fix).
				8'h14, 8'h15, 8'h16: begin
					d2_op = OP_ADD; d2_wide = 1'b1;
					d2_mode1 = M_R16; d2_r1e = R16_IX + 4'(din - 8'h14);
					d2_mode2 = M_R16; d2_mem_slot = 2'd2;
				end
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
				// LDI/LDIR/LDD/LDDR/CPI/CPIR/CPD/CPDR — same b0==0xfe gate
				// as RET cc above. mode1=M_MR16 with r1 forced to R16_HL
				// (not gg — the reference always reads/writes through HL/DE
				// specifically for this group, never the b0-encoded
				// register) reuses the existing S_PRE_READ1 pipeline to
				// fetch RM8(HL) into val1 for free; mode2 stays M_NONE
				// since there's no second bus operand (DE is a destination
				// EXECUTE writes directly, not a decoded operand slot —
				// see the OP_LDI*/OP_CPI* execute block).
				8'h58,8'h59,8'h5a,8'h5b,8'h5c,8'h5d,8'h5e,8'h5f: begin
					if (gg == R16_SP) begin
						d2_op = OP_LDI + 6'(din - 8'h58);
						d2_mode1 = M_MR16; d2_r1e = R16_HL; d2_mem_slot = 2'd2;
					end else d2_op = OP_UNKNOWN;
				end
				default: d2_op = OP_UNKNOWN;
			endcase
		end else if (pfx_is_src) begin
			casez (din)
				// RLD/RRD — reachable via every SRC prefix group ((gg),
				// (mn), ($FF00+n), (ix+d)/(iy+d), (HL+A)), never the base
				// table. mode2 stays M_NONE (A isn't a decoded operand
				// slot here — EXECUTE reads/writes it directly, same
				// reasoning as LDI*/CPI*'s DE).
				8'h10: begin d2_op = OP_RLD; d2_mode1 = mem_mode; d2_mem_slot = 2'd1; end
				8'h11: begin d2_op = OP_RRD; d2_mode1 = mem_mode; d2_mem_slot = 2'd1; end
				// MUL/DIV HL,(mem) and ADD ix,(mem) — the memory-operand
				// forms of the PFX_G8 register cases above, reachable via
				// every SRC prefix group ((gg),(mn),($FF00+n),(ix+d)/(iy+d),
				// (HL+A)). Confirmed used directly by tdragon1's own
				// protection-MCU firmware and the shared NMK004 boot ROM
				// (found via a ROM byte-pattern scan after the base-level
				// ADD ix,mn fix).
				8'h12: begin d2_op = OP_MUL; d2_mode1 = M_R16; d2_r1e = R16_HL; d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'h13: begin d2_op = OP_DIV; d2_mode1 = M_R16; d2_r1e = R16_HL; d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'h14, 8'h15, 8'h16: begin
					d2_op = OP_ADD; d2_wide = 1'b1;
					d2_mode1 = M_R16; d2_r1e = R16_IX + 4'(din - 8'h14);
					d2_mode2 = mem_mode; d2_mem_slot = 2'd2;
				end
				8'h28,8'h29,8'h2a,8'h2b,8'h2c,8'h2d,8'h2e: begin
					d2_op = OP_LD; d2_mode1 = M_R8; d2_r1e = 4'(din - 8'h28); d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				8'h48,8'h49,8'h4a,8'h4c,8'h4d,8'h4e: begin
					d2_op = OP_LD; d2_wide = 1'b1; d2_mode1 = M_R16; d2_r1e = 4'(din - 8'h48); d2_mode2 = mem_mode; d2_mem_slot = 2'd2; end
				// EX (gg)/(mn)/($FF00+n)/(ix+d)/(iy+d)/(HL+A),rr — the
				// memory-operand forms of EX (register-only EX lives in
				// the base table, opcodes 0x08/0x09). Unlike every other
				// entry in this table, the memory operand sits in slot 1
				// here (mem_slot=1), matching the reference's own
				// MR16(1,...)/R16(2,...) ordering — a genuine 16-bit
				// swap, not a one-way copy, so there's no natural
				// "source"/"destination" side to match LD's convention.
				8'h50,8'h51,8'h52,8'h54,8'h55,8'h56: begin
					d2_op = OP_EX; d2_wide = 1'b1; d2_mode1 = mem_mode; d2_mode2 = M_R16; d2_r2e = 4'(din - 8'h50); d2_mem_slot = 2'd1; end
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
				// LDW (mem),mn — reuses OP_LD same as the base-level 0x3f
				// form above (MAME merges LDW into LD|OP_16's own execute
				// case). Needs a genuine 16-bit immediate fetch after the
				// selector byte, which no other DST-group entry has needed
				// before now — see d2_needs_i16 and its S_PFX_SEL handling
				// (reuses the existing base-level S_M2_BYTE1/2 states).
				8'h3f: begin
					d2_op = OP_LD; d2_wide = 1'b1; d2_mode1 = mem_mode; d2_mode2 = M_I16;
					d2_mem_slot = 2'd1; d2_needs_i16 = 1'b1;
				end
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
		S_PFX_DISP    = 21,
		// Interrupt entry: PC is pushed the same way OP_CALL already
		// pushes it (low byte at entry, high byte at S_PUSH_HI, reused
		// via the irq_taking flag), then these two push AF the same way,
		// using AF's value from *before* IF gets cleared (matching the
		// reference's Push(PC); Push(AF); F&=~IF order exactly — IF is
		// only cleared once AF has already been captured/pushed).
		S_IRQ_PUSH2_LO = 22, S_IRQ_PUSH2_HI = 23;

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
	reg        irq_taking;  // this S_PUSH_HI visit is interrupt entry (push PC then AF), not a plain PUSH/CALL

	// ------------------------------------------------------------------
	// Real per-instruction cycle-timing — see instr_cycles()'s own header
	// below for the full derivation. `sel_byte` mirrors the reference's
	// own "b0" (base-table opcode byte) or "b1"/"b2"/"b3" (prefixed
	// groups' operation-selector byte) — whichever one determines cost,
	// latched at the exact same point op/mode1/mode2 already are.
	// `target_cyc` is the real clock-cycle count this instruction should
	// take (instr_cycles()'s own output, latched once at that same
	// point); `cyc_elapsed` counts cycles since this instruction's own
	// real S_FETCH_OP fetch, checked back against target_cyc there to
	// pad the difference before the next real fetch.
	// ------------------------------------------------------------------
	reg [7:0] sel_byte;
	reg [5:0] target_cyc;
	reg [5:0] cyc_elapsed;

	// DJNZ's own not-taken cost borrows this — see instr_cycles()'s own
	// header for the full derivation. Mirrors the reference's `m_cyc_f`:
	// reset to 0 exactly once (never per-instruction), updated only at
	// an `OPCC`-class instruction's own decode (both update sites use
	// `instr_cycles(..., taken=1'b0, ...)`, i.e. that opcode's own
	// not-taken/CF-derived cost — always well-defined here since
	// `is_opcc` only ever gates opcodes this table already has a real
	// entry for).
	reg [5:0] cyc_f_reg;

	// ------------------------------------------------------------------
	// Interrupt state: NMI edge-latch and the 11 maskable sources'
	// pending-request latches (see take_interrupt()/check_interrupts() in
	// the reference — clear_irq() on take, except INT0 in level mode,
	// which isn't modeled yet since nothing drives INT0 in this milestone
	// anyway). Priority is scan order low-to-high bit index, matching
	// INTSWI+3..INTSWI+13 exactly (see the port comment above).
	// ------------------------------------------------------------------
	reg        nmi_prev, nmi_pending;
	reg [10:0] irq_pending;

	// Lowest-set-bit priority encode over (irq_pending & irq_mask); valid
	// only checked when the result is nonzero.
	function automatic [3:0] irq_prio_idx(input [10:0] req);
		integer i;
		begin
			irq_prio_idx = 4'd0;
			for (i = 10; i >= 0; i = i - 1)
				if (req[i]) irq_prio_idx = i[3:0];
		end
	endfunction

	// Effective bus address for a memory-mode operand: M_MI16 already
	// holds the resolved address directly in r1/r2 (short-address, direct
	// 16-bit, or the prefix-group's resolved mn/ff/ixd address); M_MR16
	// holds a register-pair *code* instead, resolved through the register
	// file.
	wire [15:0] eff1 = (mode1 == M_MR16) ? r16_read(r1[3:0]) : r1;
	wire [15:0] eff2 = (mode2 == M_MR16) ? r16_read(r2[3:0]) : r2;

	// Bank nibble for eff1/eff2 — see module header's "IX/IY bank
	// extension" note. Two cases produce an IX/IY-based address:
	//   - mode==M_MR16 with the register code itself (r1[3:0]/r2[3:0])
	//     equal to R16_IX/R16_IY (the "(gg)" prefix groups, no
	//     displacement) — mirrors eff1/eff2's own mode/register check.
	//   - mode==M_MI16 but the address was actually resolved by an
	//     IXD_SRC/IXD_DST prefix (0xf0-0xf6, "(ix+d)"/"(iy+d)"/"(sp+d)")
	//     with its own base register (`gg`, latched once at prefix decode
	//     and stable for the rest of the instruction) equal to R16_IX/
	//     R16_IY — `gg`==R16_SP falls through to bank 0, matching the
	//     reference (SP+d is never banked). A genuine M_MI16 direct/short
	//     address (MN/FF prefixes, or the base table's own direct forms)
	//     never matches either IXD prefix check, so it correctly stays
	//     bank 0 too — this is what distinguishes "really M_MI16" from
	//     "M_MI16 because that's how a resolved IXD address is tagged"
	//     without needing a separate mode enum for the latter.
	wire ixd_pfx = (pfx == PFX_IXD_SRC) || (pfx == PFX_IXD_DST);
	wire [3:0] bank1 =
		(mode1 == M_MR16 && r1[3:0] == R16_IX[3:0]) ? ix_bank :
		(mode1 == M_MR16 && r1[3:0] == R16_IY[3:0]) ? iy_bank :
		(mode1 == M_MI16 && ixd_pfx && gg == R16_IX[3:0]) ? ix_bank :
		(mode1 == M_MI16 && ixd_pfx && gg == R16_IY[3:0]) ? iy_bank :
		4'h0;
	wire [3:0] bank2 =
		(mode2 == M_MR16 && r2[3:0] == R16_IX[3:0]) ? ix_bank :
		(mode2 == M_MR16 && r2[3:0] == R16_IY[3:0]) ? iy_bank :
		(mode2 == M_MI16 && ixd_pfx && gg == R16_IX[3:0]) ? ix_bank :
		(mode2 == M_MI16 && ixd_pfx && gg == R16_IY[3:0]) ? iy_bank :
		4'h0;

	function automatic mode_needs_read(input [3:0] m);
		mode_needs_read = (m == M_MI16) || (m == M_MR16);
	endfunction
	function automatic op_reads_m1(input [5:0] o);
		case (o)
			// OP_EX is deliberately NOT here: the base-table register-only
			// forms never need it (mode1 is M_R16, and mode_needs_read()
			// already gates M_R16 out regardless of this table), but the
			// memory-operand forms (EX (gg)/(mn)/...,rr) genuinely need to
			// read the memory word before overwriting it — the swap can't
			// happen otherwise. Defaulting to "reads" is correct for both
			// cases at once, so no case-by-case distinction is needed here.
			OP_LD, OP_JP, OP_JR, OP_CALL, OP_RET, OP_PUSH, OP_POP,
			OP_DJNZ, OP_BIT, OP_SET, OP_RES, OP_EXX, OP_NOP,
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

	wire [10:0] irq_active = irq_pending & irq_mask;
	wire        irq_any    = nmi_pending | (|irq_active);
	wire [3:0]  irq_idx    = irq_prio_idx(irq_active);
	// vector = 0x10 + (irq_idx+3)*8, i.e. INT0(idx0)->0x28 .. INTTX(idx10)->0x78;
	// NMI is the fixed INTNMI vector (0x10+1*8).
	wire [15:0] irq_vector = nmi_pending ? 16'h0018 : (16'h0010 + (({12'h0,irq_idx} + 16'd3) << 3));

	always @(posedge clk) begin
		mem_rd <= 1'b0;
		mem_wr <= 1'b0;
		addr_bank <= 4'h0;
		dbg_valid <= 1'b0;

		// Free-running cycle counter for the padding check in S_FETCH_OP
		// below — overridden there (to 6'd1) on the one cycle a real
		// fetch actually happens, so this default increment only ever
		// takes effect on every *other* cycle.
		cyc_elapsed <= cyc_elapsed + 6'd1;

		// Interrupt request latching: level-sensitive but internally held
		// pending until dispatched (matches raise_irq()'s m_irq_state bit
		// staying set until clear_irq() — see the S_FETCH_OP dispatch
		// clearing the taken source's bit below, which lands *after* this
		// assignment in program order and so correctly wins for that one
		// bit on the same edge if both happen to coincide).
		nmi_prev <= nmi;
		if (nmi && !nmi_prev) nmi_pending <= 1'b1;
		irq_pending <= irq_pending | irq_req;

		if (reset) begin
			state <= S_FETCH_OP;
			pc <= 16'h0000;
			f <= 8'h00;
			halt_r <= 1'b0;
			after_ei <= 1'b0;
			nmi_pending <= 1'b0;
			irq_pending <= 11'd0;
			irq_taking <= 1'b0;
			cyc_elapsed <= 6'd0;
			target_cyc <= 6'd0;
			cyc_f_reg <= 6'd0;
		end else begin
			case (state)
				// ------------------------------------------------------
				S_FETCH_OP: begin
					// Real per-instruction cycle-timing pad: hold here
					// (doing nothing else — dbg_valid stays 0, no bus
					// activity, no interrupt/halt check) until the
					// *previous* instruction has consumed its own real
					// target_cyc cycle count, matching the reference's
					// per-opcode timing (see instr_cycles()'s own header).
					// cyc_elapsed's default free-running increment (top of
					// this always block) already advances it every cycle
					// spent here; only the real-work branch below needs to
					// reset it, for the instruction about to begin.
					if (cyc_elapsed < target_cyc) begin
						// padding — cyc_elapsed's generic increment above
						// already applies this cycle, nothing else to do.
					end else begin
					cyc_elapsed <= 6'd1; // this cycle is the new instruction's own cycle 1
					if (op != OP_EI && after_ei) begin
						f[IFB] <= 1'b1;
						after_ei <= 1'b0;
					end
					// Interrupt dispatch, checked once per instruction
					// boundary exactly like the reference's
					// check_interrupts() — gated by IF for everything
					// here (NMI included; SWI is the only source that
					// bypasses this, and it's a synchronous opcode, not
					// modeled as an external request). Push PC now (AF
					// follows via S_PUSH_HI's irq_taking chain, using its
					// pre-IF-clear value); IF itself isn't cleared until
					// S_IRQ_PUSH2_HI, after AF has been captured.
					if (f[IFB] && irq_any) begin
						halt_r <= 1'b0; // leave_halt()
						if (nmi_pending) nmi_pending <= 1'b0;
						else irq_pending[irq_idx] <= 1'b0;
						push_val <= pc;
						sp <= sp - 16'd2;
						addr <= sp - 16'd2; dout <= pc[7:0]; mem_wr <= 1'b1;
						pc <= irq_vector;
						irq_taking <= 1'b1;
						state <= S_PUSH_HI;
					end else if (halt_r) begin
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
						// `pfx` is otherwise only written on the prefixed
						// path below, so without this it would keep holding
						// a *previous* instruction's prefix kind here — a
						// real bug found via tb_banktest.cpp: a base-table
						// direct-address write immediately after an
						// IX-relative access spuriously inherited that
						// access's bank, because bank1/bank2 (see their
						// definition above) key off `pfx`/`gg` to tell a
						// genuine M_MI16 direct address apart from an
						// IXD-prefix-resolved one, and both are stored in
						// the same mode1/mode2 tag.
						pfx <= PFX_NONE;
						sel_byte <= din;
						// DJNZ (0x18/0x19) is NOT a flag-based conditional —
						// test_cc()'s own d_r1e-keyed lookup is meaningless
						// for it (0x19's own d_r1e even holds R16_BC, a
						// register-select code, not a condition-code
						// nibble). Its own "will branch" outcome is whether
						// the live `bc`/`bc[15:8]` register is nonzero
						// *after* decrementing — the same live register the
						// OP_DJNZ execute block itself (further below)
						// re-derives independently; mirrored here, read-
						// only, purely so instr_cycles()'s own taken-cost
						// table entry for 0x18/0x19 picks the right branch.
						target_cyc <= instr_cycles(PFX_NONE, din,
							(din == 8'h18) ? ((bc[15:8] - 8'd1) != 8'd0) :
							(din == 8'h19) ? ((bc - 16'd1) != 16'd0) :
							test_cc(d_r1e[3:0], f), cyc_f_reg);
						if (is_opcc(PFX_NONE, din)) cyc_f_reg <= instr_cycles(PFX_NONE, din, 1'b0, cyc_f_reg);
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
					// d2_r1e always holds the raw condition-code nibble
					// whenever d2_mode1==M_CC (true for every JP/JR/CALL/RET
					// cc form, regardless of which slot it ends up in below)
					// — safe to test unconditionally here.
					sel_byte <= din;
					target_cyc <= instr_cycles(pfx, din, test_cc(d2_r1e[3:0], f), cyc_f_reg);
					if (is_opcc(pfx, din)) cyc_f_reg <= instr_cycles(pfx, din, 1'b0, cyc_f_reg);
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
					end else if (d2_needs_i16) begin
						// LDW (mem),mn's trailing 16-bit immediate — reuses
						// the base-level S_M2_BYTE1/S_M2_BYTE2 states
						// verbatim (they already write the fetched value
						// into r2 generically, exactly what mode2==M_I16
						// needs here too).
						addr <= pc; mem_rd <= 1'b1; pc <= pc + 16'd1;
						m2bytes_left <= 2'd2;
						state <= S_M2_BYTE1;
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
						addr <= eff1; addr_bank <= bank1; mem_rd <= 1'b1;
						state <= S_READ1_LO;
					end else begin
						val1 <= !op_reads_m1(op) ? r1 : (mode1 == M_R8) ? {8'h00, r8_read(r1[2:0])} : (mode1 == M_R16) ? r16_read(r1[3:0]) : r1;
						state <= S_PRE_READ2;
					end
				end
				S_READ1_LO: begin
					if (wide) begin
						byte_lo <= din;
						addr <= eff1 + 16'd1; addr_bank <= bank1; mem_rd <= 1'b1;
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
						addr <= eff2; addr_bank <= bank2; mem_rd <= 1'b1;
						state <= S_READ2_LO;
					end else begin
						if (mode2 != M_NONE) val2 <= (mode2 == M_R8) ? {8'h00, r8_read(r2[2:0])} : (mode2 == M_R16) ? r16_read(r2[3:0]) : r2;
						state <= S_EXECUTE;
					end
				end
				S_READ2_LO: begin
					if (wide) begin
						byte_lo <= din;
						addr <= eff2 + 16'd1; addr_bank <= bank2; mem_rd <= 1'b1;
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
							if (mode1 == M_R16) begin
								// base-table register-only forms
								if (r1[3:0] == R16_DE) begin
									de <= hl; hl <= de;
								end else begin // AF <-> AF2
									{a, f} <= r16_read(R16_AF2);
									{a2, f2} <= {a, f};
								end
							end else begin
								// M_MI16/M_MR16: memory-operand form — a
								// genuine 16-bit swap. val1 already holds
								// the pre-read memory word (op_reads_m1
								// defaults true for OP_EX now, specifically
								// so this read happens); write val2 (rr's
								// current value) back to that same address
								// (eff1/bank1 still valid, unchanged since
								// the read) via the same wb_val/S_WRITE1_HI
								// wide-write chain OP_LD's memory
								// destination already uses, while val1
								// lands in rr the same cycle.
								wb_val <= val2;
								addr <= eff1; addr_bank <= bank1; dout <= val2[7:0]; mem_wr <= 1'b1;
								state <= S_WRITE1_HI;
								r16_write_reg(r2[3:0], val1);
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
								addr <= eff1; addr_bank <= bank1; dout <= val2[7:0]; mem_wr <= 1'b1;
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
						// `wide` (set only by the base table's 0x1b) picks
						// the 16-bit M_D16 form (raw value reads as -1, no
						// sign-extension needed — it's already 16 bits)
						// over the existing 8-bit sign-extended-
						// displacement form the 0xc0-0xcf opcodes use.
						OP_JR: if (test_cc(r1[3:0], f))
							pc <= wide ? (pc + val2 - 16'd1) : (pc + {{8{val2[7]}}, val2[7:0]});
						OP_CALL: if (test_cc(r1[3:0], f)) begin
							push_val <= pc;
							sp <= sp - 16'd2;
							addr <= sp - 16'd2; dout <= pc[7:0]; mem_wr <= 1'b1;
							pc <= val2;
							state <= S_PUSH_HI;
						end
						// CALLR +cd: unconditional push+jump, identical
						// mechanics to OP_CALL, but the target is
						// PC-relative (M_D16, raw-1) rather than an
						// absolute M_I16 address.
						OP_CALLR: begin
							push_val <= pc;
							sp <= sp - 16'd2;
							addr <= sp - 16'd2; dout <= pc[7:0]; mem_wr <= 1'b1;
							pc <= pc + val2 - 16'd1;
							state <= S_PUSH_HI;
						end
						// LDAR HL,+cd: no bus access, no flags — a single
						// register write.
						OP_LDAR: hl <= pc + val2 - 16'd1;
						// SWI: reuses the exact same push-PC-then-AF,
						// clear-IF-after-AF-captured chain the S_FETCH_OP
						// interrupt dispatch already builds (irq_taking
						// gates S_PUSH_HI into pushing AF next, then
						// S_IRQ_PUSH2_HI clears f[IFB]) — this is
						// identical machinery, just entered synchronously
						// from EXECUTE instead of the per-instruction
						// dispatch check, with the vector fixed at
						// INTSWI's own 0x0010 rather than a
						// priority-scanned one.
						OP_SWI: begin
							push_val <= pc;
							sp <= sp - 16'd2;
							addr <= sp - 16'd2; dout <= pc[7:0]; mem_wr <= 1'b1;
							pc <= 16'h0010;
							irq_taking <= 1'b1;
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
							addr <= eff2; addr_bank <= bank2;
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
								else begin wb_val <= {8'h00,r8v}; addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
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
								else begin wb_val <= {8'h00,r8v}; addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
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
								addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1;
							end
						end
						OP_DECX: begin : decx_blk
							reg [7:0] r8v;
							if (f[XCF]) begin
								r8v = val1[7:0] - 8'd1;
								f <= (f & ((8'd1<<IFB)|(8'd1<<CF))) | szhv_dec8(r8v);
								addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1;
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
							addr <= eff1; addr_bank <= bank1; dout <= r16v[7:0]; mem_wr <= 1'b1;
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
							addr <= eff1; addr_bank <= bank1; dout <= r16v[7:0]; mem_wr <= 1'b1;
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
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
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
									else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
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
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
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
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
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
								else if (mode1 == M_MI16 || mode1 == M_MR16) begin addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
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
							else begin addr <= eff1; addr_bank <= bank1; dout <= r8v; mem_wr <= 1'b1; end
						end

						// val1 already holds RM8(HL) (fetched via mode1=
						// M_MR16/r1=R16_HL through the normal read pipeline
						// — see the level-2 decode above). Write it straight
						// to (DE) here: DE is never IX/IY-banked, matching
						// the reference's WM8 (never routed through WX8), so
						// addr_bank is forced to 0. LDIR/LDDR's repeat is a
						// literal `pc -= 2` re-fetch of this same 2-byte
						// instruction (opcode 0xfe + selector byte), exactly
						// mirroring the reference's own `m_pc.w.l -= 2`
						// rather than looping internally — the next
						// S_FETCH_OP naturally redecodes and re-executes it.
						OP_LDI, OP_LDIR, OP_LDD, OP_LDDR: begin : ldblk_blk
							reg [15:0] bc_new;
							addr <= de; addr_bank <= 4'h0; dout <= val1[7:0]; mem_wr <= 1'b1;
							if (op == OP_LDI || op == OP_LDIR) begin de <= de + 16'd1; hl <= hl + 16'd1; end
							else begin de <= de - 16'd1; hl <= hl - 16'd1; end
							bc_new = bc - 16'd1;
							bc <= bc_new;
							f <= (f & ((8'd1<<SF)|(8'd1<<ZF)|(8'd1<<IFB)|(8'd1<<XCF)|(8'd1<<CF))) |
							     (bc_new != 16'd0 ? (8'd1<<PF) : 8'h00);
							if ((op == OP_LDIR || op == OP_LDDR) && bc_new != 16'd0) pc <= pc - 16'd2;
						end

						// Same val1=RM8(HL) source as above, but compare-only
						// (like CP: A-val1, no writeback) — HL still
						// increments/decrements and BC still counts down,
						// but nothing is written to memory. CPIR/CPDR's
						// repeat additionally requires a mismatch (b8!=0),
						// unlike LDIR/LDDR which always repeats until BC==0.
						OP_CPI, OP_CPIR, OP_CPD, OP_CPDR: begin : cpblk_blk
							reg [8:0] d9; reg [7:0] b8; reg [15:0] bc_new;
							d9 = {1'b0,a} - {1'b0,val1[7:0]};
							b8 = d9[7:0];
							if (op == OP_CPI || op == OP_CPIR) hl <= hl + 16'd1;
							else hl <= hl - 16'd1;
							bc_new = bc - 16'd1;
							bc <= bc_new;
							f <= (f & ((8'd1<<IFB)|(8'd1<<CF))) | sz8(b8) |
							     ((a ^ val1[7:0] ^ b8) & (8'd1<<HF)) | (8'd1<<NF) |
							     (bc_new != 16'd0 ? (8'd1<<PF) : 8'h00);
							if ((op == OP_CPIR || op == OP_CPDR) && bc_new != 16'd0 && b8 != 8'h00) pc <= pc - 16'd2;
						end

						// val1 holds the pre-fetched memory byte (see the
						// pfx_is_src level-2 decode above); A isn't a
						// decoded operand here (there's no room for a
						// second `M_R8` slot alongside the memory one in
						// this group's own selector-byte encoding), so
						// EXECUTE reads/writes it directly, mirroring the
						// reference's own m_af.b.h access. RLD rotates the
						// 12-bit {A_lo,M_hi,M_lo} unit left by one nibble;
						// RRD rotates it right — both write the new memory
						// byte back to the SAME address val1 was read from
						// (mode1/eff1/bank1 all still valid, unchanged
						// since the read) and load the new A.
						OP_RLD: begin : rld_blk
							reg [7:0] m8, newa;
							m8 = val1[7:0];
							newa = {a[7:4], m8[7:4]};
							addr <= eff1; addr_bank <= bank1; dout <= {m8[3:0], a[3:0]}; mem_wr <= 1'b1;
							a <= newa;
							f <= (f & ((8'd1<<IFB)|(8'd1<<CF))) | szp8(newa);
						end
						OP_RRD: begin : rrd_blk
							reg [7:0] m8, newa;
							m8 = val1[7:0];
							newa = {a[7:4], m8[3:0]};
							addr <= eff1; addr_bank <= bank1; dout <= {a[3:0], m8[7:4]}; mem_wr <= 1'b1;
							a <= newa;
							f <= (f & ((8'd1<<IFB)|(8'd1<<CF))) | szp8(newa);
						end

						// MUL: HL = L(old HL) * g (unsigned 8x8->16), no
						// flags touched at all (reference has no F=...
						// line for this op — confirmed by direct reading,
						// not an oversight). val1[7:0] already IS L, since
						// val1 = r16_read(HL) via mode1=M_R16's normal
						// register-read path (see S_PRE_READ1).
						OP_MUL: hl <= {8'h00,val1[7:0]} * {8'h00,val2[7:0]};

						// DIV: HL/g -> H=remainder, L=quotient (truncated
						// to 8 bits if it overflows); only PF/VF is
						// touched (set when the quotient doesn't fit in 8
						// bits, or unconditionally on divide-by-zero) —
						// every other flag bit is left exactly as it was,
						// matching the reference's `F |= VF`/`F &= ~VF`
						// (never a full `F = ...` reassignment here).
						// Divide-by-zero doesn't divide at all: HL becomes
						// {old L, ~old H} per the reference's literal
						// `(a16<<8) | ((a16>>8)^0xff)` formula.
						OP_DIV: begin : div_blk
							reg [15:0] hlv, divisor, quot, rem;
							hlv = val1;
							divisor = {8'h00, val2[7:0]};
							if (divisor == 16'd0) begin
								f[PF] <= 1'b1;
								hl <= {hlv[7:0], ~hlv[15:8]};
							end else begin
								quot = hlv / divisor;
								rem  = hlv % divisor;
								hl <= {rem[7:0], quot[7:0]};
								f[PF] <= (quot > 16'd255);
							end
						end

						default: ; // OP_UNKNOWN: no-op, treated as a bug marker for the testbench to catch via dbg_pc stall
					endcase
				end

				S_WRITE1_HI: begin
					addr <= eff1 + 16'd1; addr_bank <= bank1; dout <= wb_val[15:8]; mem_wr <= 1'b1;
					state <= S_FETCH_OP;
				end

				S_PUSH_HI: begin
					addr <= sp + 16'd1; dout <= push_val[15:8]; mem_wr <= 1'b1;
					if (irq_taking) begin
						irq_taking <= 1'b0;
						push_val <= {a, f}; // pre-IF-clear value, matching Push(AF) before F&=~IF in the reference
						sp <= sp - 16'd2;
						state <= S_IRQ_PUSH2_LO;
					end else begin
						state <= S_FETCH_OP;
					end
				end
				S_IRQ_PUSH2_LO: begin
					addr <= sp; dout <= push_val[7:0]; mem_wr <= 1'b1;
					state <= S_IRQ_PUSH2_HI;
				end
				S_IRQ_PUSH2_HI: begin
					addr <= sp + 16'd1; dout <= push_val[15:8]; mem_wr <= 1'b1;
					f[IFB] <= 1'b0;
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
