// ===========================================================================
// m7_abi.h — ARM-side mirror of rtl/m7_abi.svh (the HD Mode 7 ABI).
//
// scripts/check_abi.sh compares the constants in both files; keep them in
// sync. Address convention: all M7_* addresses are HPS physical byte
// addresses, mmap'd via /dev/mem at M7_MAILBOX_BASE.
//
// See docs/m7_abi.md for the full protocol description.
// ===========================================================================
#ifndef M7_ABI_H
#define M7_ABI_H

// --- Region base addresses (HPS physical byte addresses) ---
#define M7_MAILBOX_BASE  0x3E000000u  // header, 32 B (FPGA->ARM)
#define M7_REGS_BASE     0x3E000020u  // per-line regs, 224x8x2 B (FPGA->ARM)
#define M7_CTRL_BASE     0x3E001000u  // ctrl word, 8 B (ARM->FPGA)
#define M7_PIXBUF_BASE   0x3E002000u  // HD pixel buffer A (ARM->FPGA)
#define M7_PIXBUF_B_BASE 0x3E072000u  // HD pixel buffer B (ARM->FPGA)
#define M7_VRAM1_BASE    0x3E100000u  // VRAM plane 1 image, 64 KiB (FPGA->ARM)
#define M7_VRAM2_BASE    0x3E110000u  // VRAM plane 2 image, 64 KiB (FPGA->ARM)
#define M7_CGRAM_BASE    0x3E120000u  // CGRAM image, 256x2 B (FPGA->ARM)

#define M7_PIXBUF_BYTES  0x00070000u  // 224 lines * 1024 px * 2 B

// --- Header / protocol identity ---
#define M7_MAGIC0       0x4D37u  // 'M7'
#define M7_MAGIC1       0x4231u  // 'B1'
#define M7_ABI_VERSION  1u
#define M7_LINE_COUNT   224u     // visible scanlines
#define M7_HD_SCALE     4u       // HD scale fixed at 4x

// --- Header layout: 16-bit word index at M7_MAILBOX_BASE ---
#define M7_HDR_MAGIC0      0
#define M7_HDR_MAGIC1      1
#define M7_HDR_VERSION     2
#define M7_HDR_LINES       3
#define M7_HDR_FRAME_SEQ   4  // FPGA++ every frame (heartbeat)
#define M7_HDR_CUR_BUF     5  // buffer the FPGA reads this frame
#define M7_HDR_FLAGS       6  // bit0 dump_busy, bit1 dump_done
#define M7_HDR_SCALE       7  // = M7_HD_SCALE
#define M7_HDR_VRAM1_VER   8  // FPGA++ on plane-1 write-through
#define M7_HDR_VRAM2_VER   9  // FPGA++ on plane-2 write-through
#define M7_HDR_WT_DROPS    10 // saturating write-through drop count
#define M7_HDR_SIZE_WORDS  16 // header is 32 bytes

#define M7_FLAG_DUMP_BUSY 0x1u
#define M7_FLAG_DUMP_DONE 0x2u

// --- Ctrl word bits (32-bit word at M7_CTRL_BASE, ARM->FPGA) ---
#define M7_CTRL_SEQ_LSB   0   // [15:0] ready_seq, ARM++
#define M7_CTRL_READY_BUF 16  // buffer the daemon published
#define M7_CTRL_DUMP_REQ  17  // daemon requests a VRAM resync dump

// VRAM image size: 32768 words (one 16-bit slot per VRAM byte).
#define M7_VRAM_WORDS 32768u

#endif // M7_ABI_H
