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
| 17 | `FMT8` | pixel buffers hold 8bpp CLUT indices (ctrl word v2 — MUST be 1) |
| 18 | `DUMP_REQ` | request a VRAM resync dump (REVISION v5) |
| 31:19 | — | zero |

**Bits [31:19] must be zero and `FMT8` must be 1.** The FPGA rejects a
ctrl word otherwise, as boot-time DDR3 garbage (there is no header magic
anymore, so this check is the only sanity gate on the word). Note bit 18
lives *inside* the old "reserved" span — the adoption mask narrowed from
`[31:17]` to `[31:19]` in REVISION v5; bit-18-set words from a pre-v5
bitstream are rejected there and vice versa a v5 daemon must not publish
to a pre-v5 bitstream expecting dumps (the daemon's telemetry probe
handles that).

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

# REVISION v5 — VRAM resync dump + write-through records on the stream (2026-10-16, P2c-3)

The record byte stream gains three VRAM opcodes in the LINE byte (values
outside 0..223 are opcodes), and the ctrl word gains a live `DUMP_REQ`
(bit 18). Together they close the loop that lets the daemon hold an
accurate local copy of Mode 7 VRAM:

## VRAM records

Address fields are **plane-local dpram byte addresses** (= VRAM word
index — daemon `loc_v1_`/`loc_v2_` arrays index them directly). `ah`
bit 7 = plane (0 = plane 1, 1 = plane 2), `ah[6:0]` = `addr[14:8]`;
`al` = `addr[7:0]`. Data bytes are consecutive addresses from `addr`.

| Record | Layout | Notes |
|---|---|---|
| `0xFD` dump chunk | `[len][FD][al][ah][data...]` | len=244 (240 data); short tail len=132 (128 data) at the 32 KiB plane end |
| `0xFC` write-through run | `[len][FC][al][ah][data...]` | len=4+N, N≤8; coalesced same-plane consecutive VRAM writes snooped from the PPU port |
| `0xFB` dump done | `[5][FB][seq][wt_drops l h]` | seq = completed-dump counter; wt_drops = current drop count |

Length budget: line/sync ≤ 20, WT ≤ 12, dump 244/132, pad 0x00. A
boundary len byte is therefore **never 0xC3**: `payload[0]==0xC3` with
the parser at a record boundary is a telemetry slot, unambiguously.
Mid-record (partial record carried across payloads) the first payload
byte is arbitrary data — receivers must keep feeding such payloads to
the record parser (the FPGA pauses record drain during telemetry slots
and resumes afterwards; no record bytes are ever consumed by a telemetry
payload).

## Dump protocol

- **Request**: daemon publishes a ctrl word with `DUMP_REQ` set (bit 18)
  and a bumped `READY_SEQ`. The FPGA consumes the bit when it adopts the
  word while idle (not dumping, nothing pending, not clearing RAM), then
  re-arms its trigger the next time it sees the bit clear. The daemon
  sets the bit for exactly one publish per request.
- **Transfer**: the FPGA hijacks port B of the plane being dumped, only
  inside vblank and never during RAM clear, paced by record-FIFO
  backpressure. A full 2×32 KiB dump takes ~17 frames at 3 Mbaud.
- **Completion**: the `0xFB` status record (in-band) and telemetry
  `dump_seq`++ (sideband).
- **Pacing (daemon)**: requests are cooldown-paced (≥1 s apart); a dump
  that doesn't complete within 3 s is re-requested. *(Superseded by v6:
  10 s timeout — yield-capped dumps legitimately take 2-6 s — plus a
  5 s paced full-resync while rendering.)*
- **Drift triggers**: telemetry `wt_drops` advancing by ≥4 (dropped
  write-through runs ⇒ the local image has holes) or any CRC-failed
  payload ⇒ hold publishing (`vram_valid_` cleared) and request a
  fresh dump. `0xFB` re-baselines the drop counter. *(Superseded by v6:
  the drift detector is DISABLED — the 16-bit `wt_drops` telemetry reads
  tear on the HPS UART (high byte unstable by ±32k, a counter observed
  frozen across 10 s while requests cycled), so the trigger fired
  spuriously. CRC-failed payloads still invalidate the stream via the
  framing layer.)*
