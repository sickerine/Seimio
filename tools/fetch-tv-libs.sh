#!/bin/bash
# Copies the TV's own libraries that the native plugin links against into tvlibs/ (LG's builds; not in
# the repo). Needs the TV in developer mode with the SSH key at ~/.ssh/tv_key.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
TV=${TV_HOST:-192.168.1.37}
mkdir -p "$REPO/tvlibs"
ssh -i ~/.ssh/tv_key -p 9922 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o LogLevel=ERROR prisoner@$TV \
    'cd /usr/lib && tar chf - libQt5Core.so.5 libQt5Gui.so.5 libQt5Qml.so.5 libQt5Quick.so.5 libumedia_api.so.1 libwebos-platform-interface.so.1 libluna-service2.so.3 libglib-2.0.so.0' \
    | tar xf - -C "$REPO/tvlibs"
ls "$REPO/tvlibs"
