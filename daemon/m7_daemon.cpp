// Expose nanosleep / clock_gettime under g++ -std=c++11 on glibc (MiSTer);
// _DEFAULT_SOURCE also pulls in the extended baud constants (B3000000).
// macOS gets these via _DARWIN_C_SOURCE automatically, so only define on Linux.
#if defined(__linux__) && !defined(_DEFAULT_SOURCE)
#define _DEFAULT_SOURCE 1
#endif

#include "m7_abi.h"
#include "m7_mode7_renderer.h"
#include "m7_uart_parser.h"

#include <cstdint>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/mman.h>
#include <termios.h>
#include <unistd.h>

// ===========================================================================
// True HD Mode 7 ARM daemon — PIVOT v2
//
// Transport reality (docs/m7_abi.md REVISION v2): f2sdram port-1 FPGA
// writes are broken on this device, so the FPGA NEVER writes DDR3 — there
// is no header, no heartbeat, no mailbox. The daemon is the only DDR3
// writer (pixel buffers + ctrl word, proven path) and the FPGA reads them
// back at clk_sys (proven path). FPGA->ARM control data arrives over the
// HPS UART (/dev/ttyS1, rtl/m7_reg_stream.sv framing).
//
// P2b mode: test card. The daemon gates on a run of CRC-valid UART frames
// (the bitstream gate — wrong rbf = silent line), fills the pixel buffer
// with an animated diagonal sweep and publishes the ctrl word once; the
// FPGA's continuous fetch loop then shows it in Mode 7 content. This
// proves UART -> parse -> render -> DDR3 -> fetch -> screen end to end.
// The software renderer consumes the per-line register and VRAM records on
// the same framing, then publishes one 8bpp CLUT-index row per scanline.
//
// Exit codes: 1 = /dev/mem or mmap failure, 2 = ttyS1 open/config failure,
// 3 = no valid UART stream (wrong/absent bitstream).
// ===========================================================================

namespace {

// SIGUSR1 debug: write the last-published pixbuf + renderer state to /tmp.
// The handler only sets a flag; the main loop does the (unsafe-in-a-handler)
// file work between polls.
volatile sig_atomic_t g_dbg_dump = 0;
void OnUsr1(int) { g_dbg_dump = 1; }

const char *kDevMem = "/dev/mem";
// Optional kernel module (kernel/m7_mem_wc) exposing a write-combined
// mapping of the two pixel buffers — avoids per-word Device-memory AXI
// serialization on the 448 KiB/frame pixel push. Absent ⇒ /dev/mem fallback.
const char *kDevWc = "/dev/m7_mem_wc";
// Header + regs + ctrl + both pixel buffers live in the first 1 MiB;
// VRAM/CGRAM images follow. One 2 MiB mapping covers everything.
const uint32_t kMapSpan = 0x200000;
// Byte size of the WC window: both ping-pong buffers, contiguous.
const uint32_t kPixWindowSpan = 2u * M7_PIXBUF_BYTES;

inline uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + ts.tv_nsec;
}

inline void sleep_ns(uint64_t ns) {
  timespec ts = {static_cast<time_t>(ns / 1000000000ull),
                 static_cast<long>(ns % 1000000000ull)};
  nanosleep(&ts, nullptr);
}

// /dev/mem maps of RAM-range physical addresses are CACHEABLE on ARM32
// mainline (pfn_valid ⇒ MT_MEMORY, not Device). Stores to a cold line sit
// dirty in L2 indefinitely — the FPGA's f2sdram read path (physical DDR3)
// never sees them. A single 32-bit ctrl store has no streaming pressure to
// force eviction, so every publish must clean the line explicitly. The
// glibc wrapper header (sys/cachectl.h) is missing from the cross sysroot,
// so call the ARM private syscall directly: __ARM_NR_cacheflush(start, end,
// flags=0 clean+invalidate), stable ABI since ARM Linux 2.6.
#if defined(__arm__)
inline long CacheFlush(volatile void *addr, size_t bytes) {
  const uintptr_t begin = reinterpret_cast<uintptr_t>(addr);
  return syscall(0x0F0002, reinterpret_cast<void *>(begin),
                 reinterpret_cast<void *>(begin + bytes), 0);
}
#else
inline long CacheFlush(volatile void *, size_t) { return 0; }
#endif

}  // namespace

class M7Daemon {
 public:
  M7Daemon(bool extbg) : extbg_(extbg) {}

  // Returns 0 on success, else the process exit code (1 = /dev/mem or mmap
  // failure, 2 = magic/version mismatch, 3 = no heartbeat). The message is
  // already logged on failure.
  int Init() {
    mem_fd_ = open(kDevMem, O_RDWR | O_SYNC);
    if (mem_fd_ == -1) {
      std::cerr << "ERROR: could not open /dev/mem" << std::endl;
      return 1;
    }
    map_ = static_cast<volatile uint8_t *>(
        mmap(nullptr, kMapSpan, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd_,
             M7_MAILBOX_BASE));
    if (map_ == MAP_FAILED) {
      std::cerr << "ERROR: mmap of " << std::hex << "0x" << M7_MAILBOX_BASE
                << std::dec << " failed" << std::endl;
      return 1;
    }

    hdr_  = reinterpret_cast<volatile uint16_t *>(map_);
    regs_ = reinterpret_cast<volatile uint16_t *>(map_ + (M7_REGS_BASE - M7_MAILBOX_BASE));
    ctrl_ = reinterpret_cast<volatile uint32_t *>(map_ + (M7_CTRL_BASE - M7_MAILBOX_BASE));

    // Pixel buffers through the write-combined device when the module is
    // loaded; the ctrl-word publish still goes over /dev/mem Device memory,
    // so data-before-publish ordering is preserved without extra barriers.
    wc_fd_ = open(kDevWc, O_RDWR | O_SYNC);
    if (wc_fd_ != -1) {
      wc_map_ = static_cast<volatile uint8_t *>(
          mmap(nullptr, kPixWindowSpan, PROT_READ | PROT_WRITE, MAP_SHARED,
               wc_fd_, M7_PIXBUF_BASE));
      if (wc_map_ != MAP_FAILED) {
        std::cout << "pixel window via " << kDevWc << " (write-combined)"
                  << std::endl;
      } else {
        close(wc_fd_);
        wc_fd_ = -1;
      }
    }
    const volatile uint8_t *pix_base =
        (wc_map_ && wc_map_ != MAP_FAILED)
            ? wc_map_
            : map_ + (M7_PIXBUF_BASE - M7_MAILBOX_BASE);
    pix_[0] = reinterpret_cast<volatile uint16_t *>(const_cast<uint8_t *>(pix_base));
    pix_[1] = reinterpret_cast<volatile uint16_t *>(
        const_cast<uint8_t *>(pix_base) + M7_PIXBUF_BYTES);
    // --- PIVOT v2 bitstream gate: the UART stream IS the handshake. The
    // FPGA never writes DDR3, so there is no header magic to check; a
    // run of CRC-valid frames proves the HD bitstream is loaded. ---
    if (OpenStream() != 0) return 2;
    if (!WaitStreamFrames(8, 5000)) {
      std::cerr << "ERROR: no CRC-valid UART frames in 5 s — HD bitstream "
                   "absent or stream misconfigured (need M7_2X_ENABLE rbf)"
                << std::endl;
      return 3;
    }
    std::cout << "stream OK: " << frames_valid_ << " valid frames, seq "
              << last_seq_ << ", " << parser_.resyncs() << " resyncs, "
              << M7_HD_SCALE << "x, lines " << M7_LINE_COUNT
              << (extbg_ ? ", EXTBG on" : ", BG1 only") << std::endl;
    return 0;
  }

