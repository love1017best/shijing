package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

// ── 待删原图（图库没连上时排队，连上后自动执行）──────────────────────────────
//
// 壁纸文件夹在本地，图库（NAS）不在时看图、移出、撤销、不再选都照常能用；
// 只有「删除图库里的原图」需要动网络卷。连不上时不报错，而是把这一条记进待办队列，
// 并且这次连不上的原因也记下来：等图库连上（定时器每分钟检查一次挂载）自动校验、删除。

// loadPending 在启动时读队列（main.go 里调）。
func (a *app) loadPending() { a.pending = core.LoadPending(a.paths.Pending) }

func (a *app) savePending() { _ = core.SavePending(a.paths.Pending, a.pending) }

// sourceUnmounted 判断这张原图所在的图库目录现在是不是连不上。
// 只按配置里的目录前缀和挂载状态判断，不去 stat（网络卷卡住时 stat 会阻塞）。
func (a *app) sourceUnmounted(src string) bool {
	src = filepath.Clean(src)
	for _, d := range a.allDirs() {
		d = strings.TrimRight(filepath.Clean(core.ExpandUser(d)), "/")
		if src != d && !strings.HasPrefix(src, d+"/") {
			continue
		}
		switch a.mounts[d] {
		case mountMissing, mountSlow:
			return true
		}
		return false
	}
	return false
}

// queueDelete 把一张原图记进待办队列，并把壁纸文件夹里的那份移出（可以 ⌘Z 撤销）。
func (a *app) queueDelete(wall, src string) {
	if !slices.ContainsFunc(a.pending, func(e core.PendingDelete) bool { return e.Path == src }) {
		e := core.PendingDelete{Path: src, Wall: filepath.Base(wall), AddedAt: time.Now()}
		// 排队时一般拿不到文件信息，记零值：执行时只确认文件还在，不比对指纹
		if fi, err := os.Stat(src); err == nil {
			e.Size, e.ModTime = fi.Size(), fi.ModTime()
		}
		a.pending = append(a.pending, e)
		a.savePending()
	}
	a.appendLog(fmt.Sprintf("🕓 图库没连上，排队删除原图（连上后自动执行）: %s", src))
	a.removeWallpaper(wall, false)
	a.toast = "图库没连上，已排队：连上后自动删除这张原图（⌘Z 撤销移出，队列在概览页查看）"
}

// maybeProcessPending 尝试执行队列：只在图库目录全都挂上时动手（对着断掉/卡住的卷逐个 stat 会一直卡着），
// 每次执行前重新校验文件还在、大小和修改时间没变。由每分钟的定时器和挂载状态变化触发。
func (a *app) maybeProcessPending() {
	if a.pendingBusy || a.running || len(a.pending) == 0 || a.unmountedCount() > 0 {
		return
	}
	a.pendingBusy = true
	list := slices.Clone(a.pending)
	go func() {
		res := core.RunPending(list, nil) // 已经确认都挂上了，不用再按目录判断
		a.update(func() { a.applyPending(res) })
	}()
}

// applyPending 把一次执行的结果写回队列和删除记录（主线程）。
// 变了的（Stale）不删、也不再自动重试：提示用户自己看过再决定。
func (a *app) applyPending(res core.PendingResult) {
	a.pendingBusy = false
	for _, e := range res.Deleted {
		core.LogDeletion(a.paths.DeleteLog, e.Path, int(a.minW), int(a.minH), core.ReasonManual)
		a.appendLog(fmt.Sprintf("🔥 手动删除原图（排队执行，%s 排队）: %s", e.AddedAt.Format("1月2日 15:04"), e.Path))
	}
	for _, e := range res.Gone {
		a.appendLog(fmt.Sprintf("🕓 排队的原图已经不在了，跳过: %s", e.Path))
	}
	for _, e := range res.Stale {
		a.appendLog(fmt.Sprintf("⚠️ 排队的原图在排队期间被改过，没有删除: %s", e.Path))
	}
	if len(res.Deleted)+len(res.Gone) > 0 {
		a.toast = fmt.Sprintf("图库连上了：删除了 %d 张排队的原图", len(res.Deleted))
	}
	if len(res.Stale) > 0 && len(res.Deleted)+len(res.Gone) == 0 {
		a.toast = fmt.Sprintf("%d 张排队的原图在排队期间被改过，没有删除（见日志）", len(res.Stale))
	}
	a.pending = res.Kept
	a.savePending()
}

