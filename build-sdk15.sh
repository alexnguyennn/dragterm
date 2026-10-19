#!/bin/sh
# Build drag against an older macOS SDK and install it as `drag-sdk15`.
#
# Why: AppKit switches behaviour on the SDK version recorded in LC_BUILD_VERSION, not on the
# deployment target. Our binary is linked against the 26.5 SDK, and on macOS 26 a drag
# started by an application that is not the active application is never negotiated with a
# destination: no highlight, and the mouse up is delivered to whoever is active. A process
# exec'd from a terminal cannot become the active application on macOS 26 (measured: policy
# Regular, effective policy Regular, -[NSApplication activate] refused, TransformProcessType
# -50, frontmost stays the terminal), so under those rules a terminal-launched drag can never
# land.
#
# Linking against the 15.x SDK asks AppKit for the pre-26 semantics instead. This script
# exists to test that in isolation: same sources, same bundle, same signature, only the
# recorded SDK differs.
#
# Usage: ./build-sdk15.sh [sdk-path]
set -eu

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"

sdk="${1:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
root="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/dragterm}"
bin="${BINDIR:-$HOME/.local/bin}"
out="$root/build-sdk15"

[ -d "$sdk" ] || {
	echo "no SDK at $sdk" >&2
	echo "available: $(ls "$(dirname "$sdk")" | tr '\n' ' ')" >&2
	exit 1
}

app="$prefix/drag-sdk15.app"

rm -rf "$out" "$app"
mkdir -p "$out" "$app/Contents/MacOS" "$bin"

# Compiled directly with clang rather than through xcodebuild: two files, no build settings
# worth keeping, and xcodebuild will not take an SDK outside the toolchain.
# shellcheck disable=SC2086
cc -arch arm64 -fobjc-arc -fmodules -O2 -g \
	-isysroot "$sdk" -mmacosx-version-min=11.0 \
	-framework Cocoa \
	-o "$out/drag" "$root/dragterm/main.m" "$root/dragterm/DTDraggingSourceView.m"

# Reuse the Info.plist the real install produced, so the bundles differ in nothing but the
# binary. It has to move with the binary, since the activation policy is read from LSUIElement.
cp "$prefix/drag-regular.app/Contents/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.derailer.dragterm.sdk15 "$app/Contents/Info.plist"
cp "$out/drag" "$app/Contents/MacOS/drag"

codesign --force --sign - --entitlements "$root/drag.entitlements" "$app"

printf '#!/bin/sh\nexec "%s/Contents/MacOS/drag" "$@"\n' "$app" > "$bin/drag-sdk15"
chmod +x "$bin/drag-sdk15"

echo "installed $app"
echo "     -> $bin/drag-sdk15"
echo "recorded build version:"
otool -l "$app/Contents/MacOS/drag" | grep -A4 LC_BUILD_VERSION | sed -n 's/^ *//p' | grep -E '^(minos|sdk)'
