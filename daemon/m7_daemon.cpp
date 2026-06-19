// Expose nanosleep / clock_gettime under g++ -std=c++11 on glibc (MiSTer).
// macOS gets these via _DARWIN_C_SOURCE automatically, so only define on Linux.
#if defined(__linux__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 199309L
#endif

#include <cstdint>
#include <ctime>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <sched.h>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

// ===========================================================================
// Phase C: True HD Mode 7 ARM C++ Daemon
//
// Communicates with the FPGA over a shared DDR3 memory window:
//
//   0x3E000000  M7 register mailbox (8 × 16-bit, written by FPGA per frame)
//   0x3E001000  HD pixel buffer      (daemon writes, FPGA DMA reads)
//   0x3E100000  VRAM1 mirror         (32K × 16-bit, written by FPGA per frame)
//   0x3E108000  VRAM2 mirror         (32K × 16-bit, written by FPGA per frame)
//   0x3E110000  CGRAM mirror         (256 × 16-bit, written by FPGA per frame)
//
// Each frame the daemon:
//   1. Reads the Mode 7 affine registers from the mailbox.
//   2. Reads VRAM1/VRAM2/CGRAM mirrors (refreshed by the FPGA every frame).
//   3. Renders 4×-resolution Mode 7 scanlines with real tile lookups and
//      palette conversion, including EXTBG compositing.
//   4. Writes the HD pixels into the pixel buffer for the FPGA DMA reader.
// ===========================================================================

#define DDR3_PHYS_BASE 0x3E000000
#define DDR3_SPAN      0x01000000   // 16 MB window

#define SNES_WIDTH     256
#define SNES_HEIGHT    224

// Offsets from DDR3_PHYS_BASE to each region (must match the FPGA localparams).
#define OFFS_MAILBOX   0x000000
#define OFFS_PIXELS    0x002000
#define OFFS_VRAM1     0x100000
#define OFFS_VRAM2     0x108000
#define OFFS_CGRAM     0x110000

struct M7Regs {
  int16_t a, b, c, d;
  int16_t x, y;
  int16_t hofs, vofs;
};

class M7Daemon {
private:
  int mem_fd;
  void *virtual_base;
  uint32_t       *hd_pixel_buffer;  // 32-bit view (DMA reads 64-bit chunks)
  volatile uint16_t *mailbox_regs;
  const uint16_t *vram1_mirror;   // 32K entries, each = one VRAM byte (low 8 bits)
  const uint16_t *vram2_mirror;
  const uint16_t *cgram_mirror;   // 256 entries, 15-bit BGR555

  int scale_multiplier;
  int hd_width;

  int determine_snes_multiplier() {
    std::ifstream ini_file("/media/fat/MiSTer.ini");
    int target_height = 1080;
    if (ini_file.is_open()) {
      std::string line;
      while (std::getline(ini_file, line)) {
        if (line.empty() || line[0] == ';' || line[0] == '#') continue;
        if (line.find("video_mode") == 0) {
          if      (line.find("1440") != std::string::npos) target_height = 1440;
          else if (line.find("1080") != std::string::npos) target_height = 1080;
          else if (line.find("720")  != std::string::npos) target_height = 720;
          else if (line.find("480")  != std::string::npos) target_height = 480;
        }
      }
      ini_file.close();
    }
    std::cout << "Detected Target Height: " << target_height << "p" << std::endl;
    if (target_height >= 1344) return 6;
    if (target_height >= 896)  return 4;
    if (target_height >= 672)  return 3;
    if (target_height >= 448)  return 2;
    return 1;
  }

public:
  M7Daemon() {
    mem_fd = open("/dev/mem", (O_RDWR | O_SYNC));
    if (mem_fd == -1) { std::cerr << "ERROR: could not open /dev/mem" << std::endl; exit(1); }

    virtual_base = mmap(NULL, DDR3_SPAN, (PROT_READ | PROT_WRITE), MAP_SHARED,
                        mem_fd, DDR3_PHYS_BASE);
    if (virtual_base == MAP_FAILED) {
      std::cerr << "ERROR: mmap failed" << std::endl; close(mem_fd); exit(1);
    }

    uint8_t *base = (uint8_t *)virtual_base;
    mailbox_regs    = (volatile uint16_t *)(base + OFFS_MAILBOX);
    hd_pixel_buffer = (uint32_t *)(base + OFFS_PIXELS);
    vram1_mirror    = (const uint16_t *)(base + OFFS_VRAM1);
    vram2_mirror    = (const uint16_t *)(base + OFFS_VRAM2);
    cgram_mirror    = (const uint16_t *)(base + OFFS_CGRAM);

    scale_multiplier = determine_snes_multiplier();
    hd_width = SNES_WIDTH * scale_multiplier;

    // Dynamic scale isn't wired to the FPGA yet (CMD_M7_SET_SCALE TODO).
    // The FPGA defaults to 4×, so force 4× here to match.
    if (scale_multiplier != 4) {
      std::cerr << "WARNING: forcing 4× (FPGA default). Dynamic scale TODO." << std::endl;
      scale_multiplier = 4;
      hd_width = SNES_WIDTH * scale_multiplier;
    }
    std::cout << "M7 Multiplier: " << scale_multiplier << "× (width " << hd_width << ")" << std::endl;
  }

