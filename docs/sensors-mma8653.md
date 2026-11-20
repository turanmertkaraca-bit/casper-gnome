# MMA8653 accelerometer — how to make rotation work

NXP/Freescale MMA8653, 3-axis, I2C, on the Casper Nirvana N220.
Goal: GNOME rotates the screen via `iio-sensor-proxy`.

Everything here was verified against the Linux v6.12 source tree.

## Verified facts

| Fact | Value | Source |
|---|---|---|
| Chip | MMA8653FC, 10-bit | `drivers/iio/accel/mma8452.c` header comment |
| I2C address | **0x1d** | same header comment |
| `WHO_AM_I` | register 0x0D, returns **0x5A** for MMA8653 | `MMA8653_DEVICE_ID 0x5a`, `MMA8452_WHO_AM_I 0x0d` |
| Driver | `mma8452.ko`, config symbol **`CONFIG_MMA8452`** | `drivers/iio/accel/Kconfig:566` |
| Match tables | **`of_device_id` YES, `i2c_device_id` YES, `acpi_device_id` NO** | source |

`of_device_id mma8452_dt_ids[]` includes `fsl,mma8653` → `mma_chip_info_table[mma8653]`.
`i2c_device_id mma8452_id[]` includes `mma8653`.

**There is no `acpi_device_id` table.** `mma8452_driver` sets only
`.of_match_table` and `.id_table`. This is the single most important fact: it
means ACPI enumeration does **not** work by default.

## Correction to earlier advice

An earlier assessment said *"`CONFIG_IIO` is redundant, `MMA8452` selects its own
deps."* That is **wrong**:

- `drivers/iio/accel/Kconfig` is sourced inside `if IIO … endif # IIO`
  (`drivers/iio/Kconfig:84`).
- `config MMA8452` has `depends on I2C` and `select IIO_BUFFER` /
  `select IIO_TRIGGERED_BUFFER`. **It does not `select IIO`.**
- Therefore `CONFIG_MMA8452=m` alone leaves the symbol **invisible** — it will not
  build at all.

**Correct requirement: `CONFIG_IIO=y` AND `CONFIG_MMA8452=m`.**

The original advice we were given ("enable CONFIG_IIO and CONFIG_MMA8452") was
right; my calling it redundant was the error.

## Why ACPI without a match table can still work

`i2c_device_match()` (`drivers/i2c/i2c-core-base.c:139`) tries, in order:
`i2c_of_match_device()` → `acpi_driver_match_device()` → `i2c_match_id()`.

`acpi_driver_match_device()` (`drivers/acpi/bus.c:993`): **if `drv->acpi_match_table`
is NULL, it calls `acpi_of_match_device(ACPI_COMPANION(dev), drv->of_match_table, NULL)`.**

And `acpi_of_match_device()` (`bus.c:777`) matches `_DSD` `"compatible"` strings
against the driver's `of_match_table`, case-insensitively via `strcasecmp`.

**Consequence: the missing `acpi_device_id` is NOT fatal for PRP0001 devices.**
If the firmware exposes `_HID = "PRP0001"` with `_DSD` property
`compatible = "fsl,mma8653"`, the driver binds today with no kernel change.

## Three cases, three different fixes

Run `test/diag-sensors.sh` on the device first — it tells you which case you are in.

### Case A — ACPI node with `PRP0001` + `compatible = "fsl,mma8653"`
Should already bind. No kernel change needed.
If it binds but rotation is wrong → **mount matrix** problem (below).

### Case B — ACPI node exists with an unrecognised vendor HID
The driver will not bind. Two options:

1. **Add an `acpi_device_id` table** (kernel patch):
   ```c
   static const struct acpi_device_id mma8452_acpi_match[] = {
       { "XXXX0001", 0 },   /* the real HID from diag output */
       { }
   };
   MODULE_DEVICE_TABLE(acpi, mma8452_acpi_match);
   ```
   and add `.acpi_match_table = mma8452_acpi_match,` to `mma8452_driver`.
   Upstreamable, small, and correct.

2. **Override the ACPI table** to expose PRP0001 instead — heavier, needs an
   initrd ACPI override, and DSDT patching is fragile.

Option 1 is preferable, but only if a real HID is present.

### Case C — no ACPI node at all (most likely for an Android-era Bay Trail tablet)
Instantiate manually on the specific I2C bus:

```bash
sudo modprobe mma8452
# N = the bus from diag-sensors.sh that shows 0x1d
echo mma8653 0x1d | sudo tee /sys/bus/i2c/devices/i2c-N/new_device
# verify
dmesg | tail -20        # should report the chip id it read
```

This works because `i2c_of_match_device_sysfs` strips the prefix and matches the
sysfs-provided name against the driver's `of_match_table`/`i2c_device_id`.

Persist it with a systemd unit (the bus number can change between boots):

```
# /etc/systemd/system/casper-sensor.service
[Unit]
Description=Instantiate MMA8653 accelerometer
After=systemd-modules-load.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/casper-sensor-bind
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
```

with a small script that finds the bus by scanning for 0x1d rather than
hardcoding a number.

## Mount matrix (orientation)

Once the device binds, the axes are almost certainly not what userspace expects —
tablets are mounted at 90° rotations. IIO exposes `mount_matrix` per device:

```
/sys/bus/iio/devices/iio:deviceX/mount_matrix
```

Set from a device-tree/ACPI property normally. From userspace the practical route
is a **udev rule** or a small systemd unit writing the matrix at bind time.

For a panel mounted rotated 90° (this tablet is physically portrait, used
landscape), a typical matrix is:

```
0 -1 0
1  0 0
0  0 1
```

`iio-sensor-proxy` reads `mount_matrix` and applies it, so GNOME receives
already-corrected orientation. **Do not** try to correct rotation in the shell —
fix it at the sensor.

## Verification sequence

1. `cat /sys/bus/iio/devices/iio:device*/name` → should say `mma8653`
2. `cat /sys/bus/iio/devices/iio:device*/in_accel_x_raw` while tilting the tablet
   → values must change
3. `monitor-sensor` → should print accelerometer orientation events
4. Tilt the tablet → GNOME rotates

If (1) works but (2) returns a constant, the chip is bound but not sampling —
check `sampling_frequency` and whether the device is in standby mode.

If (3) fails but (2) works, `iio-sensor-proxy` is not seeing the device — check
its `systemctl status` and that it is not blocked by a missing `mount_matrix`.

## Where this sits in the project

- **Not** needed for the desktop to work. Rotation is a nice-to-have.
- Blocked on a single run of `test/diag-sensors.sh` on real hardware.
- The kernel side is already covered: add `CONFIG_IIO=y` + `CONFIG_MMA8452=m` to
  the fragment.

## Sources
- `torvalds/linux` v6.12: `drivers/iio/accel/mma8452.c`, `drivers/iio/accel/Kconfig`,
  `drivers/iio/Kconfig`, `drivers/i2c/i2c-core-base.c`, `drivers/acpi/bus.c`
- `Documentation/iio/`, `Documentation/firmware-guide/acpi/DSD-properties-rules.rst`
