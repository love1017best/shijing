package main

import (
	"image"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

func TestSlideshowPlaybackAndPreferences(t *testing.T) {
	f, tt := newFakeApp(t)
	img := image.NewRGBA(image.Rect(0, 0, 16, 9))
	bmp := ui.NewBitmap(img)
	walls := []string{"/w/a.jpg", "/w/b.jpg", "/w/c.jpg"}
	f.walls = wallpapers{
		dir:      core.ExpandUser(f.cfg.DestDir),
		hero:     bmp,
		heroPath: walls[0],
		thumbs:   map[string]*ui.Bitmap{walls[0]: bmp, walls[1]: bmp, walls[2]: bmp},
		all:      walls,
	}
	f.wallsLoadedGen = f.wallsGen
	var awakeEvents []bool
	f.setKeepAwake = func(on bool) { awakeEvents = append(awakeEvents, on) }
	fs := false
	f.isFullScreen = func() bool { return fs }
	f.setFullScreen = func(v bool) { fs = v }

	tt.Frame()
	f.openSlideshowOf(walls[0])
	f.big = map[string]*ui.Bitmap{walls[0]: bmp, walls[1]: bmp, walls[2]: bmp}
	tt.Frame()

	if !f.slideOpen || !f.slidePlaying || f.slidePath != walls[0] {
		t.Fatalf("进入幻灯片状态异常: open=%v playing=%v path=%q", f.slideOpen, f.slidePlaying, f.slidePath)
	}
	if len(awakeEvents) != 1 || !awakeEvents[0] {
		t.Fatalf("播放中应开启防息屏: %v", awakeEvents)
	}

	// 到点自动切到下一张
	t1 := f.slideNextAt.Add(time.Second)
	f.tickSlideshow(t1)
	tt.Frame()
	if f.slidePath != walls[1] {
		t.Fatalf("到点应切到下一张 b.jpg，实际 %q", f.slidePath)
	}

	// 暂停：释放防息屏且不再自动切图
	click(t, tt, "暂停")
	tt.Frame()
	if f.slidePlaying {
		t.Fatal("点暂停后应处于暂停状态")
	}
	if len(awakeEvents) != 2 || awakeEvents[1] {
		t.Fatalf("暂停后应释放防息屏: %v", awakeEvents)
	}
	f.tickSlideshow(t1.Add(time.Minute))
	if f.slidePath != walls[1] {
		t.Fatalf("暂停期间不应切图，实际 %q", f.slidePath)
	}

	// 继续播放并切到全屏
	click(t, tt, "播放")
	tt.Frame()
	if !f.slidePlaying || len(awakeEvents) != 3 || !awakeEvents[2] {
		t.Fatalf("继续播放应重新开启防息屏: playing=%v awake=%v", f.slidePlaying, awakeEvents)
	}
	click(t, tt, "全屏")
	tt.Frame()
	if !fs || !f.slideEnteredFS {
		t.Fatalf("点全屏应切入系统全屏: fs=%v entered=%v", fs, f.slideEnteredFS)
	}

	// 调整间隔、关闭时钟和防息屏并验证持久化
	click(t, tt, "切换间隔") // 10 -> 20
	click(t, tt, "填充方式") // cover -> contain
	click(t, tt, "时钟与文件名")
	click(t, tt, "防息屏")
	tt.Frame()
	if f.slideIntervalSec != 20 || f.slideCover || f.slideShowInfo || f.slideKeepAwake {
		t.Fatalf("偏好切换异常: interval=%d cover=%v info=%v awake=%v",
			f.slideIntervalSec, f.slideCover, f.slideShowInfo, f.slideKeepAwake)
	}
	if len(awakeEvents) != 4 || awakeEvents[3] {
		t.Fatalf("关闭防息屏开关应立刻释放断言: %v", awakeEvents)
	}

	// 重新加载 ui_state.json 确认偏好已持久化
	f2 := newApp(f.cfgPath, core.PathsIn(filepath.Dir(f.cfgPath)))
	if f2.slideIntervalSec != 20 || f2.slideCover || f2.slideShowInfo || f2.slideKeepAwake {
		t.Fatalf("ui_state.json 未正确持久化幻灯片偏好: interval=%d cover=%v info=%v awake=%v",
			f2.slideIntervalSec, f2.slideCover, f2.slideShowInfo, f2.slideKeepAwake)
	}

	// 点击「整理当前壁纸」：退出幻灯片、还原全屏，并打开当前图 b.jpg 的常规大图预览
	click(t, tt, "整理当前壁纸")
	tt.Frame()
	if f.slideOpen || fs || !f.preview || f.previewIdx != 1 {
		t.Fatalf("跳转整理异常: slide=%v fs=%v preview=%v idx=%d", f.slideOpen, fs, f.preview, f.previewIdx)
	}
}

func TestSlideshowAutoExitsOnRun(t *testing.T) {
	f, tt := newFakeApp(t)
	img := image.NewRGBA(image.Rect(0, 0, 16, 9))
	bmp := ui.NewBitmap(img)
	f.walls = wallpapers{
		dir:      core.ExpandUser(f.cfg.DestDir),
		hero:     bmp,
		heroPath: "/w/a.jpg",
		all:      []string{"/w/a.jpg", "/w/b.jpg"},
	}
	f.wallsLoadedGen = f.wallsGen
	awake := false
	f.setKeepAwake = func(on bool) { awake = on }

	f.openSlideshowOf("/w/a.jpg")
	tt.Frame()
	if !f.slideOpen || !awake {
		t.Fatalf("预期进入幻灯片并开启防息屏: open=%v awake=%v", f.slideOpen, awake)
	}
	f.running = true
	tt.Frame()
	if f.slideOpen || awake {
		t.Fatalf("开始换一批壁纸时应自动退出幻灯片并释放防息屏: open=%v awake=%v", f.slideOpen, awake)
	}
}

func TestSlideshowOrderStepWaitAndFormatting(t *testing.T) {
	// 格式化辅助
	if got := slideIntervalLabel(5); got != "5秒" {
		t.Fatalf("5秒标签错误: %q", got)
	}
	if got := slideIntervalLabel(60); got != "1分" {
		t.Fatalf("60秒标签错误: %q", got)
	}
	if got := slideIntervalLabel(90); got != "90秒" {
		t.Fatalf("90秒标签错误: %q", got)
	}
	if got := slideFileTitle("/a/b/sunset.4k.jpg"); got != "sunset.4k" {
		t.Fatalf("去扩展名错误: %q", got)
	}
	if got := slideFileTitle("/a/b/.hidden"); got != ".hidden" {
		t.Fatalf("隐藏文件名不应去空: %q", got)
	}
	dt := time.Date(2026, 11, 28, 20, 0, 0, 0, time.UTC) // 周六
	if got := slideDateText(dt); got != "11月28日 周六" {
		t.Fatalf("日期格式错误: %q", got)
	}

	f, _ := newFakeApp(t)
	walls := []string{"/w/a.jpg", "/w/b.jpg", "/w/c.jpg", "/w/d.jpg"}
	f.walls = wallpapers{dir: core.ExpandUser(f.cfg.DestDir), all: walls}
	f.wallsLoadedGen = f.wallsGen
	f.openSlideshowOf(walls[1])

	// 反向循环与大步长负偏移，并验证 A/B 槽位交替与 slidePrevPath
	now := time.Now()
	f.slideStep(-1, now)
	if f.slidePath != walls[0] || f.slidePrevPath() != walls[1] {
		t.Fatalf("后退一步异常: path=%q prev=%q", f.slidePath, f.slidePrevPath())
	}
	f.slideStep(-5, now) // 0 - 5 ≡ 3 (mod 4)
	if f.slidePath != walls[3] || f.slidePrevPath() != walls[0] {
		t.Fatalf("跨圈负步长异常: path=%q prev=%q", f.slidePath, f.slidePrevPath())
	}

	// 开启随机：当前图保持在第 0 位，且包含全部元素
	f.toggleSlideShuffle(now)
	order := f.slideList()
	if len(order) != len(walls) || order[0] != walls[3] {
		t.Fatalf("随机顺序首项应为当前图 %q: %v", walls[3], order)
	}
	sorted := slices.Clone(order)
	slices.Sort(sorted)
	if !slices.Equal(sorted, walls) {
		t.Fatalf("随机顺序元素集合不一致: %v", order)
	}
	// 列表未变化时复用已有随机顺序
	order2 := f.slideList()
	if !slices.Equal(order, order2) {
		t.Fatalf("列表未变时不应重新洗牌: %v vs %v", order, order2)
	}

	// 下一张大图尚未解码时，最多等待 slideWaitMax 再兜底切换
	f.toggleSlideShuffle(now) // 回到顺序
	f.big = map[string]*ui.Bitmap{}
	cur := f.slidePath
	next := f.slideNextWall()
	due := f.slideNextAt
	f.tickSlideshow(due)
	if f.slidePath != cur {
		t.Fatalf("下一张未解码时首次到点应暂缓切图，实际已切到 %q", f.slidePath)
	}
	f.tickSlideshow(due.Add(slideWaitMax - time.Second))
	if f.slidePath != cur {
		t.Fatalf("未满 slideWaitMax 时仍应等待，实际已切到 %q", f.slidePath)
	}
	f.tickSlideshow(due.Add(slideWaitMax))
	if f.slidePath != next {
		t.Fatalf("达到 slideWaitMax 应兜底切到 %q，实际 %q", next, f.slidePath)
	}
}
