#!/usr/bin/env bash
# Boot a CasperOS GNOME disk image under 32-bit (IA32) UEFI and report how far
# the chain got.
#
# The tablet's firmware is IA32-only on an x86_64 CPU, so testing under x86-64
# OVMF would prove nothing. This uses IA32 OVMF specifically.
#
# Judgement is by framebuffer capture, because a GNOME session may not write
# anything useful to serial. A blank framebuffer means the chain is broken;
# real content means it rendered.
#
# Usage: ./boot-test.sh --img /tmp/casper-gnome.img [--wait 180]
# Exit: 0 rendered content, 1 blank/failed, 2 environment problem
set -euo pipefail

IMG=""; OUT="/tmp/casper-gnome-boot"; WAIT=180; MEM=2048
while [ $# -gt 0 ]; do
    case "$1" in
        --img)  IMG="$2"; shift 2 ;;
        --out)  OUT="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --mem)  MEM="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32mOK\033[0m   %s\n' "$*"; }

[ -n "$IMG" ] || die "--img is required" 2
[ -f "$IMG" ] || die "no such image: $IMG" 2
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed" 2

mkdir -p "$OUT"; rm -f "$OUT"/*.ppm "$OUT"/serial.log

# ── IA32 firmware ─────────────────────────────────────────────────────────
find_ia32() {
    for c in /usr/share/OVMF/OVMF32_CODE_4M.fd \
             /usr/share/OVMF/OVMF32_CODE_4M.secboot.fd \
             /usr/share/OVMF/OVMF32_CODE.fd; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done; return 1
}
FCODE="$(find_ia32 || true)"
if [ -z "$FCODE" ]; then
    info "fetching IA32 OVMF"
    # 2025.02+ is preferred: earlier packages ship only a secboot image, which
    # faults at the reset vector without SMM (IA32 Exception 06 at EIP 0xE0000).
    for ver in 2025.02-8+deb13u1 2022.11-6+deb12u2; do
        url="http://deb.debian.org/debian/pool/main/e/edk2/ovmf-ia32_${ver}_all.deb"
        curl -fsSL --max-time 180 -o "$OUT/ovmf.deb" "$url" 2>/dev/null || continue
        dpkg-deb -x "$OUT/ovmf.deb" "$OUT/ovmf" 2>/dev/null || continue
        FCODE=$(find "$OUT/ovmf" -name 'OVMF32_CODE*' ! -name '*secboot*' | head -1)
        [ -n "$FCODE" ] || FCODE=$(find "$OUT/ovmf" -name 'OVMF32_CODE*' | head -1)
        [ -n "$FCODE" ] && break
    done
    [ -n "$FCODE" ] || die "no IA32 OVMF available (apt install ovmf-ia32)" 2
fi
info "firmware: $FCODE"

# Verify it really is IA32; a 64-bit OVMF would make this test meaningless.
python3 - "$FCODE" <<'PY' || die "firmware is not IA32" 2
import struct, sys
d = open(sys.argv[1], 'rb').read()
m = set(); i = 0
while True:
    i = d.find(b'PE\0\0', i)
    if i < 0: break
    m.add(struct.unpack('<H', d[i+4:i+6])[0]); i += 4
print("PE machines:", {hex(x) for x in m})
sys.exit(0 if 0x14c in m else 1)
PY

VARS="$OUT/OVMF32_VARS.fd"
for v in /usr/share/OVMF/OVMF32_VARS_4M.fd /usr/share/OVMF/OVMF32_VARS.fd; do
    [ -f "$v" ] && { cp -f "$v" "$VARS"; break; }
done
[ -f "$VARS" ] || truncate -s 4M "$VARS"

EXTRA=()
case "$FCODE" in *secboot*) EXTRA=(-machine q35,smm=on); NEED_SMM=1;; *) NEED_SMM=0;; esac
[ "$NEED_SMM" = 1 ] && info "secboot firmware: SMM enabled"

# ── boot ──────────────────────────────────────────────────────────────────
# The image is a whole disk: attach as a disk, not a cdrom. -cpu max gives the
# x86-64-v2 feature set (SSE4.2/POPCNT) that Debian and GNOME expect.
info "booting ${MEM} MB, IA32 UEFI, ${WAIT}s"
MON="$OUT/mon.sock"; rm -f "$MON"
qemu-system-x86_64 \
    -machine q35 -m "$MEM" -cpu max \
    "${EXTRA[@]}" \
    -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$IMG",format=raw,if=virtio \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -display none -vga std -no-reboot \
    -serial "file:$OUT/serial.log" \
    -monitor "unix:$MON,server,nowait" \
    >"$OUT/qemu.log" 2>&1 &
QPID=$!
cleanup() { kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }
trap cleanup EXIT

mon() {
python3 - "$MON" "$1" <<'PY' 2>/dev/null || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10)
s.connect(sys.argv[1]); time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(1.0)
try: s.recv(65536)
except Exception: pass
s.close()
PY
}

for t in 30 60 120 "$WAIT"; do
    cur=0
    while [ "$cur" -lt "$t" ]; do
        kill -0 "$QPID" 2>/dev/null || break
        sleep 5; cur=$((cur + 5))
    done
    kill -0 "$QPID" 2>/dev/null || { info "qemu exited before ${t}s"; break; }
    mon "screendump $OUT/boot-${t}s.ppm"
    [ -s "$OUT/boot-${t}s.ppm" ] && info "captured ${t}s"
done
sleep 3; cleanup

# ── verdict ───────────────────────────────────────────────────────────────
RESULT=$(python3 - "$OUT" <<'PY'
import sys, glob, os
from collections import Counter
best = None
for p in sorted(glob.glob(os.path.join(sys.argv[1], 'boot-*.ppm'))):
    d = open(p, 'rb').read()
    if not d.startswith(b'P6'): continue
    f = []; i = 2
    while len(f) < 3:
        while d[i:i+1].isspace(): i += 1
        j = i
        while not d[j:j+1].isspace(): j += 1
        f.append(int(d[i:j])); i = j
    i += 1
    w, h, px = f[0], f[1], d[i:]
    n = min(len(px)//3, w*h); step = max(1, n//60000)
    nb = 0; c = Counter(); cnt = 0
    for k in range(0, n, step):
        r, g, b = px[k*3], px[k*3+1], px[k*3+2]
        cnt += 1
        if r or g or b: nb += 1
        if len(c) < 8000: c[(r >> 3, g >> 3, b >> 3)] += 1
    frac = nb / (cnt or 1); ncol = len(c)
    if frac < 0.01: kind = 'blank'
    elif ncol >= 200 and frac > 0.5: kind = 'rich-ui'
    elif ncol > 40: kind = 'graphical'
    else: kind = 'early'
    if best is None or frac > best[1]:
        best = (os.path.basename(p), frac, ncol, kind)
print("NONE" if best is None else "BEST %s nonblack=%.3f colours=%d kind=%s" % best)
PY
)
echo "$RESULT"

SER=$( [ -f "$OUT/serial.log" ] && stat -c %s "$OUT/serial.log" || echo 0 )
echo "serial: $SER bytes"
head -20 "$OUT/serial.log" 2>/dev/null || true

# A firmware crash looks identical to a broken boot in a screenshot, but means
# the TEST is misconfigured. Say so explicitly.
if grep -aq "Exception Type" "$OUT/serial.log" 2>/dev/null; then
    printf '\033[31mFIRMWARE FAULT\033[0m: %s\n' "$(grep -a -m1 'Exception Type' "$OUT/serial.log")"
    die "the IA32 firmware crashed before loading anything — test environment
problem, not evidence about the image. A secboot image needs -machine q35,smm=on."
fi

KIND=$(echo "$RESULT" | sed -n 's/.*kind=\([a-z-]*\).*/\1/p')
case "$KIND" in
    rich-ui)   ok "full graphical UI rendered"; echo "RESULT: boot chain works, GNOME rendered."; exit 0 ;;
    graphical) ok "graphical content rendered ($KIND)"; echo "RESULT: boot chain works."; exit 0 ;;
    early)     ok "some content rendered but not a full UI"; echo "RESULT: inconclusive — check serial."; exit 3 ;;
    *)         die "framebuffer blank — the image did not render anything." 1 ;;
esac
