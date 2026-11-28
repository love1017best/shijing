package main

import (
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// slideIntervals 是幻灯片自动切图的可选间隔（秒）。
var slideIntervals = []int{5, 10, 20, 30, 60}

const (
	slideFadeDur = 700 * time.Millisecond
	slideHUDDur  = 3500 * time.Millisecond
	slideWaitMax = 3 * time.Second
)

// slideshowState 是幻灯片模式的状态（嵌入 app，主线程读写；slideOpenAtomic 供后台定时器快速短路）。
// 视图渲染在 slideshowview.go。
type slideshowState struct {
	slideOpen        bool
	slideOpenAtomic  atomic.Bool
	slidePlaying     bool
	slideIntervalSec int
	slideShuffle     bool
	slideCover       bool
	slideShowInfo    bool
	slideKeepAwake   bool

	// A/B 双槽位实现平滑交叉淡入淡出：slotIdx 表示当前显示的是槽 0 还是槽 1。
	slideSlots     [2]string
	slideSlot      int
	slidePath      string
	slideOrder     []string // 随机模式下的播放顺序
	slideOrderRev  string   // 构建 slideOrder 时的壁纸列表指纹
	slideNextAt    time.Time
	slideWaitSince time.Time // 等待下一张大图解码开始的时刻
	slideHudUntil  time.Time
	slideHudHover  bool
	slideNow       time.Time
	slideEnteredFS bool // 是否由幻灯片主动切入系统全屏（退出时还原）
	slideAwakeOn   bool // 当前防息屏断言是否处于激活状态
	slideLastX     float32
	slideLastY     float32
	slideHasPtr    bool
}

func defaultSlideshowState() slideshowState {
	return slideshowState{
		slideIntervalSec: 10,
		slideCover:       true,
		slideShowInfo:    true,
		slideKeepAwake:   true,
	}
}

// slideIntervalLabel 返回间隔按钮的简短标签（如「10秒」「1分」）。
func slideIntervalLabel(sec int) string {
	if sec >= 60 && sec%60 == 0 {
		return fmt.Sprintf("%d分", sec/60)
	}
	return fmt.Sprintf("%d秒", sec)
}

func slideFileTitle(path string) string {
	base := filepath.Base(path)
	ext := filepath.Ext(base)
	if ext != "" && len(ext) < len(base) {
		return strings.TrimSuffix(base, ext)
	}
	return base
}

var chineseWeekdays = [...]string{"周日", "周一", "周二", "周三", "周四", "周五", "周六"}

func slideDateText(t time.Time) string {
	return fmt.Sprintf("%d月%d日 %s", t.Month(), t.Day(), chineseWeekdays[t.Weekday()])
}

func (a *app) slideInterval() time.Duration {
	if a.slideIntervalSec <= 0 {
		return 10 * time.Second
	}
	return time.Duration(a.slideIntervalSec) * time.Second
}

// openSlideshowOf 从指定壁纸开始进入幻灯片模式（铺满当前窗口，可随时切全屏）。
func (a *app) openSlideshowOf(wall string) {
	all := a.walls.all
	if len(all) == 0 || a.running {
		return
	}
	if !slices.Contains(all, wall) {
		wall = all[0]
	}
	now := time.Now()
	a.preview = false
	a.slideOpen = true
	a.slideOpenAtomic.Store(true)
	a.slidePlaying = true
	a.slidePath = wall
	a.slideSlot = 0
	a.slideSlots = [2]string{wall, ""}
	a.slideOrder = nil
	a.slideOrderRev = ""
	if a.slideShuffle {
		a.ensureSlideOrder(wall)
	}
	a.slideNow = now
	a.slideNextAt = now.Add(a.slideInterval())
	a.slideWaitSince = time.Time{}
	a.slideHudUntil = now.Add(slideHUDDur)
	a.slideHudHover = false
	a.slideEnteredFS = false
	a.slideHasPtr = false
	a.syncSlideKeepAwake()
	a.pumpPreview()
}

// closeSlideshow 退出幻灯片模式并释放防息屏；restoreFS 为 true 且本次由幻灯片主动进了全屏时还原窗口。
func (a *app) closeSlideshow(restoreFS bool) {
	if !a.slideOpen {
		return
	}
	a.slideOpen = false
	a.slideOpenAtomic.Store(false)
	a.slidePlaying = false
	a.slideSlots = [2]string{}
	a.slideWaitSince = time.Time{}
	a.slideHudHover = false
	a.syncSlideKeepAwake()
	if restoreFS && a.slideEnteredFS && a.setFullScreen != nil && a.isFullScreen != nil && a.isFullScreen() {
		a.setFullScreen(false)
	}
	a.slideEnteredFS = false
	if !a.preview {
		a.big = nil
	}
}

// openPreviewFromSlideshow 退出幻灯片并直接跳转到当前这张图的常规大图预览（用于整理）。
func (a *app) openPreviewFromSlideshow() {
	wall := a.slidePath
	a.closeSlideshow(true)
	if wall != "" {
		a.openPreviewOf(wall)
	}
}

// syncSlideKeepAwake 根据幻灯片播放状态同步显示器防息屏。
func (a *app) syncSlideKeepAwake() {
	want := a.slideOpen && a.slidePlaying && a.slideKeepAwake
	if want == a.slideAwakeOn {
		return
	}
	a.slideAwakeOn = want
	if a.setKeepAwake != nil {
		a.setKeepAwake(want)
	}
}

// slideList 返回当前幻灯片使用的有序壁纸列表（顺序用 walls.all，随机用洗牌后的 slideOrder）。
func (a *app) slideList() []string {
	all := a.walls.all
	if len(all) == 0 {
		return nil
	}
	if !a.slideShuffle {
		return all
	}
	a.ensureSlideOrder(a.slidePath)
	return a.slideOrder
}

func (a *app) ensureSlideOrder(first string) {
	all := a.walls.all
	rev := a.walls.cachedRev()
	if len(a.slideOrder) == len(all) && a.slideOrderRev == rev {
		return
	}
	order := slices.Clone(all)
	rand.Shuffle(len(order), func(i, j int) { order[i], order[j] = order[j], order[i] })
	if i := slices.Index(order, first); i > 0 {
		order[0], order[i] = order[i], order[0]
	}
	a.slideOrder = order
	a.slideOrderRev = rev
}

// slideIndex 返回当前图片在 slideList 里的下标。
func (a *app) slideIndex() (int, []string) {
	list := a.slideList()
	if len(list) == 0 {
		return -1, nil
	}
	if i := slices.Index(list, a.slidePath); i >= 0 {
		return i, list
	}
	a.slidePath = list[0]
	a.slideSlots[a.slideSlot] = list[0]
	return 0, list
}

// slideStep 按方向切到上一张或下一张，切换 A/B 槽位以触发平滑交叉淡入淡出。
func (a *app) slideStep(delta int, now time.Time) {
	idx, list := a.slideIndex()
	if len(list) <= 1 || idx < 0 {
		return
	}
	next := list[((idx+delta)%len(list)+len(list))%len(list)]
	if next == a.slidePath {
		return
	}
	a.slideSlot = 1 - a.slideSlot
	a.slideSlots[a.slideSlot] = next
	a.slidePath = next
	a.slideNextAt = now.Add(a.slideInterval())
	a.slideWaitSince = time.Time{}
	a.pumpPreview()
}

// slideNextWall 返回下一张要播放的图片路径（用于预取和判断大图是否就绪）。
func (a *app) slideNextWall() string {
	idx, list := a.slideIndex()
	if len(list) <= 1 || idx < 0 {
		return ""
	}
	return list[(idx+1)%len(list)]
}

// tickSlideshow 每秒由定时器调用：更新时钟、检查控制条自动隐藏、到点时推进下一张。
func (a *app) tickSlideshow(now time.Time) {
	if !a.slideOpen {
		return
	}
	if a.running || len(a.walls.all) == 0 {
		a.closeSlideshow(true)
		return
	}
	a.slideNow = now
	if !a.slidePlaying || len(a.walls.all) <= 1 {
		return
	}
	if now.Before(a.slideNextAt) {
		return
	}
	// 等下一张大图解码就绪再切，避免闪缩略图；最多等 slideWaitMax 兜底
	next := a.slideNextWall()
	if next != "" && a.big[next] == nil {
		if _, tried := a.big[next]; !tried {
			a.pumpPreview()
			if a.slideWaitSince.IsZero() {
				a.slideWaitSince = now
			}
			if now.Sub(a.slideWaitSince) < slideWaitMax {
				return
			}
		}
	}
	a.slideStep(1, now)
}

func (a *app) touchSlideHUD(now time.Time) {
	a.slideHudUntil = now.Add(slideHUDDur)
}

func (a *app) toggleSlidePlay(now time.Time) {
	a.slidePlaying = !a.slidePlaying
	if a.slidePlaying {
		a.slideNextAt = now.Add(a.slideInterval())
	}
	a.slideWaitSince = time.Time{}
	a.touchSlideHUD(now)
	a.syncSlideKeepAwake()
}

func (a *app) cycleSlideInterval(now time.Time) {
	next := slideIntervals[0]
	for i, v := range slideIntervals {
		if v == a.slideIntervalSec {
			next = slideIntervals[(i+1)%len(slideIntervals)]
			break
		}
	}
	a.slideIntervalSec = next
	if a.slidePlaying {
		a.slideNextAt = now.Add(a.slideInterval())
	}
	a.touchSlideHUD(now)
	a.saveUIState()
}

func (a *app) toggleSlideShuffle(now time.Time) {
	a.slideShuffle = !a.slideShuffle
	a.slideOrder = nil
	a.slideOrderRev = ""
	if a.slideShuffle {
		a.ensureSlideOrder(a.slidePath)
	}
	a.touchSlideHUD(now)
	a.saveUIState()
	a.pumpPreview()
}

func (a *app) toggleSlideFullScreen(now time.Time) {
	if a.setFullScreen == nil || a.isFullScreen == nil {
		return
	}
	if a.isFullScreen() {
		a.setFullScreen(false)
		a.slideEnteredFS = false
	} else {
		a.setFullScreen(true)
		a.slideEnteredFS = true
	}
	a.touchSlideHUD(now)
}

// slidePrevPath 返回淡出槽位里保留的上一张图路径，供 pumpPreview 在过渡期间保留缓存。
func (a *app) slidePrevPath() string {
	if !a.slideOpen {
		return ""
	}
	return a.slideSlots[1-a.slideSlot]
}

// displayAwakeGuard 通过 macOS 自带的 caffeinate -d -w <pid> 在幻灯片播放期间防止显示器休眠。
// 绑定当前进程 pid，即使应用异常退出，caffeinate 也会随之自动结束，不会残留。
type displayAwakeGuard struct {
	mu  sync.Mutex
	cmd *exec.Cmd
}

func (g *displayAwakeGuard) Set(on bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if on {
		if g.cmd != nil {
			return
		}
		cmd := exec.Command("caffeinate", "-d", "-w", strconv.Itoa(os.Getpid()))
		if err := cmd.Start(); err != nil {
			return
		}
		g.cmd = cmd
		go func(c *exec.Cmd) { _ = c.Wait() }(cmd)
		return
	}
	if g.cmd != nil {
		if g.cmd.Process != nil {
			_ = g.cmd.Process.Kill()
		}
		g.cmd = nil
	}
}
