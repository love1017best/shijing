# CLAUDE.md

给未来在这个仓库里工作的 Claude/Agent 的项目背景说明。完整的功能/参数文档见 `README.md`，这里只记录**基本情况 + 踩过的坑**，避免同样的问题重新调查一遍。

## 项目是什么

个人壁纸库管理工具集：从一个挂载在 NAS 上的大型图片库（`/Volumes/Media0`，通过 SMB 挂载）里，按分辨率/方向筛选、随机采样一批图片，复制到本地 `~/Pictures/Wallpapers0` 供 macOS 壁纸幻灯片使用，并清理壁纸缓存。

**唯一在维护的是 `desktop/`**：产品名「拾景」（bundle id `com.love1017best.shijing`），Go + [MyGo](https://mygo.egoist.dev/)（原生 UI，不走 webview）。核心逻辑在 `desktop/core/`：
- `sorter.go` — 删除不合规图片（竖屏/正方形/分辨率不足），增量模式按目录内文件 mtime 判断是否跳过
- `copier.go` — 扫描 + 随机/平衡采样 + 复制/软链接到目标目录 + 可选的归档（硬链接）副本
- `imageutil.go` — 格式/分辨率判断、`walk`（`os.walk` 语义）、并发工具
- `pipeline.go` — 编排：筛选 → 采样复制 → 刷新系统壁纸；GUI（`app.go`）和命令行（`cmd/wallpaper`）都调它

**Python 版已于 2026-11 从仓库删除**，不再维护，改功能不需要考虑 Python；本仓库（`love1017best/shijing`）从 v0.2.106 起用一个全新的初始提交开始，不含以前的历史；Python 版的完整代码和之前的提交在旧的私有仓库 `love1017best/wallpaper-toolkit` 里（tag `python-final`），本地克隆里也留有 `legacy-main` 分支，`git show python-final:image_sorter.py` 之类可以直接看。Python 时期的删除日志、增量状态和双击启动壳 `壁纸工具.app` 也都已删除。下面坑 1–10 是 Python 时期踩出来的，提到的 `image_sorter.py`、`clean_directory()` 等指旧仓库里的旧实现，Go 版里都有对应处理和测试（名字换成了 Go 风格，如 `dirMtime`、`clearDirectoryContents`、`sampleBalanced`），坑本身仍然成立。Go 版刻意没有迁移的只有几个单独跑脚本时的命令行参数：`image_sorter.py --reset-state`（替代：删状态文件）、`image_copyer.py --ratio` / `--no-format-check` / `--log`。

## 踩过的坑（重要，别重新踩一遍）

### 1. `/Volumes/Media0` 是 SMB 网络挂载，协议层面天生不支持硬链接
`mount | grep Media0` 确认是 `smbfs`。在这个卷上 `os.link()` 会直接报 `[Errno 45] Operation not supported`，不是代码 bug，是 macOS SMB 客户端的限制。**永远不要假设 `/Volumes/Media0` 下能创建硬链接**，要么走软链接兜底，要么换协议（见第 4 点）。

### 2. macOS 在 SMB 上创建的软链接，Windows 读不了
macOS 通过 SMB 创建的符号链接用的是苹果私有的 SMB 扩展编码，只有 macOS 的 SMB 客户端能解析。如果归档文件夹要给 Windows 远程当壁纸素材源用，Windows 端会完全读不出来（不是权限问题，是编码不兼容）。

### 3. 网络卷/被 Finder 打开的目录，`shutil.rmtree()` 会报 `Errno 16 Resource busy`
`clean_directory()`（`rmtree` 整个目录再 `mkdir` 重建）在本地磁盘上没问题，但对着一个正被 Finder 窗口打开着、或位于网络卷上的目录做「删除目录本身再重建」，删除 `rmdir` 这一步经常会 `Resource busy`。
**解法**：`image_copyer.py` 里的 `clear_directory_contents()` 只清空目录内容、不删除目录本身（`iterdir()` 逐个删），归档目录用这个而不是 `clean_directory()`。如果哪天要对网络卷上的目录做"清空重建"，优先用这个模式。

### 4. `shutil.copy2()` 会因为 `SF_ARCHIVED` 等 flags 假性报错
NAS/网络卷上同步来的文件经常带有 `SF_ARCHIVED`（superuser-only）等 `st_flags`。`copy2` 内部 `copyfile` 成功后还会调用 `copystat` 还原这些 flags，非 root 进程设置这类 flag 会抛 `PermissionError`——**此时文件内容其实已经复制成功**，只是元数据还原失败。如果直接把这个异常当作"复制失败"处理（比如 `continue` 跳过后续步骤），会产生大量假阳性失败。
**解法**：拆成 `shutil.copyfile()` + 单独 try/except 包住的 `shutil.copystat()`，metadata 失败只 `pass`，不影响主流程判定。

### 5. 硬链接要求两端在**同一个本地挂载点**，不能跨协议/跨挂载点连
即使 SMB 和 NFS 挂载的是 NAS 上同一份物理数据，`os.link(a, b)` 里 `a` 在 SMB 挂载点、`b` 在 NFS 挂载点也一定失败——OS 层面它们是两个不同的 mount（不同 st_dev），跟数据是否相同无关。
这台机器上：SMB 挂载在 `/Volumes/Media0`，NFS 挂载在 `/Volumes/nfs/Media0`（同一份数据，`ls` 对比过内容一致，且已用 `os.link` 实测在 NFS 挂载点内部可以正常建硬链接）。
`image_copyer.py` 里 `archive_smb_root` / `archive_nfs_root` 这对参数就是干这个的：采样/扫描/真复制全程仍然只走 `sources` 里配置的 SMB 路径不变，只有创建归档链接这一步，把源文件路径的 `archive_smb_root` 前缀换算成 `archive_nfs_root` 再做硬链接（`translate_source_for_archive()`），这样链接和源文件才落在同一个 NFS 挂载点下。

### 6. 归档功能优先级：硬链接 > 软链接兜底，且默认关闭
`archive_enabled` 默认 `false`，不影响任何已有行为。开启后每张选中的图片，除了真复制/软链接到 `dest_dir` 外，还会在归档目录下额外建一份链接（优先硬链接，不支持时自动降级软链接），归档目录默认是「源目录自身上级路径 / `_WallpaperArchive` 子文件夹」，可用 `archive_dir_override` 整体覆盖，或用 `archive_smb_root`/`archive_nfs_root` 做跨挂载点换算（见第 5 点）。

### 7. 增量筛选的"缓存"曾经被 AppleDouble 影子文件/NAS 索引缓存目录污染
`image_sorter.py` 的增量模式靠 `get_dir_mtime()` 判断目录有没有变化。旧实现直接拿目录本身裸的 `os.stat().st_mtime` 当信号，但 macOS 在非原生文件系统（网络共享/NFS/exFAT）上访问文件时会偷偷生成隐藏的 AppleDouble 影子文件（`._xxx.jpg`），Synology/QNAP 等 NAS 的缩略图/索引服务也会在媒体文件夹里建 `@eaDir` 之类的缓存目录——这些噪声文件/目录的增删会推高所在目录自身的 `mtime`，但图片内容其实根本没变，导致明明没动过的文件夹被反复整个重新扫描（实测过：文件夹里真实图片的 mtime 仍是几个月前，但目录自身 mtime 却是"刚刚"，SMB 默认还会把这些 `._`/`@eaDir` 从目录列表里隐藏掉，所以从 Finder/SMB 完全看不出问题在哪，只有换到 NFS 挂载点才能看到这些隐藏文件）。
**解法**：`get_dir_mtime()` 不再用目录自身裸的 `st_mtime`，改成只统计"有意义的文件"本身的 mtime（用 `_IGNORED_NAMES` 集合 + `._` 前缀过滤掉已知噪声），递归子目录时同样跳过这些噪声目录，不下钻、不计入。这样一来，AppleDouble/索引缓存的增删完全不影响判断，但新增/修改真实图片仍然会被正确识别为"变化"。

### 8. 叶子文件夹数量 > 采样数量时，`sample_images_balanced()` 曾经永远覆盖同一批文件夹
`image_copyer.py` 里平衡采样第一轮"每个叶子文件夹优先选1张"，遍历的是 `list(grouped_images.keys())`——这个顺序来自 `os.walk()` 遍历顺序，对同一份目录结构是稳定不变的。旧实现没有打乱这个顺序，第一轮循环一旦凑够 `total_needed` 就 `break`，导致：当叶子文件夹总数多于采样数量时，排在遍历顺序前面的那些文件夹永远会被选中一次，排在后面的文件夹永远选不到——不管重跑多少次都是完全一样的那一批（实测过：同一份目录结构下连续调用/跨进程调用，覆盖到的文件夹集合 md5 哈希完全一致）。`random.choice` 只负责"选中的文件夹里挑哪张图"，不影响"选中哪些文件夹"，所以这不是靠多跑几次就能自然规避的。
**解法**：在第一轮循环前 `random.shuffle(leaf_folders)`。修复后验证：连续 4 次独立进程调用，覆盖到的文件夹集合互不相同；累计并集覆盖率随运行次数增加而上升（本机 415 个叶子文件夹、采样 300 的配置下，4 次跑完就能覆盖全部 415 个）。

### 9. 一轮优化小结（都已实测验证，不只是猜测）
- `image_copyer.py`：`find_image_files()` + `find_images_by_leaf_folder()` 合并成 `scan_images()` 一次遍历同时产出两种视图。之前 `balance_first` 模式下这两个函数各自完整 `os.walk` 一遍相同的源目录（`filter_sources` 里的图片还要被 PIL 打开检查分辨率两次），实测单独跑一遍在冷/热缓存下花 2~10 秒不等，跑两遍纯属白白多付一次这个代价。
- `image_copyer.py`：`run_copy()` 里算"叶子文件夹覆盖率"的 `covered_folders`，之前是对每张选中的图片都拿 `is_relative_to()` 逐个比对所有 leaf key（O(选中数×叶子数)）；实际上按 `scan_images()` 的构造方式，`src_path.parent` 必然就是它所属的叶子文件夹本身，直接 `{src_path.parent for _, src_path in selected_images}` 就是答案，验证过零误差。
- `image_sorter.py`：`save_dir_state()` 之前会对每个刚处理过的目录**重新调用一次** `get_dir_mtime()`，而这个值在扫描阶段其实已经算过——对网络卷来说等于重新递归 stat 一遍该目录下所有文件。现在扫描时顺手把 mtime 存进 `dir_mtimes` 字典，保存状态时直接复用。同时把"事后用 `os.path.commonpath`/`startswith` 反推某个 `root` 属于哪个 `source`"的重复逻辑去掉了——扫描本来就是按 `source` 嵌套 `os.walk` 走的，直接在遍历时归类即可，不需要事后反推（也顺带消除了反推失败时静默丢失该目录输出的理论风险）。
- 用过 `.resolve()` 单独计时确认：`Path.resolve()` 在这几个挂载点上快到可以忽略（300 次调用 <10ms），所以没有为归档路径换算加缓存——加了反而是无意义的复杂度。
- `gui.py`/`run.py`：「清除壁纸缓存」这个勾选框之前是个摆设——`_build_cfg()` 从来没读过它的值，`run_pipeline()` 里清缓存那一步也没检查任何开关，只要 `wallpaper_cache_path` 非空就无条件清。现在补了 `clear_wallpaper_cache` 字段，勾选框真正生效了；顺手把清缓存路径展开从 `.replace('~', ...)` 换成正规的 `os.path.expanduser()`。

### 10. 第二轮审查修掉的几个"出事后果比较重"的问题
- `run_copy()` 以前先清空 `dest_dir` 再扫描源目录——NAS 没挂载/网络抖动时扫描不到图片，壁纸目录白白被清空。现在顺序是：扫描 → 采样 → 确认选出图片后才清空 dest/归档目录并复制；找不到图片会抛 `CopyError`（不再在库代码里 `sys.exit`），目标目录原样保留。
- `image_sorter.py` 的增量缓存现在会在 state 里记录 `thresholds`（最小宽高）；阈值与上次不同就整体失效重扫，否则调严分辨率后没变化的目录会被一直跳过、新阈值对老图片永远不生效。
- 筛选实际删除文件时会往 `.image_sorter_deleted.log`（已 gitignore）追加一行（时间/阈值/路径）——删的是 NAS 上的原图，不可撤销，至少要能事后核对。
- GUI 的默认值统一引用 `run.DEFAULTS`（以前 GUI/CLI 各写一份，「清除壁纸缓存」勾选框失效就是这种漂移导致的）；配置文件缺失时用默认值初始化；数字框被清空时弹窗提示而不是抛 `TclError`。
- 杂项：`process_image.sh` 改用 `python3`；README 的 Python 版本要求改为 3.10+（代码用了 `str | Path` 注解）；清掉未使用的 import 和死代码（`get_image_info` 等），pyflakes 现在是干净的（没装，用 `pip install --target /tmp/pf pyflakes` 临时跑）。

### 11. 拾景（`desktop/`）特有的注意点
- 依赖 MyGo v0.8.x（0.x 阶段，小版本升级可能改 API）。升级前读 `desktop/.agents/skills/mygo-maintenance/SKILL.md`，用 `go tool mygo migrate-ui .` 预览迁移；改完跑 `go tool mygo vet .` 和 `CGO_ENABLED=0 go test ./...`。
- 配置、增量状态、删除日志、窗口位置都在 `~/Library/Application Support/拾景/`，不是仓库目录（`.app` 位置不固定，不能像 Python 版那样相对脚本目录找文件）。状态文件故意不和 Python 版共享。改名前叫「壁纸工具」，`main.go` 启动时会用 `core.MigrateDataDir` 把旧目录搬过来（新目录已存在就不动）。以后再改 `appName` 也要照此迁移，否则用户配置会"丢"。
- 窗口用 `TitleBarHiddenInset` + `VibrancySidebar`：侧边栏顶部和内容区顶部各留了一条 `DragWindow()` 的拖拽区，侧边栏背景透明才能透出毛玻璃（`c.Vibrancy()` 为 false 时退回纯色）。配色和通用组件（`panel`/`group`/`settingRow`/`sceneArt` 插画）集中在 `theme.go`。强调色是橙色（用户定的，v0.3.11 起：浅色 #E45C00、深色 #E56900），改的话 iOS 的 `Assets.xcassets/AccentColor` 要一起改；应用图标（`desktop/resources/icon.png` 和 iOS 的 `AppIcon.png`）v0.3.12 起也是橙色日落，是用 `desktop/scripts/recolor_icon.py` 从原来的紫色图标换算的；`make_icon.py` 是更早的画法，和现在的图标对不上。横幅插画（`sceneArt`）的颜色取自图标、用同一套换算。
- 概览页缩略图由 `thumbs.go` 的 `scanWallpapers` 在后台解码缩小，`Bitmap` 回主线程再建；只读本地 `dest_dir`，运行结束 `wallsGen++` 触发重读。缩略图网格的行列数由 `stripLayout` 按**上一帧**量到的尺寸算（网格宽度定列数，滚动区高度 − 页面其余部分高度定行数，后者与行数无关所以不会来回跳），算出来变了就 `c.AnimationFrame()` 再排一帧；概览页不受 `contentMax` 限制、铺满窗口宽度。先解码 `initialThumbs` 张，放得下更多时 `loadMoreThumbs` 接着解码网格前面还没解码的（`decodeWorkers` 限并发，原图很大）。壁纸列表只有一份 `walls.all`（`shuffleStable` 按文件名哈希排的顺序：看着随机，但不换一批时每次打开都一样，方便逐张筛——用户要求，别改回 `rand.Shuffle`；横幅图也在内），缩略图按路径存在 `walls.thumbs`（值为 nil 表示读不了），网格是 `walls.grid()`（去掉横幅图和读不了的）——别再加平行的切片，移出 / 撤销只需要改 `all`。网格最后一格「+N」在预览里从第一张没显示的开始翻；Finder 里打开用横幅上的「打开」。`app.scanWallpapers` 是注入的，测试里设成 nil，界面测试不读真实目录。
- 图片解码（v0.3.14 起）：`loadScaled` 先用 `decode_darwin.go` 的 `systemDecode`（用 purego 调 ImageIO 的 `CGImageSourceCreateThumbnailAtIndex`，读文件时就按目标尺寸解，按 EXIF 方向转正、转 sRGB），失败时退回 Go 的 image 解码。**不能用 cgo**：`mygo build` 默认 `CGO_ENABLED=0`，cgo 写的版本在测试里能跑、装好的应用里根本没编进去（踩过，`otool -L` 里看不到 ImageIO）。实测 8192×5464 的 JPEG：Go 解码 1.1–1.8 s，ImageIO 0.15–0.2 s。`TestSystemDecode` 检查尺寸和颜色。缩略图和横幅图另有磁盘缓存（`thumbcache.go`，数据目录 `thumbs/`，按路径 + 大小 + mtime + 宽度命名，每次读壁纸文件夹时删掉不属于这批的；`thumbCacheDir` 只在 `main.go` 里设，测试为空不缓存），首页第二次打开 ~13 ms。大图预览不进磁盘缓存：`pumpPreview` 同一时间只解一张（当前 → 下一张 → 上一张 → 下下张），`a.big` 只留这几张，关预览就清空——别改回「每翻一张开一个 goroutine」，按住空格时会十几张原图同时解码、内存暴涨。
- 「换上时间」和「上次运行」来自 `ui_state.json`（`uistate.go`），**不要**改用壁纸文件夹里文件的 mtime：复制时 `copyFile` 会用 `Chtimes` 保留原图的修改时间，那是原图的时间，不是换上的时间。命令行跑的不会写这个文件。
- v0.3.0 加的几样，改相关代码时注意：
  - **优先选没换上过的**（`prefer_unseen`）：`selection_history.json` 是这一轮轮换里换上过的原图路径集合；没换上过的不够一批时全部选上、差的从换上过的里补，并把历史重置成只有这一批（`NewCycle`）。只在复制完整跑完后写。`CopyResult.Rotated` / `Candidates` 是轮换进度。
  - **删除日志**每行 4 列（时间、阈值、路径、原因），旧日志只有 3 列，`core.ReadDeleteLog` 两种都认；不合格原因来自 `core.ImageVerdict`。筛选时每张不合格的图只打一行日志：真删「🔥 已删除: 名  (原因)」/「❌ 删除失败」，模拟「🗑️ 待删除: 名  (原因)」——界面 `parseLogLine` 按两个空格加括号拆出原因，`countDeletion` 数这些行。
  - **大图预览**按 `walls.all`（壁纸文件夹里全部图片，固定顺序）翻，不只是缩略图那几张；没缩略图的先显示「正在载入…」，后台 `pumpPreview` 解码（读不了显示「读不了这张图」）。图片框用 `fitBox` 按图片比例算尺寸（不留黑边），弹层四周留 `previewMargin`、没有别的上限，全屏时图跟着变大（大图按 `previewWidth` 解码）。鼠标滚轮 / 触控板也能翻页（`wheelStep`：滚轮一格一张，触控板攒够 `wheelPage` 才翻、惯性滚动不算，停顿 300 ms 清零）。快捷键可以自定义（侧边栏「快捷键」页，`keysview.go`）：可改的操作和默认值在 `shortcuts.go` 的 `keyActions`，配置 `Shortcuts` 只存改过的；`fixedKeys` 是不许占用的。菜单栏三项由 `a.setMenuKeys` 同步（录制时先撤掉，免得按 ⌘R 真的开始运行）。预览按键在 `previewKeys`，必须在 `Modal` 回调里调 `c.Shortcut`，外面收不到；回车被弹层里有焦点的按钮占着，不能当快捷键，所以预览打开时焦点放在图片上。预览默认是空格 / ⇧空格翻页（固定键，← → 是可改的那一套）、J K L 按轻重排移出 / 不再选 / 删除原图（用户定的，手不离主键区）。移出可以 ⌘Z 撤销（`undo.go`）：移出时文件挪进数据目录 `undo/` 暂存，撤销时挪回、放回原位置并去掉这次加的「不再选」；启动时和开始换一批前清空。⌘Z 要靠 `c.Shortcut(Cmd, KeyZ)` 注册了，「编辑」菜单的撤销才会亮、按键才传得到（MyGo 把没人接的编辑命令转成快捷键）；预览开着时在 Modal 里注册，关着时在 `view` 里。预览里数字键输入编号、回车跳转（`jumpKeys`，0–9 在 `fixedKeys` 里）；正在输入时 Esc 会先被 Modal 自己接走关掉预览，所以在 `previewModal` 里看到「刚被关掉且有编号」就重新打开、只清编号。新加可快捷操作时加进 `keyActions`，`TestDefaultShortcutsDoNotClash` 会检查默认值不冲突。「显示壁纸」（D）/「显示原图」（F）用注入的 `app.revealPath`（`Shell.ShowItemInFolder`，在 Finder 里选中文件），测试里记到 `opened`。三种操作的文案集中在 `preview.go` 的 `act*` 常量：「移出」只删壁纸文件夹里那份，「删除图库里的原图」才动原图——改文案时保持这个区分。
  - **缩略图 → 原图**：`last_selection.json` 里 `dests` 和 `sources` 一一对应，`core.WallpaperSources` 读成「壁纸文件名 → 原图」；旧版本换上的没有 `dests`，缩略图菜单里就不出现「不再选它 / 删除原图」。
  - **定时自动换**（`auto_run_hours`）：`main.go` 里每分钟 `maybeAutoRun`，从上次运行（没运行过从应用启动）开始计时；`startRunWith(true)` 会强制 `DeleteDuringFilter=false`，自动运行永远不删原图。
  - 图库统计、空间预估用 `a.lastGood`（最近一次成功运行，存在 `ui_state.json` 的 `last_success`），因为运行中 / 失败后 `a.last` 不是成功的结果。
- 页面分文件：`view.go` 只有窗口骨架和侧边栏，概览 / 图库 / 设置在 `overview.go` / `library.go` / `settings.go`。归档（v0.3.10 起）不再单独一页，是设置里的「归档」分组，开关打开后才显示位置和跨挂载点那几项；侧边栏是 概览、图库、设置、删除记录、快捷键、关于（⌘1–5）。侧边栏底部平时不显示东西，只在配置保存失败时出红字。`app` 的字段按用途收进嵌入的 `runStats`（运行进度和删除计数，开始运行时整体清零）、`previewState`、`keyRecorder`。
- 概览的摘要条只放状态（图库挂载、轮换进度、自动换的下一次——只在打开了定时自动换时出现、上次运行），画质这类纯设置不放；「会删原图」的提醒在横幅副标题里，点「换一批」时还有确认框。
- 页面宽度策略（`view.go`）：概览页铺满；其余页面按上一帧量到的内容区宽度 `a.viewW` 决定——`a.twoCol()`（内容区 ≥ `twoColMin`）时设置 / 图库用 `a.columns` 排成左右两栏、最宽 `twoColMax`，窄时单栏、最宽 `contentMax`；窗口更宽时都居中放；关于页始终单栏。新加设置分组时放进 `columns` 的左栏或右栏，注意两栏高度大致平衡。概览横幅图（`walls.heroPath`）也能点开预览，所以预览序号从横幅图算起。
- 「上次运行」的「新换 N 张 / 重合率」来自 `core.compareSelection`：按**原图路径**比（壁纸文件夹里的文件名会因重名被改写，不能拿来比），上一轮的选择存在数据目录的 `last_selection.json`（命令行也会写），没有记录（刚升级、换了壁纸文件夹）时，在清空壁纸文件夹**之前**读里面现有的文件名，按 `destName`（「上级文件夹-原名」）近似比较（`PrevByName`）。只在复制完整跑完后写，被停止的不算一轮。运行卡片上的删除计数是 `app.countDeletion` 从日志行里数的，改 `sorter.go` 的「待删除 / 已删除 / 删除失败」日志格式要同步改这里。
- 停止靠 `core.Reporter.Stop`：筛选在文件夹之间检查（没检查的目录不写进增量状态，否则下次会被当成"没变化"跳过）、清空壁纸目录前检查一次、复制时不再开始新任务；被停止返回 `core.ErrCanceled`。新加耗时步骤时记得在安全点检查它。
- 删除原图前的确认框是注入的 `app.confirmDelete`（测试里可以替换）；「不再提示」存在 `ui_state.json`，`view` 发现「删除不合格原图」被重新打开时恢复确认。
- 设置改动是**自动保存**的：每次 view 构建末尾 `autosave()` 拿 `buildConfig()` 和上次写盘的值做 `reflect.DeepEqual`，变了才写。新增配置字段时只要进 `core.Config` 就自动生效。
- 概览页的步骤条/进度条/结果卡片靠 `core.Reporter.Progress` 和 `RunPipeline` 返回的 `core.Summary`；改流程时记得同步上报，`TestRunPipelineEndToEnd` 会检查四个阶段都报到了。
- 界面状态只能在主线程改：后台 goroutine（目录选择框、流程运行）一律通过 `app.update`（= `Window.Update`）回到主线程。日志是攒批刷新的（80ms 一次），复制几百张图时不会每行触发一次重绘。
- 关窗不退出（`background.go`）：`win.OnClose` 里 `PreventDefault` + `Hide`，Dock 点击走 `App.OnActivate` 重新 `Show`。真正退出时 `App.Quit()` 也会经过 `OnClose`，所以 `OnBeforeQuit` 里要先置 `quitting = true` 放行，否则 Cmd+Q 会被吞掉变成"只隐藏"；任务运行中 Cmd+Q 先弹窗确认。Dock 角标由 `app.onRunState` 钩子驱动（测试里为 nil）。
- `resolvePath()` 必须像 Python 的 `Path.resolve(strict=False)` 那样解析"存在的那部分前缀"：macOS 上 `/var` → `/private/var`，只对完整路径 `EvalSymlinks` 的话，不存在的文件会退回未解析的路径，SMB→NFS 换算就会因前缀不匹配而静默失效（测试里踩过）。
- 与 Python 版的细微差异（都是有意的）：`filter_sources` 用解析后的路径比较（Python 版拿未解析的 source 去比解析后的集合，路径含软链接时会漏过滤）；重复添加同一个目录会被拒绝（列表用路径当 key）；删除失败只记日志继续，不像 Python 版直接抛异常中断。
- 界面测试用 `ui.NewTester` 无窗口跑；按标签找输入框要用 `AccessByRole`（`Access(...)` 会先命中 Field 的标签文字），文本框是 `RoleTextField`，`NumberInput` 在无障碍树里是 `RoleGroup`。
- MyGo 的 `Row` 默认把子元素**垂直居中**，要撑满高度得显式 `.AlignItems(ui.Stretch)`；`Segmented` 默认拉满整行宽度，想按内容宽度就包一层 `Row`。看布局最快的办法是写个临时测试用 `NewTesterWith(..., TesterOptions{Dark: ...})` 渲染 `tt.Image()` 存 PNG，比启动应用截图快得多。
- README 截图（`docs/screenshots/`）由 `desktop/screenshots_test.go` 用无窗口 Tester 渲染：程序画的示意风景图当壁纸、演示用的目录和日志，2 倍缩放后再画上圆角和红绿灯。**不要用真实壁纸/真实 NAS 路径截图**。界面改了就设 `SHOTS_DIR` 重跑一遍。
- `mygo build` 生成的 dmg 文件名是应用名的拼音（`shi-jing-*.dmg`），这是正常的。

### 12. 慢的根源是 SMB 往返延迟，不是计算量；拾景对 NAS 的 I/O 已并发化
2026-11 实测（只读剖析：模拟筛选、复制到临时目录、不归档；约 2.9 万个文件、475 个图片目录，`sample_count` 400 ≈ 6.2 GB）：

| 阶段 | 串行（冷缓存） | 并发后 |
|---|---|---|
| 筛选：增量判断 `dirMtime`（每个文件一次 lstat） | ~28 s | ~8.6 s |
| 扫描：「仅采样目录」Fav 的分辨率检查（逐张打开 1219 张图读文件头） | ~25 s | ~0.6 s |
| 复制 400 张 | ~82 s（58–75 MB/s） | ~53 s（4 路 107、8 路 121 MB/s） |

- SMB 元数据缓存热的时候 walk/lstat 都只要几毫秒，冷的时候约 1ms/文件，所以同一操作两次计时能差几十倍——**剖析一定要区分冷/热**，别拿第二次跑的数字下结论。纯 `walk`（只 readdir）冷缓存全库也就 ~2.6 s，慢的是逐文件 lstat 和打开文件。
- 做法（`core/imageutil.go` 的 `parallelFor` / `checkResolutions`，`metaWorkers=8`、`copyWorkers=6`）：只把网络 I/O 并发，结果按下标写回、之后按原顺序串行组装，删除和日志顺序不变，采样结果与串行版完全一致。
- 并发复制前，目标名/归档名在 `planCopies` 里**串行一次分配完**（`generateFilename` 的 `taken` 集合），否则两张同名图片会同时看到"磁盘上还没有"而写到同一个文件。
- 调用方给的 `Reporter` 回调不保证并发安全，并发段里用 `rep.synced()` 加锁。
- 2026-11-09 第二轮：没有改动时「筛选」仍要 30 多秒，剖析发现大头是**串行递归 readdir**（冷缓存每次 ~42 ms，484 个文件夹 ~20 s），扫描阶段又整库遍历一遍（~8.7 s）。`walk` 改成并发读目录（`metaWorkers` 个并发，回调仍在调用方 goroutine 里按先序顺序逐个调用，`TestWalkOrderMatchesSerial` 保证顺序不变）；筛选不再等所有 `dirMtime` 算完再统一判断，而是后台并发算、主循环按顺序算好一个判断一个，进度「筛选 i / N 个文件夹」和「已跳过」日志随之逐个前进。遍历阶段上报 `Progress(stage, 已找到的文件夹数, 0)`（total 为 0），界面显示「已找到 N 个文件夹」。同样冷到半冷的缓存下，筛选 + 扫描从 ~36 s 降到 ~14 s，热缓存 <0.5 s。
- 后台算 mtime 的 worker 不调 `Reporter.Stop`（调用方的 Stop 不一定并发安全，测试里就是裸变量），停止时由主循环置内部的 `abandon` 标志。
- 已归档的 Python 版没有做并发化。

### 13. 「清除壁纸缓存」从来没生效过；文件夹轮换要靠重启 WallpaperAgent
2026-11-09 实测（macOS 27.2，系统设置里壁纸选 `~/Pictures/Wallpapers0` 文件夹、每分钟随机切换）：
- 以前删的是 `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image`。这个容器目录受系统保护，读都读不了（Permission denied），`os.RemoveAll` 失败，但旧代码忽略了错误，日志照样写「已清除」——目录 mtime 一直早于运行时间，证明从没删掉过。
- 壁纸设置存在 `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`，里面只记了 `{'type': 'imageFolder', 'url': ...}`，没有文件列表；轮换由 `WallpaperImageExtension` 进程自己读文件夹。换一批之后用 `lsof -Fn -p <pid>` 看它打开的文件：3 个屏幕里 2 个停在已经被删掉的旧图上，「每分钟」设置下 2 分多钟都没动；`killall WallpaperAgent` 后 launchd 立刻重新拉起 agent 和扩展，几秒内打开的全是新一批的图。
- 所以现在流程最后一步是 `core.RefreshWallpaper`（`killall WallpaperAgent`），配置 JSON 键仍叫 `clear_wallpaper_cache` 兼容老配置，`wallpaper_cache_path` 已删除。测试里 `TestMain` 把它换成空函数，**别让测试真的重启壁纸服务**。
- 查 lsof 的坑：lsof 输出里中文路径是 `\xe7..` 转义的，要先 `codecs.escape_decode` 再判断文件是否存在；这台机器的 `ls` 是 eza，`ls -i` 输出格式不同，别拿它比 inode。

### 14. 手机遥控（iOS 端，v0.3.6 起）
- 桌面端 `desktop/remote.go`：设置里打开 `remote_enabled` 才监听（默认端口 52819，被占用时随机），Bonjour 用系统的 `dns-sd -R` 广播 `_shijing._tcp`（走 mDNSResponder，比纯 Go 的 mDNS 库可靠）。dns-sd 外面包了一层 `sh … & read _; kill`，拾景的 stdin 管道一断（包括崩溃）它就退出；退出应用时 `OnBeforeQuit` 里也会 `remote.stop()`。
- 读状态的请求读主线程发布的快照（`publishRemote`：每帧 view 末尾、以及 `main.go` 里包了一层的 `a.update` 之后），不等主线程；要改状态的（运行、停止）走 `remoteServer.onMain`，**它在 fn 之后先 `publishRemote` 再放行**，否则响应里带的是旧快照（踩过）。
- 遥控运行前在后台重新 `probeMount` 一遍图库目录：桌面的挂载状态只在启动 / 导入配置时查，NAS 后挂上的话 `canRun` 一直是 false。
- 遥控运行不弹桌面的删除确认框（Mac 前面可能没人），由手机先确认，`/api/run {"delete": false}` 时这次 `noDelete`，不改设置。日志里记一行「📱 由「xx」遥控运行」。
- 配对：`/api/pair/start` 生成 6 位码在桌面弹层显示（`pairModal`，按 `pairCode` 判断是不是新请求，点拒绝后不会被下一帧重新打开），2 分钟有效、输错 5 次作废；令牌只存 SHA-256（`remote_devices.json`，0600）。同名手机重新配对会替换旧记录。
- iOS 端在 `ios/`（SwiftUI，iOS 17+，XcodeGen 的 `project.yml` 生成工程）。用户没有付费开发者账号：免费签名 7 天过期、没有 APNs 推送；不上架。版本号和桌面端同步，见「版本号规则」。
- 本机装了 Xcode（`/Applications/Xcode-27.2.0.app`，2026-11-11），但 `xcode-select` 仍指向命令行工具（切换要用户输密码）：命令行里用 `DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer` 前缀跑 `xcodebuild` / `xcrun`。模拟器 MCP 工具只认 `xcode-select`，没切换前用不了，用 `xcrun simctl` 装、启动、截图代替。
- 真机安装：团队 ID 在 gitignore 的 `ios/ShiJing/Local.xcconfig`（由 `Signing.xcconfig` 的 `#include?` 引用），**不要写进 `project.yml` 或提交的工程文件**——仓库公开。用户 Xcode 里选 Team 后工程文件会出现 `DEVELOPMENT_TEAM`，挪到 Local.xcconfig 再 `xcodegen`。构建 `-destination 'generic/platform=iOS' -allowProvisioningUpdates`，`xcrun devicectl device install app` / `process launch` 装到手机（命令见 `ios/README.md`）。免费签名 7 天过期，过期了重新构建安装即可。
- 看 iOS 布局不用配对：Debug 构建带启动参数 `-demo`（空闲 + 上次运行）或 `-demoRunning`（运行中）会显示一份假状态（`RemoteSession.demo`），`xcrun simctl launch booted com.love1017best.shijing.ios -demo` 后 `xcrun simctl io booted screenshot` 截图。
- iPhone Duo（折叠屏，iPhone19,4）有模拟器：机型 `iPhone Duo`，用它自己的运行时 `iOS-27-2-iPhone19-4`。两块屏截图要指定 `--display`：内屏（展开）`--display=3`，外屏（合上）`--display=1`。切换展开 / 合上用 Device Hub 窗口底部的 Closed / Partially Open / Open 按钮（`com.apple.dt.Devices`，命令行没有接口）；**别用 `simctl io … screenConfig power off` 关屏**，会把 SpringBoard 弄崩、要重启模拟器。内屏展开后是横向的，侧边有传感器区占安全区：大图预览因此不用 `TabView(.page)`（它按扣掉安全区的宽度分页，会露出下一张）。
- 大图预览（`ios/ShiJing/WallPreview.swift`）的翻页是自己写的：只摆上一张 / 当前 / 下一张三页，首尾相接（和桌面一样）；一次拖动开头判断方向——横向翻页、往下关闭、放大后平移，双指缩放以手指位置为中心。屏幕横着（内屏、手机横放）默认铺满，裁掉超过三成才完整显示；竖着一律完整显示，并让开顶栏底栏（`fitInsets`）。双击在铺满 / 完整之间切换（放大时双击还原）。底部缩略图条（`FilmStrip`）拖动时大图跟着换，按屏幕正中对齐（内屏侧边的传感器区会让这条变窄，不能用它自己的正中）；点顶部编号输入数字跳转，「全部壁纸」页的缩略图标着同样的编号。`-demoPreview` 启动参数直接打开大图预览；Device Hub 里用鼠标没法双指缩放，只能真机试。
- iOS 的开发语言必须是 `zh-Hans`（`project.yml` 的 `developmentLanguage`）：App 没有中文本地化时 `Locale.current` 会退回英文，日期、系统按钮都显示成英文（踩过）。
- 「附近的 Mac」只在有界面显示它时才用 Bonjour 搜索（`Discovery.want(名字, 开关)`）：一台都没配对时侧栏直接显示，配对过之后只在「添加其他 Mac」弹层里搜。
- 本机没装完整 Xcode 时，Swift 代码用命令行工具在 macOS SDK 上类型检查（命令见 `ios/README.md`）；必须用 `MacOSX26.5.sdk`，27.x 的 SwiftUI `@State` 是宏、命令行工具缺宏插件。iOS 专有修饰符包在 `PairView.swift` 底部的 `iOSKeyboard` / `iOSInlineTitle` 等扩展里。
- 两边 JSON 对接验证过的方法：写个临时的 Go 测试用 `newRemoteHarness` 起服务并把地址和令牌写到文件，再用 `swiftc Models.swift APIClient.swift main.swift` 编一个命令行客户端去连。时间字段一律用 Unix 秒（Go 的 RFC3339 纳秒精度 Swift 解析不稳）。

### 15. 横竖屏要按 EXIF 方向判断（v0.3.18）
不少照片是「像素横着存 + EXIF Orientation 标记转 90°」：像素 6240×4160，系统壁纸、Finder、预览里显示的却是 4160×6240 的竖图（例：`[织梦映像]NO.098 …/0163.jpg`，Orientation=8）。以前 `ImageVerdict` 只看 `image.DecodeConfig` 的像素宽高，这种竖图被当成横屏选进壁纸。现在先用 `core/orientation.go` 的 `exifOrientation`（纯 Go，只读 JPEG 的 APP1 / TIFF 的 IFD0）读方向，5–8 时宽高互换再判断。2026-11 只读统计：全库 27464 张里有 287 张因此从合格变成竖屏。
- `sips -g orientation` 对这张图报 `<nil>`，但 PIL 的 `getexif()[274]` 是 8——**查方向别信 sips**，用 PIL 或 `exifOrientation`。
- 「仅采样目录」采样时走同一个 `ImageVerdict`（`scanImages` → `checkResolutions`）。「筛选并采样目录」只有真删时才干净：只模拟、定时自动换、手机「只模拟」都不删原图，以前不合格的图留在图库里、采样时又不查，竖图照样会被选进壁纸（增量模式还会把目录记成查过、以后一直跳过）。现在筛选把「不合格但没删」的图记进增量状态的 `rejected`（按目录），跳过的目录也带上，经 `SortResult.Remaining` → `CopyOptions.Rejected` 在采样时排除。`TestSimulatedFilterNeverSamplesRejected` 盖住了这条。
- 判断逻辑改了要把 `sorter.go` 的 `verdictRules` 加 1：它记在增量状态的 `thresholds.rules` 里，不一样就整体重扫，否则以前判过、之后没动过的目录会一直被跳过，新规则永远不生效。

## 两个会话并行开发（2026-11-11 起）

macOS 端和 iOS 端分别由不同的会话负责，**两个会话共用同一个工作区**（同一个 checkout、都在 `main` 上，没有各自的 worktree）。所以：

- **只提交自己改的文件**：`git add <具体路径>` / `git commit -- <路径>`，**不要 `git add -A`、`git commit -a`**，否则会把另一个会话写到一半的文件一起提交。提交前 `git status` 看一眼，不认识的改动别碰、别还原、别 `git stash`。
- 接口两边对应（`desktop/remote.go` ↔ `ios/ShiJing/Models.swift` / `APIClient.swift`）：改了一边要同步另一边。另一边归对方会话管时，在提交说明里写清楚，或者告诉用户请对方会话跟进。
- **构建、安装、发布只用这三个脚本**，它们共用一把锁（`desktop/scripts/lock.zsh`，锁文件在 `.git/shijing-build.lock`），两个会话同时跑时后来的会排队等，不会抢 `build/` 目录、同时替换 `/Applications/拾景.app` 或撞版本号：
  - `desktop/scripts/install-local.sh`：构建 macOS 并装到 `/Applications`、启动；连着 iPhone / iPad 时再构建 iOS 装到设备上并启动。**哪一端改了都跑它**，两端都会重新安装运行（iOS 会话也一样，不要只装手机）。
  - `desktop/scripts/install-ios-device.sh`：只装手机，`install-local.sh` 会自动调，一般不单独用。
  - `desktop/scripts/release.sh`：发布，见下面「发布规则」。
- 不要手动走发布步骤、不要手动 `bump-version.sh`、不要手动打 tag。

## 版本号规则（用户规定）

- 格式 `vX.Y.Z`（如 `v0.2.101`），写在 `desktop/mygo.json` 的 `version`（那里不带 `v`，macOS 的 Info.plist 只认数字）。
- **macOS 和 iOS 两端永远用同一个版本号，每次发布两端一起发，不管哪一端有没有改动**（用户规定，2026-11-11）。
  - 版本号由 `release.sh` 调 `bump-version.sh` 升：同时改 `desktop/mygo.json`、`ios/project.yml` 的 `MARKETING_VERSION`（= 版本号）和 `CURRENT_PROJECT_VERSION`（= Z），并重新生成 Xcode 工程。功能提交里不要升版本号。
  - `desktop/version_test.go` 检查这几处一致，`go test ./...` 会挡住只改了一端的情况。
- `X.Y` 是大版本号，**只有用户明确要求大迭代时才提升**，不要自己改（`bump-version.sh 0.4.0` 这种只在用户要求时用）。
- `Z`：有代码改动、要给用户用的构建都走 `release.sh`，它会先把 Z 加 1。自己调试时用 `install-local.sh` 装的预览不升版本；改完要交给用户试的，发布一个新版本。
- 起点：v0.2.100。

## 发布规则（用户规定）

- **只用 `desktop/scripts/release.sh` 发布**（两个会话都是）：
  ```bash
  desktop/scripts/release.sh --macos "- 这一版 macOS 的改动" --ios "- iOS 的改动"
  ```
  某一端没改就不传，说明里自动写「无改动，仅同步版本号」；`--dry-run` 只检查和构建、不推送不发布。它会：
  1. 拿锁；检查暂存区是空的、版本号文件没有没提交的改动（**先把自己的改动提交好**；工作区里别人没提交的文件不碰、也不会被打包进去）。
  2. 和 `origin/main` 同步（快进；本地有没推送的提交时 rebase，这时要求工作区干净）。
  3. 在临时 worktree 里升 Z、跑 `go test`、只提交版本号文件、打 tag `v<版本>`，`git push --atomic origin HEAD:main v<版本>` 一次推送提交和 tag（**不要 `git push --tags`**：本地还有旧历史的 tag `python-final`、`v0.2.104`、`v0.2.105` 和 `legacy` 远端，会把旧历史推到公开仓库）。另一个会话抢先发布了同一个版本号时推送会被拒，自动同步后重来。本地 `main` 再快进到这个提交。
  4. 还在那个 worktree 里构建两个 dmg（通用版 `shi-jing-<版本>.dmg`、Apple Silicon 版 `shi-jing-<版本>-arm64.dmg`），跑 iOS 模拟器构建检查——发布包严格等于 tag 的内容。
  5. `gh release create`（两个 dmg 都传，说明分「macOS」「iOS」两节，开头写清两个包怎么选，结尾注明 ad-hoc 签名、未公证），然后用刚发布的 arm64 dmg 装到 `/Applications` 并启动，连着手机时把同一个 tag 的 iOS 版也装上。
- iOS 端没有上架、也不传安装包（免费签名的包只能装到签名者自己的设备上）：Release 里只说明 iOS 源码在 `ios/`、按 `ios/README.md` 自己用 Xcode 装。
- 仓库是**公开**的（2026-11-10 起），提交前注意别放进个人信息、真实壁纸或密钥（签名团队 ID 只放在 gitignore 的 `ios/ShiJing/Local.xcconfig`，`release.sh` 会把它拷进临时 worktree）。
- **不要直接运行 `build/` 下的 `.app`**（用户规定），预览、试用也一样，任何时候都不 `open build/...app`；一律用 `install-local.sh` 装到 `/Applications` 再启动。
- **连着 iPhone / iPad 时，每次构建都要顺带把 iOS 版装上去**（用户规定，2026-11-11；没连就算了）：`install-local.sh` 最后自动调 `install-ios-device.sh`，用 `devicectl list devices --json-output` 找连着的真机（模拟器不算），有就构建、安装并启动，一台都没有就跳过；iOS 失败只提示，不影响 macOS 的退出码。设备锁屏或没信任这台电脑时安装会失败，提示用户解锁就行。免费签名 7 天过期，重新跑一次就续上。
- 预览只需要 arm64；通用版只在发布时构建。`.app` 是 dmg 的中间产物，`mygo build` 省不掉它。

## 调试小抄

- 这台机器的 shell 里 `cp` / `rm` 是交互式别名（会问 overwrite?/remove?，非交互环境下默认 n，静默不生效）：脚本里用 `command cp -f` / `command rm -f`
- `ps aux | grep 拾景` 找不到进程（`ps` 会把中文路径转义成 `M-f…` 字节），查应用是否在运行用 `lsappinfo list | grep -A6 com.love1017best.shijing`

- 确认某个 `/Volumes/xxx` 到底是什么协议挂载的：`mount | grep xxx`
- 确认 NAS 是否开了 NFS：`nc -zv <nas_ip> 2049`（能连不代表一定能挂载/建硬链接，还要看 NAS 端导出配置）
- 怀疑某个文件的 `st_flags` 导致复制报错：`python3 -c "import os; print(os.stat(path).st_flags)"`，`65536` 就是 `SF_ARCHIVED`
