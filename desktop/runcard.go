package main

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

// ── 运行结果摘要与运行中卡片 ──────────────────────────────────────────────

// resultBrief 是上次结果里最值得看的两项，放在摘要条里。
func (a *app) resultBrief() string {
	s := a.last.sum
	var parts []string
	if s.Copy.PrevSelected > 0 {
		parts = append(parts, "重合 "+overlapPercent(s.Copy))
	}
	if len(a.cfg.FilterAndSampleDirs) > 0 {
		if s.Sort.Simulated {
			parts = append(parts, fmt.Sprintf("%d 张不合格", s.Sort.Rejected))
		} else {
			parts = append(parts, fmt.Sprintf("删 %d 张", s.Sort.Deleted))
		}
	}
	if s.Copy.LeafFolders > 0 && a.cfg.BalanceFirst && len(parts) < 2 {
		parts = append(parts, fmt.Sprintf("覆盖 %d/%d", s.Copy.CoveredFolders, s.Copy.LeafFolders))
	}
	if len(parts) == 0 {
		return a.last.at.Format("15:04") + " 完成"
	}
	return strings.Join(parts, " · ")
}

// resultDetail 是完整的结果说明，鼠标停在「上次运行」上时显示。
func (a *app) resultDetail() string {
	s := a.last.sum
	var parts []string
	if c := s.Copy; c.PrevSelected > 0 {
		parts = append(parts, fmt.Sprintf("和上一轮相比：新更换 %d 张，重复 %d 张（重合率 %s）",
			c.Selected-c.Repeated, c.Repeated, overlapPercent(c)))
		if c.PrevByName {
			parts = append(parts, "（没有上一轮的记录，按壁纸文件夹里原有的文件名比较，结果是近似的）")
		}
	}
	if len(a.cfg.FilterAndSampleDirs) > 0 {
		if s.Sort.Simulated {
			parts = append(parts, fmt.Sprintf("模拟筛选：%d 张不合格（未删除）", s.Sort.Rejected))
		} else {
			parts = append(parts, fmt.Sprintf("筛选删除 %d 张", s.Sort.Deleted))
		}
		if s.Sort.Skipped > 0 {
			parts = append(parts, fmt.Sprintf("跳过 %d 个没变化的文件夹", s.Sort.Skipped))
		}
	}
	if s.Copy.LeafFolders > 0 && a.cfg.BalanceFirst {
		parts = append(parts, fmt.Sprintf("覆盖 %d / %d 个文件夹", s.Copy.CoveredFolders, s.Copy.LeafFolders))
	}
	if a.cfg.ArchiveEnabled {
		parts = append(parts, fmt.Sprintf("归档 %d 张", s.Copy.Archived))
	}
	parts = append(parts, fmt.Sprintf("%s 完成，用时 %.0f 秒", a.last.at.Format("1月2日 15:04"), s.Elapsed.Seconds()))
	return strings.Join(parts, "\n")
}

// overlapPercent 是这一轮选中的图片里上一轮也选中过的比例；有重复但不到 1% 时不显示成 0%。
func overlapPercent(c core.CopyResult) string {
	if c.Selected == 0 {
		return "0%"
	}
	p := float64(c.Repeated) / float64(c.Selected) * 100
	if c.Repeated > 0 && p < 1 {
		return "<1%"
	}
	return fmt.Sprintf("%.0f%%", p)
}

type step struct {
	stage core.Stage
	label string
}

func (a *app) progressLabel() string {
	switch p := a.prog; p.stage {
	case core.StageFilter:
		if p.total > 0 {
			return fmt.Sprintf("筛选 %d / %d 个文件夹", p.done, p.total)
		}
		if p.done > 0 {
			return fmt.Sprintf("正在读取图库目录… 已找到 %d 个文件夹", p.done)
		}
		return "正在读取图库目录…"
	case core.StageScan:
		if p.done > 0 {
			return fmt.Sprintf("正在扫描图库… 已读 %d 个文件夹", p.done)
		}
		return "正在扫描图库、挑选图片…"
	case core.StageCopy:
		if eta := a.copyETA(time.Now()); eta != "" {
			return fmt.Sprintf("复制 %d / %d 张 · %s", p.done, p.total, eta)
		}
		return fmt.Sprintf("复制 %d / %d 张", p.done, p.total)
	default:
		return "正在刷新系统壁纸…"
	}
}