  ~M7Daemon() {
    if (stream_fd_ != -1) close(stream_fd_);
    if (map_ && map_ != MAP_FAILED) munmap(const_cast<uint8_t *>(map_), kMapSpan);
    if (mem_fd_ != -1) close(mem_fd_);
    if (wc_map_ && wc_map_ != MAP_FAILED)
      munmap(const_cast<uint8_t *>(wc_map_), kPixWindowSpan);
    if (wc_fd_ != -1) close(wc_fd_);
  }

  // The ctrl word is a one-store-per-event write to a cold cache line: with
  // a cached /dev/mem mapping it never reaches DDR3 without an explicit
  // clean (the FPGA's ctrl poller reads physical memory every frame).
  void PublishCtrl(uint32_t w) {
    *ctrl_ = w;
    const long r = CacheFlush(ctrl_, sizeof(*ctrl_));
    static int log_n = 0;
    if (++log_n <= 4)
      std::cout << "publish seq=" << (w & 0xFFFF) << " flush_ret=" << r
                << std::endl;
  }

  void Run() {
    std::cout << "P2c Mode 7 software renderer (per-line register + VRAM stream)"
              << std::endl;

    FillCard(0, 0);
    FillCard(1, 0);
    cur_pub_ = 0;
    ready_seq_ = 1;
    PublishCtrl(CtrlWord(ready_seq_, cur_pub_, false));
    std::cout << "ctrl published (ready_seq=1, READY_BUF=0, FMT8) — FPGA "
                 "should start fetching" << std::endl;

    uint64_t log_last = now_ns();
    uint32_t log_mark = 0;
    uint32_t last_syncs = 0;
    bool published_frame = false;

    signal(SIGUSR1, OnUsr1);

    while (true) {
      PumpStream();
      if (g_dbg_dump) {
        g_dbg_dump = 0;
        WriteDebugDump();
      }

      // The full-sync record follows the line records at vblank. Do not
      // render until the initial VRAM snapshot is complete as well.
      if (syncs_ != last_syncs) {
        last_syncs = syncs_;
        if (completed_frame_ready_ && vram_valid_ && tel_mode_ == 7 &&
            (!static_card_ || !published_frame)) {
          cur_pub_ ^= 1u;
          RenderFrame(cur_pub_);
          PublishCtrl(CtrlWord(++ready_seq_, cur_pub_, false));
          last_render_ns_ = now_ns();
          published_frame = true;
          completed_frame_ready_ = false;
        }
      }

      const uint64_t now = now_ns();
      // Periodic VRAM resync: the write-through channel cannot carry a
      // stream-heavy game's VRAM writes (SMK streams map tiles every frame;
      // the daemon receives ~1-byte wt fragments and its image goes stale —
      // visibly: multicolor pixel noise over an otherwise recognizable
      // frame). The pre-v4 dump storm re-synced VRAM every 3-5 s by
      // accident and the image benefited from it; institutionalize that
      // benefit in bounded form: one paced re-request per interval while
      // the renderer is actually publishing (the yield cap keeps line
      // coverage alive during dumps, and dstat outranks chunks so
      // completions still land promptly).
      if (!dump_requested_ && !dump_req_pending_ && vram_valid_ &&
          now - last_render_ns_ < 2000000000ull &&
          now - last_resync_ns_ >= ResyncInterval()) {
        last_resync_ns_   = now;
        dump_req_pending_ = true;
      }
      // VRAM resync lifecycle: publish a pending request (cooldown-paced)
      // and re-request when a dump in flight stalls past the timeout.
      MaybeRequestDump(now);
      if (dump_clear_pending_ && now >= dump_clear_at_ns_) {
        // DUMP_REQ re-arm: the FPGA re-arms its request latch only on an
        // adopted word with the bit CLEAR (a level, edge-detected against
        // the latch). While stuck waiting for a first successful dump we
        // publish nothing but request words, so the latch would stay
        // disarmed forever and every request after the first is silently
        // swallowed. Follow each request with one clear word; the FPGA's
        // per-frame ctrl poll always adopts the request word first.
        dump_clear_pending_ = false;
        PublishCtrl(CtrlWord(++ready_seq_, cur_pub_, false));
        std::cout << "dump_req clear word published (ready_seq=" << ready_seq_
                  << ")" << std::endl;
      }
      if (dump_requested_ && now - dump_requested_at_ns_ >= kDumpTimeoutNs) {
        dump_requested_ = false;
        dump_req_pending_ = true;
      }
      if (now - log_last >= 5000000000ull) {
        log_last = now;
        std::cout << "stream: " << frames_valid_ << " valid frames ("
                  << (frames_valid_ - log_mark) / 5 << "/s), "
                  << parser_.resyncs() << " resyncs, "
                  << parser_.crc_bad() << " crc_bad | syncs=" << syncs_
                  << " lines=" << rec_lines_ << " sel=0x"
                  << std::hex << static_cast<int>(m7sel_) << std::dec
                  << " mode=" << static_cast<int>(tel_mode_)
                  << " drops=" << static_cast<int>(tel_drops_)
                  << " wtdrop=" << tel_wt_drops_ << " dumps=" << dumps_done_
                  << " fb=" << static_cast<int>(fb_seq_seen_)
                  << "/" << static_cast<int>(tel_dump_seq_)
                  << " dm=" << static_cast<int>(tel_dm_)
                  << " rd=" << tel_rd_ << " bc=" << tel_bc_
                  << " bw=" << tel_bw_ << " rcnt=" << tel_rcnt_
                  << " cov=" << cov_lines_last_ << "/224 g=" << cov_gap_last_
                  << " drops16=" << tel_drops16_ << " retry=" << tel_retry_
                  << " arm=" << tel_arm_ << "/224 lri="
                  << static_cast<int>(tel_lri_) << " dr="
                  << static_cast<int>(tel_disp_row_)
                  << " py=" << tel_ppuy_
                  << " ars=" << tel_ars_ << " pub=" << ready_seq_
                  << " rows=" << std::hex << RowsHex(tel_rows_, 0, 14)
                  << RowsHex(tel_rows_, 14, 28) << std::dec
                  << " hde=" << tel_hde_
                  << " fr=" << (drt_frames_ ? (drt_acc_ / 32) / drt_frames_
                                            : 0) << "r/f"
                  << " wt=" << wt_recs_last_ << "r/" << wt_bytes_last_ << "B"
                  << " wts=" << wtdrop_acc_
                  << (dump_requested_ ? " dumpWAIT" : "")
                  << (dump_req_pending_ ? " dumpREQ" : "") << std::endl;
        drt_acc_    = 0;
        drt_frames_ = 0;
        wtdrop_acc_ = 0;
        log_mark = frames_valid_;
      }
      sleep_ns(2000000ull);  // 2 ms poll; syncs arrive at 60 Hz
    }
  }

