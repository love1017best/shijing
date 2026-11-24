#!/bin/zsh
# 发布一个新版本（macOS 和 iOS 两端一起，见 CLAUDE.md「版本号规则」「发布规则」）。两个会话都用它，不要手动走发布步骤。
#
# 用法：scripts/release.sh --macos "这一版 macOS 的改动（Markdown 列表）" --ios "iOS 的改动"
#       某一端没改就不传那一项，说明里写「无改动，仅同步版本号」。
#       --dry-run 走一遍全部检查和构建，但不推送、不建 Release、不安装（验证脚本用）。
#       --version 0.4.0 直接发成这个版本（不是 Z 加 1）。只在用户明确要求某个版本号时用，
#       大版本 X.Y 只在用户要求时改；要比当前版本大。
#       --ios-note "…" 替换 iOS 一节末尾的验证说明（默认按有没有连着手机自动写）。
#
# 做的事（全程持有构建锁，另一个会话的构建 / 安装 / 发布会排队等）：
#   1. 先提交好自己的改动再跑：暂存区必须是空的；版本号文件不能有没提交的改动。
#      工作区里别的没提交的文件（多半是另一个会话正在改的）不碰、不提交、也不会被打包进去。
#   2. 和 origin/main 同步（只快进；本地有没推送的提交时 rebase，需要工作区干净）。
#   3. 在临时 worktree（detached，从同步后的 HEAD 开）里：bump-version.sh 升 Z、跑 go test -race 和 mygo vet、
#      跑 iOS 模拟器构建检查、构建两个 dmg——全部通过后再只提交版本号文件、打 tag，用 --atomic 一次推送 main 和 tag；
#      任一步失败都不会在远端留下半成品 tag。另一个会话抢先发布时推送被拒，丢掉这个 worktree 同步后重来（最多 3 次）。
#      推送成功后本地 main 快进到这个提交。
#   4. 发布包在临时 worktree 里基于即将推送的提交构建，严格等于 tag 的内容，不受工作区里没提交的改动影响。
#   5. gh release create，然后用这个 dmg 装到本机并启动；连着 iPhone / iPad 时把同一个 tag 的 iOS 版也装上。
set -euo pipefail
zmodload zsh/datetime # EPOCHREALTIME（计时用）
TOTAL=$EPOCHREALTIME

MACOS="" IOS="" IOS_NOTE="" DRY="" WANT=""
while (($#)); do
	case $1 in
	--macos) MACOS=$2; shift 2 ;;
	--ios) IOS=$2; shift 2 ;;
	--ios-note) IOS_NOTE=$2; shift 2 ;;
	--dry-run) DRY=1; shift ;;
	--version) WANT=${2#v}; shift 2 ;;
	*) echo "不认识的参数：$1"; exit 2 ;;
	esac
done
[[ -n "$MACOS$IOS" ]] || { echo "至少要写一端的改动：--macos \"…\" 和 / 或 --ios \"…\""; exit 2; }

ROOT=${0:A:h:h:h}
cd "$ROOT"
source desktop/scripts/common.zsh
source desktop/scripts/lock.zsh
VERSION_FILES=(desktop/mygo.json ios/project.yml ios/ShiJing.xcodeproj/project.pbxproj)

[[ $(git branch --show-current) == main ]] || { echo "要在 main 上发布"; exit 1; }
git diff --cached --quiet || { echo "暂存区里有东西（可能是另一个会话的），先处理掉再发布"; git diff --cached --stat; exit 1; }
git diff --quiet -- $VERSION_FILES || { echo "版本号文件有没提交的改动，先提交或还原："; git diff --stat -- $VERSION_FILES; exit 1; }
if [[ -n $(git status --porcelain) ]]; then
	echo "提示：工作区里有没提交的文件，这次发布不包含它们（多半是另一个会话正在改的）："
	git status --short | sed 's/^/  /'
fi

sync_main() {
	git fetch -q origin
	local behind ahead
	behind=$(git rev-list --count HEAD..origin/main)
	ahead=$(git rev-list --count origin/main..HEAD)
	((behind == 0)) && return 0
	if ((ahead == 0)); then
		git merge -q --ff-only origin/main
	elif [[ -z $(git status --porcelain) ]]; then
		git rebase -q origin/main
	else
		echo "本地有没推送的提交，远端也有新提交，需要 rebase，但工作区不干净（可能是另一个会话在改）。等它提交后再发布。"
		exit 1
	fi
}