func (a *app) runningCard(c *ui.Context) {
	t := c.Theme()
	var steps []step
	if len(a.cfg.FilterAndSampleDirs) > 0 {
		steps = append(steps, step{core.StageFilter, "筛选"})
	}
	steps = append(steps, step{core.StageScan, "采样"}, step{core.StageCopy, "复制"}, step{core.StageRefresh, "刷新"})

	panel(c).Gap(16).Padding(18, 20).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(10).Children(func() {
			for i, s := range steps {
				if i > 0 {
					line := hairline(t)
					if s.stage <= a.prog.stage {
						line = t.Accent
					}
					ui.Box(c).Height(2).Grow(1).Radius(1).Background(line)
				}
				done, active := s.stage < a.prog.stage, s.stage == a.prog.stage
				ui.Row(c).Gap(7).AlignItems(ui.Center).Children(func() {
					dot := ui.Box(c).Size(22, 22).Radius(11).Center()
					switch {
					case done:
						dot.Background(t.Accent).Children(func() {
							ui.Icon(c, iconCheckSmall).FontSize(13).TextColor(t.AccentText)
						})
					case active:
						dot.Background(t.Accent).Shadow(0, 0, 0, 4, t.Accent.Alpha(0.2)).Children(func() {
							ui.Text(c, fmt.Sprint(i+1)).FontSize(11).Bold().TextColor(t.AccentText)
						})
					default:
						dot.Border(1.5, hairline(t).Alpha(0.2)).Children(func() {
							ui.Text(c, fmt.Sprint(i+1)).FontSize(11).TextColor(t.TextMuted)
						})
					}
					l := ui.Text(c, s.label).FontSize(13)
					if active {
						l.Bold()
					} else if !done {
						l.TextColor(t.TextMuted)
					}
					if n, color := a.runDeleteCount(t); s.stage == core.StageFilter && n > 0 {
						pill(c, fmt.Sprint(n), color).Tooltip(a.deleteHeadline())
					}
				})
			}
		})

		value := -1.0
		if p := a.prog; p.total > 0 && (p.stage == core.StageFilter || p.stage == core.StageCopy) {
			value = float64(p.done) / float64(p.total)
		}
		label := a.progressLabel()
		stopping := a.stopReq.Load()
		ui.Column(c).Gap(8).Children(func() {
			ui.Row(c).AlignItems(ui.Center).Gap(12).Children(func() {
				ui.Text(c, label).FontSize(13).Bold().Grow(1)
				if value >= 0 {
					ui.Text(c, fmt.Sprintf("%.0f%%", value*100)).FontSize(12).TextColor(t.TextMuted)
				}
				if stopping {
					ui.Button(c, "正在停止…").Disabled(true).
						Tooltip("正在复制的几张会先复制完；筛选会在当前文件夹检查完后停下")
				} else {
					iconButton(c, iconStop, "停止", false).Tooltip(withKey("停止这次运行", a.keyLabel("stop"))).OnClick(a.stopRun)
				}
			})
			ui.Progress(c, value).Label(label)
			ui.Text(c, stripEmoji(cleanLogLine(a.lastLogLine()))).FontSize(12).TextColor(t.TextMuted).SingleLine()
		})
		if len(a.cfg.FilterAndSampleDirs) > 0 {
			a.deleteStrip(c)
		}
	})
}

// runDeleteCount 是运行中要突出的删除数：真删时是已删除的张数（红色），模拟运行时是不合格的张数（警告色）。
func (a *app) runDeleteCount(t *ui.Theme) (int, ui.Color) {
	if a.runDelete {
		return a.runDeleted, t.Danger
	}
	return a.runRejected, t.Warning
}

func (a *app) deleteHeadline() string {
	if a.runDelete {
		return fmt.Sprintf("已删除 %d 张不合格原图", a.runDeleted)
	}
	return fmt.Sprintf("发现 %d 张不合格（模拟运行，没有删除）", a.runRejected)
}

