# GNOME Shell 48 — where frames actually cost (for keeping animations)

Verified by cloning `GNOME/gnome-shell` at branch `48.0`
(commit `a2ffd14` "Bump version to 48.0", `meson.build` version `48.0`).

## Two findings that change the plan

### 1. The Overview is NOT blurred in GNOME 48

`grep blur js/ui/overviewControls.js js/ui/overview.js js/ui/appDisplay.js js/ui/windowPreview.js`
→ **no hits**. The only JS consumer of `Shell.BlurEffect` in the whole shell is
`js/ui/unlockDialog.js:667`.

This kills a common assumption. People disable "overview blur" in older GNOME
and think they have won. In 48 there is nothing to disable there — the overview
is not blurring. Any plan that starts with "remove the overview blur to save
GPU" is optimising a cost that does not exist in this version.

### 2. Animations are compositor-side, not JS redraw storms

`js/ui/animation.js` is **only the spinner** (73 lines):
- `SPINNER_ANIMATION_TIME = 300` (l.7), `SPINNER_ANIMATION_DELAY = 1000` (l.8)
- driven by `this.ease({opacity: 255, ...})` (l.40–45, 54–58)

There is **no JS timer-driven animation system**. Everything else uses
`actor.ease()` / `adjustment.ease()` → **Clutter transitions on the compositor
timeline**. That is cheap on the main loop.

**But** each transition still forces a full-stage repaint per frame, and on a
fill-rate-bound Gen7 that is where the cost lands. So: *motion itself is not the
problem; per-frame repainted area and offscreen buffers are.*

The real helper is `js/misc/animationUtils.js`:
- `SCROLL_TIME = 100` (l.6), `WIGGLE_OFFSET = 6`, `WIGGLE_DURATION = 65`, `N_WIGGLES = 3`
- `adjustAnimationTime()` (l.22–32) returns `0` when `!settings.enable_animations`
  (unless `params.animationRequired`), else `settings.slow_down_factor * msecs`
- `wiggle()` early-returns when animations are disabled (l.87)

`slow_down_factor` default is `1.` (`src/st/st-settings.c:547`, property
`slow-down-factor` l.397–401). `GNOME_SHELL_SLOWDOWN_FACTOR` env override at
`js/ui/environment.js:356–361`.

**Useful for us:** `gnome-shell --force-animations` exists (verified in
`src/main.c`), which is the opposite of what most tuning guides do.

## Default animation durations (all verified in-tree)

| Constant | Value | File |
|---|---|---|
| `Overview.ANIMATION_TIME` | 250 | `js/ui/overview.js:12` |
| `SIDE_CONTROLS_ANIMATION_TIME` | 250 | `js/ui/overviewControls.js:28` |
| `WINDOW_ANIMATION_TIME` | 250 | `js/ui/workspaceAnimation.js:14` |
| `WINDOW_SCALE_TIME` | 200 | `js/ui/windowPreview.js:19` |
| `WINDOW_OVERLAY_FADE_TIME` | 200 | `js/ui/windowPreview.js:17` |
| `DASH_ANIMATION_TIME` | 200 | `js/ui/dash.js:16` |
| `POPUP_ANIMATION_TIME` | 150 | `js/ui/boxpointer.js:14` |
| `STARTUP_ANIMATION_TIME` | 500 | `js/ui/layout.js:19` |
| `BACKGROUND_FADE_ANIMATION_TIME` | 1000 | `js/ui/layout.js:20` |
| minimize / show / destroy | 400 / 150 / 150 | `js/ui/windowManager.js:30–36` |
| background fade | 1000 | `js/ui/background.js:122` |

## What actually costs GPU

### `ShellBlurEffect` — the expensive one
`src/shell-blur-effect.c`: **three FBOs** — `actor_fb`, `background_fb`,
`brightness_fb`, each a `CoglTexture2D` via `cogl_offscreen_new_with_texture`
(`update_fbo`). Constants `MAX_RADIUS 12.f`, `MIN_DOWNSCALE_SIZE 256.f` (l.53–54);
`calculate_downscale_factor()` halves until radius ≤ 12 or size < 256 px.

**Critical detail (l.42–44 doc comment):** in *background* mode the blur forces
`downscale_factor = 1.0` — a **full-resolution FBO that cannot be cached**. That
is a full-screen read+write per frame. On 4 EUs this is the single most
expensive effect in the shell.

Brightness pass is a fragment snippet `cogl_color_out.rgb *= brightness` (l.47–51).

**Port target:** this file, plus wherever blur is enabled. Since the overview
does not use it in 48, the only current user is the unlock dialog — so the win
here is *not shipping blur in our own effects*, not removing an existing cost.

### Lightbox / vignette
- `js/ui/background.js:700` `vignette: false` default; l.712, l.803–805 set
  `{vignette, vignette_shader, brightness}`.
- `js/ui/lightbox.js:16–28` builds a `rand()`-based noise shader; `vfunc_build_pipeline`
  at l.56–59.

`rand()` in a fragment shader is per-pixel work, and a full-screen darkening pass
costs a full-screen blend. These are cheap-ish but non-zero on Gen7.

## Concrete patch targets (animated UI preserved)

1. **`js/ui/lightbox.js:16–28`** — replace the `rand()` noise with a constant, or
   drop the snippet when the effect is disabled. Keeps the fade, removes the
   per-pixel shader.
2. **`js/ui/background.js:803–805`** — pass `brightness: 1.0` and skip `vignette`
   uniformly; guarantee `vignette:false` for overview/workspace managers
   (`layout.js:493–495`, `workspace.js:977`, `workspaceAnimation.js:36`).
3. **`js/ui/environment.js:356–361`** — add a `GNOME_SHELL_NO_EFFECTS`-style env
   that shadows `St.Settings` for (a) offscreen redirects, (b) radial shader,
   while leaving `enable_animations` **untouched**.
4. **Leave all `ease()` durations alone.** Motion is not the bottleneck.

## Caveat on `St.Widget` vs `Clutter.Actor`

Not fully enumerated in this pass — that mapping (which shell elements are real
GTK4 widgets vs compositor actors) is still UNVERIFIED and would need a file-by-file
audit. What *is* verified: the shell is GTK4-based in 48
(`gnome-shell` depends on `libgtk-4-1 (>= 4.12.0)`, `gir1.2-gtk-4.0`).

## Sources
- `git clone --depth 1 --branch 48.0 https://github.com/GNOME/gnome-shell.git` (commit `a2ffd14`)
- File/line references above are from that tree.
