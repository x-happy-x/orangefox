# ANDROID-3 UI adjustment

The primary panel is 1200 x 2608 pixels. Android reports rounded corners with
radius 170 pixels, top centers (170, 170) and (1030, 170), and a center cutout
bounding rectangle (566, 0)-(634, 144). Recovery's primary DSI modes confirm
1200 x 2608. The secondary 976 x 596 display is unrelated to this adjustment.

The profile uses `OF_SCREEN_H=2347`, `OF_STATUS_H=72`,
`OF_STATUS_INDENT_LEFT=112`, and `OF_STATUS_INDENT_RIGHT=92`, without LAB.
These are theme units, not Android density settings. The theme's width is
1080; its default virtual height was 1920. `gui/pages.cpp:1373-1427` scales
the axes independently, using `screen_original_h` for height. At zero offsets,
1200/1080 = 1.111111 and 2608/2347 = 1.111206 make the axes effectively equal.
This reduces vertical widget heights and spacing by 18.2% compared with the
old height. Font sizes use the smaller axis, so this height change alone
does not shrink text (`gui/resources.cpp:174`, `gui/gui.cpp:1213-1221`).

The status bar retains the existing height of 72 theme units, approximately
80 physical pixels. Its text top is `(status_h / 2) - 28`, or 8 theme units
and approximately 8.89 physical pixels (`data.cpp:819-832`). The conservative
corner boundary there is `170 - sqrt(170^2 - (170 - 8.89)^2) = 115.75` pixels.
Both selected horizontal margins are approximately 124.44 physical pixels.
The right flag is 20 units smaller because `resources/vars.xml:381` anchors
the right text at `1060 - status_indent_right` on a 1080-unit canvas;
`pages/templates/statusbar.xml:9-30` supplies the left and right anchors.
The previous default margins were only 22.22 and 44.44 physical pixels.
This addresses the rounded corners; it does not reserve a 144-pixel full-width
strip for the central camera. `OF_CLOCK_POS=1` hides the Center clock option
while allowing Left and Right; it does not override an existing placement.
Actual placement is the persisted `center_clock` setting
(`resources/vars.xml:5`, `pages/customization.xml:290-293`).

`ui-source-edits.json` makes every initially loaded TTF 90% of its calculated
size, rounded to the nearest integer with a minimum of 1. It changes only
`FontResource::LoadFont`, immediately before `origFontSize` is saved. Existing
font family, weight, and size selections remain effective, including the
saved `%fox_theme_path%/font.xml` which takes precedence over the built-in default
(`ui.xml:12`). Language font overrides scale the already reduced
`origFontSize`, so the adjustment is applied once rather than twice
(`gui/resources.cpp:165-175,213-220,624-635`). Each theme reload creates new
font resources; the reduction does not accumulate across reloads. No new
include or build flag is needed for this popsicle-specific overlay.

The upstream Small preset is not used: it reduces body text from 42 to 34,
leaves menu text at 44, and changes the lock-screen clock from 210 in the
built-in default to 240. Editing only a stock font XML would be overridden
by an existing saved theme; changing the loader gives the requested modest
reduction immediately for both built-in and saved fonts.

The two Magisk removal entry points are hidden because this port's root ZIP
supports guarded installation and rejects removal. One exact XML edit
removes the `Uninstall Magisk` list item from Fox Addons (`advanced.xml:440-443`);
another removes both the deletion button and its icon from the Magisk modules
header (`rmmanager.xml:147-160`). Removing the paired elements leaves no stray
touch target or icon. Back uses the separate base-template `ab_back_x` anchor;
the other header and list anchors remain unchanged. The `mod_unmagisk` page
is retained but has no theme navigation entry point. Root removal remains an
operation for the corresponding Manager or a verified stock backup; the UI
does not promise automatic root migration.

Deleting only `uninstall.zip` would not hide the unconditional Addons list
item. In addition, `vendor/recovery/FoxExtras/sbin/foxstart.sh:579-583`
recreates that file from `/FFiles/OF_Magisk/Magisk.zip` at startup. The ZIP's
removal guard therefore remains necessary. Installation labels retain the
stock localization: `Install Magisk` / `Установить Magisk` and
`Install KernelSU` / `Установить KernelSU`, followed by their version labels.

The text viewer's tap failure is a selection-state bug, independent of file
permissions. `files.xml:2190-2198` binds the viewer list to `of_file_to_read`.
Previously, tapping a text row selected that row and `listbox.cpp:550-553`
assigned its displayed contents to this path variable. The notification at
`listbox.cpp:404-409` then tried to open those contents as another filename.
The constructor now disables selection only for `of_file_to_read`; scrolling
and other selectable lists are unchanged. User file contents are not needed
to confirm the bug and must not be collected from the resulting error logs.

`OF_USE_NANO_EDITOR=1` enables the existing `Edit in nano` /
`Редактировать в nano` action in file options. It opens a full-screen nano
editor inside OrangeFox's terminal, with its onscreen keyboard and
Ctrl/Esc/Tab/Left/Down/Up/Right row. Use the arrows to move the cursor;
Ctrl+O then Enter saves, and Ctrl+X exits and closes this editor's fresh PTY.
An already running terminal session is preserved: launching an editor into
that unknown state is refused with an English/Russian message. The new
editor uses `exec /system/bin/nano`, replacing only its own freshly started
shell. Its saved terminal-directory marker is cleared before launch so Back
does not send a shell command into the editor. Tapping the terminal toggles the
keyboard; touch-to-position editing is not implemented. `Open > Text` remains
the read-only viewer.

