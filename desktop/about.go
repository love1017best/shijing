package main

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/ui"
)

// author 是「关于」页上的作者。
const author = "@love1017best"

// versionLabel 是显示用的版本号：打包后是 vX.Y.Z，开发运行时没有版本号。
func (a *app) versionLabel() string {
	if a.version == "" {
		return "开发版"
	}
	return "v" + a.version
}

func (a *app) aboutPage(c *ui.Context) {
	t := c.Theme()
	// 顶部：大图标、名字、一句话介绍
	ui.Column(c).AlignItems(ui.Center).Gap(10).Padding(28, 0, 6, 0).Children(func() {
		if aboutIcon != nil {
			ui.Image(c, aboutIcon).Size(96, 96).Label(appName + " 图标")
		}
		ui.Text(c, appName).FontSize(28).Bold()
		muted(c, "从图库里随机拾一批风景，换上 macOS 壁纸。")
		ui.Row(c).Gap(8).Children(func() {
			pill(c, a.versionLabel(), t.Accent)
			pill(c, "作者 "+author, t.TextMuted)
		})
	})

	infoRow := func(icon *ui.SVG, title, value string, trailing func()) func() {
		return func() {
			ui.Row(c).Gap(12).AlignItems(ui.Center).Padding(13, 16).Children(func() {
				ui.Icon(c, icon).FontSize(15).TextColor(t.Accent)
				ui.Text(c, title).FontSize(13.5).Width(72).Shrink(0)
				ui.Text(c, value).FontSize(13.5).TextColor(t.TextMuted).SingleLine().Grow(1).Shrink(1).MinWidth(0).Tooltip(value)
				if trailing != nil {
					trailing()
				}
			})
		}
	}
	dataDir := filepath.Dir(a.cfgPath)
	group(c, "信息", "图标取自 Lucide（ISC 许可）。",
		infoRow(iconUser, "作者", author, nil),
		infoRow(iconTag, "版本", a.versionLabel(), nil),
		infoRow(iconCode, "构建", "Go + MyGo 原生界面", nil),
		infoRow(iconFolder, "数据目录", tildify(dataDir), func() {
			iconButton(c, iconExternal, "在 Finder 中显示", false).Label("数据目录 在 Finder 中显示").
				OnClick(func() { a.openPath(dataDir) })
		}),
	)
}

// tildify 把家目录开头的路径写成 ~/…，和设置里的写法一致，也更短。
func tildify(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return p
	}
	if p == home {
		return "~"
	}
	if rest, ok := strings.CutPrefix(p, home+string(filepath.Separator)); ok {
		return "~/" + rest
	}
	return p
}
