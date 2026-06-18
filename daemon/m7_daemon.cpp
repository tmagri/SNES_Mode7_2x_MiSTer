#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

// ===========================================================================
// Phase 3: True HD Mode 7 ARM C++ Daemon (DDR3 Shared Memory Version)
//
// This daemon allocates a 16MB chunk of physical DDR3 RAM. It writes the
// rendered HD pixels directly to memory, where the FPGA's sysmem controller
// will fetch them, eliminating AXI bridge collisions entirely.
// ===========================================================================

// 0x3E000000 is safely placed in the upper half of the MiSTer's 1GB DDR3 RAM,
// far away from the Linux OS which sits in the lower half.
#define DDR3_PHYS_BASE 0x3E000000
#define DDR3_SPAN 0x01000000 // 16 MB of space (plenty for HD frames)

// SNES native screen dimensions
#define SNES_WIDTH 256
#define SNES_HEIGHT 224

struct M7Regs {
  int16_t a, b, c, d;
  int16_t x, y;
  int16_t hofs, vofs;
};

class M7Daemon {
private:
  int mem_fd;
  void *virtual_base;
  uint32_t *hd_pixel_buffer; // Pointer to our massive RAM canvas
  volatile uint16_t *mailbox_regs; // Phase 4: 8 × 16-bit M7 regs written by FPGA

  // Dynamic resolution variables
  int scale_multiplier;
  int hd_width;

  // Parses MiSTer.ini to figure out the target resolution height
  int determine_snes_multiplier() {
    std::ifstream ini_file("/media/fat/MiSTer.ini");
    int target_height = 1080; // Default to 1080p if file cannot be read

    if (ini_file.is_open()) {
      std::string line;
      while (std::getline(ini_file, line)) {
        // Ignore comments
        if (line.empty() || line[0] == ';' || line[0] == '#')
          continue;

        if (line.find("video_mode") == 0) {
          if (line.find("1440") != std::string::npos ||
              line.find("=12") != std::string::npos ||
              line.find("= 12") != std::string::npos) {
            target_height = 1440;
          } else if (line.find("1080") != std::string::npos ||
                     line.find("=8") != std::string::npos ||
                     line.find("= 8") != std::string::npos) {
            target_height = 1080;
          } else if (line.find("720") != std::string::npos ||
                     line.find("=0") != std::string::npos ||
                     line.find("= 0") != std::string::npos) {
            target_height = 720;
          } else if (line.find("480") != std::string::npos) {
            target_height = 480;
          }
        }
      }
      ini_file.close();
    }

    std::cout << "Detected Target Height: " << target_height << "p"
              << std::endl;

    if (target_height >= 1344)
      return 6; // 6x (1536x1344)
    if (target_height >= 896)
      return 4; // 4x (1024x896) - Best for 1080p
    if (target_height >= 672)
      return 3; // 3x (768x672) - Best for 720p
    if (target_height >= 448)
      return 2; // 2x (512x448)
    return 1;   // 1x Native
  }

public:
  M7Daemon() {
    mem_fd = open("/dev/mem", (O_RDWR | O_SYNC));
    if (mem_fd == -1) {
      std::cerr << "ERROR: could not open /dev/mem" << std::endl;
      exit(1);
    }

    // Map the physical DDR3 RAM directly into our C++ virtual space
    virtual_base = mmap(NULL, DDR3_SPAN, (PROT_READ | PROT_WRITE), MAP_SHARED,
                        mem_fd, DDR3_PHYS_BASE);

    if (virtual_base == MAP_FAILED) {
      std::cerr << "ERROR: mmap failed" << std::endl;
      close(mem_fd);
      exit(1);
    }

    // Cast the raw memory block to a 32-bit integer array so we can write
    // pixels to it. Skip the first 4 KB — that page is reserved for the
    // FPGA's register mailbox (8 × 16-bit Mode 7 regs written by the FPGA
    // at the start of every frame). Pixels live at offset 0x1000.
    hd_pixel_buffer = (uint32_t *)((uint8_t *)virtual_base + 0x1000);
    mailbox_regs    = (volatile uint16_t *)virtual_base;

    // Calculate scale on boot
    scale_multiplier = determine_snes_multiplier();
    hd_width = SNES_WIDTH * scale_multiplier;

    // TODO(Phase 5): push scale_multiplier to the FPGA via CMD_M7_SET_SCALE
    // so the DMA reader's HD_WIDTH matches our local hd_width. The MiSTer
    // framework's hps_ext protocol requires linking against libuserio and
    // calling:
    //     spi_uio_cmd_cont(0x38);  // CMD_M7_SET_SCALE
    //     spi_w(scale_multiplier);
    //     DisableIO();
    // (Reference: support/megacd/megacd.cpp in Main_MiSTer.) Without that,
    // the FPGA defaults to 4x (see hps_ext.v) and the daemon MUST also use
    // 4x — override the ini-derived value here for now.
    if (scale_multiplier != 4) {
        std::cerr << "WARNING: dynamic scale (" << scale_multiplier
                  << "x) is not wired to the FPGA yet; forcing 4x to match "
                  << "the FPGA default. See Phase 5 TODO." << std::endl;
        scale_multiplier = 4;
        hd_width = SNES_WIDTH * scale_multiplier;
    }

    std::cout << "Setting M7 Multiplier to: " << scale_multiplier
              << "x (Width: " << hd_width << ")" << std::endl;
  }

