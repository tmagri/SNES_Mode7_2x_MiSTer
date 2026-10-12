#!/usr/bin/env bash
# check_abi.sh — verify rtl/m7_abi.svh and daemon/m7_abi.h define identical
# constants. This is the no-hardware regression test for the address
# convention (the factor-of-2 mailbox bug shipped because FPGA and daemon
# disagreed about units; this script makes that class of bug un-shippable).
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTL="$DIR/rtl/m7_abi.svh"
HDR="$DIR/daemon/m7_abi.h"

# Emit "NAME VALUE(decimal)" lines for every M7_* constant in a file.
# Handles both `localparam [x:y] NAME = 32'hVAL;` and `#define NAME 0xVALu`.
extract() {
    awk '
    {
        sub(/\/\/.*/, "")                       # strip comments
        if ($0 ~ /localparam/ || $0 ~ /^#define/) {
            name = ""; val = ""
            for (i = 1; i <= NF; i++) {
                t = $i; sub(/;$/, "", t)
                if (t ~ /^M7_[A-Z0-9_]+$/) {
                    if ($(i+1) == "=")      { name = t; val = $(i+2) }
                    else if ($(i+1) != "")  { name = t; val = $(i+1) }
                }
            }
            sub(/;$/, "", val); sub(/u$/, "", val)
            if (name != "" && val ~ /^(0[xX]|[0-9]|[0-9]+.[hhd])/)
                print name, val
        }
    }' "$1"
}

# normalize <raw> — print a decimal value for 'hNN / 'dNN / 0xNN / NN forms.
normalize() {
    local raw="$1"
    case "$raw" in
        *\'h*) echo $(( 16#${raw##*\'h} )) ;;
        *\'d*) echo $(( 10#${raw##*\'d} )) ;;
        0[xX]*) echo $(( 16#${raw#0[Xx]} )) ;;
        [0-9]*) echo "$raw" ;;
        *) echo "BAD:$raw" ;;
    esac
}

# Constants that legitimately live on only one side:
#   *_WORD are DDR3 read-port word addresses (FPGA-side DMA bookkeeping);
#   flags/VRAM_WORDS are daemon-side parsing helpers.
FPGA_ONLY="M7_CTRL_WORD M7_PIXBUF_WORD M7_PIXBUF_B_WORD"
ARM_ONLY="M7_FLAG_DUMP_BUSY M7_FLAG_DUMP_DONE M7_VRAM_WORDS"

rtl_vals="$(extract "$RTL" | while read -r n v; do echo "$n $(normalize "$v")"; done)"
hdr_vals="$(extract "$HDR" | while read -r n v; do echo "$n $(normalize "$v")"; done)"

rtl_n="$(echo "$rtl_vals" | grep -c . )"
hdr_n="$(echo "$hdr_vals" | grep -c .)"

if [ "$rtl_n" -eq 0 ] || [ "$hdr_n" -eq 0 ]; then
    echo "ERROR: could not extract constants (rtl: $rtl_n entries, header: $hdr_n)" >&2
    exit 1
fi

fail=0
while read -r name val; do
    other="$(awk -v n="$name" '$1 == n {print $2}' <<<"$hdr_vals")"
    if [ -z "$other" ]; then
        case " $FPGA_ONLY " in *" $name "*) continue ;; esac
        echo "MISMATCH: $name missing from daemon/m7_abi.h" >&2
        fail=1
    elif [ "$other" != "$val" ]; then
        echo "MISMATCH: $name rtl=$val header=$other" >&2
        fail=1
    fi
done <<<"$rtl_vals"

while read -r name val; do
    if ! awk -v n="$name" '$1 == n {found=1} END {exit !found}' <<<"$rtl_vals"; then
        case " $ARM_ONLY " in *" $name "*) continue ;; esac
        echo "MISMATCH: $name missing from rtl/m7_abi.svh" >&2
        fail=1
    fi
done <<<"$hdr_vals"

# --- kernel module window constants (kernel/m7_mem_wc/m7_mem_wc.c) ----------
# The module hard-codes the pixel-buffer window; it must match the ABI and
# the two ping-pong buffers must be contiguous so one WC mapping covers both.
KMOD="$DIR/kernel/m7_mem_wc/m7_mem_wc.c"
if [ -f "$KMOD" ]; then
    k_base="$(awk '/#define M7_PIXBUF_PHYS_BASE/ {print $3; exit}' "$KMOD" | sed 's/[uU][lL]*$//')"
    k_bytes="$(awk '/#define M7_PIXBUF_BYTES/ {print $3; exit}' "$KMOD" | sed 's/[uU][lL]*$//')"
    h_base="$(awk -v n="M7_PIXBUF_BASE" '$1 == n {print $2}' <<<"$hdr_vals")"
    h_bytes="$(awk -v n="M7_PIXBUF_BYTES" '$1 == n {print $2}' <<<"$hdr_vals")"
    h_bbase="$(awk -v n="M7_PIXBUF_B_BASE" '$1 == n {print $2}' <<<"$hdr_vals")"
    if [ -z "$k_base" ] || [ -z "$k_bytes" ] || [ -z "$h_base" ] || [ -z "$h_bytes" ] || [ -z "$h_bbase" ]; then
        echo "ERROR: could not parse kernel-module / header pixel constants" >&2
        exit 1
    fi
    if [ "$(normalize "$k_base")" != "$h_base" ]; then
        echo "MISMATCH: m7_mem_wc base $(normalize "$k_base") != header M7_PIXBUF_BASE $h_base" >&2
        fail=1
    fi
    if [ "$(normalize "$k_bytes")" != "$h_bytes" ]; then
        echo "MISMATCH: m7_mem_wc bytes $(normalize "$k_bytes") != header M7_PIXBUF_BYTES $h_bytes" >&2
        fail=1
    fi
    if [ "$h_bbase" -ne $((h_base + h_bytes)) ]; then
        echo "MISMATCH: pixel buffers not contiguous (B base $h_bbase != A base + bytes)" >&2
        fail=1
    fi
fi

if [ "$fail" = 0 ]; then
    echo "ABI OK: $rtl_n constants match between rtl/m7_abi.svh and daemon/m7_abi.h (kernel module window checked)"
fi
exit "$fail"
