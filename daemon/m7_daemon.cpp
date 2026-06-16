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
// Phase 3: True HD Mode 7 ARM C++ Daemon (Auto-Resolution Version)
//
// This daemon memory-maps the HPS-to-FPGA Lightweight bridge to communicate
// with the sys_top ioctl / hps_ext mechanism. It auto-detects the MiSTer
// resolution from MiSTer.ini to set the optimal integer scale.
// ===========================================================================

#define HW_REGS_BASE (0xFF200000)
#define HW_REGS_SPAN (0x00200000)
#define HW_REGS_MASK (HW_REGS_SPAN - 1)

// Hypothetical offset for the user_io / hps_ext command register on the bridge
#define HPS_EXT_BASE_OFFSET 0x00000

// hps_ext commands
#define CMD_M7_READ 0x36
#define CMD_M7_WRITE_PIXELS 0x37
#define CMD_M7_SET_SCALE 0x38

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
  volatile uint16_t *hps_ext_ptr;

  // Dynamic resolution variables
  int scale_multiplier;
  int hd_width;

  std::vector<uint8_t> snes_vram;

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

        // Look for video_mode (A robust implementation would also check [SNES]
        // section overrides)
        if (line.find("video_mode") == 0) {
          // MiSTer standard modes (e.g., 0=720p, 8=1080p, 12=1440p) or custom
          // strings (1920,1080,60)
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

    // Calculate max integer scale that fits inside the target height
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

    // Calculate scale on boot
    scale_multiplier = determine_snes_multiplier();
    hd_width = SNES_WIDTH * scale_multiplier;

    std::cout << "Setting M7 Multiplier to: " << scale_multiplier
              << "x (Width: " << hd_width << ")" << std::endl;

    // Send the scale configuration to the FPGA
    *hps_ext_ptr = CMD_M7_SET_SCALE;
    *hps_ext_ptr = scale_multiplier;
  }

  ~M7Daemon() {
    if (virtual_base != MAP_FAILED) {
      munmap(virtual_base, HW_REGS_SPAN);
    }
    close(mem_fd);
  }

  M7Regs read_m7_registers() {
    M7Regs regs;
    *hps_ext_ptr = CMD_M7_READ;

    regs.a = *hps_ext_ptr;
    regs.b = *hps_ext_ptr;
    regs.c = *hps_ext_ptr;
    regs.d = *hps_ext_ptr;
    regs.x = *hps_ext_ptr & 0x1FFF; // 13-bit
    regs.y = *hps_ext_ptr & 0x1FFF;
    regs.hofs = *hps_ext_ptr & 0x1FFF;
    regs.vofs = *hps_ext_ptr & 0x1FFF;

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

  void write_m7_pixels(const std::vector<uint16_t> &hd_pixels) {
    *hps_ext_ptr = CMD_M7_WRITE_PIXELS;

    // Burst the exact number of dynamically scaled pixels
    for (int i = 0; i < hd_width; ++i) {
      *hps_ext_ptr = hd_pixels[i];
    }
  }

  std::vector<uint16_t> render_hd_scanline(const M7Regs &regs, int scanline) {
    // Allocate vector sized to our dynamic HD width
    std::vector<uint16_t> pixels(hd_width, 0);

    int y_screen = scanline;
    int cy = y_screen + regs.vofs - regs.y;

    for (int x_screen = 0; x_screen < hd_width; ++x_screen) {
      // Map the high-res screen X coordinate back to native 0..255 space
      // E.g. if multiplier is 4x, every 4 pixels map to 1 native unit
      int cx = (x_screen / scale_multiplier) + regs.hofs - regs.x;

      int map_x = ((regs.a * cx) + (regs.b * cy)) >> 8;
      int map_y = ((regs.c * cx) + (regs.d * cy)) >> 8;

      map_x += regs.x;
      map_y += regs.y;

      // Placeholder map rendering pattern
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
        write_m7_pixels(hd_pixels);
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