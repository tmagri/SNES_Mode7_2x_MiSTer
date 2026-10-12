//
// m7_dbg_uart.sv — HD Mode 7 mailbox write-path reporter (/dev/ttyS1).
//
// TX-only UART in the style of TI89_MiSTer's rtl/dbg_uart.sv: every 250 ms it
// snapshots the M7 mailbox→DDR3 write-path state and emits one ASCII line at
// 115200 baud 8N1. sys_top.v already routes the core's UART_TXD to the HPS
// UART1 controller through the peripheral-UART fabric interface (see the
// HPSINTERFACEPERIPHERALUART location assignment in SNES.qsf), so the lines
// are readable on the MiSTer itself over ssh:
//
//   stty -F /dev/ttyS1 115200 raw -echo && cat /dev/ttyS1
//
// Line format (values hex unless noted), 99 bytes incl. CRLF:
//   [M7] F=seq M=mbst D=dmst W=wr A=ack E=we RD=rdy B=busy C=cli T=wt
//        H=hdr HA=addr HD=data P0=probe0 P1=probe1
//
//   F   frame_seq  — mailbox header triggers served (~80 Hz under
//                    M7_DEBUG_MAILBOX; stuck at 0 = trigger logic dead)
//   M   mb_state   — mailbox service FSM (IDLE=0 ADDR=1 WAIT=2 WRITE=3)
//   D   dm_state   — HD DMA fetch FSM state
//   W   mailbox writes issued this window (mb_we_req toggles)
//   A   ddram acks this window            (mb_we_ack changes)
//   E   DDRAM_WE edges this window        (writes accepted by the EMIF port)
//   RD  DDRAM_DOUT_READY edges this window (read data returned)
//   B   DDRAM_BUSY live level (solid 1 = f2sdram waitrequest stuck)
//   C   active_client live level
//   T   wt_cnt — write-through FIFO occupancy (0..8)
//   H   header-region writes this window (wraddr == 0x3E000000)
//   HA  last mailbox write's byte offset (wraddr[16:1])
//   HD  last mailbox write's data (din)
//   P0  FPGA readback of 0x3E000000 (via the savestate read path)
//   P1  FPGA readback of 0x3F800008 (CPU wrote 0xA5A51234 there with an
//       O_SYNC /dev/mem write)
//
// Dead-link decode matrix (ARM-side reads MUST use an O_SYNC /dev/mem tool —
// busybox devmem maps RAM cacheable and reports stale zeros):
//   F stuck 0            → header trigger logic never fires
//   F climbs, W=0        → mb FSM never services (arbitration starved)
//   W>0, A=0             → ddram.sv never completes (port dead/stuck)
//   P1 == A5A51234       → the port delivers real DRAM contents (shared view)
//   P0 == 42314D37ish    → mailbox writes DO land; ARM visibility was wrong
//   P1 real, P0 zero     → writes die inside the EMIF despite no waitrequest
//   P1 zero              → port/CPU views differ (address translation) or
//                          port reads dead — cross-check with poke
//
// All inputs are clk_sys-domain; no CDC. Clocked at clk_sys (21.477273 MHz):
// BIT_PERIOD = 21477273/115200 ≈ 186 (+0.24 % baud error), report period
// 250 ms = 5,369,318 clocks.
//

