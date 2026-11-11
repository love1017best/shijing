package main

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

// ── 概览 ──────────────────────────────────────────────────────────────────

func (a *app) modeLabel() string {
	if a.modeIdx == 1 {
		return "软链接"
	}
	return "复制"
}

func (a *app) overviewPage(c *ui.Context) {
	pageHeader(c, "概览", "", nil)
	a.hero(c)

	switch {
	case a.running:
		a.runningCard(c)
	case a.last != nil && a.last.err != nil:
		a.errorCard(c)
	}
	a.thumbStrip(c)
	a.statStrip(c)
	a.logPanel(c)
	a.previewModal(c)
}

// hero 是概览顶部的大横幅：背景是当前壁纸里的一张图，没有壁纸时画一幅暮色山景。
func (a *app) hero(c *ui.Context) {
	t := c.Theme()
	dirs := a.allDirs()
	white := ui.RGB(255, 255, 255)

	box := ui.Box(c).Height(236).Radius(16).Clip().Background(duskTop)
	if a.walls.hero != nil && a.walls.heroPath != "" && !a.running {
		// 横幅图也是壁纸文件夹里的一张：点空白处打开它的大图（按钮各管各的）
		box.Label("横幅壁纸").Cursor(ui.CursorPointer).Tooltip(filepath.Base(a.walls.heroPath) + "（点击查看大图，右键更多操作）").
			ContextMenu(func(m *ui.Menu) { a.wallMenu(m, a.walls.heroPath) })
		if box.Clicked() {
			a.openPreviewOf(a.walls.heroPath)
		}
	}
	box.Children(func() {
		if a.walls.hero != nil {
			ui.Image(c, a.walls.hero).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(ui.Cover)
		} else {
			sceneArt(c)
		}
		// 底部压暗，保证文字在任何图片上都看得清；运行中整体再暗一些
		top := ui.RGBA(0, 0, 0, 0.05)
		if a.running {
			top = ui.RGBA(0, 0, 0, 0.35)
		}
		ui.Box(c).Absolute().Top(0).Left(0).Right(0).Bottom(0).LinearGradient(ui.LinearGradient{
			Angle: 180, Stops: []ui.GradientStop{
				{Color: top, At: 0}, {Color: ui.RGBA(0, 0, 0, 0.12), At: 0.4}, {Color: ui.RGBA(0, 0, 0, 0.68), At: 1},
			}})

		ui.Row(c).Absolute().Left(24).Right(22).Bottom(20).Gap(16).AlignItems(ui.End).Children(func() {
			ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(4).Children(func() {
				ui.Text(c, a.heroEyebrow()).FontSize(12).TextColor(white.Alpha(0.78)).SingleLine()
				ui.Text(c, a.heroTitle()).FontSize(24).Bold().TextColor(white).SingleLine()
				// 张数、画质在下面的摘要条里；这里只放去向，或者需要处理的问题
				warn := ""
				switch n := a.unmountedCount(); {
				case a.running:
				case strings.TrimSpace(a.cfg.DestDir) == "":
					warn = "还没有设置壁纸文件夹，先到「设置」里选一个"
				case n > 0 && n == len(dirs):
					warn = "图库目录都没挂载，连上 NAS 后到「图库」里重新检查"
				case n > 0:
					warn = fmt.Sprintf("%d 个目录未挂载，这次会跳过它们", n)
				}
				if warn != "" {
					ui.Row(c).Gap(5).AlignItems(ui.Center).Children(func() {
						amber := ui.Hex("#FFD27A")
						ui.Icon(c, iconAlert).FontSize(12).TextColor(amber)
						ui.Text(c, warn).FontSize(12.5).TextColor(amber).SingleLine()
					})
				} else {
					ui.Row(c).Gap(6).AlignItems(ui.Center).MinWidth(0).Children(func() {
						ui.Text(c, a.modeLabel()+"到 "+a.cfg.DestDir).
							FontSize(12.5).TextColor(white.Alpha(0.82)).SingleLine().Shrink(1)
						// 会删原图时在这里说一句（点「换一批」时还会再确认一次）
						if a.willDelete() {
							amber := ui.Hex("#FFD27A")
							ui.Row(c).Shrink(0).Gap(4).AlignItems(ui.Center).Tooltip(a.deleteNotice()).Children(func() {
								ui.Icon(c, iconAlert).FontSize(11.5).TextColor(amber)
								ui.Text(c, "会先删除不合格原图").FontSize(12.5).TextColor(amber).SingleLine()
							})
						}
					})
				}
			})
			ui.Row(c).Shrink(0).Gap(10).AlignItems(ui.Center).Children(func() {
				if len(a.walls.all) > 0 || (a.last != nil && a.last.err == nil) {
					open := ui.ButtonBase(c).Label("打开壁纸文件夹").Tooltip("在 Finder 中打开壁纸文件夹").
						Height(40).Padding(0, 14).Radius(10).Center().Gap(6).
						Background(white.Alpha(0.18)).Border(1, white.Alpha(0.25)).TextColor(white)
					if open.Hovered() {
						open.Background(white.Alpha(0.28))
					}
					open.Children(func() {
						ui.Icon(c, iconFolderOpen).FontSize(15)
						ui.Text(c, "打开").FontSize(13).SingleLine()
					})
					if open.Clicked() {
						a.openWallpapers()
					}
				}
				iconButton(c, iconShuffle, "换一批壁纸", true).Height(40).Padding(0, 18).Radius(10).
					Shadow(0, 4, 14, 0, t.Accent.Alpha(0.45)).
					Disabled(!a.canRun()).OnClick(a.requestRun)
			})
		})
	})
}

