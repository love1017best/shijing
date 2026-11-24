package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"desktop/core"
)

// ── 定时自动换壁纸 ──────────────────────────────────────────────────────────

// autoRunLabel 是间隔的说法：「每 6 小时」「每天」「每周」。
func autoRunLabel(hours int) string {
	switch {
	case hours <= 0:
		return "关闭"
	case hours == 24:
		return "每天"
	case hours == 168:
		return "每周"
	case hours%24 == 0:
		return fmt.Sprintf("每 %d 天", hours/24)
	default:
		return fmt.Sprintf("每 %d 小时", hours)
	}
}

// nextAutoRun 是下一次自动运行的时间；没开启时返回零值。从上次运行（不论成败）开始计时，
// 从没运行过就从应用启动开始计时。
func (a *app) nextAutoRun() time.Time {
	h := a.buildConfig().AutoRunHours
	if h <= 0 {
		return time.Time{}
	}
	base := a.started
	if a.last != nil && a.last.at.After(base) {
		base = a.last.at
	}
	return base.Add(time.Duration(h) * time.Hour)
}

// maybeAutoRun 由后台的定时器每分钟在主线程上调一次（关窗后应用仍在后台运行）。
func (a *app) maybeAutoRun(now time.Time) {
	next := a.nextAutoRun()
	if next.IsZero() || now.Before(next) || a.running || !a.canRun() {
		return
	}
	a.startRunWith(runOpts{auto: true})
}

// ── 删除记录 ──────────────────────────────────────────────────────────────

// deleteCacheTTL 是 deleteRecords() 的 stat 冷却时间，避免鼠标悬停、滚动等高频重绘每帧调 os.Stat。
const deleteCacheTTL = time.Second

// deleteCache 缓存读出来的删除日志，文件没变（大小和修改时间）就不重读。
type deleteCache struct {
	checkedAt time.Time
	exists    bool
	size      int64
	mod       time.Time
	recs      []core.DeleteRecord
	byDir     map[string]int // 图库目录 → 累计删除张数
	dirs      string         // byDir 是按哪组目录算的
}

// invalidateDeleteCache 在本进程写入删除日志或切换至删除记录页时调用，下次读取立即 stat。
func (a *app) invalidateDeleteCache() {
	a.delCache.checkedAt = time.Time{}
}

func (a *app) deleteRecords() []core.DeleteRecord {
	now := time.Now()
	if !a.delCache.checkedAt.IsZero() && now.Sub(a.delCache.checkedAt) < deleteCacheTTL {
		return a.delCache.recs
	}
	st, err := os.Stat(a.paths.DeleteLog)
	if err != nil {
		a.delCache = deleteCache{checkedAt: now}
		return nil
	}
	if !a.delCache.exists || st.Size() != a.delCache.size || !st.ModTime().Equal(a.delCache.mod) {
		a.delCache = deleteCache{
			checkedAt: now,
			exists:    true,
			size:      st.Size(),
			mod:       st.ModTime(),
			recs:      core.ReadDeleteLog(a.paths.DeleteLog),
		}
	} else {
		a.delCache.checkedAt = now
	}
	return a.delCache.recs
}

// deletedIn 是某个图库目录累计删除了几张（按路径前缀从删除日志里数）。
func (a *app) deletedIn(dir string) int {
	recs := a.deleteRecords()
	key := strings.Join(a.allDirs(), "\x00")
	if a.delCache.byDir == nil || a.delCache.dirs != key {
		a.delCache.byDir, a.delCache.dirs = map[string]int{}, key
		for _, r := range recs {
			for _, d := range a.allDirs() {
				prefix := filepath.Clean(core.ExpandUser(d)) + string(filepath.Separator)
				if strings.HasPrefix(r.Path, prefix) {
					a.delCache.byDir[d]++
				}
			}
		}
	}
	return a.delCache.byDir[dir]
}

// ── 统计和预估 ────────────────────────────────────────────────────────────