module m7_dbg_uart (
    input             clk,
    input      [2:0]  mb_state,
    input      [2:0]  dm_state,
    input      [3:0]  wt_cnt,
    input      [15:0] frame_seq,
    input             mb_we_req,
    input             mb_we_ack,
    input      [15:0] mb_addr_lo,    // mb_wraddr[16:1], sampled at issue
    input      [15:0] mb_din,        // write data, sampled at issue
    input             mb_hdr,        // wraddr[31:3] == mailbox header word
    input      [31:0] probe0_data,   // FPGA readback of 0x3E000000
    input      [31:0] probe1_data,   // FPGA readback of 0x3F800008
    input             active_client,
    input             ddr_busy,
    input             ddr_we,
    input             ddr_rdy,
    output reg        txd
);

    localparam [9:0]  BIT_PERIOD = 10'd186;
    localparam [23:0] REP_PERIOD = 24'd5369318;   // 250 ms @ 21.477273 MHz
    localparam [6:0]  MSG_LEN    = 7'd99;         // bytes incl. CRLF

    // ---- event counters (saturating, cleared each report window) --------
    reg       wr_q = 1'b0, ack_q = 1'b0, we_q = 1'b0, rdy_q = 1'b0;
    reg [7:0] c_wr = 8'd0, c_ack = 8'd0, c_we = 8'd0, c_rdy = 8'd0,
              c_hdr = 8'd0;

    // ---- last write captured at issue -----------------------------------
    reg [15:0] cap_addr = 16'd0, cap_din = 16'd0;

    // ---- window snapshots -----------------------------------------------
    reg [15:0] s_seq = 16'd0;
    reg [2:0]  s_mb  = 3'd0, s_dm = 3'd0;
    reg [7:0]  s_wr = 8'd0, s_ack = 8'd0, s_we = 8'd0, s_rdy = 8'd0,
               s_hdr = 8'd0;
    reg        s_bsy = 1'b0, s_cli = 1'b0;
    reg [3:0]  s_wt  = 4'd0;
    reg [15:0] s_cap_addr = 16'd0, s_cap_din = 16'd0;
    reg [31:0] s_p0 = 32'd0, s_p1 = 32'd0;

    // ---- TX engine -------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_LOAD = 2'd1, S_SEND = 2'd2;
    reg [1:0]  state      = S_IDLE;
    reg [23:0] period_cnt = 24'd0;
    reg [9:0]  baud_cnt   = 10'd0;
    reg [3:0]  bit_idx    = 4'd0;
    reg [6:0]  char_idx   = 7'd0;
    reg [9:0]  tx_shift   = 10'h3FF;
    reg        latch_stb  = 1'b0;

    function [7:0] hex2ascii;
        input [3:0] nib;
        begin
            hex2ascii = (nib < 4'd10) ? (8'h30 + {4'd0, nib})
                                      : (8'h41 + {4'd0, nib - 4'd10});
        end
    endfunction

    // rising-edge / toggle events on the path handshake
    wire wr_evt  = (mb_we_req != wr_q);
    wire ack_evt = (mb_we_ack != ack_q);
    wire we_evt  = ddr_we  && !we_q;
    wire rdy_evt = ddr_rdy && !rdy_q;

    always @(posedge clk) begin
        wr_q  <= mb_we_req;
        ack_q <= mb_we_ack;
        we_q  <= ddr_we;
        rdy_q <= ddr_rdy;

        if (wr_evt) begin
            cap_addr <= mb_addr_lo;
            cap_din  <= mb_din;
        end

        if (latch_stb) begin
            c_wr  <= 8'd0;
            c_ack <= 8'd0;
            c_we  <= 8'd0;
            c_rdy <= 8'd0;
            c_hdr <= 8'd0;
        end else begin
            if (wr_evt  && (c_wr  != 8'hFF)) c_wr  <= c_wr  + 8'd1;
            if (ack_evt && (c_ack != 8'hFF)) c_ack <= c_ack + 8'd1;
            if (we_evt  && (c_we  != 8'hFF)) c_we  <= c_we  + 8'd1;
            if (rdy_evt && (c_rdy != 8'hFF)) c_rdy <= c_rdy + 8'd1;
            if (wr_evt && mb_hdr && (c_hdr != 8'hFF)) c_hdr <= c_hdr + 8'd1;
        end
    end

    // one ASCII line, byte index char_idx
    reg [7:0] tx_byte;
    always @(*) begin
        case (char_idx)
            // 0-4: "[M7] "
            7'd0:  tx_byte = "[";
            7'd1:  tx_byte = "M";
            7'd2:  tx_byte = "7";
            7'd3:  tx_byte = "]";
            7'd4:  tx_byte = " ";
            // 5-11: "F=xxxx "
            7'd5:  tx_byte = "F";
            7'd6:  tx_byte = "=";
            7'd7:  tx_byte = hex2ascii(s_seq[15:12]);
            7'd8:  tx_byte = hex2ascii(s_seq[11:8]);
            7'd9:  tx_byte = hex2ascii(s_seq[7:4]);
            7'd10: tx_byte = hex2ascii(s_seq[3:0]);
            7'd11: tx_byte = " ";
            // 12-15: "M=x "
            7'd12: tx_byte = "M";
            7'd13: tx_byte = "=";
            7'd14: tx_byte = hex2ascii({1'b0, s_mb});
            7'd15: tx_byte = " ";
            // 16-19: "D=x "
            7'd16: tx_byte = "D";
            7'd17: tx_byte = "=";
            7'd18: tx_byte = hex2ascii({1'b0, s_dm});
            7'd19: tx_byte = " ";
            // 20-24: "W=xx "
            7'd20: tx_byte = "W";
            7'd21: tx_byte = "=";
            7'd22: tx_byte = hex2ascii(s_wr[7:4]);
            7'd23: tx_byte = hex2ascii(s_wr[3:0]);
            7'd24: tx_byte = " ";
            // 25-29: "A=xx "
            7'd25: tx_byte = "A";
            7'd26: tx_byte = "=";
            7'd27: tx_byte = hex2ascii(s_ack[7:4]);
            7'd28: tx_byte = hex2ascii(s_ack[3:0]);
            7'd29: tx_byte = " ";
            // 30-34: "E=xx "
            7'd30: tx_byte = "E";
            7'd31: tx_byte = "=";
            7'd32: tx_byte = hex2ascii(s_we[7:4]);
            7'd33: tx_byte = hex2ascii(s_we[3:0]);
            7'd34: tx_byte = " ";
            // 35-40: "RD=xx "
            7'd35: tx_byte = "R";
            7'd36: tx_byte = "D";
            7'd37: tx_byte = "=";
            7'd38: tx_byte = hex2ascii(s_rdy[7:4]);
            7'd39: tx_byte = hex2ascii(s_rdy[3:0]);
            7'd40: tx_byte = " ";
            // 41-44: "B=x "
            7'd41: tx_byte = "B";
            7'd42: tx_byte = "=";
            7'd43: tx_byte = s_bsy ? "1" : "0";
            7'd44: tx_byte = " ";
            // 45-48: "C=x "
            7'd45: tx_byte = "C";
            7'd46: tx_byte = "=";
            7'd47: tx_byte = s_cli ? "1" : "0";
            7'd48: tx_byte = " ";
            // 49-52: "T=x "
            7'd49: tx_byte = "T";
            7'd50: tx_byte = "=";
            7'd51: tx_byte = hex2ascii({1'b0, s_wt});
            7'd52: tx_byte = " ";
            // 53-57: "H=xx "
            7'd53: tx_byte = "H";
            7'd54: tx_byte = "=";
            7'd55: tx_byte = hex2ascii(s_hdr[7:4]);
            7'd56: tx_byte = hex2ascii(s_hdr[3:0]);
            7'd57: tx_byte = " ";
            // 58-65: "HA=xxxx "
            7'd58: tx_byte = "H";
            7'd59: tx_byte = "A";
            7'd60: tx_byte = "=";
            7'd61: tx_byte = hex2ascii(s_cap_addr[15:12]);
            7'd62: tx_byte = hex2ascii(s_cap_addr[11:8]);
            7'd63: tx_byte = hex2ascii(s_cap_addr[7:4]);
            7'd64: tx_byte = hex2ascii(s_cap_addr[3:0]);
            7'd65: tx_byte = " ";
            // 66-73: "HD=xxxx "
            7'd66: tx_byte = "H";
            7'd67: tx_byte = "D";
            7'd68: tx_byte = "=";
            7'd69: tx_byte = hex2ascii(s_cap_din[15:12]);
            7'd70: tx_byte = hex2ascii(s_cap_din[11:8]);
            7'd71: tx_byte = hex2ascii(s_cap_din[7:4]);
            7'd72: tx_byte = hex2ascii(s_cap_din[3:0]);
            7'd73: tx_byte = " ";
            // 74-85: "P0=xxxxxxxx "
            7'd74: tx_byte = "P";
            7'd75: tx_byte = "0";
            7'd76: tx_byte = "=";
            7'd77: tx_byte = hex2ascii(s_p0[31:28]);
            7'd78: tx_byte = hex2ascii(s_p0[27:24]);
            7'd79: tx_byte = hex2ascii(s_p0[23:20]);
            7'd80: tx_byte = hex2ascii(s_p0[19:16]);
            7'd81: tx_byte = hex2ascii(s_p0[15:12]);
            7'd82: tx_byte = hex2ascii(s_p0[11:8]);
            7'd83: tx_byte = hex2ascii(s_p0[7:4]);
            7'd84: tx_byte = hex2ascii(s_p0[3:0]);
            7'd85: tx_byte = " ";
            // 86-96: "P1=xxxxxxxx"
            7'd86: tx_byte = "P";
            7'd87: tx_byte = "1";
            7'd88: tx_byte = "=";
            7'd89: tx_byte = hex2ascii(s_p1[31:28]);
            7'd90: tx_byte = hex2ascii(s_p1[27:24]);
            7'd91: tx_byte = hex2ascii(s_p1[23:20]);
            7'd92: tx_byte = hex2ascii(s_p1[19:16]);
            7'd93: tx_byte = hex2ascii(s_p1[15:12]);
            7'd94: tx_byte = hex2ascii(s_p1[11:8]);
            7'd95: tx_byte = hex2ascii(s_p1[7:4]);
            7'd96: tx_byte = hex2ascii(s_p1[3:0]);
            // 97-98: CRLF
            7'd97: tx_byte = 8'h0D;
            7'd98: tx_byte = 8'h0A;
            default: tx_byte = 8'h20;
        endcase
    end

    always @(posedge clk) begin
        latch_stb <= 1'b0;
        case (state)
            S_IDLE: begin
                txd <= 1'b1;
                if (period_cnt >= REP_PERIOD) begin
                    period_cnt <= 24'd0;
                    s_seq <= frame_seq;
                    s_mb  <= mb_state;
                    s_dm  <= dm_state;
                    s_wt  <= wt_cnt;
                    s_bsy <= ddr_busy;
                    s_cli <= active_client;
                    s_wr  <= c_wr;
                    s_ack <= c_ack;
                    s_we  <= c_we;
                    s_rdy <= c_rdy;
                    s_hdr <= c_hdr;
                    s_cap_addr <= cap_addr;
                    s_cap_din  <= cap_din;
                    s_p0 <= probe0_data;
                    s_p1 <= probe1_data;
                    latch_stb <= 1'b1;
                    char_idx  <= 7'd0;
                    state     <= S_LOAD;
                end else begin
                    period_cnt <= period_cnt + 24'd1;
                end
            end

            S_LOAD: begin
                // load byte with start (0) and stop (1) bits
                tx_shift <= {1'b1, tx_byte, 1'b0};
                bit_idx  <= 4'd0;
                baud_cnt <= 10'd0;
                state    <= S_SEND;
            end

            S_SEND: begin
                txd <= tx_shift[0];
                if (baud_cnt >= BIT_PERIOD) begin
                    baud_cnt <= 10'd0;
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    if (bit_idx == 4'd9) begin
                        if (char_idx == MSG_LEN - 7'd1)
                            state <= S_IDLE;
                        else begin
                            char_idx <= char_idx + 7'd1;
                            state    <= S_LOAD;
                        end
                    end else begin
                        bit_idx <= bit_idx + 4'd1;
                    end
                end else begin
                    baud_cnt <= baud_cnt + 10'd1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end

endmodule
