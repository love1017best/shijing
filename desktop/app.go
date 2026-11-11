package main

import (
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
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

// runStats 是运行中的进度和筛选阶段的删除情况（删除数从日志行里数出来，见 countDeletion）。
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
	saveErr string
	num     float64 // NumberInput 编辑 float64，保存时转回 int
	minW    float64
	minH    float64
	modeIdx int
	preset  int // resPresets 的下标，len(resPresets) 表示自定义

	page      string
	filter    dirPanel
	sample    dirPanel
	mounts    map[string]mountState
	logShown  bool
	logReveal bool // 下一帧把日志滚到可见处（错误卡片的「查看日志」）
	log       []string
	logList   ui.ListState
	// 日志的解析缓存（logview.go），只解析新追加的行
	logParsed       []logEntry
	logParsedFirst  string
	logProblemsOnly bool
	running         bool
	runStats        // 这次运行的进度和删除情况，开始运行时整体清零
	last            *runResult
	skipConfirm     bool        // 删除原图前不再弹确认框（重新打开删除开关后恢复）
	prevDelete      bool        // 上一帧「删除不合格原图」的值，用来发现它被重新打开
	stopReq         atomic.Bool // 用户点了「停止」，流程在安全的地方停下
	toast           string
	initialized     bool

	walls          wallpapers // 当前壁纸文件夹的缩略图
	previewState              // 大图预览（preview.go、undo.go）
	keyRecorder               // 「快捷键」页的录制状态（keysview.go）
	wallsGen       int        // 每次运行结束 +1，提示需要重新读取壁纸文件夹
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

	pendMu    sync.Mutex
	pendLog   []string
	pendProg  *progress
	pendSched bool
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
		a.appendLog("⚠️ 读取配置失败，已使用默认值: " + err.Error())
	}
	a.setConfig(cfg)
	a.saved = a.buildConfig()
	a.loadUIState()
	a.remote = newRemoteServer(a, filepath.Join(filepath.Dir(cfgPath), "remote_devices.json"))
	return a
}

// setConfig 把配置载入界面状态。
func (a *app) setConfig(cfg core.Config) {
	a.cfg = cfg
	a.filter.dirs = &a.cfg.FilterAndSampleDirs
	a.sample.dirs = &a.cfg.SampleOnlyDirs
	a.filter.chosen.Clear()
	a.sample.chosen.Clear()
	a.num = float64(cfg.SampleCount)
	a.minW = float64(cfg.MinWidth)
	a.minH = float64(cfg.MinHeight)
	a.modeIdx = max(0, slices.Index(modes, cfg.Mode))
	a.autoIdx = slices.Index(autoRunHours, cfg.AutoRunHours)
	a.prevDelete = cfg.DeleteDuringFilter
	a.preset = len(resPresets)
	for i, p := range resPresets {
		if p.w == cfg.MinWidth && p.h == cfg.MinHeight {
			a.preset = i
		}
	}
}

// buildConfig 从界面状态生成配置（目录列表复制一份，后台运行不受界面编辑影响）。
func (a *app) buildConfig() core.Config {
	cfg := a.cfg
	cfg.FilterAndSampleDirs = slices.Clone(a.cfg.FilterAndSampleDirs)
	cfg.SampleOnlyDirs = slices.Clone(a.cfg.SampleOnlyDirs)
	cfg.SampleCount = int(a.num)
	cfg.MinWidth = int(a.minW)
	cfg.MinHeight = int(a.minH)
	cfg.Mode = modes[a.modeIdx]
	cfg.Excluded = slices.Clone(a.cfg.Excluded)
	cfg.Shortcuts = maps.Clone(a.cfg.Shortcuts)
	if a.autoIdx >= 0 {
		cfg.AutoRunHours = autoRunHours[a.autoIdx]
	}
	return cfg
}

