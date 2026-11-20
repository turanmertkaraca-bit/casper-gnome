# Gen7 / crocus — Bay Trail graphics reality check

Bay Trail Z3735F, Intel HD Graphics Gen7 (4 EUs, 311–646 MHz), Debian trixie
(mesa 25.0.7), Wayland GNOME, goal = **keep animations, make them smooth**.

## Three corrections to earlier assumptions

### 1. Bay Trail is Gen7.0, and it does NOT get OpenGL 4.6

From `crocus_screen.c` (Mesa source):

```c
glsl_feature_level = devinfo->verx10 >= 75 ? 460 : (ver >= 7 ? 420 : ...)
```

Bay Trail is **Gen7.0** (`verx10 == 70`) → **GLSL 4.20 → OpenGL 4.2 core**.
**GLES 3.0** (`docs/features.txt` gates GLES 3.1/3.2 on `crocus/gen7.5+`).

Gen7.5 is Broadwell. Haswell/Broadwell get 4.6; Bay Trail does not.

This matters because it means the *headroom* available is smaller than assumed,
and because anything requiring GL 4.3+ (compute shaders, some modern effects)
simply is not available.

### 2. `vblank_mode` and `mesa_glthread` are not in current Mesa envvar docs

`vblank_mode` does not appear in `docs/envvars.html`, and is structurally
irrelevant on Wayland (the compositor owns presentation timing, not the client).

`mesa_glthread` likewise does not appear. Treat both as **myths for this setup** —
do not put them in a config expecting a win.

### 3. Buffer count is not a fill-rate variable

N buffers ≠ N draw passes. Compositing cost is one pass over the damaged area
per frame; buffer count affects latency and memory, not per-frame fill. Any
arithmetic that multiplies fill rate by buffer count is wrong.

## Fill-rate budget — and a correction to an earlier version of this file

**CORRECTION:** an earlier version of this document modelled fill as
`1–2 px/clk per EU × 4 EUs = 4–8 px/clk`. That is **wrong for Gen7**.

On Gen7, pixels/clock is set by the shared **Windower/Masker (ROP front end)**,
which is a fixed-function unit *outside* the EUs (`FFID_WM` per Intel PRM
IHD-OS-VLV-Vol3-04.14 p.6). The 4 EUs govern *shader* throughput, not raster
output. Convolving the two is a common error.

Correct model (from the Ivy Bridge-derived ROP design, realworldtech): the GPU
writes on the order of **4 pixels per clock**, for the whole GPU.

| Quantity | Value |
|---|---|
| ROP fill at burst (646 MHz × 4 px/clk) | ~2.6 Gpx/s |
| Required for 1366×768 @ 60 fps | 1,049,088 × 60 = **63 Mpx/s** |
| Headroom | **~40×** |

**Conclusion: raw fill rate is NOT the bottleneck** — and by a wider margin than
the original (incorrect) model suggested. Full-screen 60 fps compositing uses
single-digit percent of ROP throughput.

**So why does Gen7 feel slow?** See `bottleneck-verification.md` for the full
analysis. Ranked:

1. **Pass count / shader complexity** — a blurred full-screen FBO is multiple
   passes each re-touching the whole surface. This is the real GPU cost.
2. **VSync / page-flip timing** — missing a vblank halves your frame rate no
   matter how fast the draw was. Most likely the felt problem.
3. **CPU/driver overhead** in the Gallium path (crocus is older/less optimised
   than iris).
4. **Shader compilation stalls** on first use → fix with a persistent
   `MESA_SHADER_CACHE`.

**Memory bandwidth is also not a hard ceiling:** compositing one full-screen
surface plus a window at 60 fps is roughly 0.5–0.8 GB/s against 10.6 GB/s peak —
about 9%. It only becomes visible when pass count multiplies it.

## Driver facts

- Gen7 uses **crocus** (Gallium). Classic `i965` DRI was removed in Mesa 22.0
  (`docs/relnotes/22.0.0.rst`).
- `00-crocus-defaults.conf` exists in the driver dir → driconf per-app defaults
  are possible.
- GL 4.2 core / GLES 3.0 as above.

## Env vars that are worth testing (UNVERIFIED gains — measure, do not assume)

| Var | Claim | Status |
|---|---|---|
| `MESA_SHADER_CACHE_MAX_SIZE` | raise shader cache to avoid recompiles | plausible; shader compile stalls are a real cause of first-run jank |
| `MESA_SHADER_CACHE_DISABLE` | — | do NOT set; opposite of what we want |
| `MESA_GL_VERSION_OVERRIDE` | force reported version | only useful to *lower* it; not a speed win |
| `GALLIUM_HUD` | on-screen perf counters | diagnostic only |
| `INTEL_DEBUG` | driver debug flags | diagnostic only |
| `COGL_DRIVER` / `CLUTTER_DRIVER` | force GL vs GLES in the compositor | **worth testing** — corresponds to mutter's `-Dopengl=false` at runtime |

## Practical plan for this device

1. **Measure before assuming.** Install `sysprof` and capture a real frame trace.
   The fill-rate math above says the GPU is mostly idle; find out what is
   actually blocking.
2. **Test GLES vs GL.** `COGL_DRIVER=gles2` at runtime (and `-Dopengl=false` at
   build) — cheap experiment.
3. **Shader cache.** Make sure `MESA_SHADER_CACHE` is on disk and persistent, so
   first-run shader compiles do not repeat.
4. **Investigate vblank/page-flip.** If frames are being missed at the flip
   rather than being slow to draw, no amount of shader tuning helps.
5. **Do not expect GL 4.6 features.** Design effects within GL 4.2 / GLES 3.0.

## Unverified / to settle on hardware

- Whether FBC actually helps or hurts (see kernel doc) — needs measurement.
- Real-world bandwidth ceiling on this board with compositor load.
- Whether crocus's GLES path is measurably faster than its GL path here.

## Sources
- `https://docs.mesa3d.org/envvars.html` (extracted and grepped)
- `https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/src/gallium/drivers/crocus/crocus_screen.c`
- `https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/docs/features.txt`
- `https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/docs/relnotes/22.0.0.rst`
- `https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/src/gallium/drivers/crocus/00-crocus-defaults.conf`
