// PC-8001 keyboard matrix (ports 00h-09h, a bit is 0 while its key is down) from MiSTer's ps2_key.
//
// Keys by position, JIS layout on a PC keyboard (as the PC-6001 core's "JP (positions)"); the matrix is
// HARDWARE_NOTES.md section 7 (MAME's INPUT_PORTS):
//   00 pad 0-7 | 01 pad 8 9 * + = , . RETURN | 02 @ A-G | 03 H-O | 04 P-W | 05 X Y Z [ yen ] ^ -
//   06 0-7 | 07 8 9 : ; , . / _ | 08 CLR UP RIGHT DEL GRPH KANA SHIFT CTRL | 09 STOP F1-F5 SPACE ESC
// The machine has one key for up/down, one for right/left and one for DEL/INS: Down, Left and Insert press
// SHIFT with it. F6-F8 and F10 are SHIFT + F1-F3, F5 (as on the machine). STOP: F9 or End or Pause.
// KANA is a lock key (Caps Lock or the JP kana key toggles it). GRPH: Alt. Page Up / Page Down: pad = and ,.

module pc8001_kbd
(
	input             clk,
	input             reset,
	input      [10:0] ps2_key,
	input       [3:0] row,
	output reg  [7:0] data
);

reg [7:0] m[0:9];          // 1 = pressed
reg       kana = 0;
reg       fshift = 0;      // SHIFT held for an F6-F10 / Down / Left / Insert key
reg       old_stb = 0;

integer i;

wire       press = ps2_key[9];
wire       ext   = ps2_key[8];
wire [7:0] code  = ps2_key[7:0];

reg [3:0] r;
reg [2:0] b;
reg       hit, sh;