  ~M7Daemon() {
    if (virtual_base != MAP_FAILED) munmap(virtual_base, DDR3_SPAN);
    close(mem_fd);
  }

  // Read the 8 Mode 7 registers for a specific scanline from the per-line
  // mailbox. The FPGA captures these at each start_of_scanline so HDMA
  // changes (e.g. SMK's per-line perspective) are reflected correctly.
  M7Regs read_m7_registers(int scanline) {
    const int offset = scanline * 8;
    M7Regs r;
    r.a    = static_cast<int16_t>(mailbox_regs[offset + 0]);
    r.b    = static_cast<int16_t>(mailbox_regs[offset + 1]);
    r.c    = static_cast<int16_t>(mailbox_regs[offset + 2]);
    r.d    = static_cast<int16_t>(mailbox_regs[offset + 3]);
    r.x    = static_cast<int16_t>(mailbox_regs[offset + 4]);
    r.y    = static_cast<int16_t>(mailbox_regs[offset + 5]);
    r.hofs = static_cast<int16_t>(mailbox_regs[offset + 6]);
    r.vofs = static_cast<int16_t>(mailbox_regs[offset + 7]);
    return r;
  }

  // Convert SNES BGR555 (CGRAM) → RGB565 (wire format the FPGA expects).
  static inline uint16_t bgr555_to_rgb565(uint16_t bgr) {
    bgr &= 0x7FFF;
    uint16_t r = bgr & 0x1F;
    uint16_t g = (bgr >> 5) & 0x1F;
    uint16_t b = (bgr >> 10) & 0x1F;
    // Expand green 5→6 bits (replicate top bit into LSB).
    uint16_t g6 = (g << 1) | (g >> 4);
    return (r << 11) | (g6 << 5) | b;
  }

  // Mode7Clip: replicate the fix from upstream commit 586644c
  // ("PPU: fix Mode7 calculation — Tiny Toon Adventures Wacky Sports Challenge").
  //
  // The FPGA's ORG_X/ORG_Y are 14-bit signed (M7HOFS-M7X / M7VOFS-M7Y).
  // Before the affine multiply, the PPU passes them through Mode7Clip which
  // truncates to bits [9:0] and sign-extends from bit [13]. Without this,
  // games that use large HOFS/VOFS offsets render the wrong part of the map.
  //
  // VHDL: res := a(13) & a(9 downto 0);  -- 11-bit signed
  static inline int mode7_clip(int val) {
    int a14 = val & 0x3FFF;            // truncate to 14 bits
    int lower10 = a14 & 0x3FF;         // bits [9:0]
    if (a14 & 0x2000) lower10 -= 0x400; // sign-extend from bit 13
    return lower10;
  }

