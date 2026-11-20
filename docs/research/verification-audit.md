# Verification audit — claims tested against source

Adversarial re-check of the research corpus. Several claims were **refuted**, and
one correction is significant enough to change how we think about the shell.

## Verdict table

| # | Claim | Verdict |
|---|---|---|
| 1 | "GNOME Shell 48 is GTK4-based" | **REFUTED** — see below |
| 2 | "Mutter 48 requires GLESv2, errors without it" | **VERIFIED** (fails at *configure*, not compile) |
| 3 | "Bay Trail gets GL 4.2 / GLES 3.0, not 4.6" | **VERIFIED in substance**, but the code quote in `gen7-crocus.md` was a paraphrase presented as a quote — fixed |
| 4 | "gnome-shell hard-depends on gsd + gnome-control-center" | **VERIFIED exactly** |
| 5 | "The overview does not blur in GNOME 48" | **VERIFIED** |
| 6 | "`i915.enable_rc6` removed in 4.16; `fastboot` in 6.7" | **VERIFIED** |
| 7 | "`gnome-shell --force-animations` exists" | **VERIFIED** |
| 8 | "`CONFIG_IIO` is redundant for the sensor" | **REFUTED** — it is required |

---

## Correction 1 (important): GNOME Shell 48 is NOT a GTK4 shell

The Debian dependency on `gir1.2-gtk-4.0` / `libgtk-4-1` misled the earlier
research. What the source actually shows:

- `src/st/st-widget.h:38`:
  `G_DECLARE_DERIVABLE_TYPE (StWidget, st_widget, ST, WIDGET, ClutterActor)`
  — and `StWidgetClass`'s parent is `ClutterActorClass` (`:71`).
- **Exactly one C file in the tree includes `<gtk/gtk.h>`:
  `src/shell-perf-helper.c:14`** — a test helper.
- The `gnome-shell` executable's dependency list
  (`src/meson.build:64-78`, `:282-289`) is gio-unix, libxml, atk-bridge,
  gdk-pixbuf, gjs, mtk, clutter, gi, polkit, gcr, libsystemd, libpipewire,
  pango (+x11, nm). **No `gtk_dep`.** `gtk_dep` appears only at
  `src/meson.build:303` for `gnome-shell-perf-helper`.
- JS-side GTK4 use is confined to three **detached, out-of-process** helpers:
  `js/portalHelper/main.js:5`, `js/dbusServices/extensions/extensionPrefsDialog.js:6`,
  `js/dbusServices/screencast/screencastService.js:4`.
- **Nothing in `js/ui/` imports Gtk.**

**Actual architecture: Clutter/Mutter actors, with GTK4 only for out-of-process
dialogs.**

This is **good news** and it strengthens the plan: Clutter actors composited by
mutter are the cheap path. It also means any "port the shell to GTK4 to make it
faster" idea would be actively wrong — it would move work onto a heavier path.

## Correction 2: the crocus code quote was not verbatim

`gen7-crocus.md` presented this as a quote:

```c
glsl_feature_level = devinfo->verx10 >= 75 ? 460 : (ver >= 7 ? 420 : ...)
```

The real source (`crocus_screen.c`, Mesa main) is a chained assignment:

```c
355  caps->glsl_feature_level_compatibility =
356  caps->glsl_feature_level = devinfo->verx10 >= 75 ? 460 :
         (continuation on 357-358)
```

Also verified nearby: `:183 verx10 >= 75 ? CROCUS_MAX_TEXTURE_SAMPLERS : 16`.

`verx10` for Bay Trail is `70`, so the `>= 75` test fails and it does not get 460.
**Substance verified; the quote is now corrected.** The GLES 3.0 half was not
re-verified against `docs/features.txt`.

## Correction 3 (important): `CONFIG_IIO` IS required for the accelerometer

An earlier claim said "`CONFIG_IIO` is redundant, `MMA8452` selects its own deps."
That is **wrong**.

- `drivers/iio/accel/Kconfig` is sourced **inside `if IIO … endif # IIO`**
  (`drivers/iio/Kconfig:84`).
- `config MMA8452` (`drivers/iio/accel/Kconfig:566`) has `depends on I2C` and
  `select IIO_BUFFER` / `select IIO_TRIGGERED_BUFFER`. **It does not `select IIO`.**
- Therefore `CONFIG_MMA8452=m` alone leaves the symbol **invisible** — it will not
  build at all without `IIO` enabled.
