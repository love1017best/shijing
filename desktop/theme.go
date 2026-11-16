package main

import (
	"github.com/egoist/mygo/ui"
)

// 强调色是橙色（用户喜欢，v0.3.11 起；iOS 的 AccentColor 要保持一致）。横幅插画的日落色取自应用图标
// （v0.3.12 起图标也是橙色，由 scripts/recolor_icon.py 从原来的紫色图标换算，这几个颜色用的是同一套换算）。
var (
	sunGlow   = ui.Hex("#FDE7B8")
	duskTop   = ui.Hex("#963711")
	duskMid   = ui.Hex("#C0571F")
	duskHill  = ui.Hex("#CC742F")
	duskFront = ui.Hex("#813714")
)

const (
	sidebarWidth   = 216
	titleBarHeight = 52   // 隐藏标题栏后，红绿灯按钮占的那一条
	contentMax     = 860  // 单栏页面的最大宽度：表单再宽就不好读了
	twoColMin      = 1040 // 内容区宽度到这里时，设置类页面改成左右两栏（每栏约 500）
	twoColMax      = 1360 // 两栏时的最大宽度
)

// applyTheme 在系统明暗主题的基础上换上品牌色，并统一圆角。
func applyTheme(c *ui.Context) *ui.Theme {
	t := *c.Theme()
	if t.Dark {
		// #E56900：深色底上对比度约 5:1，白字约 3.3:1（按钮文字是粗体，够用）
		t.Accent = ui.Oklch(0.66, 0.18, 50)
		t.AccentHover = ui.Oklch(0.71, 0.17, 52)
		t.AccentPressed = ui.Oklch(0.61, 0.18, 48)
	} else {
		// #E45C00：白字约 3.6:1；再浅就发黄、白字看不清
		t.Accent = ui.Oklch(0.64, 0.19, 47)
		t.AccentHover = ui.Oklch(0.60, 0.19, 46)
		t.AccentPressed = ui.Oklch(0.56, 0.18, 45)
	}
	t.AccentText = ui.RGB(255, 255, 255)
	t.Focus = t.Accent.Alpha(0.5)
	t.Selection = t.Accent.Alpha(0.25)
	t.Radius = 7
	c.SetTheme(&t)
	return c.Theme()
}

// panelBg 是卡片的底色：浅色模式下是白底（页面是浅灰），深色模式下比页面略亮。
func panelBg(t *ui.Theme) ui.Color {
	if t.Dark {
		return ui.RGBA(255, 255, 255, 0.045)
	}
	return ui.RGB(255, 255, 255)
}

// pageBg 是内容区的底色：浅色模式用很浅的灰，让白色卡片浮起来。
func pageBg(t *ui.Theme) ui.Color {
	if t.Dark {
		return t.Background
	}
	return ui.Hex("#F6F6F8")
}

// hairline 是卡片描边和行之间的分隔线。
func hairline(t *ui.Theme) ui.Color {
	if t.Dark {
		return ui.RGBA(255, 255, 255, 0.08)
	}
	return ui.RGBA(0, 0, 0, 0.08)
}

func muted(c *ui.Context, s string) ui.Element {
	return ui.Text(c, s).TextColor(c.Theme().TextMuted).FontSize(12).Wrap()
}

// pageHeader 是每页顶部的大标题；trailing 放在右侧（按钮等）。
func pageHeader(c *ui.Context, title, subtitle string, trailing func()) {
	ui.Row(c).Gap(12).AlignItems(ui.End).Padding(0, 0, 4, 0).Children(func() {
		ui.Column(c).Grow(1).Gap(4).Children(func() {
			ui.Text(c, title).FontSize(26).Bold()
			if subtitle != "" {
				ui.Text(c, subtitle).FontSize(13).TextColor(c.Theme().TextMuted).Wrap()
			}
		})
		if trailing != nil {
			trailing()
		}
	})
}

// panel 是白底圆角卡片（带极淡的阴影和描边）。
func panel(c *ui.Context) ui.Element {
	t := c.Theme()
	p := ui.Column(c).Radius(12).Background(panelBg(t)).Border(1, hairline(t))
	if !t.Dark {
		p.Shadow(0, 1, 2, 0, ui.RGBA(20, 16, 60, 0.04))
	}
	return p
}

// group 是 macOS 系统设置风格的一组设置：标题在卡片外，卡片里一行一项、细线分隔。
// rows 里每个函数画一行。
// helpDot 是设置项旁边的小问号：指针悬停、键盘聚焦时浮现说明，界面上不再铺一段说明文字。
func helpDot(c *ui.Context, title, desc string) ui.Element {
	t := c.Theme()
	d := ui.Box(c).Size(16, 16).Radius(8).Center().
		Label("「" + title + "」的说明").Role(ui.RoleButton).Focusable().
		Cursor(ui.CursorPointer).Tooltip(desc)
	return d.Children(func() {
		ui.Icon(c, iconHelp).FontSize(13).TextColor(t.TextMuted)
	})
}

