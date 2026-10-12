#!/usr/bin/env python3
"""P2a UART stream checker.

Parses a raw /dev/ttyS1 capture of the m7_reg_stream test pattern and
reports frame count, sequence slips (lost/inserted bytes between frames),
payload mismatches (bit errors), and CRC failures.

Usage: m7_uart_check.py <capture.bin>
"""
import sys

SYNC = b"\xa5\x5c"


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def main(path):
    with open(path, "rb") as f:
        data = f.read()
    n = len(data)
    frames = slips = bad_payload = bad_crc = short = 0
    last_seq = None
    i = 0
    while True:
        j = data.find(SYNC, i)
        if j < 0 or j + 6 > n:
            break
        seq = data[j + 2] | (data[j + 3] << 8)
        ln = data[j + 4] | (data[j + 5] << 8)
        end = j + 6 + ln + 1
        if ln != 256 or end > n:
            i = j + 1  # misparse (mid-frame loss) — resync
            short += 1
            continue
        payload = data[j + 6:j + 6 + ln]
        crc = data[j + 6 + ln]
        if crc != crc8(data[j + 2:j + 6 + ln]):
            bad_crc += 1
        exp = bytes(((seq + k) & 0xFF) ^ 0xA7 for k in range(ln))
        if payload != exp:
            bad_payload += 1
        if last_seq is not None and ((seq - last_seq) & 0xFFFF) != 1:
            slips += 1
        last_seq = seq
        frames += 1
        i = end
    print(f"bytes={n} frames={frames} resyncs={short} "
          f"seq_slips={slips} payload_mismatch={bad_payload} crc_bad={bad_crc}")


if __name__ == "__main__":
    main(sys.argv[1])
