#!/bin/zsh
# 发布一个新版本（macOS 和 iOS 两端一起，见 CLAUDE.md「版本号规则」「发布规则」）。两个会话都用它，不要手动走发布步骤。
#
# 用法：scripts/release.sh --macos "这一版 macOS 的改动（Markdown 列表）" --ios "iOS 的改动"
#       某一端没改就不传那一项，说明里写「无改动，仅同步版本号」。
#       --dry-run 走一遍全部检查和构建，但不推送、不建 Release、不安装（验证脚本用）。
#       --ios-note "…" 替换 iOS 一节末尾的验证说明（默认按有没有连着手机自动写）。
#
# 做的事（全程持有构建锁，另一个会话的构建 / 安装 / 发布会排队等）：
#   1. 先提交好自己的改动再跑：暂存区必须是空的；版本号文件不能有没提交的改动。
#      工作区里别的没提交的文件（多半是另一个会话正在改的）不碰、不提交、也不会被打包进去。
#   2. 和 origin/main 同步（只快进；本地有没推送的提交时 rebase，需要工作区干净）。
#   3. 在临时 worktree（detached，从同步后的 HEAD 开）里：bump-version.sh 升 Z、跑 go test、只提交版本号文件、
#      打 tag，用 --atomic 一次推送 main 和 tag；另一个会话抢先发布时推送被拒，丢掉这个 worktree 同步后重来（最多 3 次）。
#      推送成功后本地 main 快进到这个提交。
#   4. 还在这个 worktree 里构建两个 dmg、跑 iOS 模拟器构建检查：发布包严格等于 tag 的内容，
#      不受工作区里没提交的改动影响。
#   5. gh release create，然后用这个 dmg 装到本机并启动；连着 iPhone / iPad 时把同一个 tag 的 iOS 版也装上。
set -euo pipefail

MACOS="" IOS="" IOS_NOTE="" DRY=""
while (($#)); do
	case $1 in
	--macos) MACOS=$2; shift 2 ;;
	--ios) IOS=$2; shift 2 ;;
	--ios-note) IOS_NOTE=$2; shift 2 ;;
	--dry-run) DRY=1; shift ;;
	*) echo "不认识的参数：$1"; exit 2 ;;
	esac
done
[[ -n "$MACOS$IOS" ]] || { echo "至少要写一端的改动：--macos \"…\" 和 / 或 --ios \"…\""; exit 2; }

ROOT=${0:A:h:h:h}
cd "$ROOT"
source desktop/scripts/lock.zsh
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}
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
	"$WT/desktop/scripts/bump-version.sh" >/dev/null
	VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$WT/desktop/mygo.json" | head -1)
	if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
		echo "远端已经有 v$VERSION，同步后重来"
		VERSION=""
		continue
	fi
	(cd "$WT/desktop" && CGO_ENABLED=0 go test ./... >/dev/null) || { echo "测试没过，没有发布"; exit 1; }
	git -C "$WT" commit -q -m "release(拾景): v$VERSION" -- $VERSION_FILES
	git -C "$WT" tag "v$VERSION"
	if [[ -n "$DRY" ]]; then
		git tag -d "v$VERSION" >/dev/null
		echo "（dry-run）会推送 v$VERSION：$(git -C "$WT" log --oneline -1)"
		break
	fi
	if git -C "$WT" push -q --atomic origin HEAD:main "v$VERSION" 2>/dev/null; then
		break
	fi
	echo "推送被拒（另一个会话刚发布过），放弃 v$VERSION 后重来"
	git tag -d "v$VERSION" >/dev/null
	VERSION=""
done
[[ -n "$VERSION" ]] || { echo "试了 3 次都没推上去，放弃"; exit 1; }
if [[ -z "$DRY" ]]; then
	echo "已推送 v$VERSION"
	# 本地 main 跟上（只多了版本号文件的那个提交，上面检查过它们没有没提交的改动）
	git fetch -q origin && git merge -q --ff-only origin/main
fi

[[ -f ios/ShiJing/Local.xcconfig ]] && command cp -f ios/ShiJing/Local.xcconfig "$WT/ios/ShiJing/" # 签名团队 ID（不进仓库）
cd "$WT/desktop"
echo "构建 dmg（arm64、通用版）…"
go tool mygo build -skip-notarize >build-arm64.log 2>&1 || { tail -20 build-arm64.log; exit 1; }
go tool mygo build -skip-notarize -platform darwin/universal >build-universal.log 2>&1 || { tail -20 build-universal.log; exit 1; }
ARM=build/darwin-arm64/shi-jing-$VERSION-arm64.dmg
UNI=build/darwin-universal/shi-jing-$VERSION.dmg
echo "iOS 模拟器构建检查…"
(cd ../ios && xcodebuild -project ShiJing.xcodeproj -scheme ShiJing -destination 'generic/platform=iOS Simulator' \
	-derivedDataPath build-sim build -quiet >build-sim.log 2>&1) || { grep -m5 error ../ios/build-sim.log; echo "iOS 构建失败，tag 已推送但没有建 Release"; exit 1; }

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
gh release create "v$VERSION" "$UNI" "$ARM" --verify-tag --title "拾景 v$VERSION" --notes "$NOTES"

# 装到本机（和连着的手机）：用的就是刚发布的包 / 同一个 tag
scripts/install-local.sh --no-build
