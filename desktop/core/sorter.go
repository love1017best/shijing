package core

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// 计算目录 mtime 时忽略的元数据/缓存条目（CLAUDE.md 坑 7）：AppleDouble 影子文件
// 和 NAS 索引缓存目录的增删会推高目录自身的 mtime，但图片内容并没有变化。
var ignoredNames = map[string]bool{
	".DS_Store": true, "Thumbs.db": true, "desktop.ini": true,
	"@eaDir": true, "#recycle": true, "@Recycle": true, ".@__thumb": true,
	".SynologyWorkingDirectory": true,
}

func isIgnoredEntry(name string) bool {
	return strings.HasPrefix(name, "._") || ignoredNames[name]
}

// dirMtime 返回目录里"有意义的文件"的最新 mtime（秒，浮点），递归子目录，
// 跳过已知噪声条目。不用目录自身的 mtime。
func dirMtime(dir string) float64 {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	var max float64
	for _, e := range entries {
		if isIgnoredEntry(e.Name()) {
			continue
		}
		if e.IsDir() { // DirEntry 来自 lstat，软链接不算目录，与 is_dir(follow_symlinks=False) 一致
			if m := dirMtime(filepath.Join(dir, e.Name())); m > max {
				max = m
			}
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if m := float64(info.ModTime().UnixNano()) / 1e9; m > max {
			max = m
		}
	}
	return max
}

type thresholds struct {
	MinWidth  int `json:"min_width"`
	MinHeight int `json:"min_height"`
}

type sorterState struct {
	Thresholds *thresholds        `json:"thresholds,omitempty"`
	Dirs       map[string]float64 `json:"dirs,omitempty"`
}

func loadState(path string) sorterState {
	var s sorterState
	if data, err := os.ReadFile(path); err == nil {
		if json.Unmarshal(data, &s) != nil {
			s = sorterState{}
		}
	}
	return s
}

func saveState(path string, s sorterState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// SortOptions 对应 image_sorter.scan_and_process_directories 的参数。
type SortOptions struct {
	Sources     []string
	MinWidth    int
	MinHeight   int
	Delete      bool
	Incremental bool
	StateFile   string // 增量状态文件
	DeleteLog   string // 实际删除的文件追加记录到这里；为空则不记录
}

func logDeletion(logPath, file string, minW, minH int) {
	if logPath == "" {
		return
	}
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s\t(阈值 %dx%d)\t%s\n", time.Now().Format("2006-01-02 15:04:05"), minW, minH, file)
}

func relPath(root, source string) string {
	if rel, err := filepath.Rel(source, root); err == nil {
		return rel
	}
	return filepath.Base(root)
}

type dirImages struct {
	root   string
	images []string
}

// SortImages 删除（或模拟删除）竖屏/正方形/分辨率不足的图片。
func SortImages(o SortOptions, rep Reporter) SortResult {
	logf := rep.logf
	res := SortResult{Simulated: !o.Delete}
	var state sorterState
	if o.Incremental {
		state = loadState(o.StateFile)
	}
	// 阈值变了就让旧缓存整体失效（CLAUDE.md 坑 10），否则调严分辨率后没变化的目录会被一直跳过
	th := thresholds{o.MinWidth, o.MinHeight}
	if o.Incremental && (state.Thresholds == nil || *state.Thresholds != th) {
		if len(state.Dirs) > 0 {
			logf("🔄 筛选阈值与上次不同，增量缓存已失效，本次将全量重新检查")
		}
		state = sorterState{}
	}
	state.Thresholds = &th

	start := time.Now()
	totalImages, deleteCount, deleted, processedDirs := 0, 0, 0, 0
	dirMtimes := map[string]float64{} // 已检查完的目录的 mtime，保存状态时复用

	// 先遍历出所有含图片的目录（边遍历边上报找到了几个文件夹），再按遍历顺序逐个处理：
	// 增量模式下各目录的 mtime 在后台并发计算（dirMtime 要 lstat 目录下每个文件，
	// SMB 冷缓存时约 1ms/文件，见 CLAUDE.md 坑 12），算好一个就判断一个，
	// 没变化的直接跳过，有变化的立刻检查——进度和日志随之一个个往前走，而不是等全部算完。
	type found struct {
		source string
		dirImages
	}
	var dirs []found
	seen := 0
	for _, source := range o.Sources {
		if !exists(source) {
			continue
		}
		walk(source, func(root string, _ []string, files []string) {
			seen++
			rep.progress(StageFilter, seen, 0)
			var images []string
			for _, f := range files {
				if IsValidImage(f) {
					images = append(images, filepath.Join(root, f))
				}
			}
			if len(images) > 0 {
				dirs = append(dirs, found{source, dirImages{root, images}})
			}
		})
	}
	if rep.stopped() {
		logf("\n⏹️ 已停止筛选")
		return res
	}
	logf("🔎 找到 %d 个含图片的文件夹（共遍历 %d 个）", len(dirs), seen)

	mtimes := make([]float64, len(dirs))
	ready := make([]chan struct{}, len(dirs))
	for i := range ready {
		ready[i] = make(chan struct{})
	}
	var abandon atomic.Bool // 停止后后台不再计算剩下的 mtime
	var bg sync.WaitGroup
	if o.Incremental {
		bg.Add(1)
		go func() {
			defer bg.Done()
			parallelFor(len(dirs), metaWorkers, func(i int) {
				if !abandon.Load() {
					mtimes[i] = dirMtime(dirs[i].root)
				}
				close(ready[i])
			})
		}()
	}
	defer func() {
		abandon.Store(true)
		bg.Wait()
	}()

	rep.progress(StageFilter, 0, len(dirs))
	lastSource := ""
	for i, d := range dirs {
		if rep.stopped() {
			logf("\n⏹️ 已停止筛选，剩下的文件夹下次再检查")
			break
		}
		if d.source != lastSource {
			logf("\n📁 %s", d.source)
			lastSource = d.source
		}
		rel := relPath(d.root, d.source)
		if o.Incremental {
			<-ready[i]
			if mtimes[i] <= state.Dirs[d.root] {
				res.Skipped++
				logf("  ├─ %s: ⏭️ 已跳过（无变化）", rel)
				rep.progress(StageFilter, i+1, len(dirs))
				continue
			}
		}
		processedDirs++
		logf("\n📂 处理文件夹: %s", rel)
		dirDelete := 0
		ok := checkResolutions(d.images, o.MinWidth, o.MinHeight) // 并发读文件头，删除和日志仍按顺序串行
		for k, file := range d.images {
			totalImages++
			name := filepath.Base(file)
			if ok[k] {
				continue
			}
			logf("    [%s] 🗑️ 待删除: %s", rel, name)
			dirDelete++
			deleteCount++
			if o.Delete {
				if err := os.Remove(file); err != nil {
					logf("    [%s] ❌ 删除失败: %s - %v", rel, name, err)
					continue
				}
				deleted++
				logDeletion(o.DeleteLog, file, o.MinWidth, o.MinHeight)
				logf("    [%s] 🔥 已删除: %s", rel, name)
			}
		}
		logf("  └─ %s: 处理 %d 张，删除 %d 张", rel, len(d.images), dirDelete)
		if o.Incremental {
			dirMtimes[d.root] = mtimes[i]
		}
		rep.progress(StageFilter, i+1, len(dirs))
	}
	res.Dirs, res.Images, res.Rejected, res.Deleted = processedDirs, totalImages, deleteCount, deleted

	if o.Incremental && len(dirMtimes) > 0 {
		if state.Dirs == nil {
			state.Dirs = map[string]float64{}
		}
		for k, v := range dirMtimes {
			state.Dirs[k] = v
		}
		if err := saveState(o.StateFile, state); err != nil {
			logf("⚠️ 保存增量状态失败: %v", err)
		}
	}

	sep := strings.Repeat("=", 50)
	logf("\n%s", sep)
	logf("✅ 扫描完成! 用时: %.1f秒", time.Since(start).Seconds())
	logf("📁 已处理目录: %d 个", processedDirs)
	logf("🖼️ 总图片数: %d", totalImages)
	logf("🗑️ 待删除图片: %d", deleteCount)
	if o.Delete {
		logf("🔥 实际已删除: %d 张", deleted)
	} else {
		logf("⚠️ 提示: 此为模拟运行，未实际删除文件")
	}
	if o.Incremental {
		logf("💾 状态已保存到: %s", o.StateFile)
	}
	logf("%s", sep)
	return res
}
