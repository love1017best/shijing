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
- 窗口用 `TitleBarHiddenInset` + `VibrancySidebar`：侧边栏顶部和内容区顶部各留了一条 `DragWindow()` 的拖拽区，侧边栏背景透明才能透出毛玻璃（`c.Vibrancy()` 为 false 时退回纯色）。配色和通用组件（`panel`/`group`/`settingRow`/`sceneArt` 插画）集中在 `theme.go`。
- 概览页缩略图由 `thumbs.go` 的 `scanWallpapers` 在后台解码缩小，`Bitmap` 回主线程再建；只读本地 `dest_dir`，运行结束 `wallsGen++` 触发重读。缩略图网格的行列数由 `stripLayout` 按**上一帧**量到的尺寸算（网格宽度定列数，滚动区高度 − 页面其余部分高度定行数，后者与行数无关所以不会来回跳），算出来变了就 `c.AnimationFrame()` 再排一帧；概览页不受 `contentMax` 限制、铺满窗口宽度。先解码 `initialThumbs` 张，放得下更多时 `loadMoreThumbs` 从 `walls.rest` 接着解码（`decodeWorkers` 限并发，原图很大）。`app.scanWallpapers` 是注入的，测试里设成 nil，界面测试不读真实目录。
- 「换上时间」和「上次运行」来自 `ui_state.json`（`uistate.go`），**不要**改用壁纸文件夹里文件的 mtime：复制时 `copyFile` 会用 `Chtimes` 保留原图的修改时间，那是原图的时间，不是换上的时间。命令行跑的不会写这个文件。
- v0.3.0 加的几样，改相关代码时注意：
  - **优先选没换上过的**（`prefer_unseen`）：`selection_history.json` 是这一轮轮换里换上过的原图路径集合；没换上过的不够一批时全部选上、差的从换上过的里补，并把历史重置成只有这一批（`NewCycle`）。只在复制完整跑完后写。`CopyResult.Rotated` / `Candidates` 是轮换进度。
  - **删除日志**每行 4 列（时间、阈值、路径、原因），旧日志只有 3 列，`core.ReadDeleteLog` 两种都认；不合格原因来自 `core.ImageVerdict`。筛选时每张不合格的图只打一行日志：真删「🔥 已删除: 名  (原因)」/「❌ 删除失败」，模拟「🗑️ 待删除: 名  (原因)」——界面 `parseLogLine` 按两个空格加括号拆出原因，`countDeletion` 数这些行。
  - **大图预览**按 `walls.all`（壁纸文件夹里全部图片，打乱后的顺序）翻，不只是缩略图那几张；没缩略图的先显示「正在载入…」，后台 `loadPreview` 解码。图片框用 `fitBox` 按图片比例算尺寸（不留黑边），整个弹层不超过主窗口。快捷键可以自定义（侧边栏「快捷键」页，`keysview.go`）：可改的操作和默认值在 `shortcuts.go` 的 `keyActions`，配置 `Shortcuts` 只存改过的；`fixedKeys` 是不许占用的。菜单栏三项由 `a.setMenuKeys` 同步（录制时先撤掉，免得按 ⌘R 真的开始运行）。预览按键在 `previewKeys`，必须在 `Modal` 回调里调 `c.Shortcut`，外面收不到；回车被弹层里有焦点的按钮占着，不能当快捷键，所以预览打开时焦点放在图片上。预览默认是空格 / ⇧空格翻页（固定键，← → 是可改的那一套）、J K L 按轻重排移出 / 不再选 / 删除原图（用户定的，手不离主键区）。移出可以 ⌘Z 撤销（`undo.go`）：移出时文件挪进数据目录 `undo/` 暂存，撤销时挪回、放回原位置并去掉这次加的「不再选」；启动时和开始换一批前清空。⌘Z 要靠 `c.Shortcut(Cmd, KeyZ)` 注册了，「编辑」菜单的撤销才会亮、按键才传得到（MyGo 把没人接的编辑命令转成快捷键）；预览开着时在 Modal 里注册，关着时在 `view` 里。预览里数字键输入编号、回车跳转（`jumpKeys`，0–9 在 `fixedKeys` 里）；正在输入时 Esc 会先被 Modal 自己接走关掉预览，所以在 `previewModal` 里看到「刚被关掉且有编号」就重新打开、只清编号。新加可快捷操作时加进 `keyActions`，`TestDefaultShortcutsDoNotClash` 会检查默认值不冲突。三种操作的文案集中在 `preview.go` 的 `act*` 常量：「移出」只删壁纸文件夹里那份，「删除图库里的原图」才动原图——改文案时保持这个区分。
  - **缩略图 → 原图**：`last_selection.json` 里 `dests` 和 `sources` 一一对应，`core.WallpaperSources` 读成「壁纸文件名 → 原图」；旧版本换上的没有 `dests`，缩略图菜单里就不出现「不再选它 / 删除原图」。
  - **定时自动换**（`auto_run_hours`）：`main.go` 里每分钟 `maybeAutoRun`，从上次运行（没运行过从应用启动）开始计时；`startRunWith(true)` 会强制 `DeleteDuringFilter=false`，自动运行永远不删原图。
  - 图库统计、空间预估用 `a.lastGood`（最近一次成功运行，存在 `ui_state.json` 的 `last_success`），因为运行中 / 失败后 `a.last` 不是成功的结果。
