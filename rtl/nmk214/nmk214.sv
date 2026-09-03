// NMK214 GFX descrambler — a stateless, table-driven dynamic bitswap of
// graphics-ROM data, ported directly from mame/src/mame/nmk/nmk214.cpp
// (device comment there has the hardware background: works in tandem
// with the NMK215/TMP90840 protection MCU, which sends one init byte at
// startup selecting 1-of-8 hardwired internal configurations; every
// board using it has two instances, one wired for sprites (word mode)
// and one for BG tiles (byte mode)).
//
// The descramble itself is address-dependent: which bitswap gets applied
// to a given word/byte depends on 3 bits pulled out of the *address*
// (after first re-ordering the address through ADDR_BITSWAP, since the
// 13 NMK214 address pins are wired to different ROM address lines for
// sprites vs BG on the actual PCB — see nmk16.cpp's own
// nmk214_sprites_address_bitswap/nmk214_bg_address_bitswap tables, which
// become this module's own ADDR_BITSWAP parameter per instance). Those 3
// selector bits are themselves picked per-config (SEL_BITS), then used
// to pull 1 bit out of each of that config's own 3 CFG_BYTES entries —
// those 3 extracted bits form a 0-7 index into the final WORD_BITSWAP/
// BYTE_BITSWAP table.
//
// set_init_config() in the reference only stores the incoming byte if
// bit 3 matches the device's own hardwired MODE (0 or 1, opposite for
// the two instances on a board) — modeled here as a registered
// `cfg_we`-gated latch, not a combinational path, since the real device
// only samples this once at startup via the protection MCU's own
// port3(strobe)/port7(data) handshake (see nmk_prot_core.sv's own
// P3/P7 wiring for how that strobe is generated).
module nmk214 #(
	parameter               MODE        = 1'b0,
	// Width of the raw ROM address this instance's own ADDR_BITSWAP
	// entries index into — NOT 13 bits: the reference's own per-game
	// bitswap tables (nmk16.cpp's nmk214_sprites_address_bitswap/
	// nmk214_bg_address_bitswap) pick individual bits out of the full
	// ROM address bus (values up to 20 seen for a BG ROM), since a
	// single 13-line NMK214 only ever samples 13 *specific* lines of a
	// much wider real address bus, not a contiguous low slice of it.
	parameter                ADDR_WIDTH  = 21,
	// 13 entries, LSB-first: ADDR_BITSWAP[i] = which raw address line
	// (0..ADDR_WIDTH-1) feeds this device's own address bit i. Default
	// = identity over the low 13 bits — real boards always override
	// this per instance with the reference's own per-game table.
	parameter [12:0][4:0]   ADDR_BITSWAP = {5'd12,5'd11,5'd10,5'd9,5'd8,5'd7,5'd6,5'd5,5'd4,5'd3,5'd2,5'd1,5'd0}
) (
	input        clk,
	input        reset,

	// Startup config-load strobe — pulse for one clk_sys cycle on the
	// protection MCU's port3-bit2 rising edge, with cfg_data already
	// holding the port7 byte latched at that moment (see
	// nmk_prot_core.sv). Mirrors set_init_config()'s own bit3/MODE gate.
	input        cfg_we,
	input  [7:0] cfg_data,
	output       initialized,

	// Descramble interface — pure combinational function of (addr,
	// din), like the reference's own decode_word()/decode_byte(). addr
	// is the raw (pre-bitswap) ROM address; the caller drives whichever
	// of dout_word/dout_byte matches this instance's own MODE (word for
	// sprites, byte for BG) — the other stays a harmless unused output.
	input  [ADDR_WIDTH-1:0] addr,
	input  [15:0] din,
	output [15:0] dout_word,
	input   [7:0] din8,
	output  [7:0] dout_byte
);

	// ------------------------------------------------------------------
	// Hardwired tables — verbatim from nmk214.cpp's own anonymous
	// namespace. Indexed [config][entry]; each entry width matches the
	// reference's own u8 storage (values that only ever hold 0-15 stay
	// declared wide enough for direct bitswap-select indexing below).
	// ------------------------------------------------------------------
	function automatic [7:0] cfg_byte(input [2:0] cfg, input [1:0] entry);
		case ({cfg, entry})
			// config 0
			5'b000_00: cfg_byte = 8'haa; 5'b000_01: cfg_byte = 8'hcc; 5'b000_10: cfg_byte = 8'hf0;
			// config 1
			5'b001_00: cfg_byte = 8'h55; 5'b001_01: cfg_byte = 8'h39; 5'b001_10: cfg_byte = 8'h1e;
			// config 2
			5'b010_00: cfg_byte = 8'hc5; 5'b010_01: cfg_byte = 8'h69; 5'b010_10: cfg_byte = 8'h5c;
			// config 3
			5'b011_00: cfg_byte = 8'h35; 5'b011_01: cfg_byte = 8'h5c; 5'b011_10: cfg_byte = 8'hc5;
			// config 4
			5'b100_00: cfg_byte = 8'h78; 5'b100_01: cfg_byte = 8'h1d; 5'b100_10: cfg_byte = 8'h2e;
			// config 5
			5'b101_00: cfg_byte = 8'h55; 5'b101_01: cfg_byte = 8'h33; 5'b101_10: cfg_byte = 8'h0f;
			// config 6
			5'b110_00: cfg_byte = 8'ha5; 5'b110_01: cfg_byte = 8'hb8; 5'b110_10: cfg_byte = 8'h36;
			// config 7
			5'b111_00: cfg_byte = 8'h8b; 5'b111_01: cfg_byte = 8'h69; 5'b111_10: cfg_byte = 8'h2e;
			default:   cfg_byte = 8'h00;
		endcase
	endfunction

	// selection_address_bits[config][entry], 0..12
	function automatic [3:0] sel_bit(input [2:0] cfg, input [1:0] entry);
		case ({cfg, entry})
			5'b000_00: sel_bit = 4'h8; 5'b000_01: sel_bit = 4'h9; 5'b000_10: sel_bit = 4'ha;
			5'b001_00: sel_bit = 4'h6; 5'b001_01: sel_bit = 4'h8; 5'b001_10: sel_bit = 4'hb;
			5'b010_00: sel_bit = 4'h3; 5'b010_01: sel_bit = 4'h9; 5'b010_10: sel_bit = 4'hc;
			5'b011_00: sel_bit = 4'h3; 5'b011_01: sel_bit = 4'h7; 5'b011_10: sel_bit = 4'ha;
			5'b100_00: sel_bit = 4'h2; 5'b100_01: sel_bit = 4'h5; 5'b100_10: sel_bit = 4'hb;
			5'b101_00: sel_bit = 4'h1; 5'b101_01: sel_bit = 4'h4; 5'b101_10: sel_bit = 4'ha;
			5'b110_00: sel_bit = 4'h2; 5'b110_01: sel_bit = 4'h4; 5'b110_10: sel_bit = 4'ha;
			5'b111_00: sel_bit = 4'h0; 5'b111_01: sel_bit = 4'h4; 5'b111_10: sel_bit = 4'hc;
			default:   sel_bit = 4'h0;
		endcase
	endfunction

	// output_word_bitswaps[bitswap_select][bit] — which input data bit
	// feeds output bit `bit`.
	function automatic [3:0] word_bit(input [2:0] sel, input [3:0] bit_);
		case (sel)
			3'd0: case(bit_) 4'd0:word_bit=4'h2; 4'd1:word_bit=4'h3; 4'd2:word_bit=4'h7; 4'd3:word_bit=4'h8; 4'd4:word_bit=4'hc; 4'd5:word_bit=4'h4; 4'd6:word_bit=4'hb; 4'd7:word_bit=4'h9; 4'd8:word_bit=4'h1; 4'd9:word_bit=4'hf; 4'd10:word_bit=4'ha; 4'd11:word_bit=4'h5; 4'd12:word_bit=4'he; 4'd13:word_bit=4'h6; 4'd14:word_bit=4'hd; 4'd15:word_bit=4'h0; endcase
			3'd1: case(bit_) 4'd0:word_bit=4'h0; 4'd1:word_bit=4'h3; 4'd2:word_bit=4'h8; 4'd3:word_bit=4'h7; 4'd4:word_bit=4'ha; 4'd5:word_bit=4'hc; 4'd6:word_bit=4'h4; 4'd7:word_bit=4'h1; 4'd8:word_bit=4'hf; 4'd9:word_bit=4'h9; 4'd10:word_bit=4'h6; 4'd11:word_bit=4'hd; 4'd12:word_bit=4'he; 4'd13:word_bit=4'hb; 4'd14:word_bit=4'h5; 4'd15:word_bit=4'h2; endcase
			3'd2: case(bit_) 4'd0:word_bit=4'h9; 4'd1:word_bit=4'h8; 4'd2:word_bit=4'h2; 4'd3:word_bit=4'h3; 4'd4:word_bit=4'h6; 4'd5:word_bit=4'h5; 4'd6:word_bit=4'hd; 4'd7:word_bit=4'hf; 4'd8:word_bit=4'h7; 4'd9:word_bit=4'h0; 4'd10:word_bit=4'hc; 4'd11:word_bit=4'hb; 4'd12:word_bit=4'ha; 4'd13:word_bit=4'h4; 4'd14:word_bit=4'he; 4'd15:word_bit=4'h1; endcase
			3'd3: case(bit_) 4'd0:word_bit=4'h0; 4'd1:word_bit=4'h3; 4'd2:word_bit=4'h9; 4'd3:word_bit=4'hf; 4'd4:word_bit=4'hd; 4'd5:word_bit=4'hc; 4'd6:word_bit=4'hb; 4'd7:word_bit=4'h1; 4'd8:word_bit=4'h2; 4'd9:word_bit=4'h7; 4'd10:word_bit=4'he; 4'd11:word_bit=4'h6; 4'd12:word_bit=4'h4; 4'd13:word_bit=4'ha; 4'd14:word_bit=4'h5; 4'd15:word_bit=4'h8; endcase
			3'd4: case(bit_) 4'd0:word_bit=4'h1; 4'd1:word_bit=4'h3; 4'd2:word_bit=4'hf; 4'd3:word_bit=4'h7; 4'd4:word_bit=4'hd; 4'd5:word_bit=4'ha; 4'd6:word_bit=4'he; 4'd7:word_bit=4'h9; 4'd8:word_bit=4'h0; 4'd9:word_bit=4'h8; 4'd10:word_bit=4'hc; 4'd11:word_bit=4'h4; 4'd12:word_bit=4'h6; 4'd13:word_bit=4'h5; 4'd14:word_bit=4'hb; 4'd15:word_bit=4'h2; endcase
			3'd5: word_bit = bit_; // identity
			3'd6: case(bit_) 4'd0:word_bit=4'h0; 4'd1:word_bit=4'hf; 4'd2:word_bit=4'h3; 4'd3:word_bit=4'h2; 4'd4:word_bit=4'he; 4'd5:word_bit=4'h4; 4'd6:word_bit=4'h6; 4'd7:word_bit=4'h7; 4'd8:word_bit=4'h8; 4'd9:word_bit=4'h9; 4'd10:word_bit=4'h5; 4'd11:word_bit=4'hd; 4'd12:word_bit=4'hc; 4'd13:word_bit=4'hb; 4'd14:word_bit=4'ha; 4'd15:word_bit=4'h1; endcase
			3'd7: case(bit_) 4'd0:word_bit=4'hf; 4'd1:word_bit=4'h2; 4'd2:word_bit=4'h3; 4'd3:word_bit=4'h1; 4'd4:word_bit=4'hb; 4'd5:word_bit=4'he; 4'd6:word_bit=4'hd; 4'd7:word_bit=4'h8; 4'd8:word_bit=4'h7; 4'd9:word_bit=4'h0; 4'd10:word_bit=4'h4; 4'd11:word_bit=4'hc; 4'd12:word_bit=4'h6; 4'd13:word_bit=4'ha; 4'd14:word_bit=4'h5; 4'd15:word_bit=4'h9; endcase
		endcase
	endfunction

	// output_byte_bitswaps[bitswap_select][bit]
	function automatic [2:0] byte_bit(input [2:0] sel, input [2:0] bit_);
		case (sel)
			3'd0: case(bit_) 3'd0:byte_bit=3'h4; 3'd1:byte_bit=3'h1; 3'd2:byte_bit=3'h3; 3'd3:byte_bit=3'h5; 3'd4:byte_bit=3'h6; 3'd5:byte_bit=3'h0; 3'd6:byte_bit=3'h7; 3'd7:byte_bit=3'h2; endcase
			3'd1: case(bit_) 3'd0:byte_bit=3'h6; 3'd1:byte_bit=3'h4; 3'd2:byte_bit=3'h1; 3'd3:byte_bit=3'h5; 3'd4:byte_bit=3'h2; 3'd5:byte_bit=3'h7; 3'd6:byte_bit=3'h0; 3'd7:byte_bit=3'h3; endcase
			3'd2: case(bit_) 3'd0:byte_bit=3'h2; 3'd1:byte_bit=3'h3; 3'd2:byte_bit=3'h4; 3'd3:byte_bit=3'h1; 3'd4:byte_bit=3'h0; 3'd5:byte_bit=3'h5; 3'd6:byte_bit=3'h6; 3'd7:byte_bit=3'h7; endcase
			3'd3: case(bit_) 3'd0:byte_bit=3'h1; 3'd1:byte_bit=3'h5; 3'd2:byte_bit=3'h0; 3'd3:byte_bit=3'h2; 3'd4:byte_bit=3'h6; 3'd5:byte_bit=3'h7; 3'd6:byte_bit=3'h4; 3'd7:byte_bit=3'h3; endcase
			3'd4: case(bit_) 3'd0:byte_bit=3'h7; 3'd1:byte_bit=3'h3; 3'd2:byte_bit=3'h0; 3'd3:byte_bit=3'h4; 3'd4:byte_bit=3'h5; 3'd5:byte_bit=3'h6; 3'd6:byte_bit=3'h2; 3'd7:byte_bit=3'h1; endcase
			3'd5: byte_bit = bit_; // identity
			3'd6: case(bit_) 3'd0:byte_bit=3'h6; 3'd1:byte_bit=3'h7; 3'd2:byte_bit=3'h5; 3'd3:byte_bit=3'h3; 3'd4:byte_bit=3'h4; 3'd5:byte_bit=3'h1; 3'd6:byte_bit=3'h0; 3'd7:byte_bit=3'h2; endcase
			3'd7: case(bit_) 3'd0:byte_bit=3'h1; 3'd1:byte_bit=3'h2; 3'd2:byte_bit=3'h6; 3'd3:byte_bit=3'h4; 3'd4:byte_bit=3'h0; 3'd5:byte_bit=3'h7; 3'd6:byte_bit=3'h3; 3'd7:byte_bit=3'h5; endcase
		endcase
	endfunction

	// ------------------------------------------------------------------
	// Registered config state (set_init_config's own MODE-gated latch)
	// ------------------------------------------------------------------
	reg [2:0] init_config;
	reg       init_done;
	assign initialized = init_done;

	always @(posedge clk) begin
		if (reset) begin
			init_config <= 3'd0;
			init_done   <= 1'b0;
		end else if (cfg_we && (cfg_data[3] == MODE[0])) begin
			init_config <= cfg_data[2:0];
			init_done   <= 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// Combinational descramble path — get_bitswap_select_value() then
	// decode_word()/decode_byte(), applied every cycle regardless of
	// `initialized` (matching the reference: decode_word/decode_byte
	// are plain const functions with no initialized-guard of their own
	// — callers only ever invoke them once mark_all_dirty()'d after
	// m_gfx_unscramble_enabled goes true, but the device itself doesn't
	// gate on it).
	// ------------------------------------------------------------------
	wire [12:0] eff_addr;
	genvar gi;
	generate
		for (gi = 0; gi < 13; gi = gi + 1)
			assign eff_addr[gi] = addr[ADDR_BITSWAP[gi]];
	endgenerate

	wire [2:0] sel_addr = {eff_addr[sel_bit(init_config,2'd2)],
	                        eff_addr[sel_bit(init_config,2'd1)],
	                        eff_addr[sel_bit(init_config,2'd0)]};

	wire [2:0] bitswap_select = {cfg_byte(init_config,2'd2)[sel_addr],
	                              cfg_byte(init_config,2'd1)[sel_addr],
	                              cfg_byte(init_config,2'd0)[sel_addr]};

	genvar gw, gb;
	generate
		for (gw = 0; gw < 16; gw = gw + 1)
			assign dout_word[gw] = din[word_bit(bitswap_select, gw[3:0])];
		for (gb = 0; gb < 8; gb = gb + 1)
			assign dout_byte[gb] = din8[byte_bit(bitswap_select, gb[2:0])];
	endgenerate

endmodule
