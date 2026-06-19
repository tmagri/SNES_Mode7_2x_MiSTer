#!/bin/bash
#
# snes_hd_m7.sh — load the experimental HD Mode 7 SNES core and start the
# ARM daemon safely. Intended to be launched from the MiSTer OSD Scripts menu.
#
# Important: the daemon must NEVER run when another core is loaded, because
# it pokes the HPS lightweight bridge directly. We verify the loaded core
# name before launching, and we background the daemon so the OSD Scripts
# menu regains control (foregrounding it competes with the framework's
# PS/2 input loop and causes spurious save/load key events).

set -u

CORE_RBF="/media/fat/_Console/SNES_Mode7_HD.rbf"
DAEMON="/media/fat/daemon/m7_daemon"
LOG="/tmp/m7_daemon.log"
EXPECTED_CORE="SNES"   # substring matched against /tmp/CORENAME

# 1. Kill any previously-launched daemon (e.g. user re-ran the script).
pkill -f "$DAEMON" 2>/dev/null
sleep 0.2

# 2. Instruct the MiSTer framework to load the custom SNES core.
if [ ! -f "$CORE_RBF" ]; then
    echo "ERROR: $CORE_RBF not found" >&2
    exit 1
fi
echo "load_core $CORE_RBF" > /dev/MiSTer_cmd

# 3. Wait for the FPGA to configure and the framework to update CORENAME.
for i in $(seq 1 20); do
    sleep 0.2
    if [ -r /tmp/CORENAME ] && grep -q "$EXPECTED_CORE" /tmp/CORENAME; then
        break
    fi
done

if ! grep -q "$EXPECTED_CORE" /tmp/CORENAME 2>/dev/null; then
    echo "ERROR: core did not load (CORENAME=$(cat /tmp/CORENAME 2>/dev/null))" >&2
    exit 1
fi

# 4. Launch the daemon backgrounded, idle I/O priority, lowest CPU priority,
#    stdout/stderr redirected to a logfile so it cannot interfere with the
#    OSD/SSH terminal that the framework is using for keyboard input.
if [ ! -x "$DAEMON" ]; then
    echo "ERROR: $DAEMON missing or not executable" >&2
    exit 1
fi

nice -n 19 ionice -c 3 "$DAEMON" >"$LOG" 2>&1 &
DAEMON_PID=$!
disown "$DAEMON_PID" 2>/dev/null

echo "m7_daemon started (pid $DAEMON_PID); log at $LOG"
