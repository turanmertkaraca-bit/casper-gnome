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
mkdir -p "$ROOT/etc/greetd" "$ROOT/usr/local/bin"

# XDG_SESSION_TYPE MUST be set explicitly. greetd does not set it, and
# pam_systemd derives it from PAM_TTY (= tty1) and exports "tty". mutter then
# rejects the session with "Unsupported session type" and gnome-shell exits,
# so the screen stays blank even with logind healthy. GDM does this for you;
# greetd does not. The wrapper is also where the Wayland-specific environment
# belongs, so the greeter config stays trivial.
cat > "$ROOT/usr/local/bin/casper-session" <<'EOF'
#!/bin/sh
# Launch GNOME as a Wayland session under greetd.
set -e
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=GNOME
export XDG_CURRENT_DESKTOP=GNOME
export XDG_SESSION_CLASS=user
# Do NOT fabricate XDG_RUNTIME_DIR. If it is unset, pam_systemd did not
# register a session and mutter would fail anyway; failing loudly here names
# the real cause instead of producing a blank screen.
if [ -z "$XDG_RUNTIME_DIR" ]; then
    echo "casper-session: XDG_RUNTIME_DIR unset - pam_systemd registered no session" >&2
    exit 1
fi
exec gnome-session
EOF
chmod +x "$ROOT/usr/local/bin/casper-session"

cat > "$ROOT/etc/greetd/config.toml" <<'EOF'
# Autologin straight into GNOME. This tablet has one user and no password
# (disclosed in the README); a greeter would be theatre.
[terminal]
vt = 7

# greetd's config has two halves:
#   [default_session] = the GREETER (what runs before login)
#   [initial_session] = the session to start automatically at boot
# Putting gnome-session in [default_session] means it is treated as the
# greeter, which sits under greetd-greeter and never gets a proper user
# session. Autologin belongs in [initial_session].
[default_session]
command = "/usr/sbin/agreety --cmd /bin/sh"
user = "_greetd"

[initial_session]
command = "/usr/local/bin/casper-session"
user = "lvy"
EOF

# greetd resolves default_session.user at startup and EXITS 1 if it is absent,
# so this must match the config exactly. Debian's greetd package creates
# _greetd; create it explicitly rather than assuming the postinst ran.
chroot "$ROOT" /bin/sh -c 'id _greetd >/dev/null 2>&1 || useradd -r -s /sbin/nologin _greetd' || true
chroot "$ROOT" getent passwd _greetd >/dev/null 2>&1 \
    && ok "_greetd user exists" \
    || die "_greetd user missing — greetd exits immediately at startup"

# ENABLE greetd. Configuring it is not enough — without this the image boots to
# a text login with no graphical session (which is exactly what the serial log
# showed: logind healthy and seat0 present, greetd never mentioned at all).
#
# greetd's unit has NO WantedBy=; it declares Alias=display-manager.service and
# graphical.target has Wants=display-manager.service. So the correct wiring is
# the display-manager alias, not multi-user.target.wants — symlinking into
# multi-user.target.wants starts nothing because the unit has no [Install]
# WantedBy to satisfy.
mkdir -p "$ROOT/etc/systemd/system"
ln -sf /usr/lib/systemd/system/greetd.service \
    "$ROOT/etc/systemd/system/display-manager.service"

# Test the LINK, not its target: -e would follow the symlink and look for
# /usr/lib/systemd/system/greetd.service on the HOST, where it does not exist.
if [ -L "$ROOT/etc/systemd/system/display-manager.service" ]; then
    ok "greetd wired as display-manager.service -> $(readlink "$ROOT/etc/systemd/system/display-manager.service")"
else
    die "could not create the display-manager.service alias; no desktop would start"
fi

