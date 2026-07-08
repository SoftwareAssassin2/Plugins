#!/usr/bin/env bash
# Description: Profile the host's hardware (CPU, RAM, GPU, disk) cross-platform (macOS + Linux).
#
# Emits a labeled, human-readable block on stdout. Read-only — it only queries
# hardware, never changes anything. Tolerant: a missing tool or unsupported field
# degrades to "unknown" rather than aborting (no `set -e`; every probe is guarded).
# The /specs skill runs this and narrates the output in natural language.

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

# Format a byte count into a human unit (labels are decimal-vernacular GB/TB even
# though the divisor is 1024 — matches how people say "32 GB of RAM").
human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b+0<=0){ print "unknown"; exit }
    split("B KB MB GB TB PB", u, " ");
    i=1; v=b;
    while (v>=1024 && i<6){ v/=1024; i++ }
    printf (v>=10 ? "%.0f %s" : "%.1f %s"), v, u[i];
  }'
}

os="$(uname -s 2>/dev/null || echo unknown)"
os_line="unknown"; cpu_line="unknown"; ram_line="unknown"; gpu_line=""; disk_raw=""

case "$os" in
  Darwin)
    prod="$(sw_vers -productName 2>/dev/null || echo macOS)"
    ver="$(sw_vers -productVersion 2>/dev/null || echo '?')"
    os_line="$prod $ver ($(uname -s) $(uname -r), $(uname -m))"

    brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    logical="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
    physical="$(sysctl -n hw.physicalcpu 2>/dev/null || echo '')"
    if [ -n "$physical" ] && [ "$physical" != "$logical" ]; then
      cpu_line="$brand — $physical cores / $logical threads"
    else
      cpu_line="$brand — $logical cores"
    fi

    ram_line="$(human_bytes "$(sysctl -n hw.memsize 2>/dev/null || echo 0)")"

    if have system_profiler; then
      gpu_line="$(system_profiler SPDisplaysDataType 2>/dev/null \
        | awk -F': ' '/Chipset Model/{print $2}' | paste -sd '; ' -)"
    fi

    disk_raw="$(df -k / 2>/dev/null | awk 'NR==2{printf "%s|%s", $2*1024, $4*1024}')"
    ;;

  Linux)
    pretty="$( ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}" ) )"
    os_line="$pretty ($(uname -s) $(uname -r), $(uname -m))"

    brand="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    if [ -z "$brand" ] && have lscpu; then
      brand="$(lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}')"
    fi
    [ -z "$brand" ] && brand="unknown"
    threads="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')"
    cpu_line="$brand — $threads threads"

    ram_line="$(human_bytes "$(( $(awk '/MemTotal/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0) * 1024 ))")"

    if have nvidia-smi; then
      gpu_line="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd '; ' -)"
    fi
    if [ -z "$gpu_line" ] && have lspci; then
      gpu_line="$(lspci 2>/dev/null | grep -iE 'vga|3d|display controller' | sed 's/^[^:]*: //' | paste -sd '; ' -)"
    fi

    disk_raw="$(df -kP / 2>/dev/null | awk 'NR==2{printf "%s|%s", $2*1024, $4*1024}')"
    ;;

  *)
    os_line="unsupported OS ($os) — this profiler covers macOS and Linux"
    ;;
esac

[ -z "$gpu_line" ] && gpu_line="unknown"

disk_total="unknown"; disk_free="unknown"
if [ -n "$disk_raw" ]; then
  disk_total="$(human_bytes "${disk_raw%%|*}")"
  disk_free="$(human_bytes "${disk_raw##*|}")"
fi

printf 'OS:    %s\n' "$os_line"
printf 'CPU:   %s\n' "$cpu_line"
printf 'RAM:   %s\n' "$ram_line"
printf 'GPU:   %s\n' "$gpu_line"
printf 'Disk:  root volume / — %s total, %s free\n' "$disk_total" "$disk_free"
