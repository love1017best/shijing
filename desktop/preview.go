package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"
)

// previewKeys 处理预览里的键盘操作（快捷键在「快捷键」页可以改，见 shortcuts.go）。要在 Modal 里面调用：
// Modal 外面的 Shortcut 被弹层挡住收不到；删除确认框弹出时预览在它后面，这里同样收不到，回车 / Esc 归确认框。
// 回车不能当快捷键：弹层会把焦点放在按钮上，回车归那个按钮。
func (a *app) previewKeys(c *ui.Context, wall string, hasSrc bool, step func(int)) {
	// 默认是空格 / ⇧空格翻页、J K L 整理（按轻重从左到右），手不用离开主键区。
	// 移出、删除这类操作不吃按住不放的自动重复（once），免得一下子移出一串
	switch {
	case a.pressed(c, "prev", false), c.Shortcut(ui.Shift, ui.KeySpace):
		step(-1)
	case a.pressed(c, "next", false), c.Shortcut(0, ui.KeySpace):
		step(1)
	case a.pressed(c, "remove", true):
		a.removeWallpaper(wall, false)
	case hasSrc && a.pressed(c, "exclude", true):
		a.removeWallpaper(wall, true)
	case hasSrc && a.pressed(c, "delete", true):
		a.askDeleteOriginal(wall)
	case a.pressed(c, "open", true):
		a.openPath(wall)
	case hasSrc && a.pressed(c, "reveal", true):
		a.openPath(filepath.Dir(a.wallSource(wall)))
	}
}

// keyButton 是带快捷键标注的按钮：文字后面跟一个小 keycap。icon 可以为 nil。
func keyButton(c *ui.Context, icon *ui.SVG, label, key string) ui.Element {
	t := c.Theme()
	return ui.Button(c, "").Label(label).Tooltip(withKey(label, key)).Children(func() {
		if icon != nil {
			ui.Icon(c, icon)
		}
		ui.Text(c, label).SingleLine()
		if key != "" {
			ui.Text(c, key).FontSize(10.5).TextColor(t.TextMuted).SingleLine().
				Padding(1, 5).Radius(4).Border(1, hairline(t))
		}
	})
}

// iconOnly 是只有图标的按钮（上一张 / 下一张），无障碍名和提示单独给。
func iconOnly(c *ui.Context, icon *ui.SVG, label, tip string) ui.Element {
	return ui.Button(c, "").Label(label).Tooltip(tip).Children(func() { ui.Icon(c, icon) })
}

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
		a.previewKeys(c, wall, src != "", step)
		// 图片框和图片同比例，整个弹层始终比主窗口小
		boxW, boxH := fitBox(iw, ih, min(vw*0.86, 1200)-40, vh*0.86-190)
		ui.Column(c).Width(min(max(boxW+40, 760), vw*0.9)).Gap(14).Padding(20).AlignItems(ui.Center).Children(func() {
			// 焦点放在图片上而不是第一个按钮上：按钮有焦点时空格 / 回车会按下它，翻页的空格就不灵了
			box := ui.Box(c).Size(boxW, boxH).Radius(10).Clip().Label("预览图片").Focusable().FocusRing(false).AutoFocus()
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
				iconOnly(c, iconChevronLeft, "上一张", withKey("上一张", a.keyLabel("prev"))+"，⇧空格也行").OnClick(func() { step(-1) })
				iconOnly(c, iconChevronRight, "下一张", withKey("下一张", a.keyLabel("next"))+"，空格也行").OnClick(func() { step(1) })
			})

			ui.Box(c).AlignSelf(ui.Stretch).Height(1).Background(hairline(t))
			ui.Row(c).AlignSelf(ui.Stretch).Gap(8).AlignItems(ui.Center).Wrap().Children(func() {
				keyButton(c, nil, "打开", a.keyLabel("open")).Tooltip(withKey("用默认应用打开", a.keyLabel("open"))).OnClick(func() { a.openPath(wall) })
				if src != "" {
					keyButton(c, nil, "显示原图", a.keyLabel("reveal")).Tooltip(withKey("在 Finder 中显示原图", a.keyLabel("reveal"))).OnClick(func() { a.openPath(filepath.Dir(src)) })
				}
				ui.Spacer(c)
				keyButton(c, nil, actRemove, a.keyLabel("remove")).Tooltip(actRemoveTip).OnClick(func() { a.removeWallpaper(wall, false) })
				if src != "" {
					keyButton(c, nil, actExclude, a.keyLabel("exclude")).Tooltip(actExcludeTip).OnClick(func() { a.removeWallpaper(wall, true) })
					keyButton(c, nil, actDelete, a.keyLabel("delete")).TextColor(t.Danger).Tooltip(actDeleteTip).OnClick(func() { a.askDeleteOriginal(wall) })
				}
			})
			note := "「移出」只删壁纸文件夹里的这一份，图库里的原图不动；「不再选它」还会让以后的采样跳过它。"
			if src != "" {
				note += "只有「删除图库里的原图」会真的删掉原图，不可撤销。"
			} else {
				note += "这张是之前的版本换上的，找不到对应的原图，只能移出。"
			}
			muted(c, note+a.previewKeyHint()).AlignSelf(ui.Stretch)
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

// previewKeyHint 是预览底部那句键盘说明，跟着自定义的快捷键变。
func (a *app) previewKeyHint() string {
	nav := strings.TrimSpace(a.keyLabel("prev") + " " + a.keyLabel("next"))
	hint := "按钮上标着快捷键（可以在「快捷键」页修改）；"
	if nav != "" {
		hint += nav + " 或 空格 / ⇧空格 切换图片，"
	} else {
		hint += "空格 / ⇧空格 切换图片，"
	}
	if d := a.keyLabel("delete"); d != "" {
		hint += d + " 后按回车确认删除，"
	}
	return hint + "Esc 关闭。"
}
