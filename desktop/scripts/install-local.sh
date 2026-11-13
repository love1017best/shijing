#!/bin/zsh
# 构建 arm64 dmg，用 dmg 安装到 /Applications（替换旧版）并启动。
# 用法：scripts/install-local.sh            # 构建后安装
#       scripts/install-local.sh --no-build # 直接安装已有的 dmg（比如发布时刚构建过）
#       加 --no-ios 不管手机；默认连着 iPhone / iPad 时也构建 iOS 版装上去（scripts/install-ios-device.sh）
# 通用版（darwin/universal）只在发布时构建，这个脚本不管。
set -euo pipefail

cd "${0:A:h}/.."
source scripts/lock.zsh
BUNDLE_ID=com.love1017best.shijing
APP=/Applications/拾景.app
VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' mygo.json | head -1)
DMG=build/darwin-arm64/shi-jing-$VERSION-arm64.dmg

if [[ " $* " != *" --no-build "* ]]; then
	mkdir -p build && go tool mygo build -skip-notarize >build/install-local.log 2>&1 || { tail -20 build/install-local.log; exit 1; }
fi
[[ -f "$DMG" ]] || { echo "找不到 $DMG"; exit 1; }

# 先正常退出旧版（关窗只是隐藏，要用 quit），等它真正退出
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do
	lsappinfo info -only pid -app "$BUNDLE_ID" 2>/dev/null | grep -q '[0-9]' || break
	sleep 0.25
done

MNT=$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | grep -o '/Volumes/.*' | head -1)
[[ -n "$MNT" ]] || { echo "挂载 $DMG 失败"; exit 1; }
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
command rm -rf "$APP"
ditto "$MNT/拾景.app" "$APP"
# 用稳定的本地证书重签：ad-hoc 每次构建指纹都变，macOS 的「访问网络卷」授权每次都要重给，
# 手机上远程删原图时还得跑到电脑前点（见 scripts/sign-app.sh）。dmg 本身不动。
scripts/sign-app.sh "$APP" || true

open "$APP"
sleep 1
INSTALLED=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
RUNNING=$(lsappinfo info -only bundlepath -app "$BUNDLE_ID" 2>/dev/null | sed -n 's/.*="\(.*\)"/\1/p')
echo "已安装 v$INSTALLED → $APP，正在运行：${RUNNING:-未检测到}"
OK=0
[[ "$INSTALLED" == "$VERSION" && "$RUNNING" == "$APP" ]] || OK=1

# 连着 iPhone / iPad 时顺手把 iOS 版也装上（没连就跳过；失败只提示，不影响上面 macOS 的结果）
if [[ " $* " != *" --no-ios "* ]]; then
	scripts/install-ios-device.sh || true
fi
exit $OK