- `IIO` is a `menuconfig` and is never `select`ed by `MMA8452`.

**Correct requirement: `CONFIG_IIO=y` AND `CONFIG_MMA8452=m`.**

The original advice we were given ("enable CONFIG_IIO and CONFIG_MMA8452") was
therefore **correct all along**, and my calling it redundant was the error.

## Verification detail: mutter fails at configure, not compile

`mutter/meson.build` @48.7:
- `:216-224` `have_gles2 = get_option('gles2')` → `dependency('glesv2')`,
  `error('GLESv2 support requires EGL to be enabled')`
- `:226-228` `error('Neither GLES2 or OpenGL was enabled')`
- `:285-287` **`error('The native backend requires GLESv2 to be enabled')`**
  inside `if have_native_backend`
- `meson.options:60-63` `native_backend` defaults **true**

So the failure is at meson **configure** time, and only while `native_backend` is on.

## Verified exactly: hard dependencies

Parsed `dists/trixie/main/binary-amd64/Packages.gz` (68,820 packages):

- `gnome-shell 48.7-0+deb13u2` `Depends:` contains
  **`gnome-control-center (>= 1:46)`** and **`gnome-settings-daemon (>= 47~rc)`**.
  Neither is optional.
- **`xdg-desktop-portal-gnome` hard-Depends on `nautilus (>= 47~beta)`** — so
  Nautilus is also not optional if the GNOME portal is installed. This contradicts
  any "minimal GNOME without Nautilus" plan.

## Patch-writing findings (from actually reading the code)

The three target files are **byte-identical between gnome-shell 48.0 and 48.7**
(`lightbox.js`, `shell-blur-effect.c`; `background.js` differs only in two
unrelated backports). So a patch authored against either applies to both.

Line numbers in the earlier doc were off by 1–2 throughout. Trust the tree:

- **`js/ui/lightbox.js`** noise shader is lines **10–29**:
  `VIGNETTE_DECLARATIONS` l.12–17, `VIGNETTE_CODE` l.19–29.
  The `rand()` function is in `VIGNETTE_DECLARATIONS`; the *use* is the last line
  of `VIGNETTE_CODE` (l.28):
  `cogl_color_out.a += (rand(position) - 0.5) * noise_magnitude;`

  **Critical:** the noise lives in the *same snippet* as the vignette darkening.
  Deleting the snippet kills the darkening. The surgical fix is to keep everything
  up to `cogl_color_out.a *= 1.0 - pixel_brightness * brightness;` and remove only
  the `noise_magnitude` declaration plus the `rand()` line.

- **`js/ui/background.js`**: `vignette: false` default at **line 699**; the `set({…})`
  block at **lines 801–805**, with `vignette: this._vignette` and `brightness: 0.5`.

- **`src/shell-blur-effect.c`**: anchors `#define MIN_DOWNSCALE_SIZE 256.f` /
  `#define MAX_RADIUS 12.f` (l.53–54). `update_background_fbo()` hardcodes
  `update_fbo(&self->background_fb, width, height, 1.0);`.
  `calculate_downscale_factor()` is shared by actor and brightness FBOs.

- Unlock dialog blur: `js/ui/unlockDialog.js:668` and `:686`, and it uses
  `SHELL_BLUR_MODE_ACTOR` (default), **not** background mode.

**Design blocker found for the blur patch:** simply passing `downscale_factor`
into `update_background_fbo()` is a **visual bug**. In `paint_background()` the
blit node is created against the paint context's framebuffer, so a downscaled
background FBO must also scale the blit rect. If that cannot be done surgically,
**withhold the patch** rather than ship a visibly wrong blur.

## What this means for the plan

The single most consequential correction is #1. The shell is Clutter-based, which
is the cheap path — so:

- Do **not** attempt a GTK4 shell rewrite; it would be slower.
- The wins remain: fewer full-screen passes (lightbox noise, background
  vignette), direct scanout for fullscreen content, vblank behaviour, shader
  cache, and the lean image.
- The `-Dopengl=false` mutter experiment stays worth testing.

## Sources
- `GNOME/gnome-shell` tags `48.0` (`a2ffd14`) and `48.7` (`e3017af`), cloned
- `GNOME/mutter` tags `48.0` (`3af3738`) and `48.7` (`f4abb82`), cloned
- Debian trixie `Packages.gz`, 68,820 packages, stanza-parsed
- `torvalds/linux` v6.12, `drivers/iio/`, `drivers/gpu/drm/i915/`
