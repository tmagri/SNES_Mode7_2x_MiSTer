//
// ddram.v
// Copyright (c) 2017,2019 Sorgelig
//
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//

// 16-bit version

module ddram
(
	input         DDRAM_CLK,

	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	input         cache_rst,

	input  [31:3] rdaddr,
	output [63:0] dout,
	input  [63:0] rom_din,
	input   [7:0] rom_be,
	input         rom_we,
	input         rom_req,
	output reg    rom_ack,

	input  [31:3] rdaddr2,
	output [63:0] dout2,
	input         rd_req2,
	output reg    rd_ack2,

	// HD Mode 7 fetch client (PIVOT v2, 2026-10-12). The old 16-bit mailbox
	// write port is GONE: f2sdram port-1 FPGA writes are broken on this device
	// at every usable clock (accepted/acked but never committed — proven at
	// clk_mem across three placements and at clk_sys with a healthy arbiter),
	// so nothing in this core writes DDR3 anymore except the ARM CPU.
	// The fetch client reads the daemon's pixel buffer with the same proven
	// transaction shape as the rom path: burst-1, one ack per word. It is
	// arbitrated LAST — the only client with soft (per-scanline) deadlines.
	input  [31:3] hd_addr,
	input         hd_req,
	output reg    hd_ack = 1'b0,
	output [63:0] hd_dout,

	// DEBUG (M7 debug builds): observe the FSM directly from the parent —
	// states 2/3 stall forever when the f2sdram port never returns
	// readdatavalid, and nothing outside this module can see the difference
	// between "wedged in state 2" and "idle in state 0".
	output [1:0]  dbg_state
);

reg  [7:0] ram_burst;
reg [63:0] ram_q, next_q, ram_q2, next_q2, hd_q;
reg [63:0] ram_data;
reg [31:3] ram_address, cache_addr, cache_addr2;
reg        ram_read = 0;
reg        ram_write = 0;
reg  [7:0] ram_be = 0;

reg [1:0]  state  = 0;
reg [1:0]  ch = 2'd0;   // 2 bits: 0=rom 1=MSU 2=HD fetch (was 1 bit — a 2'd2
                        // client ID silently truncated to 0 and every HD
                        // completion misrouted into the rom branch, so the
                        // fetch FSM never saw a single ack)
reg        hd_turn = 1'b0;  // HD interleave: when both rom and HD are pending,
                            // hand this slot to HD every other time. Lowest
                            // priority starved HD to 8 rows/frame behind SMK's
                            // cart traffic; strict alternation gives HD ~50%
                            // of contended slots while both stay pending.

reg [1:0]  cache_valid;

assign DDRAM_BURSTCNT = ram_burst;
assign DDRAM_BE       = ram_be | {8{ram_read}};
assign DDRAM_ADDR     = ram_address;
assign DDRAM_RD       = ram_read;
assign DDRAM_DIN      = ram_data;
assign DDRAM_WE       = ram_write;

//assign dout  =  ram_q[{rdaddr[2:1],  4'b0000} +:16];
//assign dout2 = ram_q2[{rdaddr2[2:1], 4'b0000} +:16];
assign dout = ram_q;
assign dout2 = ram_q2;
assign hd_dout = hd_q;

assign dbg_state = state;

always @(posedge DDRAM_CLK) begin
	if (cache_rst) begin
		cache_valid <= 2'b00;
	end

	if(!DDRAM_BUSY) begin
		ram_write <= 0;
		ram_read  <= 0;

		case(state)
			// HD interleave: when both rom and HD are pending and hd_turn is
			// set, skip the rom/MSU chain this slot and serve HD below. The
			// old lowest-priority placement let the HD sweep starve behind
			// cart traffic (8 rows/frame, lap = 28 frames — the row-age
			// gradient across the lap IS the visible banding). Rom absorbs
			// the extra one-word latency via the core's clock-stretch, the
			// same mechanism that absorbs all its DDR3 latency.
			0: if((rom_req != rom_ack) && !((hd_req != hd_ack) && hd_turn)) begin
					if(rom_we) begin
						ram_be      <= rom_be;
						ram_data	<= rom_din;
						ram_address <= rdaddr[31:3];
						ram_write 	<= 1;
						ram_burst   <= 1;
						ch          <= 0;
						state       <= 1;
					end
					else if(cache_valid[0] & (cache_addr == rdaddr[31:3])) rom_ack <= rom_req;
					else if(cache_valid[0] & ((cache_addr+1'd1) == rdaddr[31:3])) begin
						rom_ack     <= rom_req;
						ram_q       <= next_q;
						cache_addr  <= rdaddr[31:3];
						ram_address <= rdaddr[31:3]+1'd1;
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 0; 
						state       <= 3;
					end
					else begin
						ram_address <= rdaddr[31:3];
						cache_addr  <= rdaddr[31:3];
						ram_read    <= 1;
						ram_burst   <= 1;	// burst-1: this device's f2sdram port1 never
											// returns data for multi-beat reads (observed
											// 2026-10-11: burst-2 hung the port, burst-1
											// reads complete). Costs one transaction per
											// word; the addr+1 read cache below is inert.
						ch 			<= 0;
						state       <= 2;
					end
				end
				else if(rd_req2 != rd_ack2) begin
					if(cache_valid[1] & (cache_addr2 == rdaddr2[31:3])) rd_ack2 <= rd_req2;
					else if(cache_valid[1] & ((cache_addr2+1'd1) == rdaddr2[31:3])) begin
						rd_ack2     <= rd_req2;
						ram_q2      <= next_q2;
						cache_addr2 <= rdaddr2[31:3];
						ram_address <= rdaddr2[31:3]+1'd1;
						ram_read    <= 1;
						ram_burst   <= 1;
						ch 			<= 1;
						state       <= 3;
					end
					else begin
						ram_address <= rdaddr2[31:3];
						cache_addr2 <= rdaddr2[31:3];
						ram_read    <= 1;
						ram_burst   <= 2;
						ch 			<= 1;
						state       <= 2;
					end
				end
				// HD Mode 7 fetch: burst-1 word read (see port comment). No
				// read cache — rows are streamed once and not re-visited.
				// hd_turn toggles only here: while both clients stay pending
				// this branch and the rom branch above alternate slots.
				else if(hd_req != hd_ack) begin
					ram_address <= hd_addr;
					ram_read    <= 1;
					ram_burst   <= 1;
					ch          <= 2'd2;
					state       <= 2;
					hd_turn     <= ~hd_turn;
				end

			1: begin
					cache_valid <= 2'b00;
					rom_ack <= rom_req;
					state <= 0;
				end

			2: if(DDRAM_DOUT_READY) begin
					if (ch == 2'd2) begin
						hd_q    <= DDRAM_DOUT;
						hd_ack  <= hd_req;
						state   <= 0;
					end
					else if (~ch) begin
						ram_q  <= DDRAM_DOUT;
						rom_ack <= rom_req;
						state <= 0;		// burst-1: single beat, done (was: wait beat 2)
					end
					else begin
						ram_q2  <= DDRAM_DOUT;
						rd_ack2 <= rd_req2;
						state <= 3;
					end
				end

			3: if(DDRAM_DOUT_READY) begin
					if (~ch) begin
						next_q <= DDRAM_DOUT;
						cache_valid[0] <= 1'b1;
					end
					else begin
						next_q2 <= DDRAM_DOUT;
						cache_valid[1] <= 1'b1;
					end
					state <= 0;
				end
		endcase
	end
end

endmodule
