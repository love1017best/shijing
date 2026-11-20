#!/bin/zsh
# 有连接着的 iPhone / iPad 时，构建 iOS 版装上去并启动；一台都没连就什么也不做（退出码 0）。
# install-local.sh 每次结束时会调它，也可以单独跑。iOS 这边失败不影响 macOS 的安装结果，只打一行提示。
# 免费签名：团队 ID 在 ios/ShiJing/Local.xcconfig（gitignore），见 ios/README.md。
#
# 每次都构建（没改动时 1 秒左右，改过 Swift 约 11 秒，顺便验证 iOS 端能编过），
# 但只装「这台设备上还没有这份源码与签名构建出来的那一版」的：每台设备记下装上去的指纹
# （build/.install-stamps/<UDID>，包含源码和嵌入的描述文件），指纹一样就跳过安装。
# 上次没装成（设备锁屏、没信任这台电脑）的同一版也不再重试，免得每次卡在那里等超时；
# 解锁设备后加 --force 再装。
#
# 免费签名自动刷新：检查本机拾景描述文件（主 App 与小组件）的最早到期时间，
# 剩余不足 48 小时（可用 SHIJING_RENEW_BEFORE_HOURS 调整，设为 0 关闭）或传了 --refresh-signing 时，
# 会先备份再移除旧描述文件并清掉旧 .app，由 xcodebuild -allowProvisioningUpdates 向 Apple 重新拉取新 7 天签名；
# 拉取失败时自动恢复备份的旧描述文件，不丢失可用签名。
#
# 用法：scripts/install-ios-device.sh [--force] [--refresh-signing]
# 环境变量（install-ios.sh 用）：SHIJING_IOS_DIR 换一个 ios 目录来构建（比如某个 tag 的临时 worktree），
# SHIJING_DEVICE 只装名字里含这段文字的设备（不区分大小写），
# SHIJING_RENEW_BEFORE_HOURS 剩余少于多少小时时自动刷新签名（默认 48，0 关闭）。
set -uo pipefail
zmodload zsh/datetime # EPOCHREALTIME（计时用）

FORCE=0
REFRESH_SIGNING=0
while (( $# )); do
	case $1 in
	--force) FORCE=1; shift ;;
	--refresh-signing) REFRESH_SIGNING=1; FORCE=1; shift ;;
	-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "不认识的参数：$1（--help 看用法）"; exit 2 ;;
	esac
done

SCRIPTS=${0:A:h}
source "$SCRIPTS/common.zsh"
cd "${SHIJING_IOS_DIR:-$SCRIPTS/../../ios}" || exit 1
source "$SCRIPTS/lock.zsh"
[[ -d "$DEVELOPER_DIR" ]] || { echo "iOS：没找到 Xcode，跳过"; exit 0; }
BUNDLE_ID=com.love1017best.shijing.ios
RENEW_BEFORE_HOURS=${SHIJING_RENEW_BEFORE_HOURS:-48}

JSON=""
WORK=""
PROF_BACKUP=""
PROF_COMMITTED=0

restore_profiles() {
	[[ -n "$PROF_BACKUP" && -d "$PROF_BACKUP" && -f "$PROF_BACKUP/manifest.tsv" ]] || return 0
	local idx orig
	while IFS=$'\t' read -r idx orig; do
		[[ -n "$idx" && -f "$PROF_BACKUP/$idx" ]] && command cp -f "$PROF_BACKUP/$idx" "$orig"
	done <"$PROF_BACKUP/manifest.tsv"
}

cleanup() {
	if [[ -n "$PROF_BACKUP" && -d "$PROF_BACKUP" ]]; then
		if ((!PROF_COMMITTED)); then
			restore_profiles
		fi
		command rm -rf "$PROF_BACKUP"
	fi
	[[ -n "$JSON" ]] && command rm -f "$JSON"
	[[ -n "$WORK" ]] && command rm -rf "$WORK"
}
trap cleanup EXIT

# 检查本机缓存的拾景描述文件状态，输出四列（| 分隔，避免空字段在 IFS=TAB 下被合并）：
#   <匹配到的AppID数>|<最小剩余秒数>|<最早到期本地时间>|<匹配文件总数>
inspect_profiles() {
	python3 "$SCRIPTS/profiles.py" inspect "$BUNDLE_ID"
}

