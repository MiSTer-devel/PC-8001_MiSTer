// PC-8001 keyboard matrix (ports 00h-09h, a bit is 0 while its key is down) from MiSTer's ps2_key.
//
// Keys by position, JIS layout on a PC keyboard (as the PC-6001 core's "JP (positions)"); the matrix is
// HARDWARE_NOTES.md section 7 (MAME's INPUT_PORTS):
//   00 pad 0-7 | 01 pad 8 9 * + = , . RETURN | 02 @ A-G | 03 H-O | 04 P-W | 05 X Y Z [ yen ] ^ -
//   06 0-7 | 07 8 9 : ; , . / _ | 08 CLR UP RIGHT DEL GRPH KANA SHIFT CTRL | 09 STOP F1-F5 SPACE ESC
// The machine has one key for up/down, one for right/left and one for DEL/INS: Down, Left and Insert press
// SHIFT with it. F6-F8 and F10 are SHIFT + F1-F3, F5 (as on the machine). STOP: F9 or End (not Pause: Main sends
// no release for it, and its 77h, Num Lock's code, is left pressed).
// KANA is a lock key (Caps Lock, right Alt or the JP kana key toggles it). GRPH: left Alt. Page Up / Page Down: pad = and ,.
//
// kbd_us (OSD Keyboard = US): the symbols printed on a US keyboard. A symbol key whose JIS key or shift differs
// presses the JIS key with SHIFT as that symbol needs, while it is held (one such key at a time). Not with
// KANA or GRPH, where the JIS positions stay.
// When that SHIFT differs from the SHIFT key held, the SHIFT state changes first and the JIS key follows
// ~50 ms later: BASIC reads SHIFT (port 08h, 1007h) apart from the key scan (1041h) and decodes a key with the
// SHIFT it saw last, so a key whose SHIFT changes with it reads as the other symbol (US ^ as SHIFT+^, : as *).
// That key is then held at least ~33 ms (BASIC takes a key seen in two scans).

