# Installed modules in Fox Addons

ANDROID-3 adds **Fox Addons → Installed modules** beside the explicit Magisk and
KernelSU installation choices. The chooser opens the existing OrangeFox module
list and module actions; it does not install root or modules. English and Russian
labels distinguish unavailable Data, an absent root provider, inaccessible module
storage, and an empty module list.

`modules-source-edits.json` contains 14 declared edits against the pinned
`bootable/recovery` source. Apply them after `ui-source-edits.json`; they compose
with that fragment's removal of Magisk uninstall controls. No C++ backend or
crypto/fstab changes are needed.

## Data and provider selection

Opening the chooser reads mount metadata and known provider directories only.
It neither mounts storage nor creates directories. Data must actually be mounted
read/write from a block device as ext4 or f2fs. This checks usable Data rather
than relying on `tw_is_decrypted`, which can already be set for FBE before the
credential-encrypted files are unlocked. Existing `/data/adb` and provider
directories must also be accessible.

Magisk and KernelSU are offered only when their respective known directories
exist and are accessible. If both are present, the user chooses explicitly; the
menu does not resolve an inconsistent root installation. The existing Advanced
entries, including APatch, retain access to the same manager. Provider version
display does not execute binaries or source scripts from `/data/adb`.

Modern providers use `/data/adb/modules` directly. An existing empty directory
is a valid empty list. A missing directory produces an informational empty state
without creating it. Enabling and disabling a module continues to use the
unmodified native `disable` flag action; the change does not introduce a module
installer, automatic toggles, or a new module execution mechanism. Other native
module actions remain upstream behavior.

## Legacy image ownership and exit

Only an explicit provider selection can mount a readable legacy
`modules_update.img` or `modules.img`, and only onto an existing nonsymlink module
directory. A pre-existing mount is never adopted. The manager records and checks
the loop-device source and canonical backing image before unmounting its own
image. If validation or unmount fails, it reports the error and keeps ownership
metadata rather than pretending cleanup succeeded.

Home and Back from the list, chooser, and existing module-action paths go through
`modules_unmount`. A mounted image must be released before choosing another
provider. Direct-directory providers have no image mount to release.

## Validation

- All source, UI, module, and root fragments applied sequentially in memory to
  pristine Git blobs: each declared context occurred exactly once; all resulting
  XML parsed successfully. Final composition is 35 edits across 20 files.
- Native module `disable` actions and UI uninstall-control removals remained
  unchanged after composition. Theme styles, icons, and placement variables used
  by the new chooser exist in the pinned theme.
- The no-root text is rendered after the empty provider listbox, whose native
  background is painted even with no visible items. This keeps the no-root
  message visible. Explicit entry from Fox Addons resets prior storage errors;
  returning from a failed mount keeps the relevant error message.
- All three embedded shell scripts passed shell syntax checks and ShellCheck
  after substituting GUI placeholders with shell fixture variables.
- Eight isolated fixtures covered unavailable Data, no providers, explicit
  provider detection, an empty KernelSU directory, a missing module directory,
  rejection of an existing foreign mount, failed owned-image unmount, and
  successful cleanup. Mount operations were stubbed; fixtures used temporary
  directories only.

The first rebuilt UI booted on the phone. A direct RPC page jump retained a prior
storage-error state and exposed the empty-list background overlap; this fragment
corrects the overlap. Generic RPC variable queries can leave and re-enter the
page while the action thread is busy, so its FTLS probe can be skipped.
Ordinary UI navigation is required for the chooser check.

The offline checks did not open user files, alter installed modules, or load a
root module. On-device validation then used normal Fox Addons navigation with
the user's working KernelSU and one explicitly selected inert test module.
The user enabled it (the `disable` flag disappeared), then disabled it (the flag
returned). ADB confirmed both states. Its only files were `module.prop` and the
empty flag; no scripts or mounted payloads existed. The test module and its
newly created empty parent directory were removed afterwards. Existing user
modules were not changed; installing third-party modules was not tested.
