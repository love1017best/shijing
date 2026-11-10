package core

import (
	"errors"
	"sync"
	"time"
)

// Stage 是流程当前所处的阶段，界面据此显示步骤和进度条。
type Stage int

const (
	StageFilter  Stage = iota // 筛选：删除不合格图片
	StageScan                 // 扫描源目录、采样
	StageCopy                 // 复制/软链接到目标目录（含归档）
	StageRefresh              // 刷新系统壁纸
)

// Reporter 收集流程的日志和进度；两个字段都可以为 nil。
type Reporter struct {
	Log Logf
	// Progress 报告 stage 阶段已完成 done / total 项；total 为 0 表示进度未知。
	Progress func(stage Stage, done, total int)
	// Stop 返回 true 表示用户要求停止。流程只在安全的地方检查它：筛选时在文件夹之间，
	// 清空壁纸目录之前，复制时不再开始新的图片（已经开始的会复制完）。可以为 nil。
	Stop func() bool
}

// ErrCanceled 表示流程被 Reporter.Stop 中途停止。
var ErrCanceled = errors.New("已停止")

func (r Reporter) stopped() bool { return r.Stop != nil && r.Stop() }

func (r Reporter) logf(format string, args ...any) {
	if r.Log != nil {
		r.Log(format, args...)
	}
}

func (r Reporter) progress(s Stage, done, total int) {
	if r.Progress != nil {
		r.Progress(s, done, total)
	}
}

// synced 返回一个可以被多个 goroutine 同时调用的 Reporter：调用方传进来的回调
// （测试里往切片追加、命令行里 Printf）不一定是并发安全的，这里统一加锁串行化。
func (r Reporter) synced() Reporter {
	var mu sync.Mutex
	out := Reporter{Stop: r.Stop} // Stop 只读一个标志，调用方保证并发安全
	if r.Log != nil {
		out.Log = func(format string, args ...any) {
			mu.Lock()
			defer mu.Unlock()
			r.Log(format, args...)
		}
	}
	if r.Progress != nil {
		out.Progress = func(s Stage, done, total int) {
			mu.Lock()
			defer mu.Unlock()
			r.Progress(s, done, total)
		}
	}
	return out
}

// SortResult 是筛选步骤的结果。
type SortResult struct {
	Dirs      int // 实际检查的目录数（增量模式下不含跳过的）
	Skipped   int // 增量模式下没有变化而跳过的目录数
	Images    int // 检查过的图片数
	Rejected  int // 不合格的图片数
	Deleted   int // 实际删除成功的数量（模拟运行时为 0）
	Simulated bool
}

// CopyResult 是采样复制步骤的结果。
type CopyResult struct {
	Candidates     int // 符合条件的候选图片数
	Selected       int // 选中的数量
	Copied         int // 成功复制/链接到目标目录的数量
	Failed         int // 失败的数量
	Archived       int // 成功创建归档链接的数量
	LeafFolders    int
	CoveredFolders int // 平衡采样覆盖到的叶子文件夹数
	// PrevSelected 是上一轮选中的张数，0 表示没有上一轮可比（第一次运行、换了壁纸文件夹）；
	// Repeated 是这一轮里上一轮也选中过的张数。
	PrevSelected int `json:",omitempty"`
	Repeated     int `json:",omitempty"`
	Dest         string
}

// Summary 是一次完整运行的结果。
type Summary struct {
	Sort               SortResult
	Copy               CopyResult
	WallpaperRefreshed bool
	Elapsed            time.Duration
}
