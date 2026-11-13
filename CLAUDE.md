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
- 概览页缩略图由 `thumbs.go` 的 `scanWallpapers` 在后台解码缩小，`Bitmap` 回主线程再建；只读本地 `dest_dir`，运行结束 `wallsGen++` 触发重读。缩略图网格的行列数由 `stripLayout` 按**上一帧**量到的尺寸算（网格宽度定列数，滚动区高度 − 页面其余部分高度定行数，后者与行数无关所以不会来回跳），算出来变了就 `c.AnimationFrame()` 再排一帧；概览页不受 `contentMax` 限制、铺满窗口宽度。先解码 `initialThumbs` 张，放得下更多时 `loadMoreThumbs` 接着解码网格前面还没解码的（`decodeWorkers` 限并发，原图很大）。壁纸列表只有一份 `walls.all`（`shuffleStable` 按文件名哈希排的顺序：看着随机，但不换一批时每次打开都一样，方便逐张筛——用户要求，别改回 `rand.Shuffle`；横幅图也在内），缩略图按路径存在 `walls.thumbs`（值为 nil 表示读不了），网格是 `walls.grid()`（去掉横幅图和读不了的）——别再加平行的切片，移出 / 撤销只需要改 `all`。移出 / 删除的正好是横幅那张时，`dropWall` 会清掉 `hero` / `heroPath` 并推进 `wallsGen` 让后台重读一遍挑新的横幅图（手机遥控删的也走这条路径，只改 `all` 的话横幅会一直显示那张已经不在文件夹里的图）。网格最后一格「+N」在预览里从第一张没显示的开始翻；Finder 里打开用横幅上的「打开」。`app.scanWallpapers` 是注入的，测试里设成 nil，界面测试不读真实目录。
- 图片解码（v0.3.14 起）：`loadScaled` 先用 `decode_darwin.go` 的 `systemDecode`（用 purego 调 ImageIO 的 `CGImageSourceCreateThumbnailAtIndex`，读文件时就按目标尺寸解，按 EXIF 方向转正、转 sRGB），失败时退回 Go 的 image 解码。**不能用 cgo**：`mygo build` 默认 `CGO_ENABLED=0`，cgo 写的版本在测试里能跑、装好的应用里根本没编进去（踩过，`otool -L` 里看不到 ImageIO）。实测 8192×5464 的 JPEG：Go 解码 1.1–1.8 s，ImageIO 0.15–0.2 s。`TestSystemDecode` 检查尺寸和颜色。缩略图和横幅图另有磁盘缓存（`thumbcache.go`，数据目录 `thumbs/`，按路径 + 大小 + mtime + 宽度命名，每次读壁纸文件夹时删掉不属于这批的；`thumbCacheDir` 只在 `main.go` 里设，测试为空不缓存），首页第二次打开 ~13 ms。大图预览不进磁盘缓存：`pumpPreview` 同一时间只解一张（当前 → 下一张 → 上一张 → 下下张），`a.big` 只留这几张，关预览就清空——别改回「每翻一张开一个 goroutine」，按住空格时会十几张原图同时解码、内存暴涨。
- 「换上时间」和「上次运行」来自 `ui_state.json`（`uistate.go`），**不要**改用壁纸文件夹里文件的 mtime：复制时 `copyFile` 会用 `Chtimes` 保留原图的修改时间，那是原图的时间，不是换上的时间。命令行跑的不会写这个文件。
- v0.3.0 加的几样，改相关代码时注意：
  - **优先选没换上过的**（`prefer_unseen`）：`selection_history.json` 是这一轮轮换里换上过的原图路径集合；没换上过的不够一批时全部选上、差的从换上过的里补，并把历史重置成只有这一批（`NewCycle`）。只在复制完整跑完后写。`CopyResult.Rotated` / `Candidates` 是轮换进度。
  - **删除日志**每行 4 列（时间、阈值、路径、原因），旧日志只有 3 列，`core.ReadDeleteLog` 两种都认；不合格原因来自 `core.ImageVerdict`。筛选时每张不合格的图只打一行日志：真删「🔥 已删除: 名  (原因)」/「❌ 删除失败」，模拟「🗑️ 待删除: 名  (原因)」——界面 `parseLogLine` 按两个空格加括号拆出原因，`countDeletion` 数这些行。
  - **大图预览**按 `walls.all`（壁纸文件夹里全部图片，固定顺序）翻，不只是缩略图那几张；没缩略图的先显示「正在载入…」，后台 `pumpPreview` 解码（读不了显示「读不了这张图」）。图片框用 `fitBox` 按图片比例算尺寸（不留黑边），弹层四周留 `previewMargin`、没有别的上限，全屏时图跟着变大（大图按 `previewWidth` 解码）。鼠标滚轮 / 触控板也能翻页（`wheelStep`：滚轮一格一张，触控板攒够 `wheelPage` 才翻、惯性滚动不算，停顿 300 ms 清零）。快捷键可以自定义（侧边栏「快捷键」页，`keysview.go`）：可改的操作和默认值在 `shortcuts.go` 的 `keyActions`，配置 `Shortcuts` 只存改过的；`fixedKeys` 是不许占用的。菜单栏三项由 `a.setMenuKeys` 同步（录制时先撤掉，免得按 ⌘R 真的开始运行）。预览按键在 `previewKeys`，必须在 `Modal` 回调里调 `c.Shortcut`，外面收不到；回车被弹层里有焦点的按钮占着，不能当快捷键，所以预览打开时焦点放在图片上。预览默认是空格 / ⇧空格翻页（固定键，← → 是可改的那一套）、J K L 按轻重排移出 / 不再选 / 删除原图（用户定的，手不离主键区）。移出可以 ⌘Z 撤销（`undo.go`）：移出时文件挪进数据目录 `undo/` 暂存，撤销时挪回、放回原位置并去掉这次加的「不再选」；启动时和开始换一批前清空。⌘Z 要靠 `c.Shortcut(Cmd, KeyZ)` 注册了，「编辑」菜单的撤销才会亮、按键才传得到（MyGo 把没人接的编辑命令转成快捷键）；预览开着时在 Modal 里注册，关着时在 `view` 里。预览里数字键输入编号、回车跳转（`jumpKeys`，0–9 在 `fixedKeys` 里）；正在输入时 Esc 会先被 Modal 自己接走关掉预览，所以在 `previewModal` 里看到「刚被关掉且有编号」就重新打开、只清编号。新加可快捷操作时加进 `keyActions`，`TestDefaultShortcutsDoNotClash` 会检查默认值不冲突。「显示壁纸」（D）/「显示原图」（F）用注入的 `app.revealPath`（`Shell.ShowItemInFolder`，在 Finder 里选中文件），测试里记到 `opened`。三种操作的文案集中在 `preview.go` 的 `act*` 常量：「移出」只删壁纸文件夹里那份，「删除图库里的原图」才动原图——改文案时保持这个区分。
  - **删除记录**分「筛选删除 / 手动删除」两类计数：手动删除（预览、右键菜单、手机）在日志里的原因固定是 `core.ReasonManual`（「手动删除」），其余（含没有原因的旧日志）都算筛选删的，`core.CountDeletions` 统一算；`/api/deletions` 带 `filter` / `manual`，iOS 的 `DeletionList` 对应两个可选字段。
  - **缩略图 → 原图**：`last_selection.json` 里 `dests` 和 `sources` 一一对应，`core.WallpaperSources` 读成「壁纸文件名 → 原图」；旧版本换上的没有 `dests`，缩略图菜单里就不出现「不再选它 / 删除原图」。
  - **定时自动换**（`auto_run_hours`）：`main.go` 里每分钟 `maybeAutoRun`，从上次运行（没运行过从应用启动）开始计时；`startRunWith(true)` 会强制 `DeleteDuringFilter=false`，自动运行永远不删原图。
  - 图库统计、空间预估用 `a.lastGood`（最近一次成功运行，存在 `ui_state.json` 的 `last_success`），因为运行中 / 失败后 `a.last` 不是成功的结果。