# 升版本、测试、提交都在临时 worktree（detached）里做，工作区里别人没提交的改动完全碰不到
WT=""
cleanup() { [[ -n "$WT" ]] && git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
VERSION=""
for attempt in 1 2 3; do
	sync_main
	cleanup
	WT=$(mktemp -d -t shijing-release)
	git worktree add -q --detach "$WT" HEAD
	if [[ -n "$WANT" ]]; then
		CUR=$(read_version desktop/mygo.json)
		if [[ "$WANT" == "$CUR" || "$(printf '%s\n%s\n' "$CUR" "$WANT" | sort -V | tail -1)" != "$WANT" ]]; then
			echo "--version $WANT 不比当前的 $CUR 大"; cleanup; exit 2
		fi
	fi
	"$WT/desktop/scripts/bump-version.sh" ${WANT:+"$WANT"} >/dev/null
	VERSION=$(read_version "$WT/desktop/mygo.json")
	if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
		echo "远端已经有 v$VERSION，同步后重来"
		VERSION=""
		continue
	fi
	echo "运行 Go 测试（-race）与 vet…"
	t0=$EPOCHREALTIME
	(cd "$WT/desktop" && go test -race ./... >/dev/null && go tool mygo vet) || { echo "测试或 vet 没过，没有发布"; exit 1; }
	printf 'Go 测试与 vet：%.1f 秒\n' $((EPOCHREALTIME - t0))

	[[ -f "$ROOT/ios/ShiJing/Local.xcconfig" ]] && command cp -f "$ROOT/ios/ShiJing/Local.xcconfig" "$WT/ios/ShiJing/" # 签名团队 ID（不进仓库）
	echo "iOS 模拟器构建检查…"
	t0=$EPOCHREALTIME
	(cd "$WT/ios" && xcodebuild -project ShiJing.xcodeproj -scheme ShiJing -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath build-sim build -quiet >build-sim.log 2>&1) || { grep -m5 error "$WT/ios/build-sim.log"; echo "iOS 构建失败，没有推送 tag"; exit 1; }
	printf 'iOS 模拟器构建：%.1f 秒\n' $((EPOCHREALTIME - t0))

	echo "构建 dmg（arm64、通用版）…"
	t0=$EPOCHREALTIME
	(cd "$WT/desktop" && go tool mygo build -skip-notarize >build-arm64.log 2>&1) || { tail -20 "$WT/desktop/build-arm64.log"; echo "arm64 dmg 构建失败，没有推送 tag"; exit 1; }
	(cd "$WT/desktop" && go tool mygo build -skip-notarize -platform darwin/universal >build-universal.log 2>&1) || { tail -20 "$WT/desktop/build-universal.log"; echo "通用版 dmg 构建失败，没有推送 tag"; exit 1; }
	printf '两个 dmg：%.1f 秒\n' $((EPOCHREALTIME - t0))

	git -C "$WT" commit -q -m "release(拾景): v$VERSION" -- $VERSION_FILES
	git -C "$WT" tag "v$VERSION"
	if [[ -n "$DRY" ]]; then
		git tag -d "v$VERSION" >/dev/null
		echo "（dry-run）检查与构建已通过，会推送 v$VERSION：$(git -C "$WT" log --oneline -1)"
		break
	fi
	PUSH_ERR=""
	if PUSH_ERR=$(git -C "$WT" push -q --atomic origin HEAD:main "v$VERSION" 2>&1); then
		break
	fi
	git tag -d "v$VERSION" >/dev/null
	# 仅在远端因并发发布拒绝时重试；网络断连、认证失败等直接打印错误并退出
	if [[ "$PUSH_ERR" == *"non-fast-forward"* || "$PUSH_ERR" == *"fetch first"* || "$PUSH_ERR" == *"already exists"* || "$PUSH_ERR" == *"remote rejected"* ]]; then
		echo "推送被拒（另一个会话刚发布过），放弃 v$VERSION 后重来"
		VERSION=""
	else
		echo "推送失败，已放弃 v$VERSION："
		print -r -- "$PUSH_ERR"
		exit 1
	fi
done
[[ -n "$VERSION" ]] || { echo "试了 3 次都没推上去，放弃"; exit 1; }
if [[ -z "$DRY" ]]; then
	echo "已推送 v$VERSION"
	# 本地 main 跟上（只多了版本号文件的那个提交，上面检查过它们没有没提交的改动）
	git fetch -q origin && git merge -q --ff-only origin/main
fi

cd "$WT/desktop"
ARM=build/darwin-arm64/shi-jing-$VERSION-arm64.dmg
UNI=build/darwin-universal/shi-jing-$VERSION.dmg

if [[ -z "$IOS_NOTE" ]]; then
	IOS_NOTE="iOS 端没有上架、不提供安装包：源码在 \`ios/\`，按 \`ios/README.md\` 用 Xcode 和自己的 Apple ID 装到手机上。这一版跑过模拟器构建；连着手机时会同时装到手机上。"
fi
NOTES="两个安装包任选其一：\`shi-jing-$VERSION.dmg\` 是通用版（Intel 和 Apple Silicon 都能用）；\`shi-jing-$VERSION-arm64.dmg\` 只支持 Apple Silicon，体积约一半。

## macOS

${MACOS:-无改动，仅同步版本号。}

## iOS

${IOS:-无改动，仅同步版本号。}

$IOS_NOTE

macOS 应用是 ad-hoc 签名，没有经过苹果公证，别的 Mac 第一次打开时要右键点应用选「打开」。"
if [[ -n "$DRY" ]]; then
	echo "（dry-run）构建都通过了：$ARM、$UNI。不建 Release、不安装。"
	exit 0
fi
t0=$EPOCHREALTIME
gh release create "v$VERSION" "$UNI" "$ARM" --verify-tag --title "拾景 v$VERSION" --notes "$NOTES"
printf '上传发布包：%.1f 秒\n' $((EPOCHREALTIME - t0))

# 装到本机（和连着的手机）：用的就是刚发布的包 / 同一个 tag
# 复用主工作区的 iOS 编译缓存，日志写到临时目录，避免随 worktree 清理丢失
t0=$EPOCHREALTIME
SHIJING_DERIVED_DIR="$ROOT/ios/build" SHIJING_LOG_DIR="${TMPDIR:-/tmp}" scripts/install-local.sh --no-build
printf '装到本机和手机：%.1f 秒\n' $((EPOCHREALTIME - t0))
printf '发布总耗时：%.1f 秒\n' $((EPOCHREALTIME - TOTAL))
