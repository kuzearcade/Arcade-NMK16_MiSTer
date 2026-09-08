// Minimal, standalone real-hardware SDRAM test core — built to isolate
// whether rtl/sdram.sv + rtl/sdram_req.sv work at all on THIS real
// DE10-Nano, independent of every other piece of Macross2's own game
// core (68000/Z80 CPUs, ioctl ROM loading, video tilemap rendering,
// hps_io interaction beyond the bare minimum). Context: both tdragon2
// and macross2 boot to a solid, exactly-black (RGB=0,0,0 every pixel)
// screen with exactly-silent audio (RMS=0.0) on real hardware, despite
// both rendering correctly in an accurate (real-time-raster-paced)
// simulation — see this session's own investigation in Macross2.sv's
// and tdragon2_core.sv's own git history (the ~pll_locked reset-gating
// and extra_por_hold fixes). Neither fix changed the real-hardware
// symptom. Leading remaining hypothesis: rtl/sdram.sv (this project's
// first-ever real-hardware use of it) or the project-specific
// sdram_req.sv/sdram_arb.sv/rom_cache1.sv glue around it behaves
// differently under real SDRAM timing than the behavioral
// sim/models/sdram_model.sv simulation assumes. This core tests that
// directly: write a deterministic pattern across a range of SDRAM
// words, read it back, and show the result on screen (and as an audio
// tone) — no CPU, no ROM loading, no tilemap rendering in the way.
//
// Reuses, unchanged: rtl/pll.v (same 40MHz clk_sys derivation as
// Macross2.sv, same `pll pll(...)` instance name — SdramTest.sdc reuses
// Macross2.sdc's own exclusive-clock-group wildcard as-is, since it
// matches on `emu|pll|...`, and this module is also named `emu`),
// rtl/sdram.sv (the real SDRAM controller), rtl/sdram_req.sv (the
// single-port pulse-request wrapper every real ROM region in this
// project's own game cores goes through), rtl/bjtwin/video_timing.sv
// (the same 512x278/384x224 raster generator Macross2.sv's own video
// pipeline uses — reused here purely for its proven-working hsync/vsync
// generation, not for any tilemap purpose).
//
// PHASE 1 (top half of screen) tests rtl/sdram.sv + rtl/sdram_req.sv
// directly: write then read back a deterministic pattern across the
// FULL 512KB (262144 words) maincpu-ROM-sized address range, no CPU, no
// ROM loading, no tilemap rendering in the way. Result: BLUE while
// running (or if it never starts — e.g. reset stuck), else each of the
// 128 screen-column buckets (2048 words/bucket — see BUCKET_WORDS's own
// comment) shows GREEN if every word in it read back correctly, RED if
// any did not.
//
// History: a first pass through this core tested only 384 words (well
// within a single SDRAM row) and found an apparent, exactly-50%,
// alternating-word failure pattern — root-caused (via a per-word
// display at that scale) to a bug in THIS TEST's own address
// arithmetic (right-shifting the loop counter, causing every-other test
// word to silently overwrite its own predecessor before readback), not
// a real rtl/sdram.sv bug — fixed, confirmed clean at that small scale.
// tdragon2_core.sv's own real-hardware rom_csum diagnostic (a passive
// checksum over every real 68000 ROM read, added directly to the game
// core) then showed the maincpu ROM's own real content genuinely
// differs from identical-RTL simulation at FULL 512KB scale (0xC465
// real vs. 0x44D8 simulated, reproduced twice, real input-state
// confound explicitly ruled out) — this expanded, full-range version of
// PHASE 1 exists to see whether that shows up as real word-level
// corruption the small 384-word test never reached.
//
// PHASE 2 (bottom half) tests the layer PHASE 1 never touches at all:
// a REAL ioctl_download event (releases/SdramTest.mra loads a small,
// already-verified ROM part) read back through rtl/rom_cache1.sv,
// mirroring tdragon2_core.sv's own maincpu-ROM path exactly. Result:
// BLUE while waiting for/during download or still reading back, GREEN
// if a 16-bit rotate-XOR checksum over the 128 words matches the known-
// correct value precomputed from the real file content, RED otherwise.
//
// PHASE 3 (middle strip, rows 96-127) tests the ONE structural gap
// between PHASE 1 (clean pass) and this project's own real-hardware
// finding of reset-vector corruption via tdragon2_core.sv's own
// diagnostic taps: a synthetic two-requester mux/handoff, reproducing
// tdragon2_core.sv's own sd0_inst pattern (ioctl_download-style writes
// and rom_cache1-style reads sharing one SDRAM port via a mux),
// immediately followed (no gap) by reads of word addresses 0-3. See
// this phase's own header comment further down for the full rationale.
//
// A 1kHz tone plays only once ALL THREE phases report PASS, silence
// otherwise, as a redundant audio-only signal in case video itself is
// part of the problem.
module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

assign VIDEO_ARX = 12'd4;
assign VIDEO_ARY = 12'd3;

