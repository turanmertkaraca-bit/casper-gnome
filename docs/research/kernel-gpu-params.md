# i915 kernel parameters for smooth compositing — verified against Linux 6.12

Verified against a real Linux **v6.12** tree (blobless clone of `torvalds/linux`,
tag `v6.12`, commit `adc2186`), plus per-tag fetches from git.kernel.org.

## Critical documentation correction

`Documentation/admin-guide/kernel-parameters.txt` in 6.12 contains exactly **one**
`i915.*` entry: `i915.invert_brightness=` (line 1977). It documents **no** i915
display parameters.

`Documentation/gpu/i915.rst` documents **no** module parameters either — it only
`kernel-doc`-includes `intel_fbc.c` and `intel_psr.c`.

**The authoritative source in 6.12 is `MODULE_PARM_DESC` in two headers:**
- `drivers/gpu/drm/i915/i915_params.h` (core)
- `drivers/gpu/drm/i915/display/intel_display_params.h` (display)

Display params **moved** to the second file in v6.8 (commit "Move … under
display", Jani Nikula, 2023-10-26). A grep of `i915_params.c` alone will falsely
conclude that `enable_fbc` / `enable_psr` no longer exist.

**Warning for anyone citing "kernel-parameters.txt says…" about `enable_fbc`:
that line does not exist.** This is exactly the plausible-sounding-citation
failure mode this project has been burned by before.

## Parameters that EXIST in 6.12 (verified in headers)

### Core (`i915_params.h`)
`modeset`, `enable_guc`, `guc_log_level`, `guc_firmware_path`, `huc_firmware_path`,
`gsc_firmware_path`, `memtest`, `mmio_debug`, `reset`, `force_probe`,
`request_timeout_ms`, `lmem_size`, `lmem_bar_size`, `enable_hangcheck`,
`error_capture`, `enable_gvt`, `enable_debug_only_api`.

### Display (`intel_display_params.h`)
`enable_dc=-1`, `enable_dpt=true`, `enable_dsb`, `enable_sagv`, `enable_ips=true`,
`enable_fbc=-1 (0600)`, `enable_psr=-1 (0600)`, `psr_safest_params`,
`enable_psr2_sel_fetch`, `enable_dmc_wl`, …

## Parameters that DO NOT exist — dead in 6.12

| Parameter | Reality | Evidence |
|---|---|---|
| `i915.enable_rc6` | present v4.4/v4.15, **absent from v4.16** | commit `drm/i915: Remove unsafe i915.enable_rc6`, Chris Wilson, 2017-12-01 |
| `i915.fastboot` | present v4.4→v6.6 (`i915_params.c:140` in v6.6), **absent from v6.7** | commit `drm/i915: Remove the module parameter 'fastboot'`, Arun R Murthy, 2023-10-12 |
| `i915.fifo_underrun_reporting` | **no such module parameter exists** | grep of both param headers returns nothing |

`i915.enable_rc6` being dead confirms what `casper-android/docs/optimizations.md`
§6 already said. `i915.fifo_underrun_reporting` is a new catch — it sounds
plausible and does not exist.

## Parameters that exist but are pointless here

| Parameter | Why skip |
|---|---|
| `i915.enable_guc` | exists; **no GuC on Gen7** |
| `i915.enable_dpt` | exists; **gen12+ display feature** |
| `i915.force_probe` | exists; Gen7 is default-probed, forcing it is a no-op at best |

## Frame Buffer Compression (FBC)

`intel_fbc.c` DOC, verbatim:

> "FBC tries to save memory bandwidth (and so power consumption) … benefits are
> mostly visible with solid backgrounds and variation-less patterns"

**This is directly relevant to our bandwidth-bound analysis** (see
`gen7-crocus.md`: fill rate is not the limit, bandwidth is). FBC compresses
solid-colour regions of the framebuffer, which is exactly what a desktop UI is
mostly made of.

**Tension with the existing config:** the current CasperOS cmdline sets
`i915.enable_fbc=0` for flicker reasons. That may be costing real bandwidth on
the very workload we care about.

**Recommendation: measure both.** This is a genuine trade-off, not a settled
question:
- If FBC on → no flicker on this panel, and measurable smoothness gain: keep it on.
- If FBC on → flicker: the flicker is a display correctness bug and wins; keep it off.

Pending: verify FBC support/erratum status for BYT specifically. `enable_fbc=-1`
means "auto", and auto may already disable it on this chip for known reasons.

## Panel Self Refresh (PSR)

`intel_psr.c` DOC via i915.rst. PSR lets the panel keep a static frame while the
GPU idles — good for power, and on this device it is already disabled
(`i915.enable_psr=0`) because it caused stalls.

For **smoothness** (our goal), PSR is not a win: it saves power when nothing
moves, and our problem is when things move. Leaving it off is correct.

## Display C-states (DC)

`i915.enable_dc=0` already set. DC gates display power in idle states; on Gen7 it
has a history of causing flicker. Not a smoothness lever when animating.

**Honest summary: for the three flags currently in the cmdline, `psr=0` and `dc=0`
are defensible (avoid known display bugs) but they are *inert with respect to
animation smoothness*, not wins. `fbc=0` is the one that may actually be costing
bandwidth and deserves a real measurement.**

## `intel_iommu` / `iommu`

- `intel_iommu=igfx_off` — documented to bypass DMAR for the graphics device only,
  keeping IOMMU on for everything else. **Preferred over `intel_iommu=off`**, which
  disables it globally.
- `iommu=pt` — passthrough mode, less mapping overhead.

Relevant if IOMMU translation is adding overhead in the GEM buffer path. Worth
testing.

## CPU frequency driver on Bay Trail

Bay Trail is Silvermont — **not** a Core CPU. Whether `intel_pstate` loads at all
needs verification; `acpi-cpufreq` + `schedutil` is the expected combination.
Frame timing is sensitive to frequency ramp latency: a governor that takes a few
hundred ms to ramp will make the first frames of an animation stutter.

Pending verification: check `drivers/cpufreq/intel_pstate.c` for the CPU model
list.

## Recommended smoothness-first cmdline

Baseline from the existing CasperOS config, with reasoning per item:

```
intel_idle.max_cstate=1          # touchscreen freeze (LPSS I2C clock gating) — mandatory
i915.enable_psr=0                # avoid PSR stalls; not a smoothness win either way
i915.enable_dc=0                 # avoid Gen7 DC flicker
i915.enable_fbc=1                # TEST THIS — may recover real bandwidth
intel_iommu=igfx_off              # test: reduce GEM path overhead
```

Explicitly NOT included, with reasons: `i915.enable_rc6` (removed 4.16),
`i915.fastboot` (removed 6.7), `i915.fifo_underrun_reporting` (does not exist),
`i915.enable_guc` / `i915.enable_dpt` / `i915.force_probe` (exist, irrelevant on Gen7).

## To settle on hardware
- Does FBC cause flicker on this specific panel? (`enable_fbc=1` vs `0`)
- Does `intel_iommu=igfx_off` change frame times?
- Which cpufreq driver actually loads on Z3735F?

## Sources
- `torvalds/linux` tag `v6.12` (commit `adc2186`), `drivers/gpu/drm/i915/i915_params.h`
  and `drivers/gpu/drm/i915/display/intel_display_params.h`
- `Documentation/admin-guide/kernel-parameters.txt` v6.12 (single i915 entry verified)
- git.kernel.org commit references cited above
