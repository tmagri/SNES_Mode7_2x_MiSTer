// Expose nanosleep / clock_gettime under g++ -std=c++11 on glibc (MiSTer);
// _DEFAULT_SOURCE also pulls in the extended baud constants (B3000000).
// macOS gets these via _DARWIN_C_SOURCE automatically, so only define on Linux.
#if defined(__linux__) && !defined(_DEFAULT_SOURCE)
#define _DEFAULT_SOURCE 1
#endif

#include "m7_abi.h"
#include "m7_uart_parser.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <iostream>
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
// The real Mode 7 renderer below stays for P2c (it consumes the per-line
// register stream that lands on the same framing).
//
// Exit codes: 1 = /dev/mem or mmap failure, 2 = ttyS1 open/config failure,
// 3 = no valid UART stream (wrong/absent bitstream).
// ===========================================================================

namespace {

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

// Convert SNES BGR555 (CGRAM) -> RGB565 (the pixel format the FPGA expects).
inline uint16_t bgr555_to_rgb565(uint16_t bgr) {
  bgr &= 0x7FFF;
  const uint16_t r = bgr & 0x1F;
  const uint16_t g = (bgr >> 5) & 0x1F;
  const uint16_t b = (bgr >> 10) & 0x1F;
  const uint16_t g6 = (g << 1) | (g >> 4);  // expand green 5 -> 6 bits
  return (r << 11) | (g6 << 5) | b;
}

// Mode7Clip, matching PPU.vhd: res := a(13) & a(9 downto 0) sign-extended
// from bit 13 (upstream fix 586644c). Applied to (HOFS-M7X)/(VOFS-M7Y)
// before the affine multiply.
inline int mode7_clip(int val) {
  const int a14 = val & 0x3FFF;
  int lower10 = a14 & 0x3FF;
  if (a14 & 0x2000) lower10 -= 0x400;
  return lower10;
}

struct M7Regs {
  int16_t a, b, c, d;
  uint16_t x, y, hofs, vofs;  // 13-bit unsigned SNES register values
};

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
    vr1_ = reinterpret_cast<volatile uint16_t *>(map_ + (M7_VRAM1_BASE - M7_MAILBOX_BASE));
    vr2_ = reinterpret_cast<volatile uint16_t *>(map_ + (M7_VRAM2_BASE - M7_MAILBOX_BASE));
    cg_  = reinterpret_cast<volatile uint16_t *>(map_ + (M7_CGRAM_BASE - M7_MAILBOX_BASE));

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

  void Run() {
    std::cout << "P2c-1 test-card mode (8bpp CLUT indices)" << std::endl;

    // Fill both buffers with the static card, publish buffer 0. With
    // M7_STATIC the card never changes and the FPGA fetch loop reads the
    // same buffer forever (display-path proof). Otherwise each tick fills
    // the INACTIVE buffer and flips READY_BUF — the FPGA adopts whole
    // frames, so a repaint can never tear mid-frame.
    FillCard(0, 0);
    FillCard(1, 0);
    cur_pub_ = 0;
    ready_seq_ = 1;
    *ctrl_ = CtrlWord(ready_seq_, cur_pub_);
    std::cout << "ctrl published (ready_seq=1, READY_BUF=0, FMT8) — FPGA "
                 "should start fetching" << std::endl;

    uint64_t anim_last = 0;
    uint64_t log_last  = now_ns();
    uint32_t phase = 0;
    uint32_t log_mark = 0;

    while (true) {
      const uint32_t got = PumpStream();

      const uint64_t now = now_ns();
      if (now - log_last >= 5000000000ull) {
        log_last = now;
        std::cout << "stream: " << frames_valid_ << " valid frames ("
                  << (frames_valid_ - log_mark) / 5 << "/s), "
                  << parser_.resyncs() << " resyncs, "
                  << parser_.crc_bad() << " crc_bad" << std::endl;
        log_mark = frames_valid_;
      }
      if (got == 0) sleep_ns(20000000ull);  // nothing pending: 20 ms idle

      // M7_STATIC=1 freezes the card after the initial fill.
      if (!static_card_ && now - anim_last >= 200000000ull) {  // ~5 fps flip
        anim_last = now;
        phase = (phase + 1) & 0x1Fu;
        cur_pub_ ^= 1u;
        FillCard(cur_pub_, phase);
        *ctrl_ = CtrlWord(++ready_seq_, cur_pub_);
      }
    }
  }