 private:
  // Ctrl word v2: ready_seq | buffer << 16 | FMT8 (bit 17, required).
  // DUMP_REQ (bit 18) asks the FPGA for a VRAM resync dump. The FPGA
  // consumes the bit when it adopts the word (and is not already
  // dumping), then re-arms its trigger the next time it sees the bit
  // clear — so the daemon sets it for exactly one publish per request.
  static uint32_t CtrlWord(uint32_t seq, uint32_t buf, bool dump_req) {
    return (seq & 0xFFFFu) | (buf << M7_CTRL_READY_BUF) |
           (1u << M7_CTRL_FMT8) |
           (dump_req ? (1u << M7_CTRL_DUMP_REQ) : 0u);
  }


 private:
  // M7_STATIC=1 freezes the card after the initial fill (display-path proof)
  const bool static_card_ = std::getenv("M7_STATIC") != nullptr;

  // Extended baud constants (B3000000+) are Linux-only; fall back to the
  // raw numeric value so the source still syntax-checks on macOS hosts.
#ifdef B3000000
#define M7_TTY_BAUD B3000000
#else
#define M7_TTY_BAUD 3000000
#endif

  int OpenStream() {
    stream_fd_ = open("/dev/ttyS1", O_RDONLY | O_NOCTTY);
    if (stream_fd_ == -1) {
      std::cerr << "ERROR: open /dev/ttyS1 failed" << std::endl;
      return -1;
    }
    termios tio {};
    if (tcgetattr(stream_fd_, &tio) != 0) {
      std::cerr << "ERROR: tcgetattr /dev/ttyS1 failed" << std::endl;
      return -1;
    }
    tio.c_iflag = 0;  // raw: no parity handling, no strip, no flow control
    tio.c_oflag = 0;
    tio.c_lflag = 0;
    tio.c_cflag = CS8 | CREAD | CLOCAL;
    cfsetispeed(&tio, M7_TTY_BAUD);
    cfsetospeed(&tio, M7_TTY_BAUD);
    tio.c_cc[VMIN]  = 0;
    tio.c_cc[VTIME] = 1;  // read() returns within 0.1 s of the last byte
    if (tcsetattr(stream_fd_, TCSANOW, &tio) != 0) {
      std::cerr << "ERROR: tcsetattr 3 Mbaud on /dev/ttyS1 failed" << std::endl;
      return -1;
    }
    tcflush(stream_fd_, TCIFLUSH);
    return 0;
  }

