#!/bin/bash
# Builds Stremio's core for the TV (armv7, glibc, soft-float ABI) as a static library, which native/build.sh
# links into the data plugin. The Mac's build is plain `cargo build --release` (tools/preview/build-data.sh).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
docker run --rm -v ~/Library/Caches/webos-sdk:/sdk -v "$HERE":/work -v webos-cargo:/usr/local/cargo/registry -w /work rust:bookworm bash -euc '
  rustup target add armv7-unknown-linux-gnueabi >/dev/null 2>&1
  export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_LINKER=/sdk/arm-webos-linux-gnueabi_sdk-buildroot/bin/arm-webos-linux-gnueabi-gcc
  export CC_armv7_unknown_linux_gnueabi=/sdk/arm-webos-linux-gnueabi_sdk-buildroot/bin/arm-webos-linux-gnueabi-gcc
  export AR_armv7_unknown_linux_gnueabi=/sdk/arm-webos-linux-gnueabi_sdk-buildroot/bin/arm-webos-linux-gnueabi-ar
  cargo build --release --lib --target armv7-unknown-linux-gnueabi 2>&1 | grep -E "^(error|warning: unused)|^ *--> |Finished" | head -40
  ls -la target/armv7-unknown-linux-gnueabi/release/libseimio_core.a
'
