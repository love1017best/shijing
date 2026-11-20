package main

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"desktop/core"
)

// ── 运行控制 ──────────────────────────────────────────────────────────────

// canRun 是「换一批壁纸」能不能点：没在运行、图库不为空、不是所有目录都没挂载、设了壁纸文件夹。
func (a *app) canRun() bool {
	dirs := a.allDirs()
	return !a.running && len(dirs) > 0 && a.unmountedCount() < len(dirs) && strings.TrimSpace(a.cfg.DestDir) != ""
}

// requestRun 是「换一批壁纸」按钮和 ⌘R：会删除原图时先确认，再开始运行。
func (a *app) requestRun() {
	if !a.canRun() {
		return
	}
	if !a.cfg.DeleteDuringFilter || len(a.cfg.FilterAndSampleDirs) == 0 || a.skipConfirm || a.confirmDelete == nil {
		a.startRun()
		return
	}
	detail := a.deleteNotice()
	go func() {
		ok, dontAsk := a.confirmDelete(detail)
		if !ok {
			return
		}
		a.update(func() {
			if dontAsk {
				a.skipConfirm = true
				a.saveUIState()
			}
			a.startRun()
		})
	}()
}

// willDelete 是这次运行会不会真的删除原图（打开了删除、并且有「筛选 + 采样」目录）。
func (a *app) willDelete() bool {
	return a.cfg.DeleteDuringFilter && len(a.cfg.FilterAndSampleDirs) > 0
}

// deleteNotice 是运行前确认删除原图时的说明（桌面的确认框和手机上的确认都用它）。
func (a *app) deleteNotice() string {
	return fmt.Sprintf("此操作会删除图库中的不合格原图：会检查「筛选 + 采样」中的 %d 个目录，删除竖屏、正方形和低于 %d×%d 的图片，不可撤销。"+
		"删除会记进「删除记录」。", len(a.cfg.FilterAndSampleDirs), int(a.minW), int(a.minH))
}

// stopRun 请求停止：筛选在文件夹之间停，复制时不再开始新的图片。
func (a *app) stopRun() {
	if a.running && !a.stopReq.Load() {
		a.stopReq.Store(true)
		a.appendLog("⏹️ 正在停止…")
	}
}

func (a *app) startRun() { a.startRunWith(runOpts{}) }

// runOpts 是一次运行的来源和限制。
type runOpts struct {
	auto     bool   // 定时自动运行：不删除原图（筛选只模拟），也不弹删除确认
	noDelete bool   // 这次不删除原图，筛选只模拟（手机上选了「只模拟」）
	from     string // 从哪台手机遥控的，空是本机
}

// startRunWith 开始运行（调用方负责删除原图前的确认）。
func (a *app) startRunWith(o runOpts) {
	if !a.canRun() {
		return
	}
	a.autosave()
	cfg := a.buildConfig()
	auto := o.auto
	if auto || o.noDelete {
		cfg.DeleteDuringFilter = false
	}
	a.clearUndo() // 换一批会清空壁纸文件夹，之前的移出没法再放回去
	a.running = true
	a.last = nil
	a.runStats = runStats{runDelete: cfg.DeleteDuringFilter}
	a.stopReq.Store(false)
	a.appendLog(strings.Repeat("─", 50))
	a.appendLog("▶ " + time.Now().Format("2006-01-02 15:04:05") + " 开始运行")
	if auto {
		a.appendLog(fmt.Sprintf("⏰ 定时自动运行（%s），这次不删除原图，只模拟筛选", autoRunLabel(cfg.AutoRunHours)))
	}
	if o.from != "" {
		note := ""
		if o.noDelete && a.willDelete() {
			note = "，这次只模拟筛选、不删除原图"
		}
		a.appendLog(fmt.Sprintf("📱 由「%s」遥控运行%s", o.from, note))
	}
	rep := core.Reporter{Log: a.logf, Progress: a.progressf, OnDelete: a.deletef, Stop: a.stopReq.Load}
	if a.onRunState != nil {
		a.onRunState(true, nil)
	}
	go func() {
		core.ValidateConfig(cfg, a.logf)
		sum, err := a.run(cfg, rep)
		switch {
		case errors.Is(err, core.ErrCanceled):
			a.logf("⏹️ 已停止")
		case err != nil:
			a.logf("❌ %v", err)
		}
		a.update(func() {
			// 在主线程一次性排空全部残留的日志、进度与删除事件，再切为非运行态，
			// 彻底避免与 80ms 定时刷新并发导致末尾计数漏算。
			a.drainPending()
			a.running = false
			a.last = &runResult{sum: sum, err: err, at: time.Now()}
			if err == nil {
				a.lastGood = &sum
			}
			a.invalidateDeleteCache()
			a.saveUIState()
			a.wallsGen++       // 壁纸文件夹换了一批，重新读缩略图
			a.loadWallpapers() // 不等下一帧：桌面窗口关着时 view 不重画（手机靠这次重读拿到新列表）
			switch {
			case err == nil:
				a.toast = fmt.Sprintf("已更换 %d 张壁纸", sum.Copy.Copied)
			case errors.Is(err, core.ErrCanceled):
				a.toast = "已停止"
			}
			if a.onRunState != nil {
				a.onRunState(false, err)
			}
		})
	}()
}

