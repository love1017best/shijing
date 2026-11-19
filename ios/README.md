# 拾景 iOS 遥控端

使用 SwiftUI 开发的原生 iPhone / iPad 应用，在局域网里遥控 Mac 上的拾景：查看实时进度、换一批壁纸、停止运行，浏览当前壁纸并移出 / 不再选 / 删除原图。筛选和复制都在 Mac 上执行。

- 最低 iOS 17。
- 界面按实际宽度排版：窄屏显示一栏；宽屏（横屏、展开的大屏、分屏的宽半边、iPad）上方是状态卡，下面分左右两栏。切换、添加 Mac 在标题菜单里。
- 两个 target：App（`ShiJing`）和主屏幕小组件（`ShiJingWidget`）。两边都编译 `ShiJing/Shared/` 里的代码（接口、模型、钥匙串、快捷指令操作、完成通知）。
- 免费签名没有 App Groups，App 和小组件通过**钥匙串共享**交换数据（`keychain-access-groups`，组名 `<团队前缀>com.love1017best.shijing.shared`，写在两边 Info.plist 的 `ShiJingKeychainGroup` 里），配对令牌和当前选中的 Mac（`CurrentMac`）都存在这个组里。
- 接口定义在 `desktop/remote.go`，两边的状态结构（`RemoteState`）字段一一对应，改一边要同步另一边。

## 安装到自己的手机（免费 Apple ID 即可）

需要完整的 Xcode（App Store 免费下载），只有命令行工具无法签名安装。

1. 在 Xcode › Settings › Accounts 里登录自己的 Apple ID。
2. 用 Xcode 打开 `ios/ShiJing.xcodeproj`，在 ShiJing target → Signing & Capabilities → Team 里选自己的 Personal Team。
   Xcode 会把团队 ID 写进工程文件。把它移到 `ios/ShiJing/Local.xcconfig`（已加入 gitignore，内容只有一行 `DEVELOPMENT_TEAM = 团队ID`），再在 `ios/` 下运行 `xcodegen`，重新生成的工程文件里就去掉了团队 ID。这一步只需要做一次。
   如果提示 bundle id 已被占用，把 `com.love1017best.shijing.ios` 改成其他名字，小组件的 `….ios.widget` 和钥匙串组名也一起改。
3. 用数据线把 iPhone 连到 Mac，在 Xcode 顶部选中这台手机，点运行；也可以使用下面的命令行。
4. 第一次安装：在手机上打开「设置 › 隐私与安全性 › 开发者模式」并重启确认；安装后在「设置 › 通用 › VPN 与设备管理」里信任自己的开发者证书。

在这个仓库里开发时使用 `desktop/scripts/install-local.sh`：它重新安装 Mac 端，并把 iOS 版安装到所有连接的 iPhone / iPad 上（见根目录 CLAUDE.md「两个会话并行开发」）。

只给手机或平板安装（例如免费签名 7 天到期后续签）时，使用 `desktop/scripts/install-ios.sh`：

```bash
desktop/scripts/install-ios.sh                    # GitHub 上最新发布的版本（签名不足 2 天自动刷新）
desktop/scripts/install-ios.sh --refresh-signing  # 提前强制刷新免费签名并重装
desktop/scripts/install-ios.sh --current          # 当前工作区的代码（包括未提交的改动）
desktop/scripts/install-ios.sh --device Pad       # 只安装到名称含「Pad」的设备；省略时安装到所有连接的设备
```

默认安装最新发布的 tag：脚本在临时 worktree 里检出这个 tag 再构建，构建内容只包含这个 tag 的代码，安装完删除临时 worktree。`/Applications` 里的 Mac 版保持原样。设备需要解锁、信任这台电脑并打开开发者模式。当本机缓存的描述文件剩余不足 2 天或传入 `--refresh-signing` 时，脚本会先备份旧文件再向 Apple 重新签发 7 天描述文件（拉取失败时自动恢复备份）；拉取新描述文件要求 Xcode 中已登录 Apple ID。

