package main

import (
	"fmt"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

func (a *app) view(c *ui.Context) {
	if !a.initialized {
		a.initialized = true
		a.checkMounts()
	}
	if !a.preview {
		a.undoKey(c) // 预览开着时由 previewKeys 接
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
			sc := ui.Scroll(c).Grow(1)
			a.viewH, a.viewW = sc.LayoutBounds().H, sc.LayoutBounds().W
			sc.Children(func() {
				col := ui.Column(c).Padding(0, 36, 32, 36).Gap(22)
				// 概览页铺满窗口，缩略图跟着变多；设置类页面窗口宽时分两栏，窄时单栏（表单太宽不好读）
				switch {
				case a.page == pageOverview:
				case a.page == pageAbout:
					// 关于页内容少，铺宽了显得空：保持单栏宽度，居中放
					col.Width(min(max(a.viewW, 1), contentMax)).AlignSelf(ui.Center)
				case a.twoCol():
					col.MaxWidth(twoColMax)
				default:
					col.MaxWidth(contentMax)
				}
				a.pageH = col.LayoutBounds().H
				if a.page != pageKeys && a.recording != "" {
					a.stopRecording() // 录制到一半切走了
				}
				col.Children(func() {
					switch a.page {
					case pageLibrary:
						a.libraryPage(c)
					case pageSettings:
						a.settingsPage(c)
					case pageKeys:
						a.keysPage(c)
					case pageDeleted:
						a.deletedPage(c)
					case pageAbout:
						a.aboutPage(c)
					default:
						a.overviewPage(c)
					}
				})
			})
		})
	})
	a.pairModal(c)
	a.autosave()
	a.publishRemote()
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
		ui.SidebarItem(c, pageDeleted, iconTrash, "删除记录").Children(func() {
			if n := len(a.deleteRecords()); n > 0 {
				ui.Badge(c, humanCount(n))
			}
		})
		ui.SidebarItem(c, pageKeys, iconKeyboard, "快捷键")
		ui.SidebarItem(c, pageAbout, iconInfo, "关于")
	}).Grow(1).Padding(0, 8).Label("页面")
	list.Background(ui.Transparent)

	// 设置是自动保存的（设置页标题下写着），平时不占地方；只在保存失败时提示
	if a.saveErr != "" {
		ui.Row(c).Gap(6).AlignItems(ui.Center).Padding(10, 20, 14, 20).Children(func() {
			ui.Icon(c, iconAlert).FontSize(12).TextColor(t.Danger)
			ui.Text(c, "保存失败："+a.saveErr).FontSize(11).TextColor(t.Danger).Wrap()
		})
	}
}