// deleteStrip 是运行卡片底部的删除情况：删了几张、最近删的是哪张。筛选时删的是 NAS 上的原图，
// 只在日志里滚过去不够显眼。
func (a *app) deleteStrip(c *ui.Context) {
	t := c.Theme()
	n, color := a.runDeleteCount(t)
	filtering := a.prog.stage == core.StageFilter
	var title, sub string
	switch {
	case n == 0 && a.runDelFailed == 0:
		color = t.TextMuted
		title = "尚未发现不合格的图片"
		if !filtering {
			title = "筛选没有发现不合格的图片"
		}
		if !a.runDelete {
			sub = "模拟运行，不会删除原图"
		} else {
			sub = fmt.Sprintf("低于 %d×%d 或竖屏的原图会被删除", int(a.minW), int(a.minH))
		}
	default:
		title = a.deleteHeadline()
		if !a.runDelete {
			title = fmt.Sprintf("发现 %d 张不合格", n)
			sub = "模拟运行，没有删除"
		}
	}
	ui.Row(c).Gap(12).AlignItems(ui.Center).Padding(10, 12).Radius(10).Background(color.Alpha(0.08)).Children(func() {
		ui.Box(c).Size(30, 30).Radius(15).Center().Shrink(0).Background(color.Alpha(0.16)).Children(func() {
			ui.Icon(c, iconTrash).FontSize(14).TextColor(color)
		})
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
			ui.Row(c).Gap(8).AlignItems(ui.Baseline).Children(func() {
				ui.Text(c, title).FontSize(13).Bold().TextColor(color).SingleLine()
				if a.runDelFailed > 0 {
					pill(c, fmt.Sprintf("%d 张删除失败", a.runDelFailed), t.Danger)
				}
				if sub != "" {
					ui.Text(c, sub).FontSize(12).TextColor(t.TextMuted).SingleLine()
				}
			})
			if e := a.lastDel; e.text != "" {
				ui.Row(c).Gap(6).AlignItems(ui.Baseline).MinWidth(0).Children(func() {
					ui.Text(c, "最近").FontSize(11.5).TextColor(t.TextMuted).Shrink(0)
					ui.Text(c, e.text).Font("Menlo").FontSize(11.5).TextColor(t.Text.Alpha(0.86)).SingleLine().Shrink(1)
					if e.reason != "" {
						ui.Text(c, e.reason).FontSize(11.5).TextColor(color.Alpha(0.85)).SingleLine().Shrink(1)
					}
					if e.detail != "" {
						ui.Text(c, "在 "+e.detail).FontSize(11.5).TextColor(t.TextMuted).SingleLine().Shrink(1)
					}
				})
			}
		})
	})
}

// errorCard 是失败或被停止时的提示条：说明原因和壁纸文件夹的状态，并可以直接展开日志。
func (a *app) errorCard(c *ui.Context) {
	t := c.Theme()
	r := a.last
	tint, icon, title := t.Danger, iconAlert, "本次未完成更换"
	var msg string
	switch {
	case errors.Is(r.err, core.ErrCanceled):
		tint, icon, title = t.TextMuted, iconCircleStop, "已停止"
		msg = "壁纸文件夹没有改动。"
		if n := r.sum.Copy.Copied; n > 0 {
			msg = fmt.Sprintf("壁纸文件夹里是已经复制好的 %d 张，可以直接使用，或者再换一批。", n)
		}
	case errors.Is(r.err, core.ErrNoImages):
		msg = r.err.Error()
	default:
		msg = r.err.Error() + "。日志里有详细信息。"
	}
	ui.Row(c).Gap(14).AlignItems(ui.Center).Padding(14, 18).Radius(12).
		Background(tint.Alpha(0.09)).Border(1, tint.Alpha(0.25)).Children(func() {
		ui.Icon(c, icon).FontSize(22).TextColor(tint)
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
			ui.Text(c, title).FontSize(14).Bold()
			muted(c, msg)
		})
		if ui.Button(c, "查看日志").Clicked() {
			a.logShown, a.logReveal = true, true
		}
	})
}