  // Drains whatever the UART has into the parser. CRC-valid frames are
  // classified by payload[0]: 0xC3 = telemetry (drops counter only), else a
  // slice of the per-line record byte stream.
  uint32_t PumpStream() {
    uint8_t buf[4096];
    const int n = read(stream_fd_, buf, sizeof(buf));
    uint32_t got = 0;
    for (int i = 0; i < n; ++i) {
      m7_uart_frame fr;
      if (!parser_.feed(buf[i], &fr)) continue;
      ++frames_valid_;
      ++got;
      last_seq_ = fr.seq;
      if (have_seq_ && fr.seq != static_cast<uint16_t>(expect_seq_ + 1))
        ++slips_;
      expect_seq_ = fr.seq;
      have_seq_ = true;
      // Telemetry slots carry payload[0]=0xC3. A record payload can only
      // start with 0xC3 if the stream is at a record BOUNDARY (a len
      // byte) — boundary len bytes are <=20, <=12, 132 or 244, never
      // 195. Mid-record (carry pending) the first byte is arbitrary
      // data, so the payload MUST go to the record parser or those
      // bytes are lost for good.
      if (fr.payload[0] == 0xC3 && carry_len_ == 0) {
        if (fr.len >= 132) tel_drops_ = fr.payload[131];
        // Display-path counters (pre-P2c bytes, still live): arm_cnt = lines
        // that actually showed the HD buffer last frame (224 = no native
        // fallback), disp_row = the row id in the displayed linebuf slot.
        if (fr.len >= 44)  tel_arm_ = le16(fr.payload + 42);
        if (fr.len >= 129) tel_disp_row_ = fr.payload[128];
        // Full sticky row_done bitmap (payload 4..31 = rows 0..223): shows
        // the fetch sweep's lead/consumed prefix directly. last_row_id [129]
        // is the row sitting complete in the inactive linebuf slot.
        if (fr.len >= 130) {
          memcpy(tel_rows_, fr.payload + 4, sizeof(tel_rows_));
          tel_lri_ = fr.payload[129];
        }
        // Sweep throughput: drt_cnt [36] (completed fetch words, 32/row) is
        // cumulative but only accrues ~11-14k words between telemetry
        // samples (~64 frames), so the 16-bit delta never wraps. Divide by
        // 32 and by the exact number of SNES frames since the previous
        // telemetry frame (counted via 0xFE syncs) -> rows/frame.
        if (fr.len >= 44) {
          const uint16_t drt_now = le16(fr.payload + 36);
          drt_acc_ += static_cast<uint16_t>(drt_now - drt_prev_);
          drt_prev_ = drt_now;
          tel_hde_ = le16(fr.payload + 40);
          drt_frames_ += syncs_ - drt_sync_mark_;
          drt_sync_mark_ = syncs_;
          tel_ppuy_ = le16(fr.payload + 58);  // scanline at sample instant
          tel_ars_  = le16(fr.payload + 60);  // FPGA's last adopted ready_seq
          // PPU BGMODE ($2105 low bits) at the sample instant (build-8+
          // bitstreams; 0xAA filler on older ones — keep 7 then, so the
          // publish gate below never stalls on a bitstream without it).
          if (fr.len >= 153 && fr.payload[152] != 0xAA) {
            // Adopt only after two consecutive telemetry frames agree on a
            // non-0xAA byte. The parser boots blind mid-record: one record
            // frame whose data byte 0xC3 lands at payload[0] classifies as
            // telemetry (carry_len_==0), and its arbitrary byte 152 would
            // poison tel_mode_ — which the 0xAA guard below then preserves
            // forever (true telemetry carries 0xAA and never updates it).
            // Real BGMODE repeats on every telemetry frame; boot garbage
            // happens once.
            if (fr.payload[152] == prev_mode_raw_)
              ++mode_agree_;
            else
              mode_agree_ = 0;
            prev_mode_raw_ = fr.payload[152];
            if (mode_agree_ >= 1) tel_mode_ = fr.payload[152] & 7;
            // Raw evidence for the byte-152 gate: capture neighbors so a
            // misaligned or bleeding export is visible in the debug dump.
            last_tel_len_ = fr.len;
            memcpy(tel_150_, fr.payload + 150, 6);
          }
        }
        // FPGA dump-machinery window (bytes 140-147, P2c-3 diag block):
        // dm = fetch/dump FSM state, rd = dump read pointer, bc = bytes
        // landed in the in-flight chunk, bw = byte-window cycles ever,
        // rcnt = record-ring fill. A frozen tel_dump_seq_ with rd==0 means
        // dumps never start (arm/adoption path); rd moving means one is
        // streaming; rcnt pinned high means the ring stopped draining.
        if (fr.len >= 148) {
          tel_dm_   = fr.payload[1] & 7;
          tel_rd_   = le16(fr.payload + 140);
          tel_bc_   = le16(fr.payload + 142);
          tel_bw_   = le16(fr.payload + 144);
          tel_rcnt_ = le16(fr.payload + 146);
        }
        // NOTE (2026-10-17): a "fire the resync dump NOW on the mode->7
        // transition" trigger was tried here and REVERTED. SMK's attract
        // flaps BGMODE 0/1/7 constantly; the trigger fired 75 dumps in
        // ~7 min, and at the yield-capped chunk rate a dump owns the
        // record channel for ~4-8 s — valid frames collapsed 1100->237/s,
        // cov to 0/224, and the per-line M7 matrix records starved (the
        // render ran on a=0 b=0 c=0 d=257 = vertical-band speckle). The
        // paced 2.5 s event-driven resync stays the only dump scheduler.
        // P2c-5 line-retry counters (bytes 148-151): stash overwrites (real
        // losses, 16-bit — the legacy [131] byte wraps within one frame
        // under wt bursts) and retry pushes delivered.
        if (fr.len >= 152) {
          tel_drops16_ = le16(fr.payload + 148);
          tel_retry_   = le16(fr.payload + 150);
        }
        // Capability probe: pre-P2c-3 bitstreams fill telemetry bytes
        // 132+ with 0xAA. One telemetry frame decides whether VRAM dump
        // requests are safe to send at all.
        if (fr.len >= 140) {
          if (!tel_probe_done_) {
            tel_probe_done_ = true;
            dump_capable_ = fr.payload[132] != 0xAA;
            if (dump_capable_) {
              dump_req_pending_ = true;  // boot-time full snapshot
              std::cout << "VRAM dump channel detected — boot resync "
                           "armed" << std::endl;
            } else {
              std::cout << "bitstream lacks VRAM dump channel (pre-P2c-3 "
                           "rbf); renderer disabled" << std::endl;
            }
          }
          if (dump_capable_) {
            tel_dump_seq_  = fr.payload[133];
            // 0xFB-loss watchdog v3 (freeze semantics + seq bias): fb_seq_seen_
            // ADVANCING is itself the proof that completion records are
            // flowing. TWO structural facts make "tel != fb" a BAD alarm:
            // (1) the FPGA bumps dump_seq when the 0xFB finishes entering
            // the ring, but the record CARRIES the pre-increment value — so
            // tel == fb+1 is the HEALTHY steady state forever (the -1 in
            // the comparison below); the old "tel != fb while idle" test
            // therefore fired between EVERY pair of dumps, each fire
            // requesting another dump: the ~5 s-per-dump storm seen on
            // device with build 3. (2) Under continuous re-dumping tel
            // running one ahead is legitimate indefinitely (the dump
            // treadmill: watchdog re-request -> dump -> lag re-arms the
            // watchdog, starving the renderer — 1 publish in 4 min at its
            // worst, lines= collapsed 14k/s -> 49/s on device). The real
            // failure mode (record-FIFO aliasing class) is fb FROZEN while
            // tel climbs past fb+1. Alarm only on that, across
            // kFbMissTelSamples samples.
            if (fb_seq_seen_ != fb_seq_prev_) {
              fb_seq_prev_      = fb_seq_seen_;
              tel_seq_mismatch_ = 0;
            } else if (!dump_requested_ &&
                       static_cast<uint8_t>(tel_dump_seq_ - 1 - fb_seq_seen_) != 0) {
              if (tel_seq_mismatch_ < 255) ++tel_seq_mismatch_;
              if (tel_seq_mismatch_ == kFbMissTelSamples) {
                // v3: DIAGNOSTIC ONLY. On device this fired every ~1.5 s
                // even at a 2.25 s grace, and each fire's own line showed
                // tel=fb+1 BEFORE the fire's request existed — i.e. dumps
                // ring-enter with no outstanding daemon request (the FPGA
                // self-triggers; suspected garbage ctrl-word reads while
                // dump traffic floods the f2sdram port). Every dump still
                // completes (fb advances ~0.7/s), so the image is being
                // re-proven continuously and invalidating + re-requesting
                // here only starved the renderer (1 publish in minutes)
                // and fed the treadmill. If fb ever truly freezes while
                // tel climbs (the lost-completion failure mode), this
                // line fires forever — visible in one log read; the
                // 3 s stall timeout remains the re-request backstop.
                std::cout << "dump_seq=" << static_cast<int>(tel_dump_seq_)
                          << " ahead of 0xFB (fb_seq="
                          << static_cast<int>(fb_seq_seen_)
                          << ") -- completion record lost (diagnostic)"
                          << std::endl;
                // Recovery (not invalidation): the dominant real cause is a
                // SWALLOWED REQUEST (wedged dump FSM from a kill-time
                // ring-full 0xFB drop — dump_active never cleared), which
                // leaves tel frozen ahead of fb forever and also disarms
                // the 3 s timeout via the stale FB. Re-request so the next
                // healthy window actually dumps. Keep the image live:
                // wt records keep it fresh and dumps don't touch video
                // buffers, so there is nothing to invalidate.
                if (!dump_requested_) dump_req_pending_ = true;
              }
            } else {
              tel_seq_mismatch_ = 0;
            }
            tel_vram1_ver_ = le16(fr.payload + 134);
            tel_vram2_ver_ = le16(fr.payload + 136);
            // wt_drops drift detector: DISABLED (P2c-3 device evidence).
            // The 16-bit field tears under sampling: the high byte shows
            // ±32k instability, and the device also produced small false
            // deltas — requests cycled every ~2 s while the counter read
            // IDENTICAL across two consecutive 5 s status lines, i.e.
            // nothing was actually dropping. Each false fire invalidated
            // a proven VRAM image and re-dumped (~67 kB = ~20 % of the
            // UART budget per dump), starving line records and sustaining
            // the dump treadmill together with the old watchdog. A
            // trustworthy resync trigger needs an FPGA-side STICKY burst
            // latch (set on any drop, cleared by the next ctrl word), not
            // a sampled counter. Until then wt holes from genuine drops
            // stay cosmetic (stale tiles until the next dump); dumps are
            // requested on boot, crc_bad, and the FB-loss watchdog only.
            tel_wt_drops_ = le16(fr.payload + 138);
            // Streaming-intensity signal: accumulate wrap-safe deltas of the
            // wt drop counter (torn reads jump >20k in one sample — skip
            // those). Heavy streaming (SMK racing streams map tiles
            // continuously) accelerates the paced VRAM resync below.
            if (tel_wt_drops_ != wtdrop_prev_) {
              const uint16_t d =
                  static_cast<uint16_t>(tel_wt_drops_ - wtdrop_prev_);
              if (d < 20000u) wtdrop_acc_ += d;
              wtdrop_prev_ = tel_wt_drops_;
            }
          }
        }
      } else {
        ProcessRecordPayload(fr.payload, static_cast<int>(fr.len));
      }
    }
    if (parser_.crc_bad() != crc_bad_seen_) {
      crc_bad_seen_ = parser_.crc_bad();
      pending_invalidate_ = true;  // a record payload may be lost
      // A lost payload can contain VRAM records — holes no line/sync
      // record can repair. Re-dump (unless one is already streaming;
      // its 0xFB covers the loss).
      if (!dump_requested_) dump_req_pending_ = true;
    }
    return got;
  }

