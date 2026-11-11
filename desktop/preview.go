package main

import (
	"fmt"
	"path/filepath"
	"slices"

	"github.com/egoist/mygo/ui"
)

// 三种操作的说法要让人一眼看出动不动原图：「移出」只删壁纸文件夹里的那份，「删除原图」才动图库。
const (
	actRemove     = "移出壁纸文件夹"
	actExclude    = "移出并不再选它"
	actDelete     = "删除图库里的原图…"
	actRemoveTip  = "只删掉壁纸文件夹里的这一份，图库里的原图不动，以后还可能再被选中"
	actExcludeTip = "同「移出壁纸文件夹」，原图不动；另外把它加进「不再选的图片」，以后采样跳过它（图库页可以恢复）"
	actDeleteTip  = "从图库里删除原图，不可撤销，会记进删除记录"
)

// wallMenu 是缩略图的右键菜单（和大图预览里的按钮是同一组操作）。
func (a *app) wallMenu(m *ui.Menu, wall string) {
	src := a.wallSource(wall)
	if m.Item("查看大图").Chosen() {
		a.openPreviewOf(wall)
	}
	if m.Item("用默认应用打开").Chosen() {
		a.openPath(wall)
	}
	if src != "" && m.Item("在 Finder 中显示原图").Chosen() {
		a.openPath(filepath.Dir(src))
	}
	m.Separator()
	if m.Item(actRemove + "（原图保留）").Chosen() {
		a.removeWallpaper(wall, false)
	}
	if src != "" {
		if m.Item(actExclude + "（原图保留）").Chosen() {
			a.removeWallpaper(wall, true)
		}
		m.Separator()
		if m.Item(actDelete).Danger().Chosen() {
			a.askDeleteOriginal(wall)
		}
	}
}

func (a *app) askDeleteOriginal(wall string) {
	a.pendingDelWall, a.confirmDelSrc = wall, true
}

// openPreview 打开第 i 张缩略图的大图；预览可以翻看壁纸文件夹里的全部图片，不只是缩略图里那几张。
func (a *app) openPreview(i int) {
	if i >= 0 && i < len(a.walls.paths) {
		a.openPreviewOf(a.walls.paths[i])
	}
}

func (a *app) openPreviewOf(wall string) {
	if i := slices.Index(a.walls.all, wall); i >= 0 {
		a.preview, a.previewIdx = true, i
	}
}

// loadPreview 在后台把预览的那张解码成大图（缩略图只有 360 像素宽，还有很多张没有缩略图）。
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

// previewBitmap 是预览要显示的图：大图解码好了用大图，否则先用缩略图顶着，都没有返回 nil。
func (a *app) previewBitmap(wall string) *ui.Bitmap {
	if a.previewImg != nil && a.previewFor == wall {
		return a.previewImg
	}
	if i := slices.Index(a.walls.paths, wall); i >= 0 {
		return a.walls.thumbs[i]
	}
	if wall != "" && wall == a.walls.heroPath {
		return a.walls.hero
	}
	return nil
}

// fitBox 让预览框和图片同比例（不留黑边），并且不超过 maxW × maxH。
func fitBox(imgW, imgH int, maxW, maxH float32) (w, h float32) {
	ratio := float32(16.0 / 10)
	if imgW > 0 && imgH > 0 {
		ratio = float32(imgW) / float32(imgH)
	}
	w = min(maxW, maxH*ratio)
	return w, w / ratio
}