// autosave 在每次构建界面后调用：配置变了就写盘。失败只在侧边栏提示，不弹窗打断。
func (a *app) autosave() {
	cfg := a.buildConfig()
	if reflect.DeepEqual(cfg, a.saved) {
		return
	}
	if err := core.SaveConfig(a.cfgPath, cfg); err != nil {
		a.saveErr = err.Error()
		return
	}
	a.saved, a.saveErr = cfg, ""
}

func (a *app) allDirs() []string {
	return append(slices.Clone(a.cfg.FilterAndSampleDirs), a.cfg.SampleOnlyDirs...)
}

// ── 运行 ──────────────────────────────────────────────────────────────────

// canRun 是「换一批壁纸」能不能点：没在运行、图库不为空、不是所有目录都没挂载、设了壁纸文件夹。
func (a *app) canRun() bool {
	dirs := a.allDirs()
	return !a.running && len(dirs) > 0 && a.unmountedCount() < len(dirs) && strings.TrimSpace(a.cfg.DestDir) != ""
}

// requestRun 是「换一批壁纸」按钮和 ⌘R：会删除原图时先确认，再开始运行。
func (a *app) requestRun() {
	if !a.canRun() {
		return
	}
	if !a.cfg.DeleteDuringFilter || len(a.cfg.FilterAndSampleDirs) == 0 || a.skipConfirm || a.confirmDelete == nil {
		a.startRun()
		return
	}
	detail := a.deleteNotice()
	go func() {
		ok, dontAsk := a.confirmDelete(detail)
		if !ok {
			return
		}
		a.update(func() {
			if dontAsk {
				a.skipConfirm = true
				a.saveUIState()
			}
			a.startRun()
		})
	}()
}

// willDelete 是这次运行会不会真的删除原图（打开了删除、并且有「筛选 + 采样」目录）。
func (a *app) willDelete() bool {
	return a.cfg.DeleteDuringFilter && len(a.cfg.FilterAndSampleDirs) > 0
}

// deleteNotice 是运行前确认删除原图时的说明（桌面的确认框和手机上的确认都用它）。
func (a *app) deleteNotice() string {
	return fmt.Sprintf("会先检查「筛选 + 采样」里的 %d 个目录，把竖屏、正方形和低于 %d×%d 的图片从图库里直接删除，不可撤销。"+
		"删除记录写在数据目录的删除日志里。", len(a.cfg.FilterAndSampleDirs), int(a.minW), int(a.minH))
}

// stopRun 请求停止：筛选在文件夹之间停，复制时不再开始新的图片。
func (a *app) stopRun() {
	if a.running && !a.stopReq.Load() {
		a.stopReq.Store(true)
		a.appendLog("⏹️ 正在停止…")
	}
}

func (a *app) startRun() { a.startRunWith(runOpts{}) }

// runOpts 是一次运行的来源和限制。
type runOpts struct {
	auto     bool   // 定时自动运行：不删除原图（筛选只模拟），也不弹删除确认
	noDelete bool   // 这次不删除原图，筛选只模拟（手机上选了「只模拟」）
	from     string // 从哪台手机遥控的，空是本机
}

