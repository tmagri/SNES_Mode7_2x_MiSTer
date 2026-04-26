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
