package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
)

// previewKeys 处理预览里的键盘操作（快捷键在「快捷键」页可以改，见 shortcuts.go）。要在 Modal 里面调用：
// Modal 外面的 Shortcut 被弹层挡住收不到；删除确认框弹出时预览在它后面，这里同样收不到，回车 / Esc 归确认框。
// 回车不能当快捷键：弹层会把焦点放在按钮上，回车归那个按钮。
func (a *app) previewKeys(c *ui.Context, wall string, hasSrc bool, step func(int)) {
	a.undoKey(c)
	if a.jumpKeys(c) {
		return
	}
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
	case a.pressed(c, "reveal_wall", true):
		a.revealPath(wall)
	case hasSrc && a.pressed(c, "reveal", true):
		a.revealPath(a.wallSource(wall))
	}
}

// jumpKeys 处理输入编号跳转：数字键攒编号，回车跳过去，⌫ 删一位；Esc 放弃（不关预览）在 previewModal 里处理。
// 正在输入时别的快捷键照常用，按了就放弃输入的编号。返回 true 表示这一帧的按键被它用掉了。
func (a *app) jumpKeys(c *ui.Context) bool {
	for d := range 10 {
		if c.Shortcut(0, ui.Key0+ui.Key(d)) {
			if len(a.jumpBuf) < 6 && !(a.jumpBuf == "" && d == 0) {
				a.jumpBuf += strconv.Itoa(d)
			}
			return true
		}
	}
	if a.jumpBuf == "" {
		return false
	}
	switch {
	case c.Shortcut(0, ui.KeyEnter):
		n, _ := strconv.Atoi(a.jumpBuf)
		a.jumpBuf = ""
		if total := len(a.walls.all); n >= 1 && n <= total {
			a.previewIdx = n - 1
		} else {
			a.toast = fmt.Sprintf("没有第 %d 张，一共 %d 张", n, total)
		}
		return true
	case c.Shortcut(0, ui.KeyBackspace):
		a.jumpBuf = a.jumpBuf[:len(a.jumpBuf)-1]
		return true
	}
	return false
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
	if m.Item("在 Finder 中显示").Chosen() {
		a.revealPath(wall)
	}
	if src != "" && m.Item("在 Finder 中显示原图").Chosen() {
		a.revealPath(src)
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

// openPreviewOf 打开某张壁纸的大图；预览可以翻看壁纸文件夹里的全部图片，不只是缩略图里那几张。
func (a *app) openPreviewOf(wall string) {
	if i := slices.Index(a.walls.all, wall); i >= 0 {
		a.preview, a.previewIdx = true, i
	}
}

// pumpPreview 在后台解码预览要用的大图：先当前这张，再预取下一张、上一张、下下张，同一时间只解一张。
// 按住空格连续翻时，翻过去的不会再解（以前每翻一张就开一个解码，十几张几千万像素的图同时解，内存一下冲上去）；
// 顺着翻时下一张已经提前解好，翻过去直接是清楚的大图。离当前太远的大图丢掉，只留前后几张。
func (a *app) pumpPreview() {
	all := a.walls.all
	if !a.preview || a.update == nil || len(all) == 0 {
		return
	}
	keep := map[string]bool{}
	var todo []string
	for _, d := range []int{0, 1, -1, 2} {
		p := all[(a.previewIdx+d+len(all))%len(all)]
		keep[p] = true
		if _, done := a.big[p]; !done && !slices.Contains(todo, p) {
			todo = append(todo, p)
		}
	}
	for p := range a.big {
		if !keep[p] {
			delete(a.big, p)
		}
	}
	if a.bigBusy || len(todo) == 0 {
		return
	}
	p := todo[0]
	a.bigBusy = true
	go func() {
		img := loadScaled(p, previewWidth)
		a.update(func() {
			a.bigBusy = false
			if !a.preview {
				return // 预览已经关了，不留
			}
			if a.big == nil {
				a.big = map[string]*ui.Bitmap{}
			}
			a.big[p] = nil
			if img != nil {
				a.big[p] = ui.NewBitmap(img)
			}
		})
	}()
}

// previewBitmap 是预览要显示的图：大图解码好了用大图，否则先用缩略图顶着，都没有返回 nil。
func (a *app) previewBitmap(wall string) *ui.Bitmap {
	if bmp := a.big[wall]; bmp != nil {
		return bmp
	}
	if bmp := a.walls.thumbs[wall]; bmp != nil {
		return bmp
	}
	if wall != "" && wall == a.walls.heroPath {
		return a.walls.hero
	}
	return nil
}

// wheelStep 让鼠标滚轮 / 触控板在预览里翻页：往下（或往右）是下一张。
// 滚轮一格翻一张；触控板的小位移攒够 wheelPage 才翻，手指离开后的惯性滚动不算，免得一下翻过好几张。
func (a *app) wheelStep(ev ui.InputEvent, step func(int)) bool {
	if ev.Kind != ui.InputScroll {
		return false
	}
	d := ev.DY
	if abs32(ev.DX) > abs32(d) {
		d = ev.DX
	}
	switch {
	case ev.Momentum:
	case !ev.Precise:
		if d != 0 {
			step(sign32(d))
		}
	default:
		// 停顿一会儿再滑算新的一下：上一下没攒够的不留到这一下
		if ev.Time.Sub(a.wheelAt) > 300*time.Millisecond {
			a.wheelAcc = 0
		}
		a.wheelAt = ev.Time
		a.wheelAcc += d
		if abs32(a.wheelAcc) >= wheelPage {
			step(sign32(a.wheelAcc))
			a.wheelAcc = 0
		}
	}
	return true // 预览里没有要滚动的东西，滚动都在这里接住
}

const (
	wheelPage     = 60 // 触控板滑多远（DIP）翻一张
	previewMargin = 48 // 预览弹层离窗口边缘至少这么远
)

func abs32(x float32) float32 { return max(x, -x) }

func sign32(x float32) int {
	if x < 0 {
		return -1
	}
	return 1
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
		a.pumpPreview()
	} else {
		a.jumpBuf, a.wheelAcc = "", 0
		a.big = nil // 关掉预览就把大图都放掉（每张几十 MB）
	}
	vw, vh := c.Size()
	wasOpen := a.preview
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
		// 图片框和图片同比例；弹层四周留 previewMargin（别压到红绿灯），窗口越大图越大，全屏时也铺得开。
		// 下面的文字和按钮约占 190，左右内边距 40
		boxW, boxH := fitBox(iw, ih, vw-2*previewMargin-40, vh-2*previewMargin-190)
		ui.Column(c).Width(min(max(boxW+40, 760), vw-2*previewMargin)).Gap(14).Padding(20).AlignItems(ui.Center).
			HandleInput(func(ev ui.InputEvent) bool { return a.wheelStep(ev, step) }).Children(func() {
			// 焦点放在图片上而不是第一个按钮上：按钮有焦点时空格 / 回车会按下它，翻页的空格就不灵了
			box := ui.Box(c).Size(boxW, boxH).Radius(10).Clip().Label("预览图片").Focusable().FocusRing(false).AutoFocus()
			if bmp == nil {
				msg := "正在载入…"
				if _, tried := a.big[wall]; tried {
					msg = "读不了这张图"
				}
				box.Background(hairline(t)).Center().Children(func() {
					ui.Text(c, msg).FontSize(12).TextColor(t.TextMuted)
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
				if a.jumpBuf != "" {
					ui.Text(c, fmt.Sprintf("跳到第 %s 张 ↩", a.jumpBuf)).FontSize(12).Bold().TextColor(t.Accent).
						Tooltip("回车跳过去，⌫ 删一位，Esc 放弃")
				} else {
					ui.Text(c, fmt.Sprintf("%d / %d", a.previewIdx+1, len(w.all))).FontSize(12).TextColor(t.TextMuted).
						Tooltip("直接输入编号再按回车可以跳到那一张")
				}
				iconOnly(c, iconChevronLeft, "上一张", withKey("上一张", a.keyLabel("prev"))+"，⇧空格也行").OnClick(func() { step(-1) })
				iconOnly(c, iconChevronRight, "下一张", withKey("下一张", a.keyLabel("next"))+"，空格也行").OnClick(func() { step(1) })
			})

			ui.Box(c).AlignSelf(ui.Stretch).Height(1).Background(hairline(t))
			ui.Row(c).AlignSelf(ui.Stretch).Gap(8).AlignItems(ui.Center).Wrap().Children(func() {
				keyButton(c, nil, "打开", a.keyLabel("open")).Tooltip(withKey("用默认应用打开", a.keyLabel("open"))).OnClick(func() { a.openPath(wall) })
				keyButton(c, nil, "显示壁纸", a.keyLabel("reveal_wall")).Tooltip(withKey("在 Finder 中显示这张壁纸（在壁纸文件夹里选中它）", a.keyLabel("reveal_wall"))).OnClick(func() { a.revealPath(wall) })
				if src != "" {
					keyButton(c, nil, "显示原图", a.keyLabel("reveal")).Tooltip(withKey("在 Finder 中显示原图（在图库里选中它）", a.keyLabel("reveal"))).OnClick(func() { a.revealPath(src) })
				}
				ui.Spacer(c)
				keyButton(c, nil, actRemove, a.keyLabel("remove")).Tooltip(actRemoveTip).OnClick(func() { a.removeWallpaper(wall, false) })
				if src != "" {
					keyButton(c, nil, actExclude, a.keyLabel("exclude")).Tooltip(actExcludeTip).OnClick(func() { a.removeWallpaper(wall, true) })
					keyButton(c, nil, actDelete, a.keyLabel("delete")).TextColor(t.Danger).Tooltip(actDeleteTip).OnClick(func() { a.askDeleteOriginal(wall) })
				}
			})
			// 只留一句最要紧的；完整说明和键盘用法放在 ⓘ 的提示里（按钮上已经标了快捷键）
			note := "移出不动原图，可以 ⌘Z 撤销；只有「删除图库里的原图」会删掉原图，不可撤销。"
			if src == "" {
				note = "这张是之前的版本换上的，找不到对应的原图，只能移出（⌘Z 可以撤销）。"
			}
			ui.Row(c).AlignSelf(ui.Stretch).Gap(6).AlignItems(ui.Center).Children(func() {
				muted(c, note).Grow(1).Shrink(1).MinWidth(0)
				ui.Icon(c, iconInfo).FontSize(13).TextColor(t.TextMuted).Label("键盘用法").Tooltip(
					"「移出」只删壁纸文件夹里的这一份，图库里的原图不动；「不再选它」还会让以后的采样跳过它。\n" + a.previewKeyHint())
			})
		})
	}).Label("壁纸预览")
	// 正在输入编号时按 Esc：弹层自己的 Esc 先于里面的快捷键生效，会把预览关掉；这里改成只放弃编号
	if wasOpen && !a.preview && a.jumpBuf != "" {
		a.preview, a.jumpBuf = true, ""
	}

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
	return hint + "输入编号按回车跳转，⌘Z 撤销移出，Esc 关闭。"
}
