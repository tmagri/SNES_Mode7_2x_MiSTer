#!/usr/bin/env bash
# daemon_build_mister.sh — produce daemon/m7_daemon as an ARM binary.
#
# Two paths, tried in order:
#   1. On the MiSTer over SSH (if it has make + g++) — sources are copied
#      into the support dir, compiled there, and the binary is copied back.
#   2. Locally in Docker with an ARM cross toolchain (static-linked so the
#      MiSTer's userspace libc version doesn't matter). This is the path a
#      stock MiSTer takes: its image ships no make.
#
# Usage: scripts/daemon_build_mister.sh [user@host]
#        (default: ${MISTER_HOST:-root@mister}; snes_build_debug.sh uses 192.168.1.131)

set -euo pipefail

HOST="${1:-${MISTER_HOST:-root@mister}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/daemon"
REMOTE_DIR="/media/fat/Scripts/.SNES_HD_M7/support/src"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes"
CROSS_IMAGE="${CROSS_IMAGE:-debian:bookworm-slim}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

fetch_back() {
	scp -O $SSH_OPTS -q "$HOST:$REMOTE_DIR/m7_daemon" "$SRC_DIR/m7_daemon"
}

verify_arm() {
	if command -v file >/dev/null 2>&1 && ! file "$SRC_DIR/m7_daemon" | grep -q ARM; then
		echo "ERROR: daemon/m7_daemon is not an ARM binary" >&2
		exit 1
	fi
}

# ─── Path 1: build on the MiSTer ─────────────────────────────────────────────
if ssh $SSH_OPTS "$HOST" "command -v make >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1" 2>/dev/null; then
	echo "Building on $HOST (on-device toolchain found) ..."
	ssh $SSH_OPTS "$HOST" "mkdir -p $REMOTE_DIR"
	scp -O $SSH_OPTS -q "$SRC_DIR/m7_daemon.cpp" "$SRC_DIR/m7_abi.h" "$SRC_DIR/Makefile" "$HOST:$REMOTE_DIR/"
	ssh $SSH_OPTS "$HOST" "cd $REMOTE_DIR && make clean >/dev/null 2>&1; make"
	fetch_back
	chmod 755 "$SRC_DIR/m7_daemon"
	verify_arm
	echo "OK: daemon/m7_daemon built on $HOST"
	exit 0
fi

# ─── Path 2: Docker cross-compile (static) ───────────────────────────────────
echo "No make/g++ on $HOST — cross-compiling in Docker ($CROSS_IMAGE) ..."
if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
	if [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
		DOCKER_BIN="/Applications/Docker.app/Contents/Resources/bin/docker"
	fi
	"$DOCKER_BIN" info >/dev/null 2>&1 || { open -a Docker || true
		for _ in $(seq 1 30); do "$DOCKER_BIN" info >/dev/null 2>&1 && break; sleep 2; done; }
fi
"$DOCKER_BIN" info >/dev/null 2>&1 || { echo "ERROR: Docker not available" >&2; exit 1; }

"$DOCKER_BIN" run --rm --platform linux/amd64 \
	-v "$SRC_DIR:/src:rw" -w /src \
	"$CROSS_IMAGE" \
	bash -c "apt-get update -qq && apt-get install -y -qq make g++-arm-linux-gnueabihf >/dev/null &&
	         make clean >/dev/null 2>&1; make CROSS_COMPILE=arm-linux-gnueabihf- STATIC=1"

verify_arm
echo "OK: daemon/m7_daemon cross-built (static ARM), ready to deploy"
