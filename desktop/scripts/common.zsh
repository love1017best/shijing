# 构建、安装与发布脚本的公共配置和工具函数。
# 用法：source "${0:A:h}/common.zsh"

# Xcode 工具链默认路径（可在外部通过环境变量覆盖）
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}

# 从 mygo.json 读取当前应用版本号（默认读 desktop/mygo.json）
read_version() {
	local file="${1:-mygo.json}"
	sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$file" | head -1
}
