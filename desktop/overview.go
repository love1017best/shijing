package main

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"desktop/core"

	"github.com/egoist/mygo/plugins/glass"
	"github.com/egoist/mygo/ui"
)

// ── 概览 ──────────────────────────────────────────────────────────────────

func (a *app) overviewPage(c *ui.Context) {
	pageHeader(c, "概览", "", nil)
	a.hero(c)
	a.pendingBar(c)

	switch {
	case a.running:
		a.runningCard(c)
	case a.last != nil && a.last.err != nil:
		a.errorCard(c)
	}
	a.thumbStrip(c)
	a.statStrip(c)
	a.logPanel(c)
	a.pendingModal(c)
}

// hero 是概览顶部的大横幅：背景是当前壁纸里的一张图，没有壁纸时画一幅暮色山景。
func (a *app) hero(c *ui.Context) {
	t := c.Theme()
	dirs := a.allDirs()
	white := ui.RGB(255, 255, 255)

	box := ui.Box(c).Height(236).Radius(16).Clip().Background(duskTop)
	// 轮播（advanceHero，main.go 每 heroInterval 调一次）换上的那张，没换过就是 walls.hero
	heroBmp, heroPath := a.walls.shownHero()
	canSlide := heroBmp != nil && heroPath != "" && !a.running
	if canSlide {
		// 点横幅空白处进入幻灯片模式（按钮各管各的；右键菜单仍可直接查看大图或整理）
		box.Label("横幅壁纸").Cursor(ui.CursorPointer).Tooltip(filepath.Base(heroPath) + "（单击进入幻灯片，右键打开菜单）").
			ContextMenu(func(m *ui.Menu) { a.wallMenu(m, heroPath) })
		if box.Clicked() {
			a.openSlideshowOf(heroPath)
		}
	}
	box.Children(func() {
		if heroBmp != nil {
			ui.Image(c, heroBmp).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(ui.Cover)
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

		if canSlide {
			ui.Row(c).Absolute().Top(14).Right(16).Gap(5).AlignItems(ui.Center).
				Padding(5, 10).Radius(14).
				Material(glass.Glass{Tint: ui.RGBA(0, 0, 0, 0.22)}).
				Border(1, white.Alpha(0.18)).Children(func() {
				ui.Icon(c, iconPlay).FontSize(11).TextColor(white.Alpha(0.92))
				ui.Text(c, "幻灯片").FontSize(11.5).TextColor(white.Alpha(0.92)).SingleLine()
			})
		}

		ui.Row(c).Absolute().Left(24).Right(22).Bottom(20).Gap(16).AlignItems(ui.End).Children(func() {
			ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(4).Children(func() {
				ui.Text(c, a.heroEyebrow()).FontSize(12).TextColor(white.Alpha(0.78)).SingleLine()
				ui.Text(c, a.heroTitle()).FontSize(24).Bold().TextColor(white).SingleLine()
				// 张数、画质在下面的摘要条里；这里只放去向，或者需要处理的问题
				warn := ""
				switch n := a.unmountedCount(); {
				case a.running:
				case strings.TrimSpace(a.cfg.DestDir) == "":
					warn = "尚未设置壁纸文件夹，请先在「设置」中选择"
				case n > 0 && n == len(dirs):
					warn = "图库目录均未挂载，连接后可在「图库」中重新检查"
				case n > 0:
					warn = fmt.Sprintf("%d 个目录未挂载，本次将跳过", n)
				}
				if warn != "" {
					ui.Row(c).Gap(5).AlignItems(ui.Center).Children(func() {
						amber := ui.Hex("#FFD27A")
						ui.Icon(c, iconAlert).FontSize(12).TextColor(amber)
						ui.Text(c, warn).FontSize(12.5).TextColor(amber).SingleLine()
					})
				} else {
					ui.Row(c).Gap(6).AlignItems(ui.Center).MinWidth(0).Children(func() {
						ui.Text(c, modeLabel(modes[a.modeIdx])+"到 "+a.cfg.DestDir).
							FontSize(12.5).TextColor(white.Alpha(0.82)).SingleLine().Shrink(1)
						// 会删原图时在这里说一句（点「换一批」时还会再确认一次）
						if a.willDelete() {
							amber := ui.Hex("#FFD27A")
							ui.Row(c).Shrink(0).Gap(4).AlignItems(ui.Center).Tooltip(a.deleteNotice()).Children(func() {
								ui.Icon(c, iconAlert).FontSize(11.5).TextColor(amber)
								ui.Text(c, "此操作会删除原图").FontSize(12.5).TextColor(amber).SingleLine()
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
		return "正在更换壁纸"
	case a.last != nil && a.last.err == nil:
		return "当前壁纸 · " + a.last.at.Format("1月2日 15:04") + " 更换"
	case a.stoppedWithCopies():
		return "当前壁纸 · " + a.last.at.Format("1月2日 15:04") + " 更换（中途停止）"
	case len(a.walls.all) > 0:
		return "当前壁纸"
	default:
		return "拾景"
	}
}

func (a *app) heroTitle() string {
	switch {
	case a.running:
		return "正在更换壁纸…"
	case a.last != nil && a.last.err == nil:
		return fmt.Sprintf("已更换 %d 张壁纸", a.last.sum.Copy.Copied)
	case a.stoppedWithCopies():
		return fmt.Sprintf("已更换 %d 张壁纸", a.last.sum.Copy.Copied)
	case len(a.walls.all) > 0:
		return fmt.Sprintf("%d 张壁纸", len(a.walls.all))
	case len(a.allDirs()) == 0:
		return "先在「图库」里添加目录"
	default:
		return "从图库中选取壁纸"
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
		grid.Opacity(0.4).Tooltip("正在更换壁纸，当前显示上一批")
	}
	grid.Children(func() {
		for i := range shown {
			cell := ui.Box(c).AspectRatio(stripAspect).Radius(9).Clip().Background(hairline(t)).
				Label(fmt.Sprintf("壁纸 %d", i+1))
			if i >= len(paths) || w.thumbs[paths[i]] == nil {
				continue // 还在解码
			}
			path := paths[i]
			cell.Cursor(ui.CursorPointer).Tooltip(filepath.Base(path) + "（按空格预览，右键打开菜单）").Children(func() {
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
			more.Label("查看全部壁纸").Tooltip(fmt.Sprintf("打开「壁纸」页看全部 %d 张（可以搜索、按目录筛选）", len(paths)))
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
			a.page = pageWalls
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
			mountSub = "未添加"
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
			tip = fmt.Sprintf("每次 %d 张，优先选择本轮未更换过的图片；整个图库都更换过一遍后开始新一轮", int(a.num))
		case a.cfg.PreferUnseen:
			sub = "优先选未更换过的"
		case a.cfg.BalanceFirst:
			sub = "平衡采样"
		}
		cell(1, "采样", value, sub, t.TextMuted, tip)
		// 定时自动换（设置里的「自动换壁纸」）没打开时不占一格
		if h := a.buildConfig().AutoRunHours; h > 0 {
			cell(2, "自动换", autoRunLabel(h), "下一次 "+a.nextAutoRun().Format("1月2日 15:04"), t.TextMuted,
				"应用开着时按这个间隔自动换一批（不删原图），在「设置 › 自动换壁纸」里修改或关闭")
		}

		switch r := a.last; {
		case r == nil:
			cell(3, "上次运行", "—", "尚未运行", t.TextMuted, "")
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
				value = fmt.Sprintf("已更换 %d 张", c.Selected-c.Repeated)
			}
			cell(3, "上次运行", value, sub, color, a.resultDetail())
		}
	})
}

// logPanel 是折叠起来的运行日志：工具条（筛选、复制、清空）+ 按类型排版的日志列表。
func (a *app) logPanel(c *ui.Context) {
	t := c.Theme()
	ui.Collapsible(c, fmt.Sprintf("运行日志（%d 行）", len(a.log)), &a.logShown, func() {
		rows, problems := a.logFilter()
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
						a.log, a.logParsed, a.logParsedFirst, a.logRows, a.logProblems = nil, nil, "", nil, 0
						rows = nil
					}
				})
				ui.Box(c).Height(1).Background(hairline(t))
				if len(rows) == 0 {
					msg := "暂无日志，运行一次后会显示在这里"
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
