//
// m7_reg_stream.sv — HD Mode 7 FPGA->ARM status stream (PIVOT, 2026-10-12).
//
// The f2sdram port-1 WRITE path is broken on this device at every usable
// port clock — accepted and acked but never committed (proven at clk_mem
// across three independent placements, and at clk_sys with a healthy
// arbiter: acks toggle, WE pulses fire, the array never changes) — so the
// register stream cannot ride the DDR3 mailbox. This module serializes it
// on the HPS UART1 periphery (/dev/ttyS1) instead: the same channel the
// debug telemetry used, at a raised baud with binary framing. Every other
// transport in the final architecture is an already-proven operation:
// ARM CPU writes for pixels/control, FPGA reads at clk_sys.
//
// P2a: test-pattern mode (test_mode=1). A free-running generator emits
// fixed-size frames whose payload is position-dependent, so a raw capture
// on the ARM measures BOTH slip (lost/inserted bytes) and bit-error rate
// at the target baud before anything is built on this link.
//
// Telemetry mode (test_mode=2): the payload is a snapshot of dbg_bytes
// (assembled by the parent from live HD-engine state), latched once per
// frame at the sync bytes. This is the FPGA->ARM debug channel AND the
// shape of the future per-line register stream (P2c) — same framing, real
// content.
//
// Production mix (test_mode=3, P2c-2): the payload slots carry the parent's
// per-line record stream, with telemetry interleaved so debug visibility
// survives. Payload[0] discriminates: 0xC3 = telemetry snapshot (same
// layout as mode 2), anything else = a slice of the record byte stream.
// Records are len-prefixed ([len][line][mask][values...], len includes
// itself), pushed whole by the parent; a record may straddle two payloads
// (the receiver carries the partial) and a CRC-failed payload invalidates
// the stream until the next line-0xFE full sync at the next vblank.
// Wire budget at 3 Mbaud: payload opportunities ~1100/s; every 64th is
// telemetry (P2c-4: was 1-in-16 — the measured channel budget per line
// period is ~18 B, and telemetry took 6.25 % of it; 1.56 % frees ~14 kB/s
// for line records), the rest carry records only when the FIFO is non-empty
// (idle slots are skipped, keeping the link quiet). 63/64 * 256 B * 1100/s
// ~ 278 KB/s of record bandwidth.
//
// Frame (little-endian):
//   A5 5C seq_l seq_h len_l len_h payload[0..len-1] crc8
//   test-mode payload[i] = (seq + i) ^ A7  (self-describing: detects slips
//   and bit errors from the capture alone)
//   crc8 (poly 0x07) covers seq..payload, NOT the sync bytes — the scanner
//   must be able to find A5 5C blind.
//
// Baud: NCO fractional divider (mean error ~0.01 %, bounded phase jitter;
// an integer divisor at 3 Mbaud off 21.477 MHz would be +2.3 %, which the
// HPS UART tolerates but why spend the margin).
//
module m7_reg_stream #(
	parameter [31:0] CLK_HZ      = 21_477_272, // clk_sys (4x dot clock, NTSC)
	parameter [31:0] BAUD        = 3_000_000,
	parameter [15:0] PAYLOAD_LEN = 256
)(
	input        clk,
	input        rst,          // synchronous, active high (~RESET_N)
	input  [1:0] test_mode,    // 0=off 1=pattern 2=telemetry 3=records+telemetry
	input [255:0][7:0] dbg_bytes, // telemetry payload (sampled per frame)
	input        rec_wr,       // record byte push (whole records, in order)
	input  [7:0] rec_data,
	output       rec_room,     // 1 = space for another record; drop when 0
	output wire [10:0] rec_count, // FIFO fill level (parent sizes its records
	                              // against this before staging them)
	output reg   txd = 1'b1
);

	// ------------------------------------------------------------------
	// NCO baud generator: STEP = BAUD/CLK * 2^32 (32-bit accumulator!)
	// ------------------------------------------------------------------
	localparam [31:0] NCO_STEP =
		((BAUD * 64'd4294967296) + (CLK_HZ/2)) / CLK_HZ;

	reg  [31:0] nco_acc = 0;
	wire [32:0] nco_sum = {1'b0, nco_acc} + NCO_STEP;
	wire        nco_tick = nco_sum[32];

	always @(posedge clk) nco_acc <= nco_sum[31:0];

	// ------------------------------------------------------------------
	// Byte FIFO: generator -> serializer (drains ~1 byte / 70 clk at 3 M)
	// ------------------------------------------------------------------
	reg [7:0] fifo [0:15];
	reg [3:0] fifo_wr = 0, fifo_rd = 0;
	wire [4:0] fifo_count = fifo_wr - fifo_rd;
	wire       fifo_full  = (fifo_count >= 5'd14);
	wire       fifo_empty = (fifo_wr == fifo_rd);

	// ------------------------------------------------------------------
	// Record FIFO (P2c-2): the parent pushes len-prefixed records whole.
	// 512 B absorbs >3 lines of worst-case records between payload slots.
	// Same clk domain as the parent (clk_sys), 1 byte/cycle in, drained
	// 1 byte/cycle by the payload assembler.
	// ------------------------------------------------------------------
	reg [7:0]  rec_mem [0:511];
	reg [9:0]  rec_w = 10'd0, rec_r = 10'd0;
	wire [10:0] rec_cnt = rec_w - rec_r;
	assign rec_count = rec_cnt;
	// Room gate for line records. Two records must ALWAYS fit after the
	// gate closes: the worst in-flight/queued line record (20 B) and the
	// unconditional vblank sync (20 B) — the sync branch has no room
	// check, and fill reaching 512 aliases the 10-bit pointers (count
	// wraps to 0). 471 + 20 + 20 = 511: exactly full, never aliased.
	assign rec_room = (rec_cnt < 11'd472);
	wire       rec_avail = (rec_r != rec_w);

	always @(posedge clk) begin
		if (rec_wr) begin
			rec_mem[rec_w[8:0]] <= rec_data;
			rec_w <= rec_w + 10'd1;
		end
	end

	// ------------------------------------------------------------------
	// Frame generator: one byte emitted per state entry, push + CRC step
	// in the same clocked branch (no cross-block tangles).
	// ------------------------------------------------------------------
	localparam [2:0] G_GAP=0, G_SYNC1=1, G_SYNC2=2, G_HDR=3, G_PAY=4, G_CRC=5;
	reg  [2:0]  g_state = G_GAP;
	reg  [15:0] g_seq   = 16'd0;
	reg  [7:0]  g_crc   = 8'd0;
	reg  [15:0] g_idx   = 16'd0;
	reg  [15:0] g_gap   = 16'd0;
	reg  [7:0]  slot_cnt = 8'd0;  // payload opportunities, mod 64 (mode 3)

	wire [7:0] hdr_byte = (g_idx == 0) ? g_seq[7:0] :
	                      (g_idx == 1) ? g_seq[15:8] :
	                      (g_idx == 2) ? PAYLOAD_LEN[7:0] :
	                                     PAYLOAD_LEN[15:8];
	// Payload source: pattern (BER self-test), the latched telemetry
	// snapshot, or the record byte stream. dbg_shadow is taken at the sync
	// bytes so one frame's bytes all belong to the same instant.
	reg [255:0][7:0] dbg_shadow;
	reg        is_tel = 1'b1;   // this payload is telemetry (mode 3 only)
	wire [7:0] rec_byte_q = rec_mem[rec_r[8:0]];
	wire [7:0] pay_byte = (test_mode == 2'd1) ? ((g_seq[7:0] + g_idx[7:0]) ^ 8'hA7) :
	                      (test_mode == 2'd2 || is_tel) ? dbg_shadow[g_idx[7:0]] :
	                      rec_avail ? rec_byte_q : 8'h00;

	function [7:0] crc8_next(input [7:0] c, input [7:0] b);
		reg [7:0] x;
		begin
			x = c ^ b;
			repeat (8) x = x[7] ? ({x[6:0], 1'b0} ^ 8'h07) : {x[6:0], 1'b0};
			crc8_next = x;
		end
	endfunction

	always @(posedge clk) begin
		if (rst) begin
			g_state <= G_GAP;
			g_seq   <= 16'd0;
		end else begin
			case (g_state)
				// idle gap (~64 baud bits) between frames lets the checker
				// resync. In mode 3 a non-telemetry slot with an empty
				// record FIFO is skipped: the slot counter still advances
				// so telemetry keeps its 1-in-64 cadence (P2c-4: 16->64
				// frees ~14 kB/s of the 3 Mbaud channel for line records —
				// the daemon watchdog grace is matched to this cadence),
				// but the link stays quiet while no records are pending.
				G_GAP: if (test_mode != 2'd0 && &g_gap[5:0] && !fifo_full) begin
					if (test_mode == 2'd3 && slot_cnt != 8'h00 && !rec_avail) begin
						g_gap    <= 16'd0;
						slot_cnt <= slot_cnt + 8'd1;
					end else begin
						g_gap    <= 16'd0;
						g_state  <= G_SYNC1;
						slot_cnt <= slot_cnt + 8'd1;
						is_tel   <= (test_mode != 2'd3) || (slot_cnt == 8'h00);
					end
				end else if (nco_tick)
					g_gap <= g_gap + 16'd1;

				G_SYNC1: if (!fifo_full) begin
					dbg_shadow    <= dbg_bytes;   // telemetry snapshot point
					fifo[fifo_wr] <= 8'hA5;
					fifo_wr       <= fifo_wr + 4'd1;
					g_state       <= G_SYNC2;
				end

				G_SYNC2: if (!fifo_full) begin
					fifo[fifo_wr] <= 8'h5C;
					fifo_wr       <= fifo_wr + 4'd1;
					g_crc         <= 8'd0;
					g_idx         <= 16'd0;
					g_state       <= G_HDR;
				end

				G_HDR: if (!fifo_full) begin
					fifo[fifo_wr] <= hdr_byte;
					fifo_wr       <= fifo_wr + 4'd1;
					g_crc         <= crc8_next(g_crc, hdr_byte);
					g_idx         <= g_idx + 16'd1;
					if (g_idx == 16'd3) begin
						g_idx   <= 16'd0;
						g_state <= G_PAY;
					end
				end

				G_PAY: if (!fifo_full) begin
					fifo[fifo_wr] <= pay_byte;
					fifo_wr       <= fifo_wr + 4'd1;
					g_crc         <= crc8_next(g_crc, pay_byte);
					g_idx         <= g_idx + 16'd1;
					// consume the record byte that pay_byte exposed
					if (test_mode == 2'd3 && !is_tel && rec_avail)
						rec_r <= rec_r + 10'd1;
					if (g_idx == PAYLOAD_LEN - 16'd1) begin
						g_idx   <= 16'd0;
						g_state <= G_CRC;
					end
				end

				G_CRC: if (!fifo_full) begin
					fifo[fifo_wr] <= g_crc;
					fifo_wr       <= fifo_wr + 4'd1;
					g_seq         <= g_seq + 16'd1;
					g_state       <= G_GAP;
				end

				default: g_state <= G_GAP;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// Bit serializer: 10 baud bits per byte (start d0..d7 stop)
	// ------------------------------------------------------------------
	localparam [1:0] S_IDLE=0, S_BITS=1;
	reg [1:0]  s_state = S_IDLE;
	reg [9:0]  s_shift = 10'h3FF;
	reg [3:0]  s_bits  = 0;

	always @(posedge clk) begin
		if (rst) begin
			s_state <= S_IDLE;
			txd     <= 1'b1;
		end else begin
			case (s_state)
				S_IDLE: if (!fifo_empty) begin
					s_shift <= {1'b1, fifo[fifo_rd[3:0]], 1'b0};
					s_bits  <= 4'd0;
					s_state <= S_BITS;
					fifo_rd <= fifo_rd + 4'd1;
				end
				S_BITS: if (nco_tick) begin
					txd     <= s_shift[0];
					s_shift <= {1'b1, s_shift[9:1]};
					s_bits  <= s_bits + 4'd1;
					if (s_bits == 4'd9) s_state <= S_IDLE;
				end
				default: s_state <= S_IDLE;
			endcase
		end
	end

endmodule