func (a *app) sourceStat(dir string) (core.SourceStat, bool) {
	if a.lastGood == nil {
		return core.SourceStat{}, false
	}
	for _, s := range a.lastGood.Copy.Sources {
		if s.Dir == core.ExpandUser(dir) || s.Dir == dir {
			return s, true
		}
	}
	return core.SourceStat{}, false
}

// estimateBytes 按上一轮复制的平均大小估算 n 张要占多少空间；没有数据（软链接、没运行过）返回 0。
func (a *app) estimateBytes(n int) (perImage, total int64) {
	if a.lastGood == nil || a.lastGood.Copy.Copied == 0 || a.lastGood.Copy.Bytes == 0 {
		return 0, 0
	}
	per := a.lastGood.Copy.Bytes / int64(a.lastGood.Copy.Copied)
	return per, per * int64(n)
}

func humanBytes(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	default:
		return fmt.Sprintf("%d KB", max(1, n>>10))
	}
}

// humanCount 把大数字写成「2.8 万」。
func humanCount(n int) string {
	if n >= 10000 {
		return strings.TrimSuffix(fmt.Sprintf("%.1f", float64(n)/10000), ".0") + " 万"
	}
	return fmt.Sprint(n)
}

// copyETA 是复制阶段的剩余时间，按已用时间和已复制张数线性估算；刚开始数据太少时返回 ""。
func (a *app) copyETA(now time.Time) string {
	p := a.prog
	if p.stage != core.StageCopy || p.done < 3 || p.total <= p.done || a.copyT0.IsZero() {
		return ""
	}
	elapsed := now.Sub(a.copyT0)
	if elapsed < 2*time.Second {
		return ""
	}
	left := time.Duration(float64(elapsed) / float64(p.done) * float64(p.total-p.done))
	switch {
	case left < time.Minute:
		return fmt.Sprintf("约剩 %d 秒", max(1, int(left.Seconds()+0.5)))
	default:
		return fmt.Sprintf("约剩 %d 分钟", int(left.Minutes()+0.5))
	}
}

// ── 缩略图上的操作 ────────────────────────────────────────────────────────

// 整理操作（移出、删除原图、撤销）出错时返回下面两种错误，不自己弹框：
// 桌面的按钮、菜单、快捷键用 a.report 提示，手机遥控把 err.Error() 写进 409 响应。

// opErr 是要弹错误框的失败，Error() 是「标题：原因」（手机上显示的就是这一句）。
type opErr struct {
	title string
	err   error
}

func (e *opErr) Error() string { return e.title + "：" + e.err.Error() }
func (e *opErr) Unwrap() error { return e.err }

func actionErr(title string, err error) error { return &opErr{title, err} }

// softErr 是不值得弹框的失败（比如同名文件挡着放不回去）：桌面显示成 toast。
type softErr string

func (e softErr) Error() string { return string(e) }

// report 在桌面上提示整理操作的错误；err 为 nil 时什么都不做。只在主线程调用。
func (a *app) report(err error) {
	var op *opErr
	var soft softErr
	switch {
	case err == nil:
	case errors.As(err, &soft):
		a.toast = soft.Error()
	case errors.As(err, &op):
		a.showErr(op.title, op.err.Error())
	default:
		a.showErr("操作失败", err.Error())
	}
}

// wallSource 是壁纸文件夹里这张图对应的原图；没有记录（旧版本换上的）时返回 ""。
func (a *app) wallSource(wall string) string {
	return a.walls.sources[filepath.Base(wall)]
}

// pathInDir 判断规范化后的路径 p 是否位于目录 dir 内（含 dir 本身）。
func pathInDir(p, dir string) bool {
	if dir == "" {
		return false
	}
	if dir == "/" {
		return strings.HasPrefix(p, "/")
	}
	return p == dir || strings.HasPrefix(p, dir+"/")
}

