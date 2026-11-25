#!/bin/bash
# Downloads the pinned Wine build into vendor/. Never executes it.
set -euo pipefail
cd "$(dirname "$0")/.."
version=11.21
sha=9909b486657e10ab66c7279371ae1f990345b596b3b1b3a0cf21f28af24fa0ce
[ "$(cat vendor/wine/.version 2>/dev/null || true)" = "$version" ] && exit 0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fL "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$version/wine-devel-$version-osx64.tar.xz" -o "$tmp/wine.tar.xz"
echo "$sha  $tmp/wine.tar.xz" | shasum -a 256 -c -
mkdir "$tmp/x"; tar -xf "$tmp/wine.tar.xz" -C "$tmp/x"
curl -fsSL "https://gitlab.winehq.org/wine/wine/-/raw/wine-$version/COPYING.LIB" -o "$tmp/COPYING.LIB"
grep -q "GNU LESSER GENERAL PUBLIC LICENSE" "$tmp/COPYING.LIB"
rm -rf vendor/wine; mkdir -p vendor
mv "$tmp/x/Wine Devel.app/Contents/Resources/wine" vendor/wine
mv "$tmp/COPYING.LIB" vendor/wine/
cat > vendor/wine/NOTICE.txt <<N
Wine $version, LGPL 2.1 or later. Build: https://github.com/Gcenx/macOS_Wine_builds
Source: https://gitlab.winehq.org/wine/wine/-/tree/wine-$version
Bundled third-party libraries carry their own licenses.
N
echo "$version" > vendor/wine/.version
