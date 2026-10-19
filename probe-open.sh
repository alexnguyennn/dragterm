#!/bin/sh
# Bisect why `open` leaves the installed bundle stopped at _dyld_start.
#
# Observed, from an interactive terminal:
#
#   open -n /tmp/gui.app                          -> ran (main executed, activation refused)
#   open -n ~/.local/share/dragterm/drag-*.app    -> held stopped, main never reached
#
# Both are ad-hoc signed bundles in user-writable directories, so the difference is in how the
# real bundle is built or signed. Each variant below differs from the installed bundle in
# exactly one thing.
#
# Ground truth is /tmp/dragterm-selftest.log, which the app appends to as the first thing it
# does when passed --selftest. A process held at _dyld_start cannot write it, and it does not
# depend on stdio, which `open` may not connect. Process state is reported as well, but the
# marker is what decides.
#
# Run this from the terminal you use drag from. A script runner or an IDE shell reproduces a
# different bug: launches from a non-interactive shell are held stopped regardless of bundle.
set -u

prefix="${PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/dragterm}"
root="$(cd "$(dirname "$0")" && pwd)"
src="$prefix/drag-regular.app"
work="/tmp/dragvariants"
probe="/tmp/dragprobe.txt"
marker="/tmp/dragterm-selftest.log"

[ -d "$src" ] || { echo "no installed bundle at $src; run ./install.sh first" >&2; exit 1; }

[ -f "$probe" ] || echo probe > "$probe"

rm -rf "$work"
mkdir -p "$work"

reset_state() {
	pkill -9 -f 'dragterm/drag.*\.app/Contents/MacOS/drag' 2>/dev/null
	rm -f "$marker"
	sleep 0.5
}

# make_variant <name> <hardened:yes|no> <entitlements:yes|no> <plist:real|minimal> [binary]
make_variant() {
	name="$1"
	hardened="$2"
	ents="$3"
	plist="$4"
	binary="${5:-$src/Contents/MacOS/drag}"
	app="$work/$name.app"

	rm -rf "$app"
	cp -R "$src" "$app"
	cp "$binary" "$app/Contents/MacOS/drag"

	if [ "$plist" = "minimal" ]; then
		cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>drag</string>
<key>CFBundleName</key><string>drag</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
EOF
	fi

	# A distinct identifier per variant, so LaunchServices cannot answer one variant from
	# another's registration.
	plutil -replace CFBundleIdentifier -string "org.derailer.dragterm.$name" "$app/Contents/Info.plist" 2>/dev/null

	codesign_args="--force --sign -"

	[ "$hardened" = "yes" ] && codesign_args="$codesign_args --options runtime"
	[ "$ents" = "yes" ] && codesign_args="$codesign_args --entitlements $root/drag.entitlements"

	# shellcheck disable=SC2086
	codesign $codesign_args "$app" >/dev/null 2>&1 || echo "  (signing failed for $name)"
}

# report <label> <app-path> - launch one variant several times and report how often main ran.
#
# Repetition matters: a single launch says nothing, because a hold caused by a race in the
# launch handshake looks identical to a hold caused by the bundle's contents.
report() {
	label="$1"
	app="$2"
	shift 2

	ran=0

	for trial in 1 2 3; do
		reset_state
		open -n "$@" "$app" --args --debug --selftest "$probe" 2>/dev/null
		sleep 2.5

		[ -f "$marker" ] && ran=$((ran + 1))

		# The binary is named after the bundle it came from, so match the directory and let the
	# shell find whatever executable is inside it. Hardcoding "drag" here meant the control
	# app was never reaped and piled up six stopped copies across runs.
	pid=$(pgrep -f "^$app/Contents/MacOS/" | head -1)

		if [ -n "$pid" ]; then
			state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
			kill -9 "$pid" 2>/dev/null
		fi
	done

	case "$ran" in
		0) verdict="HELD" ;;
		3) verdict="always ran" ;;
		*) verdict="RACY" ;;
	esac

	printf '  %-22s %-10s %d/3 reached main, last state %s\n' "$label" "$verdict" "$ran" "${state:-gone}"
	return 0
}

clang_built="$root/build-sdk15/drag"

