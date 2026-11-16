#!/bin/bash
# usage: rate.sh runs ms "<experiment>"... -> late frames per animated second for each run
runs=$1; ms=$2; shift 2
for n in "$@"; do
  line=""
  for r in $(seq 1 $runs); do
    f="r-$(echo "$n" | tr -cd 'a-z0-9')-$r.json"
    node diag.mjs "$n" "$f" "$ms" >/dev/null
    v=$(python3 diag.py "$f" | grep "^animated" | awk '{print $6"/"$10}')
    line="$line  $v"
  done
  printf '%-52s late>20ms/late>30ms per s:%s\n' "$n" "$line"
done