- 页面宽度策略（`view.go`）：概览页铺满；其余页面按上一帧量到的内容区宽度 `a.viewW` 决定——`a.twoCol()`（内容区 ≥ `twoColMin`）时设置 / 图库 / 归档用 `a.columns` 排成左右两栏、最宽 `twoColMax`，窄时单栏、最宽 `contentMax`；关于页始终单栏居中。新加设置分组时放进 `columns` 的左栏或右栏，注意两栏高度大致平衡。概览横幅图（`walls.heroPath`）也能点开预览，所以预览序号从横幅图算起。
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
- iOS 的开发语言必须是 `zh-Hans`（`project.yml` 的 `developmentLanguage`）：App 没有中文本地化时 `Locale.current` 会退回英文，日期、系统按钮都显示成英文（踩过）。
- 「附近的 Mac」只在有界面显示它时才用 Bonjour 搜索（`Discovery.want(名字, 开关)`）：一台都没配对时侧栏直接显示，配对过之后只在「添加其他 Mac」弹层里搜。
- 本机没装完整 Xcode 时，Swift 代码用命令行工具在 macOS SDK 上类型检查（命令见 `ios/README.md`）；必须用 `MacOSX26.5.sdk`，27.x 的 SwiftUI `@State` 是宏、命令行工具缺宏插件。iOS 专有修饰符包在 `PairView.swift` 底部的 `iOSKeyboard` / `iOSInlineTitle` 等扩展里。
- 两边 JSON 对接验证过的方法：写个临时的 Go 测试用 `newRemoteHarness` 起服务并把地址和令牌写到文件，再用 `swiftc Models.swift APIClient.swift main.swift` 编一个命令行客户端去连。时间字段一律用 Unix 秒（Go 的 RFC3339 纳秒精度 Swift 解析不稳）。

## 版本号规则（用户规定）

- 格式 `vX.Y.Z`（如 `v0.2.101`），写在 `desktop/mygo.json` 的 `version`（那里不带 `v`，macOS 的 Info.plist 只认数字）。
- **macOS 和 iOS 两端永远用同一个版本号，每次发布两端一起发，不管哪一端有没有改动**（用户规定，2026-11-11）。这样不用分别维护两套版本号，分别负责 macOS 和 iOS 的会话也不会各自升版本撞车。
  - 改版本号只用 `desktop/scripts/bump-version.sh`（不带参数 Z 加 1，带参数直接设成某个版本）：同时改 `desktop/mygo.json`、`ios/project.yml` 的 `MARKETING_VERSION`（= 版本号）和 `CURRENT_PROJECT_VERSION`（= Z），并重新生成 Xcode 工程。不要手改其中一处。
  - `desktop/version_test.go` 检查这几处一致，`go test ./...` 会挡住只改了一端的情况。
  - 多个会话并行时：只在发布那一步升版本号，升之前先 `git pull`，看清 `mygo.json` 当前是哪个版本再加 1；不要在功能分支 / 各自的改动里提前升。
