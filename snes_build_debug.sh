#!/usr/bin/env bash
# =============================================================================
# snes_build_debug.sh — SNES HD Mode 7: Compile → Deploy → Launch
# =============================================================================
# Adapted from NES_OC_MiSTer/nes_build_debug.sh, with the NDS4MiSTer dual
# core+ARM-service deployment model: the HD bitstream replaces the SNES core
# the OSD loads, and the ARM daemon is deployed into a support dir and
# started after the core is up (it only touches shared DDR3 via /dev/mem,
# so the MiSTer framework keeps running).
#
# Usage:
#   ./snes_build_debug.sh [rom]          Deploy existing .rbf + daemon (+ opt.
#                                        test rom), launch core, start daemon
#   ./snes_build_debug.sh --compile      Compile first via Docker, then deploy
#   ./snes_build_debug.sh --no-launch    Deploy but don't auto-launch
#   ./snes_build_debug.sh --no-reboot    (legacy alias of --no-launch)
#   ./snes_build_debug.sh --kill         Kill stuck Docker/Quartus processes
#
#   [rom] — optional path to a .sfc/.smc file (first non-flag argument). It
#           is copied to games/SNES and auto-loaded via auto_boot.mgl.
#
# Requirements:
#   - SSH key-based access to root@${MISTER_HOST:-192.168.1.131} (MiSTer)
#   - output_files/SNES_Mode7_HD.rbf and an ARM-built daemon/m7_daemon
#     (use --compile for the rbf; build the daemon with: make -C daemon
#      CROSS_COMPILE=arm-linux-gnueabihf-)
#
# Examples:
#   ./snes_build_debug.sh --compile ~/roms/Super\ Mario\ Kart.sfc
#   ./snes_build_debug.sh                 # redeploy current build, no ROM
#   ./snes_build_debug.sh --no-launch     # deploy only
#
# To stop a running HD session on the MiSTer, run the installed
# Scripts/SNES_HD_M7_stop.sh (restores the stock core).
# =============================================================================

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
QPF_FILE="$PROJECT_DIR/SNES.qpf"
RBF_FILE="$PROJECT_DIR/output_files/SNES_Mode7_HD.rbf"
DAEMON_FILE="$PROJECT_DIR/daemon/m7_daemon"

MISTER_HOST="${MISTER_HOST:-192.168.1.131}"
MISTER_USER="root"
MISTER_SSH="${MISTER_USER}@${MISTER_HOST}"
MISTER_CORE_DIR="/media/fat/_Console"
MISTER_RBF_PATH="${MISTER_CORE_DIR}/SNES.rbf"
# The OSD's SNES entry loads the canonical games/SNES/SNES.rbf — always keep
# it in sync so a manual core launch can never run a stale build.
MISTER_LIVE_RBF="/media/fat/games/SNES/SNES.rbf"
MISTER_ROM_DIR="/media/fat/games/SNES"

# NDS-style support layout (matches scripts/snes_hd_m7.sh + install_to_mister.sh)
MISTER_SUPPORT="/media/fat/Scripts/.SNES_HD_M7/support"
MISTER_KERNEL_DIR="${MISTER_SUPPORT}/kernel/m7_mem_wc"
MISTER_LAUNCHER="/media/fat/Scripts/SNES_HD_M7.sh"
MISTER_STOP="/media/fat/Scripts/SNES_HD_M7_stop.sh"
MISTER_PIDFILE="/tmp/m7_daemon.pid"
MISTER_LOG="/tmp/m7_daemon.log"

DOCKER_BIN="${DOCKER_BIN:-/Applications/Docker.app/Contents/Resources/bin/docker}"
QUARTUS_IMAGE="ryanfb/quartus-mister"

SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes"

# ─── Flags ────────────────────────────────────────────────────────────────────
DO_COMPILE=false
DO_LAUNCH=true
ROM_PATH=""
DO_KILL=false

for arg in "$@"; do
    case "$arg" in
        --compile)      DO_COMPILE=true ;;
        --no-launch|--no-reboot) DO_LAUNCH=false ;;
        --kill)         DO_KILL=true ;;
        --help|-h)
            sed -n '10,36p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            if [[ "$arg" != -* && -z "$ROM_PATH" ]]; then ROM_PATH="$arg";
            else echo "Unknown flag: $arg  (try --help)" >&2; exit 1; fi
            ;;
    esac
