package main

import (
	"bytes"
	"errors"
	"fmt"
	"image/color"
	"image/png"
	"strings"

	"desktop/core"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// setupTray 在菜单栏放一个图标。关窗后 Dock 图标会隐藏，应用只留在菜单栏里：
// 从这里的菜单打开主界面、换一批、看状态，或者退出。
// 不设常驻菜单，每次点开时现建一份，状态永远是最新的（运行中、挂载变化都不用另外同步）。
func setupTray(a *app) {
	icon, err := trayIcon()
	if err != nil {
		return // 画不出图标不影响应用其它部分
	}
	tray, err := mygo.NewTray(mygo.TrayOptions{
		ID:             "main",
		Icon:           icon,
		IconIsTemplate: true, // 黑色 + 透明，系统按菜单栏的深浅自己染色
		ToolTip:        appName,
	})
	if err != nil {
		return
	}
	// 左键、右键都弹菜单。菜单只在弹出的这一会儿挂上，弹完撤掉，下次点击才会现算状态。
	pop := func() {
		tray.SetMenu(mygo.NewMenu(a.trayItems()))
		defer tray.SetMenu(nil)
		tray.PopUpMenu()
	}
	tray.OnClick(pop)
	tray.OnRightClick(pop)
	mygo.App.OnWillQuit(func(*mygo.QuitEvent) { tray.Destroy() })
}

// trayItems 是菜单栏图标的菜单：打开主界面、当前状态、换一批 / 停止、打开壁纸文件夹、退出。
func (a *app) trayItems() []*mygo.MenuItem {
	items := []*mygo.MenuItem{{
		Label: "打开主界面",
		Click: func(*mygo.MenuItem, *mygo.Window) {
			if a.showWindow != nil {
				a.showWindow()
			}
		},
	}}
	items = append(items, mygo.Separator())
	for _, line := range a.trayStatus() {
		items = append(items, &mygo.MenuItem{Label: line, Disabled: true})
	}
	items = append(items, mygo.Separator())
	if a.running {
		items = append(items, &mygo.MenuItem{Label: "停止", Click: func(*mygo.MenuItem, *mygo.Window) {
			a.update(a.stopRun)
		}})
	} else {
		items = append(items, &mygo.MenuItem{Label: "换一批壁纸", Disabled: !a.canRun(),
			Click: func(*mygo.MenuItem, *mygo.Window) { a.trayRun() }})
	}
	items = append(items,
		&mygo.MenuItem{Label: "打开壁纸文件夹", Disabled: strings.TrimSpace(a.cfg.DestDir) == "",
			Click: func(*mygo.MenuItem, *mygo.Window) { a.openWallpapers() }},
		mygo.Separator(),
		&mygo.MenuItem{Label: "退出拾景", Role: mygo.RoleQuit},
	)
	return items
}

// trayRun 是菜单栏里的「换一批壁纸」：这次要删原图时先把主界面叫出来（确认框在窗口上），
// 其余情况直接在后台跑，不打开窗口。
func (a *app) trayRun() {
	if a.willDelete() && !a.skipConfirm && a.showWindow != nil {
		a.showWindow()
	}
	a.requestRun()
}

// trayStatus 是菜单里那几行状态：图库、上次运行 / 正在运行、下次自动换。
func (a *app) trayStatus() []string {
	var out []string
	dirs := a.allDirs()
	switch n := a.unmountedCount(); {
	case len(dirs) == 0:
		out = append(out, "图库：还没有添加目录")
	case n == 0 && a.checkingMounts():
		out = append(out, fmt.Sprintf("图库：%d 个目录 · 正在检查", len(dirs)))
	case n == 0:
		out = append(out, fmt.Sprintf("图库：%d 个目录都连着", len(dirs)))
	case n == len(dirs):
		out = append(out, "图库：目录都没连上")
	default:
		out = append(out, fmt.Sprintf("图库：%d 个目录没连上", n))
	}
	switch r := a.last; {
	case a.running:
		out = append(out, "正在换壁纸 · "+a.progressLabel())
	case r == nil:
		out = append(out, "上次运行：还没有运行过")
	case errors.Is(r.err, core.ErrCanceled):
		out = append(out, "上次运行：已停止 · "+r.at.Format("1月2日 15:04"))
	case r.err != nil:
		out = append(out, "上次运行：失败 · "+r.at.Format("1月2日 15:04"))
	default:
		out = append(out, fmt.Sprintf("上次运行：换上 %d 张 · %s", r.sum.Copy.Copied, r.at.Format("1月2日 15:04")))
	}
	if next := a.nextAutoRun(); !next.IsZero() {
		out = append(out, "下次自动换："+next.Format("1月2日 15:04"))
	}
	return out
}

// trayIcon 是菜单栏图标：界面上同一套 Lucide「图片」图标，画成黑色 + 透明的模板图。
func trayIcon() ([]byte, error) {
	s := ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/></svg>`))
	img := s.Image(32, 32, color.NRGBA{A: 255}) // 32 像素 = 16 pt 的 Retina 图
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
