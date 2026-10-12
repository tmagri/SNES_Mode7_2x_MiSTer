#!/bin/bash
#
# SNES_HD_M7.sh — load the HD Mode 7 SNES core and start the ARM daemon.
# Installed to /media/fat/Scripts/SNES_HD_M7.sh by scripts/install_to_mister.sh
# and launched from the MiSTer OSD Scripts menu.
#
# Support layout (installed by install_to_mister.sh):
#   /media/fat/Scripts/.SNES_HD_M7/support/SNES_Mode7_HD.rbf (+ .sha256)
#   /media/fat/Scripts/.SNES_HD_M7/support/m7_daemon          (+ .sha256)
#
# Notes:
#  * The daemon talks ONLY to shared DDR3 via /dev/mem (docs/m7_abi.md).
#    It never touches the HPS io bus, so the framework keeps running.
#  * The daemon self-gates on the FPGA's magic/version header: with the
#    wrong (stock) core loaded it exits 2 instead of writing garbage.
#  * Logs: /tmp/m7_daemon.log. PID: /tmp/m7_daemon.pid

set -eu

SUPPORT_DIR="/media/fat/Scripts/.SNES_HD_M7/support"
CORE_RBF="$SUPPORT_DIR/SNES_Mode7_HD.rbf"
DAEMON="$SUPPORT_DIR/m7_daemon"
LOG="/tmp/m7_daemon.log"
PIDFILE="/tmp/m7_daemon.pid"
LOCK="/tmp/.SNES_HD_M7.lock"
CORENAME_FILE="/tmp/CORENAME"

log() { echo "[SNES_HD_M7] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# --- sanity ---------------------------------------------------------------
[ -f "$CORE_RBF" ] || fail "$CORE_RBF missing — run scripts/install_to_mister.sh"
[ -x "$DAEMON" ]   || fail "$DAEMON missing or not executable"

sha_ok() {  # sha_ok <file>
    local f="$1"
    [ -f "$f.sha256" ] || return 0   # sidecar optional
    ( cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" >/dev/null 2>&1 )
}

sha_ok "$CORE_RBF" || fail "SNES_Mode7_HD.rbf failed its sha256 check — reinstall"
sha_ok "$DAEMON"   || fail "m7_daemon failed its sha256 check — reinstall"

# --- single instance -------------------------------------------------------
exec 9>"$LOCK"
flock -n 9 || fail "another SNES_HD_M7 run is active"

# --- stop a previously-launched daemon -------------------------------------
if [ -f "$PIDFILE" ]; then
    OLDPID="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$OLDPID" ] && kill "$OLDPID" 2>/dev/null || true
    rm -f "$PIDFILE"
    sleep 0.3
fi
pkill -f "m7_daemon" 2>/dev/null || true

# --- load the HD core -------------------------------------------------------
log "loading $CORE_RBF"
# Clear CORENAME first: it keeps its previous value on a failed load, so the
# poll below must only trust a SNES value written AFTER this point.
echo "MENU" > "$CORENAME_FILE"
echo "load_core $CORE_RBF" > /dev/MiSTer_cmd

# Wait for the FPGA to configure and the framework to publish CORENAME.
CORE_OK=0
for _ in $(seq 1 40); do
    sleep 0.25
    if [ -r "$CORENAME_FILE" ] && grep -q "SNES" "$CORENAME_FILE"; then
        CORE_OK=1
        break
    fi
done
[ "$CORE_OK" = 1 ] || fail "core did not load (CORENAME=$(cat "$CORENAME_FILE" 2>/dev/null || echo '?'))"

# --- kernel module (optional, best-effort) ----------------------------------
# /dev/m7_mem_wc gives the daemon a write-combined pixel window (see
# kernel/m7_mem_wc). Built and insmod'ed on first run; any failure is
# non-fatal — the daemon falls back to plain /dev/mem.
WC_DEV="/dev/m7_mem_wc"
KMOD_DIR="$SUPPORT_DIR/kernel/m7_mem_wc"
if [ ! -e "$WC_DEV" ]; then
    if [ -f "$KMOD_DIR/m7_mem_wc.c" ]; then
        log "m7_mem_wc not loaded — building/inserting (first run may take a minute)"
        if ! lsmod | grep -q "m7_mem_wc"; then
            ( cd "$KMOD_DIR" && make >>/tmp/m7_kmod_build.log 2>&1 ) &&
                insmod "$KMOD_DIR/m7_mem_wc.ko" 2>>/tmp/m7_kmod_build.log ||
                log "WARNING: m7_mem_wc unavailable — daemon uses /dev/mem (see /tmp/m7_kmod_build.log)"
        fi
    fi
fi

# --- launch the daemon ------------------------------------------------------
# Backgrounded + niced so the OSD regains control immediately and controller
# polling (SPI) keeps its latency.
log "starting m7_daemon"
( nice -n 19 "$DAEMON" ${M7_DAEMON_ARGS:-} >>"$LOG" 2>&1 & echo $! > "$PIDFILE" )

sleep 1
if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    RC="?"
    tail -n 5 "$LOG" >&2 || true
    fail "daemon exited immediately (see $LOG)"
fi

log "HD Mode 7 active (pid $(cat "$PIDFILE")). Log: $LOG"
log "Run SNES_HD_M7_stop.sh (or load any other game) to stop."
exit 0