The build explicitly requires the already pinned `nano_recovery` module.
Its `external/nano/Android.bp:74-91` dependencies install recovery ncurses,
syntax files and a nanorc with `/system_ext` paths rewritten to `/system`.
This replaces the obsolete `Android.mk:728-734` copy from a nonexistent
`$(TARGET_OUT_ETC)/nano` directory. `FOX_USE_NANO_EDITOR` is unnecessary and
the vendor's older prebuilt editor is not added.

The launch action now receives a filename rather than a shell command. C++
constructs `exec /system/bin/nano --` with one single-quoted argument and escapes embedded
apostrophes, preserving spaces and treating `$()`, backticks and other shell
characters literally. It rejects terminal control bytes and malformed UTF-8
before sending any input. An explicit decoder rejects overlong sequences,
surrogates, out-of-range code points and C0/C1 controls, without exceptions
or new includes. Valid UTF-8 is decoded to code points for
`NotifyCharInput`, and paths longer than 255 bytes no longer wrap the old
`uint8_t` loop counter. Host checks compile this exact function and pass
synthetic filenames through a real shell into a stand-in nano; no user file
is opened by those checks.

Target compile evidence: the module is `libfoxui` (`gui/Android.bp:23`),
with `action.o` using `m.libfoxui_android_arm64_armv8-a_static.cFlags1` in
`out/soong/build.twrp_popsicle.6.ninja`. Expanding its Ninja variables gives
`-fno-exceptions` and `-std=gnu++20`; the exception flag comes from
`g.android.soong.cc.config.CommonGlobalCflags`. The initial host check with
default exceptions did not cover this constraint. The decoder is checked
without exceptions and with the actual target compiler flags in syntax-only
mode against a temporary patched copy, leaving the source checkout intact.

The RPC output FIFO previously used blocking `fopen("foxout", "w")` on the
GUI thread. If a client disappeared before opening its response reader, that
thread could wait indefinitely for a FIFO partner. `fox_fifo/fox_channel.cpp`
now opens the existing FIFO with `O_WRONLY | O_NONBLOCK | O_CLOEXEC`, retrying
`ENXIO`/`EINTR` at most 50 times with 10 ms between attempts (490 ms of explicit
waiting). This admits the existing client's write-request/close/open-response
handshake without an unbounded GUI wait. The descriptor must refer to a FIFO;
once connected, `O_NONBLOCK` is cleared and `fdopen` retains ordinary buffered
writes for large PNG replies. Every descriptor-setup failure closes the raw
descriptor. If no output reader connects, the request is dropped and both
FIFOs are rearmed before command dispatch, so the abandoned command is not
executed and the channel remains available.

This fix addresses the absent-reader open only. A connected reader which
stays open but stops draining output can still apply backpressure to the
existing blocking write path. A client delayed beyond the connection window
can miss its response and must use a host-side timeout. Neither the client
nor the protocol is changed. Recovery already ignores SIGPIPE
(`twrp.cpp:438`); a reader disconnect therefore produces an output error
instead of terminating recovery. PIN and decryption behavior are unchanged;
this FIFO finding does not establish the cause of any separate cold-boot
PIN problem.

Real host FIFO checks compile the exact helper and caller snippets and cover
absent-reader drop/rearm (494 ms observed), a delayed reader receiving an
identical 4 MiB response, disconnects before and during a large write, and a
successful subsequent request after rearm. They also confirm that a connected
descriptor uses blocking writes. The full patched channel passed syntax-only
compilation with the actual `recovery/fox_fifo/fox_channel.o` command flags
from `out/build-twrp_popsicle.ninja` rule30097, using Android
`clang-r547379/bin/clang++`, `-fno-exceptions` and `-std=gnu++20`. Original
channel blob: `d17c403b2b531a429170f63c556652974b3e966d`; patched SHA-256:
`43bb08f7f8a04ac844225469fa87ae5e1afdae5a1d0a6f63f964dab94d5cc1a2`.
These checks used temporary host FIFOs and source copies; no phone commands
or source-checkout writes were performed.

Exact base: `bootable/recovery` commit
`0f7831d3240f4c3925a0b5fd7d2c907ddf8704c2`, original `gui/resources.cpp` Git
blob `127f7416c83e493bd9a82c641483f50dcf3f3923`. The fragment must be applied
and verified against the original blobs alongside the core source edits.
Original XML blobs are `bfed6852fe19220715ed46a9a307254ec967ceef` for
`gui/theme/portrait_hdpi/pages/advanced.xml` and
`6bf904493164e6673e4a96b2b06002f5f9c3f6a8` for
`gui/theme/portrait_hdpi/pages/rmmanager.xml`.
It does not touch crypto, vendor, or device files. Validation at preparation
time covers JSON parsing, unique replacements against the original Git blobs,
parsing all resulting XML documents, absence of navigation actions to the
removal page, integer rounding, the positive-size lower bound and editor
argument quoting. Build and on-device screenshots are separate checks; the
source checkout was not changed for this validation.