- 页面分文件：`view.go` 只有窗口骨架和侧边栏，概览 / 壁纸 / 图库 / 设置在 `overview.go` / `wallsview.go` / `library.go` / `settings.go`。归档（v0.3.10 起）不再单独一页，是设置里的「归档」分组，开关打开后才显示位置和跨挂载点那几项；侧边栏是 概览、壁纸、图库、设置、删除记录、快捷键、关于（⌘1–5 仍是图库及以下那几页，壁纸页只从侧边栏 / 概览「+N」/ 菜单进）。侧边栏底部平时不显示东西，只在配置保存失败时出红字。`app` 的字段按用途收进嵌入的 `runStats`（运行进度和删除计数，开始运行时整体清零）、`previewState`、`keyRecorder`。
- 「壁纸」页（v0.3.137 起，`wallsview.go`）和手机的「全部壁纸」页对齐：按文件名搜索（`SearchField`，不区分大小写）+ 按原图目录筛选（`MenuButton`）。目录标签 `wallFolderOf` 和 iOS 的 `folderName` 同一套算法：路径去掉 `/Volumes/<卷名>` 后最多留两级（取最后两级），没有原图记录的归「未记录原图」一组。格子里的缩略图是单独的一套 `walls.browse`（`browseThumbWidth` 240），每次后台解 `browseBatch` 张、解完触发重绘再补下一批——概览那套 360 宽的几百张一起会占近百 MB；`pruneThumbCache` 的保留集合里必须带着这一档宽度，否则每次重读壁纸文件夹都会被删掉。格子编号按 `all` 的完整顺序（筛选后不变，和大图预览、数字键跳转对得上）。概览缩略图最后一格「+N」现在打开壁纸页（不再直接开预览），换完一批仍由 `wallsGen` 触发重读。大图预览的 `previewModal` 挪到了 `view.go`（每帧对所有页面调一次），壁纸页和其他页面都能开预览；`pendingModal` 仍在概览。
  - 网格用 `ui.GridView(c, &a.wallGrid, len(list), browseMinCol, cellH, ...)`，只构建看得见的行（几百张也不会每帧把所有格子排一遍）。它的高度 = 上一帧量到的 `viewH - wallHeadH - wallBarH - 页边距`（`wallHeadH` / `wallBarH` 是标题+筛选条、底部操作条上一帧的 `LayoutBounds().H`），行高按上一帧的 `viewW` 算列数后反推，和 GridView 内部算法一致；筛选条件变了（`wallFilterKey`）就 `wallGrid.ScrollTo(0, ui.Start)`。
  - 多选（v0.3.138 起）：`wallSelecting` + `wallSel`（按路径），选择模式下点格子是勾选、`wallsMenu` 里也有「批量选择…」；操作条是 全选（只选当前筛选出来的）/ 取消 / 移出 N / 不再选 N，批量走 `removeSelectedWalls`，每张各推一条撤销（⌘Z 一次撤回一张），**不做批量删除原图**。离开页面（`view.go`）、换了一批（`loadWallpapers`）都会 `endWallSelection`，`pruneWallSel` 清掉已经不在文件夹里的勾选。
