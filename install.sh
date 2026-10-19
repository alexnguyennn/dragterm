#!/bin/sh
# Build dragterm and install it as an app bundle plus a launcher at ~/.local/bin/drag.
#
# The bundle is not cosmetic: the main bundle is derived from the path the binary was exec'd
# by, and a bare executable is classified as NSApplicationActivationPolicyProhibited, which
# can never be activated and on current macOS is never even delivered a click. So the wrapper
# has to exec the path inside the bundle rather than symlink to it.
#
# Overridable: DEVELOPER_DIR, BINDIR, PREFIX.
set -eu

# Default to the toolchain this was developed against, but fall back to whatever xcode-select
# has picked, because other machines do not have that exact version installed.
default_developer_dir() {
	pinned="/Applications/Xcode-26.6.0.app/Contents/Developer"

	if [ -d "$pinned" ]; then
		echo "$pinned"
	else
		xcode-select -p
	fi
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(default_developer_dir)}"

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/build"
prefix="${PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/dragterm}"
bin="${BINDIR:-$HOME/.local/bin}"

xcodebuild -project "$root/dragterm.xcodeproj" -scheme dragterm -configuration Release \
	-destination 'platform=macOS,arch=arm64' -derivedDataPath "$build" \
	CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -quiet

binary="$build/Build/Products/Release/drag"

# Xcode's processed Info.plist already has the $(...) build settings substituted.
processed="$(find "$build/Build/Intermediates.noindex" -name Processed-Info.plist -print -quit)"

app="$prefix/drag.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$bin"
cp "$binary" "$app/Contents/MacOS/drag"
cp "$processed" "$app/Contents/Info.plist"

plutil -insert CFBundleExecutable -string drag "$app/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
# An agent bundle has no Dock tile. Dragging needs a regular bundle, but on the versions where
# dragging works the agent bundle has always been what ships, and clipboard mode does not care.
plutil -insert LSUIElement -bool yes "$app/Contents/Info.plist"

codesign --force --sign - --entitlements "$root/drag.entitlements" "$app"

# Unlink first: writing through a pre-existing symlink into the bundle would overwrite the
# real binary with the wrapper, leaving a script that execs itself forever.
rm -f "$bin/drag"
printf '#!/bin/sh\nexec "%s/Contents/MacOS/drag" "$@"\n' "$app" > "$bin/drag"
chmod +x "$bin/drag"

echo "installed $app"
echo "     -> $bin/drag"
