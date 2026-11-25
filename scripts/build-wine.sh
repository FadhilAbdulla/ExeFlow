#!/bin/bash
# Builds all of Wine from WineHQ source (Intel, 64- and 32-bit) with every patch, into vendor/wine-built.
# Host libraries (FreeType, GnuTLS, SDL, MoltenVK) still come from vendor/wine/lib. Media (GStreamer) is not built.
# needs: brew install mingw-w64 bison freetype gnutls sdl2; Xcode; Rosetta
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD; version=11.21; out="$root/vendor/wine-built"
sha=5a40f593432d81fd3a1646db503f21ce42b8894d6d80c34c3a48b886edc54e3d
src="$root/vendor/src/wine-$version.tar.xz"; mkdir -p vendor/src vendor/build
[ -f "$src" ] || curl -fL "https://dl.winehq.org/wine/source/11.x/wine-$version.tar.xz" -o "$src"
echo "$sha  $src" | shasum -a 256 -c - >&2
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACOSX_DEPLOYMENT_TARGET=10.15
export SDKROOT=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
export PATH="$(brew --prefix bison)/bin:$PATH"
cd vendor/build; rm -rf "wine-$version" obj; tar -xf "$src"
for p in "$root"/patches/*.patch; do patch -s -d "wine-$version" -p1 < "$p"; done
mkdir obj; cd obj; L="$root/vendor/wine/lib"
"../wine-$version/configure" --prefix=/ --build=x86_64-apple-darwin --enable-archs=x86_64,i386 CC="clang -arch x86_64" CFLAGS="-O2" CROSSCFLAGS="-O2" \
  --disable-tests --without-x --without-cups --without-gstreamer --without-ffmpeg \
  FREETYPE_CFLAGS="-I$(brew --prefix freetype)/include/freetype2" FREETYPE_LIBS="-L$L -lfreetype" \
  GNUTLS_CFLAGS="-I$(brew --prefix gnutls)/include" GNUTLS_LIBS="-L$L -lgnutls" \
  SDL2_CFLAGS="-I$(brew --prefix)/opt/sdl2/include/SDL2" SDL2_LIBS="-L$L -lSDL2" > configure.log 2>&1
# configure can't read library names from another vendor's dylibs, so set them to what is bundled.
so() { sed -i '' -E "s|^(/\* )?#(undef\|define) SONAME_$1( .*)?$|#define SONAME_$1 \"$2\"|" include/config.h; grep -q "SONAME_$1 \"$2\"" include/config.h; }
sed -i '' -E 's|^/\* #undef HAVE_SDL_H \*/|#define HAVE_SDL_H 1|' include/config.h
so LIBFREETYPE libfreetype.6.dylib; so LIBGNUTLS libgnutls.30.dylib; so LIBSDL2 libSDL2-2.0.0.dylib; so LIBVULKAN libMoltenVK.dylib # no loader, so no portability patch needed
ln -sf "$L"/*.dylib . # build tools load these by bare name
# A parallel job occasionally loses a race creating a folder; a retry continues where it stopped.
for try in 1 2 3; do make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 && break; done
make > make.log 2>&1 || { grep -E 'error' make.log | head -20 >&2; exit 1; }
rm -rf "$out"; make install DESTDIR="$out" > install.log 2>&1
for f in "$out"/lib/wine/x86_64-unix/*.so; do install_name_tool -add_rpath '@loader_path/../../' "$f" 2>/dev/null || true; codesign --force --sign - "$f"; done
for t in function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc; do rm -f "$out/bin/$t"; done
rm -rf "$out/include" "$out/share/man" "$out"/lib/wine/*-windows/*.a "$out"/lib/wine/x86_64-unix/*.a
echo "Built $out" >&2
