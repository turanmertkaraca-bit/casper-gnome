# Bottleneck verification — what actually limits Gen7 compositing

Testing the claim: *"raw fill rate is not the bottleneck at 1366×768@60; the real
limits are memory bandwidth, blend/shader pass count, and vsync/page-flip timing."*

**Verdict: PARTIALLY SUPPORTED — and my own earlier mechanism was wrong.**

| Sub-claim | Verdict |
|---|---|
| Raw fill rate is not the bottleneck | **SUPPORTED**, more strongly than stated |
| Memory bandwidth is the bottleneck | **REFUTED as an independent ceiling** (~9% of peak) |
| Blend/shader pass count drives cost | **SUPPORTED** |
| vsync/page-flip timing is highest leverage | **UNVERIFIED**, but structurally the most likely |

## Published specs (VERIFIED — Intel ARK SKU 80274)

| Fact | Value | Source |
|---|---|---|
| CPU | 4C, 1.33–1.83 GHz, 2 MB L2, SDP 2.2 W | Intel ARK |
| GPU | "Intel HD Graphics for Intel Atom Z3700 Series" | ARK |
| GPU clocks | **311 MHz base / 646 MHz burst** | ARK |
| Memory | DDR3L-RS 1333, **1 channel**, **10.6 GB/s max**, 2 GB max | ARK |
| EU count | **not published by Intel** (verified absent from ARK) | ARK |
| Pixel/texture fill rate | **not published by Intel** | ARK |

EU count and shader count come from secondary sources:

| Fact | Value | Source |
|---|---|---|
| EUs | **4**, 32 shaders, Gen7 (Ivy Bridge-derived), 22 nm | notebookcheck, cpu-monkey |
| **4 EUs × 8 threads/EU** | table `#EUs 4 / #Threads/EU 8` | **Intel PRM IHD-OS-VLV-Vol3-04.14 p.5** |
| Windower/Masker (ROP front end) is a **shared unit outside the EUs** (`FFID_WM`) | | same PRM p.6 |
| Ivy Bridge ROP writes **four 32-bit pixels per clock** (whole GPU) | | realworldtech Ivy Bridge GPU review |

Cross-check on consistency: 4 EU × 8 lanes × 2 FLOP × 646 MHz ≈ 41 GFLOP/s;
CPU-Monkey lists 0.06 TFLOPS FP32 @ 0.90 GHz = 64 FLOP/clk — consistent with
4 EU × 8 lanes × 2. ✓

## Correction: the per-EU fill model in `gen7-crocus.md` is wrong

That file assumed **1–2 px/clk per EU × 4 EUs = 4–8 px/clk**. That is not Gen7's
architecture.

**Pixels/clock on Gen7 is set by the shared Windower/Masker and render cache, not
by the EU count.** The 4 EUs govern *shader* throughput. Convolving the two is a
common error and it changes the conclusion's strength, though not its direction.

The corrected position: a Gen7 GT1's ROP throughput is on the order of **4 pixels
per clock for the whole GPU** (Ivy Bridge-derived ROP), i.e. ~2.6 Gpx/s at burst.
Full-screen 1366×768 at 60 Hz needs 1,049,088 × 60 = **63 Mpx/s**. That is ~2.4%
of ROP throughput.

**So fill is roughly 40× oversized — even more headroom than the original claim
suggested.**

## Bandwidth: refuted as the ceiling

For compositing one full-screen opaque surface plus one overlapping window at
1366×768@60:

- One full-screen frame = 1,049,088 px × 4 B = **4.2 MB**
- A composite touches roughly 2–3× that (read source textures, write destination,
  plus scanout read) ≈ **8–13 MB/frame**
- At 60 fps ≈ **0.5–0.8 GB/s**

Against a 10.6 GB/s peak (realistically ~60–70% sustained on single-channel
DDR3L), that is **~9–12% of available bandwidth**.

**Conclusion: bandwidth is not a hard ceiling either.** It becomes visible when a
pass count multiplies it — which is a *consequence* of pass count, not an
independent limit.

## Ranked actual bottlenecks

1. **Pass count / shader complexity.** A blurred full-screen FBO is several
   passes with texture reads; each pass re-touches the whole surface. This is
   the real GPU cost driver and it is why `ShellBlurEffect` (3 FBOs, forces
   full-resolution in background mode) is the single most expensive shell effect.
2. **vsync and page-flip timing (most likely the felt problem).** If a frame
   misses the vblank, you drop to 30 fps regardless of how fast the draw was.
   This is where "animations feel janky on old Intel" usually lives.
3. **CPU/driver overhead in the Gallium path** (crocus is older and less
   optimised than iris).
4. **Shader compilation stalls** on first use — fixable with a persistent
   `MESA_SHADER_CACHE`.
5. Raw fill rate — **not** a factor.
6. Memory bandwidth — **not** a factor in isolation.

## What this means for the plan

The optimisations that matter are, in order:

- **Direct scanout for fullscreen content** (`direct-scanout.md`) — removes the
  composite pass entirely for video/fullscreen apps.
- **Fewer full-screen passes** — the `ShellBlurEffect` and lightbox shader findings
  in `shell-frame-hotpaths.md`.
- **Vblank behaviour** — needs measurement on hardware, not more theory.
- **Shader cache persistence** — cheap, avoids first-run hitches.

Do **not** spend time on fill-rate or bandwidth micro-optimisation. The arithmetic
says there is 40× headroom there.

## Open items
- Bay Trail FBC support status: needs `grep HAS_FBC` on
  `drivers/gpu/drm/i915/display/intel_display_device.c`.
- Real-world Bay Trail GNOME stutter attributions: not yet gathered.

## Sources
- Intel ARK SKU 80274 (read in full; absences verified)
- Intel PRM IHD-OS-VLV-Vol3-04.14 (Bay Trail GPU overview), pp. 5–6
- notebookcheck.net/Intel-HD-Graphics-Bay-Trail.103037.0.html
- cpu-monkey.com/en/igpu-intel_hd_graphics_bay_trail_gt1
- realworldtech.com/ivy-bridge-gpu/6/