// previewModal 是大图预览：可以翻看壁纸文件夹里的全部图片（←→），直接在这里移出或删除。
func (a *app) previewModal(c *ui.Context) {
	t := c.Theme()
	w := &a.walls
	if a.preview && (a.previewIdx >= len(w.all) || a.running) {
		a.preview = false
	}
	step := func(d int) {
		if n := len(w.all); n > 0 {
			a.previewIdx = (a.previewIdx + d + n) % n
		}
	}
	if a.preview {
		a.loadPreview(w.all[a.previewIdx])
		switch {
		case c.Shortcut(0, ui.KeyLeft):
			step(-1)
		case c.Shortcut(0, ui.KeyRight), c.Shortcut(0, ui.KeySpace):
			step(1)
		}
	}
	vw, vh := c.Size()
	ui.Modal(c, &a.preview, func() {
		if a.previewIdx >= len(w.all) {
			return
		}
		wall := w.all[a.previewIdx]
		src := a.wallSource(wall)
		bmp := a.previewBitmap(wall)
		var iw, ih int
		if bmp != nil {
			iw, ih = bmp.Size()
		}
		// 图片框和图片同比例，整个弹层始终比主窗口小
		boxW, boxH := fitBox(iw, ih, min(vw*0.86, 1200)-40, vh*0.86-150)
		ui.Column(c).Width(max(boxW+40, 560)).Gap(14).Padding(20).AlignItems(ui.Center).Children(func() {
			box := ui.Box(c).Size(boxW, boxH).Radius(10).Clip()
			if bmp == nil {
				box.Background(hairline(t)).Center().Children(func() {
					ui.Text(c, "正在载入…").FontSize(12).TextColor(t.TextMuted)
				})
			} else {
				box.Children(func() {
					ui.Image(c, bmp).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(ui.Cover)
				})
			}

			ui.Row(c).AlignSelf(ui.Stretch).Gap(12).AlignItems(ui.Center).Children(func() {
				ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
					ui.Text(c, filepath.Base(wall)).FontSize(13).Bold().SingleLine()
					sub := "原图：没有记录（之前的版本换上的）"
					if src != "" {
						sub = "原图：" + tildify(src)
					}
					ui.Text(c, sub).FontSize(11.5).TextColor(t.TextMuted).SingleLine().Tooltip(src)
				})
				ui.Text(c, fmt.Sprintf("%d / %d", a.previewIdx+1, len(w.all))).FontSize(12).TextColor(t.TextMuted)
				iconButton(c, iconChevronLeft, "上一张", false).Tooltip("←").OnClick(func() { step(-1) })
				iconButton(c, iconChevronRight, "下一张", false).Tooltip("→ 或空格").OnClick(func() { step(1) })
			})

			ui.Box(c).AlignSelf(ui.Stretch).Height(1).Background(hairline(t))
			ui.Row(c).AlignSelf(ui.Stretch).Gap(8).AlignItems(ui.Center).Wrap().Children(func() {
				ui.Button(c, "用默认应用打开").OnClick(func() { a.openPath(wall) })
				if src != "" {
					ui.Button(c, "在 Finder 中显示原图").OnClick(func() { a.openPath(filepath.Dir(src)) })
				}
				ui.Spacer(c)
				ui.Button(c, actRemove).Tooltip(actRemoveTip).OnClick(func() { a.removeWallpaper(wall, false) })
				if src != "" {
					ui.Button(c, actExclude).Tooltip(actExcludeTip).OnClick(func() { a.removeWallpaper(wall, true) })
					ui.Button(c, actDelete).TextColor(t.Danger).Tooltip(actDeleteTip).OnClick(func() { a.askDeleteOriginal(wall) })
				}
			})
			note := "「移出」只删壁纸文件夹里的这一份，图库里的原图不动；「不再选它」还会让以后的采样跳过它。"
			if src != "" {
				note += "只有「删除图库里的原图」会真的删掉原图，不可撤销。"
			} else {
				note += "这张是之前的版本换上的，找不到对应的原图，只能移出。"
			}
			muted(c, note).AlignSelf(ui.Stretch)
		})
	}).Label("壁纸预览")

	// 删除原图前确认
	if a.confirmDelSrc {
		src := a.wallSource(a.pendingDelWall)
		msg := fmt.Sprintf("会从图库里删除原图 %s，并移出壁纸文件夹。删除不可撤销，会记进删除记录。", tildify(src))
		if ui.AlertDialog(c, &a.confirmDelSrc, "删除图库里的这张原图？", msg, "取消", "删除原图") == 1 {
			a.deleteOriginal(a.pendingDelWall)
		}
	}
}
