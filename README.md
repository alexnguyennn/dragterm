# dragterm 1.1

Drag and drop from the command-line, updated to use modern API.

The tool itself is called “`drag`”, as that's a lot nicer to type than “`dragterm`”.

## Usage

`drag <files>`

And drag the icon that appears under the mouse cursor.

The icon stays glued to the pointer until you press, so you can move wherever you need to
before starting the drag. Moving more than 1500 points from where `drag` was invoked
abandons the drag (set `DRAG_CANCEL_RADIUS` to change it).

Pressing Escape, q, Ctrl-C, or Ctrl-D will cancel; so will closing stdin.

Set `DRAG_DEBUG=1` to log what the tool is seeing (dispatched events, the drag session
lifecycle) to stderr.

### `drag --clipboard <files>`

Puts the files on the clipboard as file references instead of dragging them, so that Cmd-V
in Finder, Mail, Slack, or a browser upload field does the same job. This exists because
dragging itself no longer works from a shell on macOS 26 — see Notes.

## History

- 1.1
	- Uses the relative path as typed when displaying a “not found” error, instead of the full path.
	- Restored the ability to cancel with the Escape key (or `q`/`Ctrl-C`/`Ctrl-D`), without needing accessibility access.
	- Fixes a crash when passing an unrecognized option.
	- Prints usage to stderr instead of stdout when it's printed because of an error (vs. `--help`).
- 1.0.2
	- Increased drag-start area to 256 × 256.
	- Supports dragging files to the Trash.
	- Added `--version` and `--help` options.
- 1.0.1
	- Supports multiple files.
- 1.0
	- Initial release.

## Notes

Starting a drag without a view (as <https://github.com/ciaran/drag> does) doesn't seem to
work anymore, hence the transparent window appearing under the mouse (which should mostly
behave the same).

### macOS 26: a process started from a shell cannot host a cross-application drag

The drag image appears and follows the pointer, but no destination ever highlights and the
button release is delivered to whichever application is frontmost. What the measurements
say, on macOS 26.4:

- LaunchServices keeps no record of the process. `lsappinfo info -pid` reports a NULL
  activation policy, NULL visibility, NULL active, and the process is absent from
  `lsappinfo list` — including for a vanilla bundled AppKit app whose only job is to ask.
- Consequently it can never be the active application. `setActivationPolicy:` is accepted
  and reports back `Regular`, while `NSWorkspace.frontmostApplication` stays the terminal
  and `-[NSApplication activate]` does nothing.
- `NSApp.run` (rather than draining the event queue by hand) does not change this,
  `TransformProcessType` is not the lever, and neither is `_LSApplicationCheckIn` nor
  `_RegisterApplication: both answer noErr and the record still does not exist.
- Linking against the 15.4 SDK instead of 26.5 changes nothing, so it is not a
  linked-on-or-after behaviour gate.
- Launching the bundle through LaunchServices (`open`) is the way to get a registered,
  activatable process, but launches of locally built ad-hoc bundles are held: the process is
  left stopped at `_dyld_start` with `main` never reached, while the same command starts a
  system application normally. This is not a property of the bundle — `./probe-open.sh`
  launches seven copies of the installed bundle, each differing in exactly one thing
  (hardened runtime on/off, entitlements on/off, minimal `Info.plist`, thin arm64 binary,
  clang-built instead of Xcode-built) plus different `open` flags, and every one of them
  behaves identically: the same fraction of launches reach `main`. It is a race in the launch
  handshake, and how often it is won depends on the calling context, not on what is being
  launched. `probe-open.sh` prints that fraction; run it from the terminal you use `drag`
  from, because a non-interactive shell loses the race almost always.

The system drag pasteboard is reachable from the unregistered process — `declareTypes:` and
`writeObjects:` both succeed against `NSPasteboardNameDrag` — so the pasteboard is not the
problem; the drag session is simply never advertised to other applications. Writing a file
URL to the *general* pasteboard with `NSPasteboard` does fail from an unregistered process,
which is why `--clipboard` shells out to `osascript`.

## Installing

Use `./install.sh`. It builds a release binary, wraps it in `drag.app` with `LSUIElement`,
installs that under `~/.local/share/dragterm`, and leaves a two-line wrapper at
`~/.local/bin/drag` that execs the binary inside the bundle.

The bundle is not cosmetic. A bare executable has no bundle for LaunchServices to
classify, so it comes up as `NSApplicationActivationPolicyProhibited`, which can never be
activated. macOS 26 will happily deliver pointer motion to such a process and never deliver
it a single click, so the drag can't start. `install.sh` also has to be a wrapper rather
than a symlink to the bundle binary, because the main bundle is derived from the path the
binary was exec'd by.
