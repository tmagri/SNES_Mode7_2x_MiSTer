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
//    · Addressed by the PPU's horizontal pixel position (hd_x_out[10:0]).
//    · Output drives HD_PIXEL_IN into the PPU video mux.
//    · HD_MODE7_EN is asserted whenever hd_x_out is inside the active region and
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
    input             clk_sys,        // NEW: ARM Write Domain
    input             clk_vid,        // NEW: Video Read Domain

    // --- Port A: ARM write interface ---
    input      [10:0] buf_wr_addr,
    input      [23:0] buf_wr_data,    
    input             buf_wr_en,      
    input             buf_arm,        

    // --- Port B: Video read interface ---
    input      [10:0] hd_x_out,       // Fixed port name!
    input             frame_out,      
    input             hblank,         

    // --- Outputs to PPU mux ---
    output reg [23:0] hd_pixel_in,    
    output reg        hd_mode7_en     
);

reg [23:0] linebuf [0:2047];

// Port A: synchronous write (ARM Domain)
always @(posedge clk_sys) begin
    if (buf_wr_en)
        linebuf[buf_wr_addr] <= buf_wr_data;
end

// Port B: synchronous read (Video Domain)
reg [23:0] rd_data;
always @(posedge clk_vid) begin
    rd_data <= linebuf[hd_x_out];
end

// ARM-triggered "armed" flag (Tracked on Sys Domain to safely catch ARM signals)
reg armed = 1'b0;
always @(posedge clk_sys) begin
    if (frame_out)
        armed <= 1'b0;
    else if (buf_arm)
        armed <= 1'b1;
end

// Output pipeline (Video Domain)
always @(posedge clk_vid) begin
    hd_pixel_in  <= rd_data;
    hd_mode7_en  <= armed & ~hblank;
end

endmodule