package main

import (
	"fmt"
	"path/filepath"

	"github.com/egoist/mygo/ui"
)

// wallMenu 是缩略图（和大图预览）的操作菜单。
func (a *app) wallMenu(m *ui.Menu, wall string) {
	src := a.wallSource(wall)
	if m.Item("用默认应用打开").Chosen() {
		a.openPath(wall)
	}
	if src != "" && m.Item("在 Finder 中显示原图所在文件夹").Chosen() {
		a.openPath(filepath.Dir(src))
	}
	m.Separator()
	if m.Item("从壁纸文件夹移除").Chosen() {
		a.removeWallpaper(wall, false)
	}
	if src != "" {
		if m.Item("移除并不再选它").Chosen() {
			a.removeWallpaper(wall, true)
		}
		if m.Item("删除原图…").Danger().Chosen() {
			a.askDeleteOriginal(wall)
		}
	}
}

func (a *app) askDeleteOriginal(wall string) {
	a.pendingDelWall, a.confirmDelSrc = wall, true
}

func (a *app) openPreview(i int) {
	if i < 0 || i >= len(a.walls.paths) {
		return
	}
	a.preview, a.previewIdx = true, i
}

// loadPreview 在后台把预览的那张解码成大图（缩略图只有 360 像素宽）。
func (a *app) loadPreview(path string) {
	if a.previewFor == path || a.update == nil {
		return
	}
	a.previewFor, a.previewImg = path, nil
	go func() {
		img := loadScaled(path, heroWidth)
		if img == nil {
			return
		}
		a.update(func() {
			if a.previewFor == path {
				a.previewImg = ui.NewBitmap(img)
			}
		})
	}()
}

// previewModal 是缩略图的大图预览：左右方向键切换，Esc 或点外面关闭。
func (a *app) previewModal(c *ui.Context) {
	t := c.Theme()
	w := &a.walls
	if a.preview && (a.previewIdx >= len(w.paths) || a.running) {
		a.preview = false
	}
	if a.preview {
		a.loadPreview(w.paths[a.previewIdx])
		switch {
		case c.Shortcut(0, ui.KeyLeft):
			a.previewIdx = (a.previewIdx + len(w.paths) - 1) % len(w.paths)
		case c.Shortcut(0, ui.KeyRight), c.Shortcut(0, ui.KeySpace):
			a.previewIdx = (a.previewIdx + 1) % len(w.paths)
		}
	}
	vw, vh := c.Size()
	ui.Modal(c, &a.preview, func() {
		if a.previewIdx >= len(w.paths) {
			return
		}
		wall := w.paths[a.previewIdx]
		src := a.wallSource(wall)
		width := min(vw*0.82, 1100)
		ui.Column(c).Width(width).Gap(12).Padding(16).Children(func() {
			img := w.thumbs[a.previewIdx]
			if a.previewImg != nil && a.previewFor == wall {
				img = a.previewImg
			}
			ui.Box(c).Height(min((width-32)/1.6, vh*0.62)).Radius(10).Clip().Background(ui.RGB(0, 0, 0)).Children(func() {
				ui.Image(c, img).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(ui.Contain)
			})
			ui.Row(c).Gap(12).AlignItems(ui.Center).Children(func() {
				ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
					ui.Text(c, filepath.Base(wall)).FontSize(13).Bold().SingleLine()
					sub := "原图：没有记录（之前的版本换上的）"
					if src != "" {
						sub = "原图：" + tildify(src)
					}
					ui.Text(c, sub).FontSize(11.5).TextColor(t.TextMuted).SingleLine().Tooltip(src)
				})
				ui.Text(c, fmt.Sprintf("%d / %d", a.previewIdx+1, len(w.paths))).FontSize(12).TextColor(t.TextMuted)
				iconButton(c, iconChevronLeft, "上一张", false).Tooltip("←").OnClick(func() {
					a.previewIdx = (a.previewIdx + len(w.paths) - 1) % len(w.paths)
				})
				iconButton(c, iconChevronRight, "下一张", false).Tooltip("→").OnClick(func() {
					a.previewIdx = (a.previewIdx + 1) % len(w.paths)
				})
				ui.Button(c, "更多…").PopoverMenu(func(m *ui.Menu) { a.wallMenu(m, wall) })
			})
		})
	}).Label("壁纸预览")

	// 删除原图前确认（只在这里弹，不用运行时的删除确认）
	if a.confirmDelSrc {
		src := a.wallSource(a.pendingDelWall)
		msg := fmt.Sprintf("会从图库里删除原图 %s，并从壁纸文件夹移除。删除不可撤销，会记进删除记录。", tildify(src))
		if ui.AlertDialog(c, &a.confirmDelSrc, "删除这张原图？", msg, "取消", "删除原图") == 1 {
			a.deleteOriginal(a.pendingDelWall)
		}
	}
}