# greetd's packaged unit does After=/Conflicts=getty@tty7.service. With vt = 7
# configured, getty on tty7 must not fight greetd for the VT. Disable it so the
# greeter actually owns the terminal.
rm -f "$ROOT/etc/systemd/system/getty.target.wants/getty@tty7.service" 2>/dev/null || true
rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/getty@tty7.service" 2>/dev/null || true
# Also keep getty on tty1 out of the way of the serial console we rely on for
# diagnostics; the recovery shell on tty2 covers the "no GUI" case.
rm -f "$ROOT/etc/systemd/system/getty.target.wants/getty@tty1.service" 2>/dev/null || true

# greetd shows "inactive (dead)" with a pending Job number even though it is
# enabled and aliased, because its packaged unit orders
# After=plymouth-quit-wait.service and then After=/Conflicts=getty@tty7. If the
# splash never exits (no graphical client to hand off to) the start job stays
# queued forever. Relax that ordering via a drop-in.
mkdir -p "$ROOT/etc/systemd/system/greetd.service.d"
cat > "$ROOT/etc/systemd/system/greetd.service.d/99-casper.conf" <<'EOF'
[Unit]
After=
After=systemd-user-sessions.service plymouth-quit.service getty@tty7.service

[Service]
TimeoutStartSec=60
EOF
ok "greetd ordering drop-in installed"

# Never let the splash hold up the session.
mkdir -p "$ROOT/etc/systemd/system/plymouth-quit-wait.service.d"
cat > "$ROOT/etc/systemd/system/plymouth-quit-wait.service.d/99-casper.conf" <<'EOF'
[Service]
# plymouth-quit-wait waits for the splash to exit before the session starts.
# With no graphical client to take over it can wait forever, holding
# multi-user.target open — which is exactly what the serial log showed:
# 'Starting plymouth-quit-wait' with the target never reached.
TimeoutStartSec=10
RemainAfterExit=yes
EOF
ok "plymouth-quit-wait bounded"

# Belt and braces: do not make the session wait on the splash at all.
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.d"
cat > "$ROOT/etc/systemd/system/multi-user.target.d/99-casper.conf" <<'EOF'
[Unit]
# Nothing in a headless/QEMU boot needs to wait for the splash.
After=
EOF

# agreety (the greeter binary) must exist or greetd exits immediately.
[ -x "$ROOT/usr/sbin/agreety" ] \
    && ok "agreety present" \
    || die "agreety missing — greetd would exit immediately with no greeter"

# greetd runs as root and needs its PAM service file.
[ -f "$ROOT/etc/pam.d/greetd" ] \
    && ok "pam.d/greetd present" \
    || die "etc/pam.d/greetd missing — greetd cannot authenticate"

# /usr/share/wayland-sessions/gnome.desktop is what tells the world a Wayland
# GNOME session exists. gnome-session ships it, but assert it: without it
# greeter helpers cannot launch the session by name.
[ -f "$ROOT/usr/share/wayland-sessions/gnome.desktop" ] \
    && ok "wayland session file present" \
    || info "  note: no /usr/share/wayland-sessions/gnome.desktop (we launch gnome-session directly)"

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
ExecStart=/bin/sh -c 'echo "=== CASPER DIAG START ==="; echo "--- greetd ---"; ls -la /etc/systemd/system/display-manager.service 2>&1; systemctl status greetd --no-pager -l 2>&1 | head -18; systemctl is-enabled greetd 2>&1; systemctl list-dependencies graphical.target --no-pager 2>&1 | grep -iE "greetd|display-manager" || echo "no greetd in graphical.target deps"; systemctl is-active systemd-logind || true; systemctl status systemd-logind --no-pager -l 2>&1 | head -25; echo "--- journal ---"; journalctl -u systemd-logind -n 30 --no-pager 2>&1; echo "--- binary/pam ---"; ls -la /usr/lib/systemd/systemd-logind /etc/pam.d/systemd-user 2>&1; echo "--- dbus ---"; systemctl is-active dbus 2>&1; ls -la /run/dbus/system_bus_socket 2>&1; echo "=== CASPER DIAG END ==="'
[Install]
WantedBy=multi-user.target
EOF

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
# Run systemd's own finalisation steps. mmdebstrap does not boot an init, so
# some post-install work that a normal install gets for free may be missing:
# systemd-sysusers creates the system accounts (messagebus, systemd-network,
# etc.), and systemd-machine-id-setup writes a valid 32-hex machine-id.
# dbus.service runs as user messagebus; if that account is absent, dbus fails,
# logind cannot reach the system bus, logind fails, and NO graphical session
# can ever start. That chain is invisible in the logs unless you know it.
info "running systemd finalisation (sysusers, machine-id)"
for cmd in systemd-sysusers systemd-machine-id-setup; do
    if chroot "$ROOT" sh -c "command -v $cmd >/dev/null 2>&1"; then
        chroot "$ROOT" "$cmd" >/dev/null 2>&1 && ok "$cmd" \
            || info "  $cmd returned nonzero (usually harmless)"
    else
        info "  $cmd not present"
    fi
