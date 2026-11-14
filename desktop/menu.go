package main

import "github.com/egoist/mygo"

// setupMenu 装上菜单栏：常用操作都有快捷键。点菜单项时窗口可能是隐藏的（关窗后台运行），
// 先把窗口叫出来再操作。
func setupMenu(a *app, win *mygo.Window) {
	do := func(fn func()) func(*mygo.MenuItem, *mygo.Window) {
		return func(*mygo.MenuItem, *mygo.Window) {
			a.showMain(win)
			a.update(fn)
		}
	}
	page := func(label, key, id string) *mygo.MenuItem {
		return &mygo.MenuItem{Label: label, Accelerator: "Cmd+" + key, Click: do(func() { a.page = id })}
	}
	// 这三项的快捷键可以在「快捷键」页改（keyActions 里 menu 为 true 的），改了由 a.setMenuKeys 同步
	run := &mygo.MenuItem{Label: "换一批壁纸", Accelerator: a.accel("run"), Click: do(func() {
		a.page = pageOverview
		a.requestRun()
	})}
	stop := &mygo.MenuItem{Label: "停止", Accelerator: a.accel("stop"), Click: do(a.stopRun)}
	openDest := &mygo.MenuItem{Label: "打开壁纸文件夹", Accelerator: a.accel("open_dest"), Click: do(a.openWallpapers)}
	items := map[string]*mygo.MenuItem{"run": run, "stop": stop, "open_dest": openDest}
	a.setMenuKeys = func(keys map[string]string) {
		for id, acc := range keys {
			if it := items[id]; it != nil && it.Accelerator != acc {
				it.SetAccelerator(acc)
			}
		}
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
			run,
			stop,
			mygo.Separator(),
			openDest,
		}},
		{Label: "显示", Submenu: []*mygo.MenuItem{
			page("概览", "1", pageOverview),
			{Label: "壁纸", Click: do(func() { a.page = pageWalls })},
			page("图库", "2", pageLibrary),
			page("设置", "3", pageSettings),
			page("删除记录", "4", pageDeleted),
			page("快捷键", "5", pageKeys),
		}},
		{Role: mygo.RoleWindowMenu},
	}))
}
