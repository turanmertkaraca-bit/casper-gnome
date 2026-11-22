HANDOFF — CasperOS GNOME
========================

You are continuing the CasperOS GNOME project: a GNOME 48 desktop for the
Casper Nirvana N220/N240 tablet, on Debian trixie with our own kernel 6.12.

USE MAXIMUM EFFORT. USE AS MANY SUBAGENTS IN PARALLEL AS YOU CAN USEFULLY
DIRECT — but read section 7 first, because subagents have burned enormous
budget and were often wrong.


0. REPO AND CREDENTIALS
-----------------------

  https://github.com/turanmertkaraca-bit/casper-gnome     68 files, all pushed

The GitHub token is NOT in the repo and must NEVER be committed. The user
supplies it per session as GH_TOKEN_RT. Use it only via environment
variables and GIT_ASKPASS; never in a command line, never in a tracked file.

Before pushing, verify history is clean:

  git log --all -p | grep -cE 'ghp_[A-Za-z0-9]{30,}'     # must be 0

Related repos (both superseded, both still useful):

  casper-nirvana-debian  earlier Debian/Hyprland attempt. Its build/configs
                         tree is where the audio and touch fixes came from;
                         those are now copied into configs/ here.
  casper-android         abandoned Android direction. Its
                         docs/optimizations.md still has good kernel, zram
                         and VA-API knowledge.


1. THE PROJECT
--------------

Hardware: Intel Atom Z3735F (Bay Trail, Gen7 graphics, 4 EUs), 2 GB RAM,
32-bit UEFI on a 64-bit CPU, 1366x768 touch panel, 32-64 GB eMMC,
RTL8723BS Wi-Fi, RT5640 audio.

The user wants REAL GNOME WITH ANIMATIONS KEPT, made fast by removing waste.
They explicitly rejected Phosh, rejected Android, and rejected a GNOME
look-alike.

CRITICAL CONTEXT FROM THE USER:
A vanilla Ubuntu 22.04 install on THIS EXACT TABLET ran GNOME, Chrome and
animations FINE. It had two bugs — touchscreen freeze, and audio cutting out
and taking 2-3 seconds to start — which were then fixed by scripts.

So this is NOT "can GNOME work on 2 GB". It already did. The job is
rebuilding a known-working thing with the known fixes. GNOME 48 is heavier
than GNOME 42, so measure rather than assume.

Secondary context: their main workload is mpv + terminal tools for
YouTube/anime (hardware H.264 decode via VA-API), not heavy browsing.


2. WHERE EVERYTHING IS
----------------------

  README.md                    status table (keep updated)
  HANDOFF.md                   this file
  docs/VERIFIED.md             every proven claim + evidence + 20-entry bug table
  docs/sensors-mma8653.md      accelerometer/rotation plan (blocked on hardware)

  docs/research/   (each file self-contained)
    verification-audit.md        * which assumptions were REFUTED (read 2nd)
    bottleneck-verification.md   what actually limits Gen7; fill rate is NOT it
    direct-scanout.md            mutter's scanout path, verified in source
    kernel-gpu-params.md         i915 params vs real 6.12 (3 do not exist)
    gnome-memory.md              measured package sizes
    debian-rebuild.md            how to rebuild mutter/gnome-shell
    mutter-build-options.md      every meson option; none is a speed knob
    shell-frame-hotpaths.md      where shell frames cost
    gen7-crocus.md               Mesa/crocus reality (GL 4.2, not 4.6)
    compositor-alternatives.md   honest comparison of other shells

  configs/                     * THE AUDIO AND TOUCH WORK
                               Copied from the earlier project. Contains
                               PipeWire buffers, the ALSA UCM symlink
                               (bytcrrt5640 -> bytcr-rt5640), the libinput
                               quirk, I2C/C-state udev rules, the touchscreen
                               watchdog, VA-API env, Firefox policies, zram.
                               build-image.sh copies the whole tree in.
                               DO NOT retype these by hand.

  kernel/casper-gnome.fragment Linux 6.12 config (76 symbols, all verified)
  build/build-image.sh         the image builder — most work happens here
  build/packages.list          minimal GNOME set (every name verified)
  build/merge-config.sh        kernel fragment merger (tested, no dupes)
  patch/0001, 0002, series     verified gnome-shell patches
  test/boot-test.sh            QEMU IA32-UEFI verification — read serial
  test/check-heredocs.sh       guards against unterminated heredocs
  test/wait_ci.sh              CI poller (avoids tripping a loop guard)
  test/diag-sensors.sh         accelerometer diagnostics (run on tablet)
  .github/workflows/build.yml  jobs: kernel, rebuild, image


