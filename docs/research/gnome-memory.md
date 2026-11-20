# GNOME 48 memory footprint on 2 GB

Sources: full Debian trixie `main/binary-amd64/Packages.gz` (68,820 packages),
parsed into a dependency-closure tool. Sizes are Debian `Installed-Size`
(on-disk KiB) — **MEASURED from package metadata**, not estimated.

## Package sizes (MEASURED)

| Package | Installed size |
|---|---|
| `gnome-shell` | 6.5 MiB |
| `gnome-shell-common` | 8.3 MiB |
| `mutter` | 0.2 MiB (libs are in `libmutter-16-0`) |
| `gnome-settings-daemon` | 1.4 MiB + `-common` 5.1 MiB |
| `gnome-session-bin` | 0.5 MiB |
| `nautilus` | 1.7 MiB + `nautilus-data` 12.1 MiB |
| `gnome-control-center` | 4.9 + `-data` 18.2 MiB |
| `gnome-user-docs` | **71.1 MiB** |
| `evolution-data-server` | 2.7 + `-common` 9.3 MiB |
| `evolution-common` | **64.4 MiB** |
| `gnome-software` | 7.1 + `-common` 6.7 MiB |
| `gnome-maps` | 5.8 MiB |
| `gnome-weather` | 1.0 MiB |
| `gnome-tour` | 2.8 MiB |
| `orca` (screen reader) | 15.4 MiB |
| `loupe` (image viewer) | 8.3 MiB |
| `seahorse` | 7.8 MiB |
| `simple-scan` | 5.8 MiB |
| `gnome-boxes` | 6.5 MiB |
| `papers` | 6.9 MiB |
| `shotwell` | 6.2 MiB |
| `gnome-system-monitor` | 5.7 MiB |
| `gnome-disk-utility` | 7.0 MiB |
| `gnome-calculator` | 7.4 MiB |
| `gnome-characters` | 4.0 MiB |
| `file-roller` | 4.8 MiB |
| `gnome-color-manager` | 3.5 MiB |
| `rygel` (DLNA) | 3.0 MiB |
| `gnome-remote-desktop` | 2.0 MiB |
| `cheese` | 0.5 MiB |
| `gnome-sound-recorder` | 0.7 MiB |

`gnome-documents` **does not exist in trixie** — already retired upstream.

## Dependency closure sizes (MEASURED)

| Metapackage | Installed size | Packages |
|---|---|---|
| `gnome-core` (Depends only) | **2,035 MiB** | 973 |
| `gnome-core` + Recommends | **3,193 MiB** | 1,358 |
| `gnome` + Recommends | 3,868 MiB | 1,503 |
| `task-gnome-desktop` + Recommends | 3,896 MiB | — |
| **Minimal shell stack** (gnome-shell + session-bin + gsd + mutter + portal-gnome, Depends only) | **1,040 MiB** | 624 |

**The 1,040 MiB figure is the one that matters**: a working GNOME Shell desktop
with no apps at all. On a 32–64 GB eMMC that is fine for disk.

## Biggest unnecessary closure offenders (MEASURED)

`firefox-esr` 260.4 MiB, `locales-all` 230.9, `ibus-data` 131.2, `libllvm19` 123.7,
`libreoffice-core` 117.0, `libwebkit2gtk-4.1-0` 94.4, `libwebkitgtk-6.0-4` 93.3,
`mesa-vulkan-drivers` 79.2, `gnome-user-docs` 71.1, `evolution-common` 64.4,
`gnome-backgrounds` 36.1, `pocketsphinx-en-us` 36.1, `speech-dispatcher` 27.8.

(`libreoffice` and `firefox-esr` come in via `gnome`'s Recommends — do not use
that metapackage.)

## What is actually removable (VERIFIED from Depends fields)

### Hard dependencies — cannot remove
- **`gnome-shell` hard-Depends on `gnome-settings-daemon (>= 47~rc)`** and
  **`gnome-control-center (>= 1:46)`**. gsd is **not** optional. Only its
  per-plugin *autostart* entries can be masked.
- `gnome-shell` hard-Depends on `gir1.2-gtk-4.0` → confirms the GTK4 shell.
- `libecal-2.0-3` / `libedataserver-1.2-27t64` are hard library deps even if the
  daemon goes.

### Removable
- **`evolution-data-server`** — gnome-shell only *Recommends* it. Remove the
  daemon; the libs stay.
- **`localsearch`** (provided by `tracker-extract` in trixie) — removable **only
  if** you also accept losing Nautilus file search, since `nautilus` hard-Depends
  on `localsearch`.

That last point is a real constraint worth stating plainly: **you cannot keep
Nautilus search and drop tracker.** Choose one.

## Realistic floor estimate

**ESTIMATE:** minimal shell stack ≈ **1.0–1.1 GiB disk**, plus a browser. RAM
floor for the shell + compositor at idle: **~200–300 MB** (gnome-shell 48 on
GTK4; older GTK3 shells were 150–250 MB). That leaves ~1.5 GB for applications
on a 2 GB device — workable for a browser, tight for more.

## Settings that do NOT reduce memory

`org.gnome.shell` keys (`dynamic-workspaces`, `app-picker-layout`,
`remember-mount-password`) are behavioural, not memory levers. `dynamic-workspaces`
may slightly reduce workspace count, which is a marginal effect. **There is no
GNOME 48 setting that meaningfully reduces shell RAM.**

## OOM strategy: systemd-oomd vs earlyoom

GNOME 48 sessions on systemd should use **systemd-oomd**, configured via
`oomd.conf` (`MemoryPressureLimit`, `ManagedOOMMemoryPressure`) and
`ManagedOOMMemoryPressureLimit` on user slices.

Rationale: systemd-oomd acts on **cgroup memory pressure**, so it can kill a
whole scope/slice (e.g. a runaway app) rather than one process, and it understands
systemd units. `earlyoom` kills individual PIDs by heuristic and can pick the
compositor. The existing CasperOS config already uses earlyoom with
`--avoid '(gnome-shell|mutter|...)'` to work around exactly that risk — with
systemd-oomd that workaround is unnecessary.

**Recommendation: use systemd-oomd on the GNOME image, not earlyoom.** Verify
`systemd-oomd` is enabled and set `ManagedOOMMemoryPressure=kill` on `user.slice`
plus a pressure limit tuned for 2 GB.

## Sources
- Debian trixie `main/binary-amd64/Packages.gz`, 68,820 packages, parsed.
- `Depends`/`Recommends` fields for the packages above.
