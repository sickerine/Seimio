#!/bin/bash
# The plugins may only need what the TV's own libraries have. The toolchain's C++ runtime is newer than
# the TV's: a destructor that calls something that can throw made the compiler ask for
# __cxa_call_terminate@CXXABI_1.3.15, which the TV's libstdc++ (6.0.32) doesn't have, so the plugin failed
# to load and the app died at launch without a word (main.qml imports the plugin's folder).
# usage, inside the build container: check-symbols.sh plugin.so...   (tvlibs/ holds the TV's libraries)
set -euo pipefail
export LC_ALL=C
NM=arm-webos-linux-gnueabi-nm
have=$(mktemp)
# (__tls_get_addr is the dynamic loader's own, which tvlibs/ doesn't hold)
{ $NM -D --defined-only /repo/tvlibs/*.so* 2>/dev/null | awk '{print $NF}' | sed 's/@@/@/'; echo "__tls_get_addr@GLIBC_2.4"; } | sort -u > "$have"
bad=0
for so in "$@"; do
  missing=$($NM -D -u "$so" | awk '{print $NF}' | grep -E '@(GLIBCXX|CXXABI|GLIBC)_' | sort -u | comm -23 - "$have" || true)
  if [ -n "$missing" ]; then echo "$so needs symbols the TV does not have:"; echo "$missing" | sed 's/^/  /'; bad=1; fi
done
exit $bad
