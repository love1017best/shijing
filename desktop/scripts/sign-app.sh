#!/bin/zsh
# 给装到本机的拾景.app 换一个稳定的本地签名。
#
# 为什么：mygo build 出来的是 ad-hoc 签名，每次构建指纹都不一样；macOS 的隐私授权
#（访问网络卷、Files & Folders）是按签名身份记的，所以每次重装都会再问一次。
# 在手机上远程删原图时，这个授权框还得人走到电脑前点一下，很别扭。
# 用一个固定的证书（本机钥匙串里的 Apple Development）签名，TCC 授权一次以后就一直有效
#（同一个证书续期、CN 不变也认）。不碰 dmg：发布包照旧是 ad-hoc，这里只处理装到本机的那份。
#
# 用法：scripts/sign-app.sh [应用路径]（默认 /Applications/拾景.app）
#       SHIJING_SIGN_IDENTITY="证书名称" 可以指定别的证书。
set -euo pipefail

APP="${1:-/Applications/拾景.app}"
[[ -d "$APP" ]] || { echo "找不到 $APP"; exit 1; }

IDENTITY="${SHIJING_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
	IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null |
		sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
fi
if [[ -z "$IDENTITY" ]]; then
	echo "没有可用的签名证书，保持 ad-hoc（重装后需要重新授权访问网络卷）"
	exit 0
fi

if ! codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
	echo "用「$IDENTITY」签名失败，改回 ad-hoc"
	codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "已用稳定的本地签名「$IDENTITY」：$APP"
