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
	parameter EXT_ROM_FILE  = ""
) (
	input clk,
	input reset,

	input nmi,

	// YM2203 — address/data on the low byte of 0xf800/0xf801, matching
	// the reference's ym_r/ym_w(offset) exactly (offset 0=addr,1=data).
	output       ym_cs,
	output       ym_we,
	output       ym_addr_sel, // 0 = address port (0xf800), 1 = data port (0xf801)
	output [7:0] ym_dout,
	input  [7:0] ym_din,

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

	// P4 bit0 = future 68000-reset drive (nmk004_device::port4_w in the
	// reference); BX/BY exposed for future IX/IY-banking debug/wiring.
	// Not consumed by anything yet — see nmk004_periph.sv's header.
	output [7:0] p4,
	output [3:0] bx, by
);

	// ------------------------------------------------------------------
	// CPU
	// ------------------------------------------------------------------
	wire [7:0]  cpu_din;
	wire [7:0]  cpu_dout;
	wire [15:0] cpu_addr;
	wire        cpu_mem_rd, cpu_mem_wr;
	wire [10:0] irq_mask, irq_req;

	tlcs90 cpu (
		.clk(clk), .reset(reset),
		.din(cpu_din), .dout(cpu_dout), .addr(cpu_addr),
		.mem_rd(cpu_mem_rd), .mem_wr(cpu_mem_wr),
		.nmi(nmi), .irq_req(irq_req), .irq_mask(irq_mask),
		.dbg_pc(dbg_pc), .dbg_valid(dbg_valid), .dbg_halt()
	);

	// ------------------------------------------------------------------
	// Address decode
	// ------------------------------------------------------------------
	wire sel_boot_rom = (cpu_addr <= 16'h1fff);
	wire sel_ext_rom  = (cpu_addr >= 16'h2000) && (cpu_addr <= 16'hefff);
	wire sel_ext_ram  = (cpu_addr >= 16'hf000) && (cpu_addr <= 16'hf7ff);
	wire sel_ym       = (cpu_addr == 16'hf800) || (cpu_addr == 16'hf801);
	wire sel_oki0     = (cpu_addr == 16'hf900);
	wire sel_oki1     = (cpu_addr == 16'hfa00);
	wire sel_host_r   = (cpu_addr == 16'hfb00);
	wire sel_host_w   = (cpu_addr == 16'hfc00);
	wire sel_oki0bank = (cpu_addr == 16'hfc01);
	wire sel_oki1bank = (cpu_addr == 16'hfc02);
	wire sel_int_ram  = (cpu_addr >= 16'hfec0) && (cpu_addr <= 16'hffbf);
	wire sel_periph   = (cpu_addr >= 16'hffc0) && (cpu_addr <= 16'hffef);

	// ------------------------------------------------------------------
	// ROMs
	// ------------------------------------------------------------------
	reg [7:0] boot_rom [0:8191];
	reg [7:0] ext_rom  [0:65535];
	initial if (BOOT_ROM_FILE != "") $readmemh(BOOT_ROM_FILE, boot_rom);
	initial if (EXT_ROM_FILE  != "") $readmemh(EXT_ROM_FILE,  ext_rom);

	// ------------------------------------------------------------------
	// RAMs
	// ------------------------------------------------------------------
	reg [7:0] ext_ram [0:2047];
	reg [7:0] int_ram [0:255];
	always @(posedge clk) if (cpu_mem_wr && sel_ext_ram) ext_ram[cpu_addr[10:0]] <= cpu_dout;
	always @(posedge clk) if (cpu_mem_wr && sel_int_ram) int_ram[cpu_addr[7:0]]  <= cpu_dout;

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
		.clk(clk), .reset(reset),
		.reg_addr(cpu_addr[5:0]),
		.wdata(cpu_dout),
		.we(sel_periph & cpu_mem_wr),
		.re(sel_periph & cpu_mem_rd),
		.rdata(periph_rdata),
		.irq_mask(irq_mask), .irq_req(irq_req),
		.p4_latch(p4), .bx(bx), .by(by)
	);

	// ------------------------------------------------------------------
	// Read mux
	// ------------------------------------------------------------------
	reg [7:0] rdata;
	always @(*) begin
		if (sel_boot_rom)      rdata = boot_rom[cpu_addr[12:0]];
		else if (sel_ext_rom)  rdata = ext_rom[cpu_addr];
		else if (sel_ext_ram)  rdata = ext_ram[cpu_addr[10:0]];
		else if (sel_int_ram)  rdata = int_ram[cpu_addr[7:0]];
		else if (sel_periph)   rdata = periph_rdata;
		else if (sel_ym)       rdata = ym_din;
		else if (sel_oki0)     rdata = oki0_din;
		else if (sel_oki1)     rdata = oki1_din;
		else if (sel_host_r)   rdata = host_to_mcu;
		else                   rdata = 8'h00;
	end
	assign cpu_din = rdata;

endmodule
