//============================================================================
//  SNES for MiSTer
//  Copyright (C) 2017-2019 Srg320
//  Copyright (C) 2018-2019 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================ 

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	// Dynamic HD Canvas Overlay signals to share with sys_top.
	// HD_PIXEL_VALID is a clk_video-domain strobe aligned with HD_PIXEL_IN:
	// asserted exactly on cycles where an HD pixel is presented (so sys_top
	// can mux it in place of the native pixel). HD_PX_STROBE is the return
	// path: sys_top's pixel-repeat engine asserts it one clk_video cycle
	// before each emitted output pixel, and hd_mode7_linebuf advances its
	// read pointer only on that strobe (consumption-indexed for any video
	// mode / PLL rate).
	output [3:0]  M7_SCALE,
    output        HD_PIXEL_VALID,
    output [23:0] HD_PIXEL_IN,
	output        HD_PIXEL_OPAQUE,
    output        HD_LINE_ARMED,
	input         HD_PX_STROBE,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output [7:0]  M7_DBG_LED,   // HD Mode 7 debug bisect (see sys_top LED mux)
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[20:19];

assign LED_USER  = cart_download | ssbin_download | spc_download | (status[23] & bk_pending);
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = osd_btn;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
// Bob deinterlace is auto-enabled for interlaced frames (including M7 Wide-Res)
assign HDMI_BOB_DEINT = interlace;

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

wire [1:0] ar       = status[33:32];
wire       vcrop_en = status[39];
wire [3:0] vcopt    = status[38:35];
reg        en216p;
reg  [4:0] voff;
always @(posedge CLK_VIDEO) begin
	en216p <= ((HDMI_WIDTH == 1920) && (HDMI_HEIGHT == 1080) && !forced_scandoubler && !scale);
	voff <= (vcopt < 6) ? {vcopt,1'b0} : ({vcopt,1'b0} - 5'd24);
end

wire vga_de;
video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? (V224_MODE ? 12'd64 : 12'd2048) : (ar - 1'd1)),
	.ARY((!ar) ? (V224_MODE ? 12'd49 : 12'd1673) : 12'd0),
	.CROP_SIZE((en216p & vcrop_en) ? 10'd216 : 10'd0),
	.CROP_OFF(voff),
	.SCALE(status[41:40])
);

///////////////////////  CLOCK/RESET  ///////////////////////////////////

wire clock_locked;
wire clk_mem;
wire clk_sys;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),
	.outclk_1(CLK_VIDEO),
	.outclk_2(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(clock_locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

always @(posedge CLK_50M) begin
	reg pald = 0, pald2 = 0;
	reg [2:0] state = 0;

	pald  <= PAL;
	pald2 <= pald;

	cfg_write <= 0;
	if(pald2 != pald) state <= 1;

	if(!cfg_waitrequest) begin
		if(state) state<=state+1'd1;
		case(state)
			1: begin
					cfg_address <= 0;
					cfg_data <= 0;
					cfg_write <= 1;
				end
			3: begin
					cfg_address <= 7;
					cfg_data <= pald2 ? 2201376898 : 2537930535;
					cfg_write <= 1;
				end
			5: begin
					cfg_address <= 2;
					cfg_data <= 0;
					cfg_write <= 1;
				end
		endcase
	end
end

wire reset = RESET | buttons[1] | status[0] | cart_download | spc_download | bk_loading | clearing_ram | msu_data_download;

////////////////////////////  HPS I/O  //////////////////////////////////

// Status Bit Map:
// 0         1         2         3          4         5         6
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX XXXXXXXXXXXXXXXXXXXXXXXXXXX

`include "build_id.v"
// Shared Mode 7 ABI constants — included before any use (m7_scale_wire at the
// linebuf instance and the Phase D engine both reference these).
`include "rtl/m7_abi.svh"
parameter CONF_STR = {
	"SNES;SS3F800000:100000,UART31250,MIDI;",
	"FS1,SFCSMCBINBS ;",
	"FS4,SPC;",
	"-;",
	"O[50],Save state to SD,On,Off;",
	"O[52:51],Savestate Slot,1,2,3,4;",
	"d6R[47],Save state (Alt-F1);",
	"d6R[48],Load state (F1);",
	"-;",
	"OEF,Video Region,Auto,NTSC,PAL;",
	"O13,ROM Header,Auto,No Header,LoROM,HiROM,ExHiROM;",
	"-;",
	"C,Cheats;",
	"H2OO,Cheats Enabled,Yes,No;",
	"-;",
	"D0RC,Load Backup RAM;",
	"D0RD,Save Backup RAM;",
	"D0ON,Autosave,Off,On;",
	"D0-;",

	"P1,Audio & Video;",
	"P1-;",
	"P1o01,Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O9B,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1-;",
	"d5P1o7,Vertical Crop,Disabled,216p(5x);",
	"d5P1o36,Crop Offset,0,2,4,8,10,12,-12,-10,-8,-6,-4,-2;",
	"P1o89,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1oA,Force 256px,Off,On;",
	"P1-;",
	"P1OG,Pseudo Transparency,Blend,Off;",
	"P1O[58],True HD Mode 7,Off,On;",
	"P1-;",
	"P1OJK,Stereo Mix,None,25%,50%,100%;", 

	"P2,Input Options;",
	"P2-;",
	"P2O7,Swap Joysticks,No,Yes;",
	"P2O8,SNAC,No,Yes;",
	"P2O[53],State Ld/Sv,Start+Up/Down,Up/Down;",
	"P2-;",
	"P2oB,Miracle Piano,No,Yes;",
	"P2OH,Multitap,Disabled,Port2;",
	"P2O56,Mouse,None,Port1,Port2;",
	"P2-;",
	"P2OPQ,Super Scope,Disabled,Joy1,Joy2,Mouse;",
	"D4P2OR,Super Scope Btn,Joy,Mouse;",
	"D4P2OST,Cross,Small,Big,None;",
	"D4P2o2,Gun Type,Super Scope,Justifier;",
	
	"P3,Hardware;",
	"P3-;",
	"D1P3OI,SuperFX/DSP Speed,Normal,Turbo;",
	"D1P3oE,SuperFX FastROM,Yes,No;",
	"D3P3O4,CPU Speed,Normal,Turbo;",
	"P3OU,Audio clock,Typical,Real;",
	"P3OV,Sufami Cart swapping,No,Yes;",
	"P3oMP,Competition Cart time,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18;",
	"P3-;",
	"P3OLM,Initial WRAM,9966(SNES2),00FF(SNES1),55(SD2SNES),FF;",
	"P3oCD,Initial ARAM,9966(SNES2),00FF(SNES1),55(SD2SNES),FF;",

	"-;",
	"R0,Reset;",
	"J1,A(SS Fire),B(SS Cursor),X(SS TurboSw),Y(SS Pause),LT(SS Cursor),RT(SS Fire),Select,Start,SaveState;",
	"I,",
	"Slot=DPAD|Save/Load=Pause+DPAD,",
	"Active Slot 1,",
	"Active Slot 2,",
	"Active Slot 3,",
	"Active Slot 4,",
	"Save to state 1,",
	"Restore state 1,",
	"Save to state 2,",
	"Restore state 2,",
	"Save to state 3,",
	"Restore state 3,",
	"Save to state 4,",
	"Restore state 4;",
	"V,v",`BUILD_DATE
};

wire  [1:0] buttons;
wire [63:0] status;
wire [15:0] status_menumask = {ss_allow ,en216p, !GUN_MODE, ~turbo_allow, ~gg_available, ~GSU_ACTIVE, ~bk_ena};
wire        forced_scandoubler;
reg  [31:0] sd_lba;
reg         sd_rd = 0;
reg         sd_wr = 0;
wire        sd_ack;
wire  [7:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din;
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire        ioctl_download;
wire [24:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wr;
wire  [7:0] ioctl_index;

wire [12:0] joy0,joy1,joy2,joy3,joy4;
wire [24:0] ps2_mouse;
wire [10:0] ps2_key;
wire [15:0] joystick1_rumble;

wire  [7:0] joy0_x,joy0_y,joy1_x,joy1_y;

reg  [7:0] uart_mode;

wire [64:0] RTC;

wire [21:0] gamma_bus;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),
	.new_vmode(new_vmode),

	.joystick_l_analog_0({joy0_y, joy0_x}),
	.joystick_l_analog_1({joy1_y, joy1_x}),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.joystick_2(joy2),
	.joystick_3(joy3),
	.joystick_4(joy4),
	.joystick_0_rumble(status[8] ? 16'h0000 : joystick1_rumble), 
	.ps2_mouse(ps2_mouse),
	.ps2_key(ps2_key),

	.status(status),
	.status_menumask(status_menumask),
	.status_in(cart_download ? {status[63:53], ss_slot, status[50:5],1'b0,status[3:0]} : {status[63:53], ss_slot, status[50:32],1'b0,status[30:0]}),
	.status_set(cart_download | status0_fall | ss_status),

	.info_req(ss_info_req),
	.info(ss_info),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),

	.sd_lba('{sd_lba}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din}),
	.sd_buff_wr(sd_buff_wr),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.uart_mode(uart_mode),

	.RTC(RTC),

	.gamma_bus(gamma_bus),
	.EXT_BUS(EXT_BUS)
);

wire       GUN_BTN = status[27];
wire [1:0] GUN_MODE = status[26:25];
wire       GUN_TYPE = status[34];
wire       GSU_TURBO = status[18];
wire       GSU_FASTROM = ~status[46];
wire       SUFAMI_SWAP = status[31];
wire [3:0] CC_TIME = status[57:54];
wire       BLEND = ~status[16];
wire       M7_HD = status[58];
wire [1:0] mouse_mode = status[6:5];
wire       joy_swap = status[7] | piano;
wire [2:0] LHRom_type = status[3:1];

wire code_index = &ioctl_index;
wire code_download = ioctl_download & code_index;
wire cart_download = ioctl_download & ((ioctl_index[5:0] == 6'h01) | (ioctl_index[7:0] == 0));
wire spc_download = ioctl_download & ioctl_index[5:0] == 6'h04;
wire msu_audio_download = ioctl_download & ioctl_index[5:0] == 6'h02;
wire msu_data_download  = ioctl_download & ioctl_index[5:0] == 6'h03;
wire ssbin_download = ioctl_download & ((ioctl_index[5:0] == 6'h00) & (ioctl_index[7:6] == 2'd1));


reg new_vmode;
always @(posedge clk_sys) begin
	reg old_pal;
	int to;

	if(~reset) begin
		old_pal <= PAL;
		if(old_pal != PAL) to <= 2000000;
	end

	if(to) begin
		to <= to - 1;
		if(to == 1) new_vmode <= ~new_vmode;
	end
end

//////////////////////////  ROM DETECT  /////////////////////////////////

reg        PAL;
reg  [7:0] rom_type;
reg [23:0] rom_mask, ram_mask;
reg  [3:0] ram_size;
always @(posedge clk_sys) begin
	reg [3:0] rom_size;
	reg       rom_region = 0;

	if (cart_download) begin
		if(ioctl_wr) begin
			if (ioctl_addr == 0) begin
				rom_size <= 4'hC;
				ram_size <= 4'h0;
				if(!LHRom_type && ioctl_dout[7:0]) {ram_size,rom_size} <= ioctl_dout[7:0];

				case(LHRom_type)
					1: rom_type <= 0;
					2: rom_type <= 0;
					3: rom_type <= 1;
					4: rom_type <= 2;
					default: rom_type <= ioctl_dout[15:8];
				endcase
			end

			if (ioctl_addr == 2) begin
				rom_region <= ioctl_dout[8];
			end

			if(LHRom_type == 2) begin
				if(ioctl_addr == ('h7FD6+'h200)) rom_size <= ioctl_dout[11:8];
				if(ioctl_addr == ('h7FD8+'h200)) ram_size <= ioctl_dout[3:0];
			end
			else if(LHRom_type == 3) begin
				if(ioctl_addr == ('hFFD6+'h200)) rom_size <= ioctl_dout[11:8];
				if(ioctl_addr == ('hFFD8+'h200)) ram_size <= ioctl_dout[3:0];
			end
			else if(LHRom_type == 4) begin
				if(ioctl_addr == ('h40FFD6+'h200)) rom_size <= ioctl_dout[11:8];
				if(ioctl_addr == ('h40FFD8+'h200)) ram_size <= ioctl_dout[3:0];
			end

			rom_mask <= (24'd1024 << rom_size) - 1'd1;
			ram_mask <= ram_size ? (24'd1024 << ram_size) - 1'd1 : 24'd0;
		end
	end
	else begin
		PAL <= (!status[15:14]) ? rom_region : status[15];
	end
end

reg spc_mode = 0;
always @(posedge clk_sys) begin
	if(ioctl_wr) begin
		spc_mode <= spc_download;
	end
end

reg osd_btn = 0;
reg status0_fall = 0;
always @(posedge clk_sys) begin
	integer timeout = 0;
	reg     has_bootrom = 0;
	reg     last_rst = 0;
	reg     old_status0;

	if (RESET) last_rst <= 0;
	if (status[0]) last_rst <= 1;

	if (cart_download & ioctl_wr & status[0]) has_bootrom <= 1;

	if(last_rst & ~status[0]) begin
		osd_btn <= 0;
		if(timeout < 24000000) begin
			timeout <= timeout + 1;
			osd_btn <= ~has_bootrom;
		end
	end

	old_status0 <= status[0];
	status0_fall <= old_status0 & ~status[0];
end

////////////////////////////  SYSTEM  ///////////////////////////////////

wire GSU_ACTIVE;
wire turbo_allow;
wire SNES_SYSCLKR_CE,SNES_SYSCLKF_CE;
wire SNES_REFRESH;

wire ss_avail;
wire ss_ddr_ack, ss_ddr_req, ss_ddr_we;
wire [63:0] ss_ddr_dout, ss_ddr_din;
wire [21:3] ss_ddr_addr;
wire [ 7:0] ss_ddr_be;

reg [15:0] main_audio_l;
reg [15:0] main_audio_r;

// Phase 1: Mode 7 register wires (outputs from main, available for hps_ext in Phase 2)
wire [15:0] m7a_out, m7b_out, m7c_out, m7d_out;
wire [12:0] m7x_out, m7y_out, m7hofs_out, m7vofs_out;
wire [7:0]  m7sel_out;

// Phase 2 Task 2.1: HD Mode 7 Line Buffer wires
wire [8:0]  x_out;
wire        frame_out;      // PPU BG strobe — NOT a frame boundary (unused, see M7 block)
wire [23:0] hd_pixel_in;
wire        hd_pixel_opaque;
wire        hd_px_valid;
wire        hd_line_armed;
wire        vblank_out;     // PPU IN_VBL — true vblank level (frame boundary)
`ifdef M7_2X_ENABLE
// VRAM resync-dump address mux (drives the vram1/vram2 port-B mux below;
// port B is the PPU fetch port, idle during vblank when dumps run).
// Each plane's port B is hijacked only while that plane is being dumped.
wire        dump_a_p1, dump_a_p2;
wire [14:0] dump_addr;
`endif

`ifdef M7_2X_ENABLE
// HD scale is fixed at 4x (hd_mode7_linebuf timing + daemon pixel buffer
// layout are validated at this rate; see rtl/m7_abi.svh).
localparam [3:0] m7_scale_wire = M7_HD_SCALE;

assign M7_SCALE       = m7_scale_wire;
assign HD_PIXEL_VALID = hd_px_valid;
assign HD_PIXEL_IN    = hd_pixel_in;
assign HD_PIXEL_OPAQUE = hd_pixel_opaque;
assign HD_LINE_ARMED  = hd_line_armed;

// HD scanline buffer (v4, 2-slot row ping-pong, 8bpp + CLUT). Port A
// (clk_sys) is written by the fetch FSM — always the slot NOT being
// displayed (the writer parks at row boundaries so a row never straddles
// a slot swap). One CLUT index byte per NATIVE pixel: a row is 32 DDR3
// words (~18 us), so the sweep refreshes every displayed line. Port B
// (clk_video) reads one pixel per HD_PX_STROBE and expands through the
// CLUT (loaded from the PPU CGRAM shadow by the loader below). The parent
// swaps slots at hde falls (arm block below) and arms at hde rise only
// for lines whose row was fetched (line_hd_in) — others fall back native.
reg        act = 1'b0;                  // slot the linebuf displays
wire       m7_wr_slot = ~act;           // the fetch FSM fills the other one
hd_mode7_linebuf linebuf (
    .clk_mem(clk_sys),
    .clk_vid(CLK_VIDEO),
    .buf_wr_addr(buf_wr_addr),
    .buf_wr_data(buf_wr_data),
    .buf_wr_slot(m7_wr_slot),
    .buf_wr_en(buf_wr_en),
    .clut_wr_addr(cgram_mirror_addr),
    .clut_wr_data(cgram_mirror_q),
    .clut_wr_en(clut_wr_en),
    .hde_in(HBlank_out),        // PPU HDE — active-high display enable
    .line_hd_in(m7_line_hd),
    .px_strobe(HD_PX_STROBE),
    .fetch_en(m7_fetch_en),
    .rd_slot(act),
    .hd_pixel_out(hd_pixel_in),
	.hd_pixel_opaque(hd_pixel_opaque),
    .hd_px_valid(hd_px_valid),
    .hd_line_armed(hd_line_armed)
);
`else
// HD Mode 7 is compiled out so the design fits the 553 M10K block
// budget. sys_top's scaler runs at 1x (one output pixel per native ce_pix),
// and the HD overlay / pixel path are forced off.
assign M7_SCALE       = 4'd1;
assign HD_PIXEL_VALID = 1'b0;
assign HD_PIXEL_IN    = 24'd0;
assign HD_PIXEL_OPAQUE = 1'b0;
assign HD_LINE_ARMED  = 1'b0;
assign hd_pixel_in    = 24'd0;
assign hd_pixel_opaque = 1'b0;
assign hd_px_valid    = 1'b0;
`endif

wire [8:0] ppu_x;
wire [8:0] ppu_y;

main main
(
	.RESET_N(RESET_N),

	.MCLK(clk_sys), // 21.47727 / 21.28137
	.ACLK(clk_sys),

	.GSU_ACTIVE(GSU_ACTIVE),
	.GSU_TURBO(GSU_TURBO),
	.GSU_FASTROM(GSU_FASTROM),
	.SUFAMI_SWAP(SUFAMI_SWAP),
	.CC_DIP({4'b0001,CC_TIME}),
	
	.SYSCLKR_CE(SNES_SYSCLKR_CE),
	.SYSCLKF_CE(SNES_SYSCLKF_CE),
	.REFRESH(SNES_REFRESH),

	.ROM_TYPE(rom_type),
	.ROM_MASK(rom_mask),
	.RAM_MASK(ram_mask),
	.RAM_SIZE(ram_size),
	.PAL(PAL),
	.BLEND(BLEND),

	.ROM_ADDR(ROM_ADDR),
	.ROM_D(ROM_D),
	.ROM_Q(ROM_Q),
	.ROM_OE_N(ROM_OE_N),
	.ROM_WE_N(ROM_WE_N),
	.ROM_WORD(ROM_WORD),

	.BSRAM_ADDR(BSRAM_ADDR),
	.BSRAM_D(BSRAM_D),			
	.BSRAM_Q(BSRAM_Q),			
	.BSRAM_CE_N(BSRAM_CE_N),
	.BSRAM_OE_N(BSRAM_OE_N),
	.BSRAM_WE_N(BSRAM_WE_N),

	.WRAM_ADDR(WRAM_ADDR),
	.WRAM_D(WRAM_D),
	.WRAM_Q(WRAM_Q),
	.WRAM_CE_N(WRAM_CE_N),
	.WRAM_OE_N(WRAM_OE_N),
	.WRAM_WE_N(WRAM_WE_N),

	.VRAM1_ADDR(VRAM1_ADDR),
	.VRAM1_DI(VRAM1_Q),
	.VRAM1_DO(VRAM1_D),
	.VRAM1_WE_N(VRAM1_WE_N),
	.VRAM1_ADDR_B(VRAM1_ADDR_B),
	.VRAM1_DI_B(VRAM1_Q_B),

	.VRAM2_ADDR(VRAM2_ADDR),
	.VRAM2_DI(VRAM2_Q),
	.VRAM2_DO(VRAM2_D),
	.VRAM2_WE_N(VRAM2_WE_N),
	.VRAM2_ADDR_B(VRAM2_ADDR_B),
	.VRAM2_DI_B(VRAM2_Q_B),
	.VRAM_OE_N(VRAM_OE_N),

	.ARAM_ADDR(ARAM_ADDR),
	.ARAM_D(ARAM_D),
	.ARAM_Q(ARAM_Q),
	.ARAM_CE_N(ARAM_CE_N),
	.ARAM_WE_N(ARAM_WE_N),

	.R(R_out),
	.G(G_out),
	.B(B_out),

	.FIELD(FIELD),
	.INTERLACE(INTERLACE),
	.HIGH_RES(HIGH_RES),
	.V224_MODE(V224_MODE),
	.DOTCLK(DOTCLK_out),
	
	.HBLANKn(HBlank_out),
	.VBLANKn(VBlank_out),
	.VBLANK_OUT(vblank_out),
	.HSYNC(HSYNC_out),
	.VSYNC(VSYNC_out),

	.JOY1_DI(JOY1_DI),
	.JOY2_DI(GUN_MODE ? LG_DO : JOY2_DI),
	.JOY_STRB(JOY_STRB),
	.JOY1_CLK(JOY1_CLK),
	.JOY2_CLK(JOY2_CLK),
	.JOY1_P6(JOY1_P6),
	.JOY2_P6(JOY2_P6),
	.JOY2_P6_in(JOY2_P6_DI),
	.SNI_JOY(SNI_JOY),

	.EXT_RTC(RTC),

	.GG_EN(status[24]),
	.GG_CODE(gg_code),
	.GG_RESET((code_download && ioctl_wr && !ioctl_addr) || cart_download),
	.GG_AVAILABLE(gg_available),
	
	.SPC_MODE(spc_mode),

	.IO_ADDR(ioctl_addr[16:0]),
	.IO_DAT(ioctl_dout),
	.IO_WR(spc_download & ioctl_wr),
	
	.TURBO(status[4] & turbo_allow),
	.TURBO_ALLOW(turbo_allow),
	
	.DSP_FREQ(status[30]),
	
`ifdef DEBUG
	.DBG_BG_EN(DBG_BG_EN),
	.DBG_CPU_EN(DBG_CPU_EN),
`else
	.DBG_BG_EN(5'b11111),
	.DBG_CPU_EN(1'b1),
`endif

	.M7_HD(M7_HD),

	// Phase 1: Mode 7 register outputs (captured here; wired to hps_ext in Phase 2)
	.M7A_OUT(m7a_out),
	.M7B_OUT(m7b_out),
	.M7C_OUT(m7c_out),
	.M7D_OUT(m7d_out),
	.M7X_OUT(m7x_out),
	.M7Y_OUT(m7y_out),
	.M7HOFS_OUT(m7hofs_out),
	.M7VOFS_OUT(m7vofs_out),
	.M7SEL_OUT(m7sel_out),

	// HD pixel ports are unused inside the PPU now (the overlay moved to
	// sys_top); the inputs stay tied off for port compatibility.
	.HD_PIXEL_IN(24'd0),
	.HD_MODE7_EN(1'b0),

	// Phase C.1: CGRAM shadow read port
	.CGRAM_MIRROR_ADDR(cgram_mirror_addr),
	.CGRAM_MIRROR_Q(cgram_mirror_q),

	// Phase 2: PPU rendering signals for line buffer sync
	.X_OUT(x_out),
	.FRAME_OUT(frame_out),

	// MSU register handling
	.MSU_TRACK_NUM(msu_track_num),
	.MSU_TRACK_REQUEST(msu_track_request),
	.MSU_TRACK_MOUNTING(msu_track_mounting),
	.MSU_TRACK_MISSING(msu_track_missing),
	.MSU_VOLUME(msu_volume),
	.MSU_AUDIO_REPEAT(msu_audio_repeat),
	.MSU_AUDIO_RESUME(msu_audio_resume),
	.MSU_AUDIO_STOP(msu_audio_stop),
	.MSU_AUDIO_PLAYING(msu_audio_playing),
	.MSU_AUDIO_SECTOR(msu_audio_sector),
	.MSU_RESUME_SECTOR(msu_resume_sector),
	.MSU_DATA_ADDR(msu_data_addr),
	.MSU_DATA(msu_data),
	.MSU_DATA_ACK(msu_data_ack),
	.MSU_DATA_SEEK(msu_data_seek),
	.MSU_DATA_REQ(msu_data_req),
	.MSU_ENABLE(msu_enable),

	.SS_SAVE(ss_save),
	.SS_TOSD(~status[50]),
	.SS_LOAD(ss_load),
	.SS_SLOT(ss_slot),
	.SS_AVAIL(ss_avail),

	.SS_DDR_DI(ss_ddr_dout),
	.SS_DDR_ACK(ss_ddr_ack),
	.SS_DDR_DO(ss_ddr_din),
	.SS_DDR_ADDR(ss_ddr_addr),
	.SS_DDR_WE(ss_ddr_we),
	.SS_DDR_BE(ss_ddr_be),
	.SS_DDR_REQ(ss_ddr_req),

	.AUDIO_L(main_audio_l),
	.AUDIO_R(main_audio_r),

	// Phase 1 Task 1.3: raw electron-gun counters from PPU (via main)
	.HCOUNT_OUT(ppu_x),
	.VCOUNT_OUT(ppu_y)
);

assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;

reg RESET_N = 0;
reg RESET_REFRESH = 0;
always @(posedge clk_sys) begin
	reg [1:0] div;
	
	div <= div + 1'd1;
	RESET_REFRESH <= !div;
	
	if (div == 2) RESET_N <= ~reset;
end

////////////////////////////  CODES  ///////////////////////////////////

reg [128:0] gg_code;
wire gg_available;

// Code layout:
// {clock bit, code flags,     32'b address, 32'b compare, 32'b replace}
//  128        127:96          95:64         63:32         31:0
// Integer values are in BIG endian byte order, so it up to the loader
// or generator of the code to re-arrange them correctly.

always_ff @(posedge clk_sys) begin
	gg_code[128] <= 0;

	if (code_download & ioctl_wr) begin
		case (ioctl_addr[3:0])
			0:  gg_code[111:96]  <= ioctl_dout; // Flags Bottom Word
			2:  gg_code[127:112] <= ioctl_dout; // Flags Top Word
			4:  gg_code[79:64]   <= ioctl_dout; // Address Bottom Word
			6:  gg_code[95:80]   <= ioctl_dout; // Address Top Word
			8:  gg_code[47:32]   <= ioctl_dout; // Compare Bottom Word
			10: gg_code[63:48]   <= ioctl_dout; // Compare top Word
			12: gg_code[15:0]    <= ioctl_dout; // Replace Bottom Word
			14: begin
				gg_code[31:16]    <= ioctl_dout; // Replace Top Word
				gg_code[128]      <= 1;          // Clock it in
			end
		endcase
	end
end

////////////////////////////  MEMORY  ///////////////////////////////////

reg [17:0] mem_fill_addr;
reg clearing_ram = 0;
reg mem_fill_wait;
always @(posedge clk_sys) begin
	if(~old_downloading & cart_download)
		clearing_ram <= 1'b1;

	if (&mem_fill_addr) clearing_ram <= 0;

	if (clearing_ram) begin
		mem_fill_wait <= ~mem_fill_wait;
		if (mem_fill_wait) 
			mem_fill_addr <= mem_fill_addr + 1'b1;
	end else begin
		mem_fill_addr <= 0;
		mem_fill_wait <= 0;
	end
end
wire mem_fill_we = clearing_ram & ~mem_fill_wait;

reg [7:0] wram_fill_data;
always @* begin
    case(status[22:21])
        0: wram_fill_data = (mem_fill_addr[8] ^ mem_fill_addr[2]) ? 8'h66 : 8'h99;
        1: wram_fill_data = (mem_fill_addr[9] ^ mem_fill_addr[0]) ? 8'hFF : 8'h00;
        2: wram_fill_data = 8'h55;
        3: wram_fill_data = 8'hFF;
    endcase
end

reg [7:0] aram_fill_data;
always @* begin
    case(status[45:44])
        0: aram_fill_data = (mem_fill_addr[8] ^ mem_fill_addr[2]) ? 8'h66 : 8'h99;
        1: aram_fill_data = (mem_fill_addr[9] ^ mem_fill_addr[0]) ? 8'hFF : 8'h00;
        2: aram_fill_data = 8'h55;
        3: aram_fill_data = 8'hFF;
    endcase
end

wire[23:0] ROM_ADDR;
wire       ROM_OE_N;
wire       ROM_WE_N;
wire       ROM_WORD;
wire[15:0] ROM_D;
wire[15:0] ROM_Q;

wire[16:0] WRAM_ADDR;
wire       WRAM_CE_N;
wire       WRAM_OE_N;
wire       WRAM_WE_N;
wire [7:0] WRAM_Q, WRAM_D;

wire[24:0]  SDRAM_SNI_ADDR;
wire[7:0]   SDRAM_SNI_DATA;
wire[7:0]   SDRAM_SNI_Q;
wire        SDRAM_SNI_RD;
wire        SDRAM_SNI_WR;
wire        SDRAM_SNI_READY;

wire[24:0] cart_addr_download = ioctl_addr-10'd512;
wire[23:0] ssbin_addr_download = { 8'hFF, ioctl_addr[15:0] };
wire[23:0] addr_download = ssbin_download ? ssbin_addr_download : cart_addr_download[23:0];

wire       sdram_download = cart_download | ssbin_download;

reg [23:0] sdram_download_addr;
reg [15:0] sdram_download_data;
reg        sdram_download_wr;
reg        sdram_download_en;
always @(posedge clk_mem) begin
	sdram_download_addr <= addr_download;
	sdram_download_data <= ioctl_dout;
	sdram_download_wr <= ioctl_wr;
	sdram_download_en <= sdram_download;
end

reg READ_PULSE;
always @(posedge clk_sys)
	READ_PULSE <= SNES_SYSCLKR_CE;

wire [15:0] sdr_dout1, sdr_sni_dout;
sdram sdram
(
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_A(SDRAM_A),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE),

	.init(0), //~clock_locked),
	.clk(clk_mem),
	
	.addr0(sdram_download_en ? sdram_download_addr : ROM_ADDR),
	.din0(sdram_download_en ? sdram_download_data : ROM_D),
	.dout0(ROM_Q),

	.rd0(sdram_download_en ? 1'b0 : !RESET_N ? RESET_REFRESH : ~ROM_OE_N),
	.wr0(sdram_download_en ? sdram_download_wr : ~ROM_WE_N),
	.word0(sdram_download_en | ROM_WORD),

	.addr1(clearing_ram ? {7'b0000000,mem_fill_addr} : {7'b0000000,WRAM_ADDR}),
	.din1(clearing_ram ? {8'h00,wram_fill_data} : {8'h00,WRAM_D}),

	.dout1(sdr_dout1),

	.rd1(clearing_ram ? 1'b0 : ~WRAM_CE_N & ~WRAM_OE_N & READ_PULSE),
	.wr1(clearing_ram ? mem_fill_we : ~WRAM_CE_N & ~WRAM_WE_N & SNES_SYSCLKF_CE),
	.rfs1(clearing_ram ? 1'b0 : !RESET_N ? RESET_REFRESH : SNES_REFRESH),
	.word1(0),

	.sni_addr(SDRAM_SNI_ADDR),
	.sni_din({8'h00,SDRAM_SNI_DATA}),
	.sni_dout(sdr_sni_dout),
	.sni_rd_req(SDRAM_SNI_RD),
	.sni_wr_req(SDRAM_SNI_WR),
	.sni_ready(SDRAM_SNI_READY),
	.sni_word(0)
);

assign WRAM_Q = sdr_dout1[7:0];
assign SDRAM_SNI_Q = sdr_sni_dout[7:0];

wire        VRAM_OE_N;
reg         VRAM_OE_N_DELAYED;
always @(posedge clk_sys)
	VRAM_OE_N_DELAYED <= VRAM_OE_N;
	
wire [15:0] VRAM1_ADDR;
wire        VRAM1_WE_N;
wire  [7:0] VRAM1_D;
wire  [7:0] vram1_q;
wire [15:0] VRAM1_ADDR_B;
wire  [7:0] VRAM1_Q_B;

dpram #(15)	vram1
(
	.clock(clk_sys),
	.address_a(VRAM1_ADDR[14:0]),
	.data_a(VRAM1_D),
	.wren_a(~VRAM1_WE_N),
	.q_a(vram1_q),

	// clear the RAM on loading, resync-dump during vblank, else route port B.
	// The dump muxes the PPU fetch port (idle during vblank) so CPU port-A
	// accesses are never delayed.
	.address_b(dump_a_p1 ? dump_addr :
	           clearing_ram ? mem_fill_addr[14:0] : VRAM1_ADDR_B[14:0]),
	.wren_b(mem_fill_we),
	.q_b(VRAM1_Q_B)
);
wire  [7:0] VRAM1_Q = !VRAM_OE_N && !VRAM_OE_N_DELAYED ? vram1_q : '1;

wire [15:0] VRAM2_ADDR;
wire        VRAM2_WE_N;
wire  [7:0] VRAM2_D;
wire  [7:0] vram2_q;
wire [15:0] VRAM2_ADDR_B;
wire  [7:0] VRAM2_Q_B;

dpram #(15) vram2
(
	.clock(clk_sys),
	.address_a(VRAM2_ADDR[14:0]),
	.data_a(VRAM2_D),
	.wren_a(~VRAM2_WE_N),
	.q_a(vram2_q),

	// clear the RAM on loading, resync-dump during vblank, else route port B
	// (dump hijacks port B only while plane 2 is being dumped)
	.address_b(dump_a_p2 ? dump_addr :
	           clearing_ram ? mem_fill_addr[14:0] : VRAM2_ADDR_B[14:0]),
	.wren_b(mem_fill_we),
	.q_b(VRAM2_Q_B)
);
wire  [7:0] VRAM2_Q = !VRAM_OE_N && !VRAM_OE_N_DELAYED ? vram2_q : '1; 

// ===========================================================================
// CGRAM shadow read port for the DDR3 copy FSM.
//
// VRAM has no shadow mirror any more: VRAM reaches DDR3 through write-through
// snooping of the CPU write strobes (~VRAM1_WE_N / ~VRAM2_WE_N) plus a full
// resync dump muxed onto the real VRAM port B during vblank when needed
// (see the M7 engine block below). That removes 32 M10K blocks versus the
// old mirror design.
//
// CGRAM keeps its PPU-side shadow (CGRAM_SHADOW inside PPU.vhd, which now
// snoops BOTH write ports) and only the sequential read port is exposed
// here for the copy FSM. With M7_2X_ENABLE off it is tied low.
// ===========================================================================
reg [7:0]  cgram_mirror_addr;

`ifndef M7_2X_ENABLE
always @(*) begin
    cgram_mirror_addr = 8'd0;
end
`endif
wire [14:0] cgram_mirror_q;

wire [15:0] ARAM_ADDR;
wire        ARAM_CE_N;
wire        ARAM_WE_N;
wire  [7:0] ARAM_Q, ARAM_D;
dpram_dif #(16,8,15,16) aram
(
	.clock(clk_sys),
	.address_a(ARAM_ADDR),
	.data_a(ARAM_D),
	.wren_a(~ARAM_CE_N & ~ARAM_WE_N),
	.q_A(ARAM_Q),

	// clear the RAM on loading
	.address_b(spc_download ? addr_download[15:1] : mem_fill_addr[15:1]),
	.data_b(spc_download ? ioctl_dout : {2{aram_fill_data}}),
	.wren_b(spc_download ? ioctl_wr : mem_fill_we)
);

localparam  BSRAM_BITS = 18; // 256Kbyte
wire [19:0] BSRAM_ADDR;
wire        BSRAM_CE_N;
wire        BSRAM_OE_N, BSRAM_WE_N;
wire  [7:0] BSRAM_Q, BSRAM_D;
wire [19:0] BSRAM_SNI_ADDR;
wire        BSRAM_SNI_WR;
wire [7:0]  BSRAM_SNI_D;
wire        BSRAM_SNI_READY = BSRAM_CE_N | (BSRAM_OE_N & BSRAM_WE_N);

dpram_dif #(BSRAM_BITS,8,BSRAM_BITS-1,16) bsram 
(
	.clock(clk_sys),

	//Thrash the BSRAM upon ROM loading
	.address_a(clearing_ram ? mem_fill_addr[BSRAM_BITS-1:0] : BSRAM_SNI_READY ? BSRAM_SNI_ADDR : BSRAM_ADDR[BSRAM_BITS-1:0]),
	.data_a(clearing_ram ? 8'hFF : BSRAM_SNI_READY ? BSRAM_SNI_D : BSRAM_D),
	.wren_a(clearing_ram ? mem_fill_we : BSRAM_SNI_READY ? BSRAM_SNI_WR : ~BSRAM_WE_N),
	.q_a(BSRAM_Q),

	.address_b({sd_lba[BSRAM_BITS-10:0],sd_buff_addr}),
	.data_b(sd_buff_dout),
	.wren_b(sd_buff_wr & sd_ack),
	.q_b(sd_buff_din)
);

////////////////////////////  VIDEO  ////////////////////////////////////

wire [7:0] R_out,G_out,B_out;
wire HSYNC_out;
wire VSYNC_out;
wire HBlank_out;
wire VBlank_out;
wire DOTCLK_out;

always @(posedge clk_sys) begin
	DOTCLK <= DOTCLK_out;
	if(DOTCLK ^ DOTCLK_out) begin
		R <= R_out;
		G <= G_out;
		B <= B_out;
		HSYNC  <= HSYNC_out;
		VSYNC  <= VSYNC_out;
		HBlank <= ~HBlank_out;
		VBlank <= ~VBlank_out;
	end
end

reg  [7:0] R,G,B;
wire FIELD,INTERLACE;
reg  HSync, HSYNC;
reg  VSync, VSYNC;
reg  HBlank;
reg  VBlank;
wire HIGH_RES,V224_MODE;
reg  DOTCLK;

reg interlace;
reg ce_pix;
always @(posedge CLK_VIDEO) begin
	reg [2:0] pcnt;
	reg old_vsync;
	reg tmp_hres, frame_hres;
	reg old_dotclk;
	
	if(~HBlank & ~VBlank) tmp_hres <= tmp_hres | HIGH_RES;

	old_vsync <= VSync;
	if(~old_vsync & VSync) begin
		frame_hres <= (tmp_hres | ~scandoubler) & ~status[42];
		tmp_hres <= 0;
		interlace <= INTERLACE;
	end

	pcnt <= pcnt + 1'd1;
	old_dotclk <= DOTCLK;
	if(~old_dotclk & DOTCLK & ~HBlank & ~VBlank) pcnt <= 1;

	ce_pix <= !pcnt[1:0] & (frame_hres | ~pcnt[2]);
	
	if(pcnt==3) {HSync, VSync} <= {HSYNC, VSYNC};
end

assign VGA_F1 = interlace & FIELD;
assign VGA_SL = {~interlace,~interlace}&sl[1:0];

wire [2:0] scale = status[11:9];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;
wire       scandoubler = ~interlace && (scale || forced_scandoubler);

video_mixer #(.LINE_LENGTH(520), .GAMMA(1)) video_mixer
(
	.*,
	.hq2x(scale==1),
	.freeze_sync(),
	.VGA_DE(vga_de),
	.R((LG_TARGET && GUN_MODE && (!status[29] | LG_T)) ? {8{LG_TARGET[0]}} : R),
	.G((LG_TARGET && GUN_MODE && (!status[29] | LG_T)) ? {8{LG_TARGET[1]}} : G),
	.B((LG_TARGET && GUN_MODE && (!status[29] | LG_T)) ? {8{LG_TARGET[2]}} : B)
);

////////////////////////////  I/O PORTS  ////////////////////////////////

assign {UART_RTS, UART_DTR} = 1;

wire uart_txd_core;
`ifdef M7_2X_ENABLE
// HD Mode 7 build: UART_TXD carries the m7_reg_stream FPGA->ARM channel
// (sys_top routes the core's UART_TXD to the HPS UART1 controller ->
// /dev/ttyS1) instead of the Miracle Piano uart below (idle unless
// uart_mode=3). The piano/SNI uart still runs; only its pin is muted.
wire m7_dbg_tx;
assign UART_TXD = m7_dbg_tx;
`else
assign UART_TXD = uart_txd_core;
`endif

wire piano = status[43] & (uart_mode == 3);
reg last_piano = 1'b0;
always @(posedge clk_sys) last_piano <= piano;
reg piano_tdata_i;
reg sni_tdata_i;
wire [15:0] piano_data_i;
wire [15:0] sni_data_i;
wire [15:0] data_o;
wire rbf;
wire txint;
wire rxint;

uart uart(
	.clk(clk_sys),
	.reset(reset || (piano ^ last_piano)),
	.midi_speed_sel(piano),
	.tdata_i(piano ? piano_tdata_i : sni_tdata_i),
	.data_i(piano ? piano_data_i : sni_data_i),
	.data_o(data_o),
	.uartbrk(1'b0),//reset),
	.rbfmirror(rbf),
	.txint(txint),
	.rxint(rxint),
	.txd(uart_txd_core),
	.rxd(UART_RXD)
);

wire piano_joypad_do;
miraclepiano miracle(
	.clk(clk_sys),
	.reset(reset || !piano),
	.strobe(JOY_STRB),
	.joypad_o(piano_joypad_do),
	.joypad_clock(JOY1_CLK),
	.txint(txint),
	.rxint(rxint),
	.tdata_i(piano_tdata_i),
	.tdata_m(piano_data_i),
	.rdata_m(data_o)
);

wire [63:0] SNI_JOY;
sni sni(
	.clk(clk_sys),
	.reset(reset || uart_mode != 6),
	.vblank(VBlank),

	.sdram_addr(SDRAM_SNI_ADDR),
	.sdram_data(SDRAM_SNI_DATA),
	.sdram_q(SDRAM_SNI_Q),
	.sdram_rd_req(SDRAM_SNI_RD),
	.sdram_wr_req(SDRAM_SNI_WR),
	.sdram_ready(SDRAM_SNI_READY),

	.bsram_addr(BSRAM_SNI_ADDR),
	.bsram_q(BSRAM_Q),
	.bsram_wr(BSRAM_SNI_WR),
	.bsram_data(BSRAM_SNI_D),
	.bsram_ready(BSRAM_SNI_READY),

	.joypad(SNI_JOY),

	.rbf(rbf),
	.txint(txint),
	.rxint(rxint),
	.tdata_i(sni_tdata_i),
	.tdata_m(sni_data_i),
	.rdata_m(data_o)
);
wire [1:0] JOY1_DO = piano ? {1'b1,piano_joypad_do} : JOY1_DO_t;

wire       JOY_STRB;

wire [1:0] JOY1_DO_t;
wire       JOY1_CLK;
wire       JOY1_P6;
ioport port1
(
	.CLK(clk_sys),

	.PORT_LATCH(JOY_STRB),
	.PORT_CLK(JOY1_CLK),
	.PORT_P6(JOY1_P6),
	.PORT_DO(JOY1_DO_t),

	.JOYSTICK1((joy_swap ^ raw_serial) ? joy1 : joy0),
	.JOYSTICK1_RUMBLE(joystick1_rumble),

	.MOUSE(ps2_mouse),
	.MOUSE_EN(mouse_mode[0])
);

wire [1:0] JOY2_DO;
wire       JOY2_CLK;
wire       JOY2_P6;
ioport port2
(
	.CLK(clk_sys),

	.MULTITAP(status[17]),

	.PORT_LATCH(JOY_STRB),
	.PORT_CLK(JOY2_CLK),
	.PORT_P6(JOY2_P6),
	.PORT_DO(JOY2_DO),

	.JOYSTICK1((joy_swap ^ raw_serial) ? joy0 : joy1),
	.JOYSTICK2(joy2),
	.JOYSTICK3(joy3),
	.JOYSTICK4(joy4),

	.MOUSE(ps2_mouse),
	.MOUSE_EN(mouse_mode[1])
);

wire       LG_P6_out;
wire [1:0] LG_DO;
wire [2:0] LG_TARGET;
wire       LG_T = ((GUN_MODE[0]&joy0[6]) | (GUN_MODE[1]&joy1[6])); // always from joysticks

lightgun lightgun
(
	.CLK(clk_sys),
	.RESET(reset),

	.MOUSE(ps2_mouse),
	.MOUSE_XY(&GUN_MODE),

	.JOY_X(GUN_MODE[0] ? joy0_x : joy1_x),
	.JOY_Y(GUN_MODE[0] ? joy0_y : joy1_y),

	.F(GUN_BTN ? ps2_mouse[0] : ((GUN_MODE[0]&(joy0[4]|joy0[9]) | (GUN_MODE[1]&(joy1[4]|joy1[9]))))),
	.C(GUN_BTN ? ps2_mouse[1] : ((GUN_MODE[0]&(joy0[5]|joy0[8]) | (GUN_MODE[1]&(joy1[5]|joy0[8]))))),
	.T(LG_T), // always from joysticks
	.P(ps2_mouse[2] | ((GUN_MODE[0]&joy0[7]) | (GUN_MODE[1]&joy1[7]))), // always from joysticks and mouse

	.HDE(~HBlank),
	.VDE(~VBlank),
	.CLKPIX(DOTCLK),
	
	.TARGET(LG_TARGET),
	.SIZE(status[28]),
	.GUN_TYPE(GUN_TYPE),

	.PORT_LATCH(JOY_STRB),
	.PORT_CLK(JOY2_CLK),
	.PORT_P6(LG_P6_out),
	.PORT_DO(LG_DO)
);

// 1 [oooo|ooo) 7 - 1:+5V  2:Clk  3:Strobe   4:D0  5:D1  6: I/O  7:Gnd

// Indexes:
// IDXDIR   Function    USBPIN
// 0  OUT   Strobe      D+
// 1  OUT   Clk (P1)    D-
// 2  IN    D1          TX-
// 3  OUT   CLK (P2)    GND_d
// 4  BI    I/O         RX+
// 5  IN    P1D0        RX-
// 6  IN    P2D0        TX+

wire raw_serial = status[8];
reg snac_p2 = 0;

assign USER_OUT[2] = 1'b1;
assign USER_OUT[5] = 1'b1;
assign USER_OUT[6] = 1'b1;

// JOYX_DO[0] is P4, JOYX_DO[1] is P5
wire [1:0] JOY1_DI;
wire [1:0] JOY2_DI;
wire JOY2_P6_DI;

always @(posedge clk_sys) begin
	if (raw_serial) begin
		if (~USER_IN[6])
			snac_p2 <= 1;
	end else begin
		snac_p2 <= 0;
	end
end

always_comb begin
	if (raw_serial) begin
		USER_OUT[0] = JOY_STRB;
		USER_OUT[1] = joy_swap ? ~JOY2_CLK : ~JOY1_CLK;
		USER_OUT[3] = joy_swap ? ~JOY1_CLK : ~JOY2_CLK;
		if (snac_p2) begin
			USER_OUT[4] = joy_swap ? JOY1_P6 : JOY2_P6;
			JOY1_DI = joy_swap ? {1'b1, USER_IN[6]} : {1'b1, USER_IN[5]};
			JOY2_DI = joy_swap ? {USER_IN[2], USER_IN[5]} : {USER_IN[2], USER_IN[6]};
			JOY2_P6_DI = USER_IN[4];
		end else begin
			USER_OUT[4] = joy_swap ? JOY2_P6 : JOY1_P6;
			JOY1_DI = joy_swap ? JOY1_DO : {USER_IN[2], USER_IN[5]};
			JOY2_DI = joy_swap ? {USER_IN[2], USER_IN[5]} : JOY2_DO;
			JOY2_P6_DI = joy_swap ? USER_IN[4] : (LG_P6_out | !GUN_MODE);
		end
	end else begin
		USER_OUT[0] = 1'b1;
		USER_OUT[1] = 1'b1;
		USER_OUT[3] = 1'b1;
		USER_OUT[4] = 1'b1;
		JOY1_DI = JOY1_DO;
		JOY2_DI = JOY2_DO;
		JOY2_P6_DI = (LG_P6_out | !GUN_MODE);
	end
end

/////////////////////////  STATE SAVE/LOAD  /////////////////////////////

wire bk_save_write = ~BSRAM_CE_N & ~BSRAM_WE_N;
reg bk_pending;

always @(posedge clk_sys) begin
	if (bk_ena && ~OSD_STATUS && bk_save_write)
		bk_pending <= 1'b1;
	else if (bk_state | ~bk_ena)
		bk_pending <= 1'b0;
end

reg bk_ena = 0;
reg old_downloading = 0;
reg cart_ready = 0;
reg ssbin_ready = 0;
always @(posedge clk_sys) begin
	old_downloading <= cart_download;
	if(~old_downloading & cart_download) bk_ena <= 0;

	if(old_downloading & ~cart_download) cart_ready <= 1;

	if (ssbin_download) ssbin_ready <= 1;

	//Save file always mounted in the end of downloading state.
	if(cart_download && img_mounted && !img_readonly) bk_ena <= |ram_mask;
end

wire bk_load    = status[12];
wire bk_save    = status[13] | (bk_pending & OSD_STATUS && status[23]);
reg  bk_loading = 0;
reg  bk_state   = 0;
wire [31:0] sd_lba_end = rom_type[7:4] == 4'h2 && rom_type[3] ? {ram_mask[23:9],1'b1} : ram_mask[23:9];//For Sufami with B cart, it's double size
always @(posedge clk_sys) begin
	reg old_load = 0, old_save = 0, old_ack;

	old_load <= bk_load & bk_ena;
	old_save <= bk_save & bk_ena;
	old_ack  <= sd_ack;

	if(~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;

	if(!bk_state) begin
		if((~old_load & bk_load) | (~old_save & bk_save)) begin
			bk_state <= 1;
			bk_loading <= bk_load;
			sd_lba <= 0;
			sd_rd <=  bk_load;
			sd_wr <= ~bk_load;
		end
		if(old_downloading & ~cart_download & |img_size & bk_ena) begin
			bk_state <= 1;
			bk_loading <= 1;
			sd_lba <= 0;
			sd_rd <= 1;
			sd_wr <= 0;
		end
	end else begin
		if(old_ack & ~sd_ack) begin
			if(sd_lba >= sd_lba_end) begin
				bk_loading <= 0;
				bk_state <= 0;
			end else begin
				sd_lba <= sd_lba + 1'd1;
				sd_rd  <=  bk_loading;
				sd_wr  <= ~bk_loading;
			end
		end
	end
end

//debug
`ifdef DEBUG
reg [4:0] DBG_BG_EN = '1;
reg       DBG_CPU_EN = 1;

wire       pressed = ps2_key[9];
wire [8:0] code    = ps2_key[8:0];

always @(posedge clk_sys) begin
	reg old_state = 0;

	old_state <= ps2_key[10];

	if((ps2_key[10] != old_state) && pressed) begin
		casex(code)
			// Debug layer toggles moved off F1-F4 (which are now Alt-gated
			// savestate hotkeys) and F5 (commonly OSD-bound). Use F6-F10.
			'h00B: begin DBG_BG_EN[0] <= ~DBG_BG_EN[0]; end // F6
			'h083: begin DBG_BG_EN[1] <= ~DBG_BG_EN[1]; end // F7
			'h00A: begin DBG_BG_EN[2] <= ~DBG_BG_EN[2]; end // F8
			'h001: begin DBG_BG_EN[3] <= ~DBG_BG_EN[3]; end // F9
			'h009: begin DBG_BG_EN[4] <= ~DBG_BG_EN[4]; end // F10
			'h177: begin DBG_CPU_EN   <= ~DBG_CPU_EN;   end // Pause
		endcase
	end
end
`endif

///////////////////////////  MSU1  ///////////////////////////////////

wire msu_enable;

// EXT bus is used to communicate with the HPS for MSU functionality
wire [35:0] EXT_BUS;
hps_ext hps_ext
(
	.reset(reset),
	.clk_sys(clk_sys),
	.EXT_BUS(EXT_BUS),

	.msu_enable(msu_enable),

	.msu_track_mounting(msu_track_mounting),
	.msu_track_missing(msu_track_missing),
	.msu_track_num(msu_track_num),
	.msu_track_request(msu_track_request),

	.msu_audio_size(msu_audio_size),
	.msu_audio_ack(msu_audio_ack),
	.msu_audio_req(msu_audio_req),
	.msu_audio_seek(msu_audio_seek),
	.msu_audio_sector(msu_audio_sector),
	.msu_audio_download(msu_audio_download),

	.msu_data_base(msu_data_base)

	// The old CMD_M7_* commands (0x36-0x38) were removed: 0x36 collides with
	// the MiSTer framework's INFO query in hps_io.sv (hijacking OSD/savestate
	// info replies), and the daemon never used the HPS io bus — it works via
	// the DDR3 mailbox in the M7 block below.
);

wire        msu_track_mounting;
wire        msu_track_missing;
wire [15:0] msu_track_num;
wire        msu_track_request;
wire [31:0] msu_audio_size;

wire  [7:0] msu_volume;
wire        msu_audio_repeat;
wire        msu_audio_playing;
wire        msu_audio_stop;
wire        msu_audio_resume;

wire        msu_audio_ack;
wire        msu_audio_req;
wire        msu_audio_seek;
wire [21:0] msu_audio_sector;
wire [21:0] msu_resume_sector;

wire [15:0] msu_l;
wire [15:0] msu_r;

msu_audio msu_audio
(
	.reset(reset),

	.clk(clk_sys),
	.clk_rate(PAL ? 21281370 : 21477270),

	.ctl_volume(msu_volume),
	.ctl_stop(msu_audio_stop),
	.ctl_play(msu_audio_playing),
	.ctl_resume(msu_audio_resume),
	.ctl_repeat(msu_audio_repeat),

	.track_size(msu_audio_size),
	.track_processing(msu_track_missing | msu_track_mounting | msu_track_request),

	.audio_download(msu_audio_download),
	.audio_data(ioctl_dout),
	.audio_data_wr(ioctl_wr),

	.audio_ack(msu_audio_ack),
	.audio_sector(msu_audio_sector),
	.audio_req(msu_audio_req),
	.audio_seek(msu_audio_seek),
	.resume_sector(msu_resume_sector),

	.audio_l(msu_l),
	.audio_r(msu_r)
);

reg [15:0] audio_l, audio_r;

always @(posedge clk_sys) begin
	reg [16:0] mix_l, mix_r;

	mix_l = $signed({main_audio_l[15], main_audio_l}) + $signed({msu_l[15], msu_l});
	mix_r = $signed({main_audio_r[15], main_audio_r}) + $signed({msu_r[15], msu_r});

	audio_l <= (^mix_l[16:15]) ? {mix_l[16], {15{mix_l[15]}}} : mix_l[15:0];
	audio_r <= (^mix_r[16:15]) ? {mix_r[16], {15{mix_r[15]}}} : mix_r[15:0];
end

wire [31:0] msu_data_addr;
wire  [7:0] msu_data;
wire        msu_data_ack;
wire        msu_data_seek;
wire        msu_data_req;
wire [31:0] msu_data_base;

wire [31:3] msu_ram_addr;
wire        msu_ram_req;
wire        msu_ram_ack;
wire [63:0] msu_ram_dout;

// ===========================================================================
// Phase D: HD Mode 7 shared-memory engine (clk_sys)
//
// The ARM daemon (daemon/m7_daemon.cpp) mmaps HPS DDR3 at M7_MAILBOX_BASE
// and cooperates with this block per docs/m7_abi.md:
//   * header (magic/version/heartbeat) + per-line M7 register mailbox
//   * VRAM/CGRAM plane images, kept current by write-through + resync dumps
//   * HD pixel ping-pong buffers, fetched by the DDR3 DMA further below
//   * ctrl word (ARM -> FPGA) for frame publication and dump requests
//
// Every DDR3 write below goes through the ddram.sv 16-bit write port. Its
// wraddr is a PHYSICAL BYTE address (rtl/m7_abi.svh): 16-bit entry i of a
// region at byte base B is written at B + 2*i, i.e. {idx,1'b0} + base.
//
// A single service FSM owns the port and re-evaluates priority per write:
//   VRAM write-through > per-line mailbox > header > CGRAM copy > resync
//   dump — so the long-running copies can never delay a write-through long
//   enough to overflow its small FIFO.
// ===========================================================================

// PIVOT v2: the DDR3 mailbox writer (mb_* signals + 16-bit write port) is
// GONE — see the ddram instance comment. The only DDR3 writer is the ARM
// daemon; everything this core used to push into the mailbox now flows to
// it over the HPS UART (rtl/m7_reg_stream.sv).

`ifdef M7_2X_ENABLE
// --- Frame timing: IN_VBL rising edge is the true frame boundary ---------
reg  vbl_d;   // driven in the per-line record capture block below
wire frame_start = vblank_out & ~vbl_d;

// DEBUG (M7_DEBUG_MAILBOX): OR in a free-running ~20 Hz event so the mailbox
// writer can be validated independently of the PPU vblank chain. Production
// builds leave m7_frame_evt == frame_start.
`ifdef M7_DEBUG_MAILBOX
reg [19:0] dbg_evt_t = 20'd0;
always @(posedge clk_sys) dbg_evt_t <= dbg_evt_t + 20'd1;
wire       m7_frame_evt = frame_start | (&dbg_evt_t);
`else
wire       m7_frame_evt = frame_start;
`endif

// --- Ctrl-word readback path (DDRAM_CLK-domain DMA toggles ctrl_done) ----
reg  [31:0] m7_ctrl_data;         // captured ctrl word (quasi-static)
reg         ctrl_req = 1'b0;      // toggled once per frame
reg         ctrl_done = 1'b0;     // toggled in the DDRAM_CLK domain when valid
reg         ctrl_done_s1, ctrl_done_s2, ctrl_done_s3;
wire        ctrl_new = ctrl_done_s2 ^ ctrl_done_s3;

// --- Handshake state ------------------------------------------------------
// frame_seq is kept as a free-running heartbeat for future stream messages;
// the v1 header block (which carried it to the daemon over DDR3) is gone.
reg  [15:0] frame_seq = 16'd0;        // heartbeat
reg         cur_buf = 1'b0;           // pixel buffer the DMA reads this frame
reg         daemon_present = 1'b0;    // set on first adopted ctrl frame
reg  [15:0] last_ready_seq = 16'hFFFF;
// Telemetry counters for the UART stream (each owned by exactly one block)
reg [15:0] fs_cnt  = 16'd0;   // frame events (frame controller block)
reg [15:0] cdn_cnt = 16'd0;   // ctrl_new pulses = completed ctrl polls
reg [15:0] drt_cnt = 16'd0;   // DM_DRAIN entries = completed fetch words
reg [15:0] dout_cnt = 16'd0;  // DDRAM_DOUT_READY rising edges (any client)
reg [15:0] hde_cnt = 16'd0;   // hde falls this frame (arm block)
reg [15:0] arm_cnt = 16'd0;   // lines armed HD this frame (arm block)
// VRAM write-through versions/drop counter — bumped by the snoop below;
// their consumers move to the UART stream in P2c (kept so the snoop logic
// is already in its final shape).
reg  [15:0] vram1_ver = 16'd0, vram2_ver = 16'd0, wt_drops = 16'd0;
reg  vram1_we_d = 1'b1, vram2_we_d = 1'b1;  // WE edge detect (idle high)

// ===========================================================================
// P2c-3: VRAM resync dump + write-through records over the UART stream.
//
// The daemon sets M7_CTRL_DUMP_REQ in its ctrl word; this FSM then streams
// both VRAM planes to it as record-opcode messages on the existing record
// stream (the DDR3 dump path died with the mailbox writer):
//   0xFD [len][FD][al][ah][data...]  240-byte resync chunk (short tail at
//                                    the 32 KiB plane end), ah bit7 = plane
//   0xFC [len][FC][al][ah][data...]  same-plane consecutive write-through
//                                    run coalesced from the wt_fifo snoop
//   0xFB [5][FB][seq][wt_drops l h]  dump complete; wt_drops is the
//                                    daemon's new corruption baseline
// Port B of the plane being dumped is hijacked ONLY inside vblank (the PPU
// never fetches there) and never while a ROM load is clearing RAM; reads
// are paced by backpressure (one staged chunk max) so the dump takes ~17
// frames at the UART drain rate and the PPU never notices.
// Room policy: a record is staged only when the record FIFO can absorb it
// whole (single-pusher invariant makes that guarantee hold).
// ===========================================================================
reg         dump_active = 1'b0;
reg         dump_plane = 1'b0;      // 0 = plane 1, 1 = plane 2
reg  [15:0] dump_rd = 16'd0;        // next plane-local byte address to present
reg  [8:0]  dump_bc = 9'd0;         // bytes buffered for the in-progress chunk
reg  [7:0]  dump_seq = 8'd0;        // completed dumps (telemetry + 0xFB record)
reg         dump_pend = 1'b0;       // staged chunk awaiting the push block
reg         dstat_pend = 1'b0;      // staged 0xFB awaiting the push block
reg         dump_last = 1'b0;       // staged chunk was plane 2's tail
reg         dump_req_arm = 1'b1;    // DUMP_REQ must clear between dumps
// One-shot request flag, OWNED by the ctrl-adoption block (set inside the
// guarded adopted-word branch, cleared on dump_fire_ack). The dump FSM only
// reads it — two drivers here would be an elaboration error (see
// fetch_restart). Replaces direct ctrl_new reaction: ctrl_new pulses once
// per POLL (every frame, changed word or not), so reacting there fired
// dumps off stale/garbage captures.
reg         dump_fire = 1'b0;
reg  [21:0] dump_stall = 22'd0;     // cycles since the last staged chunk
reg  [7:0]  dp_len, dp_op, dp_b2, dp_b3;   // staged chunk header bytes
reg  [15:0] bw_cnt = 16'd0;         // DIAG: total dump_byte_win cycles ever
reg         dump_presented_d;
reg         dbuf_we;
reg  [7:0]  dbuf_wa, dbuf_wd, dbuf_ra;
reg  [7:0]  chunk_buf_q;
reg  [7:0]  chunk_buf [0:255];      // 1 M10K: decouples vblank-bounded reads
                                    // from the UART-paced record push

// write-through record staging (owned here; wt_w/version snoop stays in the
// frame-controller block below, which never touches these)
reg         wt_pend = 1'b0;
reg  [3:0]  wt_n = 4'd0;            // entries in the staged run (1..8)
reg  [3:0]  wt_base = 4'd0;         // wt_r at scan time
reg  [7:0]  wt_al, wt_ah;

wire [10:0] rec_count;              // record FIFO fill level (stream export)

// dump_bc counts PRESENTED bytes, which land one cycle after the issue the
// gate evaluates — so the window must close while bc still reads 239 to
// issue exactly 240 bytes (with `bc < 240` a 241st byte slips in, bc lands
// at 241, and stage_chunk's (bc==240 || rd_end) matches neither => the dump
// freezes forever with active=1; found via the bw_cnt=rd=bc=241 telemetry).
wire dump_byte_win = dump_active && !dump_pend && !dstat_pend &&
                     !clearing_ram && vblank_out &&
                     (dump_bc < 9'd239) && (dump_rd != 16'h8000);
// set on the first presentation of a chunk, cleared at staging: marks that
// the in-flight chunk owns partial bytes
reg chunk_active = 1'b0;
assign dump_a_p1 = dump_byte_win & ~dump_plane;
assign dump_a_p2 = dump_byte_win &  dump_plane;
assign dump_addr = dump_rd[14:0];
wire [7:0] dump_qb = dump_plane ? VRAM2_Q_B : VRAM1_Q_B;

wire [15:0] chunk_base = dump_rd - {8'd0, dump_bc};
wire dump_rd_end = (dump_rd == 16'h8000);
// staged only once the last BRAM write has landed (two-cycle read->write
// pipeline: presented_d raises the write, dbuf_we fires the array port).
// NO FIFO-room term here on purpose: staging resets dump_bc, so a blocked
// stage leaves byte_win dead (bc==240) with no retry pressure; the room
// invariant lives entirely on the push branch, and byte_win's !dump_pend
// provides the backpressure that paces the dump.
// Third term: vblank ended mid-chunk. The window is vblank-gated, so a
// chunk truncated at bc==239 sits EXACTLY on the gate's bound — the window
// can never resume (needs bc<239) and stage (needs bc==240) never fires:
// the dump wedges forever with active=1 and blocks every later dump
// (observed on device: rd=bc=bw=30239, 125 clean chunks then dead). Ship
// the truncated tail instead — the daemon accepts short chunks, and
// chunk_base = rd - bc resumes the next vblank at the right address.
wire stage_chunk = dump_active && !dump_pend && !dump_presented_d && !dbuf_we &&
                   ((dump_bc == 9'd240) ||
                    (dump_rd_end && (dump_bc != 9'd0)) ||
                    (chunk_active && !vblank_out && (dump_bc != 9'd0)));

// coalescing scan: longest prefix of wt_fifo entries that write consecutive
// addresses in the same plane (the FIFO is 8 deep, so runs cap at 8).
// Entries are {plane, addr[14:0], data[7:0]} — snoop pushes in the frame
// controller block, this block retires.
reg [23:0] wt_fifo [0:7];
reg [3:0]  wt_w = 4'd0, wt_r = 4'd0;
wire [3:0] wt_cnt = wt_w - wt_r;
wire [23:0] wt_e0 = wt_fifo[wt_r[2:0]];
wire [23:0] wt_e1 = wt_fifo[(wt_r + 4'd1) & 4'd7];
wire [23:0] wt_e2 = wt_fifo[(wt_r + 4'd2) & 4'd7];
wire [23:0] wt_e3 = wt_fifo[(wt_r + 4'd3) & 4'd7];
wire [23:0] wt_e4 = wt_fifo[(wt_r + 4'd4) & 4'd7];
wire [23:0] wt_e5 = wt_fifo[(wt_r + 4'd5) & 4'd7];
wire [23:0] wt_e6 = wt_fifo[(wt_r + 4'd6) & 4'd7];
wire [23:0] wt_e7 = wt_fifo[(wt_r + 4'd7) & 4'd7];
wire wt_c01 = (wt_e1[23] == wt_e0[23]) && (wt_e1[22:8] == wt_e0[22:8] + 15'd1);
wire wt_c12 = wt_c01 && (wt_e2[23] == wt_e1[23]) && (wt_e2[22:8] == wt_e1[22:8] + 15'd1);
wire wt_c23 = wt_c12 && (wt_e3[23] == wt_e2[23]) && (wt_e3[22:8] == wt_e2[22:8] + 15'd1);
wire wt_c34 = wt_c23 && (wt_e4[23] == wt_e3[23]) && (wt_e4[22:8] == wt_e3[22:8] + 15'd1);
wire wt_c45 = wt_c34 && (wt_e5[23] == wt_e4[23]) && (wt_e5[22:8] == wt_e4[22:8] + 15'd1);
wire wt_c56 = wt_c45 && (wt_e6[23] == wt_e5[23]) && (wt_e6[22:8] == wt_e5[22:8] + 15'd1);
wire wt_c67 = wt_c56 && (wt_e7[23] == wt_e6[23]) && (wt_e7[22:8] == wt_e6[22:8] + 15'd1);
wire [3:0] wt_run = wt_c67 ? 4'd8 :
                    wt_c56 ? 4'd7 :
                    wt_c45 ? 4'd6 :
                    wt_c34 ? 4'd5 :
                    wt_c23 ? 4'd4 :
                    wt_c12 ? 4'd3 :
                    wt_c01 ? 4'd2 : 4'd1;
// a 68-byte wt record needs 68 free slots; dump chunks (244) get their own
// tighter gate so a chunk can never be staged into a FIFO that fits only
// line-sized records
wire wt_stage = (wt_r != wt_w) && !wt_pend && (rec_count < 11'd445);

// HD fetch gating — quasi-static (changes at frame granularity at most)
wire m7_fetch_en = daemon_present;

// --- Per-line M7 register delta capture (P2c-2) ---------------------------
// hde fall ends line L's active video; at that edge the PPU registers hold
// exactly what line L rendered with (the HDMA update for L fired during the
// previous blanking). Each line is delta-encoded against the last captured
// line and pushed into the UART stream as a len-prefixed record:
//
//   [len][line][mask][lo hi]...      len includes itself
//   mask bits: 0=A 1=B 2=C 3=D 4=X 5=Y 6=HOFS 7=VOFS
//
// Line 0xFE is a per-frame full sync pushed at vblank entry: mask=0xFF, all
// eight values plus M7SEL appended (len=20). It resynchronises a daemon
// that joined late or lost a payload, and resets the delta reference on
// both sides. line 0xFF is reserved.
reg         rec_hd_d;
reg         rec_run  = 1'b0;
reg         sync_pend = 1'b0;
reg  [7:0]  rec_step;               // 8-bit: dump chunks run to step 243
reg  [7:0]  rec_len;
reg  [7:0]  rec_line_b;
reg  [7:0]  rec_mask_b;
reg  [8:0]  rec_rm;                 // walking value mask (bit8 = M7SEL)
reg         rec_wr = 1'b0;          // one-cycle push into m7_reg_stream
reg  [7:0]  rec_data;
reg  [7:0]  rec_sel_b;
// record source modes: P2c-2 line/sync deltas plus the P2c-3 VRAM records.
// rec_mode/rec_done are push-block-owned; the dump/wt emitter reads them
// for its handshakes.
localparam [1:0] RM_LINE = 2'd0, RM_DCHUNK = 2'd1, RM_DSTAT = 2'd2, RM_WT = 2'd3;
reg  [1:0]  rec_mode = RM_LINE;
reg         rec_done = 1'b0;        // one-cycle pulse at a record's last byte
reg  [7:0]  rec_ah_b;               // 3rd header byte of VRAM records
reg  [3:0]  rec_wt_base;            // staged copy of wt_base for data steps
reg  [3:0]  rec_wt_n;               // staged copy of wt_n: retire exactly the
                                    // entries this record pushed, immune to a
                                    // newer scan overwriting wt_n mid-record
reg  [15:0] rc_a, rc_b, rc_c, rc_d; // last captured line's values (reference)
reg  [12:0] rc_x, rc_y, rc_h, rc_v;
reg  [7:0]  rec_drops = 8'd0;       // records dropped for FIFO room
// Line retry stash (P2c-5): a line whose hblank edge hits while the push
// sequencer is busy or the ring is full is STASHED here and pushed at the
// first idle slot instead of being lost — measured on device, ~52/224
// lines/frame were lost this way in Mode 7-heavy scenes (every gap line
// renders with the previous line's regs: the HDMA perspective banding).
// rec_drops counts only a stash OVERWRITTEN by a newer line (a real loss);
// delivered retries are not drops.
reg         line_pend = 1'b0;
reg         p_abs = 1'b0;           // pending survived an overwrite (wt-burst
                                    // stretch): deliver it as a full-mask
                                    // ABSOLUTE record — one record repairs the
                                    // whole stretch via the daemon's gap fill
reg  [7:0]  p_line, p_mask;
reg  [15:0] rc2_a, rc2_b, rc2_c, rc2_d;
reg  [12:0] rc2_x, rc2_y, rc2_h, rc2_v;
reg  [15:0] rec_drops16 = 16'd0;    // stash overwrites (a real loss; the old
                                    // 8-bit counter wraps within one frame)
reg  [15:0] rec_retries = 16'd0;    // retry pushes delivered

wire        rec_room;

function [3:0] popcnt8(input [7:0] m);
    popcnt8 = {3'd0,m[0]} + {3'd0,m[1]} + {3'd0,m[2]} + {3'd0,m[3]}
            + {3'd0,m[4]} + {3'd0,m[5]} + {3'd0,m[6]} + {3'd0,m[7]};
endfunction

wire [7:0] cur_mask = {rc_h != m7hofs_out, rc_v != m7vofs_out,
                       rc_x != m7x_out,      rc_y != m7y_out,
                       rc_d != m7d_out,      rc_c != m7c_out,
                       rc_b != m7b_out,      rc_a != m7a_out};

// value byte selected by the walking mask; fields walk lsb-first through
// mask bits 0..7 (A,B,C,D as lo,hi 16-bit pairs; X,Y,H,VOFS as lo,hi with
// the 13-bit value right-aligned), then bit8 = M7SEL (single byte)
reg [7:0] rm_val;
always @(*) begin
    casez (rec_rm)
        9'b???????1?: rm_val = rc_a[7:0];
        9'b??????10?: rm_val = rc_a[15:8];
        9'b?????100?: rm_val = rc_b[7:0];
        9'b????1000?: rm_val = rc_b[15:8];
        9'b???10000?: rm_val = rc_c[7:0];
        9'b??100000?: rm_val = rc_c[15:8];
        9'b?1000000?: rm_val = rc_d[7:0];
        9'b10000000?: rm_val = rc_d[15:8];
        9'b000000001: rm_val = {3'b000, rc_x[7:0]};
        9'b000000010: rm_val = {5'b00000, rc_x[12:8]};
        9'b000000100: rm_val = {3'b000, rc_y[7:0]};
        9'b000001000: rm_val = {5'b00000, rc_y[12:8]};
        9'b000010000: rm_val = {3'b000, rc_h[7:0]};
        9'b000100000: rm_val = {5'b00000, rc_h[12:8]};
        9'b001000000: rm_val = {3'b000, rc_v[7:0]};
        9'b010000000: rm_val = {5'b00000, rc_v[12:8]};
        9'b100000000: rm_val = rec_sel_b;
        default:      rm_val = 8'h00;
    endcase
end

// Record payload byte at each step. Common header: [len][opcode][b2] with
// [b3] appended for the VRAM records; the tail is mode-specific.
wire [7:0] rec_mode_data =
    (rec_mode == RM_LINE)   ? rm_val :
    (rec_mode == RM_DCHUNK) ? chunk_buf_q :
    (rec_mode == RM_DSTAT)  ? ((rec_step == 8'd4) ? wt_drops[15:8] : rec_ah_b) :
                              wt_fifo[(rec_wt_base[2:0] + rec_step[2:0] + 3'd4)][7:0];

// Record push sequencer (sole driver of rec_wr). Pushes are 1 byte/cycle.
// Priority: per-frame sync > line retry > per-line delta (render-critical)
// > dump chunk > dump status > write-through run. A line whose edge hits
// while the sequencer is busy or the ring is full is STASHED (line_pend)
// and pushed at the first idle slot; only a stash overwritten by a newer
// line is a real drop (the next frame's 0xFE full sync repairs the daemon);
// VRAM records are never staged without room, so they always complete once
// started.
// (vbl_d is driven here since the old shared block was deleted with the
// ml_* capture; frame_start above samples it.)
always @(posedge clk_sys) begin
    rec_wr   <= 1'b0;
    rec_done <= 1'b0;
    rec_hd_d <= HBlank_out;
    vbl_d    <= vblank_out;
    dbuf_ra  <= 8'd0;

    if (rec_run) begin
        rec_wr   <= 1'b1;
        rec_data <= (rec_step == 8'd0) ? rec_len :
                    (rec_step == 8'd1) ? rec_line_b :
                    (rec_step == 8'd2) ? rec_mask_b :
                    (rec_mode != RM_LINE && rec_step == 8'd3) ? rec_ah_b :
                    rec_mode_data;
        // hi byte of each value pair consumed one walked field (line records
        // only — the other modes don't use the mask walk)
        if (rec_mode == RM_LINE && rec_step >= 8'd4 && !rec_step[0])
            rec_rm <= (rec_rm & (rec_rm - 9'd1));
        // chunk data read: address presented at step s yields buf[s-3] one
        // cycle later, which is exactly the byte pushed at step s
        if (rec_mode == RM_DCHUNK)
            dbuf_ra <= rec_step - 8'd3;
        rec_step <= rec_step + 8'd1;
        if (rec_step == rec_len - 8'd1) begin
            rec_run  <= 1'b0;
            rec_done <= 1'b1;
        end
        // Edge catch while a record is mid-push: the live capture branch is
        // unreachable this cycle, so stash the line for the retry push.
        if (~HBlank_out & rec_hd_d && !vblank_out && (ppu_y < 9'd224) &&
                cur_mask != 8'd0) begin
            p_line  <= ppu_y[7:0];
            p_mask  <= cur_mask;
            rc2_a <= m7a_out;    rc2_b <= m7b_out;
            rc2_c <= m7c_out;    rc2_d <= m7d_out;
            rc2_x <= m7x_out;    rc2_y <= m7y_out;
            rc2_h <= m7hofs_out; rc2_v <= m7vofs_out;
            rec_drops   <= line_pend ? (rec_drops + 8'd1) : rec_drops;
            rec_drops16 <= line_pend ? (rec_drops16 + 16'd1) : rec_drops16;
            p_abs       <= line_pend;   // overwrite => burst stretch => absolute
            line_pend   <= 1'b1;
        end
    end else if (sync_pend || frame_start) begin
        sync_pend  <= 1'b0;
        line_pend  <= 1'b0;     // a pending line straddling vblank is stale
        p_abs      <= 1'b0;
        rec_len    <= 8'd20;
        rec_line_b <= 8'hFE;
        rec_mask_b <= 8'hFF;
        rec_mode   <= RM_LINE;
        rec_rm     <= 9'h1FF;
        rec_sel_b  <= m7sel_out;
        rec_run    <= 1'b1;
        rec_step   <= 8'd0;
        rc_a <= m7a_out;    rc_b <= m7b_out;
        rc_c <= m7c_out;    rc_d <= m7d_out;
        rc_x <= m7x_out;    rc_y <= m7y_out;
        rc_h <= m7hofs_out; rc_v <= m7vofs_out;
    end else if (line_pend && rec_room) begin
        // Retry push (P2c-5): deliver a line whose edge hit while the
        // sequencer was busy or the ring was full. Sits ABOVE the live
        // branch so wire order stays ascending — an edge landing during
        // this push is caught by the rec_run branch's stash instead.
        // rc advances to the RETRIED values: the daemon's chain just
        // applied this record's delta, so the next capture's mask must
        // diff against them or every later delta in the frame misapplies.
        // A pending that survived an overwrite (a wt-burst stretch ate the
        // intermediate lines) delivers as a full-mask ABSOLUTE record: the
        // daemon applies it as a plain delta of all 8 fields and its gap
        // fill carries the values across the whole lost stretch.
        line_pend  <= 1'b0;
        p_abs      <= 1'b0;
        rec_retries <= rec_retries + 16'd1;
        rec_len    <= p_abs ? 8'd19 : (8'd3 + {popcnt8(p_mask), 1'b0});
        rec_line_b <= p_line;
        rec_mask_b <= p_abs ? 8'hFF : p_mask;
        rec_mode   <= RM_LINE;
        rec_rm     <= {1'b0, p_abs ? 8'hFF : p_mask};
        rec_run    <= 1'b1;
        rec_step   <= 8'd0;
        rc_a <= rc2_a;    rc_b <= rc2_b;
        rc_c <= rc2_c;    rc_d <= rc2_d;
        rc_x <= rc2_x;    rc_y <= rc2_y;
        rc_h <= rc2_h;    rc_v <= rc2_v;
    end else if (~HBlank_out & rec_hd_d && !vblank_out && (ppu_y < 9'd224)) begin
        if (cur_mask != 8'd0 && rec_room) begin
            rec_len    <= 8'd3 + {popcnt8(cur_mask), 1'b0};
            rec_line_b <= ppu_y[7:0];
            rec_mask_b <= cur_mask;
            rec_mode   <= RM_LINE;
            rec_rm     <= {1'b0, cur_mask};
            rec_run    <= 1'b1;
            rec_step   <= 8'd0;
            rc_a <= m7a_out;    rc_b <= m7b_out;
            rc_c <= m7c_out;    rc_d <= m7d_out;
            rc_x <= m7x_out;    rc_y <= m7y_out;
            rc_h <= m7hofs_out; rc_v <= m7vofs_out;
        end else if (cur_mask != 8'd0) begin
            // Ring full at the edge: defer to the retry stash instead of
            // dropping the line outright (a pending line lost to the
            // overwrite still counts as a drop, and flips the pending to
            // absolute — one full-mask record then repairs the stretch).
            p_line  <= ppu_y[7:0];
            p_mask  <= cur_mask;
            rc2_a <= m7a_out;    rc2_b <= m7b_out;
            rc2_c <= m7c_out;    rc2_d <= m7d_out;
            rc2_x <= m7x_out;    rc2_y <= m7y_out;
            rc2_h <= m7hofs_out; rc2_v <= m7vofs_out;
            rec_drops   <= line_pend ? (rec_drops + 8'd1) : rec_drops;
            rec_drops16 <= line_pend ? (rec_drops16 + 16'd1) : rec_drops16;
            p_abs       <= line_pend;
            line_pend   <= 1'b1;
        end
    // dstat (the dump's 0xFB completion record) outranks chunks: with
    // chunks queued the 0xFB used to trail them by seconds of UART, and
    // the daemon's dump-sequencing logic reads that lag as loss.
    // dstat/wt pushes MUST respect rec_room like the line branch: these land
    // unannounced on top of a FIFO already carrying line+sync traffic, and an
    // unguarded push past 512 aliases the 10-bit pointers and garbles the
    // stream (lost 0xFB = dumps never complete while Mode 7 is busy). pend
    // flags hold until the serializer drains room — pacing, not loss.
    end else if (dstat_pend && rec_room) begin
        rec_len    <= 8'd5;
        rec_line_b <= M7_RECVRAM_DONE;
        rec_mask_b <= dump_seq;         // [2] dump sequence number
        rec_ah_b   <= wt_drops[7:0];    // [3] wt drop baseline low byte
        rec_mode   <= RM_DSTAT;
        rec_rm     <= 9'd0;
        rec_run    <= 1'b1;
        rec_step   <= 8'd0;
    // Chunks yield the channel to live records: the cap keeps at most one
    // staged chunk (~244 B) in the FIFO, so a dump consumes only the slack
    // the line stream doesn't need (~30 kB/s at full line coverage — a dump
    // stretches to ~2 s) instead of queuing 268 B and starving the push
    // sequencer through active video (that missed hblank capture edges:
    // on device, cov fell to 0/224 lines per frame while a dump ran and
    // 152/224 in mixed frames — the band corruption). The chunk waits for
    // room rather than pushing into a nearly-full FIFO: 244 B is larger
    // than anything else on the stream, and dump_byte_win is blocked while
    // dump_pend, so backpressure holds.
    end else if (dump_pend && (rec_count < 11'd40)) begin
        rec_len    <= dp_len;
        rec_line_b <= dp_op;
        rec_mask_b <= dp_b2;
        rec_ah_b   <= dp_b3;
        rec_mode   <= RM_DCHUNK;
        rec_rm     <= 9'd0;
        rec_run    <= 1'b1;
        rec_step   <= 8'd0;
    end else if (wt_pend && rec_room) begin
        rec_len    <= 8'd4 + {4'd0, wt_n};
        rec_line_b <= M7_RECVRAM_WT;
        rec_mask_b <= wt_al;
        rec_ah_b   <= wt_ah;
        rec_wt_base <= wt_base;
        rec_wt_n    <= wt_n;
        rec_mode   <= RM_WT;
        rec_rm     <= 9'd0;
        rec_run    <= 1'b1;
        rec_step   <= 8'd0;
    end
end

// Chunk staging buffer: write port fed by the dump reader, read port by the
// push sequencer (dbuf_ra above). Registered read = one-cycle latency, part
// of the dbuf_ra = rec_step-3 alignment.
always @(posedge clk_sys) begin
    if (dbuf_we)
        chunk_buf[dbuf_wa] <= dbuf_wd;
    chunk_buf_q <= chunk_buf[dbuf_ra];
end

// ===========================================================================
// Dump + write-through emitter (clk_sys). Owns every dump_*/dbuf_w*/wt_*
// staging register; reacts to the push block's rec_run/rec_mode/rec_step/
// rec_done for its handshakes.
// ===========================================================================
always @(posedge clk_sys) begin
    // Request consumption: dump_fire arrives from the guarded ctrl adoption
    // (one pulse per genuinely-new word). The arm latch keeps its level
    // semantics — a request only fires after a clear word was adopted, so a
    // completed dump can't re-trigger while the daemon drains its 0xFB;
    // arming and the fire acknowledgement live in the adoption block, which
    // solely drives dump_fire/dump_req_arm.
    if (dump_fire && dump_req_arm && !dump_active && !dump_pend && !dstat_pend) begin
        dump_active  <= 1'b1;
        dump_plane   <= 1'b0;
        dump_rd      <= 16'd0;
        dump_bc      <= 9'd0;
        dump_stall   <= 22'd0;
    end

    // push-block handshakes: staged -> running (the step==0 cycle identifies
    // the record the sequencer just started)
    if (dump_pend && rec_run && rec_mode == RM_DCHUNK && rec_step == 8'd0)
        dump_pend <= 1'b0;
    if (dstat_pend && rec_run && rec_mode == RM_DSTAT && rec_step == 8'd0)
        dstat_pend <= 1'b0;

    // VRAM byte landing: q_b holds the byte for the address presented one
    // cycle ago, so presented_d marks the write window
    dump_presented_d <= dump_byte_win;
    if (dump_byte_win) begin
        bw_cnt <= bw_cnt + 16'd1;
        dump_rd <= dump_rd + 16'd1;
        chunk_active <= 1'b1;
    end
    if (dump_presented_d) begin
        dbuf_we <= 1'b1;
        dbuf_wa <= dump_bc[7:0];
        dbuf_wd <= dump_qb;
        dump_bc <= dump_bc + 9'd1;
    end else begin
        dbuf_we <= 1'b0;
    end

    // stage a completed chunk (waits out the two-cycle write pipeline)
    if (stage_chunk) begin
        dump_pend    <= 1'b1;
        chunk_active <= 1'b0;
        dp_len     <= 8'd4 + dump_bc[7:0];
        dp_op      <= M7_RECVRAM_DUMP;
        dp_b2      <= chunk_base[7:0];
        dp_b3      <= {dump_plane, chunk_base[14:8]};
        dump_last  <= dump_plane && dump_rd_end;
        dump_bc    <= 9'd0;
        if (dump_rd_end && !dump_plane) begin
            dump_plane <= 1'b1;      // plane 1 done: switch, restart address
            dump_rd    <= 16'd0;
        end
    end

    // Kill-time wedge recovery: a dump whose 0xFB push was dropped by a full
    // FIFO (daemon killed mid-dump) used to leave dump_active set forever —
    // rd parked at the plane end, byte window closed, every later request
    // swallowed by !dump_active, until a core reload. Watch for progress:
    // with the yield cap a healthy dump stages a chunk at least every few
    // ms; ~195 ms (2^22 clk_sys) with nothing staged and nothing pending
    // (pend = backpressure, which is healthy) means the FSM is wedged.
    // Abandon it — the request path then accepts the daemon's next request
    // and the image self-heals from wt records + the fresh dump.
    if (dump_active) begin
        if (stage_chunk || dump_pend || dstat_pend)
            dump_stall <= 22'd0;
        else if (&dump_stall) begin
            dump_active <= 1'b0;
            dump_pend   <= 1'b0;
            dump_stall  <= 22'd0;
        end else begin
            dump_stall <= dump_stall + 22'd1;
        end
    end

    // dump completion chain: plane 2's tail chunk pushed -> status record;
    // status pushed -> dump finished
    if (rec_done && rec_mode == RM_DCHUNK && dump_last) begin
        dump_last   <= 1'b0;
        dstat_pend  <= 1'b1;
    end
    if (rec_done && rec_mode == RM_DSTAT) begin
        dump_active <= 1'b0;
        dump_seq    <= dump_seq + 8'd1;
    end

    // write-through run staging + retire
    if (wt_pend && rec_run && rec_mode == RM_WT && rec_step == 8'd0)
        wt_pend <= 1'b0;
    if (wt_stage) begin
        wt_pend <= 1'b1;
        wt_n    <= wt_run;
        wt_base <= wt_r;
        wt_al   <= wt_e0[15:8];
        wt_ah   <= {wt_e0[23], wt_e0[22:16]};
    end
    if (rec_done && rec_mode == RM_WT)
        wt_r <= wt_r + rec_wt_n;
end

// --- VRAM write-through FIFO ---------------------------------------------
// Snoops the CPU write ports (port A of vram1/vram2) into the wt_fifo
// declared with the coalescing scan above; the dump/wt emitter block packs
// same-plane consecutive runs into 0xFC UART records and retires them.
// wt_w/version accounting lives here so a same-cycle snoop and retire
// never collide (different registers).

// ===========================================================================
// One clk_sys always block owns the frame controller and the write-through
// snoop. Single ownership means every register is written from exactly one
// place.
//
// PIVOT v2: the 16-bit write service FSM (write-through / per-line mailbox /
// header / CGRAM / resync-dump writers) is gone with the DDR3 mailbox port.
// The per-line register capture moved to its own block above (it now feeds
// the UART record stream). The frame controller polls the daemon's ctrl
// word and adopts published frames.
// ===========================================================================
always @(posedge clk_sys) begin
    // ---- frame controller ------------------------------------------------
    ctrl_done_s1 <= ctrl_done;
    ctrl_done_s2 <= ctrl_done_s1;
    ctrl_done_s3 <= ctrl_done_s2;

    if (m7_frame_evt) begin
        frame_seq <= frame_seq + 16'd1;
        ctrl_req  <= ~ctrl_req;   // issue this frame's ctrl poll
        fs_cnt    <= fs_cnt + 16'd1;
    end
    // Adopt the daemon's published frame when its poll result lands — react
    // to ctrl_new directly. (v2.1 evaluated this branch inside the
    // m7_frame_evt gate: the poll is ISSUED at the frame event and its DOUT
    // lands many cycles later, so ctrl_new can never coincide with
    // m7_frame_evt. Telemetry showed polls completing every frame with the
    // exact published word while daemon_present stayed 0 — the branch was
    // unreachable by construction.) Bits [31:19] are reserved-zero in the
    // ABI and bit 17 (FMT8) must be set — requiring them rejects random
    // boot-time DDR3 garbage in the no-daemon-yet window (a false adoption
    // would set daemon_present and fetch garbage with nobody publishing)
    // and stale 16bpp-format publishers.
    //
    // fetch_restart is a one-clk_sys pulse OWNED by this block (the fetch
    // FSM only reads it — a second driver there is an elaboration error).
    // Clear-before-set order means a set in the adoption branch below wins
    // for the current cycle. clut_load re-arms the palette loader so
    // CGRAM fades track within a frame.
    if (fetch_restart)
        fetch_restart <= 1'b0;
    // ---- DUMP_REQ one-shot fire + arm latch. This block solely drives
    // dump_fire/dump_req_arm; the dump FSM only reads them. The fire is a
    // ONE-SHOT per adopted word: the old dump-FSM block reacted to bare
    // ctrl_new — which pulses once per POLL, every frame, changed word or
    // not — with no seq guard, so any stale or garbage capture with bit 18
    // set fired a dump (on device: dumps every ~2 s with no matching
    // daemon request, each one starving the line stream).
    // Acknowledgement precedes the adoption branch so a fresh request
    // pulse in the same cycle wins. Nonblocking semantics keep the
    // handshake with the dump FSM race-free (it activates on the identical
    // condition in the same cycle).
    if (dump_fire && dump_req_arm && !dump_active && !dump_pend && !dstat_pend) begin
        dump_fire    <= 1'b0;
        dump_req_arm <= 1'b0;
    end else if (dump_fire && !dump_req_arm) begin
        dump_fire <= 1'b0;   // not armed: swallowed, drop the pulse
    end
    // [31:19] reserved (M7_CTRL_DUMP_REQ = bit 18 is a legitimate request,
    // not garbage — P2c-3; the v2.1 mask [31:18] would have rejected every
    // dump-requesting word and silently frozen frame adoption).
    if (ctrl_new && (m7_ctrl_data[31:19] == 13'd0) &&
        m7_ctrl_data[M7_CTRL_FMT8] &&
        (m7_ctrl_data[15:0] != last_ready_seq)) begin
        daemon_present <= 1'b1;
        cur_buf        <= m7_ctrl_data[M7_CTRL_READY_BUF];
        last_ready_seq <= m7_ctrl_data[15:0];
        fetch_restart  <= 1'b1;
        dump_fire      <= m7_ctrl_data[M7_CTRL_DUMP_REQ];
        if (!m7_ctrl_data[M7_CTRL_DUMP_REQ]) dump_req_arm <= 1'b1;
    end
    if (ctrl_new) cdn_cnt <= cdn_cnt + 16'd1;

    // ---- VRAM write-through snoop (last: same-cycle writes never lost) ----
    // Edge-detected: the PPU holds WE low for several clk_sys cycles per
    // write, so a level sample pushes 4-6 duplicate entries per write and
    // floods the 8-deep FIFO. One push per falling WE edge = one per write.
    // wt_drops wraps (no saturation): the daemon's drift detection uses a
    // wrap-safe 16-bit delta, and a pinned counter would hide every
    // map-load burst after the first.
    vram1_we_d <= VRAM1_WE_N;
    vram2_we_d <= VRAM2_WE_N;
    if (~VRAM1_WE_N && vram1_we_d) begin
        if (wt_cnt < 4'd8) begin
            wt_fifo[wt_w[2:0]] <= {1'b0, VRAM1_ADDR[14:0], VRAM1_D};
            wt_w      <= wt_w + 4'd1;
            vram1_ver <= vram1_ver + 16'd1;
        end else
            wt_drops <= wt_drops + 16'd1;
    end
    if (~VRAM2_WE_N && vram2_we_d) begin
        if (wt_cnt < 4'd8) begin
            wt_fifo[wt_w[2:0]] <= {1'b1, VRAM2_ADDR[14:0], VRAM2_D};
            wt_w      <= wt_w + 4'd1;
            vram2_ver <= vram2_ver + 16'd1;
        end else
            wt_drops <= wt_drops + 16'd1;
    end
end
`endif

msu_data_store msu_data_store
(
	.clk_sys(clk_sys),

	.base_addr(msu_data_base),

	.rd_next(msu_data_req),
	.rd_seek(msu_data_seek),
	.rd_seek_done(msu_data_ack),
	.rd_addr(msu_data_addr),

	.ram_addr(msu_ram_addr),
	.ram_req(msu_ram_req),
	.ram_ack(msu_ram_ack),
	.ram_din(msu_ram_dout),

	.rd_dout(msu_data)
);

// ---------------------------------------------------------------------------
// ddram: the DDR3 f2sdram port-1 client FSM, wired DIRECTLY to the module's
// DDRAM_* ports (upstream topology — the traffic-cop mux layer is gone).
//
// Clients, in the FSM's arbitration order:
//   rom   — savestates (reads+writes, burst-1)
//   rd2   — MSU-1 data RAM (burst-2)
//   hd    — HD Mode 7 scanline fetch (burst-1 reads, lowest priority)
//
// PIVOT v2 (2026-10-12): the 16-bit mailbox WRITE port is deleted. f2sdram
// port-1 FPGA writes are broken on this device at every usable clock
// (accepted/acked but never committed — proven at clk_mem across three
// deterministic placements and at clk_sys with a healthy arbiter), so the
// ONLY writer to the Mode 7 DDR3 window is the ARM daemon (proven perfect);
// FPGA->ARM control data rides the HPS UART instead (rtl/m7_reg_stream.sv).
// Port clock: clk_sys (assign below) — reads proven perfect there twice.
// ---------------------------------------------------------------------------
wire [1:0] dbg_ddr_state;   // production: dangling (debug builds decoded it)

ddram ddram
(
	.DDRAM_CLK(DDRAM_CLK),

	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_BUSY(DDRAM_BUSY),

	.cache_rst(~RESET_N),

	.rdaddr({11'b0011_1111_10, ss_ddr_addr[21:3]}), // Save states at $3F80.0000
	.rom_din(ss_ddr_din),
	.rom_be(ss_ddr_be),
	.rom_we(ss_ddr_we),
	.dout(ss_ddr_dout),
	.rom_req(ss_ddr_req),
	.rom_ack(ss_ddr_ack),

	.rdaddr2(msu_ram_addr), // MSU is at $2060.0000-3F7F.FFFF
	.dout2(msu_ram_dout),
	.rd_req2(msu_ram_req),
	.rd_ack2(msu_ram_ack),

	.hd_addr(dm_addr),
	.hd_req(dm_req),
	.hd_ack(dm_ack),
	.hd_dout(dm_dout),
	.dbg_state(dbg_ddr_state)
);


// saving with keyboard/OSD/gamepad
wire [1:0] ss_slot;
wire [7:0] ss_info;
wire ss_save, ss_load, ss_info_req;
wire ss_status;
wire ss_allow = ss_avail & cart_ready & ssbin_ready;
wire ss_joy_start = joy0[11] | status[53];

savestate_ui #(.INFO_TIMEOUT_BITS(25)) savestate_ui
(
	.clk            (clk_sys       ),
	.ps2_key        (ps2_key[10:0] ),
	.allow_ss       (ss_allow      ),
	.joySS          (joy0[12]      ),
	.joyRight       (joy0[0]       ),
	.joyLeft        (joy0[1]       ),
	.joyDown        (joy0[2]       ),
	.joyUp          (joy0[3]       ),
	.joyStart       (ss_joy_start  ),
	.joyRewind      (0             ),
	.rewindEnable   (0             ),
	.status_slot    (status[52:51] ),
	.OSD_saveload   (status[48:47] ),
	.ss_save        (ss_save       ),
	.ss_load        (ss_load       ),
	.ss_info_req    (ss_info_req   ),
	.ss_info        (ss_info       ),
	.statusUpdate   (ss_status     ),
	.selected_slot  (ss_slot       )
);
// ===========================================================================
// The DDR3 traffic cop is GONE (PIVOT v2, 2026-10-12). With the mailbox
// write port deleted there is exactly one FPGA-side DDR3 bus master left —
// the ddram FSM itself — so there is nothing left to arbitrate at this
// level: ddram's internal state-0 priority (savestate > MSU-1 > HD fetch)
// is the whole arbiter, every client is a level req/ack handshake, and the
// HD fetch client simply waits its turn (its deadlines are soft: a line
// that isn't ready falls back to native output).
// ===========================================================================

// ===========================================================================
// Phase 2: HD Mode 7 DDR3 Memory Reader (DMA)
// ===========================================================================

// Run the DDR3 controller port on the MiSTer memory clock. The arbiter above
// drives all other physical DDRAM_* outputs (RD/WE/ADDR/DIN/BE/BURSTCNT) —
// do NOT reassign them here, or you will create multiple-driver compile
// errors.
// f2sdram port 1 clock: upstream stock is clk_mem (upstream SNES.sv:1372,
// ~4x clk_sys) — an earlier run of this repo drove it with clk_sys, which
// PIVOT P1 (2026-10-12): clk_mem is now proven dead in our fits across THREE
// independent deterministic placements (SEED 1/2/3 all wedge the f2sdram
// port in read-wait with zero readdatavalid), so the port moves to clk_sys —
// the NDS4MiSTer/GBA topology, where this build's reads were already proven
// correct (Build-5 identity scan). History: the 2026-10-11 clk_sys build saw
// the port's write path silently drop ALL writes (full or partial
// byteenable — a full-BE write to a prepainted scratch never committed while
// every handshake counter looked healthy), but that build still had the
// pulse-based cop wedge — fixed since — so the verdict is confounded. The
// probe+UART channel below now tests the one unproven combination:
// full-BE FPGA WRITES at clk_sys with the fixed level-based cop. devmem
// 0x3E200000 == 0x1234ABCD after load ⇒ writes commit ⇒ the all-DDR3
// architecture works at clk_sys unchanged.
assign DDRAM_CLK      = clk_sys;

`ifdef M7_2X_ENABLE
// HD pixel line fetch — runs on clk_sys (the DDR3 bus domain), CONTINUOUSLY.
//
// PIVOT v2 (2026-10-12): the fetch is no longer per-line-triggered. At
// burst-1 (the only read shape proven on this device), one 64-bit word
// costs its full transaction latency, so a 256-word row takes several
// THOUSAND clk_sys cycles — far more than one scanline's 341. The fetch
// therefore runs as a free-running background sequencer over rows
// 0..223, and each row's completion sets a sticky done bit. At hde-fall
// the arm decision looks up row_done[next_row]: a row that is ready gets
// its HD line, one that isn't falls back to native output — no tearing,
// just graceful per-line degradation. The done bits are cleared and the
// sequencer restarts from row 0 whenever a new daemon frame is adopted,
// so stale rows from an older frame are never re-shown as "fresh".
//
// Clients the ddram FSM serves ahead of us: savestates, MSU-1. Our level
// handshake (hd_req/hd_ack toggles) simply waits its turn — lost pulses
// are structurally impossible, which was the whole cop lesson.
//
// ---------------------------------------------------------------------------
// CLUT loader: once per well-formed ctrl-word completion, copy the PPU's
// CGRAM shadow (256 BGR555 entries through the sequential mirror port) into
// the linebuf's palette BRAM. Pure PPU-port + BRAM traffic — no DDR3
// involvement, so it runs beside the fetch FSM. Two cycles per entry (set
// mirror address, then write while q is valid): a full palette refresh
// costs ~24 us, so CGRAM fades track within a frame. Trigger = ctrl_new
// with the v2 guard bits (same shape as the adoption branch, minus the seq
// guard — reloading an unchanged palette is harmless, and this block OWNS
// clut_load/clut_cnt so no other always block may drive them).
// clut_wr_addr rides cgram_mirror_addr — the address is held across the
// write cycle, and the final entry's write drains in the first idle cycle
// before the park (addr <= 0) lands.
// ---------------------------------------------------------------------------
reg        clut_load  = 1'b0;
reg  [8:0] clut_cnt   = 9'd0;
reg        clut_wr_en = 1'b0;

always @(posedge clk_sys) begin
    clut_wr_en <= 1'b0;
    if (ctrl_new && (m7_ctrl_data[31:18] == 14'd0) && m7_ctrl_data[M7_CTRL_FMT8]) begin
        clut_load <= 1'b1;
        clut_cnt  <= 9'd0;
    end else if (clut_load) begin
        if (!clut_cnt[0])
            cgram_mirror_addr <= clut_cnt[8:1];
        else
            clut_wr_en <= 1'b1;
        clut_cnt <= clut_cnt + 9'd1;
        if (&clut_cnt)
            clut_load <= 1'b0;
    end else begin
        cgram_mirror_addr <= 8'd0;
    end
end

// Address convention (rtl/m7_abi.svh): DDRAM_ADDR is a 64-bit WORD address
// (physical byte >> 3); row r of the pixel buffer lives at word offset
// r*32 from the buffer base, i.e. {r, fetch_word[4:0]} (8bpp, 256 B/row).
reg  ctrl_req_s1, ctrl_req_s2, ctrl_req_s3;
wire ctrl_req_pulse = ctrl_req_s2 ^ ctrl_req_s3;

reg        m7_fetch_en_s1, m7_fetch_en_s2;
reg        cur_buf_s;

localparam DM_IDLE = 3'd0, DM_ROW_END = 3'd1, DM_CTRL_WAIT = 3'd2,
           DM_WAIT  = 3'd4, DM_DRAIN  = 3'd5;   // (DM_CTRL/DM_REQ were dead)
reg [2:0]  dm_state = DM_IDLE;

// linebuf write-port outputs. These are the SOLE drivers of the buf_wr_*
// wires — hps_ext has been disconnected.
reg  [7:0]  buf_wr_addr;    // native pixel index within the row (0..255, 8bpp)
reg  [7:0]  buf_wr_data;    // CLUT index byte (linebuf expands via CLUT)
reg         buf_wr_en;
reg         ctrl_pend = 1'b0;   // ctrl poll request latch (sweep-starve fix)
reg  [7:0]  last_row_id = 8'd0; // row id sitting complete in the inactive slot
reg [14:0]  park_cnt;           // DM_ROW_END safety counter

// ddram HD client handshake (level req/ack toggles)
reg  [28:0] dm_addr;
reg         dm_req  = 1'b0;
wire        dm_ack;
wire [63:0] dm_dout;

reg  [8:0]  fetch_row  = 9'd0;   // row currently being fetched (0..223)
reg  [7:0]  fetch_word = 8'd0;   // 64-bit word within the row (0..31, 8bpp)
reg  [63:0] dm_word;              // latched read (stable through DM_DRAIN)
reg  [2:0]  px_byte;              // byte within the 64-bit word (0..7)
reg  [255:0] row_done = 256'd0;  // sticky: row ready for display
reg         fetch_restart = 1'b0;    // frame controller: new frame adopted
reg         fetch_pend = 1'b0;   // restart waiting for the bus to go idle

// Watchdog: a fetch word that hasn't returned in 8192 clk_sys (~380 µs)
// aborts the FSM so a dead port degrades to "no HD lines" instead of
// hanging the sequencer. Counted only while a transaction is in flight.
reg  [12:0] dm_watchdog = 13'd0;
reg         dm_wd_evt   = 1'b0;  // sticky for the LED panel

// Row stride is 32 words (256 native bytes, 8bpp): offset = {row, word[4:0]}.
wire [28:0] dm_word_addr = (cur_buf_s ? M7_PIXBUF_B_WORD : M7_PIXBUF_WORD)
                           + {fetch_row, fetch_word[4:0]};

always @(posedge clk_sys) begin
    // 3FF synchronisers for the frame-controller toggles/quasi-static
    // payload (same domain today — kept so the FSM stays correct if the
    // port clock ever changes back to a multi-domain topology).
    ctrl_req_s1 <= ctrl_req;      ctrl_req_s2  <= ctrl_req_s1; ctrl_req_s3 <= ctrl_req_s2;
    m7_fetch_en_s1 <= m7_fetch_en; m7_fetch_en_s2 <= m7_fetch_en_s1;
    cur_buf_s   <= cur_buf;       // quasi-static (changes once per frame)

    buf_wr_en <= 1'b0;

    // Ctrl-poll request latch: the sweep keeps dm_req!=dm_ack most cycles,
    // so the 1-cycle ctrl_req_pulse used to be missed ~95% of the time
    // (first telemetry capture: 160 of 3129 polls completed). Latch it;
    // the IDLE ctrl branch below drains the latch with priority over fetch
    // words. Same-block ordering makes the IDLE clear win when both fire.
    if (ctrl_req_pulse)
        ctrl_pend <= 1'b1;

    // Watchdog: counts while a read is outstanding; abort wins over the
    // case below only if no completion lands this cycle.
    if ((dm_state == DM_CTRL_WAIT || dm_state == DM_WAIT) && (dm_req != dm_ack))
        dm_watchdog <= dm_watchdog + 13'd1;
    else
        dm_watchdog <= 13'd0;

    // While a restart is pending the FSM must not issue anything: an
    // in-flight read completes on its own (ddram toggles dm_ack unaided)
    // and the pend block below lands the reset at a genuinely idle point.
    if (!fetch_pend)
    case (dm_state)
        DM_IDLE: begin
            // dm_req == dm_ack gate: after a watchdog abort the old
            // transaction may still be outstanding — issuing before its
            // late ack lands would make ddram treat our new toggle as the
            // old read's completion (stale data, swallowed request).
            if ((dm_req == dm_ack) && (ctrl_req_pulse || ctrl_pend)) begin
                dm_addr   <= M7_CTRL_WORD;
                dm_req    <= ~dm_req;
                dm_state  <= DM_CTRL_WAIT;
                ctrl_pend <= 1'b0;
            end else if ((dm_req == dm_ack) && m7_fetch_en_s2) begin
                dm_addr  <= dm_word_addr;
                dm_req   <= ~dm_req;
                dm_state <= DM_WAIT;
            end
        end

        DM_CTRL_WAIT: begin
            if (dm_watchdog == 13'h1FFF) begin
                dm_wd_evt <= 1'b1;
                dm_state  <= DM_IDLE;
            end else if (dm_req == dm_ack) begin
                m7_ctrl_data <= dm_dout;
                ctrl_done    <= ~ctrl_done;
                dm_state     <= DM_IDLE;
            end
        end

        DM_WAIT: begin
            if (dm_watchdog == 13'h1FFF) begin
                dm_wd_evt <= 1'b1;
                dm_state  <= DM_IDLE;
            end else if (dm_req == dm_ack) begin
                dm_word  <= dm_dout;
                px_byte  <= 3'd0;
                drt_cnt  <= drt_cnt + 16'd1;   // telemetry: fetch words done
                dm_state <= DM_DRAIN;
            end
        end

        // Push the word's 8 CLUT index bytes into the linebuf (one byte per
        // cycle, little-endian in the 64-bit word). The linebuf expands via
        // its CLUT at read; the row completes after word 31's last byte.
        DM_DRAIN: begin
            buf_wr_addr <= {fetch_word[4:0], px_byte};
            buf_wr_data <= dm_word[px_byte*8 +: 8];
            buf_wr_en <= 1'b1;
            px_byte   <= px_byte + 3'd1;
            if (px_byte == 3'd7) begin
                if (fetch_word == 8'd31) begin
                    row_done[fetch_row] <= 1'b1;
                    last_row_id <= fetch_row[7:0];
                    fetch_word <= 8'd0;
                    fetch_row  <= (fetch_row == 9'd223) ? 9'd0 : fetch_row + 9'd1;
                    park_cnt   <= 15'd0;
                    // Row complete: park until the display side consumes
                    // the boundary (row_adv, pulsed at the next hde fall).
                    // This keeps the linebuf slot swap atomic — the writer
                    // can never straddle one mid-row — and rate-limits the
                    // sweep to the display pace. Safety counter un-wedges
                    // a park with no hde falls (video gone).
                    dm_state <= DM_ROW_END;
                end else begin
                    fetch_word <= fetch_word + 8'd1;
                    dm_state <= DM_IDLE;
                end
            end
        end

        DM_ROW_END: begin
            park_cnt <= park_cnt + 15'd1;
            if (row_adv || (&park_cnt))
                dm_state <= DM_IDLE;
        end
    endcase

    // New daemon frame adopted: restart the sweep from row 0 with clean
    // done bits (the frame controller sets this pulse at adoption time).
    // The reset WAITS for an idle bus — dropping the FSM out of DM_WAIT
    // with a transaction outstanding would misattribute the old read's ack
    // to the next issue (stale word + swallowed request), and dropping out
    // of DM_DRAIN would write the word's second pair to the wrong
    // row/word (fetch_row/fetch_word reset before the write fires).
    // Worst cost of waiting: one word of the old sweep still lands in the
    // linebuf, refetched anyway next sweep.
    if (fetch_restart) begin          // one-cycle pulse from the frame ctrl
        fetch_pend <= 1'b1;
    end else if (fetch_pend) begin
        if (dm_watchdog == 13'h1FFF) begin
            // port died mid-flight while pending — abort visibly
            dm_wd_evt  <= 1'b1;
            fetch_pend <= 1'b0;
            dm_state   <= DM_IDLE;
            fetch_row  <= 9'd0;
            fetch_word <= 8'd0;
            px_byte    <= 3'd0;
            row_done   <= 256'd0;
        end else if (dm_req == dm_ack) begin
            fetch_pend <= 1'b0;
            dm_state   <= DM_IDLE;   // covers DM_WAIT whose ack just landed
            fetch_row  <= 9'd0;
            fetch_word <= 8'd0;
            px_byte    <= 3'd0;
            row_done   <= 256'd0;
        end
    end
end

// --- Line arm decision (clk_sys) ------------------------------------------
// hde falling edge ends line L's active video. V_CNT has not incremented
// yet at that edge, so the row displayed by line L+1 is ppu_y+1. Arm the
// linebuf only if that row's fetch has completed (sticky row_done) —
// otherwise the line falls back to native output.
reg        hde_d;
reg        m7_line_hd = 1'b0;
reg        row_adv = 1'b0;          // one-clk pulse: fetch FSM may leave park
reg  [7:0] disp_row = 8'hFF;        // row id currently in the displayed slot
                                    // (act itself is declared by the instance)

// hde_cnt/arm_cnt reset at each frame_start: arm_cnt = lines that showed
// the HD buffer this frame — the fetch-throughput measurement.
//
// Slot swap policy (v3): at each hde fall, if this line's row was fetched
// and the inactive slot holds a COMPLETED row the display hasn't shown
// yet, swap slots. The parked writer (DM_ROW_END) guarantees the swap is
// atomic; lines between fresh rows repeat the displayed row. row_adv
// releases the parked FSM at the same edge so the next row starts into
// the slot that just became inactive.
always @(posedge clk_sys) begin
    hde_d <= HBlank_out;
    row_adv <= 1'b0;
    if (frame_start) begin
        hde_cnt <= 16'd0;
        arm_cnt <= 16'd0;
    end else if (~HBlank_out & hde_d) begin
        hde_cnt <= hde_cnt + 16'd1;
        row_adv <= (dm_state == DM_ROW_END);
        if (m7_fetch_en && (ppu_y < 9'd223)) begin
            if (row_done[ppu_y + 9'd1]) begin
                arm_cnt <= arm_cnt + 16'd1;
                if (last_row_id != disp_row) begin
                    act      <= ~act;
                    disp_row <= last_row_id;
                end
            end
            m7_line_hd <= row_done[ppu_y + 9'd1];
        end else
            m7_line_hd <= 1'b0;
    end
end
`endif

// ===========================================================================
// M7 LED panel: mirrors the HD fetch path onto the DE10-Nano's 8 user LEDs.
//   LED0  heartbeat (blinks ~1.3 Hz)   — clk_sys + this block alive
//   LED1  fetch FSM off IDLE (live)    — the fetch sequencer is mid-word
//   LED2  fetch word COMPLETED win.    — dm_ack toggling (words landing)
//   LED3  DDRAM_BUSY live level        — solid = f2sdram waitrequest stuck
//   LED4  fetch watchdog fired (latch) — a fetch word timed out
//   LED5  daemon_present               — a ctrl frame was adopted
//   LED6  WT FIFO full (live)          — VRAM write-through flood (P2c consumer)
//   LED7  read data EVER landed        — any DOUT_READY since load
// "Window" LEDs latch activity and clear every ~0.78 s, so they blink at
// any event rate above ~2 Hz.
// ===========================================================================
`ifdef M7_2X_ENABLE
reg [23:0] dbg_led_t   = 24'd0;
reg        dbg_ack_seen = 1'b0, dbg_rd_latch = 1'b0;
reg        dm_ack_q     = 1'b0;

always @(posedge clk_sys) begin
    dbg_led_t <= dbg_led_t + 24'd1;
    dm_ack_q  <= dm_ack;
    if (dm_ack != dm_ack_q)   dbg_ack_seen <= 1'b1;
    if (DDRAM_DOUT_READY)     dbg_rd_latch <= 1'b1;
    if (&dbg_led_t) dbg_ack_seen <= 1'b0;
end

assign M7_DBG_LED = { dbg_rd_latch,                 // [7]
                      (wt_cnt == 4'd8),             // [6]
                      daemon_present,               // [5]
                      dm_wd_evt,                    // [4]
                      DDRAM_BUSY,                   // [3]
                      dbg_ack_seen,                 // [2]
                      (dm_state != DM_IDLE),        // [1]
                      dbg_led_t[23] };              // [0]

// ---------------------------------------------------------------------------
// FPGA->ARM register stream (PIVOT v2): owns ttyS1. The f2sdram write path
// is broken on this device at every usable clock, so control data flows to
// the daemon over the HPS UART instead (rtl/m7_reg_stream.sv). P2b runs it
// in TELEMETRY mode (test_mode=2): each frame is a snapshot of every link
// in the ctrl->adoption->fetch->arm chain — the on-screen test card AND
// the debug channel in one build. Decode: scripts/m7_telemetry_decode.py.
// ---------------------------------------------------------------------------
// DOUT_READY rising counter — its own block (nobody else samples the port).
reg dout_d = 1'b0;
always @(posedge clk_sys) begin
    dout_d <= DDRAM_DOUT_READY;
    if (DDRAM_DOUT_READY & ~dout_d) dout_cnt <= dout_cnt + 16'd1;
end

wire [2047:0] dbg_bytes;
assign dbg_bytes[7:0]     = 8'hC3;                    // [0] magic
assign dbg_bytes[15:8]    = {fetch_pend, fetch_restart, m7_fetch_en,
                             daemon_present, dm_wd_evt, DDRAM_BUSY,
                             DDRAM_DOUT_READY, (dm_req != dm_ack)}; // [1]
assign dbg_bytes[23:16]   = {vblank_out, HBlank_out, 2'b00, ctrl_new,
                             dm_state};               // [2]
assign dbg_bytes[31:24]   = {m7_line_hd, cur_buf_s, cur_buf, fetch_pend,
                             4'b0000};                // [3]
assign dbg_bytes[255:32]  = row_done[223:0];          // [4..31] sticky rows
assign dbg_bytes[271:256] = fs_cnt;                   // [32..33]
assign dbg_bytes[287:272] = cdn_cnt;                  // [34..35] ctrl polls OK
assign dbg_bytes[303:288] = drt_cnt;                  // [36..37] fetch words
assign dbg_bytes[319:304] = dout_cnt;                 // [38..39] DOUT edges
assign dbg_bytes[335:320] = hde_cnt;                  // [40..41] hde falls/frame
assign dbg_bytes[351:336] = arm_cnt;                  // [42..43] HD lines/frame
assign dbg_bytes[367:352] = {7'd0, fetch_row};        // [44..45] (7+9=16)
assign dbg_bytes[383:368] = {8'd0, fetch_word};       // [46..47]
assign dbg_bytes[415:384] = m7_ctrl_data;             // [48..51] LAST CTRL READ
assign dbg_bytes[447:416] = dm_word[31:0];            // [52..55] last word
assign dbg_bytes[463:448] = {7'd0, ppu_x};            // [56..57]
assign dbg_bytes[479:464] = {7'd0, ppu_y};            // [58..59]
assign dbg_bytes[495:480] = last_ready_seq;           // [60..61]
assign dbg_bytes[1031:1024] = disp_row;               // [128] displayed row
assign dbg_bytes[1039:1032] = last_row_id;            // [129] inactive-slot row
assign dbg_bytes[1047:1040] = {row_adv, act, 6'b0};   // [130] swap activity
assign dbg_bytes[1055:1048] = rec_drops;              // [131] records dropped (room)
assign dbg_bytes[1063:1056] = {dump_req_arm, dstat_pend, dump_pend, dump_last,
                               dump_active, dump_plane, 2'b00}; // [132] dump phase
assign dbg_bytes[1071:1064] = dump_seq;               // [133] completed dumps
assign dbg_bytes[1087:1072] = vram1_ver;              // [134..135] plane-1 wt version
assign dbg_bytes[1103:1088] = vram2_ver;              // [136..137] plane-2 wt version
assign dbg_bytes[1119:1104] = wt_drops;               // [138..139] wt drops
// P2c-3 dump diagnostics (bytes 140..147): where the dump FSM actually is.
assign dbg_bytes[1135:1120] = dump_rd;                // [140..141] dump read ptr
assign dbg_bytes[1151:1136] = {7'b0, dump_bc};        // [142..143] bytes landed
assign dbg_bytes[1167:1152] = bw_cnt;                 // [144..145] byte-win pulses
assign dbg_bytes[1183:1168] = {5'b0, rec_count};      // [146..147] record FIFO fill
// P2c-5 line-retry diagnostics (bytes 148..151): the 8-bit [131] counter
// wraps within one frame under wt bursts — these are the wide truth.
assign dbg_bytes[1191:1184] = rec_drops16[7:0];       // [148] stash overwrites (l)
assign dbg_bytes[1199:1192] = rec_drops16[15:8];      // [149] stash overwrites (h)
assign dbg_bytes[1207:1200] = rec_retries[7:0];       // [150] retry pushes (l)
assign dbg_bytes[1215:1208] = rec_retries[15:8];      // [151] retry pushes (h)
assign dbg_bytes[503:496] = {6'b0, dbg_ddr_state};    // [62] ddram FSM state
assign dbg_bytes[511:504] = 8'h5A;                    // [63] tail magic
assign dbg_bytes[1023:512] = 64'd0;                   // [64..127] undefined
assign dbg_bytes[2047:1216] = {104{32'hAAAA_AAAA}};   // filler (bytes 152..255)

wire m7_stream_txd;
m7_reg_stream #(
	.CLK_HZ      (32'd21_477_272),
	.BAUD        (32'd3_000_000),
	.PAYLOAD_LEN (16'd256)
) m7_reg_stream (
	.clk       (clk_sys),
	.rst       (~RESET_N),
	.test_mode (2'd3),          // per-line records + interleaved telemetry
	.dbg_bytes (dbg_bytes),
	.rec_wr    (rec_wr),
	.rec_data  (rec_data),
	.rec_room  (rec_room),
	.rec_count (rec_count),
	.txd       (m7_stream_txd)
);
assign m7_dbg_tx = m7_stream_txd;
wire dbg_uart_txd;   // legacy ASCII telemetry instance removed; port unused
`else
assign M7_DBG_LED = 8'h00;
assign m7_dbg_tx = 1'b1;
`endif

endmodule
