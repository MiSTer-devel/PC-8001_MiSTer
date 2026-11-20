// OSD joystick: a pad pressing keys of the PC-8001 keyboard matrix (the machine had no joystick port; its games
// read the keys). OR'd into the matrix by rtl/pc8001_kbd.sv, so the keyboard keeps working and a held direction
// stays held. Acts at once (status, not cfg).
//
// joy (hps_io joystick_0, CONF_STR J1): 0 right, 1 left, 2 down, 3 up, 4 A, 5 B, 6 C, 7 Start, 8 Select, 9 STOP.
// mode: 0 Off, 1 Numpad (8 2 4 6), 2 Cursor keys (UP, RIGHT; down and left press SHIFT with them as the
//   machine's own keys do, and the SR's row 0Ah down / left), 3 Auto: the known tape's map (auto_map, from
//   tools/tape_db.txt joy:), else Numpad with the OSD's diag and buttons.
// auto_map: {valid, mode[1:0], diag, key ids of A, B, C}.
// diag (Numpad only): 0 two keys at once (8+6), 1 one key (7 9 1 3).
// a / b / c: the button's key, by its OSD row (each row lists its default first):
//   A: Space, Return, SHIFT, Z, X, Numpad 0, Numpad 5
//   B: Return, Space, SHIFT, Z, X, Numpad 0, Numpad 5
//   C: SHIFT, Space, Return, Z, X, Numpad 0, Numpad 5
// Start = Return, Select = Space, STOP = STOP.
// keys: row r at bits 8r+7..8r (rows 00h-0Ah, HARDWARE_NOTES.md section 7), 1 = pressed.

module pc8001_joy
(
	input       [9:0] joy,
	input       [1:0] mode,
	input             diag,
	input       [2:0] a,
	input       [2:0] b,
	input       [2:0] c,
	input      [12:0] auto_map,
	output reg [87:0] keys
);

// key ids: 0 Space, 1 Return, 2 SHIFT, 3 Z, 4 X, 5 pad 0, 6 pad 5
function automatic [87:0] key(input [2:0] id);
	key = 0;
	case (id)
	3'd0: key[9*8 + 6] = 1;     // SPACE
	3'd1: key[1*8 + 7] = 1;     // RETURN
	3'd2: key[8*8 + 6] = 1;     // SHIFT
	3'd3: key[5*8 + 2] = 1;     // Z
	3'd4: key[5*8 + 0] = 1;     // X
	3'd5: key[0*8 + 0] = 1;     // pad 0
	3'd6: key[0*8 + 5] = 1;     // pad 5
	default: ;
	endcase
endfunction

// pad digit n: row 0 bit n (0-7), row 1 bits 0-1 (8, 9): bit n of keys
function automatic [87:0] pad(input [3:0] n);
	pad = 0;
	pad[n] = 1;
endfunction

// OSD order (status[19:18]): 0 Auto (the default), 1 Numpad, 2 Cursor keys, 3 Off
wire [1:0] mo = mode == 2'd0 ? 2'd3 : mode == 2'd3 ? 2'd0 : mode;
wire r = joy[0], l = joy[1], d = joy[2], u = joy[3];
wire [2:0] b_osd = b == 3'd0 ? 3'd1 : b == 3'd1 ? 3'd0 : b;
wire [2:0] c_osd = c == 3'd0 ? 3'd2 : c == 3'd2 ? 3'd1 : c == 3'd1 ? 3'd0 : c;
wire       am   = mo == 2'd3 && auto_map[12];
wire [1:0] md   = mo == 2'd3 ? (am ? auto_map[11:10] : 2'd1) : mo;
wire       dg   = am ? auto_map[9] : diag;
wire [2:0] a_id = am ? auto_map[8:6] : a;
wire [2:0] b_id = am ? auto_map[5:3] : b_osd;
wire [2:0] c_id = am ? auto_map[2:0] : c_osd;

always @(*) begin
	keys = 0;
	if (md == 2'd1) begin
		if (dg && u && r)      keys = pad(4'd9);
		else if (dg && u && l) keys = pad(4'd7);
		else if (dg && d && r) keys = pad(4'd3);
		else if (dg && d && l) keys = pad(4'd1);
		else begin
			if (u) keys = keys | pad(4'd8);
			if (d) keys = keys | pad(4'd2);
			if (l) keys = keys | pad(4'd4);
			if (r) keys = keys | pad(4'd6);
		end
	end
	else if (md == 2'd2) begin
		if (u | d) keys[8*8 + 1] = 1;              // UP (down: SHIFT + UP)
		if (r | l) keys[8*8 + 2] = 1;              // RIGHT (left: SHIFT + RIGHT)
		if (d | l) keys[8*8 + 6] = 1;              // SHIFT
		if (d) keys[10*8 + 1] = 1;                 // SR down
		if (l) keys[10*8 + 2] = 1;                 // SR left
	end
	if (md != 2'd0) begin
		if (joy[4]) keys = keys | key(a_id);
		if (joy[5]) keys = keys | key(b_id);
		if (joy[6]) keys = keys | key(c_id);
		if (joy[7]) keys = keys | key(3'd1);       // Start: Return
		if (joy[8]) keys = keys | key(3'd0);       // Select: Space
		if (joy[9]) keys[9*8 + 0] = 1;             // STOP
	end
end

endmodule