  std::vector<uint16_t> render_hd_scanline(const M7Regs &regs, int scanline) {
    std::vector<uint16_t> pixels(hd_width, 0);

    // Screen-space Y.
    int y_screen = scanline;

    for (int x_screen = 0; x_screen < hd_width; ++x_screen) {
      // Map HD x back to native SNES x for the affine input.
      int native_x = x_screen / scale_multiplier;
      int cx = native_x + regs.hofs - regs.x;
      int cy = y_screen + regs.vofs - regs.y;

      // Apply Mode7Clip before the affine multiply (upstream 586644c fix).
      int cx_clip = mode7_clip(cx);
      int cy_clip = mode7_clip(cy);

      // Affine transform (signed 32-bit math, >>8 matches the SNES hardware).
      int32_t tx = (int32_t)regs.a * cx_clip + (int32_t)regs.b * cy_clip;
      int32_t ty = (int32_t)regs.c * cx_clip + (int32_t)regs.d * cy_clip;
      int32_t map_x = (tx >> 8) + regs.x;
      int32_t map_y = (ty >> 8) + regs.y;

      // Wrap to 1024×1024 pixel space (128×128 tiles). This matches the
      // SNES M7SEL repeat behaviour, which is what SMK uses.
      int wx = map_x & 0x3FF;
      int wy = map_y & 0x3FF;

      // --- Tilemap lookup -----------------------------------------------
      // tilemap word address = {tile_y[6:0], tile_x[6:0]} (14-bit)
      int tile_x = (wx >> 3) & 0x7F;
      int tile_y = (wy >> 3) & 0x7F;
      int tilemap_addr = (tile_y << 7) | tile_x;
      uint8_t tile_number = vram1_mirror[tilemap_addr] & 0xFF;

      // --- Tile pixel lookup --------------------------------------------
      // byte address = {tile_number[7:0], row[2:0], col[2:0]} (14-bit)
      int col = wx & 7;
      int row = wy & 7;
      int tile_addr = (tile_number << 6) | (row << 3) | col;
      uint8_t bg1_index = vram1_mirror[tile_addr] & 0xFF;

      // --- EXTBG (BG2) layer --------------------------------------------
      // VRAM2 high byte: bit 7 = priority, bits 6-0 = color index (into
      // CGRAM at offset +128). Only meaningful when the game enables BG2
      // in Mode 7, but rendering it unconditionally is harmless.
      uint8_t extbg_byte = vram2_mirror[tile_addr] & 0xFF;
      bool    extbg_pri  = extbg_byte & 0x80;
      uint8_t extbg_idx  = extbg_byte & 0x7F;

      // --- Compositing ---------------------------------------------------
      // Standard SNES BG priority logic:
      //   BG2 wins if it is opaque AND (it has priority OR BG1 is transparent)
      uint16_t rgb565;
      if (extbg_idx != 0 && (extbg_pri || bg1_index == 0)) {
        rgb565 = bgr555_to_rgb565(cgram_mirror[128 + extbg_idx]);
      } else {
        rgb565 = bgr555_to_rgb565(cgram_mirror[bg1_index]);
      }

      pixels[x_screen] = rgb565;
    }
    return pixels;
  }

  void write_m7_pixels(const std::vector<uint16_t> &hd_pixels, int scanline) {
    // Pack pixels as consecutive 16-bit RGB565 values. The FPGA DMA
    // reader extracts 4 pixels per 64-bit DDR3 read (C.4 optimization).
    uint16_t *buf = reinterpret_cast<uint16_t *>(hd_pixel_buffer);
    int pixel_offset = scanline * hd_width;
    for (int i = 0; i < hd_width; ++i)
      buf[pixel_offset + i] = hd_pixels[i];
  }

  void run() {
    std::cout << "Starting HD Mode 7 Daemon Main Loop..." << std::endl;

    const long FRAME_NS = 1000000000L / 60; // ~16.67 ms

    while (true) {
      struct timespec t0, t1;
      clock_gettime(CLOCK_MONOTONIC, &t0);

      // Read per-line registers for each scanline so HDMA changes
      // (SMK perspective, etc.) are captured correctly.
      for (int scanline = 0; scanline < SNES_HEIGHT; ++scanline) {
        M7Regs regs = read_m7_registers(scanline);
        std::vector<uint16_t> hd_pixels = render_hd_scanline(regs, scanline);
        write_m7_pixels(hd_pixels, scanline);
      }

      // Pace to ~60 Hz so we don't starve the ARM.
      clock_gettime(CLOCK_MONOTONIC, &t1);
      long elapsed_ns = (t1.tv_sec - t0.tv_sec) * 1000000000L + (t1.tv_nsec - t0.tv_nsec);
      long sleep_ns = FRAME_NS - elapsed_ns;
      if (sleep_ns > 1000000L) {
        struct timespec rem = {0, sleep_ns};
        nanosleep(&rem, nullptr);
      } else {
        sched_yield();
      }
    }
  }
};

int main(int argc, char *argv[]) {
  M7Daemon daemon;
  daemon.run();
  return 0;
}
