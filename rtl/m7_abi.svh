// ===========================================================================
// m7_abi.svh — Single source of truth for the HD Mode 7 FPGA<->ARM ABI.
//
// The ARM daemon keeps a mirrored copy of these constants in
// daemon/m7_abi.h. scripts/check_abi.sh compares both files and fails the
// build if any value drifts.
//
// Address convention (verified against rtl/ddram.sv):
//   * All M7_* addresses are HPS PHYSICAL BYTE addresses. The daemon
//     mmaps /dev/mem at M7_MAILBOX_BASE and indexes them directly.
//   * The ddram.sv 16-bit write port takes a byte address in wraddr[31:1]:
//       ram_address <= wraddr[31:3];  lane from wraddr[2:1].
//     So 16-bit entry i of a region at byte base B is written at
//     wraddr = B + 2*i (i.e. {base, idx, 1'b0} — NOT base + idx).
//   * The 64-bit read port takes DDRAM_ADDR = physical byte address >> 3.
//
// See docs/m7_abi.md for the full protocol description.
// ===========================================================================

// --- Region base addresses (HPS physical byte addresses) ---
localparam [31:0] M7_MAILBOX_BASE  = 32'h3E000000;  // header, 32 B (FPGA->ARM)
localparam [31:0] M7_REGS_BASE     = 32'h3E000020;  // per-line regs, 224x8x2 B (FPGA->ARM)
localparam [31:0] M7_CTRL_BASE     = 32'h3E001000;  // ctrl word, 8 B (ARM->FPGA)
localparam [31:0] M7_PIXBUF_BASE   = 32'h3E002000;  // HD pixel buffer A (ARM->FPGA)
localparam [31:0] M7_PIXBUF_B_BASE = 32'h3E072000;  // HD pixel buffer B (ARM->FPGA)
localparam [31:0] M7_VRAM1_BASE    = 32'h3E100000;  // VRAM plane 1 image, 64 KiB (FPGA->ARM)
localparam [31:0] M7_VRAM2_BASE    = 32'h3E110000;  // VRAM plane 2 image, 64 KiB (FPGA->ARM)
localparam [31:0] M7_CGRAM_BASE    = 32'h3E120000;  // CGRAM image, 256x2 B (FPGA->ARM)

localparam [31:0] M7_PIXBUF_BYTES  = 32'h00070000;  // buffer slot (224*256 B used, 8bpp)
localparam [8:0]  M7_PIX_STRIDE    = 9'd256;        // native pixels per row (8bpp = bytes)

// --- Header / protocol identity ---
localparam [15:0] M7_MAGIC0       = 16'h4D37;  // 'M7'
localparam [15:0] M7_MAGIC1       = 16'h4231;  // 'B1'
localparam [15:0] M7_ABI_VERSION  = 16'd1;
localparam [15:0] M7_LINE_COUNT   = 16'd224;   // visible scanlines
localparam [3:0]  M7_HD_SCALE     = 4'd4;      // HD scale fixed at 4x

// --- Header layout: 16-bit word index at M7_MAILBOX_BASE ---
localparam [4:0] M7_HDR_MAGIC0      = 0;  // = M7_MAGIC0
localparam [4:0] M7_HDR_MAGIC1      = 1;  // = M7_MAGIC1
localparam [4:0] M7_HDR_VERSION     = 2;  // = M7_ABI_VERSION
localparam [4:0] M7_HDR_LINES       = 3;  // = M7_LINE_COUNT
localparam [4:0] M7_HDR_FRAME_SEQ   = 4;  // FPGA++ every frame (heartbeat)
localparam [4:0] M7_HDR_CUR_BUF     = 5;  // buffer the FPGA reads this frame
localparam [4:0] M7_HDR_FLAGS       = 6;  // bit0 dump_busy, bit1 dump_done
localparam [4:0] M7_HDR_SCALE       = 7;  // = M7_HD_SCALE
localparam [4:0] M7_HDR_VRAM1_VER   = 8;  // FPGA++ on plane-1 write-through
localparam [4:0] M7_HDR_VRAM2_VER   = 9;  // FPGA++ on plane-2 write-through
localparam [4:0] M7_HDR_WT_DROPS    = 10; // saturating write-through drop count
localparam [4:0] M7_HDR_SIZE_WORDS  = 16; // header is 32 bytes

// --- Ctrl word bits (32-bit word at M7_CTRL_BASE, ARM->FPGA) ---
localparam [4:0] M7_CTRL_SEQ_LSB   = 0;   // [15:0] ready_seq, ARM++
localparam [4:0] M7_CTRL_READY_BUF = 16;  // buffer the daemon published
localparam [4:0] M7_CTRL_FMT8      = 17;  // pixbufs hold 8bpp CLUT indices (v2)
localparam [4:0] M7_CTRL_DUMP_REQ  = 18;  // daemon requests a VRAM resync dump
// Bits [31:19] reserved-zero. The FPGA adopts only words with the reserved
// bits clear AND FMT8 set (rejects boot garbage + stale 16bpp publishers).

// --- Per-line record stream (UART payload type != 0xC3, P2c-2) ---
// Record: [len][line][mask][lo hi]... len includes itself.
// mask selects which changed fields follow, lsb-first.
localparam [2:0] M7_RECF_A    = 0;  // int16
localparam [2:0] M7_RECF_B    = 1;  // int16
localparam [2:0] M7_RECF_C    = 2;  // int16
localparam [2:0] M7_RECF_D    = 3;  // int16
localparam [2:0] M7_RECF_X    = 4;  // 13-bit (zero-extended to 16)
localparam [2:0] M7_RECF_Y    = 5;  // 13-bit
localparam [2:0] M7_RECF_HOFS = 6;  // 13-bit
localparam [2:0] M7_RECF_VOFS = 7;  // 13-bit
localparam [7:0] M7_RECLINE_SYNC = 8'hFE; // full sync: mask FF + M7SEL tail

// --- 64-bit read-port word addresses (physical byte >> 3) ---
localparam [28:0] M7_CTRL_WORD     = 29'h07C00200;  // M7_CTRL_BASE     >> 3
localparam [28:0] M7_PIXBUF_WORD   = 29'h07C00400;  // M7_PIXBUF_BASE   >> 3
localparam [28:0] M7_PIXBUF_B_WORD = 29'h07C0E400;  // M7_PIXBUF_B_BASE >> 3