# 备份并移除本机所有拾景描述文件，记下原路径供失败时恢复
backup_and_remove_profiles() {
	python3 "$SCRIPTS/profiles.py" backup-remove "$BUNDLE_ID" "$1"
}

# 读取已构建 .app 里实际嵌入的描述文件信息，输出三列（| 分隔）：
#   <最早到期本地时间>|<剩余可读文本>|<嵌入描述文件内容指纹>
inspect_embedded_profiles() {
	python3 "$SCRIPTS/profiles.py" inspect-embedded "$1"
}

JSON=$(mktemp -t shijing-devices) || exit 0

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
	if ((REFRESH_SIGNING)); then
		if [[ -n "${SHIJING_DEVICE:-}" ]]; then echo "iOS：没有连着名字里含「$SHIJING_DEVICE」的 iPhone / iPad，未刷新签名"
		else echo "iOS：没有连接 iPhone / iPad，未刷新签名"; fi
		exit 1
	fi
	if [[ -n "${SHIJING_DEVICE:-}" ]]; then echo "iOS：没有连着名字里含「$SHIJING_DEVICE」的 iPhone / iPad，跳过"
	else echo "iOS：没有连接 iPhone / iPad，跳过"; fi
	exit 0
fi

# 构建产物和日志的位置：默认在 ios/build 里；install-ios.sh 在临时 worktree 里构建时，
# 用 SHIJING_DERIVED_DIR 复用工作区的派生数据（装得快）、用 SHIJING_LOG_DIR 把日志放到 worktree 外（worktree 装完就删了）
DERIVED=${SHIJING_DERIVED_DIR:-build}
LOG=${SHIJING_LOG_DIR:-$PWD}/install-device.log
STAMPS=$DERIVED/.install-stamps
APP="$DERIVED/Build/Products/Release-iphoneos/拾景.app"
mkdir -p "$DERIVED" "$STAMPS" "${LOG:h}" || exit 1

# 检查是否需要刷新免费签名描述文件
IFS='|' read -r OLD_APP_COUNT OLD_MIN_REM OLD_EXP_LOCAL OLD_FILE_COUNT <<<"$(inspect_profiles)"
DO_REFRESH=0
REFRESH_REASON=""
if ((REFRESH_SIGNING)); then
	DO_REFRESH=1
	REFRESH_REASON="手动要求"
elif [[ "$RENEW_BEFORE_HOURS" == <-> ]] && ((RENEW_BEFORE_HOURS > 0 && OLD_APP_COUNT > 0)); then
	if ((${OLD_MIN_REM:-0} <= 0)); then
		DO_REFRESH=1
		REFRESH_REASON="已过期"
	elif ((${OLD_MIN_REM:-0} < RENEW_BEFORE_HOURS * 3600)); then
		DO_REFRESH=1
		REFRESH_REASON="即将到期（$OLD_EXP_LOCAL）"
	fi
fi

if ((DO_REFRESH)); then
	if ((OLD_FILE_COUNT > 0)); then
		PROF_BACKUP=$(mktemp -d -t shijing-prof-backup) || exit 1
		backup_and_remove_profiles "$PROF_BACKUP"
	fi
	# 删掉旧 .app，确保新拉下来的描述文件被完整重新嵌入并重签
	command rm -rf "$APP"
	echo "iOS：刷新免费签名（$REFRESH_REASON）…"
fi

run_xcodebuild() {
	xcodebuild -project ShiJing.xcodeproj -scheme ShiJing -configuration Release -destination 'generic/platform=iOS' \
		-derivedDataPath "$DERIVED" -allowProvisioningUpdates build -quiet >"$LOG" 2>&1
}

build_error_hint() {
	if grep -q "No Accounts" "$LOG" 2>/dev/null; then
		echo "Xcode 未登录 Apple 账号，请打开 Xcode → Settings → Accounts 登录后再试"
	else
		grep -m1 "error:" "$LOG" 2>/dev/null | sed 's/^.*error: //'
	fi
}

