package main

import "github.com/egoist/mygo"

// setupMenu 装上菜单栏：常用操作都有快捷键。点菜单项时窗口可能是隐藏的（关窗后台运行），
// 先把窗口叫出来再操作。
func setupMenu(a *app, win *mygo.Window) {
	do := func(fn func()) func(*mygo.MenuItem, *mygo.Window) {
		return func(*mygo.MenuItem, *mygo.Window) {
			win.Show()
			a.update(fn)
		}
	}
	page := func(label, key, id string) *mygo.MenuItem {
		return &mygo.MenuItem{Label: label, Accelerator: "Cmd+" + key, Click: do(func() { a.page = id })}
	}
	mygo.App.SetMenu(mygo.NewMenu([]*mygo.MenuItem{
		{Label: appName, Submenu: []*mygo.MenuItem{
			{Label: "关于" + appName, Click: do(func() { a.page = pageAbout })},
			mygo.Separator(),
			{Label: "设置…", Accelerator: "Cmd+,", Click: do(func() { a.page = pageSettings })},
			mygo.Separator(),
			{Role: mygo.RoleServices},
			mygo.Separator(),
			{Role: mygo.RoleHide},
			{Role: mygo.RoleHideOthers},
			{Role: mygo.RoleUnhide},
			mygo.Separator(),
			{Role: mygo.RoleQuit},
		}},
		// 「文件」菜单里只有「关闭窗口」⌘W：macOS 的 ⌘W 来自这一项，没有它按 ⌘W 什么都不会发生。
		// 关闭走 win.OnClose，被 background.go 改成隐藏窗口（任务继续跑），⌘Q 才退出。
		{Role: mygo.RoleFileMenu},
		{Role: mygo.RoleEditMenu},
		{Label: "壁纸", Submenu: []*mygo.MenuItem{
			{Label: "换一批壁纸", Accelerator: "Cmd+R", Click: do(func() {
				a.page = pageOverview
				a.requestRun()
			})},
			{Label: "停止", Accelerator: "Cmd+.", Click: do(a.stopRun)},
			mygo.Separator(),
			{Label: "打开壁纸文件夹", Accelerator: "Cmd+O", Click: do(a.openWallpapers)},
		}},
		{Label: "显示", Submenu: []*mygo.MenuItem{
			page("概览", "1", pageOverview),
			page("图库", "2", pageLibrary),
			page("设置", "3", pageSettings),
			page("归档", "4", pageArchive),
		}},
		{Role: mygo.RoleWindowMenu},
	}))
}
