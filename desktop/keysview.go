package main

import (
	"slices"

	"github.com/egoist/mygo/ui"
)

// withKey 在提示文字后面加上快捷键，没有快捷键时原样返回。
func withKey(text, key string) string {
	if key == "" {
		return text
	}
	return text + "（" + key + "）"
}

// keysPage 是「快捷键」页：点右边的按键开始录制，按下新的组合就改好了（自动保存）。
func (a *app) keysPage(c *ui.Context) {
	a.recordKey(c)
	changed := len(a.cfg.Shortcuts) > 0
	pageHeader(c, "快捷键", "点右边的按键，再按下新的组合键就改好了；Esc 取消录制。改动立即生效、自动保存。", func() {
		iconButton(c, iconRotateCcw, "全部恢复默认", false).Disabled(!changed).OnClick(func() {
			a.cfg.Shortcuts = nil
			a.recording, a.keyErr = "", ""
			a.syncMenuKeys()
			a.toast = "快捷键已全部恢复默认"
		})
	})
	var menuRows, previewRows []func()
	for _, act := range keyActions {
		row := func() { a.keyRow(c, act) }
		if act.menu {
			menuRows = append(menuRows, row)
		} else {
			previewRows = append(previewRows, row)
		}
	}
	menuGroup := func() {
		group(c, "全局（菜单栏）", "窗口在前台时任何页面都能用，要带 ⌘ 或 ⌃。", menuRows...)
	}
	previewGroup := func() {
		group(c, "大图预览", "在预览里浏览、整理壁纸时用，可以全程只用键盘。", previewRows...)
	}
	fixedGroup := func() {
		group(c, "固定", "这些不能改，也不能分给别的操作。", func() {
			ui.Column(c).Gap(8).Padding(13, 16).Children(func() {
				for _, f := range [][2]string{
					{"⌘1 – ⌘6", "切换页面"}, {"⌘,", "设置"}, {"⌘W", "关闭窗口（后台继续运行）"}, {"⌘Q", "退出"},
					{"空格", "预览里下一张"}, {"⇧空格", "预览里上一张"}, {"0 – 9 ↩", "预览里输入编号跳转"}, {"⌘Z", "撤销移出"}, {"↩", "确认（比如确认删除原图）"}, {"Esc", "关闭预览 / 取消"},
				} {
					ui.Row(c).Gap(12).AlignItems(ui.Center).Children(func() {
						ui.Text(c, f[1]).FontSize(13).Grow(1)
						keycap(c, f[0])
					})
				}
			})
		})
	}
	// 两栏时左边放全局 + 固定、右边放预览（高度差不多）；单栏时可改的在前、固定的放最后
	if a.twoCol() {
		a.columns(c, 24, func() { menuGroup(); fixedGroup() }, previewGroup)
	} else {
		a.columns(c, 24, func() { menuGroup(); previewGroup() }, fixedGroup)
	}
}

// keyRow 是一行可改的快捷键：名称、录制按钮，改过的话再加一个「恢复默认」。
func (a *app) keyRow(c *ui.Context, act keyAction) {
	t := c.Theme()
	desc := act.desc
	if a.keyErrFor == act.id && a.keyErr != "" {
		desc = a.keyErr
	}
	settingRow(c, act.label, desc, func(ui.Element) {
		_, custom := a.cfg.Shortcuts[act.id]
		if custom {
			reset := ui.Button(c, "").Label(act.label + " 恢复默认").Tooltip("恢复默认（" + defaultLabel(act) + "）").
				Children(func() { ui.Icon(c, iconRotateCcw) })
			if reset.Clicked() {
				a.setShortcut(act.id, act.def)
				a.keyErr = ""
			}
		}
		if a.keyLabel(act.id) != "" {
			clear := ui.Button(c, "").Label(act.label + " 清除").Tooltip("清除（不用快捷键）").
				Children(func() { ui.Icon(c, iconXCircle) })
			if clear.Clicked() {
				a.setShortcut(act.id, "")
				a.keyErr = ""
			}
		}
		recording := a.recording == act.id
		text := a.keyLabel(act.id)
		if recording {
			text = "按下新的快捷键…"
		} else if text == "" {
			text = "未设置"
		}
		b := ui.ButtonBase(c).Label(act.label+" 快捷键").MinWidth(120).Height(28).Padding(0, 12).Radius(7).Center().
			Background(panelBg(t)).Border(1, hairline(t))
		if recording {
			b.Border(1.5, t.Accent).Background(t.Accent.Alpha(0.1))
		} else if b.Hovered() {
			b.Background(t.SurfaceHover)
		}
		b.Children(func() {
			l := ui.Text(c, text).FontSize(12.5).SingleLine()
			if recording {
				l.TextColor(t.Accent)
			} else if a.keyLabel(act.id) == "" {
				l.TextColor(t.TextMuted)
			}
		})
		if b.Clicked() {
			if recording {
				a.stopRecording()
			} else {
				a.recording, a.keyErr, a.recordIgnore = act.id, "", slices.Clone(c.KeysDown())
				a.syncMenuKeys() // 录制期间撤掉菜单快捷键，按 ⌘R 不会真的开始运行
			}
		}
	})
}

func defaultLabel(act keyAction) string {
	if k, ok := parseCombo(act.def); ok {
		return k.Label()
	}
	return "无"
}

// recordKey 在录制时读这一帧按下的键：Esc 取消，其余的检查冲突后分给正在录制的操作。
// 放在页面最前面调用，这一帧录到的键不会再被录制按钮当成点击。
func (a *app) recordKey(c *ui.Context) {
	if a.recording == "" {
		return
	}
	held := c.KeysDown()
	// 开始录制时就按着的键（比如用空格点了录制按钮）松开之后才算
	a.recordIgnore = slices.DeleteFunc(a.recordIgnore, func(k ui.Key) bool { return !slices.Contains(held, k) })
	for _, k := range held {
		if slices.Contains(a.recordIgnore, k) {
			continue
		}
		id := a.recording
		if k == ui.KeyEscape && c.Modifiers() == 0 {
			a.stopRecording()
			return
		}
		if _, _, ok := keyRow(k); !ok {
			continue
		}
		combo := keyCombo{mods: c.Modifiers(), key: k}
		a.recordIgnore = append(a.recordIgnore, k)
		if why := a.checkCombo(id, combo); why != "" {
			a.keyErr, a.keyErrFor = why, id
			a.stopRecording()
			return
		}
		a.stopRecording()
		a.setShortcut(id, combo.String())
		a.keyErr = ""
		return
	}
}

func (a *app) stopRecording() {
	a.recording = ""
	a.syncMenuKeys()
}

// keycap 是一个小按键样式的标签。
func keycap(c *ui.Context, s string) ui.Element {
	t := c.Theme()
	return ui.Text(c, s).FontSize(11.5).TextColor(t.TextMuted).SingleLine().
		Padding(2, 7).Radius(5).Border(1, hairline(t)).Background(panelBg(t))
}