3. CURRENT STATE — PRECISE
--------------------------

GREEN AND STABLE:

  kernel job    6.12 builds. Asserts EFI_MIXED, RT5640 audio, RTL8723BS,
                zram, IIO+MMA8452. Produces r8723bs.ko and mma8452.ko.
                bzImage reports BOTH 32-bit and 64-bit EFI handoff entries.

  rebuild job   Both patches applied to real Debian source. mutter and
                gnome-shell built with -O3 -march=silvermont. Verified by
                objdump: 0 AVX instructions, which proves the flag applied.

BUILDS AND BOOTS, NOT YET GRAPHICAL:

  image job     Builds a 3.8 GB GPT disk: FAT32 ESP + ext4 root, IA32 GRUB
                at both the removable and vendor paths, BOOTIA32.EFI present
                (106496 bytes). Boots under IA32 OVMF to systemd userspace:
                sysinit.target reached, logind starts, "New seat seat0".

LIVE BLOCKER:

  multi-user.target and graphical.target are NEVER reached. greetd shows
  "enabled" but "inactive (dead)" with a pending Job number. Two units were
  seen stuck at "Starting...": plymouth-quit-wait.service and
  casper-growroot.service.

LATEST FIX — PUSHED BUT UNTESTED AT HANDOFF:

  1. casper-growroot moved to DefaultDependencies=no, before local-fs.target.
     It was calling resize2fs on a MOUNTED rw root, which stalls.
  2. plymouth-quit-wait bounded at 10s and dropped from multi-user.target's
     After= list.
  3. The entire configs/ tree was just added and wired into the build.
  4. casper-cpu-governor, casper-nvram and casper-touchscreen-watchdog are
     now enabled via direct symlinks with assertions.

START BY TESTING THAT. Run the loop in section 4 and read the serial log.


4. HOW TO ITERATE
-----------------

  cd casper-gnome
  export GH_TOKEN_RT='<token>'
  ./test/wait_ci.sh turanmertkaraca-bit/casper-gnome 540

