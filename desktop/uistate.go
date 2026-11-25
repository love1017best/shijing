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
	LastRun *savedRun `json:"last_run,omitempty"`
	// LastSuccess 是最近一次成功运行的结果：上次运行失败或被停止时，图库统计和空间预估仍然有数
	LastSuccess       *core.Summary `json:"last_success,omitempty"`
	SkipDeleteConfirm bool          `json:"skip_delete_confirm,omitempty"`
	SlideIntervalSec  int           `json:"slide_interval_sec,omitempty"`
	SlideShuffle      bool          `json:"slide_shuffle,omitempty"`
	SlideContain      bool          `json:"slide_contain,omitempty"`
	SlideHideInfo     bool          `json:"slide_hide_info,omitempty"`
	SlideNoAwake      bool          `json:"slide_no_awake,omitempty"`
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
	a.lastGood = s.LastSuccess
	if s.SlideIntervalSec > 0 {
		a.slideIntervalSec = s.SlideIntervalSec
	}
	a.slideShuffle = s.SlideShuffle
	a.slideCover = !s.SlideContain
	a.slideShowInfo = !s.SlideHideInfo
	a.slideKeepAwake = !s.SlideNoAwake
	if r := s.LastRun; r != nil {
		a.last = &runResult{sum: r.Summary, err: savedError(r.Error), at: r.At}
		if a.lastGood == nil && r.Error == "" {
			a.lastGood = &r.Summary
		}
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
	s := uiState{
		SkipDeleteConfirm: a.skipConfirm,
		LastSuccess:       a.lastGood,
		SlideIntervalSec:  a.slideIntervalSec,
		SlideShuffle:      a.slideShuffle,
		SlideContain:      !a.slideCover,
		SlideHideInfo:     !a.slideShowInfo,
		SlideNoAwake:      !a.slideKeepAwake,
	}
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
	_ = core.WriteFileAtomic(a.uiStatePath(), data, 0o644)
}