  bool WaitStreamFrames(uint32_t need, uint32_t timeout_ms) {
    const uint64_t deadline =
        now_ns() + static_cast<uint64_t>(timeout_ms) * 1000000ull;
    while (frames_valid_ < need) {
      PumpStream();
      if (now_ns() >= deadline) return false;
      sleep_ns(2000000ull);
    }
    return true;
  }

  // Publishes one ctrl word with DUMP_REQ set (bumping ready_seq so the
  // FPGA adopts it). Cooldown-paced so a storm of triggers costs at most
  // one request per second. The FPGA consumes the bit only when idle.
  void MaybeRequestDump(uint64_t now) {
    if (!dump_capable_ || !dump_req_pending_) return;
    if (now - dump_req_last_ns_ < kDumpCooldownNs) return;
    dump_req_last_ns_     = now;
    dump_requested_at_ns_ = now;
    dump_req_pending_     = false;
    dump_requested_       = true;
    PublishCtrl(CtrlWord(++ready_seq_, cur_pub_, true));
    dump_clear_pending_ = true;
    dump_clear_at_ns_   = now + kDumpClearDelayNs;
    std::cout << "VRAM resync dump requested (ready_seq=" << ready_seq_
              << ")" << std::endl;
  }

  // Test card: one CLUT index byte per native pixel, 8-px diagonal bands
  // cycling through the full 256-entry palette — coarse enough that Mode 7
  // scaling distortion (shear/squeeze/row drops) is obvious at a glance,
  // and every band colour exercises a different CGRAM entry.
  void FillCard(uint32_t slot, uint32_t phase) {
    volatile uint8_t *buf = reinterpret_cast<volatile uint8_t *>(pix_[slot]);
    for (int y = 0; y < static_cast<int>(M7_LINE_COUNT); ++y) {
      volatile uint8_t *row = buf + y * M7_PIX_STRIDE;
      const uint8_t base = static_cast<uint8_t>(((y / 8) + phase) & 0xFF);
      for (int x = 0; x < static_cast<int>(M7_PIX_STRIDE); ++x) {
        row[x] = static_cast<uint8_t>(base + (x / 8));
      }
    }
    // Streaming a whole buffer evicts its lines naturally, but flush so the
    // card is visible to the FPGA deterministically before the first frame.
    CacheFlush(buf, static_cast<size_t>(M7_LINE_COUNT) * M7_PIX_STRIDE);
  }

  // ------------------------------------------------------------------
  // Per-line register record stream (P2c-2).
  //
  // Record payloads are a byte stream of len-prefixed records:
  //   [len][line][mask][lo hi]...   len includes itself
  //   mask bits: 0=A 1=B 2=C 3=D 4=X 5=Y 6=HOFS 7=VOFS
  // A record may straddle two payloads (or a telemetry payload); carry_
  // bridges the split. Line 0xFE is the per-frame full sync (mask=0xFF,
  // 8 values + M7SEL tail): it resets the delta chain on both sides. A
  // CRC-failed payload invalidates per-line values until the next sync.
  // ------------------------------------------------------------------
  // Longest record on the wire: a full dump chunk is [len][FD][al][ah]
  // + 240 data bytes = 244 (short tail 132 at the 32 KiB plane end).
  static const int kRecMax = 244;

  static uint16_t le16(const uint8_t *p) {
    return static_cast<uint16_t>(p[0] | (p[1] << 8));
  }

  static void SetChainField(M7Regs &r, int field, uint16_t v) {
    switch (field) {
      case 0: r.a = static_cast<int16_t>(v); break;
      case 1: r.b = static_cast<int16_t>(v); break;
      case 2: r.c = static_cast<int16_t>(v); break;
      case 3: r.d = static_cast<int16_t>(v); break;
      case 4: r.x = v & 0x1FFF; break;
      case 5: r.y = v & 0x1FFF; break;
      case 6: r.hofs = v & 0x1FFF; break;
      case 7: r.vofs = v & 0x1FFF; break;
      default: break;
    }
  }

  void ProcessRecordPayload(const uint8_t *p, int n) {
    for (int i = 0; i < n; ++i) {
      if (carry_len_ > 0) {
        // A pad 0x00 can only appear when the record stream is exhausted;
        // a lone pending len byte followed by pads means the record never
        // continued — drop it. (Mid-record pads are impossible: the FPGA
        // pads only when its record FIFO is fully drained.)
        if (carry_len_ == 1 && p[i] == 0x00) {
          carry_len_ = 0;
          continue;
        }
        carry_[carry_len_++] = p[i];
        if (carry_len_ >= carry_[0]) {
          ApplyRecord(carry_, carry_[0]);
          carry_len_ = 0;
        }
      } else {
        const int len = p[i];
        if (len < 3 || len > kRecMax) continue;  // padding / garbage byte
        carry_[0] = static_cast<uint8_t>(len);
        carry_len_ = 1;
      }
    }
  }

