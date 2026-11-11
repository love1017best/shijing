package main

import (
	"errors"
	"fmt"
	"image"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

// fakeApp 用同步队列代替 Window.Update，用固定返回值代替系统对话框。
type fakeApp struct {
	*app
	mu      sync.Mutex
	queue   []func()
	dirs    []string // pickDir 依次返回的目录
	opened  []string
	runCfgs []core.Config
	runErr  error
	release chan struct{} // 非 nil 时，假的流程会等它关闭才返回
}

func newFakeApp(t *testing.T) (*fakeApp, *ui.Tester) {
	dir := t.TempDir()
	f := &fakeApp{app: newApp(filepath.Join(dir, "config.json"), core.PathsIn(dir))}
	f.update = func(fn func()) {
		f.mu.Lock()
		f.queue = append(f.queue, fn)
		f.mu.Unlock()
	}
	f.pickDir = func(string) string {
		f.mu.Lock()
		defer f.mu.Unlock()
		if len(f.dirs) == 0 {
			return ""
		}
		d := f.dirs[0]
		f.dirs = f.dirs[1:]
		return d
	}
	f.pickFile = func(string) string { return "" }
	f.showErr = func(title, msg string) { t.Errorf("意外的错误弹窗 %s: %s", title, msg) }
	f.openPath = func(p string) { f.opened = append(f.opened, p) }
	f.statDir = func(p string) bool { return !strings.Contains(p, "Offline") }
	f.scanWallpapers = nil // 不读真实的壁纸文件夹
	f.run = func(cfg core.Config, rep core.Reporter) (core.Summary, error) {
		f.runCfgs = append(f.runCfgs, cfg)
		rep.Log("fake pipeline ran")
		rep.Progress(core.StageCopy, 1, 2)
		sum := core.Summary{Elapsed: 1500 * time.Millisecond}
		sum.Copy = core.CopyResult{Selected: 2, Copied: 2, Dest: "/tmp/wall"}
		for f.release != nil { // 等测试放行，或者被「停止」
			select {
			case <-f.release:
				return sum, f.runErr
			case <-time.After(5 * time.Millisecond):
				if rep.Stop() {
					sum.Copy.Copied = 1
					return sum, core.ErrCanceled
				}
			}
		}
		return sum, f.runErr
	}
	return f, ui.NewTesterWith(f.view, 1040, 1100, ui.TesterOptions{})
}

// settle 把后台排队的更新在"主线程"（测试 goroutine）上执行，再渲染一帧，直到 want 成立。
func (f *fakeApp) settle(t *testing.T, tt *ui.Tester, want func() bool) {
	t.Helper()
	for range 300 {
		f.mu.Lock()
		q := f.queue
		f.queue = nil
		f.mu.Unlock()
		for _, fn := range q {
			fn()
		}
		tt.Frame()
		if want() {
			return
		}
		time.Sleep(10 * time.Millisecond) // 让后台 goroutine 和日志刷新定时器执行
	}
	t.Fatal("等待超时")
}

func click(t *testing.T, tt *ui.Tester, label string) {
	t.Helper()
	if err := tt.Click(label); err != nil {
		t.Fatal(err)
	}
}

// control 按名字找输入控件（文本框；数字框在无障碍树里是 Group），跳过同名的标签文字。
func control(tt *ui.Tester, name string) (ui.AccessInfo, bool) {
	for _, r := range []ui.Role{ui.RoleTextField, ui.RoleGroup, ui.RoleStepper} {
		if info, ok := tt.AccessByRole(r, name); ok {
			return info, true
		}
	}
	return ui.AccessInfo{}, false
}

func TestLibraryAddRemoveAndMountStatus(t *testing.T) {
	f, tt := newFakeApp(t)
	click(t, tt, "图库")
	f.dirs = []string{"/Volumes/Media0/A", "/Volumes/Offline/B"}

	click(t, tt, "筛选 + 采样 添加")
	f.settle(t, tt, func() bool { return len(f.cfg.FilterAndSampleDirs) == 1 })
	click(t, tt, "仅采样 添加")
	f.settle(t, tt, func() bool { return len(f.cfg.SampleOnlyDirs) == 1 })

	// 重新检查挂载：Offline 那个应标成未挂载，侧边栏显示提示
	click(t, tt, "重新检查挂载")
	f.settle(t, tt, func() bool { return tt.HasText("未挂载") })
	if !tt.HasText("1 未挂载") {
		t.Errorf("侧边栏应提示有目录未挂载: %q", tt.Texts())
	}

	// 选中 A 再移除，自动保存到磁盘
	click(t, tt, "A")
	click(t, tt, "筛选 + 采样 移除")
	tt.Frame()
	if len(f.cfg.FilterAndSampleDirs) != 0 {
		t.Fatalf("移除后: %q", f.cfg.FilterAndSampleDirs)
	}
	saved, err := core.LoadConfig(f.cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(saved.FilterAndSampleDirs) != 0 || !slices.Equal(saved.SampleOnlyDirs, []string{"/Volumes/Offline/B"}) {
		t.Errorf("自动保存的配置不对: %+v", saved)
	}

	// 重复添加同一个目录会被拒绝
	f.dirs = []string{"/Volumes/Offline/B"}
	click(t, tt, "筛选 + 采样 添加")
	f.settle(t, tt, func() bool { f.mu.Lock(); defer f.mu.Unlock(); return len(f.dirs) == 0 && len(f.queue) == 0 })
	tt.Frame()
	if len(f.cfg.FilterAndSampleDirs) != 0 {
		t.Error("重复目录不应被添加")
	}
}

func TestSettingsAutosaveAndPresets(t *testing.T) {
	f, tt := newFakeApp(t)
	click(t, tt, "设置")

	click(t, tt, "软链接")
	click(t, tt, "2K")
	tt.Frame()
	saved, err := core.LoadConfig(f.cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Mode != "symlink" || saved.MinWidth != 2560 || saved.MinHeight != 1440 {
		t.Errorf("自动保存的配置不对: mode=%s %dx%d", saved.Mode, saved.MinWidth, saved.MinHeight)
	}
	if _, ok := control(tt, "最小宽度"); ok {
		t.Error("选了预设时不应显示自定义宽高")
	}
	if !tt.HasText("2560 × 1440") {
		t.Error("预设应标出实际像素")
	}
	click(t, tt, "自定义")
	if info, ok := control(tt, "最小宽度"); !ok || info.Disabled {
		t.Errorf("自定义时宽高应可编辑: %+v %v", info, ok)
	}

	click(t, tt, "刷新系统壁纸")
	if f.cfg.RefreshWallpaper {
		t.Fatal("开关应关闭")
	}
}

func TestArchiveToggleEnablesFields(t *testing.T) {
	f, tt := newFakeApp(t)
	click(t, tt, "归档")
	if info, ok := tt.AccessByRole(ui.RoleTextField, "归档文件夹名"); !ok || !info.Disabled {
		t.Errorf("归档未开启时字段应禁用: %+v %v", info, ok)
	}
	click(t, tt, "启用归档")
	if !f.cfg.ArchiveEnabled {
		t.Fatal("归档应开启")
	}
	if info, ok := tt.AccessByRole(ui.RoleTextField, "归档文件夹名"); !ok || info.Disabled {
		t.Errorf("开启归档后字段应可编辑: %+v %v", info, ok)
	}
	if !tt.HasText("开") {
		t.Error("侧边栏应标出归档已开启")
	}
}

func TestRunShowsProgressThenResult(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Media0/Fav"}
	f.release = make(chan struct{})
	tt.Frame()

	click(t, tt, "换一批壁纸")
	if !f.running {
		t.Fatal("点击后应进入运行状态")
	}
	f.settle(t, tt, func() bool { return tt.HasText("复制 1 / 2 张") })
	if _, ok := tt.AccessByRole(ui.RoleProgress, "复制 1 / 2 张"); !ok {
		t.Error("运行中应显示进度条")
	}
	close(f.release)
	f.settle(t, tt, func() bool { return !f.running && tt.HasText("已换上 2 张新壁纸") })

	if len(f.runCfgs) != 1 || !slices.Equal(f.runCfgs[0].SampleOnlyDirs, []string{"/Volumes/Media0/Fav"}) {
		t.Errorf("传给流程的配置: %+v", f.runCfgs)
	}
	click(t, tt, "打开壁纸文件夹")
	if !slices.Equal(f.opened, []string{"/tmp/wall"}) {
		t.Errorf("应打开目标目录: %q", f.opened)
	}
	click(t, tt, fmt.Sprintf("运行日志（%d 行）", len(f.log)))
	if !tt.HasText("fake pipeline ran") {
		t.Error("展开日志后应能看到流程输出")
	}
}

func TestRunFailureKeepsMessage(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Media0/Fav"}
	f.runErr = core.ErrNoImages
	tt.Frame()
	click(t, tt, "换一批壁纸")
	f.settle(t, tt, func() bool { return !f.running && tt.HasText("这次没有换成") })
	if !errors.Is(f.last.err, core.ErrNoImages) || !tt.HasText(core.ErrNoImages.Error()) {
		t.Errorf("应显示失败原因: %q", tt.Texts())
	}
}

func TestRunDisabledWithoutDirs(t *testing.T) {
	f, tt := newFakeApp(t)
	tt.Frame()
	if info, ok := tt.AccessByRole(ui.RoleButton, "换一批壁纸"); !ok || !info.Disabled {
		t.Error("图库为空时不能运行")
	}
	_ = f
}

func TestRunStopAndResultSurvivesRestart(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Media0/Fav"}
	f.release = make(chan struct{})
	tt.Frame()
	click(t, tt, "换一批壁纸")
	f.settle(t, tt, func() bool { return tt.HasText("复制 1 / 2 张") })
	click(t, tt, "停止")
	f.settle(t, tt, func() bool { return !f.running && tt.HasText("已停止") })
	if !errors.Is(f.last.err, core.ErrCanceled) || !tt.HasText("换上了 1 张新壁纸") {
		t.Errorf("停止后应说明保留了几张: %q", tt.Texts())
	}

	// 重启后「上次运行」仍在
	b := newApp(f.cfgPath, f.paths)
	if b.last == nil || !errors.Is(b.last.err, core.ErrCanceled) || b.last.sum.Copy.Copied != 1 ||
		!b.last.at.Equal(f.last.at) {
		t.Errorf("重启后应读回上次运行: %+v", b.last)
	}
}

func TestDeleteConfirmation(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/A"}
	f.cfg.DeleteDuringFilter = true
	var asked []string
	answer := [2]bool{false, false}
	f.confirmDelete = func(detail string) (bool, bool) {
		f.mu.Lock()
		defer f.mu.Unlock()
		asked = append(asked, detail)
		return answer[0], answer[1]
	}
	idle := func() bool { f.mu.Lock(); defer f.mu.Unlock(); return len(f.queue) == 0 }
	tt.Frame()

	// 取消：不运行
	click(t, tt, "换一批壁纸")
	f.settle(t, tt, func() bool { f.mu.Lock(); defer f.mu.Unlock(); return len(asked) == 1 })
	time.Sleep(20 * time.Millisecond)
	f.settle(t, tt, idle)
	if f.running || len(f.runCfgs) != 0 {
		t.Fatal("取消确认后不应运行")
	}
	if !strings.Contains(asked[0], "3840×2160") {
		t.Errorf("确认框应写明阈值: %s", asked[0])
	}

	// 确认并勾选「不再提示」：运行，下次不再问
	answer = [2]bool{true, true}
	click(t, tt, "换一批壁纸")
	f.settle(t, tt, func() bool { return !f.running && len(f.runCfgs) == 1 })
	click(t, tt, "换一批壁纸")
	f.settle(t, tt, func() bool { return !f.running && len(f.runCfgs) == 2 })
	if len(asked) != 2 {
		t.Errorf("勾了不再提示后不应再问，问了 %d 次", len(asked))
	}

	// 关掉再打开删除开关：恢复确认
	click(t, tt, "设置")
	click(t, tt, "删除不合格原图")
	click(t, tt, "删除不合格原图")
	if !f.cfg.DeleteDuringFilter || f.skipConfirm {
		t.Errorf("重新打开删除后应恢复确认: delete=%v skip=%v", f.cfg.DeleteDuringFilter, f.skipConfirm)
	}
}

func TestRunDisabledWhenAllUnmounted(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Offline/Fav"}
	f.checkMounts()
	f.settle(t, tt, func() bool { return f.unmountedCount() == 1 })
	if info, ok := tt.AccessByRole(ui.RoleButton, "换一批壁纸"); !ok || !info.Disabled {
		t.Error("目录都没挂载时不能运行")
	}
	if !tt.HasText("图库目录都没挂载，连上 NAS 后到「图库」里重新检查") {
		t.Errorf("横幅应说明原因: %q", tt.Texts())
	}
}

func TestThumbnailOpensItsImage(t *testing.T) {
	f, tt := newFakeApp(t)
	img := image.NewRGBA(image.Rect(0, 0, 16, 10))
	f.walls = wallpapers{dir: core.ExpandUser(f.cfg.DestDir), total: 9,
		thumbs: []*ui.Bitmap{ui.NewBitmap(img), ui.NewBitmap(img)}, paths: []string{"/w/a.jpg", "/w/b.jpg"},
		all: []string{"/w/hero.jpg", "/w/a.jpg", "/w/b.jpg", "/w/c.jpg"}}
	f.wallsLoadedGen = f.wallsGen
	tt.Frame()
	click(t, tt, "壁纸 2")
	tt.Frame()
	if !f.preview || !tt.HasText("b.jpg") || !tt.HasText("3 / 4") {
		t.Errorf("点缩略图应打开大图预览，能翻看文件夹里的全部图片: %q", tt.Texts())
	}
	click(t, tt, "下一张")
	if !tt.HasText("c.jpg") || !tt.HasText("4 / 4") || !tt.HasText("正在载入…") {
		t.Errorf("没有缩略图的图片也能预览: %q", tt.Texts())
	}
	click(t, tt, "下一张")
	if !tt.HasText("1 / 4") {
		t.Error("下一张应循环到第一张")
	}
	if !tt.HasText("移出壁纸文件夹") || tt.HasText("删除图库里的原图…") {
		t.Errorf("没有原图记录时只能移出: %q", tt.Texts())
	}
	f.preview = false
	tt.Frame()
	if !tt.HasText("+7") {
		t.Errorf("最后一格应显示剩下的张数: %q", tt.Texts())
	}
}

func TestRunNeedsDestDir(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Media0/Fav"}
	f.cfg.DestDir = " "
	tt.Frame()
	if info, ok := tt.AccessByRole(ui.RoleButton, "换一批壁纸"); !ok || !info.Disabled {
		t.Error("没有壁纸文件夹时不能运行")
	}
	if !tt.HasText("还没有设置壁纸文件夹，先到「设置」里选一个") {
		t.Errorf("横幅应提示设置壁纸文件夹: %q", tt.Texts())
	}
}

func TestLibraryContextMenu(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/A", "/Volumes/Media0/B"}
	click(t, tt, "图库")
	if err := tt.RightClick("B"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("在 Finder 中打开"); err != nil {
		t.Fatalf("%v, 菜单: %q", err, tt.Menu())
	}
	tt.Frame()
	if !slices.Equal(f.opened, []string{"/Volumes/Media0/B"}) {
		t.Errorf("应在 Finder 中打开目录: %q", f.opened)
	}
	if err := tt.RightClick("A"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("移除"); err != nil {
		t.Fatalf("%v, 菜单: %q", err, tt.Menu())
	}
	tt.Frame()
	if !slices.Equal(f.cfg.FilterAndSampleDirs, []string{"/Volumes/Media0/B"}) {
		t.Errorf("右键移除后: %q", f.cfg.FilterAndSampleDirs)
	}
}

func TestCommonParent(t *testing.T) {
	for _, c := range []struct {
		dirs []string
		want string
	}{
		{[]string{"/Volumes/Media0/A", "/Volumes/Media0/B/"}, "/Volumes/Media0"},
		{[]string{"/Volumes/Media0/A", "/Volumes/Offline/B"}, ""},
		{nil, ""},
	} {
		if got := commonParent(c.dirs); got != c.want {
			t.Errorf("commonParent(%q) = %q, want %q", c.dirs, got, c.want)
		}
	}
}

func TestAboutPage(t *testing.T) {
	f, tt := newFakeApp(t)
	click(t, tt, "关于")
	for _, s := range []string{"@love1017best", "开发版"} {
		if !tt.HasText(s) {
			t.Errorf("关于页应显示 %q: %q", s, tt.Texts())
		}
	}
	f.version = "0.2.101"
	tt.Frame()
	if !tt.HasText("v0.2.101") {
		t.Errorf("应显示版本号: %q", tt.Texts())
	}
	click(t, tt, "数据目录 在 Finder 中显示")
	if !slices.Equal(f.opened, []string{filepath.Dir(f.cfgPath)}) {
		t.Errorf("应打开数据目录: %q", f.opened)
	}
}

func TestParseLogLine(t *testing.T) {
	for _, c := range []struct {
		line   string
		kind   logKind
		text   string
		detail string
	}{
		{"", logSkip, "", ""},
		{"==================================================", logSkip, "", ""},
		{strings.Repeat("─", 50), logSkip, "", ""},
		{"▶ 2026-11-09 18:58:24 开始运行", logRun, "11月9日 18:58:24", ""},
		{"⚠️  目录不存在（可能卷未挂载）: /Volumes/Offline/X", logWarn, "目录不存在（可能卷未挂载）: /Volumes/Offline/X", ""},
		{"🗑️  开始筛选目录：3 个", logStage, "开始筛选目录：3 个", ""},
		{"📁 /Volumes/Media0/物恋传媒", logSource, "物恋传媒", "/Volumes/Media0"},
		{"📂 处理文件夹: set0", logFolder, "set0", ""},
		{"    [set0] 🗑️ 待删除: portrait.png", logDelete, "portrait.png", "set0"},
		{"    [set0] 🔥 已删除: a.jpg", logDelete, "a.jpg", "set0"},
		{"    [set0] ❌ 删除失败: a.jpg - busy", logError, "[set0] 删除失败: a.jpg - busy", ""},
		{"🗑️ 待删除图片: 3", logInfo, "待删除图片: 3", ""},
		{"  ├─ set0: ⏭️ 已跳过（无变化）", logSummary, "set0: 已跳过（无变化）", ""},
		{"  └─ set0: 处理 2 张，删除 1 张", logSummary, "set0: 处理 2 张，删除 1 张", ""},
		{"  复制: IMG_1.jpg  ➡️ A-IMG_1.jpg", logCopy, "IMG_1.jpg", "A-IMG_1.jpg"},
		{"失败: x.jpg - permission denied", logError, "失败: x.jpg - permission denied", ""},
		{"✅ 所有操作完成 - 壁纸已更新", logSuccess, "所有操作完成 - 壁纸已更新", ""},
		{"⏹️ 已停止", logStop, "已停止", ""},
	} {
		e := parseLogLine(c.line)
		if e.kind != c.kind || (c.kind != logSkip && (e.text != c.text || e.detail != c.detail)) {
			t.Errorf("parseLogLine(%q) = %d %q %q, want %d %q %q", c.line, e.kind, e.text, e.detail, c.kind, c.text, c.detail)
		}
	}
}

func TestLogFilterProblems(t *testing.T) {
	f, tt := newFakeApp(t)
	f.appendLog("▶ 2026-11-09 18:58:24 开始运行\n📸 开始采样复制：2 个目录\n⚠️ 出了点问题\n  复制: a.jpg")
	f.logShown = true
	tt.Frame()
	tt.Advance(time.Second)
	tt.Frame()
	if !tt.HasText("开始采样复制：2 个目录") {
		t.Fatalf("全部模式应显示所有行: %q", tt.Texts())
	}
	click(t, tt, "只看问题 1")
	if tt.HasText("开始采样复制：2 个目录") || !tt.HasText("出了点问题") {
		t.Errorf("只看问题时应只剩警告: %q", tt.Texts())
	}
}

func TestRunShowsDeletionsAndOverlap(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/Lib"}
	f.cfg.DeleteDuringFilter = true
	f.skipConfirm = true
	f.release = make(chan struct{})
	inner := f.run
	f.run = func(cfg core.Config, rep core.Reporter) (core.Summary, error) {
		rep.Progress(core.StageFilter, 1, 3)
		rep.Log("    [set0] 🗑️ 待删除: a.jpg")
		rep.Log("    [set0] 🔥 已删除: a.jpg")
		rep.Log("    [set1] 🗑️ 待删除: b.jpg")
		rep.Log("    [set1] 🔥 已删除: b.jpg")
		rep.Log("    [set1] 🗑️ 待删除: c.jpg")
		rep.Log("    [set1] ❌ 删除失败: c.jpg - permission denied")
		sum, err := inner(cfg, rep)
		sum.Copy.Selected, sum.Copy.PrevSelected, sum.Copy.Repeated = 2, 2, 1
		return sum, err
	}
	tt.Frame()
	click(t, tt, "换一批壁纸")
	f.settle(t, tt, func() bool { return tt.HasText("已删除 2 张不合格原图") })
	for _, s := range []string{"1 张删除失败", "b.jpg", "在 set1"} {
		if !tt.HasText(s) {
			t.Errorf("运行卡片上应显示 %q", s)
		}
	}
	close(f.release)
	f.settle(t, tt, func() bool { return !f.running && tt.HasText("新换 1 张") })
	if !tt.HasText("重合 50%") {
		t.Error("上次运行应显示和上一轮的重合率")
	}
}

func TestOverlapPercent(t *testing.T) {
	for _, c := range []struct {
		sel, rep int
		want     string
	}{{0, 0, "0%"}, {400, 0, "0%"}, {400, 1, "<1%"}, {400, 28, "7%"}, {4, 4, "100%"}} {
		if got := overlapPercent(core.CopyResult{Selected: c.sel, Repeated: c.rep}); got != c.want {
			t.Errorf("%d/%d = %s, 想要 %s", c.rep, c.sel, got, c.want)
		}
	}
}

func TestStripLayout(t *testing.T) {
	for _, c := range []struct {
		grid               ui.Rect
		pageH, viewH       float32
		wantCols, wantRows int
	}{
		{ui.Rect{}, 0, 0, 6, 1},                    // 第一帧还没量到
		{ui.Rect{W: 750, H: 90}, 900, 700, 5, 1},   // 页面已经比窗口高：只放一行
		{ui.Rect{W: 750, H: 90}, 700, 1000, 5, 4},  // 剩 390 高：每格 88.75 高，4 行加 3 个间距 385
		{ui.Rect{W: 1100, H: 90}, 700, 2000, 7, 6}, // 再高也最多 6 行
		{ui.Rect{W: 400, H: 90}, 700, 700, 4, 1},   // 很窄也至少 4 列
		{ui.Rect{W: 3000, H: 90}, 700, 700, 12, 1}, // 很宽最多 12 列
	} {
		cols, rows := stripLayout(c.grid, c.pageH, c.viewH)
		if cols != c.wantCols || rows != c.wantRows {
			t.Errorf("stripLayout(%v, %v, %v) = %d×%d，想要 %d×%d", c.grid, c.pageH, c.viewH, cols, rows, c.wantCols, c.wantRows)
		}
	}
}

func TestWallpaperActions(t *testing.T) {
	f, _ := newFakeApp(t)
	dir := t.TempDir()
	wall, src := filepath.Join(dir, "wall", "s-a.jpg"), filepath.Join(dir, "lib", "s", "a.jpg")
	for _, p := range []string{wall, src} {
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte("x"), 0o644)
	}
	img := ui.NewBitmap(image.NewRGBA(image.Rect(0, 0, 4, 4)))
	reset := func() {
		os.WriteFile(wall, []byte("x"), 0o644)
		f.walls = wallpapers{total: 1, thumbs: []*ui.Bitmap{img}, paths: []string{wall}, all: []string{wall}, sources: map[string]string{"s-a.jpg": src}}
	}

	reset()
	f.removeWallpaper(wall, true)
	if _, err := os.Stat(wall); !os.IsNotExist(err) || len(f.walls.paths) != 0 || len(f.walls.all) != 0 {
		t.Error("应从壁纸文件夹移除")
	}
	if !slices.Equal(f.cfg.Excluded, []string{src}) || !slices.Equal(f.buildConfig().Excluded, []string{src}) {
		t.Errorf("应加进排除名单: %q", f.cfg.Excluded)
	}

	reset()
	f.deleteOriginal(wall)
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Error("应删除原图")
	}
	reset()
	f.removeWallpaper(wall, false)
	if _, err := os.Stat(filepath.Dir(src)); err != nil {
		t.Error("移出壁纸文件夹不应动原图所在目录")
	}
	if recs := core.ReadDeleteLog(f.paths.DeleteLog); len(recs) != 1 || recs[0].Path != src || recs[0].Reason != "手动删除" {
		t.Errorf("应记进删除记录: %+v", recs)
	}
}

func TestDeletedPageAndLibraryStats(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/Lib"}
	core.LogDeletion(f.paths.DeleteLog, "/Volumes/Media0/Lib/set1/p.jpg", 3840, 2160, "竖屏 1080×1920")
	f.lastGood = &core.Summary{Copy: core.CopyResult{Sources: []core.SourceStat{{Dir: "/Volumes/Media0/Lib", Images: 23456, Folders: 12}}}}
	tt.Frame()
	click(t, tt, "删除记录")
	for _, s := range []string{"p.jpg", "竖屏 1080×1920", "共 1 张"} {
		if !tt.HasText(s) {
			t.Errorf("删除记录页应显示 %q: %q", s, tt.Texts())
		}
	}
	click(t, tt, "图库")
	if !tt.HasText("2.3 万 张 · 12 个文件夹 · 删过 1 张") {
		t.Errorf("图库页应显示目录统计: %q", tt.Texts())
	}
}

func TestAutoRunSkipsDeletion(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/Lib"}
	f.cfg.DeleteDuringFilter = true
	f.autoIdx = slices.Index(autoRunHours, 6)
	tt.Frame()
	f.maybeAutoRun(f.started.Add(5 * time.Hour))
	if f.running {
		t.Fatal("还没到时间不应运行")
	}
	f.maybeAutoRun(f.started.Add(6*time.Hour + time.Minute))
	f.settle(t, tt, func() bool { return !f.running })
	if len(f.runCfgs) != 1 || f.runCfgs[0].DeleteDuringFilter || f.runCfgs[0].AutoRunHours != 6 {
		t.Errorf("定时运行不应删除原图: %+v", f.runCfgs)
	}
}

func TestFitBoxKeepsImageRatio(t *testing.T) {
	for _, c := range []struct {
		iw, ih     int
		maxW, maxH float32
		w, h       float32
	}{
		{1600, 900, 1000, 800, 1000, 562.5}, // 宽度先到上限
		{1600, 900, 1000, 450, 800, 450},    // 高度先到上限
		{900, 1600, 1000, 800, 450, 800},    // 竖图
		{0, 0, 800, 800, 800, 500},          // 还没有图：按 16:10
	} {
		w, h := fitBox(c.iw, c.ih, c.maxW, c.maxH)
		if w != c.w || h != c.h {
			t.Errorf("fitBox(%d×%d, %v×%v) = %v×%v，想要 %v×%v", c.iw, c.ih, c.maxW, c.maxH, w, h, c.w, c.h)
		}
	}
}
