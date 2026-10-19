# Why `drag` cannot drag on macOS 26, and what was ruled out

Investigated 2026-10-19 on `theta` (M5 Max MacBook Pro, macOS 26.4 / 25E246), against
`dragterm` built with Xcode 26.6.0 / MacOSX26.5.sdk. Reference machine for comparison is
`zeta` (M1 Max MacBook Pro, older macOS), where dragging works.

## Symptom

`drag <file>` shows the icon under the cursor, the press starts a session
(`mouseDown:` → `draggingSession:willBeginAtPoint:` both fire), and the drag image tracks the
pointer. But no destination application ever highlights, and releasing the button does nothing
to the destination. The session appears to never end: the icon keeps following the pointer.

## Root cause

**A process exec'd from a shell has no LaunchServices application record**, and without that
record a drag session is never advertised to other processes.

```
$ lsappinfo info -only ActivationPolicy -only visible -only active -Foremost -pid $(pgrep -f MacOS/drag)
"ActivationPolicy"=[ NULL ]
"visible"=[ NULL ]
"active"=[ NULL ]
"Foremost"=[ NULL ]
```

The process is also absent from `lsappinfo list`. This is not specific to `dragterm`: a
40-line vanilla AppKit app (`NSApplicationLoad`, `sharedApplication`, policy `Regular`,
`[NSApp run]`, delegate logging from `applicationDidFinishLaunching:`) reports the same NULLs
and is refused activation as well.

Consequences, all observed:

- it can never become the active application, whatever is called;
- the drag session it starts is local to its own process: AppKit draws and moves the drag
  image because we do, and no other application is told a drag is under way;
- the button release is delivered to whichever application is frontmost, so the session
  never sees it and looks "sticky".

## Ruled out, by measurement rather than reasoning

| Hypothesis | Result |
| --- | --- |
| `acceptsFirstMouse:` and click delivery | clicks *are* delivered when it returns `YES`; returning `NO` only swallows the click |
| Non-activating `NSPanel` vs plain `NSWindow` | the window was already a plain `NSWindow`; not the lever |
| Manual event queue draining instead of `-[NSApp run]` | a genuine bug (fixed: `finishLaunching` never ran), does not affect registration |
| `NSApplicationActivationPolicyProhibited` because there is no bundle | real, and fixed by bundling; still no record afterwards |
| `TransformProcessType` with a bogus PSN | `GetCurrentProcess()` was wrong; `kCurrentProcess` is right. Returns `noErr` once `_RegisterApplication` is called first — and nothing changes |
| `_RegisterApplication` / `_LSApplicationCheckIn` | both return `noErr`; the record still does not exist, `lsappinfo` unchanged |
| Launching via `launchctl submit` instead of exec | process ran, logged, still `active 0` |
| macOS 26 SDK linked-on-or-after gate | binary linked against `MacOSX15.4.sdk` (`sdk 15.4` in `LC_BUILD_VERSION`) behaves identically |
| Hardened runtime, entitlements, `Info.plist` contents, universal vs thin arm64, Xcode-built vs clang-built | 9 bundle variants, 3 launches each, all identical — see `probe-open.sh` |
| `open` invocation flags (`-F`, `-j`, `-g`, `--arch`) | identical |
| Pasteboard access denied | the *drag* pasteboard is writable from the unregistered process: `declareTypes:` bumps the change count, `writeObjects:` succeeds, the URL reads back |
| Writing a file URL to the *general* pasteboard | fails (`writeObjects:` returns `NO`, change count unmoved) — which is why `--clipboard` shells out to `osascript` |

## The one route to a fix, and why it stalled

Getting an application record requires LaunchServices to launch the process, i.e. `open`.
On this machine no ad-hoc-built bundle ever reached `main` that way: 24 launches across 9
variants in two different shells, all held stopped, while
`open -na /System/Applications/Calculator.app` works normally.

One data point contradicts this: early in the investigation a trivial AppKit bundle in `/tmp`
*did* launch and run from the interactive terminal. Two candidate explanations, not
distinguished:

1. macOS 26 holds LaunchServices launches of bundles it has not assessed, and that one slipped
   through on first registration.
2. The machine's LaunchServices/RunningBoard state was degraded by roughly thirty held
   launches during the investigation.

**To resume: reboot `theta`, then run `./probe-open.sh` (~2 min, no interaction).**

- `control in /tmp → always ran` → the LaunchServices path is alive. Whichever variant also
  reports `always ran` names the single property to change in `install.sh`, and real dragging
  becomes reachable.
- `control in /tmp → HELD` → this is an OS policy on Tahoe and nothing in this repository
  fixes it.

## Measurement traps encountered (each cost at least one wrong conclusion)

- **Process state `T` means nothing here.** `open`-launched Calculator shows `T` two seconds
  after launch. Only an on-disk marker written as the first statement of `main` distinguishes
  "held at `_dyld_start`" from "ran". `--debug --selftest` writes
  `/tmp/dragterm-selftest.log`.
- **`pgrep -f <binary> | head -1` samples the wrong process** when earlier attempts are still
  stopped. That produced phantom results (`--arch arm64 → ran`, `-j → ran`) which vanished
  under repetition. Any launch test must kill prior instances first and repeat at least 3x.
- **The `built %s %s` debug stamp lies under incremental builds**: it is `__DATE__ __TIME__`
  from `main.m`, which is not recompiled when only other files change. A "stale binary"
  conclusion drawn from it was wrong.
- **`launchctl submit` respawns.** A job submitted during testing kept relaunching `drag`
  after every kill, which presented as a file icon blinking under the cursor with nothing
  obvious in Activity Monitor (stopped, 0 % CPU, ~1 s lifetime). Removed with
  `launchctl remove org.derailer.dragtest`. Do not leave submitted jobs behind.
- **`lsappinfo` reports bundle metadata even for unregistered processes.** The distinguishing
  fields are the NULL ones: activation policy, visibility, active.

## Artifacts on this branch

- `install.sh` — builds and installs `drag.app` (LSUIElement agent) and `drag-regular.app`
  (regular), plus `drag-open`, a wrapper that hands the launch to LaunchServices and reaps
  stopped attempts.
- `dragterm/DTActivation.h` — `_RegisterApplication` / `_LSApplicationCheckIn` wrappers and
  the policy logic. Both calls return `noErr` and have no observable effect; kept as the
  documented dead end.
- `dragterm/DTLog.h` — stderr logging (`DRAG_DEBUG=1`) and the `--selftest` marker.
- `build-sdk15.sh` — installs `drag-sdk15` against `MacOSX15.4.sdk` to test the
  linked-on-or-after hypothesis.
- `probe-open.sh` — the bundle-variant and `open`-flag bisect described above, self-contained
  (it builds its own control app).
- `DRAG_SELFTEST=1` / `--selftest` — reports activation state and writes the marker file.
- `DRAG_CLICK_TO_ACTIVATE=1`, `DRAG_POLICY`, `DRAG_CANCEL_RADIUS` — experiment switches.
- `--clipboard` / `-c` — the fallback that works.

## The working fallback

`drag --clipboard <files>` puts file references on the clipboard via `osascript`
(`set the clipboard to (POSIX file "...")`, or a list of them), which Finder, Mail, Slack and
browser upload fields accept with Cmd-V. Verified for a single file, multiple files, and paths
containing quotes and spaces. It works because it does not need an application record,
activation, or a drag session.