done

# ─── ANSI colours ─────────────────────────────────────────────────────────────
RED=$'\e[1;31m';  GRN=$'\e[1;32m';  YLW=$'\e[1;33m'
BLU=$'\e[1;34m';  CYN=$'\e[1;36m';  RST=$'\e[0m'
BOLD=$'\e[1m'

log()  { echo "${BLU}▶${RST} ${BOLD}$*${RST}"; }
ok()   { echo "${GRN}✔${RST} $*"; }
warn() { echo "${YLW}⚠${RST}  $*"; }
fail() { echo "${RED}✘${RST} $*" >&2; exit 1; }
step() { echo; echo "${CYN}━━━ $* ━━━${RST}"; }

# ─── Compile-phase lock ───────────────────────────────────────────────────────
BUILD_LOCK="${PROJECT_DIR}/.snes_build.lock"

build_lock_wait() {
    while pgrep -f "quartus_sh --flow compile" >/dev/null 2>&1; do
        warn "quartus_sh compile in flight — waiting"
        sleep 10
    done
}

build_lock_acquire() {
    if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
        build_lock_wait
        rm -rf "$BUILD_LOCK"
        mkdir "$BUILD_LOCK" 2>/dev/null || fail "cannot acquire build lock"
    fi
}

build_lock_release() {
    rm -rf "$BUILD_LOCK" 2>/dev/null || true
}

# =============================================================================
if $DO_KILL; then
    step "Killing stuck compile processes and clearing locks"
    if [[ -x "$DOCKER_BIN" ]]; then
        CONTAINERS=$("$DOCKER_BIN" ps -q --filter ancestor="$QUARTUS_IMAGE" 2>/dev/null || echo "")
        [[ -n "$CONTAINERS" ]] && "$DOCKER_BIN" kill $CONTAINERS >/dev/null 2>&1 || true
    fi
    pkill -f "quartus_sh" 2>/dev/null || true
    rm -rf "$BUILD_LOCK"
    ok "Cleanup complete. (On-device daemon: run Scripts/SNES_HD_M7_stop.sh there.)"
    exit 0
fi

# =============================================================================
step "Pre-flight checks"
[[ -f "$QPF_FILE" ]] || fail "Not in project root — SNES.qpf not found at $QPF_FILE"
log "Project: $PROJECT_DIR"

if [[ -n "$ROM_PATH" ]]; then
    [[ -f "$ROM_PATH" ]] || fail "ROM not found: $ROM_PATH"
    ROM_BASENAME="$(basename "$ROM_PATH")"
    ok "Test ROM: $ROM_BASENAME ($(du -h "$ROM_PATH" | cut -f1))"
fi

if $DO_COMPILE; then
    [[ -x "$DOCKER_BIN" ]] || fail "Docker binary not found at $DOCKER_BIN"
    if ! "$DOCKER_BIN" info &>/dev/null; then
        warn "Docker Desktop not running — attempting to start..."
        open -a Docker || true
        deadline=$((SECONDS + 60))
        while ! "$DOCKER_BIN" info &>/dev/null; do
            if [[ $SECONDS -ge $deadline ]]; then fail "Docker Desktop did not start within 60 s"; fi
            sleep 2
        done
    fi
    ok "Docker is running"
else
    [[ -f "$RBF_FILE" ]] || fail ".rbf not found at $RBF_FILE — run with --compile to build it"
    ok "RBF found: output_files/SNES_Mode7_HD.rbf ($(du -h "$RBF_FILE" | cut -f1), $(date -r "$RBF_FILE" '+%Y-%m-%d %H:%M'))"
fi

# The daemon must be an ARM build (a Mac build won't run on the MiSTer).
[[ -x "$DAEMON_FILE" ]] || fail "daemon not found at $DAEMON_FILE — run scripts/daemon_build_mister.sh (or VS Code task 'Daemon: Build on MiSTer')"
if command -v file >/dev/null 2>&1; then
    file "$DAEMON_FILE" | grep -q "ARM" \
        || fail "$DAEMON_FILE is not an ARM binary — rebuild via scripts/daemon_build_mister.sh"
fi
ok "Daemon found: daemon/m7_daemon ($(du -h "$DAEMON_FILE" | cut -f1))"