 private:
  // Ctrl word v2: ready_seq | buffer << 16 | FMT8 (bit 17, required).
  static uint32_t CtrlWord(uint32_t seq, uint32_t buf) {
    return (seq & 0xFFFFu) | (buf << M7_CTRL_READY_BUF) |
           (1u << M7_CTRL_FMT8);
  }


 private:
  // M7_STATIC=1 freezes the card after the initial fill (display-path proof)
  const bool static_card_ = std::getenv("M7_STATIC") != nullptr;

  // 256 native pixels x M7_HD_SCALE (one HD scanline, RGB565)
  static const int HD_PIXELS_PER_LINE = 256 * static_cast<int>(M7_HD_SCALE);

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

  // Drains whatever the UART has into the parser; returns how many new
  // CRC-valid frames came out, and tracks sequence continuity.
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

  static void CopyPlane(volatile uint16_t *src, uint16_t *dst) {
    for (uint32_t i = 0; i < M7_VRAM_WORDS; ++i) dst[i] = src[i];
  }

  // SNES VRAM is stored as two byte planes written by $2118/$2119 at the
  // same word address: byte 2*w lives in plane 1, byte 2*w+1 in plane 2.
  inline uint8_t VramByte(uint32_t word_addr, bool odd) const {
    return odd ? static_cast<uint8_t>(loc_v2_[word_addr])
               : static_cast<uint8_t>(loc_v1_[word_addr]);
  }

  void RenderLine(const M7Regs &r, int line, uint16_t *out) {
    // Screen-space origin terms (pre-clip), then the affine transform.
    const int cy_in = line + r.vofs - r.y;
    const int cy_clip = mode7_clip(cy_in);
    for (int x = 0; x < HD_PIXELS_PER_LINE; ++x) {
      const int cx_in = (x / M7_HD_SCALE) + r.hofs - r.x;
      const int cx_clip = mode7_clip(cx_in);

      const int32_t tx = static_cast<int32_t>(r.a) * cx_clip +
                         static_cast<int32_t>(r.b) * cy_clip;
      const int32_t ty = static_cast<int32_t>(r.c) * cx_clip +
                         static_cast<int32_t>(r.d) * cy_clip;
      int map_x = (tx >> 8) + r.x;
      int map_y = (ty >> 8) + r.y;

      // Wrap into the 1024x1024 Mode 7 map/tile space (128x128 tiles).
      const int wx = map_x & 0x3FF;
      const int wy = map_y & 0x3FF;

      // Tilemap entry: word address {tile_y[6:0], tile_x[6:0]}; the tile
      // number is the entry's LOW byte, i.e. plane 1 at word w.
      const uint32_t map_w = static_cast<uint32_t>((wy >> 3) * 128 + (wx >> 3));
      const uint8_t tile = static_cast<uint8_t>(loc_v1_[map_w]);

      // Tile pixel: word 0x2000 + tile*32 + row*4 + col/2; the byte is in
      // plane 1 for even columns, plane 2 for odd columns.
      const int col = wx & 7;
      const int row = wy & 7;
      const uint32_t tw =
          0x2000u + tile * 32u + static_cast<uint32_t>(row) * 4u +
          static_cast<uint32_t>(col >> 1);
      const uint8_t px = VramByte(tw, col & 1);

      if (extbg_) {
        // EXTBG: the same pixel byte feeds both layers — bits 6:0 are the
        // BG2 color index (palette +128) and bit 7 its priority; BG1 keeps
        // the full 8-bit index.
        const uint8_t bg2_idx = px & 0x7F;
        const bool bg2_pri = px & 0x80;
        if (bg2_idx != 0 && (bg2_pri || px == 0))
          out[x] = bgr555_to_rgb565(loc_cg_[128 + bg2_idx]);
        else
          out[x] = bgr555_to_rgb565(loc_cg_[px]);
      } else {
        out[x] = bgr555_to_rgb565(loc_cg_[px]);
      }
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
  volatile uint16_t *vr1_;
  volatile uint16_t *vr2_;
  volatile uint16_t *cg_;

  uint16_t loc_v1_[M7_VRAM_WORDS];
  uint16_t loc_v2_[M7_VRAM_WORDS];
  uint16_t loc_cg_[256];
  uint16_t line_px_[HD_PIXELS_PER_LINE];
  uint16_t ready_seq_ = 0;
  uint32_t cur_pub_ = 0;   // buffer the last ctrl word points at

  // UART stream state (FPGA -> ARM, rtl/m7_reg_stream.sv framing)
  M7UartParser parser_;
  uint32_t frames_valid_ = 0;
  uint32_t slips_ = 0;
  uint16_t last_seq_ = 0;
  uint16_t expect_seq_ = 0;
  bool have_seq_ = false;
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
