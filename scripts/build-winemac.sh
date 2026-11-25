#!/bin/bash
# Builds Wine's winemac.so (Intel) with patches/winemac-deadlock.patch (LGPL 2.1+).
# usage: build-winemac.sh <output.so>     needs: brew install mingw-w64 bison freetype; Xcode; Rosetta
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD; out=$1; version=11.21
case "$out" in /*) ;; *) out="$root/$out";; esac
sha=5a40f593432d81fd3a1646db503f21ce42b8894d6d80c34c3a48b886edc54e3d
src="$root/vendor/src/wine-$version.tar.xz"; mkdir -p vendor/src
[ -f "$src" ] || curl -fL "https://dl.winehq.org/wine/source/11.x/wine-$version.tar.xz" -o "$src"
echo "$sha  $src" | shasum -a 256 -c - >&2
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACOSX_DEPLOYMENT_TARGET=10.15
export SDKROOT=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
export PATH="$(brew --prefix bison)/bin:$PATH"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tar -xf "$src" -C "$tmp"
patch -s -d "$tmp/wine-$version" -p1 < patches/winemac-deadlock.patch
mkdir "$tmp/obj"; cd "$tmp/obj"
"../wine-$version/configure" --build=x86_64-apple-darwin --enable-archs=x86_64,i386 CC="clang -arch x86_64" CFLAGS="-g -O2" \
  --disable-tests --without-gnutls --without-gstreamer --without-sdl --without-cups --without-x \
  FREETYPE_CFLAGS="-I$(brew --prefix freetype)/include/freetype2" FREETYPE_LIBS="-L$root/vendor/wine/lib -lfreetype" > configure.log 2>&1
make -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so > make.log 2>&1 || { grep error: make.log >&2; exit 1; }
so=dlls/winemac.drv/winemac.so
nm "$so" | grep -q try_get_win_data # the patch is really in this build
install_name_tool -add_rpath '@loader_path/../../' "$so"
codesign --force --sign - "$so"
cp "$so" "$out"
echo "Built $out" >&2
