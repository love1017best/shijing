#!/bin/zsh
# 有连接着的 iPhone / iPad 时，构建 iOS 版装上去并启动；一台都没连就什么也不做（退出码 0）。
# install-local.sh 每次结束时会调它，也可以单独跑。iOS 这边失败不影响 macOS 的安装结果，只打一行提示。
# 免费签名：团队 ID 在 ios/ShiJing/Local.xcconfig（gitignore），见 ios/README.md。
set -uo pipefail

cd "${0:A:h}/../../ios"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || { echo "iOS：没找到 Xcode，跳过"; exit 0; }
BUNDLE_ID=com.love1017best.shijing.ios
JSON=$(mktemp -t shijing-devices) || exit 0
trap 'command rm -f "$JSON"' EXIT

xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || { echo "iOS：列不出设备，跳过"; exit 0; }
# 真机（不是模拟器）、iPhone 或 iPad、现在连着的；每行「udid<TAB>名字」
DEVICES=$(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn = d["hardwareProperties"], d["connectionProperties"]
    if hw.get("reality") == "physical" and hw.get("deviceType") in ("iPhone", "iPad") and conn.get("tunnelState") == "connected":
        print(hw["udid"] + "\t" + d["deviceProperties"].get("name", hw["udid"]))
' "$JSON")
[[ -n "$DEVICES" ]] || { echo "iOS：没有连接 iPhone / iPad，跳过"; exit 0; }

LOG=build/install-device.log
mkdir -p build
if ! xcodebuild -project ShiJing.xcodeproj -scheme ShiJing -destination 'generic/platform=iOS' \
	-derivedDataPath build -allowProvisioningUpdates build -quiet >"$LOG" 2>&1; then
	echo "iOS：构建失败，没有安装（日志：ios/$LOG）"
	grep -m3 "error" "$LOG"
	exit 1
fi
APP=build/Build/Products/Debug-iphoneos/拾景.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
STATUS=0
while IFS=$'\t' read -r UDID NAME; do
	if xcrun devicectl device install app --device "$UDID" "$APP" >>"$LOG" 2>&1 &&
		xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >>"$LOG" 2>&1; then
		echo "iOS：已安装 v$VERSION 到「$NAME」并启动"
	else
		echo "iOS：装到「$NAME」失败（设备锁屏或没信任这台电脑？日志：ios/$LOG）"
		STATUS=1
	fi
done <<<"$DEVICES"
exit $STATUS