// startRunWith 开始运行（调用方负责删除原图前的确认）。
func (a *app) startRunWith(o runOpts) {
	if !a.canRun() {
		return
	}
	a.autosave()
	cfg := a.buildConfig()
	auto := o.auto
	if auto || o.noDelete {
		cfg.DeleteDuringFilter = false
	}
	a.clearUndo() // 换一批会清空壁纸文件夹，之前的移出没法再放回去
	a.running = true
	a.last = nil
	a.runStats = runStats{runDelete: cfg.DeleteDuringFilter}
	a.stopReq.Store(false)
	a.appendLog(strings.Repeat("─", 50))
	a.appendLog("▶ " + time.Now().Format("2006-01-02 15:04:05") + " 开始运行")
	if auto {
		a.appendLog(fmt.Sprintf("⏰ 定时自动运行（%s），这次不删除原图，只模拟筛选", autoRunLabel(cfg.AutoRunHours)))
	}
	if o.from != "" {
		note := ""
		if o.noDelete && a.willDelete() {
			note = "，这次只模拟筛选、不删除原图"
		}
		a.appendLog(fmt.Sprintf("📱 由「%s」遥控运行%s", o.from, note))
	}
	rep := core.Reporter{Log: a.logf, Progress: a.progressf, Stop: a.stopReq.Load}
	if a.onRunState != nil {
		a.onRunState(true, nil)
	}
	go func() {
		core.ValidateConfig(cfg, a.logf)
		sum, err := a.run(cfg, rep)
		switch {
		case errors.Is(err, core.ErrCanceled):
			a.logf("⏹️ 已停止")
		case err != nil:
			a.logf("❌ %v", err)
		}
		a.flush()
		a.update(func() {
			a.running = false
			a.last = &runResult{sum: sum, err: err, at: time.Now()}
			if err == nil {
				a.lastGood = &sum
			}
			a.saveUIState()
			a.wallsGen++ // 壁纸文件夹换了一批，重新读缩略图
			switch {
			case err == nil:
				a.toast = fmt.Sprintf("已换上 %d 张新壁纸", sum.Copy.Copied)
			case errors.Is(err, core.ErrCanceled):
				a.toast = "已停止"
			}
			if a.onRunState != nil {
				a.onRunState(false, err)
			}
		})
	}()
}

// ── 日志与进度（任意 goroutine 可调用，攒批后每 80ms 刷一次界面）───────────────

func (a *app) logf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	a.pendMu.Lock()
	a.pendLog = append(a.pendLog, line)
	a.scheduleLocked()
	a.pendMu.Unlock()
}

func (a *app) progressf(stage core.Stage, done, total int) {
	a.pendMu.Lock()
	a.pendProg = &progress{stage, done, total}
	a.scheduleLocked()
	a.pendMu.Unlock()
}

func (a *app) scheduleLocked() {
	if !a.pendSched {
		a.pendSched = true
		time.AfterFunc(80*time.Millisecond, a.flush)
	}
}

func (a *app) flush() {
	a.pendMu.Lock()
	lines, prog := a.pendLog, a.pendProg
	a.pendLog, a.pendProg, a.pendSched = nil, nil, false
	a.pendMu.Unlock()
	if len(lines) == 0 && prog == nil {
		return
	}
	a.update(func() {
		if len(lines) > 0 {
			a.appendLog(strings.Join(lines, "\n"))
		}
		if prog != nil {
			if prog.stage == core.StageCopy && a.prog.stage != core.StageCopy {
				a.copyT0 = time.Now()
			}
			a.prog = *prog
		}
	})
}

// appendLog 只能在主线程调用。
func (a *app) appendLog(text string) {
	lines := strings.Split(text, "\n")
	if a.running {
		for _, l := range lines {
			a.countDeletion(l)
		}
	}
	a.log = append(a.log, lines...)
	if over := len(a.log) - maxLogLines; over > 0 {
		a.log = slices.Delete(a.log, 0, over)
	}
}

// countDeletion 数筛选阶段的「[文件夹] 🗑️ 待删除 / 🔥 已删除 / ❌ 删除失败」行。
func (a *app) countDeletion(line string) {
	raw := strings.TrimSpace(line)
	if !strings.HasPrefix(raw, "[") {
		return
	}
	if strings.Contains(raw, "删除失败") {
		a.runDelFailed++
		return
	}
	e := parseLogLine(line)
	if e.kind != logDelete {
		return
	}
	switch e.label {
	case "待删除":
		a.runRejected++
	case "已删除":
		a.runDeleted++
	}
	// 真删时只记真正删掉的那张（待删除之后可能删除失败），模拟运行时记不合格的那张
	if (e.label == "已删除") == a.runDelete {
		a.lastDel = e
	}
}

