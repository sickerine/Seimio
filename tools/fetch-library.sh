#!/bin/bash
# The Stremio account's stand-in until the app signs in: the Stremio core's continue-watching list and
# library state (cw.out.json, library_recent.json), copied as they are from the core probe's newest run on the
# TV into app/stremio/. Everything else the app shows it fetches live (native/src/live.h).
# usage: tools/fetch-library.sh
REPO=$(cd "$(dirname "$0")/.." && pwd); mkdir -p "$REPO/app/stremio"
SSH="ssh -i $HOME/.ssh/tv_key -p 9922 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o LogLevel=ERROR prisoner@192.168.1.37"
run=$($SSH 'ls -td /media/developer/temp/core/run* | head -1') || exit 1
for f in cw.out.json library_recent.json; do $SSH "cat $run/$f" > "$REPO/app/stremio/$f" || exit 1; done
echo "copied $run/{cw.out.json,library_recent.json} into app/stremio/"
