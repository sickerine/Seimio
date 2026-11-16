#!/bin/bash
# Builds the TV's QML plugins (Qt 5.12, 32-bit ARM webOS) into native/out/: Seimio.Native (Luna, the
# media server player, libass, window properties, lab probes) and Seimio.Data (catalog.h and streams.h, plain Qt).
# Step 1 (Ubuntu 20.04): Qt 5.12 armhf headers (incl. private ones for the platform interface) and the
# Qt 5.12 moc. Step 2 (Debian): compile with the webOS toolchain, linked against the TV's own libraries
# (tools/fetch-tv-libs.sh copies them into tvlibs/) and libass (third_party/libass/build.sh).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
docker run --rm -e DEBIAN_FRONTEND=noninteractive -v "$HERE":/work -w /work ubuntu:focal bash -euc '
  if [ ! -d qt512/usr/include/arm-linux-gnueabihf/qt5/QtGui/5.12.8 ]; then
    dpkg --add-architecture armhf && apt-get update -qq >/dev/null
    mkdir -p /tmp/deb qt512 && cd /tmp/deb && apt-get download -qq qtbase5-dev:armhf qtdeclarative5-dev:armhf qtbase5-private-dev:armhf >/dev/null
    for d in *.deb; do dpkg -x $d /work/qt512; done; cd /work
  fi
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends qtbase5-dev-tools >/dev/null
  Q=qt512/usr/include/arm-linux-gnueabihf/qt5
  mkdir -p out/moc
  for h in src/*.h; do grep -q Q_OBJECT $h && /usr/lib/qt5/bin/moc -I$Q -I$Q/QtCore -I$Q/QtGui -I$Q/QtQml -I$Q/QtQuick -I$Q/QtNetwork $h -o out/moc/moc_$(basename $h .h).cpp; done
  /usr/lib/qt5/bin/moc -I$Q -I$Q/QtCore -I$Q/QtQml src/plugin.cpp -o out/moc/plugin.moc
  /usr/lib/qt5/bin/moc -I$Q -I$Q/QtCore -I$Q/QtQml src/data_plugin.cpp -o out/moc/data_plugin.moc
'
docker run --rm -v ~/Library/Caches/webos-sdk:/sdk -v "$REPO":/repo -w /repo/native debian:bookworm bash -euc '
  T=/sdk/arm-webos-linux-gnueabi_sdk-buildroot; export PATH=$T/bin:$PATH
  S=$(arm-webos-linux-gnueabi-gcc -print-sysroot)
  Q=qt512/usr/include/arm-linux-gnueabihf/qt5
  arm-webos-linux-gnueabi-g++ -std=c++17 -O2 -fPIC -shared -o out/libseimionative.so src/plugin.cpp $(ls out/moc/moc_*.cpp | grep -v -e moc_catalog -e moc_streams) \
    -Isrc -Iout/moc -I$Q -I$Q/QtCore -I$Q/QtGui -I$Q/QtQml -I$Q/QtQuick -I$Q/QtGui/5.12.8 -I$Q/QtGui/5.12.8/QtGui -I$Q/QtCore/5.12.8 -I$Q/QtCore/5.12.8/QtCore \
    -I/repo/third_party/libass/out/include -I$S/usr/include/glib-2.0 -I$S/usr/lib/glib-2.0/include \
    -DQT_NO_DEBUG -DQT_PLUGIN -DQT_QML_LIB -DQT_QUICK_LIB -DQT_GUI_LIB -DQT_CORE_LIB \
    -L/repo/tvlibs -l:libQt5Quick.so.5 -l:libQt5Qml.so.5 -l:libQt5Gui.so.5 -l:libQt5Core.so.5 -l:libumedia_api.so.1 -l:libwebos-platform-interface.so.1 -l:libluna-service2.so.3 -l:libglib-2.0.so.0 \
    -L/repo/third_party/libass/out/lib -lass -Wl,-rpath,\$ORIGIN -Wl,--allow-shlib-undefined
  arm-webos-linux-gnueabi-g++ -std=c++17 -O2 -fPIC -shared -o out/libseimiodata.so src/data_plugin.cpp out/moc/moc_catalog.cpp out/moc/moc_streams.cpp \
    -Isrc -Iout/moc -I$Q -I$Q/QtCore -I$Q/QtGui -I$Q/QtQml -I$Q/QtNetwork \
    -DQT_NO_DEBUG -DQT_PLUGIN -DQT_QML_LIB -DQT_NETWORK_LIB -DQT_CORE_LIB \
    -L/repo/tvlibs -l:libQt5Qml.so.5 -l:libQt5Network.so.5 -l:libQt5Core.so.5 -lpthread -Wl,--allow-shlib-undefined
  cp src/qmldir out/
  cp /repo/third_party/libass/out/lib/libass.so.9.*.* out/libass.so.9
  arm-webos-linux-gnueabi-readelf -d out/libseimionative.so | grep -c NEEDED
'
