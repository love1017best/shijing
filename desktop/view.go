package main

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

func (a *app) view(c *ui.Context) {
	if !a.initialized {
		a.initialized = true
		a.checkMounts()
	}
	if a.scanWallpapers != nil && !a.walls.loading &&
		(a.walls.dir != core.ExpandUser(a.cfg.DestDir) || a.wallsGen != a.wallsLoadedGen) {
		a.wallsLoadedGen = a.wallsGen
		a.loadWallpapers()
	}
	// 「删除不合格原图」被重新打开：恢复运行前的确认
	if a.cfg.DeleteDuringFilter && !a.prevDelete && a.skipConfirm {
		a.skipConfirm = false
		a.saveUIState()
	}
	a.prevDelete = a.cfg.DeleteDuringFilter
	if a.toast != "" {
		c.Toast(a.toast)
		a.toast = ""
	}
	t := applyTheme(c)
	vibrant := c.Vibrancy()
	if vibrant {
		c.Root().Background(ui.Transparent)
	}

	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		side := ui.Column(c).Width(sidebarWidth).Shrink(0)
		if !vibrant {
			side.Background(sidebarBg(t))
		}
		side.Children(func() { a.sidebar(c, vibrant) })
		ui.Box(c).Width(1).Background(hairline(t))

		ui.Column(c).Grow(1).MinWidth(0).Background(pageBg(t)).Children(func() {
			// 隐藏标题栏后，内容区顶部这一条用来拖动窗口
			ui.Box(c).Height(max(c.TitleBar().Height, 24)).Shrink(0).DragWindow()
			ui.Scroll(c).Grow(1).Children(func() {
				ui.Column(c).Padding(0, 36, 32, 36).Gap(22).MaxWidth(contentMax).Children(func() {
					switch a.page {
					case pageLibrary:
						a.libraryPage(c)
					case pageSettings:
						a.settingsPage(c)
					case pageArchive:
						a.archivePage(c)
					case pageAbout:
						a.aboutPage(c)
					default:
						a.overviewPage(c)
					}
				})
			})
		})
	})
	a.autosave()
}

func sidebarBg(t *ui.Theme) ui.Color {
	if t.Dark {
		return ui.Hex("#232228")
	}
	return ui.Hex("#ECEBF1")
}

// ── 侧边栏 ────────────────────────────────────────────────────────────────

func (a *app) sidebar(c *ui.Context, vibrant bool) {
	t := c.Theme()
	ui.Box(c).Height(titleBarHeight).Shrink(0).DragWindow()
	ui.Row(c).Gap(10).AlignItems(ui.Center).Padding(0, 18, 14, 18).DragWindow().Children(func() {
		if appIcon != nil {
			ui.Image(c, appIcon).Size(34, 34)
		}
		ui.Column(c).Gap(1).Children(func() {
			ui.Text(c, appName).FontSize(16).Bold()
			ui.Text(c, "壁纸采样").FontSize(11).TextColor(t.TextMuted)
		})
	})

	list := ui.Sidebar(c, &a.page, func() {
		ui.SidebarItem(c, pageOverview, iconHome, "概览")
		ui.SidebarItem(c, pageLibrary, iconFolder, "图库").Children(func() {
			if n := a.unmountedCount(); n > 0 {
				ui.Badge(c, fmt.Sprintf("%d 未挂载", n)).Background(t.Warning).TextColor(ui.RGB(255, 255, 255))
			} else {
				ui.Badge(c, fmt.Sprint(len(a.allDirs())))
			}
		})
		ui.SidebarItem(c, pageSettings, iconSliders, "设置")
		ui.SidebarItem(c, pageArchive, iconArchive, "归档").Children(func() {
			if a.cfg.ArchiveEnabled {
				ui.Badge(c, "开").Background(t.Success.Alpha(0.18)).TextColor(t.Success)
			}
		})
		ui.SidebarItem(c, pageAbout, iconInfo, "关于")
	}).Grow(1).Padding(0, 8).Label("页面")
	list.Background(ui.Transparent)

	ui.Row(c).Gap(6).AlignItems(ui.Center).Padding(10, 20, 14, 20).Children(func() {
		if a.saveErr != "" {
			ui.Icon(c, iconAlert).FontSize(12).TextColor(t.Danger)
			ui.Text(c, "保存失败："+a.saveErr).FontSize(11).TextColor(t.Danger).Wrap()
			return
		}
		ui.Icon(c, iconCloudCheck).FontSize(13).TextColor(t.TextMuted)
		ui.Text(c, "设置已自动保存").FontSize(11).TextColor(t.TextMuted)
	})
}

