#!/usr/bin/env bash
# Build a minimal GNOME 48 image for the Casper Nirvana N220/N240.
#
# Target: Bay Trail Z3735F, 2 GB RAM, 32-bit UEFI on a 64-bit CPU, 1366x768.
# Desktop: GNOME Shell 48 with animations INTACT — the tuning here removes
# wasted work, not motion. See docs/research/ for the full reasoning.
#
# This builds a partitioned disk image: FAT32 ESP + ext4 root, IA32 GRUB at
# both the removable and vendor paths (many Bay Trail firmwares only boot one).
#
# Usage: sudo ./build-image.sh --out /tmp/casper.img --size 6G
#
# Requires root: mmdebstrap needs it for correct file ownership and device nodes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

OUT="/tmp/casper-gnome.img"
SIZE="6G"
WORK=""
DEB_DIR=""          # optional: directory of rebuilt mutter/gnome-shell debs
SUITE="trixie"
ARCH="amd64"

while [ $# -gt 0 ]; do
    case "$1" in
        --out)   OUT="$2"; shift 2 ;;
        --size)  SIZE="$2"; shift 2 ;;
        --work)  WORK="$2"; shift 2 ;;
        --debs)  DEB_DIR="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32mOK\033[0m %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "must run as root (mmdebstrap needs it)"

WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
ROOT="$WORK/root"
info "work: $WORK"

for t in mmdebstrap parted mkfs.vfat mkfs.ext4 losetup; do
    command -v "$t" >/dev/null || die "$t not found"
done

# ── 1. rootfs ─────────────────────────────────────────────────────────────
# No metapackage. gnome-shell hard-depends on gnome-settings-daemon and
# gnome-control-center, and xdg-desktop-portal-gnome hard-depends on nautilus,
# so those come in regardless — but everything else is chosen deliberately.
PKGS="$(grep -vE '^\s*(#|$)' "$REPO/build/packages.list" | tr '\n' ',' | sed 's/,$//')"
info "building rootfs ($SUITE/$ARCH)"
# mmdebstrap builds its own apt keyring inside the target and does not inherit
# the host's trust state, so it needs --keyring explicitly. Without this it
# fails immediately with "The repository ... is not signed" — which looks like
# a network or mirror problem but is not.
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
[ -f "$KEYRING" ] || die "missing $KEYRING (apt install debian-archive-keyring)"

mmdebstrap \
    --variant=minbase \
    --architectures="$ARCH" \
    --include="$PKGS" \
    --components=main,contrib,non-free-firmware \
    --keyring="$KEYRING" \
    --aptopt='Acquire::Retries "5"' \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    "$SUITE" "$ROOT" \
    "deb http://deb.debian.org/debian $SUITE main contrib non-free-firmware" \
    >"$WORK/mmdebstrap.log" 2>&1 \
    || { tail -40 "$WORK/mmdebstrap.log" >&2; die "mmdebstrap failed (see log above)"; }
ok "rootfs: $(du -sh "$ROOT" | cut -f1)"

