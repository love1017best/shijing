package main

import (
	"fmt"
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
	src = mountKey(src)
	for _, raw := range a.allDirs() {
		d := mountKey(raw)
		if src != d && !strings.HasPrefix(src, d+"/") {
			continue
		}
		switch a.mountStateOf(raw) {
		case mountMissing, mountSlow:
			return true
		}
		return false
	}
	return false
}

// enqueuePending 仅把原图记进待办队列并写日志，不动壁纸文件夹里的本地文件。
func (a *app) enqueuePending(wall, src string) {
	if !slices.ContainsFunc(a.pending, func(e core.PendingDelete) bool { return e.Path == src }) {
		// 排队时拿不到安全的文件指纹，记零值：执行时只确认文件还在，不比对指纹
		e := core.PendingDelete{Path: src, Wall: filepath.Base(wall), AddedAt: time.Now()}
		a.pending = append(a.pending, e)
		a.savePending()
	}
	if a.pendingBusy {
		a.pendingMu.Lock()
		delete(a.pendingCanceled, src)
		a.pendingMu.Unlock()
	}
	a.appendLog(fmt.Sprintf("🕓 图库未连接，原图删除已排队（连接后自动执行）: %s", src))
}

// queueDelete 把一张原图记进待办队列，并把壁纸文件夹里的那份移出（可以 ⌘Z 撤销）。
// 移出失败时队列照样记着（连上后照样删原图），把移出的错误返回给调用方。
// 排队只在图库未挂载/挂起/删除出错时触发，这里不再在主线程调 os.Stat(src)，避免挂起卷卡死界面。
func (a *app) queueDelete(wall, src string) error {
	a.enqueuePending(wall, src)
	if err := a.removeWallpaper(wall, false); err != nil {
		return err
	}
	a.toast = "图库未连接，删除已排队：连接后自动删除这张原图（⌘Z 撤销移出，队列在概览页查看）"
	return nil
}

// queueDeleteOnly 仅记入待删队列，不动当前壁纸文件夹（用于异步删原图超时期间已换批、正在运行或本地已移出的场景）。
func (a *app) queueDeleteOnly(wall, src string) {
	a.enqueuePending(wall, src)
	a.toast = "图库未连接，删除已排队：连接后自动删除这张原图（队列在概览页查看）"
}

// maybeProcessPending 尝试执行队列：只在图库目录全都挂上时动手（对着断掉/卡住的卷逐个 stat 会一直卡着），
// 每次执行前重新校验文件还在、大小和修改时间没变。由每分钟的定时器和挂载状态变化触发。
func (a *app) maybeProcessPending() {
	if a.pendingBusy || a.running || len(a.pending) == 0 || a.unmountedCount() > 0 || a.checkingMounts() {
		return
	}
	a.pendingBusy = true
	a.pendingMu.Lock()
	a.pendingCanceled = map[string]bool{}
	a.pendingMu.Unlock()
	list := slices.Clone(a.pending)
	isCanceled := func(path string) bool {
		a.pendingMu.Lock()
		defer a.pendingMu.Unlock()
		return a.pendingCanceled[path]
	}
	go func() {
		res := core.RunPendingWithCancel(list, nil, isCanceled) // 已经确认都挂上了，不用再按目录判断
		a.update(func() { a.applyPending(res) })
	}()
}

// applyPending 把一次执行的结果写回队列和删除记录（主线程）。
// 变了的（Stale）不删、也不再自动重试：提示用户自己看过再决定。
// 用路径差集归并而非整片覆盖，确保后台执行期间新入队的条目不丢、已取消的条目不复活。
func (a *app) applyPending(res core.PendingResult) {
	a.pendingBusy = false
	a.pendingMu.Lock()
	a.pendingCanceled = nil
	a.pendingMu.Unlock()
	finished := make(map[string]bool, len(res.Deleted)+len(res.Gone)+len(res.Stale))
	for _, e := range res.Deleted {
		finished[e.Path] = true
		core.LogDeletion(a.paths.DeleteLog, e.Path, int(a.minW), int(a.minH), core.ReasonManual)
		a.invalidateDeleteCache()
		a.appendLog(fmt.Sprintf("🔥 手动删除原图（排队执行，%s 排队）: %s", e.AddedAt.Format("1月2日 15:04"), e.Path))
	}
	for _, e := range res.Gone {
		finished[e.Path] = true
		a.appendLog(fmt.Sprintf("🕓 排队的原图已不存在，跳过: %s", e.Path))
	}
	for _, e := range res.Stale {
		finished[e.Path] = true
		a.appendLog(fmt.Sprintf("⚠️ 排队的原图在排队期间被修改，未删除: %s", e.Path))
	}
	switch {
	case len(res.Deleted) > 0 && len(res.Stale) > 0:
		a.toast = fmt.Sprintf("图库已连接：删除了 %d 张排队的原图，另有 %d 张已被修改未删除（见日志）", len(res.Deleted), len(res.Stale))
	case len(res.Deleted) > 0:
		a.toast = fmt.Sprintf("图库已连接：删除了 %d 张排队的原图", len(res.Deleted))
	case len(res.Stale) > 0:
		a.toast = fmt.Sprintf("%d 张排队的原图在排队期间被修改，未删除（见日志）", len(res.Stale))
	case len(res.Gone) > 0:
		a.toast = fmt.Sprintf("图库已连接：排队的 %d 张原图已不存在，已跳过", len(res.Gone))
	}
	if len(finished) > 0 {
		kept := a.pending[:0]
		for _, e := range a.pending {
			if !finished[e.Path] {
				kept = append(kept, e)
			}
		}
		if len(kept) == 0 {
			a.pending = nil
		} else {
			a.pending = kept
		}
	}
	a.savePending()
}

// cancelPending 取消队列里的一条（不动已经移出的壁纸）。
func (a *app) cancelPending(i int) {
	if i < 0 || i >= len(a.pending) {
		return
	}
	path := a.pending[i].Path
	if a.pendingBusy {
		a.pendingMu.Lock()
		if a.pendingCanceled == nil {
			a.pendingCanceled = map[string]bool{}
		}
		a.pendingCanceled[path] = true
		a.pendingMu.Unlock()
	}
	a.pending = slices.Delete(a.pending, i, i+1)
	a.savePending()
	a.toast = "已取消排队删除：" + filepath.Base(path)
}

func (a *app) cancelAllPending() {
	n := len(a.pending)
	if a.pendingBusy {
		a.pendingMu.Lock()
		if a.pendingCanceled == nil {
			a.pendingCanceled = map[string]bool{}
		}
		for _, e := range a.pending {
			a.pendingCanceled[e.Path] = true
		}
		a.pendingMu.Unlock()
	}
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
		ui.Text(c, fmt.Sprintf("%d 张原图等待删除", n)).FontSize(12.5).Bold().TextColor(amber).SingleLine()
		muted(c, "图库连接后自动执行，可逐条取消").Shrink(1).MinWidth(0)
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
			muted(c, "这些是在图库未连接时点击「删除原图」的原图。图库连接后会自动校验并删除，删除会记进删除记录；"+
				"排队期间被修改过的原图不会删除，只记日志。取消只撤销删除原图，壁纸文件夹中的那份已经移出，可以用 ⌘Z 恢复。")
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
					muted(c, fmt.Sprintf("还有 %d 项…（取消上方条目后会继续显示）", rest))
				}
			})
			ui.Row(c).Gap(8).Justify(ui.End).Children(func() {
				ui.Button(c, "关闭").OnClick(func() { a.pendingShown = false })
			})
		})
	}).Label("待删除的原图")
}
