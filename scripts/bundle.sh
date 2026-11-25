#!/bin/bash
# Builds an ad-hoc signed app for local use in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
unset SDKROOT # a stale SDKROOT can mix incompatible SDKs
if pgrep -f "$PWD/${OUT:-dist}/ExeFlow.app/Contents" >/dev/null; then echo "error: quit ExeFlow and its Windows programs first" >&2; exit 1; fi
scripts/fetch-wine.sh
swift build -c release
app="${OUT:-dist}/ExeFlow.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ExeFlow" "$app/Contents/MacOS/"
cp Support/Info.plist "$app/Contents/"
ditto vendor/wine "$app/Contents/Resources/wine"
# Without this patch many 32-bit programs crash under Rosetta (WineHQ bug 60494).
dll=vendor/wow64cpu.dll
if [ ! -f "$dll" ] || [ patches/wow64cpu-rosetta.patch -nt "$dll" ] || [ scripts/build-wow64cpu.sh -nt "$dll" ]; then
  scripts/build-wow64cpu.sh "$dll"
fi
cp "$dll" "$app/Contents/Resources/wine/lib/wine/x86_64-windows/wow64cpu.dll"
# Without this patch multi-window programs can deadlock.
so=vendor/winemac.so
if [ ! -f "$so" ] || [ patches/winemac-deadlock.patch -nt "$so" ] || [ scripts/build-winemac.sh -nt "$so" ]; then
  scripts/build-winemac.sh "$so"
fi
cp "$so" "$app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so"
cp patches/*.patch "$app/Contents/Resources/wine/"
echo "Modified by ExeFlow: wow64cpu.dll and winemac.so, see the .patch files." >> "$app/Contents/Resources/wine/NOTICE.txt"
loader="$app/Contents/Resources/wine/lib/wine/x86_64-unix/wine"
python3 -I scripts/brand-loader.py "$loader" ExeFlow
codesign --force --preserve-metadata=entitlements --sign - "$loader"
icons=$(mktemp -d); trap 'rm -rf "$icons"' EXIT
logo=(); [ -f Support/Logo.png ] && logo=(Support/Logo.png)
swift scripts/make-icon.swift "$icons/AppIcon.iconset" ${logo[@]+"${logo[@]}"}
iconutil -c icns "$icons/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "Built $app"