// ── 概览 ──────────────────────────────────────────────────────────────────

func (a *app) resLabel() string {
	if a.preset < len(resPresets) {
		return resPresets[a.preset].label
	}
	return fmt.Sprintf("%d×%d", int(a.minW), int(a.minH))
}

func (a *app) modeLabel() string {
	if a.modeIdx == 1 {
		return "软链接"
	}
	return "复制"
}

func (a *app) overviewPage(c *ui.Context) {
	t := c.Theme()
	pageHeader(c, "概览", "", nil)
	a.hero(c)

	if a.cfg.DeleteDuringFilter && len(a.cfg.FilterAndSampleDirs) > 0 && !a.running {
		ui.Row(c).Gap(6).AlignItems(ui.Center).Margin(-10, 0, 0, 4).Children(func() {
			ui.Icon(c, iconAlert).FontSize(12).TextColor(t.Warning)
			ui.Text(c, "运行时会先删除「筛选 + 采样」目录里不合格的原图，删除不可撤销").FontSize(12).TextColor(t.Warning).Wrap()
		})
	}

	switch {
	case a.running:
		a.runningCard(c)
	case a.last != nil && a.last.err != nil:
		a.errorCard(c)
	}
	a.thumbStrip(c)
	a.statStrip(c)
	a.logPanel(c)
}

// hero 是概览顶部的大横幅：背景是当前壁纸里的一张图，没有壁纸时画一幅暮色山景。
func (a *app) hero(c *ui.Context) {
	t := c.Theme()
	dirs := a.allDirs()
	white := ui.RGB(255, 255, 255)

	ui.Box(c).Height(236).Radius(16).Clip().Background(duskTop).Children(func() {
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
					ui.Text(c, a.modeLabel()+"到 "+a.cfg.DestDir).
						FontSize(12.5).TextColor(white.Alpha(0.82)).SingleLine()
				}
			})
			ui.Row(c).Shrink(0).Gap(10).AlignItems(ui.Center).Children(func() {
				if a.walls.total > 0 || (a.last != nil && a.last.err == nil) {
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
	case a.walls.total > 0:
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
	case a.walls.total > 0:
		return fmt.Sprintf("%d 张壁纸", a.walls.total)
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

// thumbStrip 是当前壁纸的缩略图条：点一张用默认应用打开它，最后一格打开整个文件夹。
// 运行中壁纸文件夹正在被清空重写，缩略图是上一批的，调暗并且不能点。
func (a *app) thumbStrip(c *ui.Context) {
	t := c.Theme()
	w := a.walls
	if w.total == 0 && !w.loading {
		return
	}
	grid := ui.Grid(c).Columns(stripThumbs + 1).Gap(10).Disabled(a.running)
	if a.running {
		grid.Opacity(0.4).Tooltip("正在换壁纸，这是上一批")
	}
	grid.Children(func() {
		for i := range stripThumbs {
			cell := ui.Box(c).AspectRatio(16.0 / 10).Radius(9).Clip().Background(hairline(t)).
				Label(fmt.Sprintf("壁纸 %d", i+1))
			if i >= len(w.thumbs) {
				continue
			}
			name := filepath.Base(w.paths[i])
			cell.Cursor(ui.CursorPointer).Tooltip(name).Children(func() {
				ui.Image(c, w.thumbs[i]).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(ui.Cover)
			})
			if !a.running && cell.Clicked() {
				a.openPath(w.paths[i])
			}
		}
		more := ui.ButtonBase(c).AspectRatio(16.0/10).Radius(9).Center().Column().Gap(2).
			Background(panelBg(t)).Border(1, hairline(t)).Label("查看全部壁纸").Tooltip("在 Finder 中打开壁纸文件夹")
		if more.Hovered() {
			more.Background(t.SurfaceHover)
		}
		more.Children(func() {
			if rest := w.total - len(w.thumbs); rest > 0 {
				ui.Text(c, fmt.Sprintf("+%d", rest)).FontSize(17).Bold()
				ui.Text(c, "查看全部").FontSize(11).TextColor(t.TextMuted)
			} else {
				ui.Icon(c, iconFolderOpen).FontSize(18).TextColor(t.TextMuted)
				ui.Text(c, "打开文件夹").FontSize(11).TextColor(t.TextMuted)
			}
		})
		if !a.running && more.Clicked() {
			a.openWallpapers()
		}
	})
}

// statStrip 是一条四格的摘要：图库、采样、画质、上次运行。
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
		balance := "完全随机"
		if a.cfg.BalanceFirst {
			balance = "平衡采样"
		}
		cell(0, "图库", fmt.Sprintf("%d 个目录", len(dirs)), mountSub, mountColor, "")
		cell(1, "每次采样", fmt.Sprintf("%d 张", int(a.num)), balance, t.TextMuted, "")
		cell(2, "最低画质", a.resLabel()+" 横屏", fmt.Sprintf("%d×%d", int(a.minW), int(a.minH)), t.TextMuted, "")

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
					iconButton(c, iconStop, "停止", false).Tooltip("停止这次运行（⌘.）").OnClick(a.stopRun)
				}
			})
			ui.Progress(c, value).Label(label)
			ui.Text(c, cleanLogLine(a.lastLogLine())).FontSize(12).TextColor(t.TextMuted).SingleLine()
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

