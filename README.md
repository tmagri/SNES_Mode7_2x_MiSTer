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
This branch implements an experimental **True HD Mode 7** architecture using the MiSTer HPS (ARM Cortex-A9) as a graphics co-processor to generate up to 4× horizontal resolution affine transformations and inject pixels back into the FPGA video pipeline.

### How It Works
1. The FPGA captures the 8 Mode 7 registers **per scanline** into a BRAM (so HDMA changes — e.g. SMK's pseudo-3D perspective — are preserved), then dumps them to DDR3 during vertical blank.
2. The FPGA also mirrors VRAM1, VRAM2, and CGRAM into DDR3 every frame (VRAM copies are skipped when nothing has changed via dirty flags).
3. The ARM daemon `mmap`s the DDR3 window, reads the per-line registers + VRAM/CGRAM mirrors, and performs real Mode 7 affine tile rendering with palette lookup and EXTBG compositing at 4× resolution.
4. The daemon writes RGB565 pixels back to DDR3. A DMA reader in the FPGA fetches them (4 pixels per 64-bit read) into a dual-port BRAM line buffer that overrides the PPU's Mode 7 output.

### DDR3 Shared Memory Map
| Address | Region | Size |
|---|---|---|
| `0x3E000000` | Per-line M7 register mailbox (224 lines × 8 regs) | 3584 B |
| `0x3E002000` | HD pixel buffer (daemon → FPGA DMA) | ~900 KB |
| `0x3E100000` | VRAM1 mirror (32K entries) | 64 KB |
| `0x3E108000` | VRAM2 mirror (32K entries) | 64 KB |
| `0x3E110000` | CGRAM mirror (256 entries) | 512 B |

### Component Layout
1. **FPGA Hardware (`.rbf`):** Shadow VRAM/CGRAM dprams, per-line register capture BRAM, DDR3 frame writer, round-robin DDR3 arbiter, DMA reader (4 pixels/read), dual-port line buffer with per-line arming and CDC synchronizers, and the updated PPU video mux.
2. **HPS Daemon (`m7_daemon`):** C++ user-space daemon that `mmap`s `/dev/mem`, reads the per-line registers + VRAM/CGRAM mirrors, performs real Mode 7 affine tile rendering with CGRAM palette conversion and EXTBG support, and writes HD pixels back.
3. **Control Script (`snes_hd_m7.sh`):** Loads the core, verifies it via `/tmp/CORENAME`, kills any stale daemon, then launches the daemon backgrounded at low priority with output redirected to a logfile.

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
> Accessing the HPS lightweight bridge when the SNES core is not active can lock up the system bus and freeze your MiSter. Always load the core first before starting the daemon.

#### Option 1: Using the automation script (Recommended)
1. Copy the script [snes_hd_m7.sh](scripts/snes_hd_m7.sh) to `/media/fat/Scripts/snes_hd_m7.sh` on the MiSTer.
2. Ensure it is executable:
   ```bash
   chmod +x /media/fat/Scripts/snes_hd_m7.sh
   ```
3. Run the script from the OSD **Scripts** menu. It will:
   - Kill any previously-running `m7_daemon`
   - Load `SNES_Mode7_HD.rbf` via `/dev/MiSTer_cmd`
   - Wait until `/tmp/CORENAME` confirms the core is active
   - Launch the daemon **backgrounded** at `nice -n 19 ionice -c 3` with output to `/tmp/m7_daemon.log`

   The daemon runs in the background; the OSD menu returns immediately. To stop it later: `pkill -f m7_daemon`.

#### Option 2: Run manually via SSH
1. Load your custom `SNES_Mode7_HD.rbf` core using the MiSTer OSD menu.
2. SSH into your MiSTer and run:
   ```bash
   /media/fat/daemon/m7_daemon &
   ```
3. Stop it with `pkill -f m7_daemon` before closing the core or rebooting.

### Keyboard Bindings
Save-state hotkeys (F1–F4) now require **Alt** to avoid spurious popups:
- **Alt + F1–F4**: Save to slot 0–3
- **Alt + Shift + F1–F4**: Load from slot 0–3
- Plain F1–F4: no savestate action (previously triggered load, which caused random "Loading state" popups)
- Debug layer toggles (DEBUG builds only): F6–F10