  void ApplyRecord(const uint8_t *r, int len) {
    const uint8_t line = r[1];
    const uint8_t mask = r[2];

    if (line == M7_RECVRAM_DUMP || line == M7_RECVRAM_WT) {
      ApplyVramRecord(r, len);
      return;
    }
    if (line == M7_RECVRAM_DONE) {
      // Dump finished: [5][FB][seq][wt_drops l h]. The image is complete
      // and the counter is re-baselined so drops that happened before the
      // dump don't retrigger drift forever.
      if (len == 5) {
        vram_valid_       = true;
        tel_wt_drops_     = le16(r + 3);
        dump_requested_   = false;
        fb_seq_seen_      = r[2];
        tel_seq_mismatch_ = 0;
        ++dumps_done_;
      }
      return;
    }
    if (line == 0xFF) return;  // reserved

    if (line == 0xFE) {
      // Full sync: [20][FE][FF][A B C D X Y H V][SEL]
      if (len < 20) return;
      if (shadow_synced_ && !pending_invalidate_) {
        FillShadowThrough(M7_LINE_COUNT);
        memcpy(completed_shadow_, shadow_, sizeof(shadow_));
        memcpy(completed_line_ok_, line_ok_, sizeof(line_ok_));
        completed_m7sel_ = m7sel_;
        completed_frame_ready_ = true;
      } else {
        completed_frame_ready_ = false;
      }
      chain_.a    = static_cast<int16_t>(le16(r + 3));
      chain_.b    = static_cast<int16_t>(le16(r + 5));
      chain_.c    = static_cast<int16_t>(le16(r + 7));
      chain_.d    = static_cast<int16_t>(le16(r + 9));
      chain_.x    = le16(r + 11) & 0x1FFF;
      chain_.y    = le16(r + 13) & 0x1FFF;
      chain_.hofs = le16(r + 15) & 0x1FFF;
      chain_.vofs = le16(r + 17) & 0x1FFF;
      m7sel_ = r[19];
      // snapshot this frame's record coverage, then re-arm the counters
      cov_lines_last_   = cov_lines_;
      cov_gap_last_     = cov_armed_ ? cov_gap_max_ : 0;
      cov_lines_        = 0;
      cov_gap_max_      = 0;
      cov_armed_        = false;
      cov_prev_line_    = -1;
      wt_recs_last_     = wt_recs_;
      wt_bytes_last_    = wt_bytes_;
      wt_recs_          = 0;
      wt_bytes_         = 0;
      if (pending_invalidate_) {
        pending_invalidate_ = false;
      }
      memset(line_ok_, 0, sizeof(line_ok_));
      next_shadow_line_ = 0;
      shadow_synced_ = true;
      ++syncs_;
      return;
    }

    if (!shadow_synced_) return;
    int off = 3;
    for (int f = 0; f < 8 && off + 1 < len; ++f) {
      if (mask & (1 << f)) {
        SetChainField(chain_, f, le16(r + off));
        off += 2;
      }
    }
    if (line < M7_LINE_COUNT) {
      FillShadowThrough(line);
      shadow_[line] = chain_;
      line_ok_[line] = true;
      // Per-frame coverage diagnostics: records arrive in ascending line
      // order within a frame, so a jump in the line number is a gap —
      // records dropped by the FPGA ring (band displacement on screen).
      // cov_lines_ counts records seen this frame; cov_gap_max_ the worst
      // consecutive-run of missing lines. Snapshot at the 0xFE sync.
      if (cov_armed_) {
        const int gap = static_cast<int>(line) - cov_prev_line_ - 1;
        if (gap > cov_gap_max_) cov_gap_max_ = gap;
      }
      cov_prev_line_ = line;
      cov_armed_     = true;
      ++cov_lines_;
      next_shadow_line_ = line + 1;
      ++rec_lines_;
    }
  }

  void FillShadowThrough(int line_exclusive) {
    const int end = line_exclusive < static_cast<int>(M7_LINE_COUNT)
                        ? line_exclusive
                        : static_cast<int>(M7_LINE_COUNT);
    while (next_shadow_line_ < end) {
      shadow_[next_shadow_line_] = chain_;
      line_ok_[next_shadow_line_] = true;
      ++next_shadow_line_;
    }
  }

  void ApplyVramRecord(const uint8_t *r, int len) {
    if (len < 5) return;
    const unsigned address = r[2] | (static_cast<unsigned>(r[3] & 0x7F) << 8);
    const unsigned plane = r[3] >> 7;
    const int data_len = len - 4;
    uint8_t *dst = plane ? loc_v2_ : loc_v1_;
    if (address + static_cast<unsigned>(data_len) > M7_VRAM_WORDS) return;
    for (int i = 0; i < data_len; ++i) dst[address + i] = r[4 + i];
    ++wt_recs_;
    wt_bytes_ += static_cast<uint32_t>(data_len);
  }

  bool testpat_ = getenv("M7_TESTPAT") != nullptr;

  void RenderFrame(uint32_t slot) {
    volatile uint8_t *buf = reinterpret_cast<volatile uint8_t *>(pix_[slot]);
    uint8_t rendered[M7_PIX_STRIDE];
    for (int y = 0; y < static_cast<int>(M7_LINE_COUNT); ++y) {
      volatile uint8_t *row = buf + y * M7_PIX_STRIDE;
      if (testpat_) {
        for (int x = 0; x < static_cast<int>(M7_PIX_STRIDE); ++x)
          row[x] = static_cast<uint8_t>(x ^ y);
      } else if (completed_line_ok_[y]) {
        m7::render_line(completed_shadow_[y], y, completed_m7sel_, extbg_,
                        loc_v1_, loc_v2_, rendered);
        for (int x = 0; x < static_cast<int>(M7_PIX_STRIDE); ++x)
          row[x] = rendered[x];
      } else {
        for (int x = 0; x < static_cast<int>(M7_PIX_STRIDE); ++x)
          row[x] = 0;
      }
    }
    // Clean the rendered frame to DDR3 so the FPGA's fetch never races L2
    // eviction (one syscall per frame; ~14k cache lines on the A9).
    CacheFlush(buf, static_cast<size_t>(M7_LINE_COUNT) * M7_PIX_STRIDE);
  }

