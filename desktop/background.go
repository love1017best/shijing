package main

import (
	"errors"
	"fmt"

	"desktop/core"

	"github.com/egoist/mygo"
)

// setupBackground 让窗口关闭后应用继续在后台运行（macOS 菜单栏应用的习惯）：
//   - 红色关闭按钮 / ⌘W 只隐藏窗口，Dock 图标一起隐藏，应用只留在菜单栏里；
//     界面状态和正在跑的任务都保留（菜单栏图标见 tray.go）；
//   - 从菜单栏「打开主界面」或 Dock 图标恢复窗口和 Dock 图标；
//   - Cmd+Q / 菜单退出才真正退出，任务进行中会先确认；
//   - 运行中 Dock 角标显示「…」，窗口隐藏期间跑完会跳一下 Dock 图标，
//     并发一条系统通知（点通知回到窗口）。
//
// 所有监听器都在主线程执行，和 view 读写 a.running 不会冲突。
func setupBackground(a *app, win *mygo.Window) {
	quitting := false      // 已确认退出：放行窗口关闭
	confirmedQuit := false // 任务进行中，用户已在对话框里确认退出

	win.OnClose(func(e *mygo.CloseEvent) {
		if quitting {
			return
		}
		e.PreventDefault()
		a.hideMain(win)
	})

	mygo.App.OnActivate(func(hasVisibleWindows bool) {
		if !hasVisibleWindows {
			a.showMain(win)
		}
	})
	win.OnShow(func() {
		if !a.running {
			mygo.App.Dock.SetBadge("")
		}
	})

	mygo.App.OnBeforeQuit(func(e *mygo.QuitEvent) {
		if a.running && !confirmedQuit {
			e.PreventDefault()
			a.showMain(win)
			go func() {
				res, err := mygo.Dialog.Message(mygo.MessageOptions{
					Parent:             win,
					Type:               mygo.MessageWarning,
					Message:            "任务还在运行，确定要退出吗？",
					Detail:             "退出会中断正在进行的筛选或复制，壁纸目录可能只换了一部分。",
					Buttons:            []string{"继续运行", "退出"},
					DefaultButton:      0,
					CancelButton:       0,
					DestructiveButtons: []int{1},
				})
				if err == nil && res.Button == 1 {
					win.Update(func() {
						confirmedQuit = true
						mygo.App.Quit()
					})
				}
			}()
			return
		}
		quitting = true
		a.remote.stop() // 结束 Bonjour 广播（dns-sd 子进程）
	})

	a.onRunState = func(running bool, err error) {
		switch {
		case running:
			mygo.App.Dock.SetBadge("…")
		case win.IsVisible():
			mygo.App.Dock.SetBadge("")
		default:
			if err != nil {
				mygo.App.Dock.SetBadge("!")
			} else {
				mygo.App.Dock.SetBadge("✓")
			}
			mygo.App.Dock.Bounce(false)
			if title, body := a.runNotice(); title != "" && mygo.NotificationsSupported() {
				n := mygo.NewNotification(mygo.NotificationOptions{ID: "run-done", Title: title, Body: body})
				n.OnClick(func() { a.showMain(win) })
				go func() { _ = n.Show() }() // 第一次会请求通知权限，可能阻塞
			}
		}
	}
}

// hideMain 是关窗后台运行：隐藏窗口，Dock 图标也收起来，只留菜单栏的图标。
func (a *app) hideMain(win *mygo.Window) {
	win.Hide()
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyAccessory)
}

// showMain 叫出主界面：把 Dock 图标和菜单栏的应用菜单恢复回来，窗口显示并切到前台。
func (a *app) showMain(win *mygo.Window) {
	mygo.App.SetActivationPolicy(mygo.ActivationPolicyRegular)
	win.Show()
	mygo.App.Focus()
}

// runNotice 是窗口隐藏期间跑完时的通知文字。
func (a *app) runNotice() (title, body string) {
	r := a.last
	switch {
	case r == nil:
		return "", ""
	case r.err == nil:
		return fmt.Sprintf("已换上 %d 张新壁纸", r.sum.Copy.Copied), fmt.Sprintf("用时 %.0f 秒", r.sum.Elapsed.Seconds())
	case errors.Is(r.err, core.ErrCanceled):
		return "已停止", ""
	default:
		return "这次没有换成", r.err.Error()
	}
}
