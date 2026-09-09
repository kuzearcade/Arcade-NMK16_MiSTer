# The Template.sdc scaffold this project inherited from Tier 0 left this
# file as just derive_pll_clocks/derive_clock_uncertainty with an empty
# "core specific constraints" placeholder — it never actually sourced
# sys/sys_top.sdc, the MiSTer framework's own real base constraints
# (root 50MHz clock definitions, HPS/SPI/HDMI-I2C virtual clocks, the
# exclusive clock-group partitioning that decouples unrelated PLL/clock
# domains from each other, and a large set of false-path exceptions for
# OSD/config/ascal-parameter signals). Without it, derive_pll_clocks had
# no properly-defined root clocks to derive from and Quartus tried to
# time-relate every clock domain against every other one — including
# genuinely unrelated ones — which is what quartus_sta's own "Design is
# not fully constrained" warnings and several bogus-looking negative
# slack paths actually were.
source sys/sys_top.sdc

derive_pll_clocks
derive_clock_uncertainty

# ------------------------------------------------------------------
# core specific constraints
# ------------------------------------------------------------------
# This core's game logic (68000, Z80, video) lives on clk_sys (40MHz)
# and rtl/sdram.sv on clk_ram (96MHz), both outputs of rtl/pll.v's own
# hand-written altpll instance — no interactive Quartus GUI was
# available in this environment to generate the MegaWizard-style
# altera_pll IP that sys/sys_top.sdc's own exclusive-group wildcard
# (*|pll|pll_inst|altera_pll_i|...) expects, so their real hierarchical
# clock names don't match that pattern and never landed in any of
# sys_top.sdc's mutually-exclusive groups. Confirmed directly from a
# real quartus_sta run: clk_sys's actual node name is
# emu|pll|altpll_component|auto_generated|generic_pll1~PLL_OUTPUT_COUNTER|divclk
# (the "auto_generated|generic_pllN" middle segment is Quartus's own
# internal naming and not guaranteed stable across recompiles, hence
# the wildcard) — and it was, unsurprisingly, the single most common
# endpoint across every worst-case slack line quartus_sta reported.
#
# The two PLL outputs MUST each be their own exclusive group, not one
# shared group: they come from one VCO, so a single group would make
# Quartus time every clk_sys<->clk_ram path synchronously against the
# worst-case edge relationship of a 25ns/10.4ns pair (about 2ns, every
# 125ns) — and fail on the addr/din payload paths that the toggle-
# style req/ack protocol (see rtl/sdram.sv's own CDC comment) makes
# deliberately irrelevant: the payload is held stable from the toggle
# until ack, and only sampled after a 2-flop synchronizer has seen the
# toggle. Every matching PLL output gets its own group below, so this
# stays correct whatever Quartus names the second counter.
set core_pll_groups {}
foreach_in_collection c [get_clocks {emu|pll|altpll_component|*PLL_OUTPUT_COUNTER|divclk}] {
	lappend core_pll_groups -group [get_clock_info -name $c]
}
set_clock_groups -exclusive \
	{*}$core_pll_groups \
	-group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {spi_sck}] \
	-group [get_clocks {hdmi_sck}] \
	-group [get_clocks {*|h2f_user0_clk}] \
	-group [get_clocks {FPGA_CLK1_50}] \
	-group [get_clocks {FPGA_CLK2_50}] \
	-group [get_clocks {FPGA_CLK3_50}]

# ------------------------------------------------------------------
# TLCS-90 sound CPU (rtl/tlcs90/tlcs90.sv) and its peripheral block
# (nmk004_periph.sv) run on clk_sys with an 8 MHz clock ENABLE
# (raphero_core.sv's snd_cen, one pulse per 5 clk_sys at most): every
# register in them updates only on those pulses, so register-to-register
# paths inside the pair have 5 clk_sys periods, not one. Without this the
# CPU's execute logic (val2 -> hl etc.) fails by ~10 ns at 40 MHz.
# Paths into and out of the pair (memory/latch data, address decode) are
# left single-cycle.
# ------------------------------------------------------------------
set snd_regs [get_registers {*|raphero_core:core|tlcs90:snd_cpu|* *|raphero_core:core|nmk004_periph:periph|*}]
set_multicycle_path -setup 5 -from $snd_regs -to $snd_regs
set_multicycle_path -hold  4 -from $snd_regs -to $snd_regs
