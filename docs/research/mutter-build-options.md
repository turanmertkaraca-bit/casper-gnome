# Mutter 48.7 build options — what actually matters on Gen7

Verified against the real `meson.options` from `https://raw.githubusercontent.com/GNOME/mutter/48.7/meson.options`
(HTTP 200, 4514 bytes; identical across 48.0 / 48.6 / 48.7). Note: the file is
`meson.options` in 48.x — `meson_options.txt` returns 404 at every 48.x tag.

## Headline finding

**No meson option in mutter 48.7 makes Gen7 render faster while keeping
animations.** The build options are about *which* drivers/features are compiled
in, not about tuning the frame path. The only runtime-relevant lever is
`-Dopengl=false`, and even that is a driver-selection change rather than a
speed knob.

This is an important negative result: it means "rebuild mutter for speed" via
configure flags is *not* where the wins are. The wins are in the kernel cmdline,
the Mesa driver path, and shell-level effect scope.

## Option table (runtime-relevant only)

| Option | Default | What it actually changes | Verdict for this device |
|---|---|---|---|
| `opengl` | `true` | `meson.build:196` → `have_gl`; gates `HAVE_GL`, which adds `COGL_DRIVER_ID_GL3` to `_cogl_drivers[]` (`cogl/cogl/cogl-renderer.c:68-79`) and pulls `<GL/gl.h>` (`cogl-gl-header.h:39`) | **The one real lever.** `-Dopengl=false` removes the desktop-GL driver entirely, forcing the GLES2/EGL path. Plausibly *helps* Gen7: the i965/crocus GLES2 path is better exercised than desktop GL via GLX |
| `gles2` | `true` | `meson.build:216`, requires `egl`; adds `COGL_DRIVER_ID_GLES2` | **Keep true** — it is what makes `opengl=false` usable |
| `egl` | `true` | `meson.build:202` → `HAVE_EGL` | **Must stay true**; gles2 hard-errors without it |
| `glx` | `true` | `meson.build:207` = `get_option('glx') and have_x11` → `HAVE_GLX`, selects the GLX winsys for the GL3 driver (`meta-renderer-x11.c:59-73`) | Falls out of `opengl=false` anyway; no per-frame effect on its own |
| `wayland` | `true` | `meson.build:135`; errors if both wayland and x11 are false | Session choice |
| `x11` | `true` | `meson.build:136` | Session choice |
| `xwayland` | `true` | `meson.build:137` → `HAVE_XWAYLAND`; requires wayland | `false` drops XWayland startup + a selection/input bridge. Not per-frame |
| `profiler` | `true` | `meson.build:452` → `HAVE_PROFILER`, pulls `sysprof-capture-4` | `false` removes sysprof trace macros. **Magnitude UNVERIFIED** — call sites were not traced |
| `libwacom` | `true` | `meson.build:320` → `HAVE_LIBWACOM`; tablet handling only | `false` saves a dep; no frame-path gain |
| `sound_player` | `true` | libcanberra calls | `false` avoids sound-event calls. Small |
| `remote_desktop` | `true` | pulls the remote-desktop path | `false` trims surface-copy machinery you will not use |
| `startup_notification` | `true` | startup-notify protocol | `false` trims a little IPC |
| `catch` | `false` | `meson.build:430` — **test-only**, appends `catch` to test wrappers | **Zero runtime effect.** Already off |
| `devkit` | — | **DOES NOT EXIST in 48.7.** Only present in `main/meson.options:181`. Grepping 48.7 hits only stale `po/*.po` strings | Not passable; meson will reject it |

## Recommended configure line

```
-Dopengl=false -Dprofiler=false -Dlibwacom=false -Dsound_player=false \
-Dremote_desktop=false -Dxwayland=false -Dtests=false -Ddocs=false -Dintrospection=true
```

Keep `-Dintrospection=true`: `gir1.2-mutter-16` is how the shell talks to mutter,
and `gnome-shell` depends on `gir1.2-mutter-16 (>= 48.0)`.

Caveats:
- `-Dxwayland=false` means **no X11 apps at all**. Only do this if the session is
  pure Wayland and you accept losing XWayland.
- `-Dopengl=false` needs verification on real hardware: if crocus exposes GLES 3.0
  (it does — see `gen7-crocus.md`), GLES2 driver selection should work, but
  confirm the compositor actually comes up before shipping.

## What is NOT here

- No option controls buffer count, vsync, or scanout.
- No option disables compositing for fullscreen windows (that is a runtime code
  path, not a build flag).
- `MUTTER_DEBUG_*` env vars are runtime, not build-time — see
  `kernel-gpu-params.md` and `shell-frame-hotpaths.md`.

## Sources

- `https://raw.githubusercontent.com/GNOME/mutter/48.7/meson.options` (verified, HTTP 200)
- `https://github.com/GNOME/mutter/archive/refs/tags/48.7.tar.gz` (11,317,318 bytes, extracted)
- Debian trixie: `mutter` 48.7-0+deb13u1, `libmutter-16-dev`, `libmutter-16-0`
