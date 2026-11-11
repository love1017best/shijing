# 构建 / 安装 / 发布的互斥锁：macOS 和 iOS 两个会话共用一个工作区，同时跑会抢同一个 build 目录、
# 同时替换 /Applications/拾景.app、同时升版本号。被 install-local.sh、install-ios-device.sh、release.sh source。
# 锁文件在 .git 里（worktree 也共用同一个），进程退出时自动释放；子脚本看到 SHIJING_LOCKED 就不再加锁。
# 用法：source "${0:A:h}/lock.zsh"   （在 cd 到仓库里之后）
if [[ -z "${SHIJING_LOCKED:-}" ]]; then
	zmodload zsh/system
	SHIJING_LOCKFILE="$(git rev-parse --path-format=absolute --git-common-dir)/shijing-build.lock"
	: >>"$SHIJING_LOCKFILE"
	if ! zsystem flock -t 0 "$SHIJING_LOCKFILE" 2>/dev/null; then
		echo "另一个会话正在构建 / 安装 / 发布，等它结束（最多 20 分钟）…"
		zsystem flock -t 1200 "$SHIJING_LOCKFILE" || { echo "等了 20 分钟还没轮到，放弃"; exit 1; }
	fi
	export SHIJING_LOCKED=1
fi
