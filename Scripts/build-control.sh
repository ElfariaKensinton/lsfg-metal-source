#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

command -v swift >/dev/null 2>&1 || {
  echo "Swift/Xcode Command Line Tools are required." >&2
  exit 1
}

swift build --package-path control -c release

mkdir -p dist/tools
cp control/.build/release/LSFGMetalControl dist/tools/LSFGMetalControl
codesign -s - -f dist/tools/LSFGMetalControl

echo "built dist/tools/LSFGMetalControl"
