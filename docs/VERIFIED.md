# Verified results

Everything here was measured in CI on this repo. Each entry names the evidence.
Anything not listed is unverified and is called out in `README.md` and
`HANDOFF.md`.

---

## 1. Kernel — green

Job `Kernel 6.12 (Bay Trail + IIO sensor)`. Asserted **after** `olddefconfig`
resolution, so a silently-dropped symbol fails the build:

| Symbol | Why it matters |
|---|---|
| `CONFIG_EFI_MIXED=y` | the 32→64-bit thunk; without it IA32 firmware cannot enter the kernel |
| `CONFIG_EFI_STUB=y` | required alongside it |
| `CONFIG_DRM_I915=y` | Gen7 graphics |
| `CONFIG_SND_SOC_INTEL_BYTCR_RT5640_MACH=y` | audio; without it the tablet is silent |
| `CONFIG_RTL8723BS=m` | Wi-Fi — **module only**, `=y` is impossible (`depends on m`) |
| `CONFIG_CFG80211=m`, `CONFIG_WLAN=y` | its dependencies |
| `CONFIG_ZRAM=y` | compressed swap on a 2 GB device |
| `CONFIG_IIO=y` | **required**: `drivers/iio/accel/Kconfig` is sourced inside `if IIO` |
| `CONFIG_MMA8452=m` | the accelerometer driver |

Artifacts produced:

```
LD [M] drivers/staging/rtl8723bs/r8723bs.ko      (note the name: r8723bs)
     drivers/iio/accel/mma8452.ko
```

`bzImage` verified to report **both** `32-bit EFI handoff entry point` and
`64-bit EFI handoff entry point`. (`bzImage` is not an ELF, so
`file | grep x86-64` fails on a perfectly good build — the handoff entries are
the correct assertion.)

## 2. Patched mutter + gnome-shell — green

Job `Rebuilt mutter + gnome-shell`. Verified:

- both patches applied against the **real Debian source** for
  gnome-shell `48.7-0+deb13u2` / mutter `48.7-0+deb13u1`
- built with `DEB_CFLAGS_SET="-O3 -march=silvermont"`
- **`objdump -d libmutter-16.so | grep -c avx` = 0** — a correct Silvermont
  build must not emit AVX, so this proves the flag actually applied

Artifact: `rebuilt-debs`.

## 3. Disk image — builds and boots to systemd

Job `GNOME image`. Verified from the build log:

```
OK BOOTIA32.EFI present (106496 bytes)
Installing for i386-efi platform.   (twice: removable + vendor path)
OK messagebus user exists
OK machine-id is valid
OK _greetd user exists
OK greetd wired as display-manager.service
OK agreety present
OK image: /tmp/casper-gnome.img (3.8G)
```

Verified from the boot serial log:

```
BdsDxe: starting Boot0001 "UEFI Misc Device"
[  OK  ] Reached target sysinit.target
systemd-logind[352]: New seat seat0.
systemd[1]: Started systemd-logind.service
[  OK  ] Started polkit.service / udisks2.service / NetworkManager.service
```

So the chain **firmware → IA32 loader → 64-bit kernel → systemd userspace** is
confirmed on a real built image.

**Not yet reached:** `multi-user.target` and `graphical.target`. No desktop.

---

## Bugs found by verification (all fixed)

These are the concrete value of automating the checks. Several would have looked
like hardware faults on the tablet.

| Bug | Symptom it produced |
|---|---|
| `CONFIG_GPIO_LYNXPOINT`, `CONFIG_MEMCG_SWAP`, `CONFIG_ANDROID` invented | silently dropped; feature simply absent |
| `CONFIG_RTL8723BS=y` (impossible: `depends on m`) | kernel builds, **no Wi-Fi**, on a device with no Ethernet |
| Module named `r8723bs.ko`, not `rtl8723bs.ko` | verification looked for a file that never exists |
| `ZRAM_DEF_COMP_*` choice-group conflict | wrong default compressor |
| `SECURITY_SELINUX` deps on `AUDIT`/`NET`/`INET` missing | SELinux silently off; init then fails looking like a binder bug |
| GCC 15 C23 `bool` breaks 6.12's EFI stub | kernel will not build on a modern toolchain |
| `-Werror=unterminated-string-initialization` in ACPI | same |
| `file \| grep x86-64` on a bzImage | fails a good kernel |
| secboot IA32 OVMF without `smm=on` | `IA32 Exception 06 (#UD)` at the reset vector |
| **Unterminated heredoc** | an entire build stage silently never executed |
| **`dd`-style `machine-id` truncated to empty** | logind fails `status=238/STATE_DIRECTORY` in a restart loop |
| `dbus` missing from the package list | logind cannot reach the system bus |
| `greetd` configured but never enabled | no session launcher at all |
| greetd symlinked into `multi-user.target.wants` | starts nothing; its unit has `Alias=display-manager.service` and no `WantedBy` |
| greetd `user = "greeter"` | Debian ships `_greetd`; greetd exits 1 at startup |
| `agreety` not on greetd's non-root PATH | greeter "not found" |
| `[ -e ]` on a symlink into `$ROOT` | tests the target on the **host**, where it does not exist |
| `casper-growroot` resizing a **mounted rw** root | stalls; `multi-user.target` never completes |
| `plymouth-quit-wait` with no graphical client | holds the target open indefinitely |

---

## A methodology error worth recording

An early run of the boot harness reported:

> "RESULT: the 32-bit UEFI handoff into the Android kernel WORKS."

That was **wrong**. It came from a dark frame with white text that pixel
statistics called "kernel console". Rendering it as ASCII showed it read
**"Android-x86 9.0-r2"** — GRUB's menu with a dark theme.

A second false positive: counting `New seat seat0` as evidence of a GNOME
session. That is logind, not a desktop; it made the harness report success on an
image where greetd never ran.

**The rule that came out of this:** pixels prove only that *something rendered*.
A kernel claim needs `Linux version` in serial; a desktop claim needs
`greetd`/`gnome-shell` markers. Serial is primary, and it must be read from the
artifact rather than summarised from a 30-line log excerpt.

## Not verified

| Item | Blocker |
|---|---|
| Graphical session starting | current work |
| Touchscreen over 30+ min and across suspend | needs the tablet |
| RT5640 audio (first-second, no pop) | needs the tablet |
| RTL8723BS stability | needs the tablet |
| Panel rotation / brightness | needs the tablet |
| Whether crocus/GL works on real Gen7 | QEMU uses software rendering |
| Whether the two patches improve frame times | needs `sysprof` on the tablet |
| Our 6.12 kernel inside the image | the image currently also carries Debian's kernel; we install ours but GRUB lists both |