// cleanLogLine 去掉日志行开头的 emoji（保留缩进），颜色由 logColor 表达。
func cleanLogLine(s string) string {
	trimmed := strings.TrimLeft(s, " ")
	indent := s[:len(s)-len(trimmed)]
	rs := []rune(trimmed)
	i := 0
	for i < len(rs) && (unicode.Is(unicode.So, rs[i]) || rs[i] == 0xFE0F || rs[i] == 0x200D) {
		i++
	}
	if i == 0 {
		return s
	}
	return indent + strings.TrimLeft(string(rs[i:]), " ")
}

// ── 图库 ──────────────────────────────────────────────────────────────────

func (a *app) libraryPage(c *ui.Context) {
	pageHeader(c, "图库", "两类目录都会参与采样，区别在于是否先删除不合格的图片。", func() {
		iconButton(c, iconRefresh, "重新检查挂载", false).OnClick(a.checkMounts)
	})
	ui.Column(c).Gap(26).Disabled(a.running).Children(func() {
		a.dirSection(c, "filter", "筛选 + 采样", iconScissors,
			"先删除竖屏、正方形、分辨率不足的图片，再参与采样。会直接删除原图，删除记录写在数据目录的删除日志里。", &a.filter)
		a.dirSection(c, "sample", "仅采样", iconHeart,
			"不删除任何文件，采样时跳过不合格的图片。适合收藏夹这类不想动的目录。", &a.sample)
	})
}

// commonParent 返回所有目录共同的上级目录（由配置里的目录算出来，不是写死的）；不一致时返回 ""。
func commonParent(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	p := filepath.Dir(filepath.Clean(dirs[0]))
	for _, d := range dirs[1:] {
		if filepath.Dir(filepath.Clean(d)) != p {
			return ""
		}
	}
	return p
}

