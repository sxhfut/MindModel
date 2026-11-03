#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="build/MindModel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> 编译"
swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  Sources/Probe.swift Sources/Catalog.swift Sources/GGUF.swift Sources/Advisor.swift \
  Sources/Agent.swift Sources/App.swift Sources/Views.swift \
  -o "$APP/Contents/MacOS/MindModel"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "（跳过签名）"

echo "==> 完成: $(pwd)/$APP"