// isSampleOnlySource 判断原图是否处于「仅采样」目录。
// 存在嵌套目录时按最深匹配目录归属；同一目录同时出现在两边时按「仅采样」处理以防误删。
func (a *app) isSampleOnlySource(src string) bool {
	if src == "" {
		return false
	}
	p := mountKey(src)
	longest := func(dirs []string) int {
		best := 0
		for _, raw := range dirs {
			d := mountKey(raw)
			if pathInDir(p, d) && len(d) > best {
				best = len(d)
			}
		}
		return best
	}
	sampleLen := longest(a.cfg.SampleOnlyDirs)
	if sampleLen == 0 {
		return false
	}
	return sampleLen >= longest(a.cfg.FilterAndSampleDirs)
}

// wallDeletable 判断这张壁纸是否允许删除原图：需要有原图记录，且原图不在「仅采样」目录中。
func (a *app) wallDeletable(wall string) bool {
	src := a.wallSource(wall)
	return src != "" && !a.isSampleOnlySource(src)
}

// removeWallpaper 从壁纸文件夹里移除一张（不动原图），exclude 时还把原图加进排除名单。
// 失败返回错误，由调用方决定怎么提示：桌面 a.report 弹框，手机遥控写进响应。
func (a *app) removeWallpaper(wall string, exclude bool) error {
	r := removedWall{wall: wall, idx: slices.Index(a.walls.all, wall), thumb: a.walls.thumbs[wall]}
	stash, err := a.stashWall(wall)
	if os.IsNotExist(err) {
		stash = "" // 文件已经不在了：照样从列表里去掉，只是没法撤销
	} else if err != nil {
		return actionErr("移除失败", err)
	}
	if exclude {
		if src := a.wallSource(wall); src != "" && !slices.Contains(a.cfg.Excluded, src) {
			a.cfg.Excluded = append(a.cfg.Excluded, src)
			r.excluded = src
		}
	}
	a.dropWall(wall)
	if exclude {
		a.toast = "已移出壁纸文件夹，图库中的原图未删除；后续采样将跳过它（⌘Z 撤销）"
	} else {
		a.toast = "已移出壁纸文件夹，图库中的原图未删除（⌘Z 撤销）"
	}
	if stash != "" {
		r.stash = stash
		a.pushUndo(r)
	}
	return nil
}

const deleteSrcTimeout = 3 * time.Second

type removeSrcOutcome int

const (
	removeSrcDone removeSrcOutcome = iota
	removeSrcQueue
	removeSrcPerm
)

// removeSourceWithTimeout 在独立 goroutine 里执行原图删除与父目录校验，避免挂起网络卷卡死调用方。
func removeSourceWithTimeout(src string, timeout time.Duration) (removeSrcOutcome, error) {
	type result struct {
		out removeSrcOutcome
		err error
	}
	ch := make(chan result, 1)
	go func() {
		if err := os.Remove(src); err != nil && !os.IsNotExist(err) {
			if !os.IsPermission(err) { // 删不掉多半是网络卷临时断开：排队等下次
				ch <- result{removeSrcQueue, nil}
				return
			}
			ch <- result{removeSrcPerm, err}
			return
		}
		// 路径不存在要分清「文件真的没了」和「整个卷没挂上」：后者报的也是 ENOENT
		if _, err := os.Lstat(filepath.Dir(src)); os.IsNotExist(err) {
			ch <- result{removeSrcQueue, nil}
			return
		}
		ch <- result{removeSrcDone, nil}
	}()
	select {
	case r := <-ch:
		return r.out, r.err
	case <-time.After(timeout):
		return removeSrcQueue, nil
	}
}

