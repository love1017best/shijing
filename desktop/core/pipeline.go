package core

import (
	"fmt"
	"math/rand/v2"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Paths 指定状态与缓存文件的位置。
type Paths struct {
	StateFile string // 增量筛选状态
	DeleteLog string // 删除留痕
	Selection string // 上一轮选中了哪些原图，用来算两轮之间的重合
	History   string // 这一轮轮换里换上过哪些原图（PreferUnseen）
	Pending   string // 图库没连上时排队的「删除原图」（pending.go）
	// Lock 是运行锁：桌面和命令行共用数据目录，同时跑会一起写增量状态、轮换历史和壁纸文件夹。
	// 为空时不加锁。
	Lock string
}

// PathsIn 返回数据目录下的默认文件路径。
func PathsIn(dataDir string) Paths {
	return Paths{
		StateFile: filepath.Join(dataDir, "image_sorter_state.json"),
		DeleteLog: filepath.Join(dataDir, "image_sorter_deleted.log"),
		Selection: filepath.Join(dataDir, "last_selection.json"),
		History:   filepath.Join(dataDir, "selection_history.json"),
		Pending:   filepath.Join(dataDir, "pending_deletes.json"),
		Lock:      filepath.Join(dataDir, "run.lock"),
	}
}

// RefreshWallpaper 让 macOS 重新读取壁纸文件夹。
//
// 系统设置里「文件夹 + 随机切换」的壁纸由 WallpaperImageExtension 负责，它只在启动时读一次
// 文件夹里有哪些图，之后一直在旧列表里轮换；文件夹被换成新的一批后，它会停在已经被删掉的旧图上，
// 很久才更新。com.apple.wallpaper.agent 容器里的缓存目录受系统保护，删不掉也不会让它重新读文件夹。
// 结束 WallpaperAgent 后 launchd 会立刻把它和各个壁纸扩展重新拉起来，设置不受影响。
// 是变量，测试里替换掉，免得真的重启系统的壁纸服务。
var RefreshWallpaper = func() error {
	out, err := exec.Command("/usr/bin/killall", "WallpaperAgent").CombinedOutput()
	if err != nil && len(out) > 0 {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return err
}

// ValidateConfig 检查源目录是否存在；不存在只警告（可能卷未挂载）。
func ValidateConfig(cfg Config, logf Logf) {
	cfg = cfg.expanded()
	for _, d := range append(append([]string{}, cfg.FilterAndSampleDirs...), cfg.SampleOnlyDirs...) {
		if !exists(d) {
			logf("⚠️  目录不存在（可能卷未挂载）: %s", d)
		}
	}
}

// TryLockRun 对运行锁文件加非阻塞排他锁；lockPath 为空时直接返回空操作解锁函数。
// 另一个拾景进程（桌面版或命令行）持有锁时返回 ErrBusy。
func TryLockRun(lockPath string) (func(), error) {
	if lockPath == "" {
		return func() {}, nil
	}
	return lockRun(lockPath)
}

// RunPipeline 对应 run.run_pipeline：筛选 → 采样复制 → 刷新系统壁纸。
// r 为 nil 时使用随机种子；测试可以传入固定种子。出错时返回已完成部分的结果。
func RunPipeline(cfg Config, paths Paths, rep Reporter, r *rand.Rand) (Summary, error) {
	start := time.Now()
	logf := rep.logf
	var sum Summary

	unlock, err := TryLockRun(paths.Lock)
	if err != nil {
		return sum, err
	}
	defer unlock()

	cfg = cfg.expanded()
	filterDirs := cfg.FilterAndSampleDirs
	sampleOnly := cfg.SampleOnlyDirs
	all := append(append([]string{}, filterDirs...), sampleOnly...)

	if len(filterDirs) > 0 {
		logf("🗑️  开始筛选目录：%d 个", len(filterDirs))
		sum.Sort = SortImages(SortOptions{
			Sources:     filterDirs,
			MinWidth:    cfg.MinWidth,
			MinHeight:   cfg.MinHeight,
			Delete:      cfg.DeleteDuringFilter,
			Incremental: cfg.Incremental,
			StateFile:   paths.StateFile,
			DeleteLog:   paths.DeleteLog,
		}, rep)
		if rep.stopped() {
			sum.Elapsed = time.Since(start)
			return sum, ErrCanceled
		}
	}

	logf("📸 开始采样复制：%d 个目录", len(all))
	sum.Copy, err = CopySamples(CopyOptions{
		Sources:            all,
		Dest:               cfg.DestDir,
		Mode:               cfg.Mode,
		Num:                cfg.SampleCount,
		BalanceFirst:       cfg.BalanceFirst,
		FilterSources:      sampleOnly,
		MinWidth:           cfg.MinWidth,
		MinHeight:          cfg.MinHeight,
		ArchiveEnabled:     cfg.ArchiveEnabled,
		ArchiveSubdirName:  cfg.ArchiveSubdirName,
		ArchiveDirOverride: cfg.ArchiveDirOverride,
		ArchiveSMBRoot:     cfg.ArchiveSMBRoot,
		ArchiveNFSRoot:     cfg.ArchiveNFSRoot,
		SelectionFile:      paths.Selection,
		HistoryFile:        paths.History,
		StateFile:          paths.StateFile,
		Incremental:        cfg.Incremental,
		PreferUnseen:       cfg.PreferUnseen,
		Excluded:           cfg.Excluded,
		Rejected:           sum.Sort.Remaining,
	}, rep, r)
	if err != nil {
		sum.Elapsed = time.Since(start)
		return sum, err
	}

	rep.progress(StageRefresh, 0, 0)
	switch {
	case !cfg.RefreshWallpaper:
		logf("🔄 已跳过刷新系统壁纸（未启用）")
	default:
		if err := RefreshWallpaper(); err != nil {
			logf("⚠️ 刷新系统壁纸失败: %v（新图片要等系统自己重新读文件夹才会出现）", err)
		} else {
			sum.WallpaperRefreshed = true
			logf("🔄 已刷新系统壁纸")
		}
	}

	logf("✅ 所有操作完成 - 壁纸已更新")
	sum.Elapsed = time.Since(start)
	return sum, nil
}
