# Rebuilding mutter / gnome-shell for Debian trixie

Verified against `sources.debian.org` API and the real `debian/` packaging.

## Versions (confirmed via sources.debian.org)

| Package | trixie version |
|---|---|
| `mutter` | **48.7-0+deb13u1** |
| `gnome-shell` | **48.7-0+deb13u2** |

Note gnome-shell is `u2`, not plain `48.7` — getting this wrong means your patch
series applies to a different tree than you think.

Toolchain: debhelper **13.24.2**, dpkg **1.22.22**, meson **1.7.0-1**.

## How compiler flags actually reach the compile (the important part)

mutter's `debian/rules`:

```make
include /usr/share/dpkg/default.mk
export DEB_BUILD_MAINT_OPTIONS = hardening=+all
export DEB_LDFLAGS_MAINT_APPEND = -Wl,-O1
DPKG_GENSYMBOLS_CHECK_LEVEL = 4
%: dh $@
```

**There is no explicit `-O2` anywhere.** Flags come from `dpkg-buildflags`.

The chain, from debhelper source:

1. `Dh_Lib.pm::set_buildflags()` instantiates `Dpkg::BuildFlags`, calls
   `load_config()`, then for every flag matching `/^[A-Z]/` does
   `$ENV{$flag} = $buildflags->get($flag)` **only if `! exists $ENV{$flag}`**.
   → **A pre-set `CFLAGS` in the environment is NOT clobbered.**
2. `Buildsystem/meson.pm::configure()` passes `--buildtype=plain`.
   → **meson adds no optimisation flags of its own**; everything comes from `$CFLAGS`.

**Therefore the correct override is the environment, not editing `debian/rules`:**

```bash
export DEB_CFLAGS_SET="-O3 -march=silvermont -pipe -fno-plt"
```

`DEB_CFLAGS_SET` / `DEB_CFLAGS_APPEND` sit above config files in
`dpkg-buildflags(1)`'s precedence order (system `/etc/dpkg/buildflags.conf` →
`$XDG_CONFIG_HOME/dpkg/buildflags.conf` → user env → `debian/rules` env).

This is much better than patching `debian/rules`, because the patch does not
need rebasing every release.

### Verify `-march=silvermont` is valid

```bash
gcc -march=silvermont -E - </dev/null && echo OK
```
Silvermont is supported by GCC 12+ (Debian 12 has GCC 12.2, bookworm).
Confirm on the actual build host before committing.

### Verify the flags actually took effect

```bash
readelf -p .comment build/.../libmutter-16.so | head     # compiler identity
objdump -d build/.../libmutter-16.so | grep -c avx       # should be 0 (Silvermont has no AVX)
objdump -d build/.../libmutter-16.so | grep -c popcnt    # should be > 0
dpkg-buildflags --get CFLAGS                             # what dpkg thinks
```

`grep -c avx` returning 0 is a strong positive signal: Silvermont has no AVX, so
a correctly-targeted build must not emit AVX instructions. If you see AVX, the
flags did not apply.

## ABI coupling — does gnome-shell need rebuilding too?

**Yes, treat them as a pair.** Reasons:

- `gnome-shell` links `libmutter-16-0 (>= 48.0)` and depends on
  `gir1.2-mutter-16 (>= 48.0)`.
- mutter's debian/rules sets `DH_GIREPOSITORY` paths and runs `dh_makeshlibs -V`
  plus `dh_shlibdeps -Llibmutter-16-0`. Rebuilding mutter regenerates
  `Meta-16.typelib` / `Clutter-16.typelib` / `Cogl-16.typelib`.
- Compiler flags alone do not change the ABI, so a *flags-only* rebuild of mutter
  does not strictly require a gnome-shell rebuild. But if you apply **patches**
  that touch public headers, you must rebuild both, and you should rebuild both
  anyway to keep the pair consistent.

**Practical rule: rebuild mutter and gnome-shell together, ship them as a pair.**

## Getting a trixie build environment on an Ubuntu runner

`sbuild` with a trixie chroot is the clean route (UNVERIFIED in this environment —
no sbuild/pbuilder/Docker here):

```bash
sudo apt-get install -y sbuild debootstrap
sudo sbuild-createchroot --include=eatmydata,ccache trixie \
     /srv/chroot/trixie-sbuild http://deb.debian.org/debian
# build
sbuild -d trixie ../mutter_48.7-0+deb13u1.dsc
```

Alternative that avoids chroot management: run the whole build inside a
`debian:trixie` container. On GitHub Actions this is a `container:` job, which
is simpler and reproducible.

## Source acquisition

```bash
# needs deb-src lines in sources.list
apt-get source mutter gnome-shell
# or directly:
dget http://deb.debian.org/debian/pool/main/m/mutter/mutter_48.7-0+deb13u1.dsc
```

## Applying patches

Use `debian/patches/series` + `quilt` — standard Debian mechanism, applied
automatically by `dh_quilt_patch`/`dpkg-source`.

```bash
cd mutter-48.7
quilt new 0001-reduce-fbo-realloc.patch
quilt add src/...
# edit
quilt refresh
```

This keeps the change as a reviewable, rebasable patch rather than a fork.

## Injecting the rebuilt debs into the image

```bash
# local apt repo
mkdir -p repo/pool repo/dists/local/main/binary-amd64
cp /build/*.deb repo/pool/
(cd repo && apt-ftparchive packages pool > dists/local/main/binary-amd64/Packages)
(cd repo && apt-ftparchive release dists/local > dists/local/Release)
```

Then in the mmdebstrap build, add the repo and pin it above trixie:

```
deb [trusted=yes] file:///repo ./
```

with an apt preferences file giving it priority 1001 so the local mutter wins
over trixie's. (Same technique the existing CasperOS image already uses to pin
trixie-backports — see `build/configs/etc/apt/preferences.d/99-casper-backports`.)

## Build dependencies (mutter 48, trixie)

Heavy ones to expect: `gobject-introspection`, `gtk-doc-tools`, `sysprof` (for
the profiler build), `xvfb` + `xwayland` (for the test suite), `libgl-dev`,
`libgles-dev`, `libegl-dev`, `libwayland-dev`, `libgtk-4-dev`, `libpipewire-0.3-dev`,
`libgbm-dev`, `libdrm-dev`, `libinput-dev`, `libudev-dev`, `libwacom-dev`,
`libcolord-dev`, `libgnome-desktop-dev`, `libxkbcommon-dev`, `libcanberra-dev`,
`libstartup-notification0-dev`.

If you set `-Dtests=false -Ddocs=false -Dprofiler=false`, many of these drop out.

## Build time

**ESTIMATE (not measured here):** mutter on 4 cores, `-j4`, with ccache cold:
roughly 10–20 minutes. gnome-shell: roughly 5–10 minutes. Both fit inside a
GitHub Actions job with room to spare. With ccache warm, minutes.

## What this all means

The flag-only rebuild is **cheap and low-risk** (hours of work, no rebasing), but
per `mutter-build-options.md` the flags alone will not transform performance.
Patches are where behaviour changes live, and quilt makes them maintainable.

## Sources
- `https://sources.debian.org/api/src/mutter/` (version + dsc)
- `https://sources.debian.org/api/src/gnome-shell/`
- `mutter_48.7-0+deb13u1` `debian/rules`, downloaded and read
- `dpkg-buildflags(1)` dpkg 1.22.22, manpages.debian.org
- debhelper `Dh_Lib.pm` `set_buildflags()`, `Buildsystem/meson.pm` `configure()`
