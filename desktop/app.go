package main

import (
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

// maxLogLines 限制日志保留的行数，长时间运行也不会无限增长。
const maxLogLines = 20000

// 侧边栏页面的 ID。
const (
	pageOverview = "overview"
	pageWalls    = "walls"
	pageLibrary  = "library"
	pageSettings = "settings"
	pageDeleted  = "deleted"
	pageAbout    = "about"
	pageKeys     = "keys"
)

// autoRunHours 是「自动换壁纸」的选项（小时，0 为关闭），和设置页的分段控件一一对应。
var autoRunHours = []int{0, 6, 12, 24, 168}

var modes = []string{"copy", "symlink"}

// 分辨率预设；最后一项「自定义」显示两个数字输入框。
var resPresets = []struct {
	label string
	w, h  int
}{
	{"4K", 3840, 2160},
	{"5K", 5120, 2880},
	{"2K", 2560, 1440},
	{"1080p", 1920, 1080},
}

// presetFor 是最低分辨率对应的预设下标；对不上任何预设时返回 len(resPresets)（界面上是「自定义」）。
func presetFor(minW, minH int) int {
	for i, p := range resPresets {
		if p.w == minW && p.h == minH {
			return i
		}
	}
	return len(resPresets)
}

// mountState 是一个源目录当前能不能访问。
type mountState int

const (
	mountUnknown mountState = iota // 还没检查 / 正在检查
	mountOK
	mountMissing // 不存在（多半是卷没挂载）
	mountSlow    // 几秒内没响应（网络卷卡住）
)

// dirPanel 是一个目录列表（「筛选+采样」或「仅采样」）及其选择状态。
type dirPanel struct {
	dirs   *[]string
	chosen ui.Selection[string]
	list   ui.ListState
}

// runResult 是最近一次运行的结果。
type runResult struct {
	sum core.Summary
	err error
	at  time.Time
}

// progress 是运行中的阶段和进度。
type progress struct {
	stage       core.Stage
	done, total int
}

// runStats 是运行中的进度和筛选阶段的删除情况（由 core.Reporter.OnDelete 结构化回调维护）。
type runStats struct {
	prog                                  progress
	copyT0                                time.Time // 复制阶段开始的时间，算剩余时间用
	runDelete                             bool      // 这次运行是否真删（否则是模拟运行，只判定不合格）
	runRejected, runDeleted, runDelFailed int
	lastDel                               logEntry // 最近一张待删除/已删除的图片
}

// previewState 是大图预览、删除原图确认、编号跳转和移出的撤销记录。
type previewState struct {
	preview        bool
	previewIdx     int
	big            map[string]*ui.Bitmap // 解码好的大图（当前这张和前后几张，pumpPreview）；值为 nil 表示读不了
	bigBusy        bool                  // 正在后台解码一张大图：同一时间只解一张
	confirmDelSrc  bool
	pendingDelWall string    // 要删除原图的那张壁纸（壁纸文件夹里的路径）
	jumpBuf        string    // 正在输入的跳转编号
	wheelAcc       float32   // 触控板滚动攒下的距离，够一页翻一张（wheelStep）
	wheelAt        time.Time // 上一次触控板滚动的时间：停顿一会儿就把 wheelAcc 清零
	undo           []removedWall
	undoSeq        int
}

// keyRecorder 是「快捷键」页正在录制的状态。
type keyRecorder struct {
	recording    string   // 正在录制快捷键的操作 id
	recordIgnore []ui.Key // 开始录制时已经按着的键（比如按空格点的录制按钮），松开前不算
	keyErr       string   // 上次录制被拒绝的原因
	keyErrFor    string
}

// app 是窗口显示的全部状态。view 只在主线程运行；后台 goroutine 通过 update 改状态。
type app struct {
	cfgPath string
	paths   core.Paths
	version string // 打包后的版本号（mygo.json 的 version）；开发运行和测试里为空

	cfg     core.Config
	saved   core.Config // 最近一次写入磁盘的配置，用来判断是否需要自动保存
	cfgRev  uint64      // 配置变更序号：用于 publishRemote 零开销判定是否需要重新序列化快照
	saveErr string
	num     float64 // NumberInput 编辑 float64，保存时转回 int
	minW    float64
	minH    float64
	modeIdx int
	preset  int // resPresets 的下标，len(resPresets) 表示自定义

	page      string
	prevPage  string // 上一帧的页面：切页时把开着的说明气泡收起来
	filter       dirPanel
	sample       dirPanel
	mounts       map[string]mountState
	mountProbing map[string]bool // 正在后台执行 stat 的目录（按 mountKey 规范化），防止挂起卷重复泄漏线程
	mountSeq     map[string]int  // 每个目录的探测序号，防止旧探针乱序覆盖新状态
	logShown     bool
	logReveal bool // 下一帧把日志滚到可见处（错误卡片的「查看日志」）
	log       []string
	logList   ui.ListState
	// 日志的解析缓存（logview.go），只解析新追加的行
	logParsed       []logEntry
	logParsedFirst  string
	logProblemsOnly bool
	logRows         []int // 当前筛选下要显示的行号
	logRowsOnly     bool  // logRows 是按哪种筛选算出来的
	logProblems     int   // 解析结果里问题有几行
	// 删除记录页的两个类型标签：都关着就是全部；delClosed 记着收起来的日期（2006-01-02）
	delFilter   bool
	delManual   bool
	delClosed   map[string]bool
	running     bool
	runStats    // 这次运行的进度和删除情况，开始运行时整体清零
	last        *runResult
	skipConfirm bool        // 删除原图前不再弹确认框（重新打开删除开关后恢复）
	prevDelete  bool        // 上一帧「删除不合格原图」的值，用来发现它被重新打开
	stopReq     atomic.Bool // 用户点了「停止」，流程在安全的地方停下
	toast       string
	initialized bool

	walls          wallpapers      // 当前壁纸文件夹的缩略图
	wallQuery      string          // 壁纸页的搜索词（按文件名）
	wallFolder     string          // 壁纸页筛选的原图目录，"" 表示全部
	wallSelecting  bool            // 壁纸页在选择模式：点格子是勾选，不是看大图
	wallSel        map[string]bool // 壁纸页勾选的壁纸
	wallGrid       ui.GridState    // 壁纸页网格的滚动位置：GridView 只建看得见的行
	wallHeadH      float32         // 壁纸页头部（标题 + 筛选条）的高度，上一帧量到的
	wallBarH       float32         // 选择操作条的高度，上一帧量到的
	wallFilterKey  string          // 上次的筛选条件；变了就把网格滚回顶部
	previewState                   // 大图预览（preview.go、undo.go）
	keyRecorder                    // 「快捷键」页的录制状态（keysview.go）
	wallsGen       int             // 每次运行结束 +1，提示需要重新读取壁纸文件夹
	wallsLoadedGen int

	// 以下由 main 注入：真实窗口里是 Window.Update / 系统对话框，测试里是假的实现。
	autoIdx  int           // 「自动换壁纸」选中的是 autoRunHours 的第几项；配置里是别的值时为 -1
	started  time.Time     // 应用启动时间：从没运行过时，自动换壁纸从这里开始计时
	lastGood *core.Summary // 最近一次成功运行的结果（图库统计、空间预估用；运行中 a.last 是 nil）
	delCache deleteCache
	// 概览页缩略图网格：上一帧量到的可视高度、整页高度，和据此算出的行列数（stripLayout）
	viewH, pageH         float32
	viewW                float32 // 内容滚动区的宽度（上一帧），设置类页面据此决定单栏还是两栏
	stripCols, stripRows int
	update               func(fn func())             // 在主线程上执行 fn 并重绘
	pickDir              func(title string) string   // 选择目录，取消返回 ""
	pickFile             func(title string) string   // 选择 JSON 配置文件，取消返回 ""
	showErr              func(title, message string) // 弹出错误提示（不阻塞调用方）
	// confirmDelete 在运行前确认会删除原图（会阻塞，后台调用）；返回是否继续、是否勾了「不再提示」。
	// 为 nil 时不确认（测试）。
	confirmDelete func(detail string) (ok, dontAsk bool)
	openPath      func(path string)      // 在 Finder 中打开
	revealPath    func(path string)      // 在 Finder 中显示并选中这个文件
	statDir       func(path string) bool // 目录是否存在（可能阻塞）
	run           func(core.Config, core.Reporter) (core.Summary, error)
	// scanWallpapers 读取壁纸文件夹、生成缩略图（后台调用）；为 nil 时不显示缩略图（测试）。
	scanWallpapers func(dir string) scannedWallpapers
	// onRunState 在主线程上报运行开始（running=true）和结束（running=false，err 为结果），
	// 用来更新 Dock 角标；可以为 nil。
	onRunState func(running bool, err error)
	// setMenuKeys 把菜单栏命令（keyActions 里 menu 为 true 的）的快捷键交给菜单；测试里为 nil。
	setMenuKeys func(map[string]string)
	// showWindow 把隐藏的窗口重新显示出来（手机请求配对时）；测试里为 nil。
	showWindow func()
	remote     *remoteServer // 手机遥控服务，只在设置里打开时监听
	pairOpen   bool          // 配对码弹层是否显示
	pairCode   string        // 弹层显示的是哪一个配对码（新的请求来了重新弹出）
	qrOpen     bool          // 「扫码配对」二维码弹层是否显示
	qrCode     string        // 二维码里那个配对码（配对成功后收起弹层）
	qrBitmap   *ui.Bitmap    // 二维码图
	qrURL      string        // 二维码里的地址（shijing://pair?…）
	renameOpen bool          // 「重命名手机」弹层是否显示
	renameFrom string        // 改的是列表里哪一台（改之前的名字）
	renameText string        // 输入框里的新名字

	pendMu    sync.Mutex
	pendLog   []string
	pendProg  *progress
	pendDel   []core.DeleteEvent
	pendSched bool
	logSeq    uint64 // 日志追加序号，用于 publishRemote 零开销判定 lastLine 是否可能变化

	committed       bool        // 本轮 a.update 是否已执行过 commitState，防止 onMain 与 a.update 重复发布
	lastRemoteStamp remoteStamp // 上一次发布给手机遥控的状态指纹，未变化时跳过快照序列化
	remotePublished bool        // 是否已经成功发布过至少一次快照

	// 图库没连上时排队的「删除原图」（pending.go）：loadPending 启动时读，连上后自动执行
	pending         []core.PendingDelete
	pendingBusy     bool // 正在后台执行队列
	pendingShown    bool // 「待删除的原图」弹层
	pendingMu       sync.Mutex
	pendingCanceled map[string]bool // 后台 RunPending 执行期间被取消的路径
	deletingWalls   map[string]bool // 正在后台删除 NAS 原图的壁纸路径，防重复点击
	stopTimers      func()          // 退出前停止后台定时器（main.go 注入）
}

func newApp(cfgPath string, paths core.Paths) *app {
	a := &app{cfgPath: cfgPath, paths: paths, page: pageOverview, mounts: map[string]mountState{}, started: time.Now()}
	a.logList.FollowEnd = true
	a.run = func(cfg core.Config, rep core.Reporter) (core.Summary, error) {
		return core.RunPipeline(cfg, paths, rep, nil)
	}
	a.scanWallpapers = scanWallpapers
	a.statDir = func(p string) bool {
		st, err := os.Stat(p)
		return err == nil && st.IsDir()
	}
	cfg, err := core.LoadConfig(cfgPath)
	switch {
	case err == nil:
	case errors.Is(err, os.ErrNotExist):
		// 第一次运行：用默认值，有改动时自动保存
	default:
		// 坏文件先改名留着：下一次自动保存会用默认值写 config.json，不备份就丢了
		msg := "⚠️ 读取配置失败，已使用默认值: " + err.Error()
		if bak := core.BackupBadConfig(cfgPath); bak != "" {
			msg += "（原文件已另存为 " + filepath.Base(bak) + "）"
		}
		a.appendLog(msg)
	}
	a.setConfig(cfg)
	a.saved = a.buildConfig()
	a.loadUIState()
	a.remote = newRemoteServer(a, filepath.Join(filepath.Dir(cfgPath), "remote_devices.json"))
	return a
}

// settingsPatch 是需要局部修改的设置项；nil 字段保持原值。
// 设置页的派生切换与手机遥控 POST /api/settings 都通过 app.applySettings 应用，
// 保证 a.cfg 与界面影子字段（num/minW/minH/modeIdx/autoIdx/preset）始终同步。
type settingsPatch struct {
	SampleCount  *int    `json:"sample_count"`
	AutoRunHours *int    `json:"auto_run_hours"`
	Delete       *bool   `json:"delete_during_filter"`
	PreferUnseen *bool   `json:"prefer_unseen"`
	Refresh      *bool   `json:"refresh_wallpaper"`
	BalanceFirst *bool   `json:"balance_first"`
	Incremental  *bool   `json:"incremental"`
	Mode         *string `json:"mode"`
	MinWidth     *int    `json:"min_width"`
	MinHeight    *int    `json:"min_height"`
	Archive      *bool   `json:"archive_enabled"`
}

// syncShadowFromConfig 从 a.cfg 刷新界面控件绑定的影子字段。
func (a *app) syncShadowFromConfig() {
	a.num = float64(a.cfg.SampleCount)
	a.minW = float64(a.cfg.MinWidth)
	a.minH = float64(a.cfg.MinHeight)
	a.modeIdx = max(0, slices.Index(modes, a.cfg.Mode))
	a.autoIdx = slices.Index(autoRunHours, a.cfg.AutoRunHours)
	a.preset = presetFor(a.cfg.MinWidth, a.cfg.MinHeight)
}

// syncConfigFromShadow 把界面控件直绑的影子字段写回 a.cfg，消除两套表示之间的漂移。
func (a *app) syncConfigFromShadow() {
	a.cfg.SampleCount = int(a.num)
	a.cfg.MinWidth = int(a.minW)
	a.cfg.MinHeight = int(a.minH)
	a.cfg.Mode = modes[max(0, a.modeIdx)]
	if a.autoIdx >= 0 {
		a.cfg.AutoRunHours = autoRunHours[a.autoIdx]
	}
}

// applySettings 是修改常用设置的统一入口：同时更新 a.cfg 和界面影子字段（含分辨率预设下标），
// 返回实际发生变化的字段描述列表供日志记录。调用方负责前置参数范围校验。
func (a *app) applySettings(p settingsPatch) (changed []string) {
	a.syncConfigFromShadow()
	if n := p.SampleCount; n != nil && a.cfg.SampleCount != *n {
		a.cfg.SampleCount = *n
		a.num = float64(*n)
		changed = append(changed, "每次张数 "+strconv.Itoa(*n))
	}
	if h := p.AutoRunHours; h != nil {
		if idx := slices.Index(autoRunHours, *h); idx >= 0 && a.autoIdx != idx {
			a.cfg.AutoRunHours = autoRunHours[idx]
			a.autoIdx = idx
			changed = append(changed, "自动换 "+autoRunLabel(autoRunHours[idx]))
		}
	}
	if m := p.Mode; m != nil {
		if idx := slices.Index(modes, *m); idx >= 0 && a.modeIdx != idx {
			a.cfg.Mode = modes[idx]
			a.modeIdx = idx
			changed = append(changed, "存放方式 "+modeLabel(modes[idx]))
		}
	}
	if p.MinWidth != nil || p.MinHeight != nil {
		w, h := a.cfg.MinWidth, a.cfg.MinHeight
		if p.MinWidth != nil {
			w = *p.MinWidth
		}
		if p.MinHeight != nil {
			h = *p.MinHeight
		}
		if a.cfg.MinWidth != w || a.cfg.MinHeight != h {
			a.cfg.MinWidth, a.cfg.MinHeight = w, h
			a.minW, a.minH = float64(w), float64(h)
			// 桌面设置页的预设选择跟着同步（对不上任何预设就是「自定义」）
			a.preset = presetFor(w, h)
			changed = append(changed, fmt.Sprintf("最低分辨率 %d×%d", w, h))
		}
	}
	setBool := func(dst *bool, v *bool, name string) {
		if v != nil && *dst != *v {
			*dst = *v
			changed = append(changed, name+onOff(*v))
		}
	}
	setBool(&a.cfg.DeleteDuringFilter, p.Delete, "删除不合格原图")
	setBool(&a.cfg.PreferUnseen, p.PreferUnseen, "优先选未更换过的")
	setBool(&a.cfg.RefreshWallpaper, p.Refresh, "刷新系统壁纸")
	setBool(&a.cfg.BalanceFirst, p.BalanceFirst, "平衡采样")
	setBool(&a.cfg.Incremental, p.Incremental, "增量筛选")
	setBool(&a.cfg.ArchiveEnabled, p.Archive, "归档")
	return changed
}

// setConfig 把配置载入界面状态。
func (a *app) setConfig(cfg core.Config) {
	a.cfg = cfg
	a.filter.dirs = &a.cfg.FilterAndSampleDirs
	a.sample.dirs = &a.cfg.SampleOnlyDirs
	a.filter.chosen.Clear()
	a.sample.chosen.Clear()
	a.prevDelete = cfg.DeleteDuringFilter
	a.syncShadowFromConfig()
	a.cfgRev++
}

// buildConfig 从界面状态生成配置（目录列表复制一份，后台运行不受界面编辑影响）。
func (a *app) buildConfig() core.Config {
	a.syncConfigFromShadow()
	cfg := a.cfg
	cfg.FilterAndSampleDirs = slices.Clone(a.cfg.FilterAndSampleDirs)
	cfg.SampleOnlyDirs = slices.Clone(a.cfg.SampleOnlyDirs)
	cfg.Excluded = slices.Clone(a.cfg.Excluded)
	cfg.Shortcuts = maps.Clone(a.cfg.Shortcuts)
	return cfg
}

// configMatchesSaved 无分配比较当前界面状态与上次落盘的 saved 是否一致。
func (a *app) configMatchesSaved() bool {
	a.syncConfigFromShadow()
	c, s := &a.cfg, &a.saved
	return c.DestDir == s.DestDir &&
		c.SampleCount == s.SampleCount &&
		c.MinWidth == s.MinWidth &&
		c.MinHeight == s.MinHeight &&
		c.Mode == s.Mode &&
		c.BalanceFirst == s.BalanceFirst &&
		c.Incremental == s.Incremental &&
		c.DeleteDuringFilter == s.DeleteDuringFilter &&
		c.RefreshWallpaper == s.RefreshWallpaper &&
		c.ArchiveEnabled == s.ArchiveEnabled &&
		c.ArchiveSubdirName == s.ArchiveSubdirName &&
		c.ArchiveDirOverride == s.ArchiveDirOverride &&
		c.ArchiveSMBRoot == s.ArchiveSMBRoot &&
		c.ArchiveNFSRoot == s.ArchiveNFSRoot &&
		c.PreferUnseen == s.PreferUnseen &&
		c.AutoRunHours == s.AutoRunHours &&
		c.RemoteEnabled == s.RemoteEnabled &&
		slices.Equal(c.FilterAndSampleDirs, s.FilterAndSampleDirs) &&
		slices.Equal(c.SampleOnlyDirs, s.SampleOnlyDirs) &&
		slices.Equal(c.Excluded, s.Excluded) &&
		maps.Equal(c.Shortcuts, s.Shortcuts)
}

// autosave 在配置变化时写盘。失败只在侧边栏提示，不弹窗打断。
func (a *app) autosave() {
	if a.configMatchesSaved() {
		return
	}
	a.cfgRev++
	cfg := a.buildConfig()
	if err := core.SaveConfig(a.cfgPath, cfg); err != nil {
		a.saveErr = err.Error()
		return
	}
	a.saved, a.saveErr = cfg, ""
}

// commitState 同步依赖配置的派生状态、按需落盘并向手机遥控发布最新快照。
// view()（窗口可见）与 a.update / remote.onMain（后台或窗口隐藏）统一调用，
// 避免窗口隐藏时遥控修改设置或「不再选」名单未落盘。
func (a *app) commitState() {
	// 「删除不合格原图」被重新打开：恢复运行前的确认
	if a.cfg.DeleteDuringFilter && !a.prevDelete && a.skipConfirm {
		a.skipConfirm = false
		a.saveUIState()
	}
	a.prevDelete = a.cfg.DeleteDuringFilter
	a.autosave()
	a.publishRemote()
	a.committed = true
}

func (a *app) allDirs() []string {
	return append(slices.Clone(a.cfg.FilterAndSampleDirs), a.cfg.SampleOnlyDirs...)
}
