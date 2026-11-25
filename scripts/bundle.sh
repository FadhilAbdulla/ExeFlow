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
# Wine is built from source; only host libraries, Mono and Gecko come from the downloaded build.
newest=$(ls -t patches/*.patch scripts/build-wine.sh | head -1)
if [ ! -x vendor/wine-built/bin/wine ] || [ "$newest" -nt vendor/wine-built/bin/wine ]; then scripts/build-wine.sh; fi
wine="$app/Contents/Resources/wine"
ditto vendor/wine-built "$wine"
cp vendor/wine/lib/*.dylib "$wine/lib/"
for d in mono gecko; do ditto "vendor/wine/share/wine/$d" "$wine/share/wine/$d"; done
# Wine upgrades an environment when this file's date changes. Same Wine version, so keep the date:
# the upgrade stalls in environments that have Microsoft .NET.
touch -r vendor/wine/share/wine/wine.inf "$wine/share/wine/wine.inf"
cp vendor/wine/COPYING.LIB patches/*.patch "$wine/"
cat > "$wine/NOTICE.txt" <<N
Wine 11.21, LGPL 2.1 or later, built from https://dl.winehq.org/wine/source/11.x/wine-11.21.tar.xz
with the .patch files in this folder. Libraries in lib/, Wine Mono and Wine Gecko come from
https://github.com/Gcenx/macOS_Wine_builds and carry their own licenses.
N
loader="$app/Contents/Resources/wine/lib/wine/x86_64-unix/wine"
python3 -I scripts/brand-loader.py "$loader" ExeFlow
codesign --force --preserve-metadata=entitlements --sign - "$loader"
icons=$(mktemp -d); trap 'rm -rf "$icons"' EXIT
logo=(); [ -f Support/Logo.png ] && logo=(Support/Logo.png)
swift scripts/make-icon.swift "$icons/AppIcon.iconset" ${logo[@]+"${logo[@]}"}
iconutil -c icns "$icons/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "Built $app"