# ── 2. optional rebuilt packages ─────────────────────────────────────────
if [ -n "$DEB_DIR" ] && ls "$DEB_DIR"/*.deb >/dev/null 2>&1; then
    info "installing rebuilt debs from $DEB_DIR"
    cp "$DEB_DIR"/*.deb "$ROOT/tmp/"
    chroot "$ROOT" /bin/sh -c 'apt-get install -y --no-install-recommends /tmp/*.deb' \
        || die "failed to install rebuilt debs"
    ok "rebuilt mutter/gnome-shell installed"
fi

# ── 3. kernel + initramfs ────────────────────────────────────────────────
# The kernel is built separately (see .github/workflows/build.yml, job
# 'kernel') and dropped in here, because the stock Debian kernel does not
# carry CONFIG_EFI_MIXED guarantees or our Bay Trail options.
KERNEL_DIR="${KERNEL_DIR:-$REPO/kernel/out}"
if [ -f "$KERNEL_DIR/bzImage" ]; then
    info "installing custom kernel"
    # Determine the kernel version. `strings | grep` exits non-zero when it
    # finds nothing, which under `set -e` aborts the script silently — so the
    # whole pipeline is guarded and there is a real fallback.
    KVER=$( { strings "$KERNEL_DIR/bzImage" 2>/dev/null \
              | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-z0-9.+-]*' \
              | head -1; } || true )
    if [ -z "$KVER" ] && [ -d "$KERNEL_DIR/modules/lib/modules" ]; then
        KVER=$(ls "$KERNEL_DIR/modules/lib/modules" 2>/dev/null | head -1 || true)
    fi
    [ -n "$KVER" ] || KVER="6.12.0"
    info "kernel version: $KVER"
    mkdir -p "$ROOT/boot"
    cp "$KERNEL_DIR/bzImage" "$ROOT/boot/vmlinuz-$KVER"

    # Install modules the way the kernel itself does, not with a raw cp -a:
    # Debian's /lib is a SYMLINK to /usr/lib, so 'cp -a src/lib $ROOT/' fails
    # with "cannot overwrite non-directory". Resolve it and copy the contents.
    if [ -d "$KERNEL_DIR/modules/lib/modules" ]; then
        MODDEST="$ROOT/usr/lib/modules"
        # If /lib -> usr/lib, usr/lib is the real home. Otherwise use /lib.
        if [ -L "$ROOT/lib" ]; then
            MODDEST="$ROOT/$(readlink -f "$ROOT/lib" | sed "s|^$ROOT/||")/modules"
        else
            MODDEST="$ROOT/lib/modules"
        fi
        mkdir -p "$MODDEST"
        cp -a "$KERNEL_DIR/modules/lib/modules/." "$MODDEST/"
        ok "modules installed to ${MODDEST#$ROOT}"
    else
        info "no modules directory alongside bzImage — kernel built without modules?"
    fi

    chroot "$ROOT" /bin/sh -c "depmod -a $KVER 2>/dev/null || true"
    ok "custom kernel $KVER installed"
else
    info "no custom kernel at $KERNEL_DIR — using the Debian kernel"
    info "(CONFIG_EFI_MIXED is set in Debian's amd64 config, so 32-bit UEFI still works)"
fi

# ── 4. session: greetd -> gnome ──────────────────────────────────────────
info "configuring the session"
mkdir -p "$ROOT/etc/greetd"
cat > "$ROOT/etc/greetd/config.toml" <<'EOF'
# Autologin straight into GNOME. This tablet has one user and no password
# (disclosed in the README); a greeter would be theatre.
[terminal]
vt = 1

[default_session]
command = "gnome-session"
user = "lvy"
EOF

# The user. No password: this is a single-user tablet and the existing image
# already discloses this. SSH, if enabled, is key-only (see below).
chroot "$ROOT" /bin/sh -c '
    id lvy >/dev/null 2>&1 || useradd -m -s /bin/bash lvy
    passwd -d lvy
    for g in audio video input render netdev bluetooth; do
        getent group "$g" >/dev/null && usermod -aG "$g" lvy
    done
    echo "lvy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-lvy
    chmod 440 /etc/sudoers.d/90-lvy
' || die "user setup failed"

# ── 5. kernel cmdline ────────────────────────────────────────────────────
# See docs/research/kernel-gpu-params.md — every entry is justified there, and
# parameters that do NOT exist in 6.12 are deliberately absent.
CMDLINE="quiet splash"
CMDLINE="$CMDLINE intel_idle.max_cstate=1"          # touchscreen freeze (LPSS I2C gating)
CMDLINE="$CMDLINE i915.enable_psr=0 i915.enable_dc=0"  # avoid Gen7 display stalls
# i915.enable_fbc is deliberately ABSENT: it may recover real bandwidth on a
# bandwidth-sensitive workload, but it caused flicker on this panel before.
# Test it as an experiment (see the research doc), do not ship it blind.
CMDLINE="$CMDLINE mitigations=off"                   # documented Silvermont win; personal tablet
CMDLINE="$CMDLINE nowatchdog transparent_hugepage=never"
# Serial console left on: if the graphical session fails, this is the only
# way to find out why without a working screen.
CMDLINE="$CMDLINE console=ttyS0,115200"

mkdir -p "$ROOT/etc/default/grub.d"
cat > "$ROOT/etc/default/grub.d/99-casper.cfg" <<EOF
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=1
GRUB_DISABLE_OS_PROBER=true
GRUB_CMDLINE_LINUX_DEFAULT="$CMDLINE"
EOF

# ── 6. tuning ────────────────────────────────────────────────────────────
info "applying tuning"
mkdir -p "$ROOT/etc/sysctl.d"
cat > "$ROOT/etc/sysctl.d/99-casper.conf" <<'EOF'
# zram-backed swap is RAM, so swap eagerly. The usual "swappiness=10" advice is
# for disk swap and would waste the entire benefit here.
vm.swappiness=180
vm.page-cluster=0
# eMMC has poor random-write behaviour; flush earlier and smaller.
vm.dirty_ratio=20
vm.dirty_background_ratio=5
EOF

cat > "$ROOT/etc/default/zramswap" <<'EOF'
ALGO=lz4
SIZE=2048
PRIORITY=100
EOF

# systemd-oomd, not earlyoom: it acts on cgroup pressure, so it can kill a
# whole runaway scope instead of guessing at individual PIDs and possibly
# picking the compositor.
mkdir -p "$ROOT/etc/systemd/system/user@.service.d"
cat > "$ROOT/etc/systemd/system/user@.service.d/oomd.conf" <<'EOF'
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
EOF

# Animations stay ON. This is the whole point of the project.
# Only the wasted per-frame work is removed, and that lives in the patched
# shell, not in a user setting.
mkdir -p "$ROOT/etc/dconf/db/local.d"
cat > "$ROOT/etc/dconf/db/local.d/00-casper" <<'EOF'
[org/gnome/desktop/interface]
# Keep animations. Do not add 'enable-animations=false' here.
clock-show-seconds=false

[org/gnome/shell]
# Fewer workspaces to composite.
dynamic-workspaces=true
EOF
chroot "$ROOT" /bin/sh -c 'command -v dconf >/dev/null && dconf update || true'

# ── 7. recovery path ─────────────────────────────────────────────────────
# With GNOME as the ONLY session, a compositor that fails to start means a
# black screen and no way back. This gives a shell on tty2.
info "installing recovery console"
set -x
cat > "$ROOT/etc/systemd/system/casper-recovery.service" <<'EOF'
[Unit]
Description=CasperOS recovery shell on tty2
After=systemd-user-sessions.service
# Only starts if the graphical session did not come up within 60s.
ConditionPathExists=!/run/casper-session-up
[Service]
Type=simple
ExecStart=/sbin/agetty --autologin root --noclear tty2 linux
Restart=always
[Install]
WantedBy=multi-user.target
EOF
# systemctl enable inside a chroot can return nonzero even on success (it warns
# that systemd is not the running init). Guard it so set -e does not kill the
# build at this point — this is exactly where the previous run died, right
# after "installing recovery console".
chroot "$ROOT" systemctl enable casper-recovery.service >/dev/null 2>&1 || \
    echo "  (note: could not enable casper-recovery.service; continuing)"

set +x

# Diagnostic: when logind fails, "Failed to start systemd-logind" is the only
# clue and it has dozens of causes. Dump the real reason to the serial console
# so a headless boot test can report it.
cat > "$ROOT/etc/systemd/system/casper-logind-diag.service" <<'EOF'
[Unit]
Description=Dump systemd-logind failure details to the console
After=systemd-logind.service
[Service]
Type=oneshot
# Output must go to /dev/console explicitly: a oneshot service's stdout lands
# in the journal, not on the serial console, which is why the first version of
# this unit produced nothing in the boot log.
StandardOutput=file:/dev/console
StandardError=file:/dev/console
ExecStart=/bin/sh -c 'echo "=== CASPER DIAG START ==="; systemctl is-active systemd-logind || true; systemctl status systemd-logind --no-pager -l 2>&1 | head -25; echo "--- journal ---"; journalctl -u systemd-logind -n 30 --no-pager 2>&1; echo "--- binary/pam ---"; ls -la /usr/lib/systemd/systemd-logind /etc/pam.d/systemd-user 2>&1; echo "--- dbus ---"; systemctl is-active dbus 2>&1; ls -la /run/dbus/system_bus_socket 2>&1; echo "=== CASPER DIAG END ==="'
[Install]
WantedBy=multi-user.target
chroot "$ROOT" systemctl enable casper-logind-diag.service >/dev/null 2>&1 || \
    echo "  (note: could not enable casper-logind-diag.service; continuing)"

# ── 8. disk image ────────────────────────────────────────────────────────
info "creating disk image ($SIZE)"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
parted -s "$OUT" mklabel gpt
parted -s "$OUT" mkpart ESP fat32 1MiB 513MiB
parted -s "$OUT" set 1 esp on
parted -s "$OUT" mkpart root ext4 513MiB 100%

LOOP=$(losetup -f --show -P "$OUT")
cleanup_all() {
    for m in "$WORK/mnt/sys" "$WORK/mnt/proc" "$WORK/mnt/dev/pts" "$WORK/mnt/dev" \
             "$WORK/mnt/boot/efi" "$WORK/esp" "$WORK/mnt"; do
        umount "$m" 2>/dev/null || true
    done
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup_all EXIT
mkfs.vfat -F32 -n CASPER_ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L casper-root "${LOOP}p2"

mkdir -p "$WORK/esp" "$WORK/mnt"
mount "${LOOP}p2" "$WORK/mnt"
info "copying rootfs"
# cp -a is used deliberately for the payload, but systemd state that must not
# be inherited is regenerated below — copying a built rootfs wholesale carries
# over a machine-id and stale dbus state that make systemd-logind fail, which
# in turn blocks every graphical session (logind owns seats and sessions).
cp -a "$ROOT/." "$WORK/mnt/"

# Regenerate identity/state that must be per-device.
rm -f "$WORK/mnt/etc/machine-id" "$WORK/mnt/var/lib/dbus/machine-id"
: > "$WORK/mnt/etc/machine-id"
ln -sf /etc/machine-id "$WORK/mnt/var/lib/dbus/machine-id" 2>/dev/null || true
rm -rf "$WORK/mnt/var/lib/systemd/linger" 2>/dev/null || true
rm -f "$WORK/mnt/etc/systemd/system/*.wants/systemd-logind.service" 2>/dev/null || true

ok "root filesystem copied (machine-id reset)"

# ── 9. bootloader ────────────────────────────────────────────────────────
# 32-bit UEFI is MANDATORY: Bay Trail firmware is IA32-only even though the CPU
# is x86_64. Install at BOTH paths because many Bay Trail firmwares mishandle
# NVRAM boot entries and only try the removable path.
info "installing IA32 GRUB"
mount "${LOOP}p1" "$WORK/esp"
mkdir -p "$WORK/mnt/boot/efi"
mount --bind "$WORK/esp" "$WORK/mnt/boot/efi"

# grub-install inspects /dev and /proc (it probes block devices and reads
# /proc/self/mountinfo), so those must be available INSIDE the chroot. Without
# them it fails with "cannot find a device for /boot/efi (is /dev mounted?)",
# which reads like a partitioning problem and is not.
info "bind-mounting /dev, /proc, /sys for grub-install"
for fs in dev dev/pts proc sys; do
    mkdir -p "$WORK/mnt/$fs"
    mount --bind "/$fs" "$WORK/mnt/$fs" 2>/dev/null || true
done

chroot "$WORK/mnt" /bin/sh -c '
    set -e
    grub-install --target=i386-efi --efi-directory=/boot/efi \
        --bootloader-id=CasperOS --boot-directory=/boot --removable --no-nvram
    grub-install --target=i386-efi --efi-directory=/boot/efi \
        --bootloader-id=CasperOS --boot-directory=/boot --no-nvram
    update-grub
' || GRUB_FAILED=1

# Unmount the bind mounts before anything else, in reverse order.
for fs in sys proc dev/pts dev; do
    umount "$WORK/mnt/$fs" 2>/dev/null || true
done

[ "${GRUB_FAILED:-0}" = 0 ] || die "grub-install failed (see the error above)"

# Hard check: the IA32 binary must exist. A 64-bit-only ESP would boot on a PC
# and black-screen on this tablet.
if [ -f "$WORK/esp/EFI/BOOT/BOOTIA32.EFI" ]; then
    ok "BOOTIA32.EFI present ($(stat -c %s "$WORK/esp/EFI/BOOT/BOOTIA32.EFI") bytes)"
else
    die "BOOTIA32.EFI missing — this image would NOT boot on the tablet"
fi

# ── 10. grow root to fill the eMMC on first boot ─────────────────────────
mkdir -p "$WORK/mnt/etc/systemd/system" "$WORK/mnt/usr/local/bin"
cat > "$WORK/mnt/etc/systemd/system/casper-growroot.service" <<'EOF'
[Unit]
Description=Grow root partition to fill the device
After=local-fs.target
Before=multi-user.target
ConditionPathExists=!/etc/casper-growroot-done
[Service]
Type=oneshot
ExecStart=/usr/local/bin/casper-growroot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
cat > "$WORK/mnt/usr/local/bin/casper-growroot" <<'EOF'
#!/bin/sh
set -e
ROOTDEV=$(findmnt -no SOURCE /)
DISK=$(lsblk -no PKNAME "$ROOTDEV")
PARTNUM=$(cat /sys/class/block/$(basename "$ROOTDEV")/partition)
growpart "/dev/$DISK" "$PARTNUM" || true
resize2fs "$ROOTDEV" || true
touch /etc/casper-growroot-done
EOF
chmod +x "$WORK/mnt/usr/local/bin/casper-growroot"
chroot "$WORK/mnt" /bin/sh -c 'systemctl enable casper-growroot.service 2>/dev/null || true'

sync
umount "$WORK/mnt/boot/efi" "$WORK/esp" "$WORK/mnt"
losetup -d "$LOOP"
trap - EXIT

ok "image: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Verify with:"
echo "  ./test/boot-test.sh --img $OUT"
echo
echo "NOTE: this image autologins with no password and has passwordless sudo."
echo "      Do not put it on a network you do not control."
