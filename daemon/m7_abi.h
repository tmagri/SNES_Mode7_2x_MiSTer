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

#define M7_PIXBUF_BYTES  0x00070000u  // buffer slot (224*256 B used, 8bpp)
#define M7_PIX_STRIDE    256u         // native pixels per row (8bpp = bytes)

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
#define M7_CTRL_FMT8      17  // pixbufs hold 8bpp CLUT indices (v2; MUST be set)
#define M7_CTRL_DUMP_REQ  18  // daemon requests a VRAM resync dump
// Bits [31:19] reserved-zero; the FPGA adopts only words with those clear
// and FMT8 set.

// --- Per-line record stream (UART payload type != 0xC3, P2c-2) ---
// Record: [len][line][mask][lo hi]... len includes itself.
// mask selects which changed fields follow, lsb-first.
#define M7_RECF_A    0  // int16
#define M7_RECF_B    1  // int16
#define M7_RECF_C    2  // int16
#define M7_RECF_D    3  // int16
#define M7_RECF_X    4  // 13-bit (zero-extended to 16)
#define M7_RECF_Y    5  // 13-bit
#define M7_RECF_HOFS 6  // 13-bit
#define M7_RECF_VOFS 7  // 13-bit
#define M7_RECLINE_SYNC 0xFEu // full sync: mask FF + M7SEL tail

// --- VRAM records (P2c-3). Same len-prefixed stream, opcode in the LINE
// byte (values outside 0..223 are opcodes). Address fields are plane-local
// dpram byte addresses; ah bit7 = plane (0=plane1, 1=plane2), ah[6:0] =
// addr[14:8]. Data bytes are consecutive addresses from addr. ---
#define M7_RECVRAM_DUMP 0xFDu // [len][FD][al][ah][data...] resync chunk
#define M7_RECVRAM_WT   0xFCu // [len][FC][al][ah][data...] write-through run
#define M7_RECVRAM_DONE 0xFBu // [5][FB][seq][wt_drops l h] dump finished
// Length budget: line/sync <= 20; WT runs <= 12 (8-entry coalesce); dump
// chunks 244 (0xF4; short tail 132 = 0x84 at the plane end). A boundary
// len byte is never 0xC3, so payload[0]==0xC3 at a record boundary means
// telemetry.

// --- Telemetry payload bytes (payload[0]==0xC3 slots), P2c-3 additions ---
#define M7_TEL_DUMP_PHASE 132 // 0 idle, 1 plane1, 2 plane2, 3 done
#define M7_TEL_DUMP_SEQ   133 // completed dump counter (8-bit wrap)
#define M7_TEL_VRAM1_VER  134 // 16-bit plane-1 write-through version (l,h)
#define M7_TEL_VRAM2_VER  136 // 16-bit plane-2 write-through version (l,h)
#define M7_TEL_WT_DROPS   138 // 16-bit write-through drop count (l,h)

// VRAM image size: 32768 words (one 16-bit slot per VRAM byte).
#define M7_VRAM_WORDS 32768u

#endif // M7_ABI_H
