#!/bin/zsh
# 把拾景装到连着的 iPhone / iPad 上（自己手动装用，比如免费签名 7 天到期了要续一下）。
#
# 用法：
#   desktop/scripts/install-ios.sh                 装 GitHub 上最新发布的版本（默认）
#   desktop/scripts/install-ios.sh --current       装当前工作区的代码（包括还没提交的改动）
#   desktop/scripts/install-ios.sh --device Pad    只装名字里含「Pad」的设备（不区分大小写），不写就装所有连着的
#   两个选项可以一起用。
#
# 默认装最新发布版：在临时 worktree 里检出那个 tag 再构建，工作区里没提交的改动不会混进去；装完删掉 worktree。
# 只装手机、不动 /Applications 里的 Mac 版。和 install-local.sh / release.sh 共用一把锁，同时跑会排队。
# 需要：Xcode（默认 /Applications/Xcode-27.2.0.app）、签名团队 ID（ios/ShiJing/Local.xcconfig，见 ios/README.md）、
# 设备解锁并信任这台电脑、开了开发者模式。
set -uo pipefail

CURRENT=""
DEVICE=""
while (( $# )); do
	case $1 in
	--current) CURRENT=1; shift ;;
	--device) [[ $# -ge 2 ]] || { echo "--device 后面要写设备名字里的一段"; exit 2; }; DEVICE=$2; shift 2 ;;
	-h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "不认识的参数：$1（--help 看用法）"; exit 2 ;;
	esac
done

SCRIPTS=${0:A:h}
ROOT=${SCRIPTS:h:h}
cd "$ROOT" || exit 1
source "$SCRIPTS/lock.zsh"
export SHIJING_DEVICE=$DEVICE

if [[ -n "$CURRENT" ]]; then
	echo "装当前工作区的代码…"
	"$SCRIPTS/install-ios-device.sh"
	exit
fi

# 最新发布的 tag（只看远端 vX.Y.Z，不推送任何东西）
TAG=$(git ls-remote --tags --refs origin 'v*' 2>/dev/null | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
[[ -n "$TAG" ]] || { echo "拿不到远端的版本列表（没联网？），可以用 --current 装当前代码"; exit 1; }
git fetch -q origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || git rev-parse -q --verify "refs/tags/$TAG" >/dev/null ||
	{ echo "取不到 $TAG"; exit 1; }

WT=$(mktemp -d -t shijing-ios)
cleanup() { git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || command rm -rf "$WT"; }
trap cleanup EXIT
git worktree add -q --detach "$WT" "$TAG" || exit 1
# 签名团队 ID 不进仓库，拷进去
[[ -f ios/ShiJing/Local.xcconfig ]] && command cp -f ios/ShiJing/Local.xcconfig "$WT/ios/ShiJing/"

echo "装最新发布版 $TAG（第一次构建要一两分钟）…"
SHIJING_IOS_DIR="$WT/ios" "$SCRIPTS/install-ios-device.sh"
