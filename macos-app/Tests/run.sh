#!/usr/bin/env bash
# Compiles every source except the app's entry point, plus the tests, into one executable and runs it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> macos-app/
# One work folder holds the test binary and its preferences, and goes away however the run ends.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AIMETERBAR_TEST_DIR="$WORK"
OUT="${WORK}/tests"
SOURCES=()
for file in Sources/*.swift; do
  [ "$file" = "Sources/main.swift" ] || SOURCES+=("$file")
done
swiftc -o "$OUT" -target arm64-apple-macosx26.0 "${SOURCES[@]}" Tests/*.swift \
  -framework Cocoa -framework Security -framework ServiceManagement -framework CoreWLAN
"$OUT"
