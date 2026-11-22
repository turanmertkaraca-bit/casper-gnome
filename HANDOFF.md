# HANDOFF — read this before doing anything

You are continuing a project that is **close to a working desktop image** but has
not reached one yet. This document tells you where everything is, what is already
proven, what is broken right now, and how to work efficiently.

**Use maximum effort. Use as many subagents in parallel as you can usefully
direct** — but see §7 first: subagents burned enormous budgets and were often
wrong. They are powerful for *reading source* and *checking facts*, weak at
diagnosing this build.

---

## 1. The project in one paragraph

A GNOME 48 desktop for the Casper Nirvana N220/N240: Intel Atom Z3735F (Bay
Trail, Gen7 graphics, 4 EUs), **2 GB RAM**, **32-bit UEFI on a 64-bit CPU**,
1366×768 touch panel, 32–64 GB eMMC, RTL8723BS Wi-Fi, RT5640 audio. The user
wants **real GNOME with its animations kept**, made fast by removing waste — not
a lightweight GNOME look-alike. Base is Debian trixie, kernel 6.12 built by us.

---

## 2. Where everything is

```
README.md                      project overview + status table (keep updated)
HANDOFF.md                     this file
docs/VERIFIED.md               every proven claim with its evidence, + all bugs found
docs/sensors-mma8653.md        accelerometer/rotation plan (blocked on hardware dump)

docs/research/                 all research, each file self-contained:
  verification-audit.md          ★ which assumptions were REFUTED (read 2nd)
  bottleneck-verification.md     what actually limits Gen7 (fill rate is NOT it)
  direct-scanout.md              mutter's scanout path, verified in source
  kernel-gpu-params.md           i915 params vs real 6.12 tree (3 don't exist)
  gnome-memory.md                measured package sizes
  debian-rebuild.md              how to rebuild mutter/gnome-shell
  mutter-build-options.md        every meson option, and that none is a speed knob
  shell-frame-hotpaths.md        where shell frames cost
  gen7-crocus.md                 Mesa/crocus reality (GL 4.2, not 4.6)
  compositor-alternatives.md     honest comparison of other shells

kernel/casper-gnome.fragment   Linux 6.12 config (76 symbols, all verified)
build/build-image.sh           the image builder  ← most work happens here
build/packages.list            minimal GNOME package set (all names verified)
build/merge-config.sh          kernel fragment merger (tested, no dup symbols)
patch/                         0001, 0002, series — verified gnome-shell patches
test/boot-test.sh              QEMU IA32-UEFI boot verification  ← read serial
test/check-heredocs.sh         guards against unterminated heredocs
test/wait_ci.sh                CI poller (avoids loop-guard tripping)
test/diag-sensors.sh           accelerometer diagnostics (run on the tablet)
.github/workflows/build.yml    jobs: kernel, rebuild, image
```

Related repos: `casper-nirvana-debian` (the earlier Debian/Hyprland attempt,
superseded) and `casper-android` (the abandoned Android direction — its
`docs/optimizations.md` still holds useful kernel/audio/zram knowledge).

---

## 3. Current state — precise

**Green and stable:**
- `kernel` job — 6.12 builds; `EFI_MIXED`, RT5640, RTL8723BS, zram,
  `IIO`+`MMA8452` all asserted; `r8723bs.ko` and `mma8452.ko` produced.
- `rebuild` job — both patches applied to real Debian source; mutter+gnome-shell
  built `-O3 -march=silvermont`; **0 AVX instructions** proves the flag applied.

**Builds and boots, not yet graphical:**
- `image` job builds a 3.8 GB GPT disk with IA32 GRUB at both paths,
  `BOOTIA32.EFI` present, and boots it under IA32 OVMF to systemd userspace
  (`sysinit.target` reached, logind starts, `New seat seat0`).

**The live blocker:** `multi-user.target` and `graphical.target` are never
reached. `greetd` shows `enabled` but `inactive (dead)` with a pending Job
number. Two units were seen stuck at `Starting …`:
`plymouth-quit-wait.service` and `casper-growroot.service`.

Latest fix pushed (commit "Unblock multi-user.target…"): growroot moved before
`local-fs.target` (it was calling `resize2fs` on a **mounted rw** root, which
stalls), and `plymouth-quit-wait` bounded at 10s and dropped from
`multi-user.target`'s `After=`. **This fix is untested at time of writing.**

---

## 4. How to iterate (this is the important part)

The loop that works:

```bash
cd casper-gnome
export GH_TOKEN_RT='<token from the user>'
./test/wait_ci.sh turanmertkaraca-bit/casper-gnome 540     # one call, waits internally
```

Then **read the real serial log**, do not trust the 30-line excerpt in the job
log. Download via the artifacts API and extract only `serial.log`:

