# dragterm 1.1

Drag and drop from the command-line, updated to use modern API.

The tool itself is called “`drag`”, as that's a lot nicer to type than “`dragterm`”.

## Usage

`drag <files>`

And drag the icon that appears under the mouse cursor.

Pressing Escape, q, Ctrl-C, or Ctrl-D, or moving the mouse far enough from the icon before dragging will cancel.

### On macOS 26 and later

Dragging does not reach other applications, so `drag` puts the files on the clipboard instead
and prints `Copied ... paste with Cmd-V`. Pass `--drag` to try dragging anyway, or
`--clipboard` to force the clipboard on a version where dragging works.

The reason is outside this tool: on macOS 26, LaunchServices keeps no application record for a
process exec'd from a shell (`lsappinfo info -pid` reports a NULL activation policy and the
process is absent from `lsappinfo list`), and without that record the drag session is never
advertised to another process. The icon still follows the pointer because the drag image is
drawn and moved by us, but no destination ever highlights and the button release is delivered
to whichever application is frontmost. A 40-line vanilla AppKit app behaves identically.

Clipboard mode needs none of that, and it is not done with `NSPasteboard` on purpose: writing
a file URL with `-[NSPasteboard writeObjects:]` fails for a process with no application
record, so `osascript` sets a real file reference (`«class furl»`) instead, which is what
Finder, Mail, Slack and browser upload fields accept as a paste.

The full investigation, including everything measured and ruled out and the one experiment
that would reopen the drag path, is on the `exp/macos26-drag-blocked` branch in
`docs/macos26-drag-blocked.md`.

## History

- Unreleased
	- On macOS 26 and later, copies to the clipboard by default, because dragging cannot reach another application there. `--clipboard` and `--drag` override.
	- Stops ringing the bell in a tight loop when stdin is closed, which is how launchers such as yazi run it (over a million BEL bytes into the terminal).
	- Restores the terminal's termios settings on exit, since this runs raw-mode on a terminal a full-screen TUI owns.
	- `./install.sh` builds and installs the app bundle and the `drag` launcher.
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

Starting a drag without a view (as <https://github.com/ciaran/drag> does) doesn't seem to work anymore, hence the transparent window appearing under the mouse (which should mostly behave the same).