- 概览的摘要条只放状态（图库挂载、轮换进度、自动换的下一次——只在打开了定时自动换时出现、上次运行），画质这类纯设置不放；「会删原图」的提醒在横幅副标题里，点「换一批」时还有确认框。
- 页面宽度策略（`view.go`）：概览页和壁纸页铺满；其余页面按上一帧量到的内容区宽度 `a.viewW` 决定——`a.twoCol()`（内容区 ≥ `twoColMin`）时设置 / 图库用 `a.columns` 排成左右两栏、最宽 `twoColMax`，窄时单栏、最宽 `contentMax`；窗口更宽时都居中放；关于页始终单栏。新加设置分组时放进 `columns` 的左栏或右栏，注意两栏高度大致平衡。概览横幅图（`walls.heroPath`）也能点开预览，所以预览序号从横幅图算起。
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
- 第 2 期（v0.3.16 起，`desktop/remotewalls.go`）：`GET /api/wallpapers`（`rev` + 文件名和原图路径）、`/api/wallpapers/{name}/thumb`（和桌面缩略图同宽，走磁盘缓存）、`/image`（2048 宽，不缓存，`decodeSem` 限 2 张并发）、`POST …/remove {"exclude"}` 和 `…/delete`。壁纸列表随状态快照发布（`publishWalls`），状态里的 `walls_rev` 变了手机才重新拉列表。操作在主线程调桌面现成的 `removeWallpaper` / `deleteOriginal`（桌面照样能 ⌘Z 撤销移出），临时换掉 `a.showErr` 把错误带回手机；运行中一律拒绝（「正在换壁纸，等换完再整理」）。
- 看 iOS 布局不用配对：Debug 构建带启动参数 `-demo`（空闲 + 上次运行）或 `-demoRunning`（运行中）会显示一份假状态（`RemoteSession.demo`），`xcrun simctl launch booted com.love1017best.shijing.ios -demo` 后 `xcrun simctl io booted screenshot` 截图。`-demoAll` 直接打开「全部壁纸」页看网格。
- **模拟器验证范围（用户规定，2026-11-11）**：小版本只验 iPhone Duo 的内屏、外屏各自的横竖屏（共四种）；普通竖屏 iPhone 和 iPad 的横竖屏只在用户明确要求时临时验一次，验完 `xcrun simctl shutdown`（多开模拟器太占内存）。
- iPhone Duo（折叠屏，iPhone19,4）有模拟器：机型 `iPhone Duo`，用它自己的运行时 `iOS-27-2-iPhone19-4`。两块屏截图要指定 `--display`：内屏（展开）`--display=3`，外屏（合上）`--display=1`。切换展开 / 合上用 Device Hub 窗口底部的 Closed / Partially Open / Open 按钮（`com.apple.dt.Devices`，命令行没有接口）；**别用 `simctl io … screenConfig power off` 关屏**，会把 SpringBoard 弄崩、要重启模拟器。内屏展开后是横向的，侧边有传感器区占安全区：大图预览因此不用 `TabView(.page)`（它按扣掉安全区的宽度分页，会露出下一张）。
- 大图预览（`ios/ShiJing/WallPreview.swift`）的翻页是自己写的：只摆上一张 / 当前 / 下一张三页，首尾相接（和桌面一样）；一次拖动开头判断方向——横向翻页、上下滑（`Axis.levels`，在几级之间上下移动）、往下关闭、放大后平移，双指缩放以手指位置为中心。上下滑分两级（用户要求，v0.3.112；v0.3.108 时是一下滑直接全屏，用户嫌收列表时缩略图条也跟着没了）：上滑一次拉出底部操作列表（`panel = true`，`chrome` 仍为 true，顶栏和缩略图条都在），列表再上滑才进全屏（`panel = false`、`chrome = false`，全藏起来）；全屏下滑回常态（`chrome = true`、`panel = false`），列表下滑也是回常态（缩略图条不消失），常态（`chrome && !panel`）下滑才是关闭预览。一次滑动只走一级。列表的把手点一下也能开关（VoiceOver 用）。点一下图片藏起顶栏底栏时**不动 `panel`**（再点回来列表还是开的，v0.3.118 修）；关预览时把列表开合状态记进 UserDefaults（`previewPanelOpen`），下次打开沿用。`-demoPanel` / `-demoFullscreen` 启动参数直接打开列表 / 全屏看排版。底部的四个操作按钮用 `ViewThatFits(in: .horizontal)` 三档自适应（宽度够时分成左右两组——左边「存到相册 / 移出」、右边「不再选它 / 删除原图」，挤了小号一排，再挤成工具栏式四列、图标在上小字在下），竖屏时不再竖排四行占掉一大块高度。屏幕横着（内屏、手机横放）默认铺满，裁掉超过三成才完整显示；竖着一律完整显示，并让开顶栏底栏（`fitInsets`）。双击在铺满 / 完整之间切换（放大时双击还原）。底部缩略图条（`FilmStrip`）拖动时大图跟着换，按屏幕正中对齐（内屏侧边的传感器区会让这条变窄，不能用它自己的正中）；点顶部编号输入数字跳转，「全部壁纸」页的缩略图标着同样的编号。`-demoPreview` 启动参数直接打开大图预览；Device Hub 里用鼠标没法双指缩放，只能真机试。
- 预览的视觉（v0.3.122 起，用户要求照 X 的感觉）：图片上下留白（竖屏看横图）不再是一块黑，垫一层当前这张缩略图放大模糊（`backdrop`，跟着翻页换，45% 黑遮罩）；底栏不再是一整条毛玻璃，只有操作列表是一块浮在图上的圆角毛玻璃卡，缩略图条直接浮在图上（每张带一点阴影），工具栏式的四个按钮各自一块半透明底。顶栏和底部按钮都保持半透明，别改回整条底栏铺底。
- 手机什么时候能看到新一批（v0.3.122 修）：换完一批后桌面端要**立刻**重读壁纸文件夹，不能只等下一帧 `view()`——窗口关着时 view 不重画（`main.go` 的 update 包装就是为这个），`wallsGen++` 后没人调用 `loadWallpapers`，`walls_rev` 一直不变，手机（列表、横幅、小组件）就停在上一批，直到重新打开桌面窗口。现在 `startRun` 结束的 `a.update` 里直接 `a.loadWallpapers()`，`wallsLoadedGen` 的推进也挪进了 `loadWallpapers`，读完再检查 `wallsGen` / 目录有没有又变（`wallsreload_test.go` 用「只执行主线程更新、不渲染」模拟隐藏的窗口）。
- iOS 的开发语言必须是 `zh-Hans`（`project.yml` 的 `developmentLanguage`）：App 没有中文本地化时 `Locale.current` 会退回英文，日期、系统按钮都显示成英文（踩过）。
- **离线模式**（v0.3.110 起，第 2、3 批）：手机连不上 Mac 时显示上次同步的样子。`OfflineStore.swift` 把最后一份 `RemoteState` + 壁纸列表 + 横幅图名按 Mac 存到 Application Support/拾景/offline，`RemoteSession` 开机先读它（`snapshotAt` 非空 = 显示的是快照，界面标「离线 · X 前同步」），连上后每次状态更新覆盖（5 秒最多写一次，壁纸列表变了立刻写）。图片也存磁盘（`ImageStore`）：按 `walls_rev` 分目录放 Application Support/拾景/images/，缩略图、横幅图和整批 2732 宽的预览图连上时后台预取（`prefetchAll`，3 路并发、已存下的跳过）；壁纸列表一变（换了一批或移出了几张）`ImageStore.groom` 就把缓存收拾到新的批次目录：名字还在这一批里的文件搬过去（移出一两张不用整批重下），其余的删掉，所以总量跟着一批走、不会越积越多。缓存有上限（UserDefaults 的 `offlineCacheLimitGB`，默认 10 GB，设置页可改 1–50），预取到上限就停、已在的不删；设置页「离线」分组显示占用、进度，可暂停 / 补齐 / 清除。每次从断线变回 live 也重新 `prefetchAll` 一遍（上次没缓存完的接着补）。**离线时的操作**：「移出」「不再选」「删除原图」都记在 `RemoteSession.queued`（UserDefaults 的 `offlineActions.<Mac 的 id>`，按 Mac 分开，每条还存下那张 `Wallpaper` 和原来的位置），本地先把那张从 `walls` 去掉；连接变回 live 时 `flushOfflineActions` 逐条补「移出」「不再选」——「不再选」走新加的 `POST /api/excluded/add`（只需要原图路径，和那一批还在不在无关，桌面端会去重并记一行日志），「移出」如果那张壁纸已经不在当前这一批就算过期；网络又断了的话剩下的留到下次。**「删除原图」不自动补**（v0.3.129 起；v0.3.111–v0.3.128 是离线直接禁用）：不可撤销，连上后在「待补操作」页（`QueuedActionsView.swift`）里逐张「确认删除」或「全部确认删除」才执行（`confirmQueuedDelete` 先 force 拉一次电脑上现在的列表，还在这一批才调 `POST /api/wallpapers/{name}/delete`；那一批已经换掉的算过期、原图没删，提示去电脑上删——接口只能按壁纸名删）。**「待补操作」是单独一页，带缩略图预览**（v0.3.130 起）：设置页和概览横幅下面都只是入口（设置里一行「待补操作 N 项」，概览里「N 张原图等你确认删除」一行），点开都是 `QueuedActionsView`——每条显示缩略图（点开看大图）、文件名、原图路径、时间，「删除原图」红字逐条确认，「移出」「不再选」列在「连上电脑后自动补上」一组，底部可以全部取消。队列条目记着记下时的 `rev`（`OfflineAction.rev`），缩略图按那一批的缓存找，换过批次后多半没图，就显示占位图标；`ImageStore.load` / `WallImage` 都可以传 `rev` 指定批次。`cancelQueued` / `cancelAllQueued` 取消后按存下的下标放回列表；离线时 `session.undoName` 取队列里最近一条「移出」，`undoRemove` 直接取消、不用连电脑。「存到相册」「分享原图」下载的是电脑上的原文件（不是缓存的预览图），离线时也要一并禁用（v0.3.117 补上，以前只禁用了删除；v0.3.125 起设置里存过那张的原图时离线也能存 / 分享）。截图验证用 `-demo -demoOffline`：它会把演示图写进磁盘缓存再从磁盘读，`demo` 置 false，真的走一遍离线读图路径；`-demoSettings -demoOfflineCache` 直接摆出「离线」和「待补操作」入口（设置页太长，模拟器里滚不到最下面），`-demoQueuePage` 直接打开「待补操作」页（配 `-demo` 或 `-demoOffline` 看两种状态）。离线时 `ImageStore.load` 只读磁盘、不发请求（发了要干等超时），大图没缓存但缩略图在就先垫缩略图并提示「显示的是缩略图」，都没有才显示「这张还没缓存」。
- **原图缓存**（v0.3.125 起）：设置 › 离线多了「保存原图」（`cacheOriginals`，默认关）——打开（或点「补齐原图」）后把这一批壁纸在图库里的原文件也存到手机上（`ImageStore.prefetchOriginals`，2 路并发，已存下的跳过，和预览图共用一个上限，到上限就停）。可以暂停、清除（`clearOriginals` 只删 `original-` 前缀，预览图不动）；换一批时 `groom` 连同预览图一起删，`groom` 还会顺手删掉留下的那一批里旧前缀的文件（比如以前 2048 宽的大图）。开关打开时换批 / 重新连上会自动接着补（`ImageStore.originalsEnabled`）。用途：离线时「存到相册」「分享原图」用手机上那份（没存过才禁用）；大图预览的 `.image` 缓存没命中时先看原图缓存，本地用 ImageIO 按 `ImageKind.targetWidth` 缩着解码（`downsampleFile`，按文件读、整张原图解码会爆内存），**不再联网下载**；离线时缩略图、横幅也拿原图缩，在线时缩略图照常下载（一张几十 KB，从几十 MB 的原图现缩反而拖慢网格滚动）。`prefetchAll` 对 `.image` 也跳过已有原图的（省流量）。设置里的「已缓存 N / 300 张」按「有预览图或原图」算（`viewableCount`）。大图预览和网格的图在切回前台时都会重试一次（`scenePhase` + `retry`，后台期间正在下载的会被系统掐断，不然会停在「读不了这张图」）。大图宽度同时从 2048 提到 2732（桌面 `remoteImageWidth`，覆盖 iPhone Duo 内屏）；`ImageKind.cachePrefix` 把大图的磁盘前缀改成 `image2732`，旧缓存自然失效。截图用 `-demo -demoOffline -demoSettings -demoOfflineCache`，demo 会在 `seedDiskCache` 里种一半原图，能看到「已存原图 N / 300 张 · 大小」。
- 缓存收拾的几种情况（v0.3.126 起）：`groom(keepRev:names:)` 只在列表变了（`groomedRev` 记着，同一批一次）时跑，把旧批次目录里还在这批的文件搬过来、其余删掉，并清掉留下的这一批里旧前缀（比如 2048 宽）的文件；换批前先 `stopForNewBatch()` 停掉旧那批的预取 / 原图任务，下载完的 `prefetchOne` / `prefetchOriginal` 会看 `Task.isCancelled` 不再写回旧目录。换过一批后手机上的原图跟着旧目录一起没了，开关开着就按新一批重新补、关着就不存。设置页把占用拆成「预览图缓存」和「已存原图」两行，各清各的（`clearPreviews` 只删 thumb/hero/image2732）。App 里的系统 HTTP 缓存（`URLCache`）也关了（和自建的图片磁盘缓存重复，默认容量装不下几百张 2732 图），`ShiJingApp.init` 里清一次以前攒下的。
- **记录页离线也能看**（v0.3.115 起，第 7 批）：`OfflineStore` 多了 `saveRecord` / `loadRecord`（泛型 `Cached<T>`，按 Mac 存 `records-<id>-<log|deletions|excluded>.json`，带同步时间，`clear(id)` 一起删），`RemoteSession.refreshRecordsCache()` 在连接变回 live、每换完一批、以及移出 / 删除 / 不再选成功后各存一份。`LogView` / `DeletionsView` / `ExcludedView` 在线照旧请求，失败或离线时读缓存并在顶部标「离线 · X 前同步，下面是手机上存的副本」；都没有时提示「连上电脑后会自动存一份」。离线时「不再选」只能看（恢复要改电脑上的名单），设置页顶部说明「现在连不上电脑，设置只能查看」，概览的「换一批」说明和「停止」按钮也按离线禁用。截图用 `-demo -demoOffline -demoRecords` 加 `-demoLog` / `-demoDeletions` / `-demoExcluded` 直接打开子页（模拟器的触摸注入经常失效，别指望点得进去）；demo 会在 `-demoOffline` 时往这三份缓存里写演示数据。
- **连接状态跟着系统网络走**（v0.3.116）：以前只靠 SSE 报错才知道断了，飞行模式 / 关 Wi‑Fi 后 socket 可能挂很久，界面上一直是绿的。`RemoteSession` 现在用 `NWPathMonitor`：系统网络变成不满足时立刻置 `.offline("手机没有连上网络。")` 并取消事件流任务，恢复正常后再 `start()`（后台 `paused` 时不自己重连，回前台再说，`.unpaired` 不会被网络状态盖掉）；demo 模式不启动监听。注意飞行模式开着但 Wi‑Fi 还连着时仍然显示已连接——那时候 Mac 真的连得上，是对的。
- **补离线操作的几个坑**（v0.3.118）：`flushOfflineActions` 不能拿手机上的 `walls` 判断「那张还在不在这一批」——离线记下时已经把它从本地列表去掉了，必须先用 `refreshWalls(force: true)` 拉电脑上现在的列表。还在这一批的「不再选」照在线的做法走 `removeWallpaper(exclude: true)`（只加名单不移出的话，电脑那边文件夹里还留着）；已经换掉的才退回 `POST /api/excluded/add` 按原图路径补。桌面返回 409 时看消息：「正在换壁纸」不是过期，要留在队列里（换完一批时 SSE 那一路会再补一次），「已经不在壁纸文件夹里」才算过期。「取消」对两种操作都要把那张放回列表（两种在离线时都从列表去掉了），移除一台 Mac 也要清掉它没补上的队列（`RemoteSession.clearQueue`）。图片缓存目录要排除出 iCloud / 电脑备份（10 GB 的图不该进备份）。
- 装到手机的是 **Release**（v0.3.106 起，`install-ios-device.sh` 带 `-configuration Release`，产物在 `ios/build/Build/Products/Release-iphoneos/`）：`project.yml` 里 Release 剥符号（`STRIP_INSTALLED_PRODUCT` + `DEPLOYMENT_POSTPROCESSING`），App 还排除了 `WidgetViews.swift`（只给 Debug 的 `-demoWidgets` 用）。包从 Debug 的 6.3 MB 降到 2.1 MB，小组件进程也省内存。`-demo*` 启动参数都包在 `#if DEBUG` 里，只在模拟器的 Debug 构建里有；Release 里 App 用到 `WidgetViews` 里的类型会编不过，要么包进 `#if DEBUG`，要么挪进 `Shared/`。
- **iPad 的顶栏用系统自己的**（v0.3.131 一度自己画过带图标的 `padTabBar`，v0.3.132 用户要求改回）：iPadOS 26/27 的系统顶部标签栏只画文字、没有图标，`.toolbar(.hidden, for: .tabBar)` 也藏不掉它——这是系统行为，**别再尝试补图标或自己画顶栏**，用户觉得原来的更好。iPhone 是系统底部标签栏，iOS 18 起走 `Tab(title, systemImage:value:)`，iOS 17 退回 `.tabItem`；`RootTab` 的 `title` / `icon` 两种都用得到。
- iOS 端没有侧栏（v0.3.21 起，用户嫌宽屏上占地方、连 Mac 只有第一次装时用）：一台都没配对时整屏是 `SetupView`（附近的 Mac + 手动输入地址）；配对过之后是三个标签（v0.3.105 起，对应桌面侧边栏）：概览（`DashboardView`，只放状态和操作，设置只读摘要在「状态」分组）、设置（`SettingsPage`，分组和桌面设置页一致）、记录（`RecordsPage`）。用户嫌设置堆在首页，别再把可改的设置放回概览。切换 / 添加 / 管理 Mac 在概览的标题菜单里（`macTitleMenu`，点顶部 Mac 名字）；这个菜单只放设备相关的操作，版本号别塞进去（以前在菜单里当过一行禁用按钮，用户觉得混在设备列表里很奇怪）。**「关于」是设置页的第三栏**（v0.3.132 一度独立成页、入口在概览右上角，用户觉得首页放它奇怪，v0.3.133 改回设置里的第三栏）：内容是两边版本、这台手机 / 平板的签名到期；以前混在设置页最下面，用户觉得怪。壁纸文件夹路径**不放**关于里（和电脑端「设置 › 输出」重复）。小组件深链会切回概览标签。截图用启动参数 `-demoSettings` / `-demoRecords` / `-demoAbout` 直接打开对应页面。「附近的 Mac」只在有界面显示它时才用 Bonjour 搜索（`Discovery.want(名字, 开关)`）：首次配对页和「添加其他 Mac」弹层。
- 概览页的克制（v0.3.119 起，用户嫌「乱」定的，别改回去、也别再加不必要的信息）：右上角的连接徽标只在断开 / 重连 / 未配对时出现，正常连着时不占位置；同一件事只说一次——「换上了 N 张、什么时候换的」只在横幅卡上说，「上次运行」因此改叫「上一轮对比」，只列时间和对比指标（新换上 / 重合率 / 筛选删除 / 覆盖文件夹）；缩略图网格下面不再挂「点一下看大图、长按整理」的提示；离线时横幅卡里不画一块点不动的灰色「换一批」按钮，也不在卡片里重复「连不上电脑」，改成毛玻璃面板里一行「连上电脑后才能换一批。」——这种提示不能直接叠在横幅图上，灰色字在图上几乎看不见。
- 界面文案（v0.3.133 用户要求清理过一次）：平实、具体，直接说这里是干什么的。不写预告 / 总结腔，不用「其实」「真正」「正是」这类凑语气的词，也不用「只是……」「才……」这种防御性说法（取消、离线这类行为写清楚结果就行）。实现细节和黑话不进界面：不写「NAS」「2732 宽」「硬链接 / 跨挂载点换算」，必要的地方用「图库」「原图」「连接」。功能上的区分不能省：「移出」只动壁纸文件夹，「删除原图」才动图库；不可撤销的操作要写明。
- 代码整理（v0.3.121 起，行为不变，之后的改动顺着这个结构来）：
  - 文件按职责拆开：`RemoteSession.swift` 只剩连接、状态、设置、壁纸操作；离线队列在 `RemoteSession+Queue.swift`，演示数据在 `RemoteSessionDemo.swift`（`#if DEBUG`）；记录页三页和共用的取数逻辑在 `RecordsPage.swift`；连接异常的整页占位 `ConnectionFallback` 和「非 live 才显示的徽标」`connectionToolbar` 在 `ConnectionUI.swift`。跨文件要改 `RemoteSession` 的状态，属性得是 `internal(set)`（`private(set)` 在别的文件里写不了）。
  - 离线队列 `flushOfflineActions` 是**逐条消费**：取走第一条就 `saveQueue`，失败了再 `insert(at: 0)` 放回。别回到「遍历快照 + 批量删」，那期间用户取消掉一条会被误补。桌面返回 409 时按消息区分：「正在换壁纸」放回队列下次再补，「已经不在壁纸文件夹里」才算过期。
  - 离线快照 `OfflineStore.Snapshot` 除了状态和壁纸列表还存了 `wallsRev`（壁纸属于哪一批）。旧文件没有这个字段时回退到 `state.wallsRev`。
  - 预览翻页的三页（`PageSlot`）按**文件名**做身份，同一张图翻页时不会整个重建；双击和单击用 `ExclusiveGesture`（双击不再顺带触发隐藏工具栏）；双指缩放结束后 `axis = nil` 复位，否则下一段拖拽会沿用缩放时的判定。
  - `ImageStore` 内存缓存的 key 只用 macID + 文件名 + 尺寸，不碰 `session.client()`。`MacStore.token(for:)` 读一次钥匙串就缓存在内存里（配对 / 取消配对时更新），`client()` 才能随便调——每张图加载都查一次钥匙串会卡主线程。`prefetchAll` 用代际号（`prefetchGen`）判「这轮是不是已经被新一轮顶掉」，旧的收尾不会把新的 `prefetching` 置回 false。删目录、算占用这类磁盘操作放 `Task.detached`，不占主线程。
  - 写盘别放主线程：`OfflineStore` 的保存（快照每 5 秒一次，带一整份壁纸列表）和记录缓存都排在同一条串行 `writeQueue` 上编码 + 写；`clear` 也排进这条队列，免得还在排队的旧快照把删掉的文件又写回来。`refreshWalls` 有一轮在拉时后来的非 force 调用直接返回，状态推得密也不会重复发请求。
  - 记录页三个页面的取数共用 `loadRecord(session, kind, offlineNote:online:)`（`RecordLoad`：值 + 是否来自磁盘副本的时间 + 错误），在线失败自动落到磁盘副本；`RecordsCacheHeader` / `recordsCacheSection` 分别给非 List 页面和 List 页面顶部那行「离线 · X 前同步」。加新的记录页照这个来，别各写一份。
  - 预览和长按菜单的四个整理操作统一成 `WallActionKind`（`save / remove / exclude / delete`，带图标、文案、是否要原图、是否要在线、是否危险），`WallActionButtons` 和预览底栏的 `barButtons` 都按它渲染。改文案只改这一处。
