// 拾景：从 NAS 图库里随机挑一批图片换上 macOS 壁纸。
// 最初是 Python 版（gui.py / run.py，已不再维护）的 MyGo 移植，筛选/采样/归档逻辑在 core 包里。
package main

import (
	"log"
	"path/filepath"
	"time"

	"desktop/core"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// appName 与 mygo.json 的 name 保持一致：配置、增量状态和删除日志放在
// ~/Library/Application Support/<appName>/ 下。
const appName = "拾景"

// oldAppName 是改名前的数据目录名，第一次启动时自动搬过来。
const oldAppName = "壁纸工具"

func main() {
	dataDir, err := core.DataDir(appName)
	if err != nil {
		log.Fatal(err)
	}
	if oldDir, err := core.DataDir(oldAppName); err == nil {
		if _, err := core.MigrateDataDir(oldDir, dataDir); err != nil {
			log.Printf("迁移旧数据目录失败: %v", err)
		}
	}
	a := newApp(filepath.Join(dataDir, "config.json"), core.PathsIn(dataDir))
	thumbCacheDir = filepath.Join(dataDir, "thumbs") // 缩略图缓存（thumbcache.go）
	a.clearUndo()                                    // 上次打开时暂存的移出不再撤销
	a.loadPending()                                  // 上次图库没连上时排队的删除原图

	mygo.App.WhenReady(func() {
		var win *mygo.Window
		// 每次回主线程改完状态都提交（同步派生状态、按需落盘并发布快照给手机遥控，窗口隐藏时 view 不一定会重画）；
		// 若 fn 内已显式调用 commitState（例如 remote.onMain 响应前先提交），此处不再重复执行。
		a.update = func(fn func()) {
			win.Update(func() {
				a.committed = false
				fn()
				if !a.committed {
					a.commitState()
				}
			})
		}
		a.remote.host = computerName()
		a.remote.advertise = advertiseBonjour
		a.version = mygo.App.Version()
		a.pickDir = func(title string) string {
			paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{
				Parent: win, Title: title, Message: title,
				Directory: true, CreateDirectories: true,
			})
			if err != nil || len(paths) == 0 {
				return ""
			}
			return paths[0]
		}
		a.pickFile = func(title string) string {
			paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{
				Parent: win, Title: title, Message: title,
				Filters: []mygo.FileFilter{{Name: "JSON", Extensions: []string{"json"}}},
			})
			if err != nil || len(paths) == 0 {
				return ""
			}
			return paths[0]
		}
		a.showErr = func(title, message string) {
			go mygo.Dialog.Error(title, message)
		}
		a.confirmDelete = func(detail string) (bool, bool) {
			res, err := mygo.Dialog.Message(mygo.MessageOptions{
				Parent:             win,
				Type:               mygo.MessageWarning,
				Message:            "这次运行会删除不合格的原图",
				Detail:             detail,
				Buttons:            []string{"取消", "删除并换壁纸"},
				DefaultButton:      1,
				CancelButton:       0,
				DestructiveButtons: []int{1},
				CheckboxLabel:      "不再提示（重新打开「删除不合格原图」后会再次提示）",
			})
			return err == nil && res.Button == 1, err == nil && res.CheckboxChecked
		}
		a.openPath = func(p string) {
			go func() { _ = mygo.Shell.OpenPath(core.ExpandUser(p)) }()
		}
		a.revealPath = func(p string) { mygo.Shell.ShowItemInFolder(core.ExpandUser(p)) }
		win = mygo.NewWindow(mygo.WindowOptions{
			Title:     appName,
			Width:     1040,
			Height:    760,
			MinWidth:  860,
			MinHeight: 600,
			StateKey:  "main",
			// 隐藏标题栏，红绿灯按钮浮在侧边栏上；侧边栏透出 macOS 的毛玻璃材质
			TitleBarStyle:   mygo.TitleBarHiddenInset,
			TitleBarHeight:  titleBarHeight,
			Vibrancy:        mygo.VibrancySidebar,
			BackgroundColor: "light-dark(#f6f6f8, #1e1e1e)",
			Content:         ui.View(a.view),
		})
		a.showWindow = func() { a.showMain(win) }
		stopCh := make(chan struct{})
		a.stopTimers = func() {
			select {
			case <-stopCh:
			default:
				close(stopCh)
			}
		}
		// 定时自动换壁纸：必须在 win 初始化完成后再启动，避免与 win 赋值发生数据竞争。
		// 有待删原图排队时顺手再查一遍图库挂上没、挂上了就执行。
		go func() {
			tk := time.NewTicker(time.Minute)
			defer tk.Stop()
			for {
				select {
				case <-stopCh:
					return
				case now := <-tk.C:
					a.update(func() {
						a.maybeProcessPending()
						if len(a.pending) > 0 {
							a.checkMounts()
						}
						a.maybeAutoRun(now)
					})
				}
			}
		}()
		// 概览横幅轮播：窗口显示着才换（隐藏时不解码、不重画）
		go func(w *mygo.Window) {
			tk := time.NewTicker(heroInterval)
			defer tk.Stop()
			for {
				select {
				case <-stopCh:
					return
				case <-tk.C:
					w.Update(func() {
						if w.IsVisible() {
							a.advanceHero()
						}
					})
				}
			}
		}(win)
		setupBackground(a, win)
		setupMenu(a, win)
		setupTray(a)
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}
