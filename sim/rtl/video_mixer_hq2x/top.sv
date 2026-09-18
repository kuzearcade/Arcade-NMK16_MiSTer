// video_retime feeding video_mixer, exactly as NMK16_Gunnail.sv wires them.
module vrtop (
    input clk_w, input clk_r, input reset_w, input ce_w,
    input [9:0] hcount_w, input [9:0] vcount_w, input [23:0] rgb_w,
    input mode1, input hq2x,
    output CE_PIXEL, output VGA_DE, output VGA_HS, output VGA_VS
);
    wire vm_ce, vm_hs, vm_vs, vm_hb, vm_vb;
    wire [23:0] rgb;
    video_retime #(
        .M0_X0(10'd28), .M0_HT(10'd512), .M0_HS(10'd440), .M0_HW(10'd32), .M0_AW(10'd384), .M0_DIV(5'd6),
        .M1_X0(10'd92), .M1_HT(10'd384), .M1_HS(10'd20),  .M1_HW(10'd24), .M1_AW(10'd256), .M1_DIV(5'd8),
        .LINE_CLKS(3072)
    ) vr (
        .clk_w(clk_w), .reset_w(reset_w), .ce_w(ce_w),
        .hcount_w(hcount_w), .vcount_w(vcount_w), .rgb_w(rgb_w),
        .mode1(mode1), .tall240(1'b0),
        .clk_r(clk_r),
        .ce_r(vm_ce), .rgb_r(rgb), .hs_r(vm_hs), .vs_r(vm_vs), .de_r(), .hb_r(vm_hb), .vb_r(vm_vb)
    );
    wire [21:0] gb;
    video_mixer #(.LINE_LENGTH(1024), .HALF_DEPTH(0), .GAMMA(0)) vm (
        .CLK_VIDEO(clk_r), .ce_pix(vm_ce), .CE_PIXEL(CE_PIXEL),
        .scandoubler(1'b1), .hq2x(hq2x), .gamma_bus(gb),
        .R(rgb[23:16]), .G(rgb[15:8]), .B(rgb[7:0]),
        .HSync(vm_hs), .VSync(vm_vs), .HBlank(vm_hb), .VBlank(vm_vb),
        .HDMI_FREEZE(1'b0), .freeze_sync(),
        .VGA_R(), .VGA_G(), .VGA_B(), .VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
    );
endmodule