- 本机没装完整 Xcode 时，Swift 代码用命令行工具在 macOS SDK 上类型检查（命令见 `ios/README.md`）；必须用 `MacOSX26.5.sdk`，27.x 的 SwiftUI `@State` 是宏、命令行工具缺宏插件。iOS 专有修饰符包在 `PairView.swift` 底部的 `iOSKeyboard` / `iOSInlineTitle` 等扩展里。
- 第 3 期（v0.3.100，`desktop/remoteextra.go`）：状态里加了 `settings`（手机能改的几项）、`undo_name`、`excluded`；`POST /api/settings`（只改传了的字段，改的是界面状态，下一帧 autosave 写盘）、`GET /api/log`、`POST /api/undo`（桌面 `undoRemove`，同一个撤销栈）、`GET /api/excluded` / `POST /api/excluded/restore`、`GET /api/deletions`、`GET /api/wallpapers/{name}/original`。旧版桌面没有 `settings`，手机上设置就只读、不显示「记录」。
- 第 4 期（v0.3.123）：
  - **排队中的删除原图**：`RemoteState.pending`（桌面 `remoteState.Pending` 本来就有）。概览横幅下面弹一条「N 项删除原图在电脑上排队」（`DashboardView.pendingSection`，窄屏宽屏都放在 `signingSection` 后面），不塞进最下面的「状态」分组——那里要滚到底才看得到。删除时如果电脑把这次删除排了队（返回的 `pending` 变大），`deleteOriginal` 会在手机上提示「图库没连上，这次删除已排队」。
  - **「全部壁纸」页（`AllWallpapersView`）**：`.searchable` 按文件名筛；搜索框下面一颗目录胶囊（`folderMenu`，按原图路径去掉 `/Volumes/xxx` 后最多留两级分组，菜单里带张数）。**目录筛选别放工具栏**：窄屏上工具栏第二个按钮会被挤到右侧标签栏的溢出区变成一颗浮动的圆圈，看不出是什么。`WallGrid` 多了 `walls`（只显示这些）、`selecting` / `selected`（勾选圈和「选择」模式）、`onSelect`（长按菜单里的「批量选择」）；编号按 `session.walls` 的完整顺序算，筛选后和大图预览顶部对得上。目录胶囊的标签要 `fixedSize(horizontal:)`：换成较长的目录名时，Menu 标签第一帧会按旧宽度量、先被截一截，下一帧才撑开（v0.3.126 修）。
  - **多选整理**：点「选择」或长按「批量选择」进选择模式，底部浮一条毛玻璃操作条（取消 / 移出 N / 不再选 N；不做批量删除原图，不可撤销的事一张一张来）。批量走 `RemoteSession.removeWallpapers`：逐张调接口（失败就停，错误已经弹出来了），**最后只重新拉一次壁纸列表**（`removeWallpaper(refresh: false)`），否则 50 张会拉 50 次列表。
  - **通知点开直达**：换完的通知带 `userInfo["target"] = "overview"`、签名到期带 `"about"`；`Notifications` 的 delegate 实现 `didReceive` 写进 `NotificationRouter.shared.tab`（`@Observable`，`RootView` 用 `onChange(initial: true)` 消费后清空——通知回调不保证 RootView 已经显示）；`"about"` 还会把 UserDefaults 的 `settingsGroup` 设成 `about`，设置页打开时就是第三栏。delegate 方法不是主线程隔离的，得 `await MainActor.run` 再改。
  - **扫码配对**：桌面上「设置 › 手机遥控 › 扫码配对 › 显示二维码」（`openQRPair` / `qrPairModal`），二维码内容是 `shijing://pair?h=<IP>&p=<端口>&c=<配对码>`（`github.com/skip2/go-qrcode`，`ui.NewBitmap` 给 `ui.Image`）。`remoteServer.startPair(device, qr)` 统一建配对请求，`pairRequest.qr` 的请求**不弹**「请求遥控拾景」那个确认框（电脑上点「显示二维码」就是确认）；`handlePairFinish` 的 body 多了可选 `device`，扫码时手机报上自己的名字。配对成功记 `pairedCode`，`takePaired` 让二维码弹层自己收起；关掉弹层会取消这次配对（只在当前请求还是那个二维码时才取消）。
  - 手机端：`ios/ShiJing/QRScan.swift`（AVFoundation 取景扫二维码，扫到一次就停，失败可以「重新扫描」重建取景），配对地址和码解析在 `QRScanView.parse`；`APIClient.pairFinish(code:device:)`。相机权限文案在 `project.yml` 的 `INFOPLIST_KEY_NSCameraUsageDescription`。入口在 `NearbySection`（首次配对页和「添加其他 Mac」都有）。
  - **弹层不能挂在会变化的 List 行 / Section 上**（v0.3.124 修）：扫码页一开始挂在 `NearbySection` 的 Section 上，结果「扫码页有时候打开后自己退出」。原因：点开扫码页时 `SetupView.onDisappear` 触发 `discovery.want(…, false)` → `Discovery.stop()` 清空 `found`，附近 Mac 的行一变，挂在 Section 上的 `fullScreenCover` 跟着被重建、自己关掉；已经找到 Mac 之后再点扫码才复现（第一次就打开时 found 本来就是空的，所以是「有时候」）。现在三个弹层（配对、手动输入、扫码）的状态放在 `NearbyFlow`，用 `.nearbyPresenters(store:flow:)` 挂在 `SetupView` / `AddMacView` 这种稳定容器上；`Discovery` 的搜索结果没变（`found != list`）时也不刷新界面。`-demoScan` 故意等 4 秒再打开，用来复现「先看到 Mac 列表再点扫码」的时序（挂在 Section 的旧写法下会看到它自己关掉）。
  - 截图用的启动参数：`-demoAll`（全部壁纸）、`-demoSelect`（已选 3 张的选择模式）、`-demoPending`（排队中的删除原图）。