// group 是一个设置分组：标题、白底卡片、每行之间一条分隔线。
// footnote 放在标题旁边的小问号里，不占页面高度。
func group(c *ui.Context, title, footnote string, rows ...func()) {
	t := c.Theme()
	ui.Column(c).Gap(8).Children(func() {
		if title != "" {
			ui.Row(c).Gap(6).AlignItems(ui.Center).Padding(0, 4).Children(func() {
				ui.Text(c, title).FontSize(13).Bold().TextColor(t.TextMuted)
				if footnote != "" {
					helpDot(c, title, footnote)
				}
			})
		}
		panel(c).Children(func() {
			for i, row := range rows {
				if i > 0 {
					ui.Box(c).Height(1).Background(hairline(t)).Margin(0, 16)
				}
				row()
			}
		})
	})
}

// settingRow 是一行设置：左边名称（说明收进旁边的小问号）和控件。返回名称文字，方便控件 LabelledBy。
func settingRow(c *ui.Context, title, desc string, control func(label ui.Element)) {
	settingRowNote(c, title, desc, "", control)
}

// settingRowNote 和 settingRow 一样，note 是始终显示的一行小字，只放当下状态（如端口号、下次运行时间），不放功能说明。
func settingRowNote(c *ui.Context, title, desc, note string, control func(label ui.Element)) {
	settingRowNoteColor(c, title, desc, note, c.Theme().TextMuted, control)
}

// settingRowNoteColor 和 settingRowNote 一样，note 用指定颜色（录制快捷键被拒绝之类的提示要显眼）。
func settingRowNoteColor(c *ui.Context, title, desc, note string, color ui.Color, control func(label ui.Element)) {
	ui.Row(c).Gap(20).AlignItems(ui.Center).Padding(13, 16).Children(func() {
		var label ui.Element
		ui.Column(c).Grow(1).Shrink(1).Gap(3).MinWidth(0).Children(func() {
			ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
				label = ui.Text(c, title).FontSize(13.5)
				if desc != "" {
					helpDot(c, title, desc)
				}
			})
			if note != "" {
				ui.Text(c, note).TextColor(color).FontSize(12).Wrap()
			}
		})
		ui.Row(c).Shrink(0).AlignItems(ui.Center).Gap(8).Children(func() { control(label) })
	})
}

// wideRow 是控件需要整行宽度的设置（路径输入框等）：名称在上，控件在下。
func wideRow(c *ui.Context, title, desc string, control func()) {
	ui.Column(c).Gap(8).Padding(13, 16).Children(func() {
		ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
			ui.Text(c, title).FontSize(13.5)
			if desc != "" {
				helpDot(c, title, desc)
			}
		})
		control()
	})
}

// pill 是带底色的小标签，用来显示状态。
func pill(c *ui.Context, text string, color ui.Color) ui.Element {
	return ui.Text(c, text).FontSize(11).Bold().TextColor(color).SingleLine().
		Padding(2, 8).Radius(9).Background(color.Alpha(0.14))
}

func iconButton(c *ui.Context, icon *ui.SVG, label string, primary bool) ui.Element {
	var b ui.Element
	if primary {
		b = ui.PrimaryButton(c, "")
	} else {
		b = ui.Button(c, "")
	}
	return b.Label(label).Children(func() {
		ui.Icon(c, icon)
		ui.Text(c, label).SingleLine()
	})
}

// sceneArt 是没有壁纸可展示时的横幅：和应用图标同风格的暮色山景。
func sceneArt(c *ui.Context) {
	ui.Box(c).Absolute().Top(0).Left(0).Right(0).Bottom(0).
		LinearGradient(ui.LinearGradient{Angle: 180, Stops: []ui.GradientStop{
			{Color: duskTop, At: 0}, {Color: duskMid, At: 0.55}, {Color: duskHill, At: 1},
		}, Oklab: true})
	ui.Box(c).Absolute().Top(34).Right(150).Size(64, 64).Radius(32).Background(sunGlow).
		Shadow(0, 0, 60, 18, sunGlow.Alpha(0.45))
	ui.Box(c).Absolute().Left(0).Right(0).Bottom(0).Height(110).Draw(func(p *ui.Painter, r ui.Rect) {
		hills := func(color ui.Color, ys ...float32) {
			var path ui.Path
			path.MoveTo(r.X, r.Y+r.H)
			for i, y := range ys {
				path.LineTo(r.X+r.W*float32(i)/float32(len(ys)-1), r.Y+y)
			}
			path.LineTo(r.X+r.W, r.Y+r.H)
			path.Close()
			p.FillPath(&path, color)
		}
		hills(duskHill, 50, 18, 46, 6, 40, 22)
		hills(duskMid, 70, 52, 74, 40, 66, 58)
		hills(duskFront, 92, 84, 98, 80, 94, 88)
	})
}