```bash
A=$(curl -s -H "Authorization: token $GH_TOKEN_RT" \
    "https://api.github.com/repos/turanmertkaraca-bit/casper-gnome/actions/runs?per_page=1" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
ART=$(curl -s -H "Authorization: token $GH_TOKEN_RT" \
    "https://api.github.com/repos/turanmertkaraca-bit/casper-gnome/actions/runs/$A/artifacts" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
[print(a['id']) for a in d['artifacts'] if 'image' in a['name']]")
# resume until the zip validates — it is ~1.1 GB and truncates constantly
for i in $(seq 1 25); do
  curl -sL -C - -H "Authorization: token $GH_TOKEN_RT" \
    "https://api.github.com/repos/turanmertkaraca-bit/casper-gnome/actions/artifacts/$ART/zip" -o a.zip
  python3 -c "import zipfile,sys; zipfile.ZipFile('a.zip'); sys.exit(0)" 2>/dev/null && break
done
# extract ONLY the serial log (unzipping the whole thing is very slow here)
python3 -c "
import zipfile
z=zipfile.ZipFile('a.zip')
for n in z.namelist():
    if n.endswith('serial.log'): open('/tmp/s.log','wb').write(z.read(n))
"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r/\n/g' /tmp/s.log | tail -40
```

**Hard-won rules:**
- Never call the same command repeatedly in a loop — the harness trips a loop
  guard. Use `test/wait_ci.sh`, which waits internally.
- `bash -n` **and** `./test/check-heredocs.sh` before every push; an
  unterminated heredoc silently swallowed an entire build stage and cost four
  CI runs.
- A whole CI round is ~10–20 minutes. Batch related fixes into one push.
- The build script writes a boot-time diagnostic to `/dev/console`; look for
  `=== CASPER DIAG START ===` in the serial log. That is how the
  `status=238/STATE_DIRECTORY` logind bug was found after many wrong guesses.

---

## 5. The single most useful next step

1. Run the loop above on the current HEAD and read `serial.log`.
2. Find whether `multi-user.target` is now reached and whether `greetd` starts.
3. If greetd still does not start, the diagnostic unit already prints
   `systemctl status greetd`, `is-enabled`, and graphical.target dependencies —
   read that block first.
4. If greetd starts but GNOME does not, look for `gnome-session`, `mutter`,
   `gnome-shell` in serial. Likely failures on this hardware:
   - mutter cannot get a GL context on QEMU's software renderer (expected; not a
     real failure, but it blocks CI verification of the *session*)
   - `XDG_RUNTIME_DIR` unset → `casper-session` now fails loudly by design
   - missing `dbus-user-session`

**Consider whether QEMU can verify the session at all.** If mutter needs real
GL, CI can only ever prove "boots to systemd", and the graphical milestone must
be verified on the tablet. Deciding this early saves days. A legitimate option
is to give QEMU `-vga virtio -display none` plus `virtgl`, or accept a
`MUTTER_DEBUG` software-rendering path just to prove the session launches.

---

## 6. What the user actually wants (do not drift)

- **Real GNOME, animations intact.** They explicitly rejected Phosh, rejected
  Android, rejected a GNOME look-alike.
- They want the tablet to feel fast by removing wasted work, not by removing
  motion.
- They are planning a **debug option in the OS** and want to connect the agent
  to the real hardware over SSH later. `test/diag-sensors.sh` is the first piece
  of that.
- They care about: touchscreen working, audio not cutting the first second,
  Wi-Fi stable, rotation, and general responsiveness.

---

## 7. Lessons about subagents (learned the hard way)

Used well, they are excellent. Used as oracles, they wasted enormous budget.

**They are good at:**
- reading upstream source and quoting it (mutter, gnome-shell, systemd, greetd)
- checking Debian package metadata and versions
- verifying a config against real Kconfig/packaging

**They are bad at:**
- diagnosing this specific build. Multiple confidently-wrong root causes were
  offered (usrmerge symlinks, missing sysusers users) — all refuted by evidence
- remembering to write their deliverable file. Most ran out of budget *before*
  writing the file they were asked for, so **capture their findings immediately**
- not dumping enormous output into context — one agent printed 500 KB

**Practical rules:**
- One narrow question per agent. Ask for under ~150 lines back.
- Ask them to return findings *in the reply*, not only to a file.
- Always verify their central claim yourself before acting on it.
- Prefer instrumenting the build over asking an agent to theorise. The
  `/dev/console` diagnostic found in one run what three agent theories missed.

---

## 8. Credentials

The GitHub token is **not** in this repo and must never be committed. The user
supplies it per session as `GH_TOKEN_RT`. Use it only via environment variables
and `GIT_ASKPASS`, never in a command line, never in a file that is added to git.

Note: `git push` over plain `https://` with only the token in `GIT_ASKPASS`
works; see earlier commits for the exact pattern. Scan history before pushing:
`git log --all -p | grep -c 'ghp_'` must be 0.

---

## 9. Honest assessment of remaining risk

| Risk | Likelihood | Note |
|---|---|---|
| The graphical session needs real GL that QEMU cannot provide | Medium-high | This may make CI verification of the desktop impossible; plan for on-tablet testing |
| GNOME 48 too slow on Gen7 even after tuning | Medium | The research says fill/bandwidth are not the limit, so this hinges on pass count and vblank behaviour — measurable only on the tablet |
| The two patches do nothing measurable | Medium | They are reasoned, not benchmarked. One `sysprof` trace settles it |
| Touchscreen/audio/Wi-Fi each need bespoke fixes | High | They are classic Bay Trail problems; `intel_idle.max_cstate=1` is already in the cmdline |
| 2 GB is simply too little for GNOME + a browser | Medium | 350 MB idle is the target; browsing will be the real test |

None of these are project-killers, but **do not promise a working desktop until
one has been seen.**
