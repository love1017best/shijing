package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"desktop/core"
)

// uiState 是界面自己的状态（不属于 config.json）：上次运行的结果、是否跳过删除确认。
// 放在配置文件旁边的 ui_state.json，重启后「上次运行」和横幅上的换上时间仍然准确
// ——壁纸文件夹里的文件时间靠不住，复制时会保留原图的修改时间。
type uiState struct {
	LastRun           *savedRun `json:"last_run,omitempty"`
	SkipDeleteConfirm bool      `json:"skip_delete_confirm,omitempty"`
}

type savedRun struct {
	At      time.Time    `json:"at"`
	Error   string       `json:"error,omitempty"`
	Summary core.Summary `json:"summary"`
}

func (a *app) uiStatePath() string { return filepath.Join(filepath.Dir(a.cfgPath), "ui_state.json") }

func (a *app) loadUIState() {
	data, err := os.ReadFile(a.uiStatePath())
	if err != nil {
		return
	}
	var s uiState
	if json.Unmarshal(data, &s) != nil {
		return
	}
	a.skipConfirm = s.SkipDeleteConfirm
	if r := s.LastRun; r != nil {
		a.last = &runResult{sum: r.Summary, err: savedError(r.Error), at: r.At}
	}
}

// savedError 把存下来的错误文字还原成 error，已知的几种还原成同一个值，界面可以用 errors.Is 判断。
func savedError(msg string) error {
	switch msg {
	case "":
		return nil
	case core.ErrNoImages.Error():
		return core.ErrNoImages
	case core.ErrCanceled.Error():
		return core.ErrCanceled
	default:
		return errors.New(msg)
	}
}

// saveUIState 只在主线程调用；文件很小，写失败也不影响使用，忽略错误。
func (a *app) saveUIState() {
	s := uiState{SkipDeleteConfirm: a.skipConfirm}
	if r := a.last; r != nil {
		s.LastRun = &savedRun{At: r.at, Summary: r.sum}
		if r.err != nil {
			s.LastRun.Error = r.err.Error()
		}
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(a.uiStatePath()), 0o755)
	_ = os.WriteFile(a.uiStatePath(), data, 0o644)
}