func (a *app) dirSection(c *ui.Context, key, title string, icon *ui.SVG, desc string, p *dirPanel) {
	t := c.Theme()
	c.Key(key)
	dirs := *p.dirs
	parent := commonParent(dirs)
	ui.Column(c).Gap(10).Children(func() {
		ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
			ui.Box(c).Size(28, 28).Radius(8).Center().Background(t.Accent.Alpha(0.12)).Children(func() {
				ui.Icon(c, icon).FontSize(15).TextColor(t.Accent)
			})
			ui.Text(c, title).FontSize(16).Bold()
			ui.Text(c, fmt.Sprint(len(dirs))).FontSize(12).TextColor(t.TextMuted)
			ui.Spacer(c)
			if n := p.chosen.Len(); n > 0 {
				remove := "移除"
				if n > 1 {
					remove = fmt.Sprintf("移除 %d 项", n)
				}
				iconButton(c, iconTrash, remove, false).Label(title + " 移除").OnClick(func() { a.removeChosen(p) })
			}
			iconButton(c, iconPlus, "添加目录…", false).Label(title + " 添加").OnClick(func() { a.addDir(p) })
		})
		muted(c, desc).Padding(0, 0, 2, 38)
		// 共同的上级目录单独一行、不折行：拼进说明文字里，长路径会在中间断开
		if parent != "" && len(dirs) > 1 {
			ui.Row(c).Gap(6).AlignItems(ui.Center).Padding(0, 0, 0, 38).Children(func() {
				ui.Icon(c, iconFolderOpen).FontSize(12).TextColor(t.TextMuted)
				ui.Text(c, "都位于 "+parent).FontSize(12).TextColor(t.TextMuted).SingleLine().Tooltip(parent)
			})
		}

		p.list.Key = func(i int) any { return dirs[i] }
		p.list.Label = func(i int) string { return dirs[i] }
		p.list.Selection = &p.chosen
		box := panel(c).Clip()
		if len(dirs) == 0 {
			box.Children(func() {
				ui.Column(c).Height(84).Center().Gap(4).Children(func() {
					ui.Text(c, "还没有目录").FontSize(13).TextColor(t.TextMuted)
					muted(c, "点右上角的「添加目录…」，可以一次选一个文件夹")
				})
			})
			return
		}
		box.Children(func() {
			ui.List(c, &p.list, len(dirs), func(i int) {
				d := dirs[i]
				ui.Row(c).Gap(12).AlignItems(ui.Center).Padding(9, 14).ContextMenu(func(m *ui.Menu) {
					if m.Item("在 Finder 中打开").Chosen() {
						a.openPath(d)
					}
					m.Separator()
					// 右键的是已选中的多项之一：一起移除；否则只移除这一项
					if n := p.chosen.Len(); n > 1 && p.chosen.Has(d) {
						if m.Item(fmt.Sprintf("移除选中的 %d 项", n)).Danger().Chosen() {
							a.removeChosen(p)
						}
					} else if m.Item("移除").Danger().Chosen() {
						a.removeDir(p, d)
					}
				}).Children(func() {
					ui.Icon(c, iconFolder).FontSize(17).TextColor(t.Accent.Alpha(0.85))
					ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(1).Children(func() {
						ui.Text(c, filepath.Base(d)).FontSize(13.5).SingleLine()
						if parent == "" || len(dirs) == 1 {
							ui.Text(c, filepath.Dir(filepath.Clean(d))).FontSize(11).TextColor(t.TextMuted).SingleLine()
						}
					})
					switch a.mounts[d] {
					case mountOK:
						pill(c, "可访问", t.Success)
					case mountMissing:
						pill(c, "未挂载", t.Danger)
					case mountSlow:
						pill(c, "无响应", t.Warning)
					default:
						pill(c, "检查中", t.TextMuted)
					}
				})
			}).Height(listHeight(len(dirs), parent == "" || len(dirs) == 1)).Padding(4, 0)
		})
		if len(dirs) > 1 {
			muted(c, "按住 ⌘ 点击可以多选；右键可以在 Finder 中打开或移除").Padding(0, 4)
		}
	})
}

// listHeight 让列表按行数长高、全部显示：页面本身会滚动，列表里再套一层滚动会露出半行。
func listHeight(rows int, twoLine bool) float32 {
	row := float32(35)
	if twoLine {
		row = 46
	}
	return float32(rows)*row + 8
}

// ── 设置 ──────────────────────────────────────────────────────────────────

// pathInput 是「输入框 + 选择按钮」。
func (a *app) pathInput(c *ui.Context, value *string, label, dialogTitle string) {
	ui.Row(c).Gap(8).Children(func() {
		ui.TextInput(c, value).Grow(1).Label(label)
		if ui.Button(c, "选择…").Label(label + " 选择").Clicked() {
			a.browse(dialogTitle, func(p string) { *value = p })
		}
	})
}