make_variant a-installed yes yes real
make_variant b-plain-signing no no real
make_variant c-hardened-no-ents yes no real
make_variant d-ents-no-hardened no yes real
make_variant e-minimal-plist no no minimal

# f needs the thin binary in place before signing, so it is not built by make_variant
rm -rf "$work/f-thin-arm64.app"
cp -R "$src" "$work/f-thin-arm64.app"
plutil -replace CFBundleIdentifier -string org.derailer.dragterm.f-thin-arm64 "$work/f-thin-arm64.app/Contents/Info.plist" 2>/dev/null
lipo "$src/Contents/MacOS/drag" -thin arm64 -output "$work/f-thin-arm64.app/Contents/MacOS/drag" 2>/dev/null
codesign --force --sign - --options runtime --entitlements "$root/drag.entitlements" "$work/f-thin-arm64.app" >/dev/null 2>&1

if [ -x "$clang_built" ]; then
	# g: same bundle and signing as installed, but the binary came from plain clang instead of
	# the Xcode target. This is the axis that separates it from the app that did launch.
	make_variant g-clang-binary yes yes real "$clang_built"
fi

# FLAGS_ONLY=1 skips the build variants and only sweeps how open is invoked.
if [ "${FLAGS_ONLY:-0}" != "1" ]; then
	echo "each variant differs from the installed bundle in exactly one thing, all in /tmp:"
	echo
	report "a installed" "$work/a-installed.app"
report "b plain signing" "$work/b-plain-signing.app"
report "c hardened, no ents" "$work/c-hardened-no-ents.app"
report "d ents, no hardened" "$work/d-ents-no-hardened.app"
report "e minimal plist" "$work/e-minimal-plist.app"
report "f thin arm64" "$work/f-thin-arm64.app"

	if [ -d "$work/g-clang-binary.app" ]; then
		report "g clang-built binary" "$work/g-clang-binary.app"
	fi

	# h: the installed bundle copied into /tmp unchanged, which is the one property the app
	# that did launch has that none of the variants above isolated on its own.
	rm -rf /tmp/drag-installed.app
	cp -R "$src" /tmp/drag-installed.app
	plutil -replace CFBundleIdentifier -string org.derailer.dragterm.h-tmp-copy /tmp/drag-installed.app/Contents/Info.plist 2>/dev/null
	codesign --force --sign - --options runtime --entitlements "$root/drag.entitlements" /tmp/drag-installed.app >/dev/null 2>&1
	report "h copy in /tmp" /tmp/drag-installed.app
	rm -rf /tmp/drag-installed.app
fi

echo
echo "the installed bundle, launched with different open flags:"
echo
report "plain" "$src"
report "-F fresh" "$src" -F
report "-j hidden" "$src" -j
report "-g background" "$src" -g

echo
echo "control - a trivial AppKit app, built here, in /tmp:"
echo

# Built rather than assumed present, so the script has no external dependencies: this is the
# reference point that says whether open can launch anything at all from this shell right now.
# It writes the same marker the variants write, so its verdict is directly comparable.
build_control() {
	mkdir -p /tmp/drag-control.app/Contents/MacOS

	cat > /tmp/drag-control.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>control</string>
<key>CFBundleIdentifier</key><string>org.test.drag-launch-control</string>
<key>CFBundleName</key><string>control</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST

	cat > /tmp/drag-control.m <<'OBJC'
#import <AppKit/AppKit.h>

int main(void) {
	@autoreleasepool {
		FILE *file = fopen("/tmp/dragterm-selftest.log", "a");

		if (file != NULL) {
			fprintf(file, "pid %d: control entered main\n", getpid());
			fclose(file);
		}

		NSApplicationLoad();
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		[NSApp activate];

		for (int i = 0; i < 10; i++) {
			[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
		}
	}

	return 0;
}
OBJC

	DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}" 		cc -arch arm64 -fobjc-arc -framework AppKit -o /tmp/drag-control.app/Contents/MacOS/control 		/tmp/drag-control.m >/dev/null 2>&1 		&& codesign --force --sign - /tmp/drag-control.app >/dev/null 2>&1
}

if build_control; then
	report "control in /tmp" /tmp/drag-control.app
else
	echo "  control failed to build - ignore this line"
fi

rm -rf /tmp/drag-control.app /tmp/drag-control.m

reset_state
echo
echo "done - paste the whole table back"
