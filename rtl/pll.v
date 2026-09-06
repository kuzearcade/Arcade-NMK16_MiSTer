// Hand-written altpll instantiation: CLK_50M (50MHz) -> clk_sys (40MHz),
// a plain 4/5 multiply/divide ratio. The Template.qsf scaffold this
// project inherited from Tier 0 referenced this file but never actually
// generated it (rtl/pll.v/rtl/mycore.v/rtl/cos.sv/rtl/lfsr.v didn't
// exist) — no interactive Quartus GUI is available in this environment
// to run the MegaWizard IP generator, so this is hand-written directly
// against the altpll megafunction's own documented parameter set rather
// than wizard-generated boilerplate. Quartus's own PLL analysis at
// compile time is the authority on whether 4/5 is achievable within the
// Cyclone V 5CSEBA6's real PLL constraints, not a hand-check here.
//
// width_clock MUST be 5: altpll.tdf's own internal implementation
// unconditionally references symbolic names clk1-clk4 regardless of
// this parameter (confirmed directly — width_clock(1) fails fast with
// "Symbolic name clk4 is used but not defined", not slowly). The much
// earlier, genuinely slow (15+ minute) run was something else (most
// likely just real PLL legalization/VCO search taking a while for this
// specific 4/5 ratio) — not a config mismatch, so it's given more time
// to finish this time rather than assumed hung.
module pll
(
	input  refclk,
	input  rst,
	output outclk_0,
	output locked
);

	wire [4:0] sub_wire0;
	wire       clk_out = sub_wire0[0];
	wire       locked_out;

	assign outclk_0 = clk_out;
	assign locked   = locked_out;

	altpll #(
		.bandwidth_type("AUTO"),
		.clk0_divide_by(5),
		.clk0_duty_cycle(50),
		.clk0_multiply_by(4),
		.clk0_phase_shift("0"),
		.compensate_clock("CLK0"),
		.inclk0_input_frequency(20000),
		.intended_device_family("Cyclone V"),
		.lpm_type("altpll"),
		.operation_mode("NORMAL"),
		.pll_type("AUTO"),
		.port_activeclock("PORT_UNUSED"),
		.port_areset("PORT_USED"),
		.port_clkbad0("PORT_UNUSED"),
		.port_clkbad1("PORT_UNUSED"),
		.port_clkloss("PORT_UNUSED"),
		.port_clkswitch("PORT_UNUSED"),
		.port_configupdate("PORT_UNUSED"),
		.port_fbin("PORT_UNUSED"),
		.port_inclk0("PORT_USED"),
		.port_inclk1("PORT_UNUSED"),
		.port_locked("PORT_USED"),
		.port_pfdena("PORT_UNUSED"),
		.port_phasecounterselect("PORT_UNUSED"),
		.port_phasedone("PORT_UNUSED"),
		.port_phasestep("PORT_UNUSED"),
		.port_phaseupdown("PORT_UNUSED"),
		.port_pllena("PORT_UNUSED"),
		.port_scanaclr("PORT_UNUSED"),
		.port_scanclk("PORT_UNUSED"),
		.port_scanclkena("PORT_UNUSED"),
		.port_scandata("PORT_UNUSED"),
		.port_scandataout("PORT_UNUSED"),
		.port_scandone("PORT_UNUSED"),
		.port_scanread("PORT_UNUSED"),
		.port_scanwrite("PORT_UNUSED"),
		.port_clk0("PORT_USED"),
		.width_clock(5)
	) altpll_component (
		.areset(rst),
		.inclk({1'b0, refclk}),
		.clk(sub_wire0),
		.locked(locked_out),
		.activeclock(),
		.clkbad(),
		.clkena(6'b111111),
		.clkloss(),
		.clkswitch(1'b0),
		.configupdate(1'b0),
		.enable0(),
		.enable1(),
		.extclk(),
		.extclkena(4'b1111),
		.fbin(1'b1),
		.fbmimicbidir(),
		.fbout(),
		.fref(),
		.icdrclk(),
		.pfdena(1'b1),
		.phasecounterselect(4'b1111),
		.phasedone(),
		.phasestep(1'b0),
		.phaseupdown(1'b0),
		.pllena(1'b1),
		.scanaclr(1'b0),
		.scanclk(1'b0),
		.scanclkena(1'b1),
		.scandata(1'b0),
		.scandataout(),
		.scandone(),
		.scanread(1'b0),
		.scanwrite(1'b0),
		.sclkout0(),
		.sclkout1(),
		.vcooverrange(),
		.vcounderrange()
	);

endmodule
