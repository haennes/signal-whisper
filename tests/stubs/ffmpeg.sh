#!/usr/bin/env bash
# Test stub for ffmpeg: writes the output file (last argument) untouched.
last=""
for a in "$@"; do
  last="$a"
done
mkdir -p "$(dirname "$last")"
printf 'RIFFstubwav' > "$last"
exit 0