- 第 5 期（v0.3.129）：手机上补了桌面设置里常用的几项。`remoteSettings` 多了 `balance_first`、`incremental`、`mode`（copy / symlink）、`min_width` / `min_height` + `min_presets`、`archive_enabled` / `archive_subdir` / `archive_dir`，都走 `POST /api/settings`；改分辨率时桌面会把 `a.preset` 对上预设或「自定义」（不然电脑设置页还停在旧的预设）。状态快照多了 `dirs`（图库目录只读：类型、挂载状态、上次统计、删过几张）和 `pending_items`（电脑上排队的删除原图明细，带完整路径用来取消）；`POST /api/mounts/check` 让电脑重新检查挂载（结果随快照推），`POST /api/pending/cancel`（`{"path": ...}` 或 `{"all": true}`）逐条 / 全部取消排队删除，日志里记一行 📱。iOS 设置页新增「输出、画质要求、归档、待删除」分组，「图库」只占一行（「图库目录 N 个」），点开是二级页 `LibraryDirsView`（目录列表 + 挂载状态 + 重新检查挂载），目录多时不把设置页撑长；旧版桌面端不推这些字段时，这几组整组不显示。图库目录只在快照里：在线时随 SSE 更新，离线时是 RemoteState 一起存进 `OfflineStore` 的上次同步副本（二级页顶部会提示「下面的是上次同步的信息」），「重新检查挂载」离线时禁用。**设置页分三栏**（v0.3.131 起分两类，v0.3.133 加了关于）：导航栏中间一个分段控件，「电脑上的拾景」（输出、采样、画质要求、归档、筛选、自动换、系统、图库目录、待删除）、「这台 iPhone / 这台 iPad」（`ThisDevice.label` 按 `UIDevice.current.localizedModel` 取，平板上不写成「手机」：待补操作入口、离线缓存）和「关于」（两边版本、签名到期）。选过哪一类存在 UserDefaults 的 `settingsGroup`（`@AppStorage`），下次打开还是那一类；三栏放在 `.tabViewStyle(.page(indexDisplayMode: .never))` 的 TabView 里，和分段控件共用一个 selection，所以左右滑也能切（v0.3.134）。切换控件用 `.toolbar(placement: .principal)` + inline 标题（用 `safeAreaInset` 会把导航大标题压掉，踩过）；TabView 里每页是自己的 List，调试用的单页 demo 分支绕过 pager。`-demoSettings` 能看排版，`-demoPending` 同时塞了 `pending_items`；`-demoSettings -demoLibrary` 只摆「图库入口 / 待删除」两组（设置页太长，模拟器里滚不到下面），`-demoLibraryPage` 直接打开图库目录二级页；模拟器里想切到另一类，`xcrun simctl spawn booted defaults write com.love1017best.shijing.ios settingsGroup phone`（再启动）。
- 小组件（`ios/ShiJingWidget`，bundle id `….ios.widget`）和快捷指令（`Shared/Intents.swift`）读不到 App 的 UserDefaults：**免费签名没有 App Groups，但钥匙串共享能用**（2026-11-11 真机签名验证过）。令牌和 `CurrentMac` 存在共享组里，组名带团队前缀，靠 Info.plist 的 `ShiJingKeychainGroup = $(AppIdentifierPrefix)…` 在构建时展开；模拟器没签名时退回默认组。旧版本存在默认组里的令牌读到时自动挪进共享组。`MacStore` 选中的 Mac 变了就写 `CurrentMac`。
- 换完发通知没有推送可用：App 进后台时如果正在换，用 `beginBackgroundTask` 多连 ~30 秒；小组件运行中按分钟刷新。两边经 `RunNotifier` 共用钥匙串里「通知过的那次 `last.at`」，第一次只记不发，结束超过 15 分钟的不发。通知权限在第一次从手机换一批时才问。
- 签名到期：`SigningExpiry` 读 `embedded.mobileprovision` 的 `ExpirationDate`；模拟器里用启动参数 `-demoExpiring` 假装 36 小时后到期，看提醒横幅。
- 横幅图（v0.3.102）：`/api/wallpapers` 带 `hero`（桌面 `walls.heroPath` 的文件名），`/api/wallpapers/{name}/hero` 给 `heroWidth`（1600）宽、走桌面的磁盘缓存。手机概览的横幅卡和小组件背景都用它；旧版桌面没有 `hero` 时手机用第一张的大图、小组件用缩略图。
- 小组件（v0.3.104 起）有两种：「拾景」（状态 + 按钮，`StatusWidget`）和「拾景壁纸」（只有图，`PhotoWidget`），都是 `AppIntentConfiguration`，长按编辑改换图间隔（`RotateInterval`）。尺寸表在 `WidgetViews.swift` 的 `WidgetFamilies`；iOS 27 的 `systemExtraLargePortrait` 要包 `#available`。时间线由 `TimelineMaker` 排：按「时间段 + 哈希」挑图（同一时段总是同一张），一次排 2–12 条，图用 ImageIO 按小组件像素缩着解码、封顶 1600（小组件进程内存只有几十 MB，别放整张大图），条目里只存文件路径、显示时才解码。**离线缓存**：小组件没有 App Groups，缓存放小组件自己的 Caches（`WidgetCache`：状态 JSON + 最多 120 张 JPEG），连不上时读缓存、在已缓存的图里轮换、标「离线」，15 分钟后重试。点小组件走深链 `shijing://wall/<文件名>`（Info.plist 的 `CFBundleURLTypes`）→ `session.openRequest` → `DashboardView` 打开大图。界面 App 的 Debug 构建也编译：启动参数 `-demoWidgets` 把所有尺寸摆在一页上看排版（模拟器里很难用鼠标长按主屏幕添加小组件）；`xcrun simctl openurl` 测深链时系统会先弹「Open in 拾景?」。
- 大图预览的状态（`previewing`）和「全部壁纸」页（`navigationDestination(isPresented: $showAll)`）都挂在 `DashboardView` 上：概览按宽度在宽 / 窄两种排版之间切换，转屏时 `WallGrid` 和 header 里的 `NavigationLink` 会被重建，状态放在它们里面就会丢、预览关掉回到首页（v0.3.103 及以前的 bug）。
- `release.sh --version X.Y.Z` 直接发成指定版本（v0.3.100 就是这样发的），只在用户要求某个版本号时用。
- 两边 JSON 对接验证过的方法：写个临时的 Go 测试用 `newRemoteHarness` 起服务并把地址和令牌写到文件，再用 `swiftc Models.swift APIClient.swift main.swift` 编一个命令行客户端去连。时间字段一律用 Unix 秒（Go 的 RFC3339 纳秒精度 Swift 解析不稳）。

