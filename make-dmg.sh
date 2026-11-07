#!/bin/bash
# 生成可分发的 macOS DMG。
# 只依赖系统自带的 hdiutil / ditto / PlistBuddy，不需要第三方 create-dmg。
#
#   ./make-dmg.sh                 # 用现有 build/MindModel.app 打包（不存在则先 ./build.sh）
#   ./make-dmg.sh --rebuild       # 强制先重新编译再打包
#   OUT=/path/to/x.dmg ./make-dmg.sh   # 自定义输出路径
#
# 产物默认 build/MindModel-<版本>.dmg；build/ 已被 .gitignore 忽略，
# 安装包属于构建产物，不入库（脚本本身入库，保证可复现）。

set -euo pipefail
cd "$(dirname "$0")"

APP="build/MindModel.app"

if [[ ! -d "$APP" || "${1:-}" == "--rebuild" ]]; then
    echo "==> 编译应用"
    ./build.sh
fi

if [[ ! -d "$APP" ]]; then
    echo "错误：找不到 ${APP}，请先运行 ./build.sh" >&2
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
MIN_MAC=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST" 2>/dev/null || echo "14.0")
ARCH=$(file -b "$APP/Contents/MacOS/MindModel" | sed -n 's/.*executable \([^ ]*\).*/\1/p')
OUT="${OUT:-build/MindModel-${VERSION}.dmg}"
mkdir -p "$(dirname "$OUT")"

STAGE=$(mktemp -d /tmp/mm-dmg.XXXXXX)
CREATE_LOG=$(mktemp /tmp/mm-dmg-create.XXXXXX.log)
cleanup() {
    # 万一挂载没卸干净，收尾时再卸一次，别把 /Volumes 弄脏
    if [[ -n "${MNT:-}" && -d "${MNT:-}" ]]; then
        hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE" "$CREATE_LOG"
}
trap cleanup EXIT

# 变量一律用 ${} 包裹：macOS 自带 bash 3.2 会把紧跟在 $VAR 后面的全角标点
# （如「$ARCH，」）误判成变量名的一部分，在 set -u 下直接报 unbound variable。
echo "==> 准备卷内容（版本 ${VERSION} (${BUILD_NUM})，架构 ${ARCH}，最低 macOS ${MIN_MAC}）"
ditto "$APP" "$STAGE/MindModel.app"
ln -s /Applications "$STAGE/Applications"

# 安装说明随包走：架构限制与签名状态必须写清楚，不能让用户装完才发现跑不起来
cat > "$STAGE/安装说明.txt" <<EOF
MindModel ${VERSION} (${BUILD_NUM}) — 本机大模型选型顾问

【安装】
把 MindModel 拖进旁边的 Applications（应用程序）文件夹即可，不需要安装器。

【运行要求】
· macOS ${MIN_MAC} 或更高
· Apple Silicon（M 系列）Mac —— 本包内是可执行文件 ${ARCH} 架构，Intel Mac 无法运行
· 本包仅含应用，不含任何模型权重；模型由你自己在 Ollama / LM Studio 中安装

【首次打开提示「无法验证开发者」时】
本包是 ad-hoc 签名、未做 Apple 公证（没有 Developer ID 证书）。
在 Finder 里右键点 MindModel →「打开」→「打开」，一次即可；
或在终端执行：
    xattr -dr com.apple.quarantine /Applications/MindModel.app
若要对实验室外部正式分发，需要 Apple Developer ID 签名 + notarization 公证后再重新打包。

【它会联网吗】
硬件体检、预算、速度估算、能力分、推荐全部在本机计算，不上传任何本机数据；
只有你在「在线模型」页主动搜索或下载模型时才会联网。

【出品与联系】
合肥工业大学 · 多模态情感计算与人因工程实验室（由孙晓教授带领）
邮箱：sunx@hfut.edu.cn
主页：https://sxhfut.github.io/
项目：https://github.com/sxhfut/MindModel
许可：Apache-2.0
Copyright 2026 多模态情感计算与人因工程团队
EOF

# Finder 生成的垃圾不要带进镜像
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true
find "$STAGE" -name '._*' -delete 2>/dev/null || true

echo "==> 生成 DMG（UDZO 压缩只读 / HFS+）"
# 新版 macOS 的 hdiutil 会对 -volname/-format 组合打「已弃用」提示（功能仍正常），
# 收进日志里；只有真正失败时才把它打印出来，避免噪声盖住结果。
if ! hdiutil create \
    -volname "MindModel ${VERSION}" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$OUT" >"$CREATE_LOG" 2>&1; then
    cat "$CREATE_LOG" >&2
    exit 1
fi
echo "    已生成：${OUT}"

echo "==> 校验镜像"
hdiutil verify "$OUT" 2>&1 | tail -3

# 挂载后逐项确认内容真的在卷里，而不是只看 hdiutil 说成功
MNT=$(mktemp -d /tmp/mm-mnt.XXXXXX)
rmdir "$MNT"
if hdiutil attach "$OUT" -mountpoint "$MNT" -nobrowse -quiet >/dev/null 2>&1; then
    for f in "MindModel.app/Contents/MacOS/MindModel" \
             "MindModel.app/Contents/Info.plist" \
             "MindModel.app/Contents/Resources/AppIcon.icns" \
             "Applications" "安装说明.txt"; do
        if [[ ! -e "$MNT/$f" && ! -L "$MNT/$f" ]]; then
            echo "错误：卷里缺 $f" >&2
            hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
            exit 1
        fi
    done
    IDENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$MNT/MindModel.app/Contents/Info.plist")
    ICON=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$MNT/MindModel.app/Contents/Info.plist")
    echo "    卷内核验通过：Identifier=${IDENT}  Icon=${ICON}  文件齐全"
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
    MNT=""
else
    echo "    警告：本环境不允许挂载 DMG，跳过卷内核验；已做 hdiutil verify" >&2
    MNT=""
fi

echo ""
echo "==> 完成：$(pwd)/${OUT}"
ls -lh "$OUT" | awk '{print "    体积 " $5}'
shasum -a 256 "$OUT" | awk '{print "    SHA-256 " $1}'
