// ===========================================================================
//  hd_mode7_linebuf.v  (v4 — 8bpp + CLUT, the P2c throughput fix)
//  True HD Mode 7: per-scanline pixel buffer — 2-slot row ping-pong
//
//  Architecture
//  ============
//  In 16bpp the DDR3 fetch path needed ~141 us per full-width row vs a
//  63.5 us scanline, so rows could not refresh every line (measured
//  stall/burst slides on screen). v4 stores one CLUT INDEX byte per
//  NATIVE pixel: a row is 256 B = 32 DDR3 words ≈ 18 us — under a third
//  of a scanline, so the sweep stays ~3 rows ahead and every displayed
//  line shows a fresh row.
//
//  Colour expansion moved to the display side: a 256-entry CLUT (loaded
//  from the PPU's CGRAM shadow by SNES.sv once per adopted frame) turns
//  each index byte into BGR555 at the read port; low-bit replication
//  expands that to RGB888. The slot RAM shrank 16x (2 x 256 x 8), which
//  pays for the CLUT block with room to spare.
//
//  Port A  (write, clk_mem = clk_sys — the DDR3 bus domain)
//    · 8 bits = one CLUT index per write, pushed by the fetch FSM.
//    · clut_wr_* writes the palette from the CGRAM mirror loader.
//    · buf_wr_slot selects which slot receives writes (= ~act; the
//      parked writer guarantees no mid-row swap).
//
//  Port B  (read, clk_vid — video/display domain)
//    · rd_slot crosses 2FF; it only changes at hde falls, long before
//      the first strobe of the next line.
//    · Read pointer advances ONLY on px_strobe (consumption-indexed);
//      the slot index is rd_x directly (one HD dot per strobe, 2x).
//    · Two-stage pipeline: slot RAM -> CLUT -> RGB888 expansion, with
//      hd_px_valid delayed to the stage where hd_pixel_out is stable.
//      sys_top's overlay mux samples on valid, so the constant extra
//      latency is transparent.
//
//  Arming / line sync (unchanged contract from v2/v3)
//  ===============================================
//  · hde_in is 2FF-synchronized. On its FALLING edge (end of line L's
//    active video) the read pointer resets.
//  · On the RISING edge (start of line L+1's active video) `armed`
//    samples line_hd_in — set by the parent only for lines whose row was
//    fetched. Disarmed lines show native pixels (fallback).
// ===========================================================================
module hd_mode7_linebuf
(
    input             clk_mem,        // DMA write domain (= DDRAM_CLK = clk_sys)
    input             clk_vid,        // Video read domain

    // --- Port A: DMA write interface (clk_mem) ---
    input      [8:0]  buf_wr_addr,    // HD dot index within the row (0..511)
    input      [7:0]  buf_wr_data,    // CLUT index byte
    input             buf_wr_slot,    // slot being written (stable per row)
    input             buf_wr_en,

    // --- CLUT write port (clk_mem, from the CGRAM mirror loader) ---
    input      [7:0]  clut_wr_addr,
    input      [14:0] clut_wr_data,   // BGR555 straight from the PPU shadow
    input             clut_wr_en,

    // --- Line timing (hde_in from PPU, clk_sys domain) ---
    input             hde_in,         // active-high display enable
    input             line_hd_in,     // this line's row was fetched (clk_sys)
    input             px_strobe,      // emit the next pixel (clk_vid)
    output            hd_line_armed,  // line-level HD enable (clk_vid, level)
    input             fetch_en,       // quasi-static: HD fetch path active

    input             rd_slot,        // slot to display (changes at hde falls)

    // --- Output to sys_top overlay (clk_vid) ---
    output wire [23:0] hd_pixel_out,
    output reg         hd_pixel_opaque,
    output reg         hd_px_valid
);

    reg [7:0]  slotram [0:1][0:511];  // two row slots, one CLUT index/HD dot
    reg [14:0] clut    [0:255];       // BGR555 palette (PPU CGRAM shadow image)

    // ---------------------------------------------------------------------
    // Port A: synchronous writes (clk_mem)
    // ---------------------------------------------------------------------
    always @(posedge clk_mem) begin
        if (buf_wr_en)
            slotram[buf_wr_slot][buf_wr_addr] <= buf_wr_data;
    end

    always @(posedge clk_mem) begin
        if (clut_wr_en)
            clut[clut_wr_addr] <= clut_wr_data;
    end

    // BGR555 -> RGB888 (low-bit replication, matching the PPU's own DAC).
    function [23:0] bgr555_to_888(input [14:0] in);
        bgr555_to_888 = {in[4:0],  in[4:2],    // R5 -> R8
                         in[9:5],  in[9:7],    // G5 -> G8
                         in[14:10], in[14:12]}; // B5 -> B8
    endfunction

    // ---------------------------------------------------------------------
    // clk_sys -> clk_vid crossings (2FF each)
    // ---------------------------------------------------------------------
    reg hde_s1, hde_s2;
    always @(posedge clk_vid) begin
        hde_s1 <= hde_in;
        hde_s2 <= hde_s1;
    end
    wire hde_fall = ~hde_s1 & hde_s2;   // end of active video
    wire hde_rise =  hde_s1 & ~hde_s2;  // start of active video

    reg line_hd_s1, line_hd_s2;
    always @(posedge clk_vid) begin
        line_hd_s1 <= line_hd_in;
        line_hd_s2 <= line_hd_s1;
    end

    reg fetch_en_s1, fetch_en_s2;
    always @(posedge clk_vid) begin
        fetch_en_s1 <= fetch_en;
        fetch_en_s2 <= fetch_en_s1;
    end

    reg rd_slot_s1, rd_slot_s2;
    always @(posedge clk_vid) begin
        rd_slot_s1 <= rd_slot;
        rd_slot_s2 <= rd_slot_s1;
    end

    // ---------------------------------------------------------------------
    // Arming + consumption-indexed read pointer (clk_vid)
    // rd_x counts HD strobes — one per HD dot, 512 per line at 2x (two
    // strobes of the four CLK_VIDEO cycles each native lores pixel spans).
    // The slot index is rd_x[8:0]. The pointer resets at the hde fall
    // ending the line.
    // ---------------------------------------------------------------------
    reg        armed = 1'b0;
    reg [9:0]  rd_x   = 10'd0;

    always @(posedge clk_vid) begin
        if (hde_fall) begin
            rd_x <= 10'd0;                      // next line starts
        end else if (px_strobe && armed) begin
            rd_x <= rd_x + 10'd1;
        end

        if (hde_rise)
            armed <= fetch_en_s2 & line_hd_s2;  // show HD only if fetched
    end

    // ---------------------------------------------------------------------
    // Display pipeline: slot RAM -> CLUT -> RGB888.
    //   strobe in T  -> rd_idx valid T+1 -> rd_rgb valid T+2; hd_px_valid
    //   rides the same two flops (v1/v2) so valid+data land together at T+2
    //   and hd_pixel_out (combinational expand) is stable then too.
    // ---------------------------------------------------------------------
    reg        v1;
    reg [7:0]  rd_idx;
    reg [14:0] rd_rgb;

    always @(posedge clk_vid) begin
        rd_idx      <= slotram[rd_slot_s2][rd_x[8:0]];
        rd_rgb      <= clut[rd_idx];
        hd_pixel_opaque <= (rd_idx != 8'd0);
        v1          <= px_strobe & armed;
        hd_px_valid <= v1;
    end

    assign hd_pixel_out = bgr555_to_888(rd_rgb);
    assign hd_line_armed = armed;

endmodule