// cancelPending 取消队列里的一条（不动已经移出的壁纸）。
func (a *app) cancelPending(i int) {
	if i < 0 || i >= len(a.pending) {
		return
	}
	path := a.pending[i].Path
	a.pending = slices.Delete(a.pending, i, i+1)
	a.savePending()
	a.toast = "已取消排队删除：" + filepath.Base(path)
}

func (a *app) cancelAllPending() {
	n := len(a.pending)
	a.pending = nil
	a.savePending()
	a.toast = fmt.Sprintf("已取消 %d 项排队删除", n)
}

// pendingBar 是概览里队列非空时显示的一条提示，点开可以逐条取消。
// 放在横幅下面单独一条，不挤横幅里那行去向文字。
func (a *app) pendingBar(c *ui.Context) {
	n := len(a.pending)
	if n == 0 {
		return
	}
	amber := ui.Hex("#FFD27A")
	ui.Row(c).AlignSelf(ui.Stretch).Padding(12, 14).Radius(12).Gap(10).AlignItems(ui.Center).
		Background(amber.Alpha(0.12)).Border(1, amber.Alpha(0.35)).Children(func() {
		ui.Icon(c, iconClock).FontSize(14).TextColor(amber)
		ui.Text(c, fmt.Sprintf("%d 项原图等着删除", n)).FontSize(12.5).Bold().TextColor(amber).SingleLine()
		muted(c, "图库连上后自动执行，可以逐条取消").Shrink(1).MinWidth(0)
		ui.Spacer(c)
		ui.Button(c, "查看").OnClick(func() { a.pendingShown = true })
	})
}

// pendingModal 列出队列里的每一条，可以逐条取消或全部取消。
func (a *app) pendingModal(c *ui.Context) {
	if len(a.pending) == 0 {
		a.pendingShown = false
		return
	}
	ui.Modal(c, &a.pendingShown, func() {
		ui.Column(c).Width(520).Gap(12).Padding(20).Children(func() {
			ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
				ui.Icon(c, iconClock).FontSize(16)
				ui.Text(c, "待删除的原图").FontSize(15).Bold()
				ui.Spacer(c)
				ui.Button(c, "全部取消").OnClick(a.cancelAllPending)
			})
			muted(c, "这些是在图库没连上时点「删除原图」的。图库连上后会自动校验并删除，删除会记进删除记录；"+
				"排队期间原图被改过的不会删，只记日志。取消只撤销删除原图，壁纸文件夹里那张已经移出，可以用 ⌘Z 恢复。")
			ui.Column(c).MaxHeight(320).Gap(2).Children(func() {
				list := a.pending
				if len(list) > 8 {
					list = list[:8] // 弹层不滚动：先取消几条，剩下的自然露出来
				}
				for i, e := range list {
					i, e := i, e
					ui.Row(c).Fill().Padding(7, 8).Radius(8).Gap(8).AlignItems(ui.Center).Children(func() {
						ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
							ui.Text(c, filepath.Base(e.Path)).FontSize(12.5).SingleLine()
							muted(c, tildify(filepath.Dir(e.Path))).FontSize(11.5).SingleLine()
						})
						ui.Button(c, "取消").OnClick(func() { a.cancelPending(i) })
					})
				}
				if rest := len(a.pending) - len(list); rest > 0 {
					muted(c, fmt.Sprintf("还有 %d 项…（取消完上面的会接着显示）", rest))
				}
			})
			ui.Row(c).Gap(8).Justify(ui.End).Children(func() {
				ui.Button(c, "关闭").OnClick(func() { a.pendingShown = false })
			})
		})
	}).Label("待删除的原图")
}
