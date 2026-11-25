#!/bin/bash
# usage: run.sh <wine folder> <scratch folder> [tests...]   Writes results to <scratch>/results.txt
here=$(cd "$(dirname "$0")"; pwd); wine=$1; s=$2; shift 2
tests=${*:-basic files registry threads seh memory child crypto fonts clipboard driver isolation https https-badcert audio gamepad-api rawinput modeset window-standard window-customframe window-borderless fullscreen opengl vulkan d3d9 d3d11-fl10_0 d3d11-fl11_0 d3d11-fl11_1 d3d12}
W() { env -i HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin WINEPREFIX="$s/prefix" WINEDEBUG=-all "$@"; }
for a in x86_64 i686; do [ -f "$here/compat-$a.exe" ] || { echo "build compat-$a.exe first" >&2; exit 2; }; done
ln -sfn "$here" "$s/prefix/dosdevices/d:"; ln -sfn "$wine/share/wine" "$s/prefix/dosdevices/y:"; rm -f "$s/prefix/dosdevices/z:"
cd "$here"; W "$wine/bin/wine" "D:\\compat-x86_64.exe" basic >/dev/null 2>&1
for t in $tests; do for a in x86_64 i686; do
  out=$(W perl -e 'alarm 60; exec @ARGV' "$wine/bin/wine" "D:\\compat-$a.exe" $t 2>/dev/null | tr -d '\r' | grep -aE 'PASS|FAIL' | tail -1)
  printf '%-20s %-7s %s\n' "$t" "$a" "${out:-CRASH/TIMEOUT}"
  [ -z "$out" ] && pkill -9 -f "D:.compat-$a" 2>/dev/null
done; done | tee "$s/results.txt"
W "$wine/bin/wineserver" -k
