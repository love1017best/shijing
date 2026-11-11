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

	mygo.App.WhenReady(func() {
		var win *mygo.Window
		// 每次回主线程改完状态都把快照发布给手机遥控（窗口隐藏时 view 不一定会重画）
		a.update = func(fn func()) {
			win.Update(func() {
				fn()
				a.publishRemote()
			})
		}
		a.remote.host = computerName()
		a.remote.advertise = advertiseBonjour
		// 定时自动换壁纸：每分钟回主线程检查一次（关窗只是隐藏，应用仍在运行）
		go func() {
			for now := range time.Tick(time.Minute) {
				a.update(func() { a.maybeAutoRun(now) })
			}
		}()
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
		a.showWindow = func() { win.Show() }
		setupBackground(a, win)
		setupMenu(a, win)
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}