// ── 日志与进度（任意 goroutine 可调用，攒批后每 80ms 刷一次界面）───────────────

func (a *app) logf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	a.pendMu.Lock()
	a.pendLog = append(a.pendLog, line)
	a.scheduleLocked()
	a.pendMu.Unlock()
}

func (a *app) progressf(stage core.Stage, done, total int) {
	a.pendMu.Lock()
	a.pendProg = &progress{stage, done, total}
	a.scheduleLocked()
	a.pendMu.Unlock()
}

func (a *app) deletef(ev core.DeleteEvent) {
	a.pendMu.Lock()
	a.pendDel = append(a.pendDel, ev)
	a.scheduleLocked()
	a.pendMu.Unlock()
}

func (a *app) scheduleLocked() {
	if !a.pendSched {
		a.pendSched = true
		time.AfterFunc(80*time.Millisecond, a.flush)
	}
}

func (a *app) flush() {
	a.pendMu.Lock()
	has := len(a.pendLog) > 0 || a.pendProg != nil || len(a.pendDel) > 0
	if !has {
		a.pendSched = false
		a.pendMu.Unlock()
		return
	}
	a.pendMu.Unlock()
	a.update(func() { a.drainPending() })
}

// drainPending 在主线程排空积攒的日志、进度与删除事件（主线程串行执行，避免与结束回调竞态）。
func (a *app) drainPending() {
	a.pendMu.Lock()
	lines, prog, dels := a.pendLog, a.pendProg, a.pendDel
	a.pendLog, a.pendProg, a.pendDel, a.pendSched = nil, nil, nil, false
	a.pendMu.Unlock()
	if len(lines) > 0 {
		a.appendLog(strings.Join(lines, "\n"))
	}
	if a.running {
		for _, ev := range dels {
			a.applyDeleteEvent(ev)
		}
	}
	if prog != nil {
		if prog.stage == core.StageCopy && a.prog.stage != core.StageCopy {
			a.copyT0 = time.Now()
		}
		a.prog = *prog
	}
}

// applyDeleteEvent 应用单条结构化筛选删除事件，不依赖解析中文日志文本。
func (a *app) applyDeleteEvent(ev core.DeleteEvent) {
	switch ev.Kind {
	case core.DeleteSimulated:
		a.runRejected++
		if !a.runDelete {
			a.lastDel = logEntry{kind: logDelete, indent: 2, label: "待删除", text: ev.Name, detail: ev.Folder, reason: ev.Reason}
		}
	case core.DeleteRemoved:
		a.runDeleted++
		if a.runDelete {
			a.lastDel = logEntry{kind: logDelete, indent: 2, label: "已删除", text: ev.Name, detail: ev.Folder, reason: ev.Reason}
		}
	case core.DeleteFailed:
		a.runDelFailed++
	}
}

// appendLog 只能在主线程调用。
func (a *app) appendLog(text string) {
	lines := strings.Split(text, "\n")
	a.log = append(a.log, lines...)
	if over := len(a.log) - maxLogLines; over > 0 {
		a.log = slices.Delete(a.log, 0, over)
	}
	a.logSeq++
}

// lastLogLine 是运行中显示在进度条下的那一行。
func (a *app) lastLogLine() string {
	for i := len(a.log) - 1; i >= 0; i-- {
		if s := strings.TrimSpace(a.log[i]); s != "" && !strings.HasPrefix(s, "===") {
			return s
		}
	}
	return ""
}
