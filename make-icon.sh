#!/bin/bash
# 重建应用图标：Tools/IconGen.swift → AppIcon.iconset → AppIcon.icns
# 改完图标设计后运行本脚本，再跑 ./build.sh 打包。
set -e
cd "$(dirname "$0")"

echo "==> 编译图标生成器"
mkdir -p build/tools
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Tools/IconGen.swift -o build/tools/icongen

echo "==> 渲染各尺寸"
rm -rf AppIcon.iconset
./build/tools/icongen AppIcon.iconset

echo "==> 打包 .icns"
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "==> 完成: $(pwd)/AppIcon.icns"
