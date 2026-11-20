#!/bin/sh
# casper-diag-sensors.sh — collect everything needed to make the MMA8653
# accelerometer work on the Casper Nirvana N220.
#
# Read-only. Makes no changes. Safe to run as a normal user (some paths need
# root; those are marked and skipped if unreadable).
#
# WHY THIS EXISTS
# The mainline mma8452 driver supports the MMA8653 (chip id 0x5a, 10-bit,
# I2C address 0x1d per the driver header), but it has NO ACPI match table —
# only of_device_id and i2c_device_id. So whether it binds depends entirely on
# how the firmware describes the sensor. There are three possible cases and
# they need completely different fixes; this script tells us which one we are in.
#
#   A) ACPI node with _HID=PRP0001 and _DSD compatible="fsl,mma8653"
#      -> should already bind; the problem is then the mount matrix.
#   B) ACPI node with an unrecognised vendor _HID
#      -> needs an acpi_device_id addition or a DSDT override.
#   C) No ACPI node at all (likely, for an Android-era Bay Trail tablet)
#      -> instantiate manually on the I2C bus/address.
#
# Usage: sh casper-diag-sensors.sh [--out DIR]
# Output: a tarball plus a human-readable summary on stdout.

set -u

OUT=""
[ "${1:-}" = "--out" ] && OUT="${2:-}"
[ -n "$OUT" ] || OUT="/tmp/casper-diag-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }

