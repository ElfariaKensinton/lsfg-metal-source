#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

command -v swift >/dev/null 2>&1 || {
  echo "Swift/Xcode Command Line Tools are required." >&2
  exit 1
}

swift build --package-path hud -c release

mkdir -p dist/tools
cp hud/.build/release/LSFGMetalHUD dist/tools/LSFGMetalHUD
codesign -s - -f dist/tools/LSFGMetalHUD

echo "built dist/tools/LSFGMetalHUD"
