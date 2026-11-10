package main

import (
	"errors"
	"fmt"
	"os"
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
	pageArchive  = "archive"
	pageAbout    = "about"
)

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
	prog            progress
	last            *runResult
	skipConfirm     bool        // 删除原图前不再弹确认框（重新打开删除开关后恢复）
	prevDelete      bool        // 上一帧「删除不合格原图」的值，用来发现它被重新打开
	stopReq         atomic.Bool // 用户点了「停止」，流程在安全的地方停下
	toast           string
	initialized     bool

	walls          wallpapers // 当前壁纸文件夹的缩略图
	wallsGen       int        // 每次运行结束 +1，提示需要重新读取壁纸文件夹
	wallsLoadedGen int

	// 以下由 main 注入：真实窗口里是 Window.Update / 系统对话框，测试里是假的实现。
	update   func(fn func())             // 在主线程上执行 fn 并重绘
	pickDir  func(title string) string   // 选择目录，取消返回 ""
	pickFile func(title string) string   // 选择 JSON 配置文件，取消返回 ""
	showErr  func(title, message string) // 弹出错误提示（不阻塞调用方）
	// confirmDelete 在运行前确认会删除原图（会阻塞，后台调用）；返回是否继续、是否勾了「不再提示」。
	// 为 nil 时不确认（测试）。
	confirmDelete func(detail string) (ok, dontAsk bool)
	openPath      func(path string)      // 在 Finder 中打开
	statDir       func(path string) bool // 目录是否存在（可能阻塞）
	run           func(core.Config, core.Reporter) (core.Summary, error)
	// scanWallpapers 读取壁纸文件夹、生成缩略图（后台调用）；为 nil 时不显示缩略图（测试）。
	scanWallpapers func(dir string) scannedWallpapers
	// onRunState 在主线程上报运行开始（running=true）和结束（running=false，err 为结果），
	// 用来更新 Dock 角标；可以为 nil。
	onRunState func(running bool, err error)

	pendMu    sync.Mutex
	pendLog   []string
	pendProg  *progress
	pendSched bool
}

func newApp(cfgPath string, paths core.Paths) *app {
	a := &app{cfgPath: cfgPath, paths: paths, page: pageOverview, mounts: map[string]mountState{}}
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
	detail := fmt.Sprintf("会先检查「筛选 + 采样」里的 %d 个目录，把竖屏、正方形和低于 %d×%d 的图片从图库里直接删除，不可撤销。"+
		"删除记录写在数据目录的删除日志里。", len(a.cfg.FilterAndSampleDirs), int(a.minW), int(a.minH))
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

// stopRun 请求停止：筛选在文件夹之间停，复制时不再开始新的图片。
func (a *app) stopRun() {
	if a.running && !a.stopReq.Load() {
		a.stopReq.Store(true)
		a.appendLog("⏹️ 正在停止…")
	}
}

func (a *app) startRun() {
	if !a.canRun() {
		return
	}
	a.autosave()
	cfg := a.buildConfig()
	a.running = true
	a.prog = progress{}
	a.last = nil
	a.stopReq.Store(false)
	a.appendLog(strings.Repeat("─", 50))
	a.appendLog("▶ " + time.Now().Format("2006-01-02 15:04:05") + " 开始运行")
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
			a.prog = *prog
		}
	})
}

// appendLog 只能在主线程调用。
func (a *app) appendLog(text string) {
	a.log = append(a.log, strings.Split(text, "\n")...)
	if over := len(a.log) - maxLogLines; over > 0 {
		a.log = slices.Delete(a.log, 0, over)
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
			result := make(chan bool, 1)
			go func() { result <- a.statDir(d) }()
			state := mountSlow
			select {
			case ok := <-result:
				state = mountMissing
				if ok {
					state = mountOK
				}
			case <-time.After(3 * time.Second):
			}
			a.update(func() { a.mounts[d] = state })
		}()
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
			a.checkMounts()
			a.toast = "已导入配置"
			a.appendLog("📥 已导入配置: " + path)
		})
	}()
}