- **Capability probe**: pre-P2c-3 bitstreams fill telemetry bytes 132+
  with `0xAA`. The daemon classifies the bitstream from the first
  telemetry frame and never sends dump requests to one that can't
  answer.

## Telemetry additions (payload[0]==0xC3 slots)

| Byte | Content |
|---|---|
| 132 | `{dump_req_arm, dstat_pend, dump_pend, dump_last, dump_active, dump_plane, 2'b00}` |
| 133 | completed-dump counter (wraps) |
| 134–135 | plane-1 write-through version (l,h) |
| 136–137 | plane-2 write-through version (l,h) |
| 138–139 | write-through drop count (l,h) |
| 140–141 | dump read pointer `dump_rd` (l,h) — v6 diag block |
| 142–143 | dump byte counter `dump_bc` (l,h) |
| 144–145 | record byte-rate `bw_cnt` (l,h) |
| 146–147 | record FIFO fill `rec_count` (l,h) |
| 148–255 | `0xAA` fill *(bytes 140–147 were `0xAA` in P2c-3; the v6 diag block reuses them)* |

## Receiver contract (daemon, P2c-3)

- Records `0xFD`/`0xFC` write their data bytes into the plane-local byte
  array at `addr` (bounds-checked); `0xFB` with len==5 marks the image
  valid and re-baselines `wt_drops`.
- Rendering publishes only when the per-line register frame is complete
  **and** the VRAM image is valid (initial `0xFB` received, no drift
  since).

# REVISION v6 — storm fixes, yield cap, paced resync, renderer VRAM model (2026-10-17, P2c-4)

Four on-device failure modes found and fixed, plus the daemon-side
renderer fix that turned the stream into a picture. No ABI field
changes; behavior, cadence and pacing all move.

## Channel cadence

Telemetry interleaving moves from 1-in-16 to **1-in-64** payload slots
(`m7_reg_stream.sv slot_cnt` widened to 8 bits). The measured channel
budget per line period (~1364 clk_sys) is ~18 B; telemetry at 6.25 %
of it starved line records. At 63/64 the record path gets ~278 KB/s of
the 3 Mbaud link. The daemon watchdog grace is matched to the new
cadence (40 telemetry slots ≈ 2.3 s at ~17 slots/s).

## Ctrl adoption + dump trigger (RTL)

The dump-FSM's arm path reacted to bare `ctrl_new` — which pulses once
per ctrl poll, every frame, changed word or not — so stale/garbage
captures with `DUMP_REQ` set fired random dumps. Now the adoption branch
(only reached for words that pass the reserved-zero + `FMT8` + new-seq
guard) drives a one-shot `dump_fire` with an explicit arm/disarm latch
(`dump_req_arm`); the FSM only consumes the pulse.

## Dump yield + completion priority (RTL)

Dump chunks previously staged whenever the record FIFO had 268 bytes
free — they monopolized the channel and per-frame line coverage
collapsed to 0/224 during dumps. Now:

- **Yield cap**: a chunk stages only while `rec_count < 40` (at most one
  chunk in flight in the ring). Dumps consume only the line stream's
  slack — measured ~4 chunks (960 B) per frame, a full 2×32 KiB dump in
  ~2-6 s, with line coverage holding 160-172/224 throughout.
- **`0xFB` completion outranks chunks**: the dstat branch moved above
  the chunk branch in the push sequencer (a lagging completion record
  used to stall the dump lifecycle for seconds).
- **Stall abort**: if the dump FSM makes no progress (no chunk staged,
  nothing pending) for ~2^22 clk_sys (~195 ms), it abandons the dump
  (clears `dump_active`/`dump_pend`). This is the kill-time wedge fix:
  a daemon killed mid-dump used to leave `dump_active` set forever and
  every later request was swallowed until a core reload.