`include "build_id.v"
localparam CONF_STR = {
	"SdramTest;;",
	"-;",
	"R[0],Reset;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr_full;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({1'b0}),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr_full),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);
wire [24:0] ioctl_addr = ioctl_addr_full[24:0];

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire clk_sdram;
wire pll_locked;
// CLK1_PHASE_SHIFT: real-hardware timing-margin hypothesis #3, after
// RASCAS_DELAY and PRECHARGE_DELAY (both purely digital, both already
// tested and found NOT to fix BACKGROUND LOAD's own real corruption —
// see rtl/sdram.sv's own SEPARATE_SDRAM_CLK parameter comment for the
// full rationale). -3000 (=-3ns) is a commonly-cited starting value for
// this kind of SDRAM_CLK trace-delay compensation on similar boards;
// not yet empirically tuned for this specific board.
pll #(.CLK1_PHASE_SHIFT("-3000")) pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

// Same gating this session added to Macross2.sv's own reset — see that
// file's own header for the derivation (por_rst-style countdowns
// completing before a real altpll has actually locked).
wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// ------------------------------------------------------------------
// SDRAM — identical wiring to Macross2.sv's own (same 4-port
// rtl/sdram.sv instance, same .init(~pll_locked)), but only port 0 is
// actually used; ports 1-3 tied off.
// ------------------------------------------------------------------
wire [24:1] sd0_addr;
wire        sd0_wrl, sd0_wrh;
wire [15:0] sd0_din;
wire [15:0] sd0_dout;
wire        sd0_req, sd0_ack;
wire        sdram_ready;

wire [24:1] sd1_addr;
wire        sd1_wrl, sd1_wrh;
wire [15:0] sd1_din;
wire [15:0] sd1_dout;
wire        sd1_req, sd1_ack;

wire [24:1] sd2_addr;
wire        sd2_wrl, sd2_wrh;
wire [15:0] sd2_din;
wire [15:0] sd2_dout;
wire        sd2_req, sd2_ack;

wire [24:1] sd3_addr;
wire        sd3_wrl, sd3_wrh;
wire [15:0] sd3_din;
wire [15:0] sd3_dout;
wire        sd3_req, sd3_ack;

// REFRESH_CYCLES=240 (6us @ 40MHz clk_sys) — see rtl/sdram.sv's own
// parameter comment. This exact override, and confirming it fixes the
// data corruption this core exists to detect, is what this core is for.
// RASCAS_DELAY/PRECHARGE_DELAY back to their own defaults (0/2) here —
// both already tested at raised values and found NOT to fix BACKGROUND
// LOAD's own real corruption; SEPARATE_SDRAM_CLK/clk_sdram (timing-
// margin hypothesis #3 — see rtl/sdram.sv's own parameter comment) is
// the one being isolated and tested now.
sdram #(.REFRESH_CYCLES(10'd240), .SEPARATE_SDRAM_CLK(1)) sdram_inst
(
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
	.init(~pll_locked), .clk(clk_sys), .clk_sdram(clk_sdram), .prio_mode(2'd0),
	.addr0(sd0_addr), .wrl0(sd0_wrl), .wrh0(sd0_wrh), .din0(sd0_din), .dout0(sd0_dout), .req0(sd0_req), .ack0(sd0_ack),
	.addr1(sd1_addr), .wrl1(sd1_wrl), .wrh1(sd1_wrh), .din1(sd1_din), .dout1(sd1_dout), .req1(sd1_req), .ack1(sd1_ack),
	.addr2(sd2_addr), .wrl2(sd2_wrl), .wrh2(sd2_wrh), .din2(sd2_din), .dout2(sd2_dout), .req2(sd2_req), .ack2(sd2_ack),
	.addr3(sd3_addr), .wrl3(sd3_wrl), .wrh3(sd3_wrh), .din3(sd3_din), .dout3(sd3_dout), .req3(sd3_req), .ack3(sd3_ack)
);

wire [24:1] req_addr;
wire        req_we, req_wrl, req_wrh;
wire [15:0] req_din;
wire        req_go;
wire        req_busy, req_valid;
wire [15:0] req_dout;

sdram_req sdram_req_inst
(
	.clk(clk_sys), .reset(reset),
	.addr(req_addr), .we(req_we), .wrl(req_wrl), .wrh(req_wrh), .din(req_din),
	.req(req_go), .busy(req_busy), .valid(req_valid), .dout(req_dout),
	.sdram_addr(sd0_addr), .sdram_wrl(sd0_wrl), .sdram_wrh(sd0_wrh), .sdram_din(sd0_din),
	.sdram_dout(sd0_dout), .sdram_req(sd0_req), .sdram_ack(sd0_ack)
);

// ------------------------------------------------------------------
// BACKGROUND LOAD: continuous, back-to-back SDRAM traffic on port 1 —
// previously PHASE 2's own port (a real ioctl_download + rtl/rom_cache1.sv
// read-back test, retired here: it never once saw real ioctl_download go
// high in this standalone core across several earlier attempts, a
// separate, still-unresolved mystery unrelated to the maincpu
// checksum-mismatch investigation this file otherwise exists for — see
// docs/hw-bringup.md — its own diagnostic value was already exhausted).
//
// Runs FOREVER, for the entire duration of PHASE 1's and PHASE 3c's own
// tests (write burst, PHASE 3c's own realistic idle gap, AND the final
// reads) — testing whether GENUINE concurrent multi-port SDRAM
// contention, absent from every other phase in this file (each of
// which only ever has one or two ports active before finishing and
// going idle), is the missing ingredient PHASE 3/3b/3c's own clean,
// isolated passes didn't capture — mimicking the real system's own
// other subsystems (audiocpu, video/sprite tile fetch, OKI) genuinely
// contending for SDRAM bandwidth at the exact moment the 68000 issues
// its first maincpu reads. Free-runs a perpetual write-then-read loop
// over a small (4096-word) rolling range, wrapping around forever,
// back-to-back, no gaps — never stopping, unlike every other phase.
// bg_heartbeat increments on every completed request, purely so the
// display can show real, sustained activity (not stuck at 0).
// ------------------------------------------------------------------
wire        bg_busy, bg_valid;
wire [15:0] bg_dout;

reg         bg_req, bg_we;
reg  [23:1] bg_addr;
reg  [15:0] bg_din;

sdram_req sd1_req_inst
(
	.clk(clk_sys), .reset(reset),
	.addr(bg_addr), .we(bg_we), .wrl(bg_we), .wrh(bg_we), .din(bg_din),
	.req(bg_req), .busy(bg_busy), .valid(bg_valid), .dout(bg_dout),
	.sdram_addr(sd1_addr), .sdram_wrl(sd1_wrl), .sdram_wrh(sd1_wrh), .sdram_din(sd1_din),
	.sdram_dout(sd1_dout), .sdram_req(sd1_req), .sdram_ack(sd1_ack)
);
assign ioctl_wait = 1'b0; // BACKGROUND LOAD never touches ioctl_download at all

localparam
	BG_WR_ISSUE = 0,
	BG_WR_CLEAR = 1,
	BG_WR_WAIT  = 2,
	BG_RD_ISSUE = 3,
	BG_RD_CLEAR = 4,
	BG_RD_WAIT  = 5;

localparam [11:0] BG_RANGE_WORDS = 12'd4096;

reg [2:0]  bg_state = BG_WR_ISSUE;
reg [11:0] bg_idx;
reg [31:0] bg_heartbeat;

always @(posedge clk_sys) begin
	if (reset) begin
		bg_state     <= BG_WR_ISSUE;
		bg_idx       <= 12'd0;
		bg_req       <= 1'b0;
		bg_heartbeat <= 32'd0;
	end else begin
		case (bg_state)
			BG_WR_ISSUE: begin
				bg_addr <= {11'd0, bg_idx};
				bg_we   <= 1'b1;
				bg_din  <= pattern_for({12'd0, bg_idx}) ^ 16'hFFFF; // distinct from PHASE 1's own pattern — never read back for correctness, only to consume bandwidth
				bg_req  <= 1'b1;
				bg_state <= BG_WR_CLEAR;
			end
			BG_WR_CLEAR: begin
				bg_req <= 1'b0;
				bg_state <= BG_WR_WAIT;
			end
			BG_WR_WAIT: if (bg_valid) begin
				bg_heartbeat <= bg_heartbeat + 32'd1;
				bg_state <= BG_RD_ISSUE;
			end

			BG_RD_ISSUE: begin
				bg_addr <= {11'd0, bg_idx};
				bg_we   <= 1'b0;
				bg_req  <= 1'b1;
				bg_state <= BG_RD_CLEAR;
			end
			BG_RD_CLEAR: begin
				bg_req <= 1'b0;
				bg_state <= BG_RD_WAIT;
			end
			BG_RD_WAIT: if (bg_valid) begin
				bg_heartbeat <= bg_heartbeat + 32'd1;
				bg_idx <= (bg_idx == BG_RANGE_WORDS - 12'd1) ? 12'd0 : bg_idx + 12'd1;
				bg_state <= BG_WR_ISSUE;
			end
		endcase
	end
end

// ------------------------------------------------------------------
// PHASE 3: synthetic two-requester mux-handoff test — reproduces the
// EXACT structural pattern tdragon2_core.sv's own sd0_inst uses to
// share ONE SDRAM port between ioctl_download's writes and
// rom_cache1's reads (`.addr(ioctl_download ? ioctl_addr[24:1] :
// cache_sd_addr)`, `.we(ioctl_download)`, `.req(ioctl_download ?
// ioctl_wr : cache_sd_req)`) — but driven by a SYNTHETIC p3_download
// control signal (this test's own FSM), not real hps_io
// ioctl_download, since PHASE 2 above already found real
// ioctl_download unreliably triggers at all in this standalone core
// (a separate, still-unsolved mystery this phase deliberately
// sidesteps). p3_download stays HIGH through a full TEST_WORDS-word
// write burst (same size as PHASE 1's own, and the real maincpu ROM's
// own download size) and drops LOW the SAME cycle the burst's last
// write's own req pulse fires — no gap — at which point the mux
// immediately routes to the READ addresses, exactly mirroring how
// ioctl_download deasserting and rom_cache1's own cache_sd_addr
// already being live/valid coincide in the real design. Reads word
// addresses 0-3 (the same 4 this project's own real-hardware bring-up
// work found corrupted via tdragon2_core.sv's own diagnostic taps —
// see docs/hw-bringup.md), comparing each against the same
// deterministic pattern_for() the write burst used.
//
// This isolates the ONE structural difference between this and PHASE 1
// above (which already writes+reads this exact same word count, but
// through a single unified FSM with no requester mux at all, and
// passed cleanly on real hardware): the dual-requester mux/handoff
// itself. A failure here that PHASE 1 doesn't show would be strong,
// clean evidence the handoff mechanism (or the real write-burst-to-
// first-read SDRAM timing it exposes) is the actual bug; a clean pass
// here would instead point suspicion further downstream — toward
// something specific to the real ROM content, real rom_cache1 usage
// pattern, or the real ioctl_download timing itself that this
// synthetic reproduction still doesn't capture.
// ------------------------------------------------------------------
wire [15:0] p3_dout;
wire        p3_valid, p3_busy;

reg         p3_download;
reg  [23:0] p3_wr_addr;
reg  [1:0]  p3_rd_idx;
reg         p3_req, p3_we;
reg  [23:1] p3_addr;
reg  [15:0] p3_din;

sdram_req sd2_req_inst
(
	.clk(clk_sys), .reset(reset),
	.addr(p3_addr), .we(p3_we), .wrl(p3_we), .wrh(p3_we), .din(p3_din),
	.req(p3_req), .busy(p3_busy), .valid(p3_valid), .dout(p3_dout),
	.sdram_addr(sd2_addr), .sdram_wrl(sd2_wrl), .sdram_wrh(sd2_wrh), .sdram_din(sd2_din),
	.sdram_dout(sd2_dout), .sdram_req(sd2_req), .sdram_ack(sd2_ack)
);

localparam
	P3_WR_ISSUE  = 0,
	P3_WR_CLEAR  = 1,
	P3_WR_WAIT   = 2,
	P3_RD_ISSUE  = 3,
	P3_RD_CLEAR  = 4,
	P3_RD_WAIT   = 5,
	P3_DONE      = 6;

reg [2:0]  p3_state = P3_WR_ISSUE;
reg [15:0] p3_readback [0:3];
reg        p3_fail     [0:3];
reg        p3_test_done;
integer    p3_i;

always @(posedge clk_sys) begin
	if (reset) begin
		p3_state     <= P3_WR_ISSUE;
		p3_download  <= 1'b1;
		p3_wr_addr   <= 24'd0;
		p3_rd_idx    <= 2'd0;
		p3_req       <= 1'b0;
		p3_test_done <= 1'b0;
		for (p3_i = 0; p3_i < 4; p3_i = p3_i + 1) begin
			p3_readback[p3_i] <= 16'd0;
			p3_fail[p3_i]     <= 1'b0;
		end
	end else begin
		case (p3_state)
			P3_WR_ISSUE: begin
				p3_addr <= p3_wr_addr[22:0];
				p3_we   <= 1'b1;
				p3_din  <= pattern_for(p3_wr_addr);
				p3_req  <= 1'b1;
				p3_state <= P3_WR_CLEAR;
			end
			P3_WR_CLEAR: begin
				p3_req  <= 1'b0;
				p3_state <= P3_WR_WAIT;
			end
			P3_WR_WAIT: if (p3_valid) begin
				if (p3_wr_addr == TEST_WORDS - 24'd1) begin
					// Last write's own completion — drop p3_download the
					// SAME cycle, no gap, matching ioctl_download's own
					// real deassertion timing relative to its last byte.
					p3_download <= 1'b0;
					p3_rd_idx   <= 2'd0;
					p3_state    <= P3_RD_ISSUE;
				end else begin
					p3_wr_addr <= p3_wr_addr + 24'd1;
					p3_state   <= P3_WR_ISSUE;
				end
			end

			P3_RD_ISSUE: begin
				p3_addr <= {21'd0, p3_rd_idx};
				p3_we   <= 1'b0;
				p3_req  <= 1'b1;
				p3_state <= P3_RD_CLEAR;
			end
			P3_RD_CLEAR: begin
				p3_req  <= 1'b0;
				p3_state <= P3_RD_WAIT;
			end
			P3_RD_WAIT: if (p3_valid) begin
				p3_readback[p3_rd_idx] <= p3_dout;
				p3_fail[p3_rd_idx]     <= (p3_dout != pattern_for({22'd0, p3_rd_idx}));
				if (p3_rd_idx == 2'd3) begin
					p3_test_done <= 1'b1;
					p3_state     <= P3_DONE;
				end else begin
					p3_rd_idx <= p3_rd_idx + 2'd1;
					p3_state  <= P3_RD_ISSUE;
				end
			end

			P3_DONE: ;
		endcase
	end
end

// ------------------------------------------------------------------
// PHASE 3b/3c: same mux-handoff structure as PHASE 3 above (port 3 this
// time, previously tied off), but writing BYTE-at-a-time instead of
// full words — matching the REAL ioctl_download protocol's own actual
// granularity exactly: tdragon2_core.sv's own g_rom_hw block writes via
// `.wrl(ioctl_download & ~ioctl_addr[0]), .wrh(ioctl_download &
// ioctl_addr[0]), .din({ioctl_dout, ioctl_dout})` — one 8-bit
// ioctl_dout value, replicated into BOTH halves of a 16-bit din bus,
// with wrl/wrh selecting which half actually lands based on the
// address's own low bit (even byte address -> low half, odd -> high).
// PHASE 3 above wrote full 16-bit words every request (wrl=wrh=1
// always) and passed cleanly. PHASE 3b (byte-at-a-time, still no gap
// anywhere) ALSO passed cleanly — see docs/hw-bringup.md.
//
// PHASE 3c (this same FSM, extended with a new P3B_GAP_WAIT state
// below): tdragon2_core.sv's own real-hardware ioctl_wr pulse-timing
// instrumentation then found the REAL download's own pacing is nothing
// like either synthetic test — real hps_io/ARM-side byte delivery has
// large, irregular stalls, up to ~358,000 clk_sys cycles (~9ms, ~1500x
// a single REFRESH_CYCLES=240-cycle refresh interval) between
// consecutive real ioctl_wr pulses, with over 10,000 individual real
// byte-writes preceded by at least one full refresh interval of idle
// time. PHASE 3c inserts ONE such realistic gap (GAP_CYCLES, matching
// that observed magnitude) immediately after the write burst's own
// LAST byte completes and before the handoff to reads — directly
// testing whether a big idle/refresh-heavy period ending right where
// the first read begins (as the real system's own post-download
// reset-sync delay very plausibly produces) is what actually exposes
// the corruption, since neither the bare mux/handoff structure (PHASE
// 3) nor real byte granularity alone (PHASE 3b, no gap) reproduced it.
// ------------------------------------------------------------------
wire [15:0] p3b_dout;
wire        p3b_valid, p3b_busy;

reg  [24:0] p3b_byte_addr; // 0..524287 (TEST_WORDS*2 bytes)
reg  [1:0]  p3b_rd_idx;
reg         p3b_req, p3b_we, p3b_wrl, p3b_wrh;
reg  [23:1] p3b_addr;
reg  [15:0] p3b_din;

wire [23:0] p3b_word_addr = p3b_byte_addr[24:1];
wire        p3b_is_high   = p3b_byte_addr[0];
wire [15:0] p3b_word_pat  = pattern_for(p3b_word_addr);
wire [7:0]  p3b_byte_val  = p3b_is_high ? p3b_word_pat[15:8] : p3b_word_pat[7:0];

sdram_req sd3_req_inst
(
	.clk(clk_sys), .reset(reset),
	.addr(p3b_addr), .we(p3b_we), .wrl(p3b_wrl), .wrh(p3b_wrh), .din(p3b_din),
	.req(p3b_req), .busy(p3b_busy), .valid(p3b_valid), .dout(p3b_dout),
	.sdram_addr(sd3_addr), .sdram_wrl(sd3_wrl), .sdram_wrh(sd3_wrh), .sdram_din(sd3_din),
	.sdram_dout(sd3_dout), .sdram_req(sd3_req), .sdram_ack(sd3_ack)
);

localparam
	P3B_WR_ISSUE  = 0,
	P3B_WR_CLEAR  = 1,
	P3B_WR_WAIT   = 2,
	P3B_GAP_WAIT  = 3,
	P3B_RD_ISSUE  = 4,
	P3B_RD_CLEAR  = 5,
	P3B_RD_WAIT   = 6,
	P3B_DONE      = 7;

// GAP_CYCLES: matches the real ioctl_wr_max_gap_o magnitude found on
// real hardware (357992 cycles, see PHASE 3c's own header comment
// above) — rounded to a clean 360000.
localparam [23:0] GAP_CYCLES = 24'd360000;

reg [2:0]  p3b_state = P3B_WR_ISSUE;
reg [23:0] p3b_gap_cnt;
reg [15:0] p3b_readback [0:3];
reg        p3b_fail     [0:3];
reg        p3b_test_done;
integer    p3b_i;

always @(posedge clk_sys) begin
	if (reset) begin
		p3b_state     <= P3B_WR_ISSUE;
		p3b_byte_addr <= 25'd0;
		p3b_gap_cnt   <= 24'd0;
		p3b_rd_idx    <= 2'd0;
		p3b_req       <= 1'b0;
		p3b_test_done <= 1'b0;
		for (p3b_i = 0; p3b_i < 4; p3b_i = p3b_i + 1) begin
			p3b_readback[p3b_i] <= 16'd0;
			p3b_fail[p3b_i]     <= 1'b0;
		end
	end else begin
		case (p3b_state)
			P3B_WR_ISSUE: begin
				p3b_addr <= p3b_word_addr[22:0];
				p3b_we   <= 1'b1;
				p3b_wrl  <= ~p3b_is_high;
				p3b_wrh  <= p3b_is_high;
				p3b_din  <= {p3b_byte_val, p3b_byte_val};
				p3b_req  <= 1'b1;
				p3b_state <= P3B_WR_CLEAR;
			end
			P3B_WR_CLEAR: begin
				p3b_req  <= 1'b0;
				p3b_state <= P3B_WR_WAIT;
			end
			P3B_WR_WAIT: if (p3b_valid) begin
				if (p3b_byte_addr == (TEST_WORDS * 24'd2) - 25'd1) begin
					p3b_gap_cnt <= 24'd0;
					p3b_state   <= P3B_GAP_WAIT;
				end else begin
					p3b_byte_addr <= p3b_byte_addr + 25'd1;
					p3b_state     <= P3B_WR_ISSUE;
				end
			end

			// The realistic idle gap this phase exists to test — see
			// PHASE 3c's own header comment above. No SDRAM requests of
			// any kind issued for GAP_CYCLES clk_sys cycles, exactly
			// mirroring the idle/refresh-only period the real ioctl_wr
			// timing instrumentation actually measured.
			P3B_GAP_WAIT: begin
				if (p3b_gap_cnt == GAP_CYCLES - 24'd1) begin
					p3b_rd_idx <= 2'd0;
					p3b_state  <= P3B_RD_ISSUE;
				end else begin
					p3b_gap_cnt <= p3b_gap_cnt + 24'd1;
				end
			end

			P3B_RD_ISSUE: begin
				p3b_addr <= {21'd0, p3b_rd_idx};
				p3b_we   <= 1'b0;
				p3b_wrl  <= 1'b0;
				p3b_wrh  <= 1'b0;
				p3b_req  <= 1'b1;
				p3b_state <= P3B_RD_CLEAR;
			end
			P3B_RD_CLEAR: begin
				p3b_req  <= 1'b0;
				p3b_state <= P3B_RD_WAIT;
			end
			P3B_RD_WAIT: if (p3b_valid) begin
				p3b_readback[p3b_rd_idx] <= p3b_dout;
				p3b_fail[p3b_rd_idx]     <= (p3b_dout != pattern_for({22'd0, p3b_rd_idx}));
				if (p3b_rd_idx == 2'd3) begin
					p3b_test_done <= 1'b1;
					p3b_state     <= P3B_DONE;
				end else begin
					p3b_rd_idx <= p3b_rd_idx + 2'd1;
					p3b_state  <= P3B_RD_ISSUE;
				end
			end

			P3B_DONE: ;
		endcase
	end
end

// ------------------------------------------------------------------
// Test FSM — write TEST_WORDS deterministic (address-dependent)
// pattern words starting at word address 0, then read every one back
// and compare. req is a rising-edge trigger (see sdram_req.sv's own
// header) so it must be pulsed low again before the next request.
// ------------------------------------------------------------------
// TEST_WORDS = 262144 (512KB, 0x80000 bytes) — the real maincpu ROM's
// own full size, NOT just a small 384-word sample. A first version of
// this test only covered addr 0..383 (well within a single SDRAM row)
// and reported a clean pass; tdragon2_core.sv's own real-hardware
// rom_csum diagnostic (a passive checksum over every real 68000 ROM
// read, added directly to the game core) then showed the maincpu ROM's
// own real content genuinely differs from the identical-RTL simulation
// reference at the FULL 512KB scale (0xC465 real vs. 0x44D8 simulated,
// reproduced twice, with a real input-state confound explicitly ruled
// out) — this expanded test exists to find out whether that shows up
// as real word-level corruption somewhere in the address range a
// 384-word sample never reached (a different SDRAM row/bank/refresh
// boundary), or whether the raw write/read-back path itself stays
// clean even at full scale (which would point the remaining suspicion
// at the ioctl_download/rom_cache1 layers specifically, not raw SDRAM
// read/write correctness).
localparam [23:0] TEST_WORDS = 24'd262144;

// BUCKET_WORDS=2048 (2048*128=262144 exactly) — 128 buckets, one per
// 3-pixel-wide screen column (128*3=384=full screen width), so a
// failure's approximate ADDRESS is still visible spatially even though
// individual words can no longer each get their own column at this
// scale.
localparam [23:0] BUCKET_WORDS = 24'd2048;

function automatic [15:0] pattern_for(input [23:0] addr);
	pattern_for = addr[15:0] ^ 16'hA5A5;
endfunction

localparam
	S_IDLE       = 0,
	S_WR_ISSUE   = 1,
	S_WR_CLEAR   = 2,
	S_WR_WAIT    = 3,
	S_RD_ISSUE   = 4,
	S_RD_CLEAR   = 5,
	S_RD_WAIT    = 6,
	S_DONE       = 7;

reg [2:0]  state = S_IDLE;
reg [23:0] addr_cnt;
reg [23:0] pass_count, fail_count;
reg        test_done;
reg [15:0] expect_r;

// Per-BUCKET pass/fail (one bit per 2048-word bucket, NOT per word —
// see BUCKET_WORDS's own comment above), indexed by bucket number ==
// screen column/3. An aggregate fail_count alone previously hid a
// suspiciously exact 50/50 split that turned out (once mapped
// spatially) to reveal a real, deterministic failure pattern rather
// than looking like refresh-driven bit decay — keeping SOME spatial
// resolution here for the same reason, just coarser given the much
// larger address range.
reg fail_map [0:127];
integer fm_i;

reg        r_req;
reg        r_we, r_wrl, r_wrh;
reg [23:1] r_addr;
reg [15:0] r_din;
assign req_addr = r_addr;
assign req_we   = r_we;
assign req_wrl  = r_wrl;
assign req_wrh  = r_wrh;
assign req_din  = r_din;
assign req_go   = r_req;

always @(posedge clk_sys) begin
	if (reset) begin
		state <= S_IDLE;
		addr_cnt <= 24'd0;
		pass_count <= 24'd0;
		fail_count <= 24'd0;
		test_done <= 1'b0;
		r_req <= 1'b0;
		for (fm_i = 0; fm_i < 128; fm_i = fm_i + 1) fail_map[fm_i] <= 1'b0;
	end else begin
		case (state)
			S_IDLE: if (sdram_ready) begin
				addr_cnt <= 24'd0;
				state <= S_WR_ISSUE;
			end

			S_WR_ISSUE: begin
				r_addr  <= addr_cnt[22:0];
				r_we   <= 1'b1;
				r_wrl  <= 1'b1;
				r_wrh  <= 1'b1;
				r_din  <= pattern_for(addr_cnt);
				r_req  <= 1'b1;
				state  <= S_WR_CLEAR;
			end
			S_WR_CLEAR: begin
				r_req <= 1'b0;
				state <= S_WR_WAIT;
			end
			S_WR_WAIT: if (req_valid) begin
				if (addr_cnt == TEST_WORDS - 24'd1) begin
					addr_cnt <= 24'd0;
					state <= S_RD_ISSUE;
				end else begin
					addr_cnt <= addr_cnt + 24'd1;
					state <= S_WR_ISSUE;
				end
			end

			S_RD_ISSUE: begin
				r_addr  <= addr_cnt[22:0];
				r_we    <= 1'b0;
				r_wrl   <= 1'b0;
				r_wrh   <= 1'b0;
				expect_r <= pattern_for(addr_cnt);
				r_req   <= 1'b1;
				state   <= S_RD_CLEAR;
			end
			S_RD_CLEAR: begin
				r_req <= 1'b0;
				state <= S_RD_WAIT;
			end
			S_RD_WAIT: if (req_valid) begin
				if (req_dout == expect_r) pass_count <= pass_count + 24'd1;
				else begin
					fail_count <= fail_count + 24'd1;
					fail_map[addr_cnt[22:11]] <= 1'b1; // addr_cnt / BUCKET_WORDS(2048)
				end
				if (addr_cnt == TEST_WORDS - 24'd1) begin
					test_done <= 1'b1;
					state <= S_DONE;
				end else begin
					addr_cnt <= addr_cnt + 24'd1;
					state <= S_RD_ISSUE;
				end
			end

			S_DONE: ; // stay, result latched in pass_count/fail_count/test_done
		endcase
	end
end

// ------------------------------------------------------------------
// Raster timing — same shared 512x278/384x224 generator Macross2.sv's
// own video pipeline uses, and the same clk_sys/5 ce_pix divider.
// ------------------------------------------------------------------
reg [2:0] pix_div = 3'd0;
wire ce_pix = (pix_div == 3'd4);
always @(posedge clk_sys) pix_div <= reset ? 3'd0 : (ce_pix ? 3'd0 : pix_div + 3'd1);

wire [9:0] hcount, vcount;
wire line_start, hblank, vblank;
video_timing vtiming
(
	.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset),
	.hcount(hcount), .vcount(vcount),
	.line_start(line_start), .hblank(hblank), .vblank(vblank)
);

// Same HSync/VSync placement Macross2.sv's own real hardware top uses
// (unmodified by this session's own black-screen investigation —
// proven to at least reach a valid, lockable picture: the MiSTer OSD's
// own "Sending ROM #0" overlay rendered crisply on top of this exact
// sync generation during this session's own real-hardware testing).
wire hsync = (hcount >= 10'd440) && (hcount < 10'd472);
wire vsync = (vcount >= 10'd244) && (vcount < 10'd247);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hsync;
assign VGA_VS = vsync;

// Top half (screen_y<112): PHASE 1 result — BLUE while running, else
// column x shows word x's own real pass(GREEN)/fail(RED) directly
// (fail_map — see its own comment above). Bottom half: PHASE 2 result —
// BLUE while waiting for/during the real ioctl_download or still
// reading back through rom_cache1, GREEN if the checksum matched,
// RED if it did not.
wire [8:0] screen_x = hcount[8:0] - 9'd28; // matches Macross2.sv's own rd_x_screen derivation
wire [7:0] screen_y = vcount[7:0] - 8'd16;
// 128 buckets * 3px/bucket = 384 = full screen width.
wire [6:0] screen_bucket = screen_x / 9'd3;
wire [23:0] phase1_rgb = !test_done ? 24'h0000FF : fail_map[screen_bucket] ? 24'hFF0000 : 24'h00FF00;
// BACKGROUND LOAD display (bottom region, previously PHASE 2's own —
// see BACKGROUND LOAD's own comment above for why it was retired):
// BLUE while bg_heartbeat is still ramping up (startup), GREEN once it
// has run enough iterations to be confidently "steadily, continuously
// running" rather than stuck — plus a moving white marker at
// bg_idx's own current position, so a single screenshot can also show
// the perpetual write/read loop is genuinely mid-sweep, not frozen.
wire [23:0] phase2_rgb =
	(bg_heartbeat < 32'd1000) ? 24'h0000FF :
	((screen_x / 9'd3) == bg_idx[11:5]) ? 24'hFFFFFF : 24'h00FF00;
// PHASE 3 display: rows 80-111 (32 rows tall — screen now split
// PHASE1(0-79)/PHASE3(80-111)/PHASE3b(112-143)/PHASE2(144-223), see the
// vertical split just below), 4 segments of 96px each — one per tested
// word address (0-3) — BLUE while !p3_test_done, else GREEN if that
// word read back correctly, RED if not (p3_fail — see PHASE 3's own
// comment above for the full rationale).
wire [1:0]  phase3_seg = screen_x / 9'd96;
wire        phase3_word_fail = (phase3_seg==2'd0) ? p3_fail[0] :
                                (phase3_seg==2'd1) ? p3_fail[1] :
                                (phase3_seg==2'd2) ? p3_fail[2] : p3_fail[3];
// DIAGNOSTIC: color-coded by p3_state directly, not just done/not-done,
// so a stuck test is distinguishable from one that never started or is
// just slow — BLUE=writing (P3_WR_*), CYAN=reading (P3_RD_*, meaning
// the write burst itself DID complete), GREEN/RED=P3_DONE.
// DIAGNOSTIC: a thin white progress bar (top 4 rows of the strip),
// width = p3_wr_addr's own value scaled to the screen — lets a genuinely
// (if slowly) advancing write burst be told apart from one that's truly
// stuck at address 0 forever. (Turned out to matter: PHASE 3's own
// first few real-hardware checks all showed solid BLUE for well over a
// minute before this bar was added — it then showed real, fast
// progress, and the test completed shortly after. Not a hang; just an
// under-sampled early check.)
wire [8:0] p3_progress_px = p3_wr_addr[23:9]; // 0-511, TEST_WORDS>>9=512
wire       p3_progress_bar = (screen_y < 8'd84) && (screen_x < p3_progress_px);

wire [23:0] phase3_rgb =
	p3_progress_bar ? 24'hFFFFFF :
	(p3_state == P3_WR_ISSUE || p3_state == P3_WR_CLEAR || p3_state == P3_WR_WAIT) ? 24'h0000FF :
	(p3_state == P3_RD_ISSUE || p3_state == P3_RD_CLEAR || p3_state == P3_RD_WAIT) ? 24'h00FFFF :
	(phase3_word_fail ? 24'hFF0000 : 24'h00FF00);

// PHASE 3b display: rows 112-143, same 4-segment/96px layout and same
// color convention as PHASE 3 above, plus the same progress bar
// (scaled for BYTE_COUNT=TEST_WORDS*2 instead of TEST_WORDS, so
// p3b_byte_addr's own upper bits divide down to the same 0-511 range).
wire        phase3b_word_fail = (phase3_seg==2'd0) ? p3b_fail[0] :
                                 (phase3_seg==2'd1) ? p3b_fail[1] :
                                 (phase3_seg==2'd2) ? p3b_fail[2] : p3b_fail[3];
wire [8:0] p3b_progress_px = p3b_byte_addr[18:10]; // 0-511, (TEST_WORDS*2)>>10=512
wire       p3b_progress_bar = (screen_y < 8'd116) && (screen_x < p3b_progress_px);

// YELLOW = P3B_GAP_WAIT (PHASE 3c's own realistic idle gap — see its
// own header comment above), inserted between BLUE (writing) and CYAN
// (reading) so the gap itself is visible as a distinct phase, not
// mistaken for either.
wire [23:0] phase3b_rgb =
	p3b_progress_bar ? 24'hFFFFFF :
	(p3b_state == P3B_WR_ISSUE || p3b_state == P3B_WR_CLEAR || p3b_state == P3B_WR_WAIT) ? 24'h0000FF :
	(p3b_state == P3B_GAP_WAIT) ? 24'hFFFF00 :
	(p3b_state == P3B_RD_ISSUE || p3b_state == P3B_RD_CLEAR || p3b_state == P3B_RD_WAIT) ? 24'h00FFFF :
	(phase3b_word_fail ? 24'hFF0000 : 24'h00FF00);

wire [23:0] result_rgb =
	(screen_y < 8'd80)  ? phase1_rgb :
	(screen_y < 8'd112) ? phase3_rgb :
	(screen_y < 8'd144) ? phase3b_rgb : phase2_rgb;

assign VGA_R = result_rgb[23:16];
assign VGA_G = result_rgb[15:8];
assign VGA_B = result_rgb[7:0];

// ------------------------------------------------------------------
// Audio — 1kHz tone while test_done && fail_count==0 (PASS), silence
// otherwise (still-running OR any failure), as a redundant, video-
// independent signal.
// ------------------------------------------------------------------
reg [14:0] tone_cnt = 15'd0;
reg        tone_bit = 1'b0;
always @(posedge clk_sys) begin
	if (tone_cnt == 15'd20000) begin // 40MHz/20000/2 = 1kHz square wave
		tone_cnt <= 15'd0;
		tone_bit <= ~tone_bit;
	end else tone_cnt <= tone_cnt + 15'd1;
end
wire signed [15:0] tone = tone_bit ? 16'sd8000 : -16'sd8000;
wire pass_ok = test_done && (fail_count == 24'd0) && p3_test_done && !(p3_fail[0]|p3_fail[1]|p3_fail[2]|p3_fail[3])
	&& p3b_test_done && !(p3b_fail[0]|p3b_fail[1]|p3b_fail[2]|p3b_fail[3]);
assign AUDIO_L = pass_ok ? tone : 16'sd0;
assign AUDIO_R = pass_ok ? tone : 16'sd0;

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
