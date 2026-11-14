#!/bin/zsh
# 构建 arm64 版，装到 /Applications（替换旧版）并启动。
# 用法：scripts/install-local.sh            # 构建后安装
#       scripts/install-local.sh --no-build # 直接安装已有的 dmg（发布时刚构建过；没有 dmg 时装构建目录里的 .app）
#       加 --no-ios 不管手机；默认连着 iPhone / iPad 时也构建 iOS 版装上去（scripts/install-ios-device.sh）
#       加 --force 手机上的那一版也重新装（平时手机上已经是最新构建时会跳过）
# 通用版（darwin/universal）只在发布时构建，这个脚本不管。
#
# 本地预览不建 dmg：mygo build -skip-dmg 直接给出 .app，省掉打包、挂载这两步。
# 用 --no-build 时（发布脚本）装的是发布构建好的 dmg，和发布包保持一致。
set -euo pipefail
zmodload zsh/datetime # EPOCHREALTIME（计时用）

cd "${0:A:h}/.."
source scripts/lock.zsh
BUNDLE_ID=com.love1017best.shijing
APP=/Applications/拾景.app
VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' mygo.json | head -1)
BUILT=build/darwin-arm64/拾景.app
DMG=build/darwin-arm64/shi-jing-$VERSION-arm64.dmg
TOTAL=$EPOCHREALTIME
NO_BUILD=0 NO_IOS=0
FORCE_ARG=""
for arg in "$@"; do
	case $arg in
	--no-build) NO_BUILD=1 ;;
	--force) FORCE_ARG=--force ;;
	--no-ios) NO_IOS=1 ;;
	esac
done

SRC_DMG="" # 非空时从 dmg 装，否则直接拷贝构建出来的 .app
if ((NO_BUILD)); then
	if [[ -f "$DMG" ]]; then SRC_DMG=$DMG; fi
	[[ -n "$SRC_DMG" || -d "$BUILT" ]] || { echo "找不到 $DMG 或 $BUILT"; exit 1; }
else
	t0=$EPOCHREALTIME
	mkdir -p build && go tool mygo build -skip-notarize -skip-dmg >build/install-local.log 2>&1 || { tail -20 build/install-local.log; exit 1; }
	printf '构建 macOS 版：%.1f 秒\n' $((EPOCHREALTIME - t0))
fi
[[ -d "$BUILT" || -n "$SRC_DMG" ]] || { echo "找不到 $BUILT"; exit 1; }

t0=$EPOCHREALTIME
# 先正常退出旧版（关窗只是隐藏，要用 quit），等它真正退出
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..20}; do
	lsappinfo info -only pid -app "$BUNDLE_ID" 2>/dev/null | grep -q '[0-9]' || break
	sleep 0.25
done

MNT=""
if [[ -n "$SRC_DMG" ]]; then
	MNT=$(hdiutil attach -nobrowse -readonly "$SRC_DMG" 2>/dev/null | grep -o '/Volumes/.*' | head -1)
	[[ -n "$MNT" ]] || { echo "挂载 $SRC_DMG 失败"; exit 1; }
	trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
	command rm -rf "$APP"
	ditto "$MNT/拾景.app" "$APP"
else
	command rm -rf "$APP"
	ditto "$BUILT" "$APP"
fi
# 用稳定的本地证书重签：ad-hoc 每次构建指纹都变，macOS 的「访问网络卷」授权每次都要重给，
# 手机上远程删原图时还得跑到电脑前点（见 scripts/sign-app.sh）。dmg 本身不动。
scripts/sign-app.sh "$APP" || true

open "$APP"
sleep 1
INSTALLED=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
RUNNING=$(lsappinfo info -only bundlepath -app "$BUNDLE_ID" 2>/dev/null | sed -n 's/.*="\(.*\)"/\1/p')
printf '安装并启动：%.1f 秒\n' $((EPOCHREALTIME - t0))
echo "已安装 v$INSTALLED → $APP，正在运行：${RUNNING:-未检测到}"
OK=0
[[ "$INSTALLED" == "$VERSION" && "$RUNNING" == "$APP" ]] || OK=1

# 连着 iPhone / iPad 时顺手把 iOS 版也装上（没连就跳过；手机上已经是最新构建的会跳过安装；
# 失败只提示，不影响上面 macOS 的结果）
if ((!NO_IOS)); then
	t0=$EPOCHREALTIME
	scripts/install-ios-device.sh ${FORCE_ARG:+"$FORCE_ARG"} || true
	printf 'iOS 这一头：%.1f 秒\n' $((EPOCHREALTIME - t0))
fi
printf '总共：%.1f 秒\n' $((EPOCHREALTIME - TOTAL))
exit $OK