always @(*) begin
	hit = 1; sh = 0; r = 0; b = 0;
	case ({ext, code})
	// 00, 01: pad
	9'h070: {r, b} = {4'd0, 3'd0};
	9'h069: {r, b} = {4'd0, 3'd1};
	9'h072: {r, b} = {4'd0, 3'd2};
	9'h07A: {r, b} = {4'd0, 3'd3};
	9'h06B: {r, b} = {4'd0, 3'd4};
	9'h073: {r, b} = {4'd0, 3'd5};
	9'h074: {r, b} = {4'd0, 3'd6};
	9'h06C: {r, b} = {4'd0, 3'd7};
	9'h075: {r, b} = {4'd1, 3'd0};
	9'h07D: {r, b} = {4'd1, 3'd1};
	9'h07C: {r, b} = {4'd1, 3'd2};
	9'h079: {r, b} = {4'd1, 3'd3};
	9'h17D: {r, b} = {4'd1, 3'd4};   // Page Up: pad =
	9'h17A: {r, b} = {4'd1, 3'd5};   // Page Down: pad ,
	9'h071: {r, b} = {4'd1, 3'd6};
	9'h05A, 9'h15A: {r, b} = {4'd1, 3'd7};
	// 02-04: letters
	9'h054: {r, b} = {4'd2, 3'd0};   // @
	9'h01C: {r, b} = {4'd2, 3'd1};
	9'h032: {r, b} = {4'd2, 3'd2};
	9'h021: {r, b} = {4'd2, 3'd3};
	9'h023: {r, b} = {4'd2, 3'd4};
	9'h024: {r, b} = {4'd2, 3'd5};
	9'h02B: {r, b} = {4'd2, 3'd6};
	9'h034: {r, b} = {4'd2, 3'd7};
	9'h033: {r, b} = {4'd3, 3'd0};
	9'h043: {r, b} = {4'd3, 3'd1};
	9'h03B: {r, b} = {4'd3, 3'd2};
	9'h042: {r, b} = {4'd3, 3'd3};
	9'h04B: {r, b} = {4'd3, 3'd4};
	9'h03A: {r, b} = {4'd3, 3'd5};
	9'h031: {r, b} = {4'd3, 3'd6};
	9'h044: {r, b} = {4'd3, 3'd7};
	9'h04D: {r, b} = {4'd4, 3'd0};
	9'h015: {r, b} = {4'd4, 3'd1};
	9'h02D: {r, b} = {4'd4, 3'd2};
	9'h01B: {r, b} = {4'd4, 3'd3};
	9'h02C: {r, b} = {4'd4, 3'd4};
	9'h03C: {r, b} = {4'd4, 3'd5};
	9'h02A: {r, b} = {4'd4, 3'd6};
	9'h01D: {r, b} = {4'd4, 3'd7};
	9'h022: {r, b} = {4'd5, 3'd0};
	9'h035: {r, b} = {4'd5, 3'd1};
	9'h01A: {r, b} = {4'd5, 3'd2};
	9'h05B: {r, b} = {4'd5, 3'd3};   // [
	9'h06A, 9'h00E: {r, b} = {4'd5, 3'd4};   // yen (JP key, or `)
	9'h05D: {r, b} = {4'd5, 3'd5};   // ]
	9'h055: {r, b} = {4'd5, 3'd6};   // ^
	9'h04E: {r, b} = {4'd5, 3'd7};   // -
	// 06, 07: digits and symbols
	9'h045: {r, b} = {4'd6, 3'd0};
	9'h016: {r, b} = {4'd6, 3'd1};
	9'h01E: {r, b} = {4'd6, 3'd2};
	9'h026: {r, b} = {4'd6, 3'd3};
	9'h025: {r, b} = {4'd6, 3'd4};
	9'h02E: {r, b} = {4'd6, 3'd5};
	9'h036: {r, b} = {4'd6, 3'd6};
	9'h03D: {r, b} = {4'd6, 3'd7};
	9'h03E: {r, b} = {4'd7, 3'd0};
	9'h046: {r, b} = {4'd7, 3'd1};
	9'h052: {r, b} = {4'd7, 3'd2};   // :
	9'h04C: {r, b} = {4'd7, 3'd3};   // ;
	9'h041: {r, b} = {4'd7, 3'd4};
	9'h049: {r, b} = {4'd7, 3'd5};
	9'h04A: {r, b} = {4'd7, 3'd6};
	9'h051: {r, b} = {4'd7, 3'd7};   // _ (JP ro key)
	// 08
	9'h16C: {r, b} = {4'd8, 3'd0};   // Home: CLR
	9'h175: {r, b} = {4'd8, 3'd1};   // Up
	9'h172: begin {r, b} = {4'd8, 3'd1}; sh = 1; end   // Down
	9'h174: {r, b} = {4'd8, 3'd2};   // Right
	9'h16B: begin {r, b} = {4'd8, 3'd2}; sh = 1; end   // Left
	9'h066, 9'h171: {r, b} = {4'd8, 3'd3};   // Backspace, Delete: DEL
	9'h170: begin {r, b} = {4'd8, 3'd3}; sh = 1; end   // Insert
	9'h011, 9'h111: {r, b} = {4'd8, 3'd4};   // Alt: GRPH
	9'h012, 9'h059: {r, b} = {4'd8, 3'd6};   // SHIFT
	9'h014, 9'h114: {r, b} = {4'd8, 3'd7};   // CTRL
	// 09
	9'h001, 9'h169, 9'h077: {r, b} = {4'd9, 3'd0};   // F9, End, Pause: STOP
	9'h005: {r, b} = {4'd9, 3'd1};
	9'h006: {r, b} = {4'd9, 3'd2};
	9'h004: {r, b} = {4'd9, 3'd3};
	9'h00C: {r, b} = {4'd9, 3'd4};
	9'h003: {r, b} = {4'd9, 3'd5};
	9'h00B: begin {r, b} = {4'd9, 3'd1}; sh = 1; end   // F6
	9'h083: begin {r, b} = {4'd9, 3'd2}; sh = 1; end   // F7
	9'h00A: begin {r, b} = {4'd9, 3'd3}; sh = 1; end   // F8
	9'h009: begin {r, b} = {4'd9, 3'd5}; sh = 1; end   // F10
	9'h029: {r, b} = {4'd9, 3'd6};
	9'h076: {r, b} = {4'd9, 3'd7};
	default: hit = 0;
	endcase
end

always @(posedge clk) begin
	old_stb <= ps2_key[10];
	if (reset) begin
		for (i = 0; i < 10; i = i + 1) m[i] <= 8'h00;
		kana <= 0;
		fshift <= 0;
	end
	else if (old_stb != ps2_key[10]) begin
		if ({ext, code} == 9'h058 || {ext, code} == 9'h013) begin
			if (press) kana <= ~kana;   // Caps Lock / JP kana: KANA lock
		end
		else if (hit) begin
			m[r][b] <= press;
			if (sh) fshift <= press;
		end
	end
end

always @(*) begin
	data = 8'hFF;
	if (row <= 4'd9) data = ~m[row];
	if (row == 4'd8) data = ~(m[8] | {1'b0, fshift, kana, 5'b00000});
end

endmodule
