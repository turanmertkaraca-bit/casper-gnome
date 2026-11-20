# CasperOS GNOME — Debian trixie + GNOME 48 on the Casper Nirvana N220/N240

A GNOME desktop for a 2014 Bay Trail tablet: **Intel Atom Z3735F, 2 GB RAM,
32-bit UEFI on a 64-bit CPU, Gen7 graphics, 1366×768**.

The goal is unusual and specific: **keep GNOME and keep its animations**, and
make it smooth anyway. Not "a light desktop that looks like GNOME" — actual
GNOME, with the wasted work removed.

---

## Start here

| Document | What it answers |
|---|---|
| **[`docs/research/verification-audit.md`](docs/research/verification-audit.md)** | Which claims survived source-level re-checking. **Read this first** — it refutes two core assumptions |
| [`docs/research/bottleneck-verification.md`](docs/research/bottleneck-verification.md) | What actually limits Gen7 compositing, with corrected arithmetic |
| [`docs/research/direct-scanout.md`](docs/research/direct-scanout.md) | The biggest available win, verified in mutter source |
| [`docs/research/kernel-gpu-params.md`](docs/research/kernel-gpu-params.md) | i915 parameters verified against the 6.12 tree, including three that **do not exist** |
| [`docs/research/gnome-memory.md`](docs/research/gnome-memory.md) | Measured package sizes and what is genuinely removable |
| [`docs/research/debian-rebuild.md`](docs/research/debian-rebuild.md) | How to rebuild mutter/gnome-shell correctly |
| [`docs/sensors-mma8653.md`](docs/sensors-mma8653.md) | Screen rotation: the accelerometer plan |

---

## The three findings that define this project

### 1. GNOME Shell 48 is **not** a GTK4 shell

This was assumed by earlier planning and it is wrong. In the 48.7 source:

- Exactly **one** C file includes `<gtk/gtk.h>` — `src/shell-perf-helper.c`, a
  test helper.
- `StWidget` derives from `ClutterActor` (`src/st/st-widget.h:38`).
- The shell binary's dependency list (`src/meson.build:64-78`, `:282-289`) has
  **no `gtk_dep`**.
- **Nothing in `js/ui/` imports Gtk.** GTK4 is used only in three detached,
  out-of-process dialogs.

**This matters enormously:** Clutter actors composited by mutter are the *cheap*
path. Any plan to "rewrite the shell in GTK4 for speed" would move work onto a
heavier path and make things worse.

### 2. Fill rate is not the bottleneck. Nor is bandwidth.

Corrected arithmetic (see `bottleneck-verification.md`):

| Quantity | Value |
|---|---|
| Gen7 Bay Trail ROP fill at 646 MHz | ~2.6 Gpx/s |
| Needed for 1366×768 @ 60 fps | 63 Mpx/s |
| Headroom | **~40×** |
| Bandwidth for a full-screen composite @ 60 fps | ~0.5–0.8 GB/s |
| Available (single-channel DDR3L-1333) | 10.6 GB/s peak |
| Utilisation | **~9%** |

An earlier version of this research modelled fill as `px/clk × EU count`. That is
wrong for Gen7: pixels/clock is set by the shared Windower/Masker, not the EUs.

**So what is slow?** In order: **pass count** (each full-screen shader pass
re-touches the whole surface), **vsync/page-flip timing** (missing a vblank
halves the frame rate regardless of draw speed), and CPU/driver overhead in the
Gallium path.

### 3. Animations are cheap; full-screen *passes* are not

`js/ui/animation.js` is only the spinner. All real animation is `actor.ease()`
→ Clutter transitions on the compositor timeline. Motion itself costs almost
nothing.

What costs is what gets **re-drawn across the whole screen**. Two concrete
culprits, both now patched:

- `js/ui/lightbox.js` ran a per-pixel `rand()` dither (`sin`+`fract` per
  fragment) to hide banding in the darkening gradient.
- `js/ui/background.js` ran a radial vignette shader over the wallpaper at
  `brightness: 0.5`.

---

## What is in this repo

```
kernel/casper-gnome.fragment   Linux 6.12 config: EFI_MIXED, RT5640, RTL8723BS,
                               zram, and CONFIG_IIO + CONFIG_MMA8452
patch/0001,0002,series         Verified gnome-shell 48.7 patches
build/build-image.sh           mmdebstrap -> partitioned GPT image, IA32 GRUB
build/packages.list            Minimal GNOME set, names verified against trixie
test/boot-test.sh              QEMU IA32-UEFI boot verification
test/diag-sensors.sh           Accelerometer diagnostics (run this on the tablet)
.github/workflows/build.yml    kernel / rebuild / image jobs
```

The two patches were authored against the real 48.7 tree and verified with
`git apply --check` plus a full apply-and-inspect. They keep every animation.

---

## Corrections that were made mid-project

Recording these because they were found by adversarial verification, not because
they were obvious:

| Claim | Verdict |
|---|---|
| "GNOME Shell 48 is GTK4" | **Refuted** — it is Clutter/Mutter actors |
| "`CONFIG_IIO` is redundant, MMA8452 selects its deps" | **Refuted** — without `CONFIG_IIO` the driver cannot build at all |
| "Bay Trail gets GL 4.6" | **Refuted** — Gen7.0 is `verx10=70`, gets GL 4.2 |
| "Fill rate is the bottleneck" | **Refuted** — ~40× headroom |
| "Bandwidth is the bottleneck" | **Refuted** — ~9% utilisation |
| "`i915.enable_rc6` is a useful parameter" | **Refuted** — removed in 4.16 |
| "`i915.fastboot` is a useful parameter" | **Refuted** — removed in 6.7 |
| "`i915.fifo_underrun_reporting` exists" | **Refuted** — no such parameter |
| "Mutter 48 requires GLESv2" | **Verified** — fails at *configure* time |
| "`gnome-shell --force-animations` exists" | **Verified** |

---

## Status

**Verified in this environment:**
- Both patches apply cleanly to gnome-shell 48.7 and produce valid GLSL.
- All 76 kernel config symbols resolve in the real 6.12 Kconfig tree.
- Every package in `packages.list` exists in trixie (main or non-free-firmware).
- Scripts pass `bash -n`; the diag script runs end to end; the merge script
  produces no duplicate symbols.

**Not yet verified — needs CI or the tablet:**
- The kernel builds (CI job `kernel`).
- mutter/gnome-shell rebuild with `-march=silvermont` (CI job `rebuild`).
- The image boots under 32-bit UEFI (CI job `image`).
- Every hardware item: touchscreen, RT5640 audio, RTL8723BS, rotation.
- Whether the two patches measurably improve frame times. **They are reasoned,
  not measured** — this is the honest gap.

---

## The one experiment that decides the rest

Before more patching, measure. On the tablet:

```bash
sudo apt install sysprof
sysprof-cli --capture ...
```

If frame times are dominated by **pass count**, patching shaders helps.
If dominated by **vblank misses**, no shader work will fix it and the effort
belongs in the kernel/display path. The research says it is likely the latter,
which is why `i915.enable_fbc=1` is flagged as an experiment worth running
rather than a settled answer.
