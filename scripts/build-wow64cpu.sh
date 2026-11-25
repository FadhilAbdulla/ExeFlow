#!/bin/bash
# Builds Wine's wow64cpu.dll with patches/wow64cpu-rosetta.patch (LGPL 2.1+).
# usage: build-wow64cpu.sh <output.dll> [--unpatched]     needs: brew install mingw-w64
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD; out=$1; mode=${2:-}
version=11.21
sha=5a40f593432d81fd3a1646db503f21ce42b8894d6d80c34c3a48b886edc54e3d
cache="$root/vendor/src"; mkdir -p "$cache" "$(dirname "$out")"
[ -f "$cache/wine-$version.tar.xz" ] || curl -fL "https://dl.winehq.org/wine/source/11.x/wine-$version.tar.xz" -o "$cache/wine-$version.tar.xz"
echo "$sha  $cache/wine-$version.tar.xz" | shasum -a 256 -c - >&2
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tar -xf "$cache/wine-$version.tar.xz" -C "$tmp" "wine-$version/dlls/wow64cpu" "wine-$version/include"
src="$tmp/wine-$version"
[ "$mode" = --unpatched ] || patch -s -d "$src" -p1 < patches/wow64cpu-rosetta.patch
# Drop the one debug message so Wine's debug library isn't needed.
sed -i '' '/ERR( "wow64cpu loaded above 4G/d' "$src/dlls/wow64cpu/cpu.c"
cc=x86_64-w64-mingw32
cat > "$tmp/ntdll.def" <<D
LIBRARY ntdll.dll
EXPORTS
LdrDisableThreadCalloutsForDll
LdrGetDllHandle
NtProtectVirtualMemory
RtlCaptureContext
RtlFindExportedRoutineByName
RtlIsProcessorFeaturePresent
RtlWow64GetThreadContext
RtlWow64SetThreadContext
memcpy
D
printf 'LIBRARY wow64.dll\nEXPORTS\nWow64SystemServiceEx\n' > "$tmp/wow64.def"
{ echo "LIBRARY wow64cpu.dll"; echo EXPORTS
  sed -nE 's/^@ stdcall (-norelay )?([A-Za-z_0-9]+)\(.*/\2/p' "$src/dlls/wow64cpu/wow64cpu.spec"; } > "$tmp/out.def"
for l in ntdll wow64; do $cc-dlltool -d "$tmp/$l.def" -l "$tmp/lib$l.a"; done
$cc-gcc -c -O2 -D__WINESRC__ -D__WINE_PE_BUILD -DWINE_NO_DEBUG_MSGS -D_NTSYSTEM_ -fno-stack-protector -fno-strict-aliasing \
  -mcmodel=small -ffreestanding -fno-builtin -nostdinc -isystem "$($cc-gcc -print-file-name=include)" \
  -I "$src/include" -I "$src/include/msvcrt" "$src/dlls/wow64cpu/cpu.c" -o "$tmp/cpu.o"
$cc-gcc -shared -nostdlib -nostartfiles -Wl,--image-base,0x7a400000 \
  -Wl,--entry,DllMain -s "$tmp/cpu.o" "$tmp/out.def" -L "$tmp" -lwow64 -lntdll -o "$tmp/out.dll"
# Wine only treats a DLL as its own when this marker follows the DOS header.
python3 -I - "$tmp/out.dll" <<'P'
import struct,sys
d=bytearray(open(sys.argv[1],'rb').read())
assert struct.unpack_from('<I',d,60)[0]>=0x60
d[0x40:0x60]=b'Wine builtin DLL'.ljust(32,b'\0')
open(sys.argv[1],'wb').write(d)
P
cp "$tmp/out.dll" "$out"
echo "Built $out" >&2
