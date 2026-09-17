// Video output PLL for the Gunnail and Afega rbfs: one 48 MHz output
// from the 50 MHz reference, 50 * 24/25 (VCO 1200 MHz). 48 MHz divides
// to both pixel rates these rbfs' games use with integer enables — 8 MHz
// (48/6, gunnail: 512 px @ 16 MHz/2) and 6 MHz (48/8, the nine lowres
// boards: 384 px @ 12 MHz/2) — for rtl/video_retime.sv. A copy of
// rtl/pll_video.v (56 MHz, the Macross2 rbf) with the multiplier
// changed; see that file.
//
// NMK-27: raising this to 96 MHz was TRIED and REVERTED on 2026-09-16.
// The theory was that sys/video_mixer.sv needs CLK_VIDEO to be an integer
// multiple of ce_pix*4, and 48/(8*4) = 1.5 explained HQ2X coming out
// 597 px wide instead of 768 on the 384-wide games. 96 MHz makes BOTH
// rates integral (96/32 = 3, 96/24 = 4) and both cores still closed
// timing (Gunnail +0.428, Afega +0.321) -- but gunnail measured 597 px
// again, so the clock ratio is NOT the cause. Do not retry this.

module pll_video48
(
	input  refclk,
	input  rst,
	output outclk_0,
	output locked
);
	wire [4:0] sub_wire0;
	wire       locked_out;
	assign outclk_0 = sub_wire0[0];
	assign locked   = locked_out;

	altpll #(
		.bandwidth_type("AUTO"),
		.clk0_divide_by(25),
		.clk0_duty_cycle(50),
		.clk0_multiply_by(24),
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
		.port_clk1("PORT_UNUSED"),
		.port_clk2("PORT_UNUSED"),
		.port_clk3("PORT_UNUSED"),
		.port_clk4("PORT_UNUSED"),
		.port_clk5("PORT_UNUSED"),
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
