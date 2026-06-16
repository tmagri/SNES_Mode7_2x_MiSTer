#!/bin/bash

# 1. Instruct the MiSTer framework to load your custom SNES core
echo "load_core /media/fat/_Console/SNES_Mode7_HD.rbf" > /dev/MiSTer_cmd

# 2. Wait a moment for the FPGA to configure
sleep 2

# 3. Start the daemon in the foreground
/media/fat/daemon/m7_daemon
