#!/bin/bash
# Builds the Lab.Native QML plugin for the TV (Qt 5.12, 32-bit ARM webOS).
# Step 1 (Ubuntu 20.04): Qt 5.12 armhf headers and Qt 5.12 moc. Step 2 (Debian): webOS toolchain compile,
# linked against the TV's own libraries copied into lab/tvlibs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LAB=$(cd "$HERE/.." && pwd)
docker run --rm -e DEBIAN_FRONTEND=noninteractive -v "$HERE":/work -w /work ubuntu:focal bash -euc '
  if [ ! -d qt512/usr/include/arm-linux-gnueabihf/qt5/QtGui/5.12.8 ]; then
    dpkg --add-architecture armhf && apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends qtbase5-dev-tools >/dev/null
    mkdir -p /tmp/deb qt512 && cd /tmp/deb && apt-get download -qq qtbase5-dev:armhf qtdeclarative5-dev:armhf qtbase5-private-dev:armhf >/dev/null
    for d in *.deb; do dpkg -x $d /work/qt512; done; cd /work
  else
    apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends qtbase5-dev-tools >/dev/null
  fi
  Q=qt512/usr/include/arm-linux-gnueabihf/qt5
  /usr/lib/qt5/bin/moc -I$Q -I$Q/QtCore -I$Q/QtGui -I$Q/QtQml -I$Q/QtQuick plugin/plugin.cpp -o plugin/plugin.moc
'
docker run --rm -v ~/Library/Caches/webos-sdk:/sdk -v "$LAB":/lab -w /lab/native debian:bookworm bash -euc '
  T=/sdk/arm-webos-linux-gnueabi_sdk-buildroot; export PATH=$T/bin:$PATH
  S=$(arm-webos-linux-gnueabi-gcc -print-sysroot)
  Q=qt512/usr/include/arm-linux-gnueabihf/qt5
  mkdir -p out
  arm-webos-linux-gnueabi-g++ -std=c++14 -O2 -fPIC -shared -o out/liblabnative.so plugin/plugin.cpp \
    -Iplugin -I$Q -I$Q/QtCore -I$Q/QtGui -I$Q/QtQml -DQT_GUI_LIB -I$Q/QtGui/5.12.8 -I$Q/QtGui/5.12.8/QtGui -I$Q/QtCore/5.12.8 -I$Q/QtCore/5.12.8/QtCore -I$Q/QtQuick -I/lab/libass/out/include -DQT_QUICK_LIB -I$S/usr/include/glib-2.0 -I$S/usr/lib/glib-2.0/include \
    -DQT_NO_DEBUG -DQT_PLUGIN -DQT_QML_LIB -DQT_CORE_LIB \
    -L/lab/tvlibs -l:libQt5Quick.so.5 -l:libQt5Qml.so.5 -l:libQt5Gui.so.5 -l:libQt5Core.so.5 -l:libumedia_api.so.1 -l:libwebos-platform-interface.so.1 -l:libluna-service2.so.3 -l:libglib-2.0.so.0 -L/lab/libass/out/lib -lass -Wl,-rpath,\$ORIGIN -Wl,--allow-shlib-undefined
  cp plugin/qmldir out/
  arm-webos-linux-gnueabi-readelf -d out/liblabnative.so | grep NEEDED
'