// twoCol 表示设置类页面这一帧是否用左右两栏（按上一帧量到的内容区宽度判断）。
func (a *app) twoCol() bool {
	return a.viewW-72 >= twoColMin
}

// columns 在宽窗口里把 left、right 并排成两栏（顶部对齐、等宽），窄窗口里上下排成一栏。
func (a *app) columns(c *ui.Context, gap float32, left, right func()) ui.Element {
	if !a.twoCol() {
		return ui.Column(c).Gap(gap).Children(func() { left(); right() })
	}
	return ui.Row(c).Gap(gap + 4).AlignItems(ui.Start).Children(func() {
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(gap).Children(left)
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(gap).Children(right)
	})
}

func (a *app) openWallpapers() {
	if a.last != nil && a.last.err == nil && a.last.sum.Copy.Dest != "" {
		a.openPath(a.last.sum.Copy.Dest)
		return
	}
	a.openPath(a.cfg.DestDir)
}

func (a *app) heroEyebrow() string {
	switch {
	case a.running:
		return "正在换壁纸"
	case a.last != nil && a.last.err == nil:
		return "当前壁纸 · " + a.last.at.Format("1月2日 15:04") + " 换上"
	case a.stoppedWithCopies():
		return "当前壁纸 · " + a.last.at.Format("1月2日 15:04") + " 换上（中途停止）"
	case len(a.walls.all) > 0:
		return "当前壁纸"
	default:
		return "拾景"
	}
}

func (a *app) heroTitle() string {
	switch {
	case a.running:
		return "正在拾一批新风景…"
	case a.last != nil && a.last.err == nil:
		return fmt.Sprintf("已换上 %d 张新壁纸", a.last.sum.Copy.Copied)
	case a.stoppedWithCopies():
		return fmt.Sprintf("换上了 %d 张新壁纸", a.last.sum.Copy.Copied)
	case len(a.walls.all) > 0:
		return fmt.Sprintf("%d 张壁纸", len(a.walls.all))
	case len(a.allDirs()) == 0:
		return "先在「图库」里添加目录"
	default:
		return "从图库里拾一批风景"
	}
}

// stoppedWithCopies 是上次运行被停止、但壁纸文件夹已经换了一部分。
func (a *app) stoppedWithCopies() bool {
	return a.last != nil && errors.Is(a.last.err, core.ErrCanceled) && a.last.sum.Copy.Copied > 0
}

const (
	stripGap      = 10
	stripAspect   = 16.0 / 10
	stripMinThumb = 132 // 缩略图最窄多宽（DIP），据此决定列数
)

// stripLayout 按上一帧量到的尺寸算缩略图网格的列数和行数：列数让每张不窄于 stripMinThumb，
// 行数尽量填满窗口里剩下的高度（页面其余部分的高度 = 整页高度 - 网格高度，跟行数无关，所以不会来回跳）。
// 第一帧还没量到尺寸时按默认窗口算（6 列 1 行）。
func stripLayout(grid ui.Rect, pageH, viewH float32) (cols, rows int) {
	cols, rows = 6, 1
	if grid.W <= 0 {
		return cols, rows
	}
	cols = max(4, min(12, int((grid.W+stripGap)/(stripMinThumb+stripGap))))
	cellH := (grid.W - stripGap*float32(cols-1)) / float32(cols) / stripAspect
	if grid.H <= 0 || pageH <= 0 || viewH <= 0 {
		return cols, rows
	}
	free := viewH - (pageH - grid.H)
	rows = max(1, min(6, int((free+stripGap)/(cellH+stripGap))))
	return cols, rows
}

