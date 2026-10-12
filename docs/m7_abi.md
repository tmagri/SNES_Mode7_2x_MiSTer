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
| Pixel buffer A | `0x3E002000` | 448 KiB | ARM→FPGA | CLUT indices, 8 bpp, 224 × 256 B used (v3) |
| Pixel buffer B | `0x3E072000` | 448 KiB | ARM→FPGA | CLUT indices, 8 bpp, 224 × 256 B used (v3) |
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

> **Superseded by ctrl word v2 — see REVISION v3 below** (`FMT8` now lives
> at bit 17; `DUMP_REQ` moved to bit 18).

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
**Resolved — REVISION v3 below: 8 bpp + FPGA-side CLUT.**

---

# REVISION v3 — 8 bpp pixel buffers + FPGA-side CLUT (2026-10-13, P2c-1)

Proven on device (build `187542bf` family): the 16 bpp fetch could sustain
only ~4–5 fresh rows per frame at clk_sys (22% native fallback, visible
seams). The 8 bpp + CLUT format cuts each row to 32 DDR3 words ≈ 18 µs
against the 63.5 µs line → ~3.5 rows produced per displayed line; telemetry
shows a fresh row on 94% of lines and tear-free double-buffer flips.

## Ctrl word v2 (32-bit at `0x3E001000`, ARM→FPGA)

| Bits | Name | Meaning |
|---|---|---|
| 15:0 | `READY_SEQ` | daemon increments on every published frame |
| 16 | `READY_BUF` | buffer the daemon just finished rendering |
| 17 | `FMT8` | **must be 1** — pixbufs hold 8 bpp CLUT indices |
| 18 | `DUMP_REQ` | daemon requests a VRAM resync dump (consumed by P2c-3; keep 0 until then) |
| 31:19 | — | zero |

Adoption guard: the FPGA accepts a ctrl word only when
`bits[31:18] == 0 && FMT8 == 1` — this rejects boot-time DDR3 garbage and
any stale 16 bpp publisher in one test. First published word for
`seq=1, buf=0` is therefore `0x00020001`. The same condition (latched once
per frame on `ctrl_new`) also triggers the CLUT reload; reloading an
identical palette is harmless.

## Pixel buffer format (per slot, `M7_PIXBUF_BASE` / `M7_PIXBUF_B_BASE`)

- 224 rows × **256 B** used (`M7_PIX_STRIDE = 256`); each byte is a CGRAM
  palette index. Buffer regions stay 448 KiB for layout stability; only the
  first 56 KiB is live.
- Row `y` occupies words `[32*y, 32*y+31]` (8 index bytes per 64-bit word).
- The daemon fills the **inactive** slot, then publishes via the ctrl word;
  the FPGA swaps slots per line (atomic at line boundaries — tearing
  impossible by construction).

## CLUT (FPGA side, in `hd_mode7_linebuf`)

- 256 × 15-bit BGR555, loaded from the PPU's live CGRAM shadow
  (sequential mirror port) once per adopted FMT8 ctrl word — i.e. every
  frame the daemon publishes. The game animating its palette shows through:
  the daemon ships indices, the core supplies colors.
- Display expansion: BGR555 → RGB888 by low-bit replication
  (`R8 = {R5, R5[4:2]}` etc.).
- Fixed 4× scale: native index = `rd_x[9:2]` — every native pixel consumes
  **4 HD pixel strobes** (the display-side expansion contract).

---

# REVISION v4 — per-line register records on the UART stream (2026-10-13, P2c-2)

The FPGA→ARM direction now carries live Mode 7 state alongside telemetry.
Every payload slot on the ttyS1 stream (3 Mbaud, framing unchanged:
`A5 5C seq len payload crc8`) is discriminated by `payload[0]`:

| `payload[0]` | Content |
|---|---|
| `0xC3` | telemetry snapshot (same byte map as before; byte 131 = record drop count) |
| anything else | a slice of the record byte stream |

## Record byte stream

Each record is `len`-prefixed, len counting itself:

```
[len][line][mask][lo hi]...
```

- `line` 0..223: the display line whose values these are. `0xFE` is a
  per-frame **full sync** (`mask=0xFF`, all eight values + M7SEL appended,
  len=20) pushed at vblank entry; `0xFF` reserved.
- `mask` bit i set ⇒ a 16-bit little-endian value follows for field i,
  lsb-first order: `A, B, C, D, X, Y, HOFS, VOFS` (constants
  `M7_RECF_*` in both ABI headers). A–D are the raw int16 register values;
  X/Y/HOFS/VOFS are 13-bit, zero-extended.
- The mask is a **delta against the previously captured line** (the
  reference chain), so an unchanged field is simply absent. A line whose
  registers didn't change at all sends nothing.
- Records may straddle two payloads (or a telemetry payload); the receiver
  carries the partial record. Padding after the last record in a payload is
  `0x00`; a mid-record pad is impossible by construction.
- A CRC-failed payload may swallow record bytes: the receiver must discard
  per-line state and resync at the next `0xFE` full sync (~16.7 ms later).

The FPGA captures each line at its hde fall — the instant the registers
hold exactly what that line rendered with — and pushes at most one record
per line; the worst-case game demand (all four matrix regs changing every
line, 60 fps) is ~134 KB/s against ~207 KB/s of record capacity (15 of
every 16 payload slots; slots with an empty record FIFO are skipped, which
keeps the link quiet when nothing changes).

## Receiver contract (daemon, P2c-2)

- Maintain the delta chain: on `0xFE` load all eight values + M7SEL into
  the chain; on a line record, apply each masked field into the chain and
  store the chain as that line's values.
- On daemon start (or after a CRC loss) per-line values are unreliable
  until each line's first record after the next full sync.
- Debug visualization (current build): each display line paints `A[7:0]`
  as the left-half CLUT index and `D[7:0]` as the right half — the HDMA
  perspective table appears as per-line colour bands.