  // SIGUSR1 debug capture: raw CLUT-index PGM of the last-published buffer,
  // plus a text sidecar (per-line reg shadow + VRAM health stats) — enough
  // to tell a stale-VRAM render from a stale-register one without guessing
  // at colors the FPGA's CGRAM adds at display time.
  void WriteDebugDump() {
    const int w = static_cast<int>(M7_PIX_STRIDE);
    const int h = static_cast<int>(M7_LINE_COUNT);
    {
      std::ofstream p("/tmp/m7_dbg.pgm", std::ios::binary);
      p << "P5\n" << w << " " << h << "\n255\n";
      p.write(const_cast<const char *>(
                  reinterpret_cast<const volatile char *>(pix_[cur_pub_])),
              static_cast<std::streamsize>(w) * h);
    }
    {
      std::ofstream t("/tmp/m7_dbg.txt");
      int ok = 0;
      for (int y = 0; y < h; ++y)
        if (completed_line_ok_[y]) ++ok;
      t << "cur_pub=" << cur_pub_ << " completed_ok=" << ok << "/" << h
        << " m7sel=0x" << std::hex << static_cast<int>(completed_m7sel_)
        << std::dec << " mode=" << static_cast<int>(tel_mode_)
        << " tel_len=" << last_tel_len_ << " tel[150..155]=" << std::hex
        << static_cast<int>(tel_150_[0]) << " "
        << static_cast<int>(tel_150_[1]) << " "
        << static_cast<int>(tel_150_[2]) << " "
        << static_cast<int>(tel_150_[3]) << " "
        << static_cast<int>(tel_150_[4]) << " "
        << static_cast<int>(tel_150_[5]) << std::dec
        << " extbg=" << extbg_ << " vram_valid=" << vram_valid_ << "\n";
      for (int y = 0; y < h; y += 16) {
        const M7Regs &r = completed_shadow_[y];
        t << "y=" << y << (completed_line_ok_[y] ? " ok  " : " BAD ")
          << " a=" << r.a << " b=" << r.b << " c=" << r.c << " d=" << r.d
          << " cx=" << r.x << " cy=" << r.y << " hofs=" << r.hofs
          << " vofs=" << r.vofs << "\n";
      }
      // Register-stream health: the pre-P2c-9 FPGA walk emitted every
      // payload byte doubled, so each corrupted 16-bit field read back as a
      // doubled-byte palindrome (0x3636, 0x4B4B, ...). Real register data is
      // almost never palindromic across a whole frame — a healthy stream
      // shows a handful of chance palindromes; the old bug showed all 1792.
      unsigned pal = 0, fld = 0;
      for (int y = 0; y < h; ++y) {
        const M7Regs &r = completed_shadow_[y];
        const uint16_t vs[8] = {
            static_cast<uint16_t>(r.a), static_cast<uint16_t>(r.b),
            static_cast<uint16_t>(r.c), static_cast<uint16_t>(r.d),
            r.x, r.y, r.hofs, r.vofs};
        for (int f = 0; f < 8; ++f) {
          ++fld;
          if ((vs[f] >> 8) == (vs[f] & 0xFF)) ++pal;
        }
      }
      t << "palindrome fields: " << pal << "/" << fld << "\n";
      // Tilemap health: the Mode 7 map is plane-1 words 0x0000..0x3FFF (see
      // the layout note in m7_mode7_renderer.h). A live SMK map has hundreds
      // of distinct tile indices; a stale/zeroed image collapses to one or
      // two values — that split decides the diagnosis.
      uint32_t hist[256] = {};
      for (unsigned i = 0; i < 16384u; ++i) ++hist[loc_v1_[i]];
      unsigned distinct = 0, nonzero = 0;
      for (int v = 1; v < 256; ++v)
        if (hist[v]) {
          ++distinct;
          nonzero += hist[v];
        }
      t << "tilemap: distinct=" << distinct << " nonzero=" << nonzero
        << "/16384 tile0=" << hist[0] << "\ntileset[0..15]:";
      for (unsigned i = 0; i < 16; ++i)
        t << " " << std::hex << static_cast<int>(loc_v2_[i]) << std::dec;
      t << "\n";
    }
    std::cout << "debug dump written to /tmp/m7_dbg.pgm + /tmp/m7_dbg.txt"
              << std::endl;
  }

  bool WaitFrameSeqChange(uint32_t timeout_ms) {
    const uint16_t start = hdr_[M7_HDR_FRAME_SEQ];
    const uint64_t deadline = now_ns() + static_cast<uint64_t>(timeout_ms) * 1000000ull;
    for (;;) {
      if (hdr_[M7_HDR_FRAME_SEQ] != start) return true;
      if (now_ns() >= deadline) return false;
      sleep_ns(1000000ull);  // 1 ms poll
    }
  }

  bool extbg_;
  int mem_fd_ = -1;
  int wc_fd_ = -1;
  int stream_fd_ = -1;
  volatile uint8_t *map_ = nullptr;
  volatile uint8_t *wc_map_ = nullptr;
  volatile uint16_t *hdr_;
  volatile uint16_t *regs_;
  volatile uint32_t *ctrl_;
  volatile uint16_t *pix_[2];
  uint8_t loc_v1_[M7_VRAM_WORDS] = {};
  uint8_t loc_v2_[M7_VRAM_WORDS] = {};
  uint16_t ready_seq_ = 0;
  uint32_t cur_pub_ = 0;   // buffer the last ctrl word points at

  // UART stream state (FPGA -> ARM, rtl/m7_reg_stream.sv framing)
  M7UartParser parser_;
  uint32_t frames_valid_ = 0;
  uint32_t slips_ = 0;
  uint16_t last_seq_ = 0;
  uint16_t expect_seq_ = 0;
  bool have_seq_ = false;

  // Per-line register shadow (P2c-2): chain_ mirrors the FPGA's delta
  // reference, shadow_[line] is the last known value for that display line.
  M7Regs chain_ = {};
  M7Regs shadow_[M7_LINE_COUNT] = {};
  M7Regs completed_shadow_[M7_LINE_COUNT] = {};
  bool line_ok_[M7_LINE_COUNT] = {};
  bool completed_line_ok_[M7_LINE_COUNT] = {};
  int next_shadow_line_ = 0;
  bool shadow_synced_ = false;
  bool completed_frame_ready_ = false;
  bool pending_invalidate_ = false;
  uint8_t carry_[kRecMax] = {};
  int carry_len_ = 0;
  uint8_t m7sel_ = 0;
  uint8_t completed_m7sel_ = 0;
  bool vram_valid_ = false;
  uint8_t tel_drops_ = 0;

  // VRAM resync dump lifecycle (P2c-3). dump_capable_ comes from the
  // telemetry probe (byte 132 == 0xAA on pre-P2c-3 bitstreams); requests
  // are cooldown-paced, stall-detected, and re-baselined by the 0xFB
  // completion record.
  static const uint64_t kDumpCooldownNs = 1000000000ull;  // between requests
  // Paced full-resync cadence. A dump consumes only the line stream's
  // slack (~2-6 s for both planes at the measured yield), so a 5 s
  // interval keeps the daemon's VRAM image within ~one dump of live even
  // for games that stream tiles continuously.
  static const uint64_t kResyncIntervalNs = 5000000000ull;
  static const uint32_t kHeavyStreamWt = 12000;  // wt drops/window that halves
                                                 // the resync interval

