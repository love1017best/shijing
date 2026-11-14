#!/bin/zsh
# 有连接着的 iPhone / iPad 时，构建 iOS 版装上去并启动；一台都没连就什么也不做（退出码 0）。
# install-local.sh 每次结束时会调它，也可以单独跑。iOS 这边失败不影响 macOS 的安装结果，只打一行提示。
# 免费签名：团队 ID 在 ios/ShiJing/Local.xcconfig（gitignore），见 ios/README.md。
#
# 每次都构建（没改动时 1 秒左右，改过 Swift 约 11 秒，顺便验证 iOS 端能编过），
# 但只装「这台设备上还没有这份源码构建出来的那一版」的：每台设备记下装上去的是哪份源码
# （build/.install-stamps/<UDID>），源码指纹一样就跳过安装。
# 上次没装成（设备锁屏、没信任这台电脑）的同一版也不再重试，免得每次卡在那里等超时；
# 解锁设备后加 --force 再装。
#
# 用法：scripts/install-ios-device.sh [--force]
# 环境变量（install-ios.sh 用）：SHIJING_IOS_DIR 换一个 ios 目录来构建（比如某个 tag 的临时 worktree），
# SHIJING_DEVICE 只装名字里含这段文字的设备（不区分大小写）。
set -uo pipefail
zmodload zsh/datetime # EPOCHREALTIME（计时用）

FORCE=0
[[ " $* " == *" --force "* ]] && FORCE=1

SCRIPTS=${0:A:h}
cd "${SHIJING_IOS_DIR:-$SCRIPTS/../../ios}" || exit 1
source "$SCRIPTS/lock.zsh"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || { echo "iOS：没找到 Xcode，跳过"; exit 0; }
BUNDLE_ID=com.love1017best.shijing.ios
JSON=$(mktemp -t shijing-devices) || exit 0
trap 'command rm -f "$JSON"' EXIT

xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || { echo "iOS：列不出设备，跳过"; exit 0; }
# 真机（不是模拟器）、iPhone 或 iPad、配对过的；每行「udid<TAB>名字」。
# 不能看 tunnelState：没在装东西时真机一直是 disconnected（要用时才建隧道），按它过滤会把连着的设备全跳过（踩过）。
DEVICES=$(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn = d["hardwareProperties"], d["connectionProperties"]
    name = d["deviceProperties"].get("name", hw["udid"])
    if sys.argv[2].lower() not in name.lower():
        continue
    if hw.get("reality") != "physical" or hw.get("deviceType") not in ("iPhone", "iPad"):
        continue
    if conn.get("pairingState") != "paired" or conn.get("transportType") not in ("wired", "localNetwork"):
        continue
    print(hw["udid"] + "\t" + name)
' "$JSON" "${SHIJING_DEVICE:-}")
if [[ -z "$DEVICES" ]]; then
	if [[ -n "${SHIJING_DEVICE:-}" ]]; then echo "iOS：没有连着名字里含「$SHIJING_DEVICE」的 iPhone / iPad，跳过"
	else echo "iOS：没有连接 iPhone / iPad，跳过"; fi
	exit 0
fi

# 构建产物和日志的位置：默认在 ios/build 里；install-ios.sh 在临时 worktree 里构建时，
# 用 SHIJING_DERIVED_DIR 复用工作区的派生数据（装得快）、用 SHIJING_LOG_DIR 把日志放到 worktree 外（worktree 装完就删了）
DERIVED=${SHIJING_DERIVED_DIR:-build}
LOG=${SHIJING_LOG_DIR:-$PWD}/install-device.log
STAMPS=$DERIVED/.install-stamps
mkdir -p "$DERIVED" "$STAMPS" "${LOG:h}" || exit 1
# 装 Release：代码优化过、去掉了调试符号和演示代码（Debug 版 6 MB 多，Release 2 MB 左右）
t0=$EPOCHREALTIME
if ! xcodebuild -project ShiJing.xcodeproj -scheme ShiJing -configuration Release -destination 'generic/platform=iOS' \
	-derivedDataPath "$DERIVED" -allowProvisioningUpdates build -quiet >"$LOG" 2>&1; then
	echo "iOS：构建失败，没有安装（日志：$LOG）"
	grep -m3 "error" "$LOG"
	exit 1
fi
APP="$DERIVED/Build/Products/Release-iphoneos/拾景.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
# 这份源码的指纹：iOS 目录里所有源文件的内容哈希（跳过构建产物和日志）。
# 源码没变就不必再往手机上装一遍——这也是「同一版重复构建出来的包内容未必逐字节一样」的原因，
# 所以用源码而不是构建出来的 .app 来比。版本号、签名配置都在里面，发布升版本时自然会对不上。
HASH=$(find . \( -name build -o -name build-sim -o -name DerivedData -o -name .git -o -name xcuserdata -o -name install-device.log \) -prune -o -type f -print0 |
	xargs -0 shasum -a 256 | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1)
printf 'iOS 构建：%.1f 秒（%s）\n' $((EPOCHREALTIME - t0)) "${HASH[1,8]}"

WORK=$(mktemp -d -t shijing-install) || exit 1
trap 'command rm -f "$JSON"; command rm -rf "$WORK"' EXIT
i=0
while IFS=$'\t' read -r UDID NAME; do
	i=$((i + 1))
	if ((!FORCE)) && [[ -f "$STAMPS/$UDID" && "$(<"$STAMPS/$UDID")" == "$HASH" ]]; then
		echo "iOS：「$NAME」上已经是这一版，跳过安装" >"$WORK/$i.out"
		continue
	fi
	if ((!FORCE)) && [[ -f "$STAMPS/$UDID.failed" && "$(<"$STAMPS/$UDID.failed")" == "$HASH" ]]; then
		echo "iOS：「$NAME」上次没装成（设备锁屏或没信任这台电脑？），这一版不再重试；解锁后再跑一次，或加 --force" >"$WORK/$i.out"
		echo skip >"$WORK/$i.state"
		continue
	fi
	# 几台设备并行装：插着多台时总时间看最慢的那台，而不是加起来
	(
		# 装和启动分开：设备锁屏时装得进去、只是启动不起来，那就记为已安装，下次不用再等一遍
		if ! OUT=$(xcrun devicectl device install app --device "$UDID" "$APP" 2>&1); then
			echo "$HASH" >"$STAMPS/$UDID.failed"
			echo "iOS：装到「$NAME」失败（没连上或没信任这台电脑？日志：$LOG）"
			print -r -- "$OUT" | grep -iE "unable|could not|error|locked" | tail -2 | sed 's/^/  /'
			echo fail >"$WORK/$i.state"
		elif ! OUT=$(xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1); then
			echo "$HASH" >"$STAMPS/$UDID"
			command rm -f "$STAMPS/$UDID.failed"
			echo "iOS：已安装 v$VERSION 到「$NAME」，设备锁屏没能启动"
			echo ok >"$WORK/$i.state"
		else
			echo "$HASH" >"$STAMPS/$UDID"
			command rm -f "$STAMPS/$UDID.failed"
			echo "iOS：已安装 v$VERSION 到「$NAME」并启动"
			echo ok >"$WORK/$i.state"
		fi
	) >"$WORK/$i.out" 2>&1 &
done <<<"$DEVICES"
wait
STATUS=0
for ((n = 1; n <= i; n++)); do
	cat "$WORK/$n.out" 2>/dev/null
	[[ -f "$WORK/$n.state" && "$(<"$WORK/$n.state")" == fail ]] && STATUS=1
done
printf 'iOS 装到设备：%.1f 秒\n' $((EPOCHREALTIME - t0))
exit $STATUS
