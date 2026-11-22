#!/bin/bash
# Builds Seimio for Android TV (32-bit ARM: the TCL's only ABI) into .lab/android/, and with `install`
# puts it on the TV and opens it. Fetches libmpv once. Needs Qt 6 for Android (with qtshadertools and qtimageformats) and the Mac in ~/Qt (aqtinstall), the SDK and NDK
# in ~/Library/Android/sdk, JDK 21 and the core's Rust target (`rustup target add armv7-linux-androideabi`).
# usage: android/build.sh [install]
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
QT=~/Qt/6.12.1; export ANDROID_HOME=~/Library/Android/sdk; NDK=$ANDROID_HOME/ndk/30.0.16248370
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
TC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
export CC_armv7_linux_androideabi=$TC/armv7a-linux-androideabi28-clang AR_armv7_linux_androideabi=$TC/llvm-ar
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER=$TC/armv7a-linux-androideabi28-clang
(cd core && cargo build --release --lib --target armv7-linux-androideabi 2>&1 | grep -E "^error|^ *--> " | head -20) || true
[ -f core/target/armv7-linux-androideabi/release/libseimio_core.a ] || { echo "the core didn't build"; exit 1; }
B=.lab/android
# libmpv: jdtech's Android build (Maven Central), and mpv's headers of the version it is built from
MPV_BUILD=1.1.0; MPV_TAG=v0.42.0; M=$B/libmpv
if [ ! -f $M/$MPV_BUILD ]; then
  mkdir -p $M/include/mpv
  curl -fsSL -A seimio-build https://repo1.maven.org/maven2/dev/jdtech/mpv/libmpv/$MPV_BUILD/libmpv-$MPV_BUILD.aar -o $M/libmpv.aar
  unzip -oq $M/libmpv.aar 'jni/armeabi-v7a/*' -d $M
  for h in client render render_gl; do curl -fsSL -A seimio-build https://raw.githubusercontent.com/mpv-player/mpv/$MPV_TAG/include/mpv/$h.h -o $M/include/mpv/$h.h; done
  touch $M/$MPV_BUILD
fi
python3 -I android/stage.py "$REPO" $B/stage "$QT/macos/bin/qsb" "$(ipconfig getifaddr en0)"
"$QT/android_armv7/bin/qt-cmake" -S android -B $B -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DQT_HOST_PATH="$QT/macos" -DANDROID_SDK_ROOT="$ANDROID_HOME" -DANDROID_NDK_ROOT="$NDK" >/dev/null
cmake --build $B --target apk 2>&1 | grep -E "error|warning: unused|FAILED" | head -40 || true
UNSIGNED=$B/android-build/build/outputs/apk/release/android-build-release-unsigned.apk
[ -f "$UNSIGNED" ] || { echo "no apk"; exit 1; }
# signed with the SDK's usual debug key, made once in ~/.android
KS=~/.android/debug.keystore; BT=$ANDROID_HOME/build-tools/36.0.0; APK=$B/seimio.apk
[ -f $KS ] || "$JAVA_HOME/bin/keytool" -genkeypair -keystore $KS -storepass android -keypass android -alias androiddebugkey \
  -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
"$BT/zipalign" -f -p 4 "$UNSIGNED" $APK && "$BT/apksigner" sign --ks $KS --ks-pass pass:android $APK
echo "built $APK"
if [ "${1:-}" = install ]; then
  "$ANDROID_HOME/platform-tools/adb" install -r "$APK" && "$ANDROID_HOME/platform-tools/adb" shell am start -n com.seimio.tv/org.qtproject.qt.android.bindings.QtActivity
fi
