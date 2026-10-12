#!/bin/bash
#
# SNES_HD_M7_stop.sh — stop the HD Mode 7 daemon and reload the stock SNES
# core. Installed to /media/fat/Scripts/SNES_HD_M7_stop.sh.

set -eu

PIDFILE="/tmp/m7_daemon.pid"
STOCK_RBF="/media/fat/_Console/SNES.rbf"

if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
    rm -f "$PIDFILE"
fi
pkill -f "m7_daemon" 2>/dev/null || true

if [ -f "$STOCK_RBF" ]; then
    echo "[SNES_HD_M7] reloading stock core"
    echo "load_core $STOCK_RBF" > /dev/MiSTer_cmd
else
    echo "[SNES_HD_M7] daemon stopped; stock core not found at $STOCK_RBF"
fi
echo "[SNES_HD_M7] stopped. Log kept at /tmp/m7_daemon.log"
