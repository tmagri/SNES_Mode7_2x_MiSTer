# HD Mode 7 Shared-Memory ABI (v1)

Single source of truth for the constants: [rtl/m7_abi.svh](../rtl/m7_abi.svh)
(FPGA) and [daemon/m7_abi.h](../daemon/m7_abi.h) (ARM).
`scripts/check_abi.sh` fails if they drift.

This follows the same philosophy as NDS4MiSTer's `docs/hybrid-3d-abi.md`: one
documented address convention, a magic/version header so a mismatched
bitstream/daemon pair fails loudly instead of rendering garbage, and the FPGA
as the timing authority.

## Address convention

All addresses are **HPS physical byte addresses**, mapped by the daemon via
`mmap("/dev/mem", M7_MAILBOX_BASE, 2 MiB)`. On the FPGA side:

- The `ddram.sv` 16-bit write port takes a byte address in `wraddr[31:1]`
  (`ram_address <= wraddr[31:3]`, 16-bit lane from `wraddr[2:1]`), so 16-bit
  entry *i* of a region at byte base *B* is written at `wraddr = B + 2*i`.
- The 64-bit read port takes `DDRAM_ADDR = physical byte address >> 3`.

## Memory map

| Region | Byte address | Size | Direction | Contents |
|---|---|---|---|---|
| Header | `0x3E000000` | 32 B | FPGA→ARM | identity + handshake state |
| Per-line M7 regs | `0x3E000020` | 3584 B | FPGA→ARM | 224 lines × 8 regs × 16-bit |
| Ctrl word | `0x3E001000` | 8 B | ARM→FPGA | publication handshake |
| Pixel buffer A | `0x3E002000` | 448 KiB | ARM→FPGA | RGB565, 224 × 1024 px |
| Pixel buffer B | `0x3E072000` | 448 KiB | ARM→FPGA | RGB565, 224 × 1024 px |
| VRAM plane 1 image | `0x3E100000` | 64 KiB | FPGA→ARM | even VRAM bytes ($2118) |
| VRAM plane 2 image | `0x3E110000` | 64 KiB | FPGA→ARM | odd VRAM bytes ($2119) |
| CGRAM image | `0x3E120000` | 512 B | FPGA→ARM | 256 × BGR555 |

SNES VRAM is stored by this core as **two byte planes written by $2118/$2119
at the same word address**: VRAM byte `2*w` is plane 1 word `w`, VRAM byte
`2*w+1` is plane 2 word `w`. Mode 7 tilemap entries live at even bytes
(plane 1); Mode 7 tile pixel data alternates planes per column
(`px = (col & 1) ? plane2[w] : plane1[w]` with `w = tile*32 + row*4 + col/2`).

## Header (16-bit words at `0x3E000000`)

| Word | Name | Meaning |
|---|---|---|
| 0 | `MAGIC0` | `0x4D37` `'M7'` |
| 1 | `MAGIC1` | `0x4231` `'B1'` |
| 2 | `VERSION` | ABI version (1) |
| 3 | `LINES` | 224 |
| 4 | `FRAME_SEQ` | FPGA increments at every frame start (vblank entry) — heartbeat |
| 5 | `CUR_BUF` | pixel buffer the FPGA reads **this** frame (0/1); writing it is the flip acknowledgement |
| 6 | `FLAGS` | bit0 `dump_busy`, bit1 `dump_done` (sticky until next dump) |
| 7 | `SCALE` | 4 |
| 8 | `VRAM1_VER` | FPGA increments on every plane-1 write-through |
| 9 | `VRAM2_VER` | FPGA increments on every plane-2 write-through |
| 10 | `WT_DROPS` | saturating count of write-through FIFO drops (should stay 0) |
| 11–15 | — | zero |

## Ctrl word (32-bit at `0x3E001000`, ARM→FPGA)

| Bits | Name | Meaning |
|---|---|---|
| 15:0 | `READY_SEQ` | daemon increments on every published frame |
| 16 | `READY_BUF` | buffer the daemon just finished rendering |
| 17 | `DUMP_REQ` | **dead since REVISION v2** — the FPGA never reads it (no dump machinery); keep 0 |
| 31:18 | — | zero |

**Bits [31:17] must be zero.** The FPGA rejects a ctrl word with any of
them set as boot-time DDR3 garbage (there is no header magic anymore, so
this zero-check is the only sanity gate on the word).

## Frame protocol

1. **FPGA (timing authority)** — at vblank entry: `FRAME_SEQ++`; reads the
   ctrl word once; if `READY_SEQ` changed, adopts `READY_BUF` into `CUR_BUF`
   and latches "daemon present"; writes the header.
