#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

command -v swift >/dev/null 2>&1 || {
  echo "Swift/Xcode Command Line Tools are required." >&2
  exit 1
}

command -v rustup >/dev/null 2>&1 || {
  echo "rustup is required to build the x86_64 macOS helper." >&2
  exit 1
}

rustup target add x86_64-apple-darwin
cargo build --release --target x86_64-apple-darwin --bin lsfg-control
swift build --package-path control -c release

APP="dist/LSFG Metal Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp control/.build/release/LSFGMetalControl "$APP/Contents/MacOS/LSFGMetalControl"
cp target/x86_64-apple-darwin/release/lsfg-control "$APP/Contents/Resources/lsfg-control"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>LSFGMetalControl</string>
    <key>CFBundleIdentifier</key><string>com.lsfgmetal.control</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>LSFG Metal Control</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

echo "built $APP"
