package main

import (
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

// deleteCache 缓存读出来的删除日志，文件没变（大小和修改时间）就不重读。
type deleteCache struct {
	size  int64
	mod   time.Time
	recs  []core.DeleteRecord
	byDir map[string]int // 图库目录 → 累计删除张数
	dirs  string         // byDir 是按哪组目录算的
}

func (a *app) deleteRecords() []core.DeleteRecord {
	st, err := os.Stat(a.paths.DeleteLog)
	if err != nil {
		a.delCache = deleteCache{}
		return nil
	}
	if st.Size() != a.delCache.size || !st.ModTime().Equal(a.delCache.mod) {
		a.delCache = deleteCache{size: st.Size(), mod: st.ModTime(), recs: core.ReadDeleteLog(a.paths.DeleteLog)}
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
				if strings.HasPrefix(r.Path, filepath.Clean(d)+string(filepath.Separator)) {
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

// wallSource 是壁纸文件夹里这张图对应的原图；没有记录（旧版本换上的）时返回 ""。
func (a *app) wallSource(wall string) string {
	return a.walls.sources[filepath.Base(wall)]
}

// removeWallpaper 从壁纸文件夹里移除一张（不动原图），exclude 时还把原图加进排除名单。
func (a *app) removeWallpaper(wall string, exclude bool) {
	r := removedWall{wall: wall, idx: slices.Index(a.walls.all, wall), thumb: a.walls.thumbs[wall]}
	stash, err := a.stashWall(wall)
	if os.IsNotExist(err) {
		stash = "" // 文件已经不在了：照样从列表里去掉，只是没法撤销
	} else if err != nil {
		a.showErr("移除失败", err.Error())
		return
	}
	if exclude {
		if src := a.wallSource(wall); src != "" && !slices.Contains(a.cfg.Excluded, src) {
			a.cfg.Excluded = append(a.cfg.Excluded, src)
			r.excluded = src
		}
	}
	a.dropWall(wall)
	if exclude {
		a.toast = "已移出壁纸文件夹，原图还在图库里；以后采样会跳过它（⌘Z 撤销）"
	} else {
		a.toast = "已移出壁纸文件夹，原图还在图库里（⌘Z 撤销）"
	}
	if stash != "" {
		r.stash = stash
		a.pushUndo(r)
	}
}

// deleteOriginal 删除原图（记进删除日志）并从壁纸文件夹移除。调用前已经确认过。
func (a *app) deleteOriginal(wall string) {
	src := a.wallSource(wall)
	if src == "" {
		return
	}
	if err := os.Remove(src); err != nil && !os.IsNotExist(err) {
		a.showErr("删除原图失败", err.Error())
		return
	}
	core.LogDeletion(a.paths.DeleteLog, src, int(a.minW), int(a.minH), "手动删除")
	a.appendLog(fmt.Sprintf("🔥 手动删除原图: %s", src))
	_ = os.Remove(wall)
	a.dropWall(wall)
	a.toast = "已删除图库里的原图，记进了删除记录"
}

// dropWall 把一张从列表里去掉（不重新扫描，其余缩略图不变）。
func (a *app) dropWall(wall string) {
	w := &a.walls
	w.all = slices.DeleteFunc(w.all, func(p string) bool { return p == wall })
	delete(w.thumbs, wall)
	if a.preview {
		// 停在原位置，看到的就是下一张
		if len(w.all) == 0 {
			a.preview = false
		} else {
			a.previewIdx = min(a.previewIdx, len(w.all)-1)
		}
	}
}