### 15. 横竖屏要按 EXIF 方向判断（v0.3.18）
不少照片是「像素横着存 + EXIF Orientation 标记转 90°」：像素 6240×4160，系统壁纸、Finder、预览里显示的却是 4160×6240 的竖图（例：`[织梦映像]NO.098 …/0163.jpg`，Orientation=8）。以前 `ImageVerdict` 只看 `image.DecodeConfig` 的像素宽高，这种竖图被当成横屏选进壁纸。现在先用 `core/orientation.go` 的 `exifOrientation`（纯 Go，只读 JPEG 的 APP1 / TIFF 的 IFD0）读方向，5–8 时宽高互换再判断。2026-11 只读统计：全库 27464 张里有 287 张因此从合格变成竖屏。
- `sips -g orientation` 对这张图报 `<nil>`，但 PIL 的 `getexif()[274]` 是 8——**查方向别信 sips**，用 PIL 或 `exifOrientation`。
- 「仅采样目录」采样时走同一个 `ImageVerdict`（`scanImages` → `checkResolutions`）。「筛选并采样目录」只有真删时才干净：只模拟、定时自动换、手机「只模拟」都不删原图，以前不合格的图留在图库里、采样时又不查，竖图照样会被选进壁纸（增量模式还会把目录记成查过、以后一直跳过）。现在筛选把「不合格但没删」的图记进增量状态的 `rejected`（按目录），跳过的目录也带上，经 `SortResult.Remaining` → `CopyOptions.Rejected` 在采样时排除。`TestSimulatedFilterNeverSamplesRejected` 盖住了这条。
- 判断逻辑改了要把 `sorter.go` 的 `verdictRules` 加 1：它记在增量状态的 `thresholds.rules` 里，不一样就整体重扫，否则以前判过、之后没动过的目录会一直被跳过，新规则永远不生效。