// finishDeleteOriginal 在主线程把后台删原图的结果落地（记日志、删本地壁纸，或转入待删队列）。
// gen 是发起删除时的 a.wallsGen：期间若开始换一批或已换成新批次，只完成原图记账/排队，不动当前壁纸文件夹和撤销栈。
func (a *app) finishDeleteOriginal(wall, src string, gen int, outcome removeSrcOutcome, permErr error) error {
	stale := a.running || a.wallsGen != gen
	switch outcome {
	case removeSrcQueue:
		if stale || !slices.Contains(a.walls.all, wall) {
			a.queueDeleteOnly(wall, src)
			return nil
		}
		return a.queueDelete(wall, src)
	case removeSrcPerm:
		return actionErr("删除原图失败", permErr)
	default:
		core.LogDeletion(a.paths.DeleteLog, src, int(a.minW), int(a.minH), core.ReasonManual)
		a.invalidateDeleteCache()
		a.appendLog(fmt.Sprintf("🔥 手动删除原图: %s", src))
		if !stale {
			if slices.Contains(a.walls.all, wall) {
				_ = os.Remove(wall)
				a.dropWall(wall)
			}
			// 后台删原图期间桌面可能已按 J 移出同一张：移除其撤销项，避免 ⌘Z 把原图已删的壁纸放回
			a.dropUndoForWall(wall)
		}
		a.toast = "已删除图库中的原图，并记进删除记录"
		return nil
	}
}

// deleteOriginal 删除原图（记进删除日志）并从壁纸文件夹移除。调用前已经确认过。
// 图库（NAS）现在连不上时不报错，而是把这一条排进待办队列，连上后自动执行（pending.go）。
func (a *app) deleteOriginal(wall string) error {
	src := a.wallSource(wall)
	if src == "" {
		return nil
	}
	if a.isSampleOnlySource(src) {
		return softErr("这张来自仅采样目录，不可删除原图")
	}
	if a.sourceUnmounted(src) {
		return a.queueDelete(wall, src)
	}
	gen := a.wallsGen
	outcome, permErr := removeSourceWithTimeout(src, deleteSrcTimeout)
	return a.finishDeleteOriginal(wall, src, gen, outcome, permErr)
}

// deleteOriginalAsync 是桌面 UI 入口：网络卷已确认离线时直接排队，否则把 NAS 删除放到后台带超时执行，
// 避免挂起的 SMB/NFS 卷阻塞主线程界面和遥控服务。
func (a *app) deleteOriginalAsync(wall string) {
	src := a.wallSource(wall)
	if src == "" || a.isSampleOnlySource(src) {
		return
	}
	if a.deletingWalls[wall] {
		return
	}
	if a.sourceUnmounted(src) {
		a.report(a.queueDelete(wall, src))
		return
	}
	if a.update == nil {
		a.report(a.deleteOriginal(wall))
		return
	}
	if a.deletingWalls == nil {
		a.deletingWalls = map[string]bool{}
	}
	a.deletingWalls[wall] = true
	gen := a.wallsGen
	go func() {
		outcome, permErr := removeSourceWithTimeout(src, deleteSrcTimeout)
		a.update(func() {
			delete(a.deletingWalls, wall)
			a.report(a.finishDeleteOriginal(wall, src, gen, outcome, permErr))
		})
	}()
}

// dropWall 把一张从列表里去掉（不重新扫描，其余缩略图不变）。
func (a *app) dropWall(wall string) {
	w := &a.walls
	w.all = slices.DeleteFunc(w.all, func(p string) bool { return p == wall })
	w.invalidateRev()
	delete(w.thumbs, wall)
	delete(w.browse, wall)
	if wall == w.slidePath {
		w.slide, w.slidePath = nil, "" // 轮播显示的是这张：退回 hero，下一轮接着往后换
	}
	if wall == w.heroPath {
		// 横幅图被移出 / 删掉了：横幅不能继续显示这张已经不在文件夹里的图。
		// 先清掉，再在后台挑一张够宽的重新当横幅（只解这一张，不整库重扫）。
		w.hero = nil
		w.heroPath = ""
		a.reloadHero()
	}
	if a.preview {
		// 停在原位置，看到的就是下一张
		if len(w.all) == 0 {
			a.preview = false
		} else {
			a.previewIdx = min(a.previewIdx, len(w.all)-1)
		}
	}
}