手动逐步安装（`xcode-select` 指向命令行工具时，用 `DEVELOPER_DIR` 指定 Xcode）：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer
xcrun devicectl list devices                     # 查看手机的 Identifier
cd ios
xcodebuild -project ShiJing.xcodeproj -scheme ShiJing -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <Identifier> build/Build/Products/Release-iphoneos/拾景.app
xcrun devicectl device process launch --device <Identifier> com.love1017best.shijing.ios
```

免费账号的限制：

- 安装的应用 **7 天后过期**，过期后无法启动。用 Xcode 再运行一次即可续签，数据和配对保留。
- 同一个 Apple ID 最多同时安装 3 个自签名应用。
- App 和小组件扩展各需要一个 App ID；免费账号 7 天内最多注册 10 个 App ID。
- 没有远程推送。完成通知只在两种情况下发出：App 切到后台后仍保持连接的约 30 秒内（系统给的后台时间），或小组件刷新时发现这次已经换完。回到前台时自动重连并显示最新状态。
- 到期时间读取自安装包里的 `embedded.mobileprovision`，剩余不到 2 天时概览顶部提醒，到期前一天发本地通知。

## 开发

工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `project.yml` 生成。增删源文件或修改 `project.yml` 后运行：

```bash
brew install xcodegen   # 只需要安装一次
cd ios && xcodegen
```

| 文件 | 内容 |
|---|---|
| `ShiJingApp.swift` | 入口：没有配对时显示 `SetupView`，否则显示三个标签页；前后台切换时断开 / 重连；本地通知 |
| `MacListView.swift` / `PairView.swift` | 首次配对页、添加 / 管理 Mac、附近的 Mac 和手动输入地址 / 输入配对码 |
| `QRScan.swift` | 扫描电脑上的配对二维码 |
| `DashboardView.swift` | 概览：横幅卡、状态、步骤、进度、换一批 / 停止、上一轮对比、签名到期提醒、待删除原图 |
| `SettingsSection.swift` | 「设置」标签（电脑上的拾景 / 这台设备 / 关于三栏）、图库目录二级页、概览的「状态」分组 |
| `RecordsPage.swift` | 「记录」标签：运行日志、删除记录、不再选三栏，以及离线时读取缓存的逻辑 |
| `QueuedActionsView.swift` | 「待处理操作」页：离线时记下的移出、不再选、删除原图 |
| `WallpapersView.swift` / `WallPreview.swift` | 缩略图网格、「全部壁纸」页、撤销移出、分享原图 / 大图预览 |
| `RemoteSession.swift` | 和一台 Mac 的连接：事件流（SSE）、断线重连、Mac 换 IP 后按 Bonjour 名称重新查找、运行中切到后台时延长连接；视图通过 `request` 发请求；写离线快照和记录缓存 |
| `RemoteSession+Queue.swift` | 离线操作队列：保存、连接后逐条处理、确认删除原图 |
| `OfflineMode.swift` / `Shared/OfflinePrefs.swift` | 离线模式：手动离线、使用蜂窝网络时离线；设置存在共享钥匙串，小组件也读 |
| `ConnectionUI.swift` | 连接异常时的整页提示、断开 / 重连时的状态徽标 |
| `OfflineStore.swift` | 离线快照（最后一次连接时的状态和壁纸列表）和记录页的三份缓存，带同步时间 |
| `ImageStore.swift` | 图片的内存缓存和磁盘缓存：缩略图、横幅、整批大图、原图（可选）在连接时后台预取，受缓存上限限制（默认 10 GB）；离线时从磁盘读取；设置页「离线」分组显示占用、进度并提供清除 |
| `AppSupport.swift` | Application Support/拾景 下各子目录的位置 |
| `Glass.swift` | 悬浮块的玻璃背景（iOS 26 使用系统液态玻璃，更早的系统使用 `.ultraThinMaterial`） |
| `SigningExpiry.swift` | 免费签名到期时间 |
| `AppShortcuts.swift` | Siri、聚焦和操作按钮里可直接使用的快捷指令 |
| `RemoteSessionDemo.swift` | Debug 构建的演示数据（`-demo*` 启动参数，截图用） |
| `Shared/APIClient.swift` / `Shared/Models.swift` | 接口客户端 / 数据结构（App 和小组件共用） |
| `Shared/SharedKeychain.swift` | 共享钥匙串：令牌、`CurrentMac` |
| `Shared/Intents.swift` | 换一批 / 停止 / 状态三个 App Intent（快捷指令和小组件按钮使用） |
| `Shared/RunNotifier.swift` | 完成通知（App 和小组件共用「已通知过哪一次」的记录，同一次只发一条） |
| `Discovery.swift` | Bonjour（`_shijing._tcp`）发现和解析 |
| `MacStore.swift` | 配对过的 Mac（UserDefaults），选中的那台同步写入共享钥匙串 |
| `../ShiJingWidget/ShiJingWidget.swift` | 两种小组件（「拾景」/「拾景壁纸」）、控制中心按钮、时间线和离线缓存 |
| `../ShiJingWidget/WidgetViews.swift` | 小组件各尺寸的界面（App 的 Debug 构建也编译它，供 `-demoWidgets` 演示页使用） |

没有安装 Xcode 时，可以用命令行工具做类型检查。iOS 专有的修饰符包在 `#if os(iOS)` 里，所以能用 macOS SDK 检查：

```bash
cd ios/ShiJing
swiftc -typecheck -swift-version 5 -parse-as-library -target arm64-apple-macos15 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk *.swift Shared/*.swift
```

需要使用 26.x 的 SDK：27.x 的 SwiftUI 把 `@State` 改成了宏，命令行工具里缺少对应的宏插件。