// thumbStrip 是当前壁纸的缩略图网格：点一张看大图，最后一格「+N」从没显示的那张开始翻。
// 运行中壁纸文件夹正在被清空重写，缩略图是上一批的，调暗并且不能点。
func (a *app) thumbStrip(c *ui.Context) {
	t := c.Theme()
	w := &a.walls
	if len(w.all) == 0 && !w.loading {
		return
	}
	grid := ui.Grid(c).Gap(stripGap).Disabled(a.running)
	cols, rows := stripLayout(grid.LayoutBounds(), a.pageH, a.viewH)
	if cols != a.stripCols || rows != a.stripRows {
		// 尺寸是上一帧量的，变了就再排一帧，让网格跟上窗口大小
		a.stripCols, a.stripRows = cols, rows
		c.AnimationFrame()
	}
	cells := cols*rows - 1 // 最后一格是「+N / 打开文件夹」
	paths := w.grid()
	shown := min(cells, len(paths))
	if w.loading && len(paths) == 0 {
		shown = cells // 第一次读取：先用占位格撑住
	}
	a.loadMoreThumbs(cells)
	grid.Columns(cols)
	if a.running {
		grid.Opacity(0.4).Tooltip("正在换壁纸，这是上一批")
	}
	grid.Children(func() {
		for i := range shown {
			cell := ui.Box(c).AspectRatio(stripAspect).Radius(9).Clip().Background(hairline(t)).
				Label(fmt.Sprintf("壁纸 %d", i+1))
			if i >= len(paths) || w.thumbs[paths[i]] == nil {
				continue // 还在解码
			}
			path := paths[i]
			cell.Cursor(ui.CursorPointer).Tooltip(filepath.Base(path) + "（空格预览，右键更多操作）").Children(func() {
				ui.Image(c, w.thumbs[path]).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(ui.Cover)
			})
			if a.running {
				continue
			}
			cell.ContextMenu(func(m *ui.Menu) { a.wallMenu(m, path) })
			if cell.Clicked() || (cell.Hovered() && c.Shortcut(0, ui.KeySpace)) {
				a.openPreviewOf(path)
			}
		}
		rest := len(paths) - shown
		more := ui.ButtonBase(c).AspectRatio(stripAspect).Radius(9).Center().Column().Gap(2).
			Background(panelBg(t)).Border(1, hairline(t))
		if rest > 0 {
			more.Label("查看全部壁纸").Tooltip(fmt.Sprintf("在大图预览里从第 %d 张开始翻（Finder 里打开用横幅上的「打开」）", shown+1))
		} else {
			more.Label("打开壁纸文件夹").Tooltip("在 Finder 中打开壁纸文件夹")
		}
		if more.Hovered() {
			more.Background(t.SurfaceHover)
		}
		more.Children(func() {
			if rest > 0 {
				ui.Text(c, fmt.Sprintf("+%d", rest)).FontSize(17).Bold()
				ui.Text(c, "查看全部").FontSize(11).TextColor(t.TextMuted)
			} else {
				ui.Icon(c, iconFolderOpen).FontSize(18).TextColor(t.TextMuted)
				ui.Text(c, "打开文件夹").FontSize(11).TextColor(t.TextMuted)
			}
		})
		switch {
		case a.running || !more.Clicked():
		case rest > 0:
			a.openPreviewOf(paths[shown])
		default:
			a.openWallpapers()
		}
	})
}

