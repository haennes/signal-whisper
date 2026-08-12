#!/usr/bin/env bash
# Test stub for whisper-cpp: writes the -of output file with fixed text.
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -of) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'hallo welt' > "${out}.txt"
exit 0
