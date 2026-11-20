# Direct scanout in mutter 48 — exists, and it is the biggest available win

Verified by cloning `GNOME/mutter` at tags `48.0` and `48.7`
(48.7 = commit `f4abb824`, tag verified).

## File-name correction

`src/compositor/meta-compositor.c` and `meta-compositor-wayland.c` **do not exist
in 48**. The real files:

- `compositor.c`
- `meta-compositor-native.c`
- `meta-compositor-server.c`
- `meta-compositor-x11.c`
- `meta-compositor-view.c`
- `meta-compositor-view-native.c` ← **Wayland direct scanout lives here**
- `meta-compositor-x11.c` ← **X11 unredirect lives here**

## Two separate mechanisms

### Wayland / native: direct scanout (built on `CoglScanout`)

- `MetaCompositorViewNative` holds `MetaWaylandSurface *scanout_candidate` (weak)
  — `src/compositor/meta-compositor-view-native.c:52`
- `find_scanout_candidate()` — `:~154`
- `try_assign_next_scanout()` → `clutter_stage_view_assign_next_scanout()` — `:337`, `:348`
- `meta_compositor_view_native_maybe_assign_scanout()` — `:352`, called **every
  frame** from `meta_compositor_native_before_paint()` — `src/compositor/meta-compositor-native.c:42`
- Cogl side: `cogl_onscreen_direct_scanout()` — `cogl/cogl/cogl-onscreen.c:385`
- Backend impl: `meta_onscreen_native_direct_scanout()` —
  `src/backends/native/meta-onscreen-native.c:1851`, hooked at `:3105`

**What it does when it engages:** sets `meta_frame_native_set_scanout()`, and
`maybe_post_next_frame()` flips the **client's own buffer** on the primary plane —
`:1660` (`is_direct_scanout = meta_frame_native_get_scanout(frame_native) != NULL`),
logged at `:1747` as `"direct scanout"` vs `"composite"`.

**That is the whole compositor blit eliminated.** For a fullscreen video or a
fullscreen GTK app, this is the largest single saving available — no read of the
client buffer, no write to a staged framebuffer, no second scanout of the result.

### X11: unredirect (XComposite)

- `MetaCompositorX11.unredirected_window` — `src/compositor/meta-compositor-x11.c:47`
- `maybe_unredirect_top_window()` — `:307`
- `set_unredirected_window()` — `:274`

## Failure path to know about

`meta-onscreen-native.c:1833` handles `"Direct scanout page flip failed"`. This is
a **recovery, not a prevention**: a failed flip is only detected after posting,
then it warns and forces a repaint. Whether that shows up as a dropped frame or a
visible tear on Bay Trail is the open question.

**Watch for this in logs.** If it fires repeatedly, direct scanout is nominally
engaged but failing, and you get worse behaviour than plain compositing.

## 48.0 vs 48.7

- `meta-compositor-x11.c` and `org.gnome.mutter.gschema.xml.in` are **byte-identical**
  between the two tags.
- In `meta-compositor-view-native.c` the 48.7 deltas are log-only for
  `try_assign_next_scanout` (added `"Assigning scanout to stage view"` at `:347`)
  plus a rewrite of `find_frame_sync_candidate` (paint-box comparison replacing
  `meta_window_geometry_contains_rect`).
- **The direct-scanout candidate logic is unchanged** — findings apply to both.

## Why this matters for keeping animations

The user wants animations. Direct scanout engages on **static fullscreen opaque**
content, which is *not* what an animated shell is doing most of the time. So:

- It helps enormously for **fullscreen video, games, presentations, and any
  maximised app** — the "I'm actually using this thing" moments.
- It does **not** help the shell's own animations (overview, workspace switch),
  because those are multi-layer composites by definition.

So direct scanout is a big win for *content*, and orthogonal to shell animation
smoothness. Both tracks are worth doing, for different reasons.

## Also worth knowing

`gnome-shell --force-animations` exists (verified `src/main.c` in the 48.0 shell
tree). Normal tuning guides disable animations; this option does the opposite and
is the flag to use when the goal is to *keep* them.

## Not researched
- Issue-tracker query for known tearing bugs on Intel. The source-level hazard
  above is visible; real-world reports were not gathered.

## Sources
- `git clone --depth 1 --branch 48.0` and `--branch 48.7` of `https://github.com/GNOME/mutter`
- File/line citations above are from those trees.
