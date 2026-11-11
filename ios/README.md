# 拾景 iOS 遥控端

SwiftUI 写的原生 iPhone / iPad 应用，在局域网里遥控 Mac 上的拾景：看实时进度、换一批壁纸、停止运行，浏览当前壁纸并移出 / 不再选 / 删除原图。筛选和复制都在 Mac 上做，手机只是遥控器。

- 最低 iOS 17。
- 界面按实际宽度排版：窄的时候一栏，宽的时候（横屏、展开的大屏、分屏的宽半边、iPad）顶部状态卡、下面左右两栏。切换 / 添加 Mac 在标题菜单里。
- 两个目标：App（`ShiJing`）和主屏幕小组件（`ShiJingWidget`）。两边共用 `ShiJing/Shared/` 里的代码（接口、模型、钥匙串、快捷指令操作、换完通知）。
- 免费签名没有 App Groups，App 和小组件靠**钥匙串共享**（`keychain-access-groups`，组名 `<团队前缀>com.love1017best.shijing.shared`，写进两边 Info.plist 的 `ShiJingKeychainGroup`）交换数据：配对令牌和「当前这台 Mac」（`CurrentMac`）都存在里面。
- 接口在 `desktop/remote.go`，两边的状态结构（`RemoteState`）一一对应，改一边要同步另一边。

## 装到自己的手机上（免费 Apple ID 就行）

需要完整的 Xcode（App Store 免费下载，只有命令行工具不够）。

1. 在 Xcode › Settings › Accounts 里登录自己的 Apple ID。
2. 用 Xcode 打开 `ios/ShiJing.xcodeproj`，ShiJing target → Signing & Capabilities → Team 选自己的 Personal Team。
   Xcode 会把团队 ID 写进工程文件；把它挪到 `ios/ShiJing/Local.xcconfig`（已 gitignore，内容只有一行 `DEVELOPMENT_TEAM = 团队ID`），再在 `ios/` 下跑 `xcodegen`，工程文件里就不留团队 ID 了。只需要做一次。
   如果提示 bundle id 已被占用，把 `com.love1017best.shijing.ios` 改成别的（小组件的 `….ios.widget` 跟着改，钥匙串组名也一样）。
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
- 一个 App 加一个小组件扩展，各要一个 App ID；免费账号 7 天内最多注册 10 个 App ID，一般够用。
- 没有远程推送：「换好了」的通知只在 App 换到后台后还连着的那一小会儿（系统给 30 秒左右），或者小组件刷新时看到才发。回到前台会自动重连并显示最新状态。
- 到期时间从安装包里的 `embedded.mobileprovision` 读，剩不到 2 天时概览顶部提醒，前一天发本地通知。

## 开发

工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 按 `project.yml` 生成。增删了源文件或改了 `project.yml` 后：

```bash
brew install xcodegen   # 只需要一次
cd ios && xcodegen
```

| 文件 | 内容 |
|---|---|
| `ShiJingApp.swift` | 入口：没配对时整屏 `SetupView`，否则遥控面板；前后台切换时断开 / 重连；本地通知 |
| `MacListView.swift` / `PairView.swift` | 首次配对页、标题菜单（切换 / 添加 / 管理 Mac）、手动输入地址 / 配对 |
| `DashboardView.swift` | 遥控面板：状态、步骤、进度、换一批 / 停止、上次运行、签名到期提醒 |
| `SettingsSection.swift` | 可以改的设置分组；记录分组和三页：运行日志、删除记录、不再选 |
| `WallpapersView.swift` / `WallPreview.swift` | 缩略图网格、撤销移出、分享原图 / 大图预览 |
| `RemoteSession.swift` | 和一台 Mac 的连接：事件流（SSE）、断线重连、Mac 换 IP 后按 Bonjour 名重新找；运行中切到后台时多连一会儿 |
| `SigningExpiry.swift` | 免费签名到期时间 |
| `AppShortcuts.swift` | Siri / 聚焦 / 操作按钮里直接能用的快捷指令 |
| `Shared/APIClient.swift` / `Shared/Models.swift` | 接口客户端 / 数据结构（App 和小组件共用） |
| `Shared/SharedKeychain.swift` | 共享钥匙串：令牌、`CurrentMac` |
| `Shared/Intents.swift` | 换一批 / 停止 / 状态三个 App Intent（快捷指令和小组件按钮） |
| `Shared/RunNotifier.swift` | 换完发通知（App 和小组件共用「通知过哪次」的记录，同一次只发一条） |
| `Discovery.swift` | Bonjour（`_shijing._tcp`）发现和解析 |
| `MacStore.swift` | 配对过的 Mac（UserDefaults），选中的那台同步写进共享钥匙串 |
| `../ShiJingWidget/` | 主屏幕小组件 |

没装 Xcode 时可以用命令行工具先做类型检查（iOS 专有的修饰符包在 `#if os(iOS)` 里，所以能在 macOS SDK 上检查）：

```bash
cd ios/ShiJing
swiftc -typecheck -swift-version 5 -parse-as-library -target arm64-apple-macos15 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk *.swift Shared/*.swift
```

用 26.x 的 SDK：27.x 的 SwiftUI 把 `@State` 换成了宏，命令行工具里没有对应的宏插件。
