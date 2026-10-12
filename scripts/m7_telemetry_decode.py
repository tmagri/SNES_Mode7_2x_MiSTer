#!/usr/bin/env python3
"""Decode m7_reg_stream telemetry captures (test_mode=2) from /dev/ttyS1.

Usage: python3 -I scripts/m7_telemetry_decode.py <capture.bin> [n_last]

Framing: A5 5C seq_l seq_h len_l len_h payload[len] crc8(poly 0x07 over
seq..payload). Payload is a per-frame snapshot of the HD Mode 7 engine
state; byte map below (mirrors the dbg_bytes assigns in SNES.sv).
"""

import sys

HEAD = 0             # [0] magic byte, expect 0xC3
FLAGS = 1            # [1] {fetch_pend, fetch_restart, fetch_en, daemon_present,
                     #      dm_wd_evt, ddram_busy, dout_ready_lvl, req!=ack}
LVLS = 2             # [2] {vblank, hblank, -, ctrl_new, dm_state[2:0]}
LINEFLAGS = 3        # [3] {m7_line_hd, cur_buf_s, cur_buf, fetch_pend, -}
ROWDONE = 4          # [4..31] row_done[223:0], bit 0 = row 0
FS_CNT = 32          # [32..33] frame events
CDN_CNT = 34         # [34..35] ctrl polls completed (ctrl_new)
DRT_CNT = 36         # [36..37] fetch words completed (DM_DRAIN entries)
DOUT_CNT = 38        # [38..39] DDRAM_DOUT_READY rising edges
HDE_CNT = 40         # [40..41] hde falls this frame
ARM_CNT = 42         # [42..43] lines armed HD this frame
FETCH_ROW = 44       # [44..45]
FETCH_WORD = 46      # [46..47]
CTRL_DATA = 48       # [48..51] last ctrl word read from DDR3
DM_WORD = 52         # [52..55] last fetched 64-bit word, low half
PPU_X = 56           # [56..57]
PPU_Y = 58           # [58..59]
LAST_SEQ = 60        # [60..61] last_ready_seq
DDR_STATE = 62       # [62] ddram FSM state (bits 1:0)
TAIL = 63            # [63] 0x5A magic
DISP_ROW = 128       # [128] row id in the displayed linebuf slot
LAST_ROW = 129       # [129] row id sitting complete in the inactive slot
SWAP = 130           # [130] {row_adv, act, 6'b0}

def crc8(data, c=0):
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c

def frames(buf):
    i, n = 0, len(buf)
    while i < n - 6:
        if buf[i] != 0xA5 or buf[i + 1] != 0x5C:
            i += 1
            continue
        seq = buf[i + 2] | (buf[i + 3] << 8)
        ln = buf[i + 4] | (buf[i + 5] << 8)
        if ln > 1024 or i + 6 + ln + 1 > n:
            i += 1
            continue
        pay = buf[i + 6:i + 6 + ln]
        ok = crc8(buf[i + 2:i + 6 + ln]) == buf[i + 6 + ln]
        if ok:
            yield seq, pay
        i += 6 + ln + 1

def ranges(bits):
    out, start = [], None
    for i, b in enumerate(bits):
        if b and start is None:
            start = i
        elif not b and start is not None:
            out.append((start, i - 1))
            start = None
    if start is not None:
        out.append((start, len(bits) - 1))
    return out

def show(seq, p, label):
    if p[HEAD] != 0xC3 or p[TAIL] != 0x5A:
        print(f"  [{label}] BAD MAGIC head={p[HEAD]:02X} tail={p[TAIL]:02X}")
        return
    f = p[FLAGS]
    rowbits = [(p[ROWDONE + (r >> 3)] >> (r & 7)) & 1 for r in range(224)]
    print(f"  [{label}] seq={seq}")
    # dbg_bytes[1] = {fetch_pend, fetch_restart, fetch_en, daemon_present,
    #                 dm_wd_evt, busy, dout_rdy, req!=ack} — concat is MSB-first
    print(f"    flags: fetch_pend={(f>>7)&1} fetch_restart={(f>>6)&1} "
          f"fetch_en={(f>>5)&1} daemon_present={(f>>4)&1} "
          f"dm_wd_evt={(f>>3)&1} ddram_busy={(f>>2)&1} "
          f"dout_rdy_lvl={(f>>1)&1} req_ne_ack={f&1}")
    l2, l3 = p[LVLS], p[LINEFLAGS]
    print(f"    levels: vblank={(l2>>7)&1} hblank={(l2>>6)&1} "
          f"ctrl_new={(l2>>3)&1} dm_state={l2&7} | "
          f"m7_line_hd={l3&1} cur_buf_s={(l3>>1)&1} cur_buf={(l3>>2)&1}")
    print(f"    row_done: {sum(rowbits)}/224 set, ranges={ranges(rowbits)[:8]}"
          f"{'...' if len(ranges(rowbits)) > 8 else ''}")
    def u16(o):
        return p[o] | (p[o + 1] << 8)
    def u32(o):
        return p[o] | (p[o+1] << 8) | (p[o+2] << 16) | (p[o+3] << 24)
    print(f"    counters: fs={u16(FS_CNT)} ctrl_polls={u16(CDN_CNT)} "
          f"fetch_words={u16(DRT_CNT)} dout_edges={u16(DOUT_CNT)}")
    print(f"    per-frame: hde_falls={u16(HDE_CNT)} armed_lines={u16(ARM_CNT)}")
    print(f"    fetch: row={u16(FETCH_ROW)} word={p[FETCH_WORD]} "
          f"ppu=({u16(PPU_X)},{u16(PPU_Y)}) ddram_state={p[DDR_STATE]&3}")
    print(f"    swap: disp_row={p[DISP_ROW]} last_row={p[LAST_ROW]} "
          f"row_adv={(p[SWAP]>>7)&1} act={(p[SWAP]>>6)&1}")
    print(f"    ctrl_read=0x{u32(CTRL_DATA):08X} (expect 0x00020001 = seq1|buf0|FMT8) "
          f"last_seq_adopted={u16(LAST_SEQ):04X} dm_word_lo=0x{u32(DM_WORD):08X}")

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    buf = open(sys.argv[1], "rb").read()
    fl = list(frames(buf))
    print(f"frames={len(fl)} bytes={len(buf)}")
    if not fl:
        sys.exit(1)
    n_last = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    for k, (seq, p) in enumerate(fl[-n_last:]):
        show(seq, p, f"frame -{len(fl[-n_last:]) - k}")
    # counter progress across the capture (first vs last)
    s0, p0 = fl[0]
    s1, p1 = fl[-1]
    def u16(p, o):
        return p[o] | (p[o + 1] << 8)
    print("progress first->last frame:")
    print(f"  ctrl_polls {u16(p0, CDN_CNT)} -> {u16(p1, CDN_CNT)}")
    print(f"  fetch_words {u16(p0, DRT_CNT)} -> {u16(p1, DRT_CNT)}")
    print(f"  dout_edges {u16(p0, DOUT_CNT)} -> {u16(p1, DOUT_CNT)}")

if __name__ == "__main__":
    main()
