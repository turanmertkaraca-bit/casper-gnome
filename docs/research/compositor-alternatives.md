# Compositor / shell alternatives — is there a lighter GNOME-with-animations?

Goal: keep GNOME's look **and animations**, on Intel Gen7 (4 EUs), 2 GB RAM.

## Headline verdict

**There is no drop-in lighter compositor that keeps GNOME's ecosystem and
animations.** Every option is a trade, and the trades are large. What *is*
available is mutter-as-a-library, which is the only route to "GNOME behaviour,
our own chrome."

## Option 1 — Stay on GNOME Shell 48 + tune (recommended baseline)

- Full GNOME behaviour, animations, ecosystem, portals, accessibility.
- Tuning levers are documented in `mutter-build-options.md`,
  `gen7-crocus.md`, `kernel-gpu-params.md`, `shell-frame-hotpaths.md`.
- **`gnome-shell --force-animations` exists** (verified in `src/main.c`) — the
  opposite of what most tuning guides do.
- Cost: you live with gnome-shell's own footprint (~200–300 MB).

This is the safe default and should be measured before anything exotic.

## Option 2 — mutter + a custom minimal shell (the real "remake")

**Verified from source.** mutter is designed to host a shell:

- `libmutter-16.so` exposes `MetaContext` with the full lifecycle:
  `meta_create_context` → `configure` → `set_plugin_gtype` → `setup` → `start` → `run_main_loop`.
- `gnome-shell` itself does **not** use a GIR plugin — it calls
  `meta_context_set_plugin_gtype(context, gnome_shell_plugin_get_type())` and
  subclasses `MetaPlugin` in C (`src/gnome-shell-plugin.c`, 264 lines of thin
  vfunc stubs forwarding to `ShellWM`).
- `gir1.2-mutter-16` installs `Meta-16.typelib`, `Clutter-16.typelib`,
  `Cogl-16.typelib`, `Mtk-16.typelib` — exposing `Meta.Context`, `Meta.Display`,
  `Meta.Window`, `Meta.WindowActor`, `Meta.Workspace`, `Meta.WorkspaceManager`,
  `Meta.BackgroundActor`, `Meta.Laters`.

**Proven in the wild:**

- **Gala** (elementary OS): `WindowManagerGala : Meta.Plugin` in Vala, links
  `libmutter-16` for the 48 series. Notable: it **hand-maintains GIR overrides**
  (`vapi/Meta-16.metadata`, `Clutter-16.metadata`) per mutter API version — that
  is the real cost of this route.
- **GNOME Kiosk**: separate libmutter compositor,
  `G_DEFINE_FINAL_TYPE(KioskCompositor, …, META_TYPE_PLUGIN)`. README says
  "no panels, dashes, or docks". It *does* do Clutter animations
  (`kiosk_compositor_map_with_fade_in`). It supports a window-config with
  `set-window-type=dock` — **the only documented route to a small GNOME-look
  panel on raw mutter**.

**Assessment:** writing a GTK4/Clutter shell on mutter is *months*, not years,
and it keeps: GTK4, mutter's window management, gestures, HiDPI, portals,
`iio-sensor-proxy` rotation. You lose: GNOME's shell chrome, extensions, and the
polish of 20 years of bugfixing. Realistic for a long project; not a weekend.

**Caveat:** from GIR, subclassing `MetaPlugin` is *not* the documented path —
gnome-shell does it in C. A GJS shell would more likely be a Wayland client
that talks to a mutter instance, or you write the plugin in C. This needs a
spike before committing.

## Option 3 — Phosh / phoc

- GTK3 + wlroots. Lighter than mutter in principle.
- **Phone-first**: single app fullscreen; no overlapping windows.
- Animations exist but are not GNOME's animation set.
- Ecosystem: GTK apps fine; GNOME shell extensions no.
- Honest summary: good tablet UI, **not a GNOME desktop**, and the user has
  already moved away from it.

## Option 4 — Sway / Wayfire

- **Sway has no window animations** by default; `swayfx` (a fork) adds them.
- **Wayfire** has a proper animation plugin and is wlroots-based.
- Cost: lowest of all options.
- Loss: no GNOME shell chrome, no GNOME ecosystem integration, different
  everything. This is "a different desktop," not "GNOME".

## Option 5 — KWin / Plasma 6

- KWin Wayland on Gen7: **UNVERIFIED** — no solid Bay Trail performance reports
  were located. Plasma 6 is generally heavier than GNOME on memory.
- Runs on crocus in principle.
- Would be a wholesale desktop change, not a GNOME optimisation.

## Option 6 — COSMIC (System76), Enlightenment, LXQt+labwc

- COSMIC: new Rust compositor, smithay-based, has animations. Maturity on old
  Intel GPUs unknown. Interesting but unproven here.
- Enlightenment/EFL: very light, but polish and app integration are far from GNOME.
- LXQt+labwc: lightest, but no GNOME feel at all.

## Recommendation

**Two-track:**

1. **Track A (now):** GNOME Shell 48 as-is, tuned. Measure with sysprof. Apply
   the kernel/Mesa findings. This is cheap and reversible.
2. **Track B (parallel, long):** prototype a minimal GTK4 shell on
   `libmutter-16`. Start with a spike: get a bare `MetaPlugin` subclass
   registered and one window on screen. If that spike works, the project is real.
   If it does not, we have learned it for the cost of a week.

Do **not** start Track B by rewriting gnome-shell's JS. Fork the *chrome*, not
the *platform*.

## Sources
- `https://raw.githubusercontent.com/GNOME/mutter/48.7/meson.options` and mutter source tree
- `GNOME/gnome-shell` `src/main.c`, `src/gnome-shell-plugin.c` (48.0, commit `a2ffd14`)
- Debian trixie `gir1.2-mutter-16` file list
- elementary Gala `meson.build` (libmutter-16 for 48 series)
- GNOME Kiosk `kiosk-compositor.c`, `kiosk-main.c`
- Phoronix / GNOME blog posts referenced inline