  // Paced resync interval: 5 s normally, 2.5 s while VRAM streaming is
  // heavy (the wt channel physically cannot keep up with games that
  // stream map tiles every frame — racing on SMK sheds ~2-3k drops/s).
  uint64_t ResyncInterval() const {
    return wtdrop_acc_ > kHeavyStreamWt ? kResyncIntervalNs / 2
                                        : kResyncIntervalNs;
  }
  uint32_t wtdrop_acc_  = 0;  // wt drops this status window
  uint16_t wtdrop_prev_ = 0;  // last cumulative wt-drops sample
  uint64_t last_render_ns_ = 0;
  uint64_t last_resync_ns_ = 0;
  // Re-request backstop. Since the P2c-4 yield cap a dump consumes only the
  // line stream's slack (~50 kB/s measured on device), so a full 2x32 KiB
  // dump legitimately takes 2-6 s — the old 3 s timeout fired mid-dump and
  // chained a follow-on request out of every dump, a storm all by itself.
  static const uint64_t kDumpTimeoutNs  = 10000000000ull;
  // Request -> clear-word spacing. Must exceed one FPGA ctrl poll period
  // (~16 ms at 60 fps) so the request word is always adopted before the
  // clear word overwrites it; short enough that the re-arm lands well
  // before the ~0.3 s dump completes and the next request is due.
  static const uint64_t kDumpClearDelayNs = 200000000ull;
  bool dump_clear_pending_ = false;
  uint64_t dump_clear_at_ns_ = 0;
  bool dump_capable_     = false;
  bool tel_probe_done_   = false;
  bool dump_req_pending_ = false;  // want to publish a request
  bool dump_requested_   = false;  // request published, awaiting 0xFB
  uint64_t dump_req_last_ns_     = 0;
  uint64_t dump_requested_at_ns_ = 0;
  uint8_t  tel_dump_seq_  = 0;
  uint8_t  tel_dm_        = 0;
  uint16_t tel_rd_        = 0;
  uint16_t tel_bc_        = 0;
  uint16_t tel_bw_        = 0;
  uint16_t tel_rcnt_      = 0;
  uint16_t tel_drops16_   = 0;
  uint16_t tel_retry_     = 0;
  uint16_t tel_arm_       = 0;
  uint8_t  tel_disp_row_  = 0;
  uint8_t  tel_lri_       = 0;
  uint8_t  tel_rows_[28]  = {};  // sticky row_done[223:0], rows 0..223
  uint32_t drt_acc_       = 0;   // fetch words across the telemetry window
  uint16_t drt_prev_      = 0;   // last cumulative drt_cnt sample
  uint32_t drt_frames_    = 0;   // SNES frames in the telemetry window
  uint32_t drt_sync_mark_ = 0;   // syncs_ at last telemetry frame
  uint16_t tel_hde_       = 0;   // hde falls last frame (edge-detector check)
  uint16_t tel_ppuy_      = 0;   // ppu_y at the telemetry sample instant
  uint16_t tel_ars_       = 0;   // FPGA last_ready_seq at the sample instant
  uint8_t  tel_mode_      = 7;   // PPU BGMODE low bits (0xAA filler => keep 7)
  uint8_t  prev_tel_mode_ = 7;   // previous sample, for the ->7 transition dump
  uint8_t  prev_mode_raw_ = 0xAA;  // last frame's raw byte 152 (agree check)
  uint8_t  mode_agree_    = 0;     // consecutive agreeing frames
  uint16_t last_tel_len_  = 0;   // debug: len of the last mode-updating frame
  uint8_t  tel_150_[6]    = {};  // debug: raw payload[150..155] of that frame

  // Compact hex of a byte range for the status line (no separators).
  static std::string RowsHex(const uint8_t *b, int from, int to) {
    std::ostringstream os;
    for (int i = from; i < to; ++i) {
      os.width(2);
      os.fill('0');
      os << std::hex << static_cast<int>(b[i]);
    }
    return os.str();
  }
  uint16_t tel_vram1_ver_ = 0;
  uint16_t tel_vram2_ver_ = 0;
  uint16_t tel_wt_drops_  = 0;
  uint32_t dumps_done_    = 0;
  // per-frame record coverage + wt throughput (snapshot at each 0xFE sync)
  int      cov_lines_ = 0, cov_gap_max_ = 0;
  int      cov_prev_line_ = -1;
  bool     cov_armed_ = false;
  int      cov_lines_last_ = 0, cov_gap_last_ = 0;
  uint32_t wt_recs_ = 0, wt_bytes_ = 0;
  uint32_t wt_recs_last_ = 0, wt_bytes_last_ = 0;
  // 0xFB-loss watchdog v2: fb_seq_seen_ is the last dump_seq confirmed by a
  // completion record. fb ADVANCING between telemetry slots resets the
  // mismatch counter — records are flowing, whatever the tel/fb spacing
  // (under continuous re-dumping tel legitimately sits one dump ahead
  // indefinitely). The alarm counts only while fb is FROZEN and tel runs
  // ahead with no dump outstanding. The grace must exceed the WORST
  // legitimate FB lag, not the average: the 0xFB trails its own dump's
  // ~274 chunk records, and since the P2c-4 yield cap a dump consumes
  // only the line stream's slack (~30 kB/s), stretching to ~2 s — while a
  // dump is outstanding dump_requested_ gates the counter off, so the
  // alarm only sees the gap AFTER a dump where no new request exists:
  // frozen fb then means the request was swallowed (wedged FSM) or the
  // record truly lost. Telemetry slots arrive at ~17/s (1-in-64 payloads,
  // ~1100 payloads/s — P2c-4 cadence, matched to the RTL), so 40 slots
  // ≈ 2.3 s. The 3 s stall timeout covers the rest.
  static const int kFbMissTelSamples = 40;
  uint8_t fb_seq_seen_      = 0;
  uint8_t fb_seq_prev_      = 0;
  uint8_t tel_seq_mismatch_ = 0;
  uint32_t crc_bad_seen_ = 0;
  uint32_t syncs_ = 0;
  uint32_t rec_lines_ = 0;
};

int main(int argc, char *argv[]) {
  bool extbg = false;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--extbg") extbg = true;
  }

  M7Daemon daemon(extbg);
  const int init_rc = daemon.Init();
  if (init_rc != 0) return init_rc;
  daemon.Run();
  return 0;
}