say() { printf '\n=== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "system"
{
    echo "date: $(date -Is)"
    echo "kernel: $(uname -r)"
    echo "cmdline: $(cat /proc/cmdline)"
    [ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release
    echo "board: $(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
    echo "product: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
} 2>&1 | tee "$OUT/00-system.txt"

# ── 1. is the driver even built? ─────────────────────────────────────────
say "driver availability"
{
    if [ -r "/boot/config-$(uname -r)" ]; then
        grep -E '^CONFIG_(IIO|MMA8452|MMA8452_)' "/boot/config-$(uname -r)" \
            || echo "no IIO/MMA8452 symbols found in /boot/config"
    else
        echo "/boot/config-$(uname -r) not readable"
    fi
    echo "--- module present on disk?"
    find /lib/modules/"$(uname -r)" -name 'mma8452*' 2>/dev/null \
        || echo "mma8452.ko not found"
    echo "--- module loaded?"
    lsmod 2>/dev/null | grep -E 'mma8452|industrialio' || echo "not loaded"
} 2>&1 | tee "$OUT/01-driver.txt"

# Note: CONFIG_IIO is REQUIRED, not optional. drivers/iio/accel/Kconfig is
# sourced inside 'if IIO', and MMA8452 does not select IIO. Without IIO the
# symbol is invisible and the driver cannot be built at all.

# ── 2. ACPI enumeration — the decisive question ──────────────────────────
say "ACPI devices"
{
    echo "--- all ACPI devices with a HID (looking for sensor-like names)"
    for d in /sys/bus/acpi/devices/*/hid; do
        [ -r "$d" ] || continue
        hid=$(cat "$d" 2>/dev/null)
        uid=$(cat "$(dirname "$d")/uid" 2>/dev/null || echo '')
        case "$hid" in
            *ACC*|*ACCEL*|*MMA*|*GEO*|*GYRO*|*SENS*|*PRP0001*|*INT3*|*10EC*)
                echo "  HID=$hid UID=$uid  ($(basename "$(dirname "$d")"))" ;;
        esac
    done
    echo "--- full HID list (for reference)"
    for d in /sys/bus/acpi/devices/*/hid; do
        [ -r "$d" ] && echo "  $(cat "$d" 2>/dev/null)"
    done | sort | uniq -c | sort -rn | head -40
    echo "--- anything already bound to mma8452?"
    find /sys/bus/i2c/drivers -maxdepth 2 -name '*mma8452*' 2>/dev/null
} 2>&1 | tee "$OUT/02-acpi.txt"

# ── 3. I2C buses and addresses ───────────────────────────────────────────
say "I2C"
{
    echo "--- adapters"
    if have i2cdetect; then
        i2cdetect -l 2>&1
    else
        echo "i2cdetect not installed (apt install i2c-tools)"
        ls /sys/bus/i2c/devices/ 2>/dev/null
    fi
    echo "--- devices already instantiated"
    ls -l /sys/bus/i2c/devices/ 2>/dev/null

    # The MMA8653 sits at 0x1d. Probe each bus for it.
    if have i2cdetect; then
        for bus in $(i2cdetect -l 2>/dev/null | sed -n 's/^i2c-\([0-9]*\).*/\1/p'); do
            echo "--- i2cdetect -y $bus (looking for 0x1d)"
            if [ "$(id -u)" = 0 ]; then
                i2cdetect -y "$bus" 2>&1 | sed "s/^/    /"
            else
                echo "    (needs root: sudo i2cdetect -y $bus)"
            fi
        done
    fi
} 2>&1 | tee "$OUT/03-i2c.txt"

# ── 4. IIO — is anything already exposed? ────────────────────────────────
say "IIO devices"
{
    if [ -d /sys/bus/iio/devices ]; then
        ls /sys/bus/iio/devices/
        for d in /sys/bus/iio/devices/iio:device*; do
            [ -d "$d" ] || continue
            echo "--- $d"
            echo "    name: $(cat "$d/name" 2>/dev/null)"
            echo "    sampling_frequency: $(cat "$d/sampling_frequency" 2>/dev/null)"
            for f in "$d"/in_accel*; do
                [ -e "$f" ] && echo "    $(basename "$f") = $(cat "$f" 2>/dev/null)"
            done
            [ -r "$d/mount_matrix" ] && cat "$d/mount_matrix" 2>/dev/null
        done
    else
        echo "no /sys/bus/iio/devices — CONFIG_IIO not enabled or no devices"
    fi
} 2>&1 | tee "$OUT/04-iio.txt"

# ── 5. iio-sensor-proxy (what GNOME actually uses) ───────────────────────
say "iio-sensor-proxy"
{
    if have monitor-sensor; then
        echo "running monitor-sensor for 5s"
        timeout 5 monitor-sensor 2>&1 | head -40
    else
        echo "monitor-sensor not installed (apt install iio-sensor-proxy)"
    fi
    systemctl status iio-sensor-proxy --no-pager 2>&1 | head -20
} 2>&1 | tee "$OUT/05-sensor-proxy.txt"

# ── 6. dmesg evidence ────────────────────────────────────────────────────
say "kernel log evidence"
{
    dmesg 2>/dev/null | grep -iE 'mma8452|mma865|iio|accel|i2c_hid|byt|LPSS' | tail -80 \
        || echo "dmesg not readable (run with sudo for full log)"
} 2>&1 | tee "$OUT/06-dmesg.txt"

# ── 7. ACPI tables (for offline decoding with iasl) ──────────────────────
say "ACPI tables"
{
    if [ -r /sys/firmware/acpi/tables/DSDT ]; then
        cp /sys/firmware/acpi/tables/DSDT "$OUT/DSDT.aml" 2>/dev/null \
            && echo "copied DSDT.aml"
        ls -l /sys/firmware/acpi/tables/ 2>/dev/null | head -20
    else
        echo "DSDT not readable (needs root)"
    fi
} 2>&1 | tee "$OUT/07-acpi-tables.txt"

# ── verdict ──────────────────────────────────────────────────────────────
say "WHAT TO DO NEXT"
{
    if lsmod 2>/dev/null | grep -q mma8452; then
        echo "mma8452 is loaded. If IIO shows no device, the sensor is not"
        echo "enumerated — go to case B or C below."
        echo "If IIO shows an iio:device, the issue is the mount matrix."
    fi

    if grep -qi 'PRP0001' "$OUT/02-acpi.txt" 2>/dev/null; then
        echo "CASE A: ACPI PRP0001 present. Check the _DSD compatible string;"
        echo "if it is fsl,mma8653 the driver should bind. If it binds but"
        echo "rotation is wrong, fix the mount matrix."
    elif grep -qiE 'HID=.*(ACC|SENS|MMA)' "$OUT/02-acpi.txt" 2>/dev/null; then
        echo "CASE B: an ACPI sensor node exists with a vendor HID."
        echo "mma8452 has NO acpi_device_id table, so it will not bind."
        echo "Fix: add that HID to a new mma8452_acpi_match[], or override"
        echo "the DSDT/SSDT to expose PRP0001 + fsl,mma8653."
    else
        echo "CASE C (most likely): no ACPI sensor node found."
        echo "The driver cannot auto-bind. Instantiate it manually:"
        echo "    sudo modprobe mma8452"
        echo "    echo mma8653 0x1d > /sys/bus/i2c/devices/i2c-N/new_device"
        echo "(replace N with the bus from 03-i2c.txt that shows 0x1d)."
        echo "Then verify WHO_AM_I returned 0x5a via dmesg."
    fi
} 2>&1 | tee "$OUT/08-verdict.txt"

# ── package ──────────────────────────────────────────────────────────────
TAR="$OUT.tar.gz"
tar -czf "$TAR" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null \
    && echo "wrote $TAR" \
    || echo "could not create tarball" >&2

echo
echo "Send this file back: $TAR"
echo "It contains no personal data."
