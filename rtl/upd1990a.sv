// uPD1990A calendar clock, as CSCP models it (src/vm/upd1990a.cpp): a 40-bit shift register (seconds, minutes,
// hours, day in BCD, day of week, month in hex, LSB first), commands C2-C0 taken at STB, CLK shifting DIN in at
// the top and the LSB out at DOUT.
//
//   0 register hold: counting; DOUT the seconds' LSB      1 register shift: each CLK shifts
//   2 time set: the register into the clock, held until  3 time read: the clock into the register
//     a 0, 1 or 3                                         4-6 TP rates (TP is not connected on the PC-8001)
//
// The time starts from the MiSTer's RTC (hps_io RTC: seconds, minutes, hours, day, month, year, weekday in BCD),
// taken once, when it first arrives. Months have 31, 30 or 28 days (the chip keeps no year).

module upd1990a #(parameter int CLK_HZ = 28636364)
(
	input         clk,
	input         reset,

	input  [64:0] rtc,            // hps_io RTC; bit 64 toggles when it is sent

	input   [2:0] c,              // C2-C0
	input         din,
	input         stb,            // rising edge: take the command
	input         clk_in,         // rising edge: shift (command 1)
	output        dout
);

reg  [7:0] sec = 0, min = 0, hour = 0, day = 8'h01;
reg  [3:0] wday = 0, mon = 4'd1;
reg [39:0] sh = 0;
reg  [3:0] mode = 0;
reg        hold = 0;
reg        sh_out = 0;             // DOUT shows the shift register's LSB (after a shift or a time read)
reg        dc = 0;                 // ... changed since the last second: kept through the next one too
reg        old_stb = 0, old_clk = 0;
reg        rtc_seen = 0, old_rtc64 = 0;

assign dout = sh_out ? sh[0] : sec[0];

// the seconds: restarted when a time set's hold ends (CSCP restarts its 1 s event then)
reg [24:0] div = 0;
reg        ce_1hz = 0;
wire       release_hold = hold && stb && !old_stb && (c == 3'd0 || c == 3'd1 || c == 3'd3);
always @(posedge clk) begin
	ce_1hz <= div == 25'(CLK_HZ - 1);
	div <= (div == 25'(CLK_HZ - 1) || release_hold) ? 25'd0 : div + 1'd1;
end

function automatic [7:0] bcd_inc(input [7:0] v);
	bcd_inc = v[3:0] == 4'd9 ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
endfunction

wire [7:0] mdays = mon == 4'd2 ? 8'h28 : (mon == 4'd4 || mon == 4'd6 || mon == 4'd9 || mon == 4'd11) ? 8'h30 : 8'h31;

always @(posedge clk) begin
	old_stb <= stb;
	old_clk <= clk_in;
	old_rtc64 <= rtc[64];

	if (!rtc_seen && rtc[64] != old_rtc64) begin
		rtc_seen <= 1'b1;
		sec <= rtc[7:0]; min <= rtc[15:8]; hour <= rtc[23:16]; day <= rtc[31:24];
		mon <= rtc[39:36] == 4'd1 ? rtc[35:32] + 4'd10 : rtc[35:32];
		wday <= rtc[51:48];
	end
	else if (ce_1hz && !hold) begin
		if (sec == 8'h59) begin
			sec <= 0;
			if (min == 8'h59) begin
				min <= 0;
				if (hour == 8'h23) begin
					hour <= 0;
					wday <= wday == 4'd6 ? 4'd0 : wday + 4'd1;
					if (day == mdays) begin
						day <= 8'h01;
						mon <= mon == 4'd12 ? 4'd1 : mon + 4'd1;
					end
					else day <= bcd_inc(day);
				end
				else hour <= bcd_inc(hour);
			end
			else min <= bcd_inc(min);
		end
		else sec <= bcd_inc(sec);
	end

	if (reset) begin
		mode <= 0; hold <= 0; sh_out <= 0; dc <= 0;
	end
	else begin
		if (clk_in && !old_clk && mode == 4'd1) sh <= {din, sh[39:1]};
		if (stb && !old_stb) begin
			mode <= {1'b0, c};
			case (c)
			3'd2: begin
				sec <= sh[7:0]; min <= sh[15:8]; hour <= sh[23:16]; day <= sh[31:24];
				wday <= sh[35:32]; mon <= sh[39:36];
				hold <= 1'b1;
			end
			3'd3: sh <= {mon, wday, day, hour, min, sec};
			default: ;
			endcase
			if (c == 3'd0 || c == 3'd1 || c == 3'd3) hold <= 1'b0;
		end
		// CSCP: each second DOUT goes back to the seconds' LSB, unless a shift or read changed it meanwhile
		if (ce_1hz) begin
			if (dc) dc <= 1'b0;
			else sh_out <= 1'b0;
		end
		if ((clk_in && !old_clk && mode == 4'd1) || (stb && !old_stb && c == 3'd3)) begin
			sh_out <= 1'b1; dc <= 1'b1;
		end
	end
end

endmodule