func (a *app) settingsPage(c *ui.Context) {
	t := c.Theme()
	pageHeader(c, "设置", "改动会立即自动保存，下次运行生效。", nil)
	ui.Column(c).Gap(24).Disabled(a.running).Children(func() {
		group(c, "输出", "",
			func() {
				wideRow(c, "壁纸文件夹", "每次运行会先清空这个文件夹，再放入新选出的图片。系统壁纸幻灯片指向这里。", func() {
					a.pathInput(c, &a.cfg.DestDir, "壁纸文件夹", "选择壁纸文件夹")
				})
			},
			func() {
				settingRow(c, "存放方式", "复制占用磁盘空间但可以脱离图库使用；软链接省空间，但图库没挂载时壁纸会失效。", func(ui.Element) {
					ui.Segmented(c, &a.modeIdx, "复制", "软链接")
				})
			})

		group(c, "采样", "",
			func() {
				settingRow(c, "每次张数", "", func(ui.Element) {
					ui.NumberInput(c, &a.num, 1, 9999, 10).Width(150).Label("每次张数")
				})
			},
			func() {
				settingRow(c, "平衡采样", "优先让每个子文件夹至少入选一张，避免少数几个大文件夹占满名额。", func(l ui.Element) {
					ui.Switch(c, &a.cfg.BalanceFirst).LabelledBy(l)
				})
			})

		custom := a.preset >= len(resPresets)
		resRows := []func(){
			func() {
				desc := fmt.Sprintf("%d × %d", int(a.minW), int(a.minH))
				if custom {
					desc = "在下面填写宽和高"
				}
				settingRow(c, "最低分辨率", desc, func(ui.Element) {
					labels := make([]string, 0, len(resPresets)+1)
					for _, p := range resPresets {
						labels = append(labels, p.label)
					}
					labels = append(labels, "自定义")
					if ui.Segmented(c, &a.preset, labels...).Changed() && a.preset < len(resPresets) {
						a.minW, a.minH = float64(resPresets[a.preset].w), float64(resPresets[a.preset].h)
					}
				})
			},
		}
		if custom {
			resRows = append(resRows, func() {
				settingRow(c, "宽 × 高", "单位是像素。", func(ui.Element) {
					ui.NumberInput(c, &a.minW, 1, 99999, 1).Width(130).Label("最小宽度")
					ui.Text(c, "×").TextColor(t.TextMuted)
					ui.NumberInput(c, &a.minH, 1, 99999, 1).Width(130).Label("最小高度")
				})
			})
		}
		group(c, "画质要求", "只有横屏（宽高比大于 1.1）且不低于这个分辨率的图片才会被选中。", resRows...)

		group(c, "筛选", "只作用于「筛选 + 采样」目录。",
			func() {
				desc := "关闭后只是模拟运行：日志里列出哪些图片不合格，但不删除文件。"
				if a.cfg.DeleteDuringFilter {
					desc = "已开启：不合格的原图会被直接删除，不可撤销。关闭后只模拟运行。"
				}
				settingRow(c, "删除不合格原图", desc, func(l ui.Element) {
					if a.cfg.DeleteDuringFilter {
						ui.Icon(c, iconAlert).FontSize(14).TextColor(t.Warning)
					}
					ui.Switch(c, &a.cfg.DeleteDuringFilter).LabelledBy(l)
				})
			},
			func() {
				settingRow(c, "增量筛选", "跳过上次检查后没有变化的文件夹，只检查新增或修改过的。", func(l ui.Element) {
					ui.Switch(c, &a.cfg.Incremental).LabelledBy(l)
				})
			})

		group(c, "系统", "",
			func() {
				settingRow(c, "刷新系统壁纸", "换完一批后重启 macOS 的壁纸服务。系统设置里用这个文件夹随机切换壁纸时，不刷新的话系统会一直轮换已经删掉的旧图。", func(l ui.Element) {
					ui.Switch(c, &a.cfg.RefreshWallpaper).LabelledBy(l)
				})
			})

		group(c, "配置文件", "",
			func() {
				settingRow(c, "config.json", a.cfgPath, func(ui.Element) {
					iconButton(c, iconExternal, "在 Finder 中显示", false).OnClick(func() {
						a.openPath(filepath.Dir(a.cfgPath))
					})
					ui.Button(c, "导入配置…").OnClick(a.importConfig)
				})
			})
	})
}

