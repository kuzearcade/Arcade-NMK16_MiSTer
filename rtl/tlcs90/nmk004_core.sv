// NMK004 sound board — TLCS-90 CPU + on-chip peripherals + memory map,
// per nmk004_device::mem_map / tmp90840_mem in the reference (see
// docs/tier2-tlcs90.md "Memory map"). This is the CPU-side half of the
// real NMK004 board; YM2203/OKIM6295x2/host-handshake are exposed as
// plain external ports for a future system-level wrapper to connect real
// jt12/jt6295 cores and the 68000 host, rather than stubbed internally —
// unlike the peripheral registers (see nmk004_periph.sv), these aren't
// this core's own state, so stubbing them here would just be moving the
// eventual real wiring one level down for no benefit.
//
// Memory map:
//   0x0000-0x1fff  internal boot ROM (nmk004.bin, shared across every
//                  NMK004 game — see docs/tier2-tlcs90.md "ROMs")
//   0x2000-0xefff  external per-game program ROM
//   0xf000-0xf7ff  external work RAM (2KB)
//   0xf800-0xf801  YM2203 address/data (external port, not this module's state)
//   0xf900         OKIM6295 #1 (external port)
//   0xfa00         OKIM6295 #2 (external port)
//   0xfb00         read latch from 68000 host (external port: host_to_mcu)
//   0xfc00         write latch to 68000 host (external port: mcu_to_host + strobe)
//   0xfc01/0xfc02  OKI #1/#2 bankswitch (external ports)
//   0xfec0-0xffbf  internal RAM (256B)
//   0xffc0-0xffef  on-chip peripherals (nmk004_periph.sv)
module nmk004_core #(
	parameter BOOT_ROM_FILE = "",
	parameter EXT_ROM_FILE  = "",
	// USE_CEN=1: advance the CPU/peripherals only on `cen` (the wrapper
	// runs this on clk_sys with an 8 MHz enable it may withhold while a
	// ROM fetch is outstanding — raphero_core.sv's TLCS-90 pattern).
	// USE_CEN=0 (every sim wrapper): `cen` is ignored, clk is the real
	// divided CPU clock as before.
	parameter USE_CEN = 0,
	// ROM_EXTERNAL=1: the boot + external program ROMs are NOT the
	// $readmemh arrays below but come through rom_addr/rom_din (a cache
	// over SDRAM in the hardware core); rom_ready must be high when
	// rom_din is valid for rom_addr — the wrapper withholds cen otherwise.
	parameter ROM_EXTERNAL = 0
) (
	input clk,
	input cen,
	input reset,

	// ROM_EXTERNAL=1 only — see above. rom_addr is the CPU's 16-bit
	// address (0x0000-0x1FFF boot ROM, 0x2000-0xEFFF external program);
	// rom_rd is high for the whole read cycle.
	output [15:0] rom_addr,
	output        rom_rd,
	input  [7:0]  rom_din,
	input         rom_ready,
	output        rom_stall,   // rom_rd & ~rom_ready: the wrapper gates cen with this

	input nmi,

	// YM2203 — address/data on the low byte of 0xf800/0xf801, matching
	// the reference's ym_r/ym_w(offset) exactly (offset 0=addr,1=data).
	output       ym_cs,
	output       ym_we,
	output       ym_addr_sel, // 0 = address port (0xf800), 1 = data port (0xf801)
	output [7:0] ym_dout,
	input  [7:0] ym_din,
	// YM2203's own IRQ (active-low, matching the chip's real convention and
	// a real core's own irq_n output) — the reference's
	// ym2203_irq_handler() routes this straight to the CPU's INT0 line
	// (set_input_line(0,...)), so it's OR'd into irq_req bit0 here rather
	// than exposed as a separate CPU input; nmk004_periph's own irq_req
	// output never drives bit0 itself (INT0 has no internal NMK004
	// peripheral source), so there's no conflict to arbitrate.
	input        ym_irq_n,

	// OKIM6295 x2
	output       oki0_cs, oki0_we,
	output [7:0] oki0_dout,
	input  [7:0] oki0_din,
	output       oki1_cs, oki1_we,
	output [7:0] oki1_dout,
	input  [7:0] oki1_din,
	output       oki0_bank_we,
	output [7:0] oki0_bank,
	output       oki1_bank_we,
	output [7:0] oki1_bank,

	// 68000 host handshake (nmk004_device::read/write)
	input  [7:0] host_to_mcu,
	output [7:0] mcu_to_host,
	output       mcu_to_host_we,

	output [15:0] dbg_pc,
	output        dbg_valid,

	// debug: live register state + a direct peek at internal RAM[dbg_hl] —
	// purely additive, for root-causing oracle divergences against MAME's
	// own debugger register/memory readout (see docs/tier2-system.md,
	// "RET Z at 0x0E5F"). dbg_ram_hl is only meaningful while dbg_hl falls
	// in the internal-RAM window (0xfec0-0xffbf); that's the only range
	// this investigation needs.
	output [7:0]  dbg_a,
	output [7:0]  dbg_f,
	output [15:0] dbg_hl,
	output [7:0]  dbg_ram_hl,
	output [15:0] dbg_de,
	output [15:0] dbg_bc,
	output [15:0] dbg_ix,
	output [15:0] dbg_iy,
	output [15:0] dbg_sp,

	// P4 bit0 = future 68000-reset drive (nmk004_device::port4_w in the
	// reference). BX/BY exposed for debug visibility; the same values are
	// also wired internally into the CPU core's ix_bank/iy_bank inputs
	// (see "Address decode" below).
	output [7:0] p4,
	output [3:0] bx, by,

	// Savestates (2026-09-18). ss_freeze parks the CPU at its next
	// instruction boundary and stops the peripheral timers; ss_frozen
	// reports it. While frozen, ss_addr selects one 16-bit word of the
	// whole device state, readable combinationally and writable with a
	// one-clk ss_wr pulse:
	//   0x000-0x3FF  external RAM (0xF000-0xF7FF), little-endian pairs
	//   0x400-0x47F  internal RAM (0xFEC0-0xFFBF), little-endian pairs
	//   0x480-0x49F  CPU registers (tlcs90.sv word map)
	//   0x4A0-0x4BF  peripheral registers (nmk004_periph.sv word map)
	// Everything else reads 0 and ignores writes. Outside a freeze the
	// bus is inert (ss_wr is ignored).
	input         ss_freeze,
	output        ss_frozen,
	input  [11:0] ss_addr,
	input         ss_wr,
	input  [15:0] ss_wdata,
	output [15:0] ss_rdata
);

	wire ss_wr_f = ss_wr & ss_frozen;
	wire ss_ext  = (ss_addr[11:10] == 2'b00);
	wire ss_int  = (ss_addr[11:7] == 5'b01000);
	wire ss_cpu  = (ss_addr[11:5] == 7'b0100100);
	wire ss_per  = (ss_addr[11:5] == 7'b0100101);
	wire [15:0] ss_cpu_rdata, ss_per_rdata;

	// ------------------------------------------------------------------
	// CPU
	// ------------------------------------------------------------------
	wire [7:0]  cpu_din;
	wire [7:0]  cpu_dout;
	wire [15:0] cpu_addr;
	wire [3:0]  cpu_addr_bank;
	wire        cpu_mem_rd, cpu_mem_wr;
	wire [10:0] irq_mask, irq_req_periph;
	// bit0 (INT0) is OR'd in from YM2203's own irq_n here — see the port
	// comment above. nmk004_periph's own irq_req_r never drives bit0
	// itself, so this is additive, not a real arbitration.
	wire [10:0] irq_req_to_cpu = {irq_req_periph[10:1], irq_req_periph[0] | ~ym_irq_n};

	wire cen_eff = USE_CEN ? cen : 1'b1;
	tlcs90 cpu (
		.clk(clk), .cen(cen_eff), .reset(reset),
		.din(cpu_din), .dout(cpu_dout), .addr(cpu_addr), .addr_bank(cpu_addr_bank),
		.mem_rd(cpu_mem_rd), .mem_wr(cpu_mem_wr),
		.nmi(nmi), .irq_req(irq_req_to_cpu), .irq_mask(irq_mask),
		.ix_bank(bx), .iy_bank(by),
		.dbg_pc(dbg_pc), .dbg_valid(dbg_valid), .dbg_halt(),
		.dbg_a(dbg_a), .dbg_f(dbg_f), .dbg_hl(dbg_hl), .dbg_de(dbg_de), .dbg_iy(dbg_iy),
		.dbg_bc(dbg_bc), .dbg_ix(dbg_ix), .dbg_sp(dbg_sp),
		.ss_freeze(ss_freeze), .ss_frozen(ss_frozen),
		.ss_sel(ss_addr[4:0]), .ss_wr(ss_wr_f & ss_cpu), .ss_wdata(ss_wdata), .ss_rdata(ss_cpu_rdata)
	);

	// ------------------------------------------------------------------
	// Address decode
	// ------------------------------------------------------------------
	// Every region below is bank 0 in the real 20-bit address space
	// IX/IY-based addressing can reach (see tlcs90.sv's "IX/IY bank
	// extension" note) — boot ROM, external ROM/RAM, peripherals, and the
	// host/YM/OKI latches are all sized and placed within the low 64KB,
	// matching every currently-known NMK004 game (external programs top
	// out around 56KB, well under 64KB, and the verified boot trace always
	// leaves BX/BY at their reset value of 0). A nonzero bank access is
	// therefore real (the CPU core computes it correctly, matching the
	// reference's bitwise-OR semantics) but currently reaches genuinely
	// unmapped space — falls through the read mux's default 0 below, and
	// every sel_* write-enable is gated off — rather than aliasing on top
	// of bank 0. If a game is ever identified that legitimately banks
	// beyond 64KB, this is where a real >64KB-backed region would be
	// added, gated on cpu_addr_bank instead of being dropped.
	wire bank0        = (cpu_addr_bank == 4'h0);
	wire sel_boot_rom = bank0 && (cpu_addr <= 16'h1fff);
	wire sel_ext_rom  = bank0 && (cpu_addr >= 16'h2000) && (cpu_addr <= 16'hefff);
	wire sel_ext_ram  = bank0 && (cpu_addr >= 16'hf000) && (cpu_addr <= 16'hf7ff);
	wire sel_ym       = bank0 && ((cpu_addr == 16'hf800) || (cpu_addr == 16'hf801));
	wire sel_oki0     = bank0 && (cpu_addr == 16'hf900);
	wire sel_oki1     = bank0 && (cpu_addr == 16'hfa00);
	wire sel_host_r   = bank0 && (cpu_addr == 16'hfb00);
	wire sel_host_w   = bank0 && (cpu_addr == 16'hfc00);
	wire sel_oki0bank = bank0 && (cpu_addr == 16'hfc01);
	wire sel_oki1bank = bank0 && (cpu_addr == 16'hfc02);
	wire sel_int_ram  = bank0 && (cpu_addr >= 16'hfec0) && (cpu_addr <= 16'hffbf);
	wire sel_periph   = bank0 && (cpu_addr >= 16'hffc0) && (cpu_addr <= 16'hffef);

	// ------------------------------------------------------------------
	// ROMs
	// ------------------------------------------------------------------
	wire [7:0] boot_rom_byte, ext_rom_byte;
	assign rom_addr  = cpu_addr;
	assign rom_rd    = (sel_boot_rom | sel_ext_rom) & cpu_mem_rd;
	assign rom_stall = ROM_EXTERNAL ? (rom_rd & ~rom_ready) : 1'b0;
	generate
	if (!ROM_EXTERNAL) begin : g_rom_int
		reg [7:0] boot_rom [0:8191];
		reg [7:0] ext_rom  [0:65535];
		initial if (BOOT_ROM_FILE != "") $readmemh(BOOT_ROM_FILE, boot_rom);
		initial if (EXT_ROM_FILE  != "") $readmemh(EXT_ROM_FILE,  ext_rom);
		assign boot_rom_byte = boot_rom[cpu_addr[12:0]];
		assign ext_rom_byte  = ext_rom[cpu_addr];
	end else begin : g_rom_ext
		assign boot_rom_byte = rom_din;
		assign ext_rom_byte  = rom_din;
	end
	endgenerate

	// ------------------------------------------------------------------
	// RAMs
	// ------------------------------------------------------------------
	// Writes are taken on the enabled edge that ends the CPU's write
	// cycle (with USE_CEN=0, cen_eff is 1 and this is the old per-clk
	// write). Reads stay combinational: with USE_CEN=1 the wrapper's
	// clk_sys is at least 5x the CPU clock, so a 2 KB / 256 B array read
	// settles long before the enabled edge (block RAM inference for these
	// small arrays is not needed).
	reg [7:0] ext_ram [0:2047];
	reg [7:0] int_ram [0:255];
	// Both arrays are flops (asynchronous reads), so every extra read or
	// write port is another 2048:1 mux / decoder -- the savestate engine
	// therefore SHARES the CPU's one port (the CPU is frozen whenever the
	// engine uses it): reads alternate even/odd bytes into a holding pair
	// inside the engine's 3-clock read window, the odd byte of a write is
	// done one clock after the even one (the engine's writes are >= 4
	// clocks apart). Adding true second ports cost ~13,000 ALUTs on the
	// NMK16_Gunnail rbf and the design no longer fit (2026-09-18).
	reg        ss_ph = 1'b0;
	reg        ss_wr_d = 1'b0, ss_ext_d = 1'b0, ss_int_d = 1'b0;
	reg [10:0] ss_addr_d;
	reg [7:0]  ss_wdata_hi_d;
	reg [7:0]  ext_qe, ext_qo, int_qe, int_qo;
	always @(posedge clk) begin
		ss_ph <= ~ss_ph;
		ss_wr_d <= ss_wr_f; ss_ext_d <= ss_ext; ss_int_d <= ss_int;
		ss_addr_d <= ss_addr[10:0]; ss_wdata_hi_d <= ss_wdata[15:8];
	end
	wire        ext_we = ss_frozen ? ((ss_wr_f & ss_ext) | (ss_wr_d & ss_ext_d)) : (cpu_mem_wr && sel_ext_ram && cen_eff);
	wire [10:0] ext_wa = ss_frozen ? (ss_wr_d ? {ss_addr_d[9:0], 1'b1} : {ss_addr[9:0], 1'b0}) : cpu_addr[10:0];
	wire [7:0]  ext_wd = ss_frozen ? (ss_wr_d ? ss_wdata_hi_d : ss_wdata[7:0]) : cpu_dout;
	wire [10:0] ext_ra = ss_frozen ? {ss_addr[9:0], ss_ph} : cpu_addr[10:0];
	// USE_CEN=1 (hardware): the read address is REGISTERED so Quartus keeps
	// the arrays in M10K (a read through a combinational address mux turned
	// both into flops, +14k ALMs, and NMK16_Gunnail no longer fit). The CPU
	// samples din >= 5 clk after presenting the address, so one clock of
	// address latency is invisible to it; the savestate capture below
	// tracks the delayed lane bit. USE_CEN=0 (sims): clk is the CPU clock,
	// the read stays combinational as it always was.
	wire [10:0] ext_ra_q;
	wire [7:0]  int_ra_q;
	wire        ss_ph_q;
	generate
	if (USE_CEN) begin : g_ram_ra_reg
		reg [10:0] ext_ra_r; reg [7:0] int_ra_r; reg ss_ph_r;
		always @(posedge clk) begin ext_ra_r <= ext_ra; int_ra_r <= int_ra; ss_ph_r <= ss_ph; end
		assign ext_ra_q = ext_ra_r; assign int_ra_q = int_ra_r; assign ss_ph_q = ss_ph_r;
	end else begin : g_ram_ra_comb
		assign ext_ra_q = ext_ra; assign int_ra_q = int_ra; assign ss_ph_q = ss_ph;
	end
	endgenerate
	wire [7:0]  ext_rd = ext_ram[ext_ra_q];
	wire        int_we = ss_frozen ? ((ss_wr_f & ss_int) | (ss_wr_d & ss_int_d)) : (cpu_mem_wr && sel_int_ram && cen_eff);
	wire [7:0]  int_wa = ss_frozen ? (ss_wr_d ? {ss_addr_d[6:0], 1'b1} : {ss_addr[6:0], 1'b0}) : cpu_addr[7:0];
	wire [7:0]  int_wd = ss_frozen ? (ss_wr_d ? ss_wdata_hi_d : ss_wdata[7:0]) : cpu_dout;
	wire [7:0]  int_ra = ss_frozen ? {ss_addr[6:0], ss_ph} : cpu_addr[7:0];
	wire [7:0]  int_rd = int_ram[int_ra_q];
	always @(posedge clk) begin
		if (ext_we) ext_ram[ext_wa] <= ext_wd;
		if (int_we) int_ram[int_wa] <= int_wd;
		if (ss_ph_q) begin ext_qo <= ext_rd; int_qo <= int_rd; end
		else         begin ext_qe <= ext_rd; int_qe <= int_rd; end
	end
	assign ss_rdata = ss_ext ? {ext_qo, ext_qe} :
	                  ss_int ? {int_qo, int_qe} :
	                  ss_cpu ? ss_cpu_rdata :
	                  ss_per ? ss_per_rdata : 16'h0000;
	assign dbg_ram_hl = int_ram[dbg_hl[7:0]];

	// ------------------------------------------------------------------
	// Host handshake / YM / OKI glue
	// ------------------------------------------------------------------
	assign ym_cs = sel_ym;
	assign ym_we = sel_ym & cpu_mem_wr;
	assign ym_addr_sel = cpu_addr[0];
	assign ym_dout = cpu_dout;

	assign oki0_cs = sel_oki0; assign oki0_we = sel_oki0 & cpu_mem_wr; assign oki0_dout = cpu_dout;
	assign oki1_cs = sel_oki1; assign oki1_we = sel_oki1 & cpu_mem_wr; assign oki1_dout = cpu_dout;
	assign oki0_bank_we = sel_oki0bank & cpu_mem_wr; assign oki0_bank = cpu_dout;
	assign oki1_bank_we = sel_oki1bank & cpu_mem_wr; assign oki1_bank = cpu_dout;

	assign mcu_to_host = cpu_dout;
	assign mcu_to_host_we = sel_host_w & cpu_mem_wr;

	// ------------------------------------------------------------------
	// Peripherals
	// ------------------------------------------------------------------
	wire [7:0] periph_rdata;

	nmk004_periph periph (
		.clk(clk), .cen(cen_eff & ~ss_frozen), .reset(reset), // timers stop while frozen
		.reg_addr(cpu_addr[5:0]),
		.wdata(cpu_dout),
		.we(sel_periph & cpu_mem_wr),
		.re(sel_periph & cpu_mem_rd),
		.rdata(periph_rdata),
		.irq_mask(irq_mask), .irq_req(irq_req_periph),
		.p4_latch(p4), .bx(bx), .by(by),
		// P5/P6 external-read override — not this role, see nmk004_periph.sv's header.
		.p5_ext_en(1'b0), .p5_ext_val(8'h00),
		.p6_ext_en(1'b0), .p6_ext_val(8'h00),
		.p6_we(), .p6_wdata(),
		.p7_ext_en(1'b0), .p7_ext_val(8'h00),
		.p3_we(), .p3_wdata(), .p7_we(), .p7_wdata(),
		.ss_wr(ss_wr_f & ss_per), .ss_sel(ss_addr[4:0]), .ss_wdata(ss_wdata), .ss_rdata(ss_per_rdata)
	);

	// ------------------------------------------------------------------
	// Read mux
	// ------------------------------------------------------------------
	reg [7:0] rdata;
	always @(*) begin
		if (sel_boot_rom)      rdata = boot_rom_byte;
		else if (sel_ext_rom)  rdata = ext_rom_byte;
		else if (sel_ext_ram)  rdata = ext_rd;   // the shared port (savestates), = ext_ram[cpu_addr] while the CPU runs
		else if (sel_int_ram)  rdata = int_rd;
		else if (sel_periph)   rdata = periph_rdata;
		else if (sel_ym)       rdata = ym_din;
		else if (sel_oki0)     rdata = oki0_din;
		else if (sel_oki1)     rdata = oki1_din;
		else if (sel_host_r)   rdata = host_to_mcu;
		else                   rdata = 8'h00;
	end
	assign cpu_din = rdata;

endmodule
