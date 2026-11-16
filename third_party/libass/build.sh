#!/bin/bash
# Builds libass (with static FriBidi and HarfBuzz inside it) and asstest for the TV (32-bit ARM webOS)
# inside an arm64 Debian container. FreeType and Fontconfig come from the TV.
# usage: lab/libass/build.sh   (needs ~/Library/Caches/webos-sdk/arm-webos-sdk.tar.gz)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SDK=~/Library/Caches/webos-sdk
docker run --rm -v "$SDK":/sdk -v "$HERE":/work -w /work debian:bookworm bash -euc '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends make pkg-config xz-utils curl ca-certificates file python3 meson ninja-build gcc libc6-dev >/dev/null
  if [ ! -d /sdk/arm-webos-linux-gnueabi_sdk-buildroot ]; then tar xzf /sdk/arm-webos-sdk.tar.gz -C /sdk; fi
  T=/sdk/arm-webos-linux-gnueabi_sdk-buildroot; [ -f $T/.relocated ] || { $T/relocate-sdk.sh >/dev/null; touch $T/.relocated; }
  export PATH=$T/bin:$PATH
  S=$(arm-webos-linux-gnueabi-gcc -print-sysroot)
  P=/work/build/prefix
  export PKG_CONFIG_SYSROOT_DIR=$S PKG_CONFIG_LIBDIR=$S/usr/lib/pkgconfig:$S/usr/share/pkgconfig
  export PKG_CONFIG_PATH=$P/lib/pkgconfig
  mkdir -p build out
  cat > build/cross.ini <<EOT
[binaries]
c = '"'"'arm-webos-linux-gnueabi-gcc'"'"'
cpp = '"'"'arm-webos-linux-gnueabi-g++'"'"'
ar = '"'"'arm-webos-linux-gnueabi-ar'"'"'
strip = '"'"'arm-webos-linux-gnueabi-strip'"'"'
pkg-config = '"'"'pkg-config'"'"'
[host_machine]
system = '"'"'linux'"'"'
cpu_family = '"'"'arm'"'"'
cpu = '"'"'armv7'"'"'
endian = '"'"'little'"'"'
EOT
  get() { [ -d build/$2 ] || curl -sSL "$1" | tar xJ -C build; }
  get https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz fribidi-1.0.18
  get https://github.com/harfbuzz/harfbuzz/releases/download/15.1.0/harfbuzz-15.1.0.tar.xz harfbuzz-15.1.0
  get https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz libass-0.17.5
  M="--cross-file build/cross.ini --prefix=$P --libdir=lib --default-library=static -Db_staticpic=true --buildtype=release"
  if [ ! -f $P/lib/libfribidi.a ]; then meson setup build/fb build/fribidi-1.0.18 $M -Ddocs=false -Dbin=false -Dtests=false >/dev/null && ninja -C build/fb install >/dev/null; fi
  if [ ! -f $P/lib/libharfbuzz.a ]; then meson setup build/hb build/harfbuzz-15.1.0 $M -Dfreetype=disabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled >/dev/null && ninja -C build/hb install >/dev/null; fi
  cd build/libass-0.17.5
  ./configure -q --host=arm-webos-linux-gnueabi --prefix=/work/out --disable-static --disable-asm --disable-fontconfig --disable-require-system-font-provider LIBS=-lstdc++ FRIBIDI_CFLAGS="-I$P/include/fribidi" FRIBIDI_LIBS="-L$P/lib -lfribidi" HARFBUZZ_CFLAGS="-I$P/include/harfbuzz" HARFBUZZ_LIBS="-L$P/lib -lharfbuzz" >/dev/null
  make -s -j$(nproc) >/dev/null && make -s install >/dev/null
  cd /work
  arm-webos-linux-gnueabi-gcc -O2 -o out/asstest asstest.c -Iout/include -Lout/lib -lass
  file out/asstest out/lib/libass.so.9.*.* | sed "s|/work/||"
  arm-webos-linux-gnueabi-readelf -d out/lib/libass.so | grep NEEDED
'