// ── 归档 ──────────────────────────────────────────────────────────────────

func (a *app) archivePage(c *ui.Context) {
	t := c.Theme()
	pageHeader(c, "归档", "把每次选中的图片在图库旁边额外留一份链接，长期保留历史记录而不占双倍空间。", nil)
	ui.Column(c).Gap(24).Disabled(a.running).Children(func() {
		group(c, "", "",
			func() {
				ui.Row(c).Gap(16).AlignItems(ui.Center).Padding(16, 16).Children(func() {
					ui.Box(c).Size(36, 36).Radius(10).Center().Background(t.Accent.Alpha(0.12)).Children(func() {
						ui.Icon(c, iconArchive).FontSize(18).TextColor(t.Accent)
					})
					var title ui.Element
					ui.Column(c).Grow(1).Shrink(1).Gap(3).Children(func() {
						title = ui.Text(c, "启用归档").FontSize(15).Bold()
						muted(c, "优先建硬链接，不支持时自动降级为软链接。每次运行前会清空归档文件夹里上一批的内容。")
					})
					ui.Switch(c, &a.cfg.ArchiveEnabled).LabelledBy(title)
				})
			})

		ui.Column(c).Gap(24).Disabled(!a.cfg.ArchiveEnabled).Opacity(archiveOpacity(a.cfg.ArchiveEnabled)).Children(func() {
			group(c, "位置", "",
				func() {
					settingRow(c, "归档文件夹名", "建在每个归档位置下的子文件夹。", func(ui.Element) {
						ui.TextInput(c, &a.cfg.ArchiveSubdirName).Width(220).Label("归档文件夹名")
					})
				},
				func() {
					wideRow(c, "归档位置", "可选。留空时放在每个图库目录的上级路径下；填了下面的 NFS 路径则默认放在那里。", func() {
						a.pathInput(c, &a.cfg.ArchiveDirOverride, "归档位置", "选择归档位置（留空则自动使用各源目录的上级路径）")
					})
				})

			group(c, "跨挂载点硬链接", "两项都留空则不做换算。采样和复制始终走图库里配置的路径。",
				func() {
					ui.Column(c).Gap(12).Padding(14, 16).Children(func() {
						muted(c, "硬链接要求图片和链接在同一个挂载点。图库走 SMB 时建不了硬链接；如果同一份数据还有 NFS 挂载点，"+
							"填这两项就能在 NFS 下建真正的硬链接，Windows 也能读。")
						mountFlow(c, a.cfg.ArchiveSMBRoot, a.cfg.ArchiveNFSRoot)
					})
				},
				func() {
					wideRow(c, "SMB 根路径", "", func() {
						a.pathInput(c, &a.cfg.ArchiveSMBRoot, "SMB 根路径", "选择图库所在的 SMB 挂载根路径")
					})
				},
				func() {
					wideRow(c, "NFS 根路径", "", func() {
						a.pathInput(c, &a.cfg.ArchiveNFSRoot, "NFS 根路径", "选择同一份数据的 NFS 挂载根路径")
					})
				})
		})
	})
}

func archiveOpacity(on bool) float32 {
	if on {
		return 1
	}
	return 0.55
}

// mountFlow 画出 SMB → NFS 的换算关系。
func mountFlow(c *ui.Context, smb, nfs string) {
	t := c.Theme()
	node := func(kind, path string, color ui.Color) {
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(2).Padding(10, 12).Radius(9).
			Background(color.Alpha(0.08)).Border(1, color.Alpha(0.22)).Children(func() {
			ui.Text(c, kind).FontSize(11).Bold().TextColor(color)
			if path == "" {
				path = "未设置"
			}
			ui.Text(c, path).FontSize(12.5).SingleLine()
		})
	}
	ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
		node("SMB · 采样和复制", smb, t.TextMuted)
		ui.Icon(c, iconArrowRight).FontSize(16).TextColor(t.TextMuted)
		node("NFS · 建归档硬链接", nfs, t.Accent)
	})
}