### 16. 图库（NAS）不在时的整理：删除原图排队（v0.3.109）
壁纸文件夹在本地，图库没挂上时看图、移出、⌘Z 撤销、不再选（`config.json` 的 `excluded`）都照常能用，只有「删除原图」要动网络卷。所以桌面端没有「离线模式」这个开关，只是把这一件事改成了队列（`desktop/pending.go` + `desktop/core/pending.go`，数据目录的 `pending_deletes.json`）。

- **`os.Remove` 在卷没挂上时返回的也是 ENOENT**，跟「文件本来就不在」分不出来。旧代码把这种情况当成删掉了、还照写删除日志——这是真 bug。现在先看挂载状态（`sourceUnmounted`），再看**文件所在目录**还在不在（`dirMissing`），都不行才排队；只有 `os.IsPermission` 才弹错误。以后动删除相关的代码要注意这一点。
- 队列每条记**路径 + 大小 + mtime**（排队时一般拿不到，记零值就只校验「文件还在」）。执行在后台（`RunPending`），只在所有图库目录都挂上时动手，避免对着断掉的卷逐个 stat 卡住；执行前指纹对不上（排队期间文件被改过）就不删、只写一行日志并从队列去掉，不自动重试。
- 触发点：`main.go` 每分钟的定时器（先执行队列、再看挂载）和 `checkMounts` 每个目录探完的 `update`（`maybeProcessPending` 里 `unmountedCount() > 0` 就直接返回）。
- 排队时壁纸文件夹里那份照样走 `removeWallpaper`（可以 ⌘Z 撤销）；概览横幅下面多一条 `pendingBar`，弹层 `pendingModal` 能逐条取消或全部取消。删除照旧记进删除记录（原因「手动删除」，日志里注明是排队执行）。`RemoteState.Pending` 把条数带给手机。
- 测试：`desktop/core/pending_test.go`（校验、指纹、目录没了）、`desktop/pending_test.go`（离线排队、连上执行、等待、改过不删、概览弹层取消）。

