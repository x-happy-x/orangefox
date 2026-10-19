# Recovery Secure Element readiness helper

Install `android-dev-crypto-ready.sh` as
`/system/bin/android-dev-crypto-ready.sh` (0755) and the RC as
`/system/etc/init/android-dev-crypto-ready.rc` (0644). The build callback and
post-image hash checks own packaging. No original device/reference files change.

The disabled, one-shot init service starts after variant files are copied for
NXP Weaver. The script additionally requires the exact `popsicle` hardware SKU.
It waits at most 60 seconds using `/proc/uptime` and finds ADSP by its remoteproc
name (`adsp` or a name ending in `remoteproc-adsp`), without assuming an index.
Only an actual `running` ADSP and `vendor.sys.listeners.registered=true` permit
publishing `twrp.adsp.ready=true`.

Property writes use absolute `/system/bin/setprop` with a per-command timeout
bounded by the remaining deadline. The helper verifies property readback,
rechecks hardware readiness, requests the idempotent `ctl.start` for
`vendor.secure_element`, and confirms its init state is `running`. Failed writes,
readback, or start confirmation retry within the deadline and never return
success merely because a command was attempted. The script does not set a false
hardware-ready value, restart any HAL, submit a PIN, or read/write user data.
Its diagnostic output goes to the kernel log through init `stdio_to_kmsg`.

As in the native wait script, `twrp.adsp.ready` is a startup latch, not continuous
hardware monitoring. Readiness is verified when published. If ADSP stops before
the second check, the helper retries its explicit start request; it does not reset
a readiness property that the native script may also have published. The original
device init trigger may already have started Secure Element on the property edge.

The observed failure was a missing Secure Element service, not a rejected PIN:
NXP Weaver `getConfig` could not connect to OMAPI. OMAPI waits for
`android.hardware.secure_element.ISecureElement/eSE1` before registering itself.
Manually starting the existing Secure Element service restored decryption on the
phone. The native wait script later published readiness when started again. The
initial race mechanism is not proven; this helper adds bounded late retries
without replacing crypto binaries or changing the original device init files.

Run offline checks with:

```sh
python3 port/recovery-helpers/test-crypto-ready.py
sh -n port/recovery-helpers/android-dev-crypto-ready.sh
shellcheck -s sh port/recovery-helpers/android-dev-crypto-ready.sh
```

Host fixtures exercise only the production function definitions with mocked
property commands, time, and temporary sysfs names/states. They never execute the
device entry point or contact a phone. A successful helper start confirms process
readiness; it does not by itself prove a working Binder HAL or FBE decryption.
