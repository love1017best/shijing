# 拾景 iOS 遥控端

SwiftUI 写的原生 iPhone / iPad 应用，在局域网里遥控 Mac 上的拾景：看实时进度、换一批壁纸、停止运行。筛选和复制都在 Mac 上做，手机只是遥控器。

- 最低 iOS 17。
- 界面按实际宽度排版：窄的时候一栏，宽的时候（横屏、展开的大屏、分屏的宽半边、iPad）左边 Mac 列表、右边遥控面板，面板本身也会分成左右两栏。
- 接口在 `desktop/remote.go`，两边的状态结构（`RemoteState`）一一对应，改一边要同步另一边。

## 装到自己的手机上（免费 Apple ID 就行）

需要完整的 Xcode（App Store 免费下载，只有命令行工具不够）。

1. 在 Xcode › Settings › Accounts 里登录自己的 Apple ID。
2. 用 Xcode 打开 `ios/ShiJing.xcodeproj`，ShiJing target → Signing & Capabilities → Team 选自己的 Personal Team。
   Xcode 会把团队 ID 写进工程文件；把它挪到 `ios/ShiJing/Local.xcconfig`（已 gitignore，内容只有一行 `DEVELOPMENT_TEAM = 团队ID`），再在 `ios/` 下跑 `xcodegen`，工程文件里就不留团队 ID 了。只需要做一次。
   如果提示 bundle id 已被占用，把 `com.love1017best.shijing.ios` 改成别的。
3. iPhone 用线连上 Mac，在 Xcode 顶部选这台手机点运行；或者用命令行（见下面）。
4. 第一次装：手机上打开「设置 › 隐私与安全性 › 开发者模式」并重启确认；装上后到「设置 › 通用 › VPN 与设备管理」里信任自己的开发者证书。

在这个仓库里开发时直接用 `desktop/scripts/install-local.sh`：它会同时重装 Mac 端，并把 iOS 版装到所有连着的 iPhone / iPad 上（见根目录 CLAUDE.md「两个会话并行开发」）。手动的话，命令行构建并安装（`xcode-select` 指向命令行工具时用 `DEVELOPER_DIR` 指定 Xcode）：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer
xcrun devicectl list devices                     # 找手机的 Identifier
cd ios
xcodebuild -project ShiJing.xcodeproj -scheme ShiJing -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <Identifier> build/Build/Products/Debug-iphoneos/拾景.app
xcrun devicectl device process launch --device <Identifier> com.love1017best.shijing.ios
```

免费账号的限制：

- 装上的应用 **7 天后过期**，过期后打不开，用 Xcode 再运行一次就续上（数据和配对都在）。
- 同一个 Apple ID 最多同时装 3 个自签名应用。
- 没有远程推送，App 在后台时收不到「换好了」的通知；回到前台会自动重连并显示最新状态。

## 开发

工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 按 `project.yml` 生成。增删了源文件或改了 `project.yml` 后：

```bash
brew install xcodegen   # 只需要一次
cd ios && xcodegen
```

| 文件 | 内容 |
|---|---|
| `ShiJingApp.swift` | 入口和顶层分栏（`NavigationSplitView`），前后台切换时断开 / 重连 |
| `MacListView.swift` / `PairView.swift` | Mac 列表、手动输入地址 / 配对 |
| `DashboardView.swift` | 遥控面板：状态、步骤、进度、换一批 / 停止、上次运行 |
| `RemoteSession.swift` | 和一台 Mac 的连接：事件流（SSE）、断线重连、Mac 换 IP 后按 Bonjour 名重新找 |
| `APIClient.swift` / `Models.swift` | 接口客户端 / 数据结构 |
| `Discovery.swift` | Bonjour（`_shijing._tcp`）发现和解析 |
| `MacStore.swift` | 配对过的 Mac（UserDefaults）和令牌（钥匙串） |

没装 Xcode 时可以用命令行工具先做类型检查（iOS 专有的修饰符包在 `#if os(iOS)` 里，所以能在 macOS SDK 上检查）：

```bash
cd ios/ShiJing
swiftc -typecheck -swift-version 5 -parse-as-library -target arm64-apple-macos15 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk *.swift
```

用 26.x 的 SDK：27.x 的 SwiftUI 把 `@State` 换成了宏，命令行工具里没有对应的宏插件。
