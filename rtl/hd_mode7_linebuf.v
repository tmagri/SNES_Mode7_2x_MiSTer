// ===========================================================================
//  hd_mode7_linebuf.v  (v3)
//  True HD Mode 7: per-scanline HD pixel buffer — 2-slot row ping-pong
//
//  Architecture
//  ============
//  The DDR3 fetch path cannot deliver a full row inside one scanline
//  (measured on-device: ~0.56 us per 64-bit word => ~141 us per 256-word
//  row vs a 63.5 us line), so per-line fetch-ahead is impossible. Instead
//  the fetch engine sweeps rows CONTINUOUSLY into the slot that is NOT
//  being displayed, one complete row at a time, and parks at row
//  boundaries (SNES.sv DM_ROW_END / row_adv) so a row can never straddle
//  a slot swap. The parent swaps slots at hde falls, only when the
//  inactive slot holds a row this line hasn't shown yet; lines between
//  fresh rows repeat the last completed row. Content stays row-coherent
//  (no tearing, no banding); until fetch throughput rises (P2c: 8bpp+CLUT
//  would fetch a row in ~18 us), ~1/3 of lines show a repeated row.
//
//  Slots store RAW RGB565 pixel pairs (32 bits) — SNES colour is 15-bit
//  anyway, and the narrower slot is what makes the second slot fit the
//  M10K budget. Expansion to RGB888 happens at the read mux.
//
//  Port A  (write, clk_mem = clk_sys — the DDR3 bus domain)
//    · 32 bits = TWO RGB565 pixels per write, pushed by the fetch FSM.
//    · buf_wr_slot selects which slot receives writes (= ~act, stable
//      between hde falls; the parked writer guarantees no mid-row swap).
//
//  Port B  (read, clk_vid — video/display domain)
//    · rd_slot crosses 2FF; it only changes at hde falls, long before the
//      first strobe of the next line.
//    · Read pointer advances ONLY on px_strobe (consumption-indexed), so
//      alignment holds at any video mode / scale.
//    · hd_px_valid and hd_pixel_out are registered together: both appear
//      one clk_vid cycle after their strobe.
//
//  Arming / line sync (unchanged contract from v2)
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
    input      [8:0]  buf_wr_addr,    // pixel PAIR index (0..511)
    input      [31:0] buf_wr_data,    // two RGB565 pixels
    input             buf_wr_slot,    // slot being written (stable per row)
    input             buf_wr_en,

    // --- Line timing (hde_in from PPU, clk_sys domain) ---
    input             hde_in,         // active-high display enable
    input             line_hd_in,     // this line's row was fetched (clk_sys)
    input             px_strobe,      // emit the next pixel (clk_vid)
    input             fetch_en,       // quasi-static: HD fetch path active

    input             rd_slot,        // slot to display (changes at hde falls)

    // --- Output to sys_top overlay (clk_vid) ---
    output reg [23:0] hd_pixel_out,
    output reg        hd_px_valid
);

    reg [31:0] slotram [0:1][0:511];  // two row slots, raw RGB565 pairs

    // ---------------------------------------------------------------------
    // Port A: synchronous write (clk_mem)
    // ---------------------------------------------------------------------
    always @(posedge clk_mem) begin
        if (buf_wr_en)
            slotram[buf_wr_slot][buf_wr_addr] <= buf_wr_data;
    end

    // RGB565 -> RGB888 (low-bit replication, same as the daemon's encode).
    function [23:0] rgb565_to_888(input [15:0] in);
        rgb565_to_888 = {in[15:11], in[15:13],   // R5 -> R8
                         in[10:5],  in[10:9],    // G6 -> G8
                         in[4:0],   in[4:2]};    // B5 -> B8
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
    // rd_x is the PIXEL index (0..1023); the BRAM word (a pixel pair) is
    // rd_x[9:1] and rd_x[0] picks the half. rd_sel is captured together
    // with rd_data so both stay one cycle behind the strobe — aligned with
    // hd_px_valid.
    // ---------------------------------------------------------------------
    reg        armed = 1'b0;
    reg [9:0]  rd_x   = 10'd0;
    reg        rd_sel = 1'b0;
    reg [31:0] rd_data;

    always @(posedge clk_vid) begin
        hd_px_valid <= px_strobe & armed;
        if (hde_fall) begin
            rd_x <= 10'd0;                      // next line starts
        end else if (px_strobe && armed) begin
            rd_x <= rd_x + 10'd1;
        end

        if (hde_rise)
            armed <= fetch_en_s2 & line_hd_s2;  // show HD only if fetched
    end

    // Port B: synchronous read from the displayed slot, aligned with
    // hd_px_valid (both 1 cycle late), RGB565 expanded to RGB888.
    always @(posedge clk_vid) begin
        rd_data <= slotram[rd_slot_s2][rd_x[9:1]];
        rd_sel  <= rd_x[0];
    end

    always @(*) begin
        hd_pixel_out = rgb565_to_888(rd_sel ? rd_data[31:16] : rd_data[15:0]);
    end

endmodule
