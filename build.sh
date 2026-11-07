#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="build/MindModel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# 转成二进制 plist：CFBundle 只认 XML/二进制两种格式，JSON 写的 Info.plist
# 会让系统读不到 CFBundleIdentifier / CFBundleIconFile（签名时 Identifier 退化成哈希、
# 图标退回通用占位图），而且在 plutil 里看着一切正常，极难排查。
plutil -convert binary1 "$APP/Contents/Info.plist"

echo "==> 图标"
# 图标由 Tools/IconGen.swift 生成：改设计后跑 ./make-icon.sh 重建 AppIcon.icns
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "（缺 AppIcon.icns，先运行 ./make-icon.sh）"
fi

echo "==> 编译"
swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  Sources/Probe.swift Sources/Catalog.swift Sources/GGUF.swift Sources/Advisor.swift \
  Sources/Agent.swift Sources/HFSearch.swift Sources/MSDownload.swift Sources/App.swift Sources/Views.swift \
  Sources/ModelNameDecoder.swift Sources/ModelNameViews.swift Sources/OnlineFit.swift \
  Sources/AboutView.swift \
  -o "$APP/Contents/MacOS/MindModel"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "（跳过签名）"

echo "==> 完成: $(pwd)/$APP"
