# android-dev

Follow `P:\services\AGENTS.md`. Tracker project: ANDROID; main branch: master.

This repository prepares the `android-dev` WSL2 distro at
`R:\vm\wsl\android-dev` and an experimental OrangeFox port for Xiaomi 17 Pro Max
(`popsicle`, Android 16).

Keep source revisions pinned. Build inside the distro's ext4 filesystem, never
on `/mnt/*`. Do not flash a phone, erase data, change AVB flags or replace
device-specific crypto components as part of environment setup.

Check shell scripts with `bash -n` and `shellcheck`; parse PowerShell scripts
before running. A successful build does not verify boot or data decryption.
Record hardware checks separately. Do not label an untested image as safe to flash.