log "Checking MiSTer SSH at $MISTER_HOST..."
ssh $SSH_OPTS "$MISTER_SSH" "true" 2>/dev/null \
    || fail "Cannot reach MiSTer at $MISTER_HOST — is it powered on and connected?"
ok "MiSTer SSH reachable"

# =============================================================================
if $DO_COMPILE; then
    step "Phase 1 — Quartus Compilation (Docker)"
    log "This typically takes 45–90 minutes single-threaded."
    COMPILE_LOG="/tmp/snes_quartus_build.log"
    COMPILE_START="$(date +%s)"

    build_lock_wait
    build_lock_acquire
    trap build_lock_release EXIT INT TERM

    set +e
    "$DOCKER_BIN" run --rm \
        --platform linux/amd64 \
        -v "${PROJECT_DIR}:/build:rw" \
        -w /build \
        "$QUARTUS_IMAGE" \
        bash -c "export PATH=\$PATH:/opt/intelFPGA_lite/17.0/quartus/bin:/intelFPGA_lite/17.0/quartus/bin && grep -q 'NUM_PARALLEL_PROCESSORS 1' SNES.qsf || echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 1' >> SNES.qsf; quartus_sh --flow compile SNES.qpf" \
        > "$COMPILE_LOG" 2>&1
    COMPILE_EXIT=$?
    set -e
    build_lock_release

    if [[ $COMPILE_EXIT -ne 0 ]] || grep -q "^Error" "$COMPILE_LOG"; then
        echo "${RED}─── Compilation Errors ───${RST}"
        grep "^Error" "$COMPILE_LOG" | head -20 || true
        fail "Quartus compilation failed — full log at $COMPILE_LOG"
    fi

    # RBF can lag behind through the Docker/macOS file sync — poll generously
    NATIVE_RBF="$PROJECT_DIR/output_files/SNES.rbf"
    RBF_OK=0
    for _ in $(seq 1 60); do
        if [[ -f "$NATIVE_RBF" && "$(date -r "$NATIVE_RBF" '+%s')" -gt "$COMPILE_START" ]]; then RBF_OK=1; break; fi
        sleep 2
    done
    [[ "$RBF_OK" == 1 ]] || fail "Compilation finished but a fresh $NATIVE_RBF was not produced"
    cp -f "$NATIVE_RBF" "$RBF_FILE"
    ok "Compiled successfully → output_files/SNES_Mode7_HD.rbf ($(du -h "$RBF_FILE" | cut -f1))"
fi

# =============================================================================
step "Phase 2 — Deploy to MiSTer ($MISTER_HOST)"

ssh $SSH_OPTS "$MISTER_SSH" "mkdir -p ${MISTER_CORE_DIR} ${MISTER_ROM_DIR} ${MISTER_SUPPORT}" \
    || fail "Cannot create core/support dirs on MiSTer"

log "Copying SNES_Mode7_HD.rbf → ${MISTER_SSH}:${MISTER_RBF_PATH}"
scp -O $SSH_OPTS "$RBF_FILE" "${MISTER_SSH}:${MISTER_RBF_PATH}" \
    || fail "SCP of .rbf failed"
ok "SNES.rbf deployed ($(du -h "$RBF_FILE" | cut -f1))"
log "Syncing canonical core → ${MISTER_LIVE_RBF}"
ssh $SSH_OPTS "$MISTER_SSH" "cp ${MISTER_RBF_PATH} ${MISTER_LIVE_RBF} && sync" \
    || warn "Could not sync canonical core path"

# The on-device launcher (Scripts/SNES_HD_M7.sh) loads its bitstream from the
# support dir — keep a copy there under its canonical name.
log "Installing HD bitstream → ${MISTER_SUPPORT}/SNES_Mode7_HD.rbf"
ssh $SSH_OPTS "$MISTER_SSH" "cp ${MISTER_RBF_PATH} ${MISTER_SUPPORT}/SNES_Mode7_HD.rbf && sync" \
    || fail "Could not install HD rbf into support dir (launcher expects it there)"

log "Deploying daemon + launcher scripts"
scp -O $SSH_OPTS "$DAEMON_FILE" "${MISTER_SSH}:${MISTER_SUPPORT}/m7_daemon" \
    || fail "SCP of daemon failed"