// lastLogLine 是运行中显示在进度条下的那一行。
func (a *app) lastLogLine() string {
	for i := len(a.log) - 1; i >= 0; i-- {
		if s := strings.TrimSpace(a.log[i]); s != "" && !strings.HasPrefix(s, "===") {
			return s
		}
	}
	return ""
}

// ── 挂载状态 ──────────────────────────────────────────────────────────────

// checkMounts 在后台检查每个源目录是否可访问。网络卷卡住时 stat 可能阻塞很久，
// 所以每个目录单独一个 goroutine，3 秒没结果就标成「无响应」。
func (a *app) checkMounts() {
	for _, d := range a.allDirs() {
		a.mounts[d] = mountUnknown
		go func() {
			state := probeMount(a.statDir, d)
			a.update(func() { a.mounts[d] = state })
		}()
	}
}

// probeMount 检查一个目录能不能访问（会阻塞，最多 3 秒）。
func probeMount(stat func(string) bool, d string) mountState {
	result := make(chan bool, 1)
	go func() { result <- stat(d) }()
	select {
	case ok := <-result:
		if ok {
			return mountOK
		}
		return mountMissing
	case <-time.After(3 * time.Second):
		return mountSlow
	}
}

func (a *app) unmountedCount() int {
	n := 0
	for _, d := range a.allDirs() {
		if s := a.mounts[d]; s == mountMissing || s == mountSlow {
			n++
		}
	}
	return n
}

// ── 目录选择 ──────────────────────────────────────────────────────────────

// browse 在后台弹出目录选择框（它会阻塞），选好后回到主线程写入。
func (a *app) browse(title string, apply func(path string)) {
	go func() {
		if p := a.pickDir(title); p != "" {
			a.update(func() { apply(p) })
		}
	}()
}

func (a *app) addDir(p *dirPanel) {
	a.browse("添加图库目录", func(path string) {
		if slices.Contains(a.allDirs(), path) {
			a.toast = "这个目录已经在图库里了"
			return
		}
		*p.dirs = append(*p.dirs, path)
		a.mounts[path] = mountOK // 刚从对话框选出来，一定可访问
	})
}

// addDropped 把拖进来的文件夹加进图库（文件、已经在图库里的跳过）。
func (a *app) addDropped(p *dirPanel, paths []string) {
	added, skipped := 0, 0
	for _, path := range paths {
		if st, err := os.Stat(path); err != nil || !st.IsDir() || slices.Contains(a.allDirs(), path) {
			skipped++
			continue
		}
		*p.dirs = append(*p.dirs, path)
		a.mounts[path] = mountOK
		added++
	}
	switch {
	case added > 0 && skipped > 0:
		a.toast = fmt.Sprintf("已添加 %d 个目录，跳过 %d 个（不是文件夹或已经在图库里）", added, skipped)
	case added > 0:
		a.toast = fmt.Sprintf("已添加 %d 个目录", added)
	default:
		a.toast = "没有可添加的文件夹（只能拖文件夹，已经在图库里的会跳过）"
	}
}

func (a *app) removeDir(p *dirPanel, dir string) {
	*p.dirs = slices.DeleteFunc(*p.dirs, func(d string) bool { return d == dir })
	p.chosen.Clear()
}

func (a *app) removeChosen(p *dirPanel) {
	*p.dirs = slices.DeleteFunc(*p.dirs, func(d string) bool { return p.chosen.Has(d) })
	p.chosen.Clear()
}

func (a *app) importConfig() {
	go func() {
		path := a.pickFile("导入配置（选择一个 config.json）")
		if path == "" {
			return
		}
		cfg, err := core.LoadConfig(path)
		if err != nil {
			a.showErr("导入失败", err.Error())
			return
		}
		a.update(func() {
			a.setConfig(cfg)
			a.syncMenuKeys()
			a.checkMounts()
			a.toast = "已导入配置"
			a.appendLog("📥 已导入配置: " + path)
		})
	}()
}
