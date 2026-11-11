#!/bin/zsh
# 把 macOS 和 iOS 两端的版本号一起加 1（只动 Z）。两端永远同一个版本号，见 CLAUDE.md「版本号规则」。
# 用法：scripts/bump-version.sh          # Z 加 1
#       scripts/bump-version.sh 0.3.9    # 直接设成某个版本（大版本 X.Y 只在用户要求时改）
# 改的是 desktop/mygo.json 的 version、ios/project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION，
# 以及 ios/ShiJing.xcodeproj（用 xcodegen 重新生成；没装 xcodegen 时直接改工程文件里的两个字段）。
set -euo pipefail

cd "${0:A:h}/../.."
OLD=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' desktop/mygo.json | head -1)
if [[ -n "${1:-}" ]]; then
	NEW=${1#v}
else
	NEW="${OLD%.*}.$(( ${OLD##*.} + 1 ))"
fi
[[ "$NEW" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "版本号格式不对：$NEW"; exit 1; }
BUILD=${NEW##*.}

sed -i '' "s/\"version\": *\"$OLD\"/\"version\": \"$NEW\"/" desktop/mygo.json
sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]*\"/\1\"$NEW\"/; s/(CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$BUILD\"/" ios/project.yml
if command -v xcodegen >/dev/null; then
	(cd ios && xcodegen generate --quiet)
else
	sed -i '' -E "s/(MARKETING_VERSION = )[^;]*;/\1$NEW;/; s/(CURRENT_PROJECT_VERSION = )[^;]*;/\1$BUILD;/" ios/ShiJing.xcodeproj/project.pbxproj
fi
echo "v$OLD → v$NEW（macOS 和 iOS 两端）"
