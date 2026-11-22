# CasperOS GNOME — Debian trixie + GNOME 48 on the Casper Nirvana N220/N240

A GNOME desktop for a 2014 Bay Trail tablet: **Intel Atom Z3735F, 2 GB RAM,
32-bit UEFI on a 64-bit CPU, Gen7 graphics, 1366×768**.

The goal: **keep GNOME and keep its animations**, and make it smooth anyway.
Not a light desktop that imitates GNOME — actual GNOME with the wasted work
removed.

---

## Read this first

| Document | What it answers |
|---|---|
| **[`HANDOFF.md`](HANDOFF.md)** | Start here for continuing the work: state, next step, how to iterate |
| [`docs/VERIFIED.md`](docs/VERIFIED.md) | Every claim traced to its evidence, plus every bug the checks caught |
| [`docs/research/verification-audit.md`](docs/research/verification-audit.md) | Which assumptions were **refuted** by source-level checking |
| [`docs/research/bottleneck-verification.md`](docs/research/bottleneck-verification.md) | What actually limits Gen7 compositing, with arithmetic |
| [`docs/research/direct-scanout.md`](docs/research/direct-scanout.md) | The biggest available win, verified in mutter source |
| [`docs/research/kernel-gpu-params.md`](docs/research/kernel-gpu-params.md) | i915 parameters verified against 6.12, including three that do not exist |
| [`docs/research/gnome-memory.md`](docs/research/gnome-memory.md) | Measured package sizes; what is genuinely removable |
| [`docs/research/debian-rebuild.md`](docs/research/debian-rebuild.md) | Rebuilding mutter/gnome-shell correctly |
| [`docs/research/mutter-build-options.md`](docs/research/mutter-build-options.md) | Every meson option and whether it matters |
| [`docs/research/shell-frame-hotpaths.md`](docs/research/shell-frame-hotpaths.md) | Where shell frames actually cost |
| [`docs/research/gen7-crocus.md`](docs/research/gen7-crocus.md) | Mesa/crocus reality on Bay Trail |
| [`docs/research/compositor-alternatives.md`](docs/research/compositor-alternatives.md) | Honest comparison of other shells |
| [`docs/sensors-mma8653.md`](docs/sensors-mma8653.md) | Screen rotation: the accelerometer plan |

---

## Project status (as of the handoff)

| Piece | State |
|---|---|
| **Kernel 6.12** | **BUILDS, CI green.** `EFI_MIXED`, RT5640 audio, RTL8723BS Wi-Fi, zram, `IIO`+`MMA8452`. `r8723bs.ko` and `mma8452.ko` produced. |
| **Patched mutter + gnome-shell** | **BUILDS, CI green.** Both CasperOS patches apply to real Debian source; `-O3 -march=silvermont` verified by **0 AVX instructions**. |
| **Disk image** | **BUILDS and BOOTS.** GPT + FAT32 ESP + ext4, IA32 GRUB at both paths, `BOOTIA32.EFI` present. Reaches systemd userspace. |
| **Graphical session** | **NOT YET.** greetd does not start; `multi-user.target` stalls. Being worked. |
| **Hardware** | **UNTOUCHED.** No touchscreen, audio, Wi-Fi or rotation testing has happened. |

Everything above is measured in CI, not estimated.

---

## Corrections that shaped this project

Found by adversarial verification, not obvious in advance:

| Assumption | Reality |
|---|---|
| "GNOME Shell 48 is GTK4" | **False.** Clutter/Mutter actors; only 3 detached dialogs use GTK4. A GTK4 rewrite would be *slower* |
| "Fill rate is the bottleneck" | **False.** ~40× headroom |
| "Memory bandwidth is the bottleneck" | **False.** ~9% utilisation |
| "`CONFIG_IIO` is redundant" | **False.** The driver cannot build without it |
| "Bay Trail gets GL 4.6" | **False.** Gen7.0 → GL 4.2 / GLES 3.0 |
| "`i915.enable_rc6` / `.fastboot` are useful" | **False.** Removed in 4.16 / 6.7 |

Real bottlenecks, ranked: **pass count**, then **vsync/page-flip timing**, then
Gallium overhead.

---

## What the two patches do

- `patch/0001-lightbox-drop-per-pixel-noise-shader.patch` — removes the
  per-pixel `rand()` dither from the lightbox shader, **keeping** the vignette
  darkening (they share one snippet).
- `patch/0002-background-drop-vignette-shader.patch` — removes a second
  full-screen shader pass over the wallpaper.

**Animations are untouched in both.** They are reasoned from source, **not yet
benchmarked** — see `HANDOFF.md` for the measurement that settles it.

---

## Building

```bash
# locally (needs root: mmdebstrap)
sudo ./build/build-image.sh --out /tmp/casper-gnome.img --size 6G

# verify it boots under 32-bit UEFI
sudo ./test/boot-test.sh --img /tmp/casper-gnome.img
```

CI (`.github/workflows/build.yml`) runs three jobs: `kernel`, `rebuild`, `image`.
The image job builds the disk and boots it under IA32 OVMF before declaring
success.

---

## Honest limitations

- **No desktop has been seen yet.** The image boots to systemd; greetd/session
  startup is the current blocker.
- **QEMU cannot validate the GPU.** Whether crocus/GL works on real Gen7, and
  whether the patches help, needs the tablet.
- **The image autologins with no password and has passwordless sudo.** That is
  inherited from the original CasperOS design and is fine for a personal
  single-user tablet, wrong on a shared network.
- **`mitigations=off`** is set for Silvermont performance. Disclosed, deliberate.