# 装 Release：代码优化过、去掉了调试符号和演示代码（Debug 版 6 MB 多，Release 2 MB 左右）
t0=$EPOCHREALTIME
BUILD_OK=0
if run_xcodebuild; then
	BUILD_OK=1
else
	# 删掉旧描述文件后首次 xcodebuild -allowProvisioningUpdates 偶发构建图 UUID 竞态报错
	# （Build input file cannot be found），但新描述文件此时已拉取落盘；检查到新文件后重试一次即可通过
	if ((DO_REFRESH || OLD_APP_COUNT == 0)); then
		IFS='|' read -r NEW_APP_COUNT NEW_MIN_REM NEW_EXP_LOCAL NEW_FILE_COUNT <<<"$(inspect_profiles)"
		MIN_NEED=$((OLD_APP_COUNT > 0 ? OLD_APP_COUNT : 1))
		if ((NEW_APP_COUNT >= MIN_NEED && ${NEW_MIN_REM:-0} > 0)); then
			if run_xcodebuild; then
				BUILD_OK=1
			fi
		fi
	fi
fi

if ((BUILD_OK)); then
	PROF_COMMITTED=1
else
	HINT=$(build_error_hint)
	# 自动临期刷新失败且旧描述文件仍未过期时，恢复旧文件并继续构建，不阻断正常开发和发版
	if ((DO_REFRESH && !REFRESH_SIGNING && OLD_APP_COUNT > 0 && ${OLD_MIN_REM:-0} > 0)); then
		restore_profiles
		PROF_COMMITTED=1
		echo "iOS：自动刷新签名失败（${HINT:-见日志 $LOG}），继续使用现有描述文件（有效期至 $OLD_EXP_LOCAL）"
		if run_xcodebuild; then
			BUILD_OK=1
		fi
	fi
fi

if ((!BUILD_OK)); then
	echo "iOS：构建失败，没有安装（日志：$LOG）"
	if [[ -n "${HINT:-}" ]]; then
		echo "  $HINT"
	else
		grep -m3 "error" "$LOG"
	fi
	exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
IFS='|' read -r EMB_EXP_LOCAL EMB_REM_TEXT EMB_FP <<<"$(inspect_embedded_profiles "$APP")"
# 这份安装包的指纹：iOS 目录里所有源文件的内容哈希 + 嵌入描述文件的内容哈希（跳过构建产物和日志）。
# 源码和签名都没变就不必再往手机上装一遍——同一份源码重新编译出的 .app 未必逐字节一样，所以不直接哈希 .app；
# 一旦刷新了描述文件，嵌入的描述文件哈希变化，已连着或之后插上的设备都会自动更新签名。
SRC_HASH=$(find . \( -name build -o -name build-sim -o -name DerivedData -o -name .git -o -name xcuserdata -o -name install-device.log \) -prune -o -type f -print0 |
	xargs -0 shasum -a 256 | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1)
HASH=$(printf '%s\n%s\n' "$SRC_HASH" "$EMB_FP" | shasum -a 256 | cut -d' ' -f1)
if [[ -n "$EMB_EXP_LOCAL" ]]; then
	printf 'iOS 构建：%.1f 秒（%s），签名有效期至 %s（%s）\n' $((EPOCHREALTIME - t0)) "${HASH[1,8]}" "$EMB_EXP_LOCAL" "$EMB_REM_TEXT"
else
	printf 'iOS 构建：%.1f 秒（%s）\n' $((EPOCHREALTIME - t0)) "${HASH[1,8]}"
fi

WORK=$(mktemp -d -t shijing-install) || exit 1
t0=$EPOCHREALTIME
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
			printf '\n=== devicectl install 失败：%s (%s) ===\n%s\n' "$NAME" "$UDID" "$OUT" >"$WORK/$i.log"
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
	[[ -f "$WORK/$n.log" ]] && cat "$WORK/$n.log" >>"$LOG"
	cat "$WORK/$n.out" 2>/dev/null
	[[ -f "$WORK/$n.state" && "$(<"$WORK/$n.state")" == fail ]] && STATUS=1
done
printf 'iOS 装到设备：%.1f 秒\n' $((EPOCHREALTIME - t0))
exit $STATUS
