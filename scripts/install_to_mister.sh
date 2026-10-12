#!/usr/bin/env bash
#
# install_to_mister.sh — copy the HD Mode 7 artifacts to a MiSTer over SSH.
#
#   Usage: scripts/install_to_mister.sh [user@host]
#   (default: ${MISTER_HOST:-root@mister})
#
# Layout installed (matches scripts/snes_hd_m7.sh):
#   /media/fat/Scripts/SNES_HD_M7.sh                  (OSD launcher)
#   /media/fat/Scripts/SNES_HD_M7_stop.sh             (stop script)
#   /media/fat/Scripts/.SNES_HD_M7/support/SNES_Mode7_HD.rbf (+.sha256)
#   /media/fat/Scripts/.SNES_HD_M7/support/m7_daemon         (+.sha256)

set -euo pipefail

HOST="${1:-${MISTER_HOST:-root@mister}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RBF="$ROOT/output_files/SNES_Mode7_HD.rbf"
DAEMON="$ROOT/daemon/m7_daemon"
SUPPORT="/media/fat/Scripts/.SNES_HD_M7/support"
SSH_OPTS="-o ConnectTimeout=5"

for f in "$RBF" "$DAEMON"; do
	[ -f "$f" ] || { echo "Missing $f — build first (./snes_build.sh, daemon/make)" >&2; exit 1; }
done

# Verify the daemon is an ARM binary (a Mac build won't run on the MiSTer).
if command -v file >/dev/null 2>&1; then
	file "$DAEMON" | grep -q "ARM" || {
		echo "ERROR: $DAEMON is not an ARM binary." >&2
		echo "Build it ON the MiSTer (daemon/make) or cross-compile:" >&2
		echo "  make -C daemon CROSS_COMPILE=arm-linux-gnueabihf-" >&2
		exit 1
	}
fi

echo "Installing to $HOST ..."
ssh $SSH_OPTS "$HOST" "mkdir -p $SUPPORT"

scp $SSH_OPTS -q "$RBF" "$HOST:$SUPPORT/SNES_Mode7_HD.rbf"
scp $SSH_OPTS -q "$DAEMON" "$HOST:$SUPPORT/m7_daemon"
scp $SSH_OPTS -q "$ROOT/scripts/snes_hd_m7.sh" "$HOST:/media/fat/Scripts/SNES_HD_M7.sh"
scp $SSH_OPTS -q "$ROOT/scripts/SNES_HD_M7_stop.sh" "$HOST:/media/fat/Scripts/SNES_HD_M7_stop.sh"

# Refresh the sidecars on-device (checksums must match the device's files).
ssh $SSH_OPTS "$HOST" "
	chmod 755 $SUPPORT/m7_daemon /media/fat/Scripts/SNES_HD_M7.sh /media/fat/Scripts/SNES_HD_M7_stop.sh
	cd $SUPPORT &&
	sha256sum SNES_Mode7_HD.rbf > SNES_Mode7_HD.rbf.sha256 &&
	sha256sum m7_daemon > m7_daemon.sha256
"
echo "Done. On the MiSTer: Scripts -> SNES_HD_M7"
