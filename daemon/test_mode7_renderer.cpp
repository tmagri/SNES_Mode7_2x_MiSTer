#include "m7_mode7_renderer.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

uint8_t vram1[M7_VRAM_WORDS] = {};
uint8_t vram2[M7_VRAM_WORDS] = {};
uint8_t line[M7_PIX_STRIDE] = {};

M7Regs identity_regs() {
  M7Regs regs = {};
  regs.a = 0x0100;
  regs.d = 0x0100;
  return regs;
}

// Set a pixel in VRAM matching the SNES Mode 7 layout as fetched by the
// PPU (see the layout note in m7_mode7_renderer.h): the Mode 7 window is
// 16K words, each holding two fetchable bytes in separate planes —
// plane 1 word i = tilemap entry i (128x128, 1 B/word), plane 2 word
// tile*64+row*8+col = character pixel bytes.
void set_pixel(unsigned map_x, unsigned map_y, uint8_t tile, uint8_t pixel) {
  const unsigned map_addr = (map_y >> 3) * 128 + (map_x >> 3);
  const unsigned char_addr = tile * 64 + (map_y & 7) * 8 + (map_x & 7);
  vram1[map_addr] = tile;
  vram2[char_addr] = pixel;
}

void clear_vram() {
  for (unsigned i = 0; i < M7_VRAM_WORDS; ++i) vram1[i] = vram2[i] = 0;
}

}  // namespace

int main() {
  // sign_extend_13 tests
  assert(m7::sign_extend_13(0x0FFF) == 4095);
  assert(m7::sign_extend_13(0x1000) == -4096);
  assert(m7::sign_extend_13(0x1FFF) == -1);

  // mode7_clip tests
  assert(m7::mode7_clip(-1024) == -1024);
  assert(m7::mode7_clip(-1) == -1);

  // mode7_product tests: product truncated to 64-boundary
  assert(m7::mode7_product(257, 1) == 256);
  assert(m7::mode7_product(-257, 1) == -320);

  // Basic pixel fetch: identity transform (A=D=1.0), pixels at (0,0) and
  // (1,0). With HD 2x each lores pixel k produces dots 2k (full step) and
  // 2k+1 (half step): dot 1 samples map x=0.5, which floors to pixel 0.
  clear_vram();
  set_pixel(0, 0, 1, 0x31);
  set_pixel(1, 0, 1, 0x32);
  M7Regs regs = identity_regs();
  m7::render_line(regs, 0, 0, false, vram1, vram2, line);
  assert(line[0] == 0x31);  // dot 0: pixel at (0,0)
  assert(line[1] == 0x31);  // dot 1: half step, floor(0.5) = pixel (0,0)
  assert(line[2] == 0x32);  // dot 2: pixel at (1,0)
  assert(line[3] == 0x32);  // dot 3: half step, floor(1.5) = pixel (1,0)

  // Color index zero is transparent
  set_pixel(0, 0, 1, 0);
  m7::render_line(regs, 0, 0, false, vram1, vram2, line);
  assert(line[0] == 0);  // color index zero remains transparent

  // Horizontal flip (M7SEL bit 0): x=0 maps to screen_x=255
  clear_vram();
  set_pixel(255, 0, 2, 0x5A);
  regs = identity_regs();
  m7::render_line(regs, 0, 0x01, false, vram1, vram2, line);
  assert(line[0] == 0x5A);  // horizontal flip reverses the screen coordinate

  // M7SEL overflow modes
  clear_vram();
  set_pixel(0, 0, 1, 0x41);
  // Also set tile 0's pixel at (0,0) in char data for mode 11 test
  vram2[0] = 0x77;  // tile 0, row 0, col 0 -> plane 2 word 0; overflow mode
                    // 11 substitutes tile zero, whose fetch reads this byte
  regs = {};
  regs.x = 1024;  // map coordinate is outside while the matrix is zero
  m7::render_line(regs, 0, 0x00, false, vram1, vram2, line);
  assert(line[0] == 0x41);  // repeat mode 00 wraps to map coordinate zero
  m7::render_line(regs, 0, 0x40, false, vram1, vram2, line);
  assert(line[0] == 0x41);  // repeat mode 01 also wraps
  m7::render_line(regs, 0, 0x80, false, vram1, vram2, line);
  assert(line[0] == 0);     // mode 10 is transparent outside the map
  m7::render_line(regs, 0, 0xC0, false, vram1, vram2, line);
  assert(line[0] == 0x77);  // mode 11 fetches tile zero outside the map

  // EXTBG: bit 7 is priority, bits 6:0 are color index
  clear_vram();
  set_pixel(0, 0, 1, 0x85);  // priority=1, color=5
  regs = identity_regs();
  m7::render_line(regs, 0, 0, true, vram1, vram2, line);
  assert(line[0] == 5);    // EXTBG strips priority bit, outputs color 5
  set_pixel(0, 0, 1, 0x05);  // priority=0, color=5
  m7::render_line(regs, 0, 0, true, vram1, vram2, line);
  assert(line[0] == 5);    // same color index regardless of priority bit

  std::cout << "Mode 7 renderer tests passed\n";
  return 0;
}