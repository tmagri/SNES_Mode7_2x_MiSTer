# [Super Nintendo Entertainment System](https://en.wikipedia.org/wiki/Super_Nintendo_Entertainment_System) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

Written by [srg320](https://github.com/srg320)

## Experimental Status (This Branch)
This version is experimental and has limited support.

It will not be pushed to `master` in its current form, since other pending changes may still be breaking.

Current status:
* Mode 7 Wide-Res works. It doubles the resolution of Mode 7 backgrounds to 512×448 by rendering two horizontal sub-pixels per dot clock (dual-port VRAM) and two vertical sub-scanlines via field interlace (B/2, D/2 affine offset on alternate fields). Sprites and other layers remain at native resolution.
* The PPU asserts INTERLACE when Wide-Res is active, and HDMI bob deinterlacing is now auto-enabled for interlaced frames to improve progressive-display stability (reduce shimmer/combing by default).
* Overclock fix for Top Gear 3000 works, albeit with minor visual glitches.

For regular support, please use the main MiSTer community channels.

This build was used as an experiment.

## Installing
copy \*.rbf to root of SD card. Put some ROMs (\*.SFC, \*.SMC, \*.BIN) into SNES folder

## Features
* Cycle accurate SNES replica.
* Supports LoROM, HiROM, ExHiROM.
* Supports additional chips: DSP-1/2/3/4, ST010, CX4, SDD1, SuperFX(GSU-1/2), SA1, OBC1, SPC7110, S-RTC, Sufami Turbo.
* MSU-1 Support
* Cheat engine.
* Save/Load Backup RAM.
* Supports mouse.
* Light gun support via Wiimote, mouse or analog stick.
* [SuperFX Turbo and CPU Turbo.](https://github.com/MiSTer-devel/SNES_MiSTer/blob/master/SNES_Turbo.md)

### BSX BIOS
Place bsx_bios.rom in game's folder.

## True HD Mode 7 (ARM Co-processor)
This branch implements an experimental **True HD Mode 7** architecture using the MiSTer HPS (ARM Cortex-A9) as a graphics co-processor to generate 2x horizontal resolution affine transformations and inject pixels back into the FPGA video pipeline.

### Component Layout
1. **FPGA Hardware (`.rbf`):** Contains the PPU extensions, dual-port BRAM line buffer (512x24-bit), and the updated `hps_ext` bridge controller.
2. **HPS Daemon (`m7_daemon`):** C++ user-space daemon that maps `/dev/mem` to communicate with the `hps_ext` bridge, reads Mode 7 registers, calculates the 2x horizontal resolution pixels, and writes them back.
3. **Control Script (`snes_hd_m7.sh`):** Automates loading the custom core and starting the daemon safely.

### Compilation

#### 1. Compile the FPGA Core (.rbf)
Compile the Quartus project (`SNES.qpf`) as usual to output the `.rbf` file. Rename and copy this file to `/media/fat/_Console/SNES_Mode7_HD.rbf` on your MiSTer SD card.

#### 2. Compile the ARM Daemon
The ARM C++ daemon must be compiled for the MiSTer's ARM architecture.

* **Method A: Compile on the MiSTer (Easiest)**
  1. Transfer the `daemon` folder (containing [Makefile](file:///Users/troymagri/Desktop/SNES_Mode7_2x_MiSTer/daemon/Makefile) and [m7_daemon.cpp](file:///Users/troymagri/Desktop/SNES_Mode7_2x_MiSTer/daemon/m7_daemon.cpp)) to your MiSTer.
  2. SSH into your MiSTer and run:
     ```bash
     cd /path/to/daemon
     make
     ```
  3. Copy the compiled `m7_daemon` executable to `/media/fat/daemon/m7_daemon`.

* **Method B: Cross-Compile on Host PC**
  1. Set the cross-compiler in the `Makefile` (e.g., `CXX = arm-linux-gnueabihf-g++`).
  2. Run `make`.
  3. Transfer the compiled `m7_daemon` binary to `/media/fat/daemon/m7_daemon` on the MiSTer.

---

### Running the Core and Daemon Safely

> [!WARNING]
> **Do NOT run the daemon at system boot.**
> Accessing the HPS lightweight bridge when the SNES core is not active can lock up the system bus and freeze your MiSTer. Always load the core first before starting the daemon.

#### Option 1: Using the automation script (Recommended)
1. Copy the script [snes_hd_m7.sh](file:///Users/troymagri/Desktop/SNES_Mode7_2x_MiSTer/scripts/snes_hd_m7.sh) to `/media/fat/Scripts/snes_hd_m7.sh` on the MiSTer.
2. Ensure it is executable:
   ```bash
   chmod +x /media/fat/Scripts/snes_hd_m7.sh
   ```
3. Run the script from the OSD **Scripts** menu. This automatically loads `SNES_Mode7_HD.rbf` and launches the daemon.

#### Option 2: Run manually via SSH
1. Load your custom `SNES_Mode7_HD.rbf` core using the MiSTer OSD menu.
2. SSH into your MiSTer and run:
   ```bash
   /media/fat/daemon/m7_daemon
   ```
3. Press `Ctrl + C` to exit the daemon before closing the core or rebooting.