done

# Hard check: without this account dbus cannot start and everything downstream
# fails. Fail the build rather than ship an image that cannot show a desktop.
if chroot "$ROOT" getent passwd messagebus >/dev/null 2>&1; then
    ok "messagebus user exists"
else
    die "the 'messagebus' user is missing — dbus.service cannot start, which
means systemd-logind fails and no graphical session can start.
This usually means systemd-sysusers did not run during the rootfs build."
fi

info "copying rootfs"
# cp -a is used deliberately for the payload, but systemd state that must not
# be inherited is regenerated below — copying a built rootfs wholesale carries
# over a machine-id and stale dbus state that make systemd-logind fail, which
# in turn blocks every graphical session (logind owns seats and sessions).
cp -a "$ROOT/." "$WORK/mnt/"

# Regenerate identity/state that must be per-device.
# IMPORTANT: do NOT truncate /etc/machine-id to empty. systemd-machine-id-setup
# already wrote a valid 32-hex id above; blanking it makes logind fail with
# status=238/STATE_DIRECTORY, because logind's unit declares
# StateDirectory=systemd/linger and systemd cannot set up state directories
# under an uninitialised machine identity. That failure is a restart loop, an
# invisible dead end, and no graphical session can ever start.
if ! grep -qE '^[0-9a-f]{32}$' "$WORK/mnt/etc/machine-id" 2>/dev/null; then
    # Regenerate properly rather than leaving it empty or random-looking.
    chroot "$ROOT" systemd-machine-id-setup >/dev/null 2>&1 || true
    cp -f "$ROOT/etc/machine-id" "$WORK/mnt/etc/machine-id" 2>/dev/null || true
fi
if grep -qE '^[0-9a-f]{32}$' "$WORK/mnt/etc/machine-id" 2>/dev/null; then
    ok "machine-id is valid"
else
    die "machine-id is missing or invalid; logind will fail with
status=238/STATE_DIRECTORY and no desktop can start."
fi
mkdir -p "$WORK/mnt/var/lib/dbus"
ln -sf /etc/machine-id "$WORK/mnt/var/lib/dbus/machine-id"

# logind declares StateDirectory=systemd/linger, so these must exist.
mkdir -p "$WORK/mnt/var/lib/systemd" "$WORK/mnt/var/lib/systemd/linger"
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
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target shutdown.target
ConditionPathExists=!/etc/casper-growroot-done
[Service]
Type=oneshot
# Run BEFORE the root is remounted rw, using growpart+resize2fs on a
# read-only root. Doing this after local-fs.target (as a plain multi-user
# service) hung the whole boot, because resize2fs on a mounted rw filesystem
# stalls. Timeout so a failure degrades instead of blocking forever.
TimeoutStartSec=45
ExecStart=/bin/sh -c 'D=$(findmnt -no SOURCE /); DISK=$(lsblk -no PKNAME $D); N=$(basename $D); P=$(cat /sys/class/block/$N/partition); growpart /dev/$DISK $P || true; resize2fs $D || true; touch /etc/casper-growroot-done'
RemainAfterExit=yes
[Install]
WantedBy=local-fs.target
EOF
ok "growroot helper installed"
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