// statStrip 是一条摘要：图库、采样（轮换进度）、自动换（打开了才有）、上次运行。画质这类纯设置不放这里。
func (a *app) statStrip(c *ui.Context) {
	t := c.Theme()
	dirs := a.allDirs()
	panel(c).Row().AlignItems(ui.Stretch).Children(func() {
		cell := func(i int, label, value, sub string, subColor ui.Color, tip string) {
			if i > 0 {
				ui.Box(c).Width(1).Background(hairline(t)).Margin(14, 0)
			}
			e := ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(3).Padding(14, 18)
			if tip != "" {
				e.Tooltip(tip)
			}
			e.Children(func() {
				ui.Text(c, label).FontSize(11.5).TextColor(t.TextMuted).SingleLine()
				ui.Text(c, value).FontSize(18).Bold().SingleLine()
				ui.Text(c, sub).FontSize(11.5).TextColor(subColor).SingleLine()
			})
		}

		mountSub, mountColor := "全部可访问", t.TextMuted
		switch n := a.unmountedCount(); {
		case len(dirs) == 0:
			mountSub = "还没有添加"
		case n > 0:
			mountSub, mountColor = fmt.Sprintf("%d 个未挂载", n), t.Warning
		case a.checkingMounts():
			mountSub = "检查中…"
		}
		cell(0, "图库", fmt.Sprintf("%d 个目录", len(dirs)), mountSub, mountColor, "")
		value, sub, tip := fmt.Sprintf("每次 %d 张", int(a.num)), "完全随机", ""
		switch g := a.lastGood; {
		case a.cfg.PreferUnseen && g != nil && g.Copy.Rotated > 0 && g.Copy.Candidates > 0:
			pct := float64(g.Copy.Rotated) / float64(g.Copy.Candidates) * 100
			value = fmt.Sprintf("已轮换 %.0f%%", pct)
			sub = fmt.Sprintf("%s / %s 张", humanCount(g.Copy.Rotated), humanCount(g.Copy.Candidates))
			tip = fmt.Sprintf("每次 %d 张，优先选没换上过的图：整个图库都换上过一遍后开始新一轮", int(a.num))
		case a.cfg.PreferUnseen:
			sub = "优先选没换上过的"
		case a.cfg.BalanceFirst:
			sub = "平衡采样"
		}
		cell(1, "采样", value, sub, t.TextMuted, tip)
		// 定时自动换（设置里的「自动换壁纸」）没打开时不占一格
		if h := a.buildConfig().AutoRunHours; h > 0 {
			cell(2, "自动换", autoRunLabel(h), "下一次 "+a.nextAutoRun().Format("1月2日 15:04"), t.TextMuted,
				"应用开着时按这个间隔自动换一批（不删原图），在「设置 → 自动换壁纸」里修改或关闭")
		}

		switch r := a.last; {
		case r == nil:
			cell(3, "上次运行", "—", "还没有运行过", t.TextMuted, "")
		case errors.Is(r.err, core.ErrCanceled):
			cell(3, "上次运行", "已停止", r.at.Format("1月2日 15:04"), t.TextMuted, "")
		case r.err != nil:
			cell(3, "上次运行", "失败", r.at.Format("1月2日 15:04"), t.Danger, "")
		default:
			sub, color := a.resultBrief(), t.TextMuted
			if r.sum.Copy.Failed > 0 {
				sub, color = fmt.Sprintf("%d 张复制失败", r.sum.Copy.Failed), t.Warning
			}
			value := fmt.Sprintf("用时 %.0f 秒", r.sum.Elapsed.Seconds())
			if c := r.sum.Copy; c.PrevSelected > 0 {
				value = fmt.Sprintf("新换 %d 张", c.Selected-c.Repeated)
			}
			cell(3, "上次运行", value, sub, color, a.resultDetail())
		}
	})
}

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
		parts = append(parts, fmt.Sprintf("和上一轮相比：新换上 %d 张，重复 %d 张（重合率 %s）",
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

func (a *app) checkingMounts() bool {
	for _, d := range a.allDirs() {
		if a.mounts[d] == mountUnknown {
			return true
		}
	}
	return false
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
		title = "还没有发现不合格的图片"
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
	tint, icon, title := t.Danger, iconAlert, "这次没有换成"
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

// logPanel 是折叠起来的运行日志：工具条（筛选、复制、清空）+ 按类型排版的日志列表。
func (a *app) logPanel(c *ui.Context) {
	t := c.Theme()
	ui.Collapsible(c, fmt.Sprintf("运行日志（%d 行）", len(a.log)), &a.logShown, func() {
		rows := a.logView()
		problems := 0
		for _, e := range a.logParsed {
			if e.isProblem() {
				problems++
			}
		}
		body := ui.Column(c).Gap(10).Padding(10, 0, 0, 0)
		if a.logReveal { // 错误卡片里点了「查看日志」：日志在页面最下面，滚过去
			a.logReveal = false
			body.ScrollIntoView(ui.ScrollIntoViewOptions{Block: ui.ScrollNearest, Animation: &ui.Smooth})
		}
		body.Children(func() {
			panel(c).Height(360).Clip().Children(func() {
				// 工具条
				ui.Row(c).Gap(8).AlignItems(ui.Center).Padding(8, 10, 8, 14).Children(func() {
					filter := 0
					if a.logProblemsOnly {
						filter = 1
					}
					ui.Row(c).Children(func() {
						if ui.Segmented(c, &filter, "全部", fmt.Sprintf("只看问题 %d", problems)).Label("日志筛选").Changed() {
							a.logProblemsOnly = filter == 1
						}
					})
					ui.Spacer(c)
					if ui.Button(c, "复制").Tooltip("复制全部日志原文").Disabled(len(a.log) == 0).Clicked() {
						c.Services().WriteClipboard(strings.Join(a.log, "\n"))
						c.Toast("日志已复制")
					}
					if ui.Button(c, "清空").Disabled(len(a.log) == 0 || a.running).Clicked() {
						a.log, a.logParsed = nil, nil
					}
				})
				ui.Box(c).Height(1).Background(hairline(t))
				if len(rows) == 0 {
					msg := "还没有日志，运行一次后会显示在这里"
					if a.logProblemsOnly && len(a.log) > 0 {
						msg = "没有警告、错误或删除"
					}
					ui.Column(c).Grow(1).Center().Children(func() { muted(c, msg) })
					return
				}
				ui.List(c, &a.logList, len(rows), func(i int) {
					a.logRow(c, a.logParsed[rows[i]])
				}).Grow(1).Padding(2, 0, 10, 0)
			})
		})
	})
}
