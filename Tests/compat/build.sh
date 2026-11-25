#!/bin/bash
# Builds the Windows-side test programs. Needs mingw-w64.
set -euo pipefail
cd "$(dirname "$0")"
for a in x86_64 i686; do
  $a-w64-mingw32-gcc -O1 -w -static compat.c -o compat-$a.exe -ld3d9 -ld3d11 -ldxgi -ldxguid -lwinhttp -lwinmm -lgdi32 -luser32 -ladvapi32 -lbcrypt -lole32
done