## Daemon dump lifecycle

- **Timeout 3 s → 10 s**: yield-capped dumps legitimately take 2-6 s;
  the old timeout re-requested mid-dump and chained dumps by itself.
- **Watchdog v3**: the `0xFB` record stages `dump_seq` at push *start*
  while the FPGA increments the counter at push *completion* — so
  `tel == fb + 1` is the healthy steady state by construction. The
  comparison is bias-corrected (`tel - 1 - fb`); a genuine loss (no `fb`
  advance for 40 telemetry slots while idle) is diagnostic + recovery
  (re-request), never invalidation.
- **Drift detector disabled** (see v5 supersession above).
- **Paced periodic resync**: stream-heavy games (SMK streams map tiles
  every frame) outrun the write-through channel for good — the daemon
  receives ~1-byte `0xFC` fragments and its image goes stale. While the
  renderer is publishing, a full-resync dump is re-requested every 5 s
  (bounded replacement for the accidental storm resync; the yield cap
  keeps line coverage alive during it).
- **Renderer VRAM model fixed**: Mode 7 fetches are *flat byte*
  addresses — character data at flat `0x0000-0x3FFF`, tilemap at flat
  `0x4000-0x7FFF` — and flat byte `b` lives in plane `b & 1` at word
  `b >> 1` (the plane-local address the records carry). The old model
  (plane 1 = tilemap array, plane 2 = pixel array at the same word
  index) rendered solid-color tiles correctly by accident and turned
  every detailed tile into per-pixel noise. This fix is what made real
  game content appear; the record addressing itself was always right.

## Status line instrumentation (daemon)

The 5 s status line now carries `cov=` (per-frame delivered line-record
count /224, max gap) decoded from the record stream itself, and
`wt=` (write-through records/bytes received per frame) — the numbers
that turned every remaining ambiguity above into decodable data.

# REVISION v7 — BGMODE telemetry byte + event-driven resync (2026-10-17, P2c-7/8)

## Telemetry byte 152 = PPU BGMODE (RTL, build-8 bitstreams)

`PPU.vhd` exports `$2105` low bits as `BGMODE_OUT[2:0]` (threaded through
`rtl/SNES.vhd` and `rtl/main.v`); the top level places it at telemetry
payload byte 152 (`{5'b0, bgmode_out}`). On older bitstreams byte 152 is
`0xAA` filler — the daemon keeps its default (`7`) whenever it sees
`0xAA`, so the publish gate never stalls a bitstream without the field.

Why: `M7SEL` is NOT a mode indicator (it holds 0x8/0x9/0xff across mode
changes). Consumers:

- **Daemon publish gate**: render/publish only while `tel_mode_ == 7` —
  stops 57 KB/frame pixel-buffer writes (port contention with the fetch
  sweep) and stops the stale-pixbuf-through-new-palette artifact on
  non-Mode-7 screens (race finish / points tally).
- **RTL arm gate** (build-8): the display-path adoption/park additionally
  requires `bgmode_out == 3'd7`, so the HD layer falls back to native
  rendering the moment the PPU leaves Mode 7 even if the daemon has not
  caught up.

**Adoption rule (daemon)**: a non-0xAA byte 152 is accepted only after
TWO consecutive telemetry frames agree (the parser boots blind
mid-record; one misclassified record frame must not poison the gate —
the 0xAA guard would otherwise preserve the poison forever).

## Event-driven resync cadence (daemon)

The 5 s paced VRAM resync halves to **2.5 s while the write-through
channel is drowning** (`wt` drop deltas > 12 000 per status window,
accumulated with a <20 000 clamp against torn reads). SMK streams ~10 k
VRAM writes/s past a ~150 B/s capture budget; the accelerated pace keeps
the daemon's VRAM image within a few frames of the PPU during racing at
the cost of ~half the fetch sweep speed during dump phases (accepted
trade — alignment lockstep holds, `dr = py+1`).