module pc8001_kbd
(
	input             clk,
	input             reset,
	input      [10:0] ps2_key,
	input             kbd_us,
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
	9'h011: {r, b} = {4'd8, 3'd4};           // left Alt: GRPH
	9'h012, 9'h059: {r, b} = {4'd8, 3'd6};   // SHIFT
	9'h014, 9'h114: {r, b} = {4'd8, 3'd7};   // CTRL
	// 09
	9'h001, 9'h169: {r, b} = {4'd9, 3'd0};   // F9, End: STOP
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

// US symbols: {valid, row, bit, SHIFT} of the JIS key for a US key and the shift held
function automatic [8:0] us_map(input [7:0] c, input s);
	case ({c, s})
	{8'h1E, 1'b1}: us_map = {1'b1, 4'd2, 3'd0, 1'b0};   // @
	{8'h36, 1'b1}: us_map = {1'b1, 4'd5, 3'd6, 1'b0};   // ^
	{8'h3D, 1'b1}: us_map = {1'b1, 4'd6, 3'd6, 1'b1};   // &
	{8'h3E, 1'b1}: us_map = {1'b1, 4'd7, 3'd2, 1'b1};   // *
	{8'h46, 1'b1}: us_map = {1'b1, 4'd7, 3'd0, 1'b1};   // (
	{8'h45, 1'b1}: us_map = {1'b1, 4'd7, 3'd1, 1'b1};   // )
	{8'h4E, 1'b1}: us_map = {1'b1, 4'd7, 3'd7, 1'b1};   // _
	{8'h55, 1'b0}: us_map = {1'b1, 4'd5, 3'd7, 1'b1};   // =
	{8'h55, 1'b1}: us_map = {1'b1, 4'd7, 3'd3, 1'b1};   // +
	{8'h54, 1'b0}: us_map = {1'b1, 4'd5, 3'd3, 1'b0};   // [
	{8'h54, 1'b1}: us_map = {1'b1, 4'd5, 3'd3, 1'b1};   // {
	{8'h5B, 1'b0}: us_map = {1'b1, 4'd5, 3'd5, 1'b0};   // ]
	{8'h5B, 1'b1}: us_map = {1'b1, 4'd5, 3'd5, 1'b1};   // }
	{8'h5D, 1'b0}: us_map = {1'b1, 4'd5, 3'd4, 1'b0};   // backslash: yen
	{8'h5D, 1'b1}: us_map = {1'b1, 4'd5, 3'd4, 1'b1};   // |
	{8'h4C, 1'b1}: us_map = {1'b1, 4'd7, 3'd2, 1'b0};   // :
	{8'h52, 1'b0}: us_map = {1'b1, 4'd6, 3'd7, 1'b1};   // '
	{8'h52, 1'b1}: us_map = {1'b1, 4'd6, 3'd2, 1'b1};   // "
	default: us_map = 9'd0;
	endcase
endfunction

wire       pshift = m[8][6];
wire [8:0] us = us_map(code, pshift);
wire       us_on = kbd_us && !ext && us[8] && !kana && !m[8][4];
reg        ov = 0, ov_sh = 0;      // a US symbol key held: its JIS key is pressed with SHIFT = ov_sh
reg  [7:0] ov_code;
reg  [6:0] ov_pos;
reg        ov_key = 0;             // its JIS key is down (else waiting for SHIFT to settle)
reg        ov_rel = 0;             // released before the minimum hold ended
reg [20:0] ov_cnt = 0;
localparam OV_WAIT = 21'd1431818;  // 50 ms (3 frames) at 28.636 MHz: SHIFT settles
localparam OV_HOLD = 21'd954545;   // 33 ms (2 frames): the shortest press

always @(posedge clk) begin
	old_stb <= ps2_key[10];
	if (reset) begin
		for (i = 0; i < 10; i = i + 1) m[i] <= 8'h00;
		kana <= 0;
		fshift <= 0;
		ov <= 0;
		ov_key <= 0;
		ov_cnt <= 0;
	end
	else begin
	if (ov && ov_cnt != 0) begin
		ov_cnt <= ov_cnt - 1'd1;
		if (ov_cnt == 21'd1) begin
			if (!ov_key) begin              // SHIFT settled: the key, held at least OV_HOLD
				m[ov_pos[6:3]][ov_pos[2:0]] <= 1'b1;
				ov_key <= 1'b1;
				ov_cnt <= OV_HOLD;
			end
			else if (ov_rel) begin          // released during the wait or the hold
				m[ov_pos[6:3]][ov_pos[2:0]] <= 1'b0;
				ov <= 0;
			end
		end
	end
	if (old_stb != ps2_key[10]) begin
		if ({ext, code} == 9'h058 || {ext, code} == 9'h013 || {ext, code} == 9'h111) begin
			if (press) kana <= ~kana;   // Caps Lock / JP kana / right Alt: KANA lock
		end
		else if (ov && !ext && code == ov_code) begin
			if (!press) begin
				if (ov_key && ov_cnt == 0) begin m[ov_pos[6:3]][ov_pos[2:0]] <= 1'b0; ov <= 0; end
				else ov_rel <= 1'b1;
			end
		end
		else if (press && us_on) begin
			if (ov) m[ov_pos[6:3]][ov_pos[2:0]] <= 1'b0;
			ov <= 1'b1; ov_sh <= us[0]; ov_code <= code; ov_pos <= us[7:1]; ov_rel <= 0;
			if (us[0] == (pshift | fshift)) begin
				m[us[7:4]][us[3:1]] <= 1'b1;
				ov_key <= 1'b1;
				ov_cnt <= 0;
			end
			else begin
				ov_key <= 1'b0;
				ov_cnt <= OV_WAIT;
			end
		end
		else if (hit) begin
			m[r][b] <= press;
			if (sh) fshift <= press;
		end
	end
	end
end

always @(*) begin
	data = 8'hFF;
	if (row <= 4'd9) data = ~m[row];
	if (row == 4'd8) data = ~({m[8][7], ov ? ov_sh : (pshift | fshift), m[8][5] | kana, m[8][4:0]});
end

endmodule