2. **FPGA** — during each active line *L*, fetch-ahead reads pixel row *L+1*
   (only if daemon present, HD option on, row < 224, no dump in progress)
   from buffer `CUR_BUF` into the scanline linebuf.
3. **Daemon** — waits for `FRAME_SEQ` to change; re-reads a VRAM plane image
   only when its version moved; re-renders all 224 lines into buffer
   `CUR_BUF ^ 1`; publishes by writing the ctrl word
   (`READY_BUF = CUR_BUF ^ 1`, `READY_SEQ++`); then waits until the header's
   `CUR_BUF` acknowledges the flip before rendering the next frame.
   This rate-locks the daemon to the FPGA and makes overwriting a buffer the
   FPGA is reading impossible. A frame that misses its deadline is simply
   not published (the FPGA repeats the previous one). After a 5-frame
   flip timeout the daemon idles at ~10 Hz (HD display off).

## VRAM resync dump

Write-through keeps the daemon's plane images current, but a freshly loaded
game (or a daemon started mid-game) needs a base image. Either side can
trigger a dump (auto after ROM load; on demand via `DUMP_REQ`). While
`IN_VBL` is asserted the FPGA muxes a dump address onto the *fetch* port
(port B) of `vram1`/`vram2` — idle during blank — and writes the full
32K-word plane image to DDR3, plane 1 then plane 2, over ~4–6 frames. During
the dump `FLAGS.dump_busy = 1` and HD output is forced off (native Mode 7
fallback); on completion both version counters bump and `dump_done` sticks.

## Disable / fallback rules

- Daemon absent (no `READY_SEQ` change ever seen): HD fetch never enables —
  the core behaves as the stock SNES core.
- HD OSD option off, or dump busy: same fallback.
- Wrong bitstream/daemon ABI: daemon exits with status 2
  ("magic/version mismatch"); no heartbeat (static `FRAME_SEQ`) exits 3.

---

# REVISION v2 — transport pivot (2026-10-12)

The section above describes the v1 mailbox architecture, which is **dead on
this device**: f2sdram port-1 FPGA-initiated *writes* are accepted and acked
but never commit — proven at clk_mem across three independent placements
(SEED 1/2/3) and at clk_sys with a healthy arbiter and serviced write port.
Port-1 FPGA-initiated *reads* are perfect at clk_sys (proven twice). Final
transport matrix:

| Operation | clk_mem | clk_sys |
|---|---|---|
| FPGA writes (port 1) | never commit | accepted, acked, **dropped** |
| FPGA reads (port 1) | wedge (×3 placements) | **perfect** |

v2 keeps only proven operations. DDRAM_CLK = clk_sys everywhere.

**ARM → FPGA (DDR3, CPU writes — proven):**
- Pixel buffers A/B and the ctrl word from the v1 layout survive unchanged
  (`0x3E002000` / `0x3E072000` / ctrl word). The daemon publishes frames by
  writing the ctrl word; the FPGA adopts `READY_BUF` on flip, exactly as v1
  specified.
- Deleted: the header block, the per-line register mailbox, the traffic cop,
  and every other FPGA write — the mailbox write port and cop muxes go away
  entirely (ddram.sv keeps ARM-independent reads only).

**FPGA → ARM (ttyS1 HPS-UART — replaces the whole mailbox side):**
Framing (rtl/m7_reg_stream.sv, little-endian):

```
A5 5C seq_l seq_h len_l len_h payload[0..len-1] crc8
```

- `crc8` is CRC-8 poly 0x07 over seq..payload, NOT the sync bytes.
- seq is a free-running u16; the receiver resyncs blind on A5 5C and tracks
  gaps via seq continuity.
- P2a test-mode payload: `payload[i] = (seq + i) ^ 0xA7` (self-describing;
  measures slip + bit-error rate at the target baud before anything is
  built on the link).
- Planned message types (finalized in P2b): per-line Mode 7 regs
  (delta-encoded), VRAM write-through deltas, VRAM/CGRAM resync dumps,
  CGRAM frames. Reference parser: daemon/m7_uart_parser.h (tested against
  the RTL in simulation; `make test`).
- hps_ext CMD_M7 stays dead by design: the HPS bus is polled by the MiSTer
  framework; a userspace daemon cannot drive it.

**TBD at P2 (decide with measured fetch numbers):** 16 bpp pixbuf vs
8 bpp + FPGA-side CLUT. Per-line fetch budget at clk_sys is the entire
scanline (341 cycles) — fetch-ahead with line-done handshakes is mandatory;
the CLUT option halves the fetch if the knife-edge turns out sharp.
