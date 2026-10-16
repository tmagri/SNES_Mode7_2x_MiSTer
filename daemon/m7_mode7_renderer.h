#ifndef M7_MODE7_RENDERER_H
#define M7_MODE7_RENDERER_H

#include "m7_abi.h"

#include <cstdint>

struct M7Regs {
  int16_t a, b, c, d;
  uint16_t x, y, hofs, vofs;
};

namespace m7 {

// 13-bit signed value (SNES X/Y/HOFS/VOFS registers): sign-extend bit 12.
inline int sign_extend_13(uint16_t value) {
  value &= 0x1FFF;
  return (value & 0x1000) ? static_cast<int>(value) - 0x2000 : value;
}

// PPU Mode7Clip: takes a 14-bit signed value and returns {a[13], a[9:0]}
// as a signed 11-bit value (range -1024..+1023).
// This is the VHDL: res := a(13) & a(9 downto 0)
inline int mode7_clip(int value) {
  const int value14 = value & 0x3FFF;
  int clipped = value14 & 0x03FF;
  if (value14 & 0x2000) clipped -= 0x0400;
  return clipped;
}

// Floor-divide a signed 8.8 fixed-point value to get the integer part.
inline int floor_fixed_8(int32_t value) {
  if (value >= 0) return value / 256;
  return -static_cast<int>((-static_cast<int64_t>(value) + 255) / 256);
}

// The PPU accumulates MPY(26 downto 6), dropping six low product bits on
// every matrix multiply before adding it to the 8.8 coordinate accumulator.
// The truncation zeros out the bottom 6 bits of the product.
inline int32_t mode7_product(int16_t matrix, int coordinate) {
  const int32_t product = static_cast<int32_t>(matrix) * coordinate;
  if (product >= 0) return (product / 64) * 64;
  return static_cast<int32_t>(-
      ((-static_cast<int64_t>(product) + 63) / 64) * 64);
}

// Outside-map check: fixed-point coordinate must be in [0, 1024) pixels,
// i.e. [0, 1024*256) in 8.8 fixed-point.  The PPU checks
// M7_VRAM_X(26 downto 18) = "000000000" — any bit above position 17
// (i.e. integer bits 10+) being nonzero means outside the map.
inline bool coordinate_inside_map(int32_t fixed) {
  return fixed >= 0 && fixed < (1024 * 256);
}

// Flat VRAM byte at address b. SNES VRAM is a flat 64 KiB byte space; the
// core stores it as two 8-bit byte planes (port A / port B of the word-wide
// memory), so byte b lives in plane (b & 1) at word b >> 1. Both Mode 7
// fetches — the tilemap entry AND the character pixel — are flat byte
// addresses and must go through this split. (An earlier model treated
// plane 1 as "the tilemap array" and plane 2 as "the pixel array" at the
// same word index; that renders solid-color tiles correctly by accident
// and turns every detailed tile into per-pixel noise.)
inline uint8_t vram7_byte(const uint8_t *v1, const uint8_t *v2,
                          unsigned byte_addr) {
  return (byte_addr & 1) ? v2[byte_addr >> 1] : v1[byte_addr >> 1];
}

// --------------------------------------------------------------------------
// render_line — software Mode 7 rasterizer for one scanline.
//
// SNES Mode 7 VRAM layout (flat byte space):
//   0x0000-0x3FFF — character data: 256 tiles x 64 bytes (8x8, 1 byte/px)
//   0x4000-0x7FFF — tilemap: 128x128 entries, one byte each (tile index)
//
// The daemon receives VRAM as two byte-plane arrays (word-indexed):
//   vram1[] = even flat bytes, vram2[] = odd flat bytes — see vram7_byte.
//
// The pixel buffer stores one CLUT index per native pixel (8bpp).
// Index 0 = transparent — the FPGA compositing mux will show the native
// pixel stream underneath, allowing sprites and HUD to render on top.
// --------------------------------------------------------------------------
inline void render_line(const M7Regs &regs, int line, uint8_t m7sel,
                       bool extbg, const uint8_t *vram1,
                       const uint8_t *vram2, uint8_t *out) {
  const int center_x = sign_extend_13(regs.x);
  const int center_y = sign_extend_13(regs.y);
  const int origin_x = mode7_clip(sign_extend_13(regs.hofs) - center_x);
  const int origin_y = mode7_clip(sign_extend_13(regs.vofs) - center_y);
  const int overflow = (m7sel >> 6) & 3;

  // Pre-compute the line-constant portion of the affine transform:
  //   base = center*256 + A*clip(OrgX) + B*clip(OrgY) + B*screenY
  // (for X axis; analogous for Y axis with C/D swapped)
  const int screen_y = (m7sel & 0x02) ? 255 - line : line;

  const int32_t base_x = center_x * 256 +
    mode7_product(regs.a, origin_x) + mode7_product(regs.b, origin_y) +
    mode7_product(regs.b, screen_y);
  const int32_t base_y = center_y * 256 +
    mode7_product(regs.c, origin_x) + mode7_product(regs.d, origin_y) +
    mode7_product(regs.d, screen_y);

  for (int x = 0; x < static_cast<int>(M7_PIX_STRIDE); ++x) {
    const int screen_x = (m7sel & 0x01) ? 255 - x : x;

    // Per-pixel: add A*screenX (for map X) and C*screenX (for map Y).
    const int32_t x_fixed = base_x + mode7_product(regs.a, screen_x);
    const int32_t y_fixed = base_y + mode7_product(regs.c, screen_x);

    const bool outside = !coordinate_inside_map(x_fixed) ||
                         !coordinate_inside_map(y_fixed);

    // M7SEL overflow modes:
    //   00, 01: wrap (mask address to 1024x1024 — handled by & 0x3FF below)
    //   10:     transparent outside the map
    //   11:     substitute tile 0 outside the map
    if (outside && overflow == 2) {
      out[x] = 0;  // transparent
      continue;
    }

    const unsigned map_x = static_cast<unsigned>(floor_fixed_8(x_fixed)) & 0x3FF;
    const unsigned map_y = static_cast<unsigned>(floor_fixed_8(y_fixed)) & 0x3FF;
    const unsigned tile_row = map_y & 7;   // pixel row within tile (0-7)
    const unsigned tile_col = map_x & 7;   // pixel column within tile (0-7)

    // Tilemap: fixed at flat byte 0x4000 in Mode 7, 128 tiles per row,
    // 128 rows = 16384 one-byte entries.
    const unsigned map_addr = (map_y >> 3) * 128 + (map_x >> 3);

    // M7SEL=11 substitutes tile zero outside the 1024x1024 map.
    const unsigned tile = (outside && overflow == 3)
                              ? 0
                              : vram7_byte(vram1, vram2, 0x4000u + map_addr);

    // Character data: fixed at flat byte 0, tile*64 + row*8 + col.
    const unsigned char_addr = tile * 64 + tile_row * 8 + tile_col;
    const uint8_t pixel = vram7_byte(vram1, vram2, char_addr);

    // EXTBG mode: bit 7 is the BG2 priority flag, bits 6:0 are the
    // color index (into CGRAM entries 0-127). For BG1 (no EXTBG bit set),
    // all 8 bits are the color index. The daemon outputs one merged
    // layer for the FPGA CLUT, so in EXTBG mode we strip the priority
    // bit and output just the 7-bit color index. Color index 0 remains
    // transparent regardless.
    if (extbg) {
      out[x] = pixel & 0x7F;  // strip priority bit, 0 stays transparent
    } else {
      out[x] = pixel;  // full 8-bit index, 0 = transparent
    }
  }
}

}  // namespace m7

#endif