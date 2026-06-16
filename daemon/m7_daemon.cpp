#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

// ===========================================================================
// Phase 3: True HD Mode 7 ARM C++ Daemon
//
// This daemon memory-maps the HPS-to-FPGA Lightweight bridge to communicate
// with the sys_top ioctl / hps_ext mechanism.
//
// *Note*: In a full MiSTer environment, this logic is often integrated directly
// into Main_MiSTer's user_io.cpp to share the SPI command lock. For this
// standalone daemon, we assume exclusive access to the hps_ext bridge.
// ===========================================================================

#define HW_REGS_BASE (0xFF200000)
#define HW_REGS_SPAN (0x00200000)
#define HW_REGS_MASK (HW_REGS_SPAN - 1)

// Hypothetical offset for the user_io / hps_ext command register on the bridge
#define HPS_EXT_BASE_OFFSET 0x00000

// hps_ext commands from Phase 2
#define CMD_M7_READ 0x36
#define CMD_M7_WRITE_PIXELS 0x37

// SNES screen dimensions
#define SNES_WIDTH 256
#define SNES_HEIGHT 224

// HD Mode 7 multipliers (2x width for 512px line buffer)
#define HD_WIDTH (SNES_WIDTH * 2)

struct M7Regs {
  int16_t a, b, c, d;
  int16_t x, y;
  int16_t hofs, vofs;
};

class M7Daemon {
private:
  int mem_fd;
  void *virtual_base;
  volatile uint16_t *hps_ext_ptr;

  // VRAM copy (requires separate integration to sync with FPGA WRAM/VRAM
  // snooping)
  std::vector<uint8_t> snes_vram;

public:
  M7Daemon() {
    mem_fd = open("/dev/mem", (O_RDWR | O_SYNC));
    if (mem_fd == -1) {
      std::cerr << "ERROR: could not open /dev/mem" << std::endl;
      exit(1);
    }

    virtual_base = mmap(NULL, HW_REGS_SPAN, (PROT_READ | PROT_WRITE),
                        MAP_SHARED, mem_fd, HW_REGS_BASE);
    if (virtual_base == MAP_FAILED) {
      std::cerr << "ERROR: mmap failed" << std::endl;
      close(mem_fd);
      exit(1);
    }

    hps_ext_ptr =
        (volatile uint16_t *)((uint8_t *)virtual_base + HPS_EXT_BASE_OFFSET);
    snes_vram.resize(64 * 1024, 0); // 64KB SNES VRAM placeholder
  }

  ~M7Daemon() {
    if (virtual_base != MAP_FAILED) {
      munmap(virtual_base, HW_REGS_SPAN);
    }
    close(mem_fd);
  }

  // Task 3.1: Read Matrix A, B, C, D and X, Y, HOFS, VOFS
  M7Regs read_m7_registers() {
    M7Regs regs;

    // Write CMD_M7_READ to initiate the read sequence
    *hps_ext_ptr = CMD_M7_READ;

    // Read the 8 consecutive 16-bit words returned by hps_ext.v
    regs.a = *hps_ext_ptr;
    regs.b = *hps_ext_ptr;
    regs.c = *hps_ext_ptr;
    regs.d = *hps_ext_ptr;
    regs.x = *hps_ext_ptr & 0x1FFF; // 13-bit
    regs.y = *hps_ext_ptr & 0x1FFF;
    regs.hofs = *hps_ext_ptr & 0x1FFF;
    regs.vofs = *hps_ext_ptr & 0x1FFF;

    // Sign extend 13-bit registers to 16-bit
    if (regs.x & 0x1000)
      regs.x |= 0xE000;
    if (regs.y & 0x1000)
      regs.y |= 0xE000;
    if (regs.hofs & 0x1000)
      regs.hofs |= 0xE000;
    if (regs.vofs & 0x1000)
      regs.vofs |= 0xE000;

    return regs;
  }

  // Task 3.3: Burst-write the generated pixel array to the FPGA
  void write_m7_pixels(const std::vector<uint16_t> &hd_pixels) {
    *hps_ext_ptr = CMD_M7_WRITE_PIXELS;

    // Burst the 512 RGB565 pixels. The hps_ext.v state machine expects exactly
    // 512 words and then asserts buf_arm to enable the line buffer for the
    // upcoming scanline.
    for (int i = 0; i < HD_WIDTH; ++i) {
      *hps_ext_ptr = hd_pixels[i];
    }
  }

  // Task 3.2: HD Mode 7 Rendering Routine
  std::vector<uint16_t> render_hd_scanline(const M7Regs &regs, int scanline) {
    std::vector<uint16_t> pixels(HD_WIDTH, 0);

    // Standard Mode 7 math, calculated at 2x horizontal resolution
    // (x_screen goes 0..511).

    // Vertical coordinate in standard SNES space (0..223)
    int y_screen = scanline;

    // Adjusted for center and scroll
    int cy = y_screen + regs.vofs - regs.y;

    for (int x_screen = 0; x_screen < HD_WIDTH; ++x_screen) {
      // Map 0..511 to 0..255 space (0.5 pixel steps)
      // By multiplying x_screen by 128 instead of 256, we step by 0.5
      int cx = (x_screen / 2) + regs.hofs - regs.x;

      // Apply the transformation matrix (fixed point 8.8)
      int map_x = ((regs.a * cx) + (regs.b * cy)) >> 8;
      int map_y = ((regs.c * cx) + (regs.d * cy)) >> 8;

      map_x += regs.x;
      map_y += regs.y;

      // Fetch pixel from VRAM (Placeholder mapping)
      // A real implementation needs access to the SNES tilemap/character data
      // and the CGRAM (palette).
      uint8_t color_index = 0;

      // To prevent crashes in this mock, we just generate a test pattern
      uint16_t rgb565 = ((map_x & 0x1F) << 11) | ((map_y & 0x3F) << 5);
      pixels[x_screen] = rgb565;
    }

    return pixels;
  }

  // Main sync loop
  void run() {
    std::cout << "Starting HD Mode 7 Daemon..." << std::cout;

    while (true) {
      // 1. Wait for VBLANK or HBLANK (Requires reading an interrupt or polled
      // register) Placeholder: Usleep to simulate scanline timing (64us per
      // line)
      usleep(64);

      // For the sake of the algorithm, we process scanlines 0..223
      for (int scanline = 0; scanline < SNES_HEIGHT; ++scanline) {

        // 2. Poll Mode 7 registers for this frame/scanline
        M7Regs regs = read_m7_registers();

        // 3. Render the HD scanline
        std::vector<uint16_t> hd_pixels = render_hd_scanline(regs, scanline);

        // 4. Burst write to FPGA Line Buffer
        write_m7_pixels(hd_pixels);

        // Wait for next HBLANK
        usleep(64);
      }
    }
  }
};

int main(int argc, char *argv[]) {
  M7Daemon daemon;
  daemon.run();
  return 0;
}