scp -O $SSH_OPTS "$PROJECT_DIR/scripts/snes_hd_m7.sh" "${MISTER_SSH}:${MISTER_LAUNCHER}" \
    || fail "SCP of launcher failed"
scp -O $SSH_OPTS "$PROJECT_DIR/scripts/SNES_HD_M7_stop.sh" "${MISTER_SSH}:${MISTER_STOP}" \
    || fail "SCP of stop script failed"
ssh $SSH_OPTS "$MISTER_SSH" "chmod 755 ${MISTER_SUPPORT}/m7_daemon ${MISTER_LAUNCHER} ${MISTER_STOP} && cd ${MISTER_SUPPORT} && sha256sum SNES_Mode7_HD.rbf > SNES_Mode7_HD.rbf.sha256 2>/dev/null; sha256sum m7_daemon > m7_daemon.sha256; sync" \
    || warn "Could not chmod/refresh checksum sidecars"

log "Deploying kernel module sources (m7_mem_wc)"
ssh $SSH_OPTS "$MISTER_SSH" "mkdir -p ${MISTER_KERNEL_DIR}" || fail "Cannot create ${MISTER_KERNEL_DIR}"
scp -O $SSH_OPTS "$PROJECT_DIR/kernel/m7_mem_wc/m7_mem_wc.c" "${MISTER_SSH}:${MISTER_KERNEL_DIR}/" \
    || fail "SCP of kernel module source failed"
scp -O $SSH_OPTS "$PROJECT_DIR/kernel/m7_mem_wc/Makefile" "${MISTER_SSH}:${MISTER_KERNEL_DIR}/" \
    || fail "SCP of kernel module Makefile failed"

log "Building + inserting m7_mem_wc on-device (best-effort)"
if ! ssh $SSH_OPTS "$MISTER_SSH" "
    if [ -e /dev/m7_mem_wc ]; then
        echo 'm7_mem_wc already loaded'
    elif ! command -v make >/dev/null 2>&1; then
        echo 'make not found on MiSTer — skipping (daemon will use /dev/mem)'
    else
        cd ${MISTER_KERNEL_DIR} &&
        make >>/tmp/m7_kmod_build.log 2>&1 &&
        ( lsmod | grep -q m7_mem_wc || insmod ./m7_mem_wc.ko ) &&
        echo 'm7_mem_wc loaded'
    fi"; then
    warn "m7_mem_wc not available (headers missing?) — daemon falls back to /dev/mem; see /tmp/m7_kmod_build.log on the MiSTer"
fi

if [[ -n "$ROM_PATH" ]]; then
    log "Copying $ROM_BASENAME → ${MISTER_SSH}:${MISTER_ROM_DIR}/"
    ssh $SSH_OPTS "$MISTER_SSH" "mkdir -p ${MISTER_ROM_DIR}" || fail "Cannot create $MISTER_ROM_DIR"
    scp -O $SSH_OPTS "$ROM_PATH" "${MISTER_SSH}:${MISTER_ROM_DIR}/" \
        || fail "SCP of ROM failed"
    ok "$ROM_BASENAME deployed"
fi

ssh $SSH_OPTS "$MISTER_SSH" "sync" 2>/dev/null || true

