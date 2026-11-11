#!/usr/bin/env bash
# Compiles every source except the app's entry point, plus the tests, into one executable and runs it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> macos-app/
OUT="$(mktemp -d)/tests"
SOURCES=()
for file in Sources/*.swift; do
  [ "$file" = "Sources/main.swift" ] || SOURCES+=("$file")
done
swiftc -o "$OUT" -target arm64-apple-macosx26.0 "${SOURCES[@]}" Tests/*.swift \
  -framework Cocoa -framework Security -framework ServiceManagement -framework CoreWLAN
"$OUT"
