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
			Click: func(*mygo.MenuItem, *mygo.Window) { a.update(a.trayRun) }})
	}
	if len(a.cfg.Profiles) > 0 {
		items = append(items, a.trayProfilesMenu())
	}
	items = append(items,
		&mygo.MenuItem{Label: "打开壁纸文件夹", Disabled: strings.TrimSpace(a.cfg.DestDir) == "",
			Click: func(*mygo.MenuItem, *mygo.Window) { a.openWallpapers() }},
		mygo.Separator(),
		&mygo.MenuItem{Label: "退出拾景", Role: mygo.RoleQuit},
	)
	return items
}

// trayProfilesMenu 构建菜单栏里的「配置方案」子菜单：点方案直接切换并换一批，底部二级菜单可仅切换。
func (a *app) trayProfilesMenu() *mygo.MenuItem {
	sub := make([]*mygo.MenuItem, 0, len(a.cfg.Profiles)+3)
	sub = append(sub, &mygo.MenuItem{Label: "切换并换一批", Disabled: true})
	only := make([]*mygo.MenuItem, 0, len(a.cfg.Profiles))
	for _, p := range a.cfg.Profiles {
		name := p.Name
		active := name == a.cfg.ActiveProfile
		summary := profileSummary(p)
		sub = append(sub, &mygo.MenuItem{
			Type:     mygo.MenuItemCheckbox,
			Label:    name,
			Subtitle: summary,
			Checked:  active,
			Disabled: a.running,
			Click: func(*mygo.MenuItem, *mygo.Window) {
				a.update(func() { a.switchProfileAndRun(name, true) })
			},
		})
		only = append(only, &mygo.MenuItem{
			Type:     mygo.MenuItemCheckbox,
			Label:    name,
			Subtitle: summary,
			Checked:  active,
			Disabled: a.running,
			Click: func(*mygo.MenuItem, *mygo.Window) {
				a.update(func() { _ = a.applyProfile(name) })
			},
		})
	}
	sub = append(sub, mygo.Separator(), &mygo.MenuItem{
		Label:    "仅切换方案",
		Disabled: a.running,
		Submenu:  only,
	})
	label := "配置方案"
	if a.cfg.ActiveProfile != "" {
		label = "配置方案：" + a.cfg.ActiveProfile
	}
	return &mygo.MenuItem{
		Label:   label,
		Submenu: sub,
	}
}

// trayRun 是菜单栏里的「换一批壁纸」：这次要删原图时先把主界面叫出来（确认框在窗口上），
// 其余情况直接在后台跑，不打开窗口。
func (a *app) trayRun() {
	if a.willDelete() && !a.skipConfirm && a.showWindow != nil {
		a.showWindow()
	}
	a.requestRun()
}

// trayStatus 是菜单里那几行状态：方案（如有）、图库、上次运行 / 正在运行、下次自动换。
func (a *app) trayStatus() []string {
	var out []string
	if a.cfg.ActiveProfile != "" {
		line := "当前方案：" + a.cfg.ActiveProfile
		if a.cfg.ActiveProfileModified() {
			line += "（已修改）"
		}
		out = append(out, line)
	}
	dirs := a.allDirs()
	switch n := a.unmountedCount(); {
	case len(dirs) == 0:
		out = append(out, "图库：未添加目录")
	case n == 0 && a.checkingMounts():
		out = append(out, fmt.Sprintf("图库：%d 个目录 · 正在检查", len(dirs)))
	case n == 0:
		out = append(out, fmt.Sprintf("图库：%d 个目录已连接", len(dirs)))
	case n == len(dirs):
		out = append(out, "图库：目录均未连接")
	default:
		out = append(out, fmt.Sprintf("图库：%d 个目录未连接", n))
	}
	switch r := a.last; {
	case a.running:
		out = append(out, "正在更换壁纸 · "+a.progressLabel())
	case r == nil:
		out = append(out, "上次运行：尚未运行")
	case errors.Is(r.err, core.ErrCanceled):
		out = append(out, "上次运行：已停止 · "+r.at.Format("1月2日 15:04"))
	case r.err != nil:
		out = append(out, "上次运行：失败 · "+r.at.Format("1月2日 15:04"))
	default:
		out = append(out, fmt.Sprintf("上次运行：已更换 %d 张 · %s", r.sum.Copy.Copied, r.at.Format("1月2日 15:04")))
	}
	if next := a.nextAutoRun(); !next.IsZero() {
		out = append(out, "下次自动换："+next.Format("1月2日 15:04"))
	}
	return out
}

// trayIcon 是菜单栏图标：和应用图标同一个画面——太阳挂在两座山之间的天上，
// 画成黑色 + 透明的模板图，菜单栏深浅由系统染色。
// 太阳和山脊之间留了缝，缩到 16pt 也不会糊成一团。
func trayIcon() ([]byte, error) {
	s := ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 20"><circle cx="12.2" cy="5.2" r="3.4" fill="currentColor"/><path fill="currentColor" d="M.6 19 6.6 6.4 12 17.4 17.2 5 23.4 19z"/></svg>`))
	img := s.Image(48, 40, color.NRGBA{A: 255}) // 48×40 像素 = 21.6×18 pt，Retina 下也够清晰
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