# Prove every path the launcher / stop script / MGL reference actually exists.
log "Verifying deployed layout..."
ssh $SSH_OPTS "$MISTER_SSH" "
    rc=0
    for f in ${MISTER_RBF_PATH} ${MISTER_LIVE_RBF} ${MISTER_SUPPORT}/SNES_Mode7_HD.rbf \
             ${MISTER_SUPPORT}/m7_daemon ${MISTER_LAUNCHER} ${MISTER_STOP}; do
        [ -f \"\$f\" ] || { echo \"  MISSING: \$f\"; rc=1; }
    done
    [ \$rc -eq 0 ] && echo '  all present'
    exit \$rc" \
    || fail "deployed files missing on MiSTer — see paths above"
ok "Deployed layout verified"

if $DO_LAUNCH; then
    step "Phase 3 — Launch HD core + daemon"

    # Make sure no daemon from a previous session writes into a fresh core.
    ssh $SSH_OPTS "$MISTER_SSH" "if [ -f ${MISTER_PIDFILE} ]; then kill \$(cat ${MISTER_PIDFILE}) 2>/dev/null; rm -f ${MISTER_PIDFILE}; fi; pkill -f m7_daemon 2>/dev/null; true"

    if [[ -n "$ROM_PATH" ]]; then
        # An MGL is only needed to auto-attach a ROM. Verified on-device
        # 2026-10-11: <rbf> must be the FULL path INCLUDING the file stem
        # ("games/SNES/SNES") — "games/SNES" and bare "SNES" make the
        # framework fail the load with "No RBF found!" and CORENAME stays
        # stale (never trust it without clearing it first). The no-ROM case
        # loads the rbf directly instead of using a bare-rbf MGL, which this
        # framework silently ignores.
        log "Generating auto-boot MGL (with $ROM_BASENAME)..."
        ssh $SSH_OPTS "$MISTER_SSH" "cat << 'EOF' > ${MISTER_CORE_DIR}/auto_boot.mgl
<mistergamedescription>
    <rbf>games/SNES/SNES</rbf>
    <file delay=\"2\" type=\"f\" index=\"0\" path=\"$ROM_BASENAME\"/>
</mistergamedescription>
EOF"
        log "Launching SNES HD core + $ROM_BASENAME via MiSTer_cmd..."
        ssh $SSH_OPTS "$MISTER_SSH" "echo 'MENU' > /tmp/CORENAME; echo 'load_core ${MISTER_CORE_DIR}/auto_boot.mgl' > /dev/MiSTer_cmd"
    else
        log "Launching SNES HD core via MiSTer_cmd (direct rbf)..."
        ssh $SSH_OPTS "$MISTER_SSH" "echo 'MENU' > /tmp/CORENAME; echo 'load_core ${MISTER_RBF_PATH}' > /dev/MiSTer_cmd"
    fi

    log "Waiting for the core to come up (CORENAME, up to 30 s)..."
    CORE_OK=0
    for _ in $(seq 1 60); do
        if ssh $SSH_OPTS "$MISTER_SSH" "grep -q SNES /tmp/CORENAME 2>/dev/null"; then CORE_OK=1; break; fi
        sleep 0.5
    done
    if [[ "$CORE_OK" != 1 ]]; then
        warn "CORENAME never showed SNES — diagnostics:"
        ssh $SSH_OPTS "$MISTER_SSH" "
            echo \"  CORENAME: \$(cat /tmp/CORENAME 2>/dev/null || echo absent)\"
            echo \"  live rbf: \$(ls -l ${MISTER_LIVE_RBF} 2>&1)\"
            echo \"  auto_boot.mgl:\"; sed 's/^/    /' ${MISTER_CORE_DIR}/auto_boot.mgl 2>/dev/null" \
            2>/dev/null || true
        fail "core did not load (no SNES CORENAME) — see diagnostics above"
    fi

    log "Starting m7_daemon (niced; log ${MISTER_LOG})..."
    ssh $SSH_OPTS "$MISTER_SSH" "nohup nice -n 19 ${MISTER_SUPPORT}/m7_daemon \${M7_DAEMON_ARGS:-} >> ${MISTER_LOG} 2>&1 & echo \$! > ${MISTER_PIDFILE}"

    sleep 1
    if ! ssh $SSH_OPTS "$MISTER_SSH" "kill -0 \$(cat ${MISTER_PIDFILE}) 2>/dev/null"; then
        ssh $SSH_OPTS "$MISTER_SSH" "tail -n 5 ${MISTER_LOG}" 2>/dev/null || true
        fail "daemon exited immediately — see ${MISTER_LOG} on the MiSTer"
    fi

    ok "HD Mode 7 active — check your screen."
    echo
    echo "${BOLD}Test checklist:${RST}"
    echo "  1. Daemon log:    ssh ${MISTER_SSH} 'tail ${MISTER_LOG}'  → magic OK, abi=1, 4x"
    echo "  2. Soak:          non-Mode7 game 10 min — no crash (native fallback path)"
    echo "  3. Super Mario Kart: 1024-px track, no shear, no 2:1 squeeze"
    echo "  4. F-Zero:        odd-column tiles correct"
    echo "  5. Savestates/MSU-1: OSD INFO works, no audio dropouts"
    echo "  6. Stop:          ssh ${MISTER_SSH} 'sh ${MISTER_STOP}'  (or run it from OSD)"
else
    ok "Deployed (launch skipped). Launch later via Scripts → SNES_HD_M7."
fi