- `X.Y` 是大版本号，**只有用户明确要求大迭代时才提升**，不要自己改。
- `Z`：每次有代码改动并重新构建（`mygo build`），就先把 Z 加 1 再构建。没有改动的重复构建不加。
- 起点：v0.2.100。

## 发布规则（用户规定）

- 每次发布都是两端一起：同一个提交、同一个 tag `v<版本>`、同一个 Release。说明里分「macOS」「iOS」两节写这一版各自的改动，某一端没改就写「无改动，仅同步版本号」。
- iOS 端没有上架、也不传安装包（免费签名的包只能装到签名者自己的设备上，传了别人也装不了）：Release 里只说明 iOS 源码在 `ios/`、按 `ios/README.md` 自己用 Xcode 装。本机装了完整 Xcode 之后，发布前要至少跑一次模拟器构建确认能编译通过（`xcodebuild -project ios/ShiJing.xcodeproj -scheme ShiJing -destination 'generic/platform=iOS Simulator' build`）；没装 Xcode 时退而用 `ios/README.md` 里的 `swiftc -typecheck` 做类型检查，并在说明里如实写明没在真机上验证。
- 每次版本构建（Z 加 1 那种）都要发布到 GitHub Release，macOS 只传 dmg，**两个都传**：
  - 通用版（Intel + Apple Silicon，纯 Go 无 cgo 所以直接支持）：`go tool mygo build -skip-notarize -platform darwin/universal` → `build/darwin-universal/shi-jing-<版本>.dmg`（文件名不带架构）
  - Apple Silicon 版（体积约一半，本机运行的也是它）：`go tool mygo build -skip-notarize` → `build/darwin-arm64/shi-jing-<版本>-arm64.dmg`
- 发布顺序：代码先提交并推送 → 给那个提交打 tag `v<版本>` 并推送 → `gh release create v<版本> <通用版 dmg> <arm64 dmg> --verify-tag --title "拾景 v<版本>" --notes ...`。`--target` 不认短 sha，所以先打 tag。说明开头写清两个包怎么选。
- 发布到 `origin`（`love1017best/shijing`）。本地还有指向旧历史的 tag（`python-final`、`v0.2.104`、`v0.2.105`）和 `legacy` 远端，**不要 `git push --tags`**，否则会把旧历史推到公开仓库；tag 一律单独推。
- 说明里写这一版的改动，并注明是 ad-hoc 签名、未公证（别的 Mac 首次打开要右键「打开」）。仓库是**公开**的（2026-11-10 起），提交前注意别放进个人信息、真实壁纸或密钥。
- 发布完**用 arm64 dmg 安装到本机，替换 `/Applications/拾景.app`**，再从 `/Applications` 启动。**不要直接运行 `build/` 下的 `.app`**（用户规定）。迭代后主动打开应用给用户预览、试用时也一样，任何时候都不 `open build/...app`。
  - 用 `desktop/scripts/install-local.sh`：构建 arm64 → 退出旧版 → 挂载 dmg 用 `ditto` 替换 `/Applications/拾景.app` → 启动，最后输出一行版本和运行路径（不一致时退出码非 0）。约 10 秒。
  - 发布时 arm64 dmg 刚构建过，用 `scripts/install-local.sh --no-build` 直接安装。
  - 预览只需要 arm64；通用版只在发布时构建（发布仍然两个都要传）。`.app` 是 dmg 的中间产物，`mygo build` 省不掉它。

## 调试小抄

- 这台机器的 shell 里 `cp` / `rm` 是交互式别名（会问 overwrite?/remove?，非交互环境下默认 n，静默不生效）：脚本里用 `command cp -f` / `command rm -f`
- `ps aux | grep 拾景` 找不到进程（`ps` 会把中文路径转义成 `M-f…` 字节），查应用是否在运行用 `lsappinfo list | grep -A6 com.love1017best.shijing`

- 确认某个 `/Volumes/xxx` 到底是什么协议挂载的：`mount | grep xxx`
- 确认 NAS 是否开了 NFS：`nc -zv <nas_ip> 2049`（能连不代表一定能挂载/建硬链接，还要看 NAS 端导出配置）
- 怀疑某个文件的 `st_flags` 导致复制报错：`python3 -c "import os; print(os.stat(path).st_flags)"`，`65536` 就是 `SF_ARCHIVED`