## Debug interface (daemon, not on the wire)

`SIGUSR1` → `/tmp/m7_dbg.pgm` (raw CLUT-index PGM of the last-published
buffer, 256×224) + `/tmp/m7_dbg.txt` (per-line reg shadow, `m7sel`,
tilemap distinct/nonzero histogram, tileset bytes). Proven
2026-10-17: the title-screen "stripes" decoded as the CORRECT render of
SMK's zoomed-out title map (a=b=−23645 ⇒ scale ≈ 0.011, wrap fill).

# REVISION v6 — record-walk implementation fix (2026-10-17, P2c-9)

The wire format above did **not** change. This note documents an RTL bug
that violated it silently from P2c-2 until this revision, because every
capture taken in that window shows its signature.

The FPGA's payload-walk LUT (`rm_val` in SNES.sv) mapped **two mask bits
per field** (bit0=A.lo, bit1=A.hi, …) with no step-parity selector, while
the mask carries one bit per field and the walk clears a bit per byte
pair. Every value byte was therefore emitted **doubled**, and the
X/Y/HOFS/VOFS LUT entries were unreachable (casez priority matched the
A/B/C/D patterns first). `cur_mask` also ordered bits 4/5 (X/Y) and 6/7
(HOFS/VOFS) opposite to `M7_RECF_*`. Net effect on the wire: values that
decoded as doubled-byte palindromes (0x3636, 0x4B4B, 0xFFFF…) or zeros —
a capture whose per-line registers are all palindromic is a pre-v6
capture, not real data.

The fix walks one bit per field via a priority chain (`M7_RECF_A..VOFS`
lsb-first), selects lo/hi by step parity (value pairs occupy steps
(3,4),(5,6),…; odd step = lo byte), and orders `cur_mask` exactly as
`M7_RECF_*`. The 0xFE sync's M7SEL tail is selected only when
`rec_rm[7:0]` is fully cleared (the sync seeds the walker with bit 8
set). Verified byte-for-byte against the daemon's parser by simulation
before hardware; the daemon's SIGUSR1 dump prints a
`palindrome fields: N/1792` counter — near-zero on v6 hardware, near-all
before.

## REVISION v7 — HD 2x geometry fix (2026-10-17)

The pixel-buffer geometry changed: rows are now **512 HD dots** (2x the 256
native lores pixels), and the display strobe rate is **2 strobes per native
lores pixel** (1024 CLK_VIDEO cycles per line, `M7_HD_SCALE = 2`).

Why: the video path outputs 1024 px per line (512 hires dots, 4 CLK_VIDEO
cycles per dot, `ce_pix` once per dot). At the old scale 4 the strobe
generator emitted 4 strobes per dot = 2048 per line, so the linebuf's
10-bit read pointer wrapped at 1024 and every line displayed its row TWICE
side by side (left half = the full row stretched 2x, right half = the same
row again) — on screen: "everything Mode 7 is very stretched wide" with a
seam and a repeated texture. At scale 2 the generator emits exactly 2
strobes per dot (strobe on the first two CLK_VIDEO cycles of each dot),
rd_x counts 0..511, and the slot index is rd_x directly.

Row layout (8bpp): row r lives at word offset r*64 from the buffer base
(`{r, fetch_word[5:0]}`, 64 64-bit words = 512 B). Buffer slots are
unchanged (0x70000 each; 224*512 B = 0x1C000 used).

Sampling: dot 2k samples the lores pixel k coordinate; dot 2k+1 samples it
offset by half a matrix step (`regs.a / 2`, `regs.c / 2` in the 8.8
domain, truncated toward zero) — the exact semantics of the PPU's native
HD path (PPU.vhd `M7_VRAM_X2 = M7_VRAM_X + M7A/2`), so the overlay and the
native renderer agree per dot.