## 两个会话并行开发（2026-11-11 起）

macOS 端和 iOS 端分别由不同的会话负责，**两个会话共用同一个工作区**（同一个 checkout、都在 `main` 上，没有各自的 worktree）。所以：

- **只提交自己改的文件**：`git add <具体路径>` / `git commit -- <路径>`，**不要 `git add -A`、`git commit -a`**，否则会把另一个会话写到一半的文件一起提交。提交前 `git status` 看一眼，不认识的改动别碰、别还原、别 `git stash`。
- 接口两边对应（`desktop/remote.go` ↔ `ios/ShiJing/Models.swift` / `APIClient.swift`）：改了一边要同步另一边。另一边归对方会话管时，在提交说明里写清楚，或者告诉用户请对方会话跟进。
- **构建、安装、发布只用这几个脚本**，它们共用一把锁（`desktop/scripts/lock.zsh`，锁文件在 `.git/shijing-build.lock`），两个会话同时跑时后来的会排队等，不会抢 `build/` 目录、同时替换 `/Applications/拾景.app` 或撞版本号：
  - `desktop/scripts/install-local.sh`：构建 macOS 并装到 `/Applications`、启动；连着 iPhone / iPad 时再构建 iOS 装到设备上并启动。**哪一端改了都跑它**，两端都会重新安装运行（iOS 会话也一样，不要只装手机）。装好后会用 `scripts/sign-app.sh` 把装到本机的那份重签一次：mygo 出来的 ad-hoc 签名每次构建指纹都变，macOS 的「访问网络卷」等隐私授权按签名身份记，重装就要重新授权（手机上远程删原图时还得跑到电脑前点那个框）；脚本默认找本机钥匙串里的 `Apple Development` 证书签（`SHIJING_SIGN_IDENTITY` 可指定别的），签一次 TCC 就一直认，证书续期 CN 不变也认。没有可用证书就保持 ad-hoc；**dmg 本身不动**，发布包还是 ad-hoc。
  - `desktop/scripts/install-ios-device.sh`：只装手机，`install-local.sh` 会自动调，一般不单独用。环境变量 `SHIJING_IOS_DIR` 换一个 `ios/` 目录来构建、`SHIJING_DEVICE` 只装名字含这段文字的设备（都给 `install-ios.sh` 用），`SHIJING_DERIVED_DIR` / `SHIJING_LOG_DIR` 改派生数据和日志的位置（在临时 worktree 里构建时用：派生数据复用工作区的、日志留在 worktree 外，否则 worktree 一删日志就没了）。判断「哪台连着」不能看 `devicectl list devices` 的 `tunnelState`——平时一直是 `disconnected`（要用时才建隧道），按它过滤会一台都找不到（v0.3.107 没装上就是这原因）；要看 `reality == physical` + `pairingState == paired` + `transportType` 是 `wired` / `localNetwork`。
  - `desktop/scripts/install-ios.sh`：给用户自己手动装手机 / 平板用（比如免费签名 7 天到期要续）。默认装 GitHub 上最新发布的 tag（在临时 worktree 里检出再构建，工作区没提交的改动不会混进去，装完删掉），`--current` 装工作区当前代码，`--device 片段` 只装匹配的设备；不动 `/Applications` 里的 Mac 版。
  - `desktop/scripts/release.sh`：发布，见下面「发布规则」（`--version X.Y.Z` 发成指定版本，只在用户要求时用）。
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
