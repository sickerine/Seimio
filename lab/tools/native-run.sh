#!/bin/bash
# usage: native-run.sh <cdn-url-file> <seek_ms> [wait_s]
D=$(cd "$(dirname "$0")" && pwd)
perl -pe 'BEGIN{open F,"<'"$1"'"; $u=<F>; chomp $u} s/\@URL\@/$u/; s/\@SEEK\@/'"$2"'/' $D/native-Win.qml.in > $D/qmlluna/Win.qml
$D/deploy.sh qmlluna lab.luna.qml ${3:-30} luna | cut -c1-1500
