#!/usr/bin/env bash
set -euo pipefail

# Compile the SNES MiSTer core (with HD Mode 7 enabled) using the Quartus
# Docker image, then stage the result as the RBF the launcher expects.
# Usage: ./snes_build.sh [--qpf SNES.qpf] [--image IMAGE]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
QPF_FILE="$PROJECT_DIR/SNES.qpf"
QUARTUS_IMAGE="${QUARTUS_IMAGE:-ryanfb/quartus-mister}"
DOCKER_BIN="${DOCKER_BIN:-}"
BUILD_LOCK="$PROJECT_DIR/.snes_build.lock"
STAGED_RBF="SNES_Mode7_HD.rbf"   # what scripts/snes_hd_m7.sh installs

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Compile the SNES MiSTer Quartus project in Docker (HD Mode 7 on).

Options:
  --qpf FILE       Quartus project file, default: SNES.qpf
  --image IMAGE    Docker image, default: $QUARTUS_IMAGE
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--qpf)
			[[ $# -ge 2 ]] || { echo "Missing value for --qpf" >&2; exit 1; }
			QPF_FILE="$PROJECT_DIR/$2"
			shift 2
			;;
		--image)
			[[ $# -ge 2 ]] || { echo "Missing value for --image" >&2; exit 1; }
			QUARTUS_IMAGE="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

[[ -f "$QPF_FILE" ]] || { echo "Quartus project not found: $QPF_FILE" >&2; exit 1; }

if [[ -z "$DOCKER_BIN" ]]; then
	if command -v docker >/dev/null 2>&1; then
		DOCKER_BIN="$(command -v docker)"
	elif [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
		DOCKER_BIN="/Applications/Docker.app/Contents/Resources/bin/docker"
	else
		echo "Docker was not found. Install Docker Desktop or set DOCKER_BIN." >&2
		exit 1
	fi
fi

"$DOCKER_BIN" info >/dev/null 2>&1 || {
	echo "Docker Desktop is not running. Start it and re-run this script." >&2
	exit 1
}

# tr -d '\r': the qpf sometimes carries CRLF endings; a stray CR in the
# revision name makes every later "$PROJECT_REVISION.rbf" path a lie.
PROJECT_REVISION="$(sed -n 's/^PROJECT_REVISION = "\([^"]*\)"/\1/p' "$QPF_FILE" | tr -d '\r')"
[[ -n "$PROJECT_REVISION" ]] || {
	echo "Could not determine PROJECT_REVISION from $QPF_FILE" >&2
	exit 1
}
QPF_NAME="$(basename "$QPF_FILE")"
QSF_NAME="${QPF_NAME%.qpf}.qsf"
RBF_FILE="$PROJECT_DIR/output_files/$PROJECT_REVISION.rbf"

grep -q 'VERILOG_MACRO "M7_2X_ENABLE"' "$QSF_NAME" || {
	echo "WARNING: M7_2X_ENABLE is not set in $QSF_NAME — the daemon will" >&2
	echo "         reject this bitstream (magic mismatch, exit 2)." >&2
}

if ! "$DOCKER_BIN" image inspect "$QUARTUS_IMAGE" >/dev/null 2>&1; then
	echo "Pulling Docker image: $QUARTUS_IMAGE"
	"$DOCKER_BIN" pull "$QUARTUS_IMAGE"
fi

if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
	echo "Another SNES build is already running: $BUILD_LOCK" >&2
	exit 1
fi
cleanup() {
	rmdir "$BUILD_LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Compiling $PROJECT_REVISION with $QUARTUS_IMAGE"
# Stage + hash INSIDE the compile container: the macOS-side VirtioFS dentry
# cache has hidden freshly-written output_files entries for >10 minutes even
# from the host's own ls, so the container is the only immediately-trustworthy
# viewer. It stages under the launcher's name and prints RBF_MD5; the host
# then polls until its (lazy) view of the file matches that hash — which also
# guarantees a later scp deploys the bits that were just built, never a stale
# copy that merely looks fresh.
COMPILE_LOG=$(mktemp)
if ! "$DOCKER_BIN" run --rm \
	--platform linux/amd64 \
	-v "$PROJECT_DIR:/build:rw" \
	-w /build \
	"$QUARTUS_IMAGE" \
	bash -c "export PATH=\"\$PATH:/opt/intelFPGA_lite/17.0/quartus/bin:/intelFPGA_lite/17.0/quartus/bin\" && if ! grep -q '^[[:space:]]*set_global_assignment -name NUM_PARALLEL_PROCESSORS[[:space:]]' '$QSF_NAME'; then echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 1' >> '$QSF_NAME'; fi && quartus_sh --flow compile '$QPF_NAME' && cp -f 'output_files/$PROJECT_REVISION.rbf' 'output_files/$STAGED_RBF' && echo \"RBF_MD5: \$(md5sum 'output_files/$STAGED_RBF' | cut -d' ' -f1)\"" \
	2>&1 | tee "$COMPILE_LOG"; then
	echo "Compilation failed" >&2
	rm -f "$COMPILE_LOG"
	exit 1
fi

EXPECTED_MD5="$(sed -n 's/^RBF_MD5: //p' "$COMPILE_LOG" | tail -1)"
rm -f "$COMPILE_LOG"
[[ -n "$EXPECTED_MD5" ]] || {
	echo "Container did not report RBF_MD5 — cannot verify the host-side copy" >&2
	exit 1
}

# Poll the host view until the staged rbf matches the container's hash.
RBF_OK=0
for _ in $(seq 1 150); do
	ls "$PROJECT_DIR/output_files/" >/dev/null 2>&1
	if [[ -f "$PROJECT_DIR/output_files/$STAGED_RBF" ]] \
		&& [[ "$(md5 -q "$PROJECT_DIR/output_files/$STAGED_RBF" 2>/dev/null)" == "$EXPECTED_MD5" ]]; then
		RBF_OK=1
		break
	fi
	sleep 4
done
if [[ "$RBF_OK" != 1 ]]; then
	echo "Host view of $STAGED_RBF never matched the container md5" >&2
	echo "(VirtioFS lag) — expected $EXPECTED_MD5; do NOT deploy until it does" >&2
	exit 1
fi

echo "Compiled successfully: $RBF_FILE"
echo "Staged as: $PROJECT_DIR/output_files/$STAGED_RBF (md5 $EXPECTED_MD5)"
