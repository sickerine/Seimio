# Seimio for Android TV: the same QML (app/) and data code (native/src, Stremio's core) as the LG build, in
# Qt 6. What only the LG has comes from stand-ins: Android's own window and player (android/imports, over mpv:
# android/mpv.h) and, for what has none yet, the Mac previews' (tools/preview/imports). Build: android/build.sh.
cmake_minimum_required(VERSION 3.21)
project(seimio LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
set(REPO ${CMAKE_CURRENT_SOURCE_DIR}/..)
set(MPV ${CMAKE_BINARY_DIR}/libmpv)
find_package(Qt6 REQUIRED COMPONENTS Quick Qml Network OpenGL)

# Qt's TLS on Android is OpenSSL, which the app carries (KDAB's builds, as Qt's docs say)
include(FetchContent)
FetchContent_Declare(android_openssl GIT_REPOSITORY https://github.com/KDAB/android_openssl GIT_TAG master GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(android_openssl)
include(${android_openssl_SOURCE_DIR}/android_openssl.cmake)

qt_add_executable(seimio main.cpp mpv.h ${REPO}/native/src/data_plugin.cpp
    ${REPO}/native/src/catalog.h ${REPO}/native/src/franchise.h ${REPO}/native/src/live.h ${REPO}/native/src/streams.h
    ${REPO}/native/src/tracks.h ${REPO}/native/src/skip.h ${REPO}/native/src/core.h ${REPO}/native/src/account.h
    ${REPO}/native/src/party.h ${REPO}/native/src/websocket.h)
set_source_files_properties(${REPO}/native/src/data_plugin.cpp PROPERTIES COMPILE_DEFINITIONS QT_STATICPLUGIN)
target_include_directories(seimio PRIVATE ${REPO}/native/src ${MPV}/include)
# the player: libmpv and its FFmpeg (jdtech's Android build, which android/build.sh fetches into MPV)
set(MPV_LIBS mpv avcodec avformat avutil avfilter avdevice swresample swscale)
list(TRANSFORM MPV_LIBS REPLACE "(.+)" "${MPV}/jni/armeabi-v7a/lib\\1.so" OUTPUT_VARIABLE MPV_SO)
target_link_libraries(seimio PRIVATE Qt6::Quick Qt6::Qml Qt6::Network Qt6::OpenGL ${MPV}/jni/armeabi-v7a/libmpv.so ${MPV}/jni/armeabi-v7a/libavcodec.so
    ${REPO}/core/target/armv7-linux-androideabi/release/libseimio_core.a log)
set_property(TARGET seimio APPEND PROPERTY QT_ANDROID_EXTRA_LIBS ${MPV_SO})

# the QML as resources, as android/stage.py puts them together: the app under :/app (its shaders compiled), the
# modules standing in for the LG's under :/imports
set(STAGE ${CMAKE_BINARY_DIR}/stage)
file(GLOB_RECURSE APP ${STAGE}/app/*)
file(GLOB_RECURSE IMPORTS ${STAGE}/imports/*)
qt_add_resources(seimio app PREFIX / BASE ${STAGE} FILES ${APP})
qt_add_resources(seimio imports PREFIX /imports BASE ${STAGE}/imports FILES ${IMPORTS})

# the manifest (a TV app: the leanback launcher, no touch screen) and the icon, which is also the TV's banner
set(PACKAGE ${CMAKE_BINARY_DIR}/package)
configure_file(AndroidManifest.xml ${PACKAGE}/AndroidManifest.xml COPYONLY)
configure_file(${REPO}/app/icon-large.png ${PACKAGE}/res/drawable/icon.png COPYONLY)
set_target_properties(seimio PROPERTIES QT_ANDROID_PACKAGE_SOURCE_DIR ${PACKAGE}
    QT_ANDROID_PACKAGE_NAME com.seimio.tv QT_ANDROID_APP_NAME Seimio
    QT_ANDROID_TARGET_SDK_VERSION 36 QT_ANDROID_MIN_SDK_VERSION 28)
add_android_openssl_libraries(seimio)