Then read the REAL serial log. Do not trust the 30-line excerpt in the job
log — it truncates:

  A=$(curl -s -H "Authorization: token $GH_TOKEN_RT" \
    "https://api.github.com/repos/turanmertkaraca-bit/casper-gnome/actions/runs?per_page=1" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['workflow_runs'][0]['id'])")

  ART=$(curl -s -H "Authorization: token $GH_TOKEN_RT" \
    "https://api.github.com/repos/turanmertkaraca-bit/casper-gnome/actions/runs/$A/artifacts" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
[print(a['id']) for a in d['artifacts'] if 'image' in a['name']]")

  # Resume until the zip validates. It is ~1.1 GB and truncates constantly.
  for i in $(seq 1 25); do
    curl -sL -C - -H "Authorization: token $GH_TOKEN_RT" \
      "https://api.github.com/repos/turanmertkaraca-bit/casper-gnome/actions/artifacts/$ART/zip" -o a.zip
    python3 -c "import zipfile,sys; zipfile.ZipFile('a.zip'); sys.exit(0)" 2>/dev/null && break
  done

  # Extract ONLY the serial log. Unzipping the whole thing is unusably slow.
  python3 -c "
import zipfile
z=zipfile.ZipFile('a.zip')
for n in z.namelist():
    if n.endswith('serial.log'): open('/tmp/s.log','wb').write(z.read(n))
"

  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r/\n/g' /tmp/s.log | tail -40

RULES LEARNED THE HARD WAY:

  - NEVER call the same command repeatedly in a loop. A loop guard trips and
    the session dies. Use test/wait_ci.sh, which waits internally.
  - Run BOTH of these before every push:
        bash -n build/build-image.sh
        ./test/check-heredocs.sh build/build-image.sh
    An unterminated heredoc once silently swallowed an entire build stage
    and cost four CI runs and three wrong diagnoses.
  - One CI round is 10-20 minutes. Batch related fixes into one push.
  - The build writes a boot-time diagnostic to /dev/console. Look for
    "=== CASPER DIAG START ===" in the serial log. That is how the
    status=238/STATE_DIRECTORY logind bug was finally found, after several
    wrong guesses.


5. NEXT STEPS
-------------

  1. Test current HEAD. Determine whether multi-user.target is reached and
     whether greetd starts. The diagnostic unit already prints
     "systemctl status greetd", "is-enabled", and graphical.target
     dependencies — read that block first.

  2. If greetd starts but GNOME does not, grep serial for gnome-session,
     mutter, gnome-shell. Likely failures:
       - mutter cannot get a GL context on QEMU's software renderer
       - XDG_RUNTIME_DIR unset (casper-session now fails loudly by design)
       - missing dbus-user-session

  3. DECIDE EARLY whether QEMU can verify the session at all. If mutter
     needs real GL, CI can only ever prove "boots to systemd", and the
     graphical milestone must be verified on the tablet. Accepting that
     early saves days.

  4. Then flash it on the tablet and LIVE WITH IT for a day. That produces
     more information than any amount of CI.


6. WHAT THE USER WANTS — DO NOT DRIFT
-------------------------------------

  - Real GNOME, animations intact. Not Phosh, not Android, not a look-alike.
  - Fast by removing waste, not by removing motion.
  - They plan a debug option in the OS and want to connect the agent to real
    hardware over SSH later. test/diag-sensors.sh is the first piece of that.
  - Priorities: touchscreen must not freeze, audio must not cut the first
    second, Wi-Fi stable, rotation working, general responsiveness.
  - Main workload: mpv + terminal tools for video, not heavy browsing.


7. LESSONS ABOUT SUBAGENTS
--------------------------

GOOD AT:
  - reading upstream source and quoting it (mutter, gnome-shell, systemd,
    greetd, Mesa)
  - checking Debian package metadata, versions, dependency fields
  - verifying a config against real Kconfig or packaging

BAD AT:
  - diagnosing this specific build. Several confidently-wrong root causes
    were offered (usrmerge symlinks, missing sysusers users); all were
    refuted by evidence.
  - finishing. Most ran out of budget BEFORE writing the file they were
    asked for. Capture findings immediately.
  - context hygiene. One agent dumped 500 KB of output.

RULES:
  - One narrow question per agent.
  - Ask for under ~150 lines back.
  - Ask them to return findings IN THE REPLY, not only in a file.
  - Verify their central claim yourself before acting on it.
  - PREFER INSTRUMENTING THE BUILD over asking an agent to theorise. The
    /dev/console diagnostic found in one run what three agent theories
    missed.


8. HONEST RISK ASSESSMENT
-------------------------

  Graphical session needs real GL that QEMU cannot provide
      Medium-high. May make CI verification of the desktop impossible.
      Plan for on-tablet testing.

  GNOME 48 too slow on Gen7 even after tuning
      LOW. The user ran vanilla Ubuntu 22 GNOME fine on this tablet.

  The two patches do nothing measurable
      Medium. They are reasoned from source, not benchmarked. One sysprof
      trace settles it.

  Touchscreen / audio / Wi-Fi each need bespoke fixes
      High. Classic Bay Trail problems. The configs are in configs/, but
      they have never been verified on this image.

  2 GB too little for GNOME plus a browser
      Medium. ~350 MB idle is the target. Browsing is the real test; mpv
      playback is not.

DO NOT PROMISE A WORKING DESKTOP UNTIL ONE HAS BEEN SEEN.

No desktop has been seen yet. The image boots to systemd and stops there.
