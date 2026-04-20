# [Super Nintendo Entertainment System](https://en.wikipedia.org/wiki/Super_Nintendo_Entertainment_System) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

Written by [srg320](https://github.com/srg320)

## Experimental Status (This Branch)
This version is experimental and has limited support.

It will not be pushed to `master` in its current form, since other pending changes may still be breaking.

Current status:
* Mode 7 Wide-Res works. It doubles the horizontal resolution of Mode 7 backgrounds by rendering two sub-pixels per dot clock using dual-port VRAM. Vertical resolution remains unchanged, so it is not a full 2x scale — it is closer to 512×224 for the Mode 7 layer while sprites and other layers remain at native resolution.
* For progressive TVs, enable the M7 WR Deinterlace option. Wide-Res outputs two sub-pixels per dot as alternating fields (similar to 448i interlace), which can cause flickering or combing on progressive displays. The deinterlace filter bobs the fields together to produce a clean image.
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