  // Safely unmap the memory block on close
  ~M7Daemon() {
    if (virtual_base != MAP_FAILED) {
      munmap(virtual_base, DDR3_SPAN);
    }
    close(mem_fd);
  }

  M7Regs read_m7_registers() {
    // =================================================================
    // Phase 4 Task 4.1: read the 8 Mode 7 registers from the FPGA's
    // DDR3 mailbox (written at the top of every frame by the mailbox
    // writer in SNES.sv). The mailbox sits at the very start of our
    // mmap region (0x3E000000-0x3E00000F). volatile because it's
    // updated by the FPGA concurrently with our reads.
    // =================================================================
    M7Regs regs;
    regs.a    = static_cast<int16_t>(mailbox_regs[0]);
    regs.b    = static_cast<int16_t>(mailbox_regs[1]);
    regs.c    = static_cast<int16_t>(mailbox_regs[2]);
    regs.d    = static_cast<int16_t>(mailbox_regs[3]);
    regs.x    = static_cast<int16_t>(mailbox_regs[4]);
    regs.y    = static_cast<int16_t>(mailbox_regs[5]);
    regs.hofs = static_cast<int16_t>(mailbox_regs[6]);
    regs.vofs = static_cast<int16_t>(mailbox_regs[7]);
    return regs;
  }

  // Updated to write directly to the 1D RAM array based on the scanline
  void write_m7_pixels(const std::vector<uint16_t> &hd_pixels, int scanline) {
    // Calculate where in our 1D RAM array this row of pixels starts
    int pixel_offset = scanline * hd_width;

    // Dump the exact number of dynamically scaled pixels into the RAM array
    for (int i = 0; i < hd_width; ++i) {
      // Writing the 16-bit RGB565 pixel into the 32-bit RAM slot
      hd_pixel_buffer[pixel_offset + i] = hd_pixels[i];
    }
  }

  std::vector<uint16_t> render_hd_scanline(const M7Regs &regs, int scanline) {
    std::vector<uint16_t> pixels(hd_width, 0);

    int y_screen = scanline;
    int cy = y_screen + regs.vofs - regs.y;

    for (int x_screen = 0; x_screen < hd_width; ++x_screen) {
      int cx = (x_screen / scale_multiplier) + regs.hofs - regs.x;

      int map_x = ((regs.a * cx) + (regs.b * cy)) >> 8;
      int map_y = ((regs.c * cx) + (regs.d * cy)) >> 8;

      map_x += regs.x;
      map_y += regs.y;

      uint16_t rgb565 = ((map_x & 0x1F) << 11) | ((map_y & 0x3F) << 5);
      pixels[x_screen] = rgb565;
    }

    return pixels;
  }

  void run() {
    std::cout << "Starting HD Mode 7 Daemon Main Loop..." << std::endl;

    while (true) {
      usleep(64); // Simulate scanline timing
      for (int scanline = 0; scanline < SNES_HEIGHT; ++scanline) {
        M7Regs regs = read_m7_registers();
        std::vector<uint16_t> hd_pixels = render_hd_scanline(regs, scanline);

        // Pass the scanline index so the array knows exactly where to put the
        // pixels!
        write_m7_pixels(hd_pixels, scanline);

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