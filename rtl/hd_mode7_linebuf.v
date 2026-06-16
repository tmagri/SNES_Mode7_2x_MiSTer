// ===========================================================================
//  hd_mode7_linebuf.v
//  Phase 2 – True HD Mode 7: Dual-Port Scanline Pixel Buffer
//
//  Architecture
//  ============
//  Port A  (write, HPS/sys clock)
//    · Written one pixel at a time by the ARM via hps_ext CMD_M7_WRITE_PIXELS.
//    · Address = buf_wr_addr[8:0]  (0..511, 512 per sub-pixel half-line)
//    · Data    = buf_wr_data[23:0] (RGB 8:8:8)
//    · Enable  = buf_wr_en
//
//  Port B  (read, video clock = same clk_sys in this design)
//    · Addressed by the PPU's horizontal pixel position (x_out[8:0]).
//    · Output drives HD_PIXEL_IN into the PPU video mux.
//    · HD_MODE7_EN is asserted whenever x_out is inside the active region and
//      the buffer has been primed (armed) by the ARM for this line.
//
//  Arming / Line Sync
//  ==================
//  The ARM writes buf_arm='1' via hps_ext after finishing a complete scanline.
//  This sets an internal "armed" flag that enables HD_MODE7_EN for one line.
//  At the start of each new line (frame_out pulse), armed is cleared, so the
//  ARM must re-write and re-arm every line during HBLANK.
//
// ===========================================================================

module hd_mode7_linebuf
(
    input             clk,            // Single clock domain (clk_sys)

    // --- Port A: ARM write interface ---
    input      [8:0]  buf_wr_addr,    // Pixel index 0..511
    input      [23:0] buf_wr_data,    // RGB 8:8:8 pixel from ARM
    input             buf_wr_en,      // Write strobe (active high)
    input             buf_arm,        // Arm this scanline (set after last write)

    // --- Port B: Video read interface ---
    input      [8:0]  x_out,          // Current horizontal pixel position from PPU
    input             frame_out,      // Pulse at start of each new pixel row (from PPU)
    input             hblank,         // PPU HBLANK signal

    // --- Outputs to PPU mux ---
    output reg [23:0] hd_pixel_in,    // HD pixel data (to HD_PIXEL_IN port)
    output reg        hd_mode7_en     // Enable: override standard PPU output
);

// ---------------------------------------------------------------------------
// Internal line buffer: 512 entries × 24-bit RGB
// Inferred dual-port Block RAM (Altera Cyclone V synthesis)
// ---------------------------------------------------------------------------
reg [23:0] linebuf [0:511];

// Port A: synchronous write
always @(posedge clk) begin
    if (buf_wr_en)
        linebuf[buf_wr_addr] <= buf_wr_data;
end

// Port B: synchronous read
reg [23:0] rd_data;
always @(posedge clk) begin
    rd_data <= linebuf[x_out];
end

// ---------------------------------------------------------------------------
// ARM-triggered "armed" flag
//   · Set   : when buf_arm is pulsed (ARM finished writing the scanline)
//   · Clear : at the rising edge of frame_out (start of a new active line)
// ---------------------------------------------------------------------------
reg armed = 1'b0;

always @(posedge clk) begin
    if (frame_out)
        armed <= 1'b0;      // New line started – clear until ARM re-arms
    else if (buf_arm)
        armed <= 1'b1;      // ARM signals scanline data is ready
end

// ---------------------------------------------------------------------------
// Output pipeline
//   · hd_mode7_en is active only when armed AND inside the active region
//     (not during HBLANK).
//   · One extra register stage to keep timing clean (matches dpram latency).
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    hd_pixel_in  <= rd_data;
    hd_mode7_en  <= armed & ~hblank;
end

endmodule
