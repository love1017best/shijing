package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"desktop/core"
)

// ── 挂载状态 ──────────────────────────────────────────────────────────────

const mountProbeTimeout = 3 * time.Second

// mountKey 把配置里的目录路径规范化（展开 ~、清理冗余斜杠和末尾 /），
// 保证 mounts / mountProbing / sourceUnmounted 的读写 key 始终一致。
func mountKey(dir string) string {
	d := filepath.Clean(core.ExpandUser(dir))
	if d != "/" {
		d = strings.TrimRight(d, "/")
	}
	return d
}

func (a *app) mountStateOf(dir string) mountState {
	if s, ok := a.mounts[mountKey(dir)]; ok {
		return s
	}
	return a.mounts[dir]
}

func (a *app) setMountState(dir string, st mountState) {
	a.mounts[mountKey(dir)] = st
}

// checkMounts 在后台检查每个源目录是否可访问。网络卷卡住时 stat 可能阻塞很久，
// 所以每个目录单独一个 goroutine，3 秒没结果就标成「无响应」；同时按目录对在途探测去重，
// 防止每分钟定时检查对已挂起卷反复泄漏阻塞在内核 stat 里的线程。
func (a *app) checkMounts() {
	if a.mountProbing == nil {
		a.mountProbing = map[string]bool{}
	}
	if a.mountSeq == nil {
		a.mountSeq = map[string]int{}
	}
	for _, raw := range a.allDirs() {
		key := mountKey(raw)
		if a.mountProbing[key] {
			continue
		}
		a.mountProbing[key] = true
		a.mountSeq[key]++
		seq := a.mountSeq[key]
		a.mounts[key] = mountUnknown
		dir := core.ExpandUser(raw)
		stat := a.statDir
		go func(dir, key string, seq int) {
			done := make(chan bool, 1)
			go func() {
				ok := stat(dir)
				done <- ok
				a.update(func() {
					delete(a.mountProbing, key)
					if a.mountSeq[key] != seq {
						return
					}
					// 推进 seq，确保 3 秒边界同时就绪的超时分支不会把已就绪状态覆写为 mountSlow
					a.mountSeq[key]++
					if ok {
						a.mounts[key] = mountOK
					} else {
						a.mounts[key] = mountMissing
					}
					a.maybeProcessPending() // 图库挂上来了就把排队的删除执行掉
				})
			}()
			select {
			case <-done:
			case <-time.After(mountProbeTimeout):
				a.update(func() {
					if a.mountSeq[key] == seq {
						a.mounts[key] = mountSlow
					}
				})
			}
		}(dir, key, seq)
	}
}

// probeMount 检查一个目录能不能访问（会阻塞，最多 3 秒）。
func probeMount(stat func(string) bool, d string) mountState {
	result := make(chan bool, 1)
	go func() { result <- stat(core.ExpandUser(d)) }()
	select {
	case ok := <-result:
		if ok {
			return mountOK
		}
		return mountMissing
	case <-time.After(mountProbeTimeout):
		return mountSlow
	}
}

func (a *app) unmountedCount() int {
	n := 0
	for _, d := range a.allDirs() {
		if s := a.mountStateOf(d); s == mountMissing || s == mountSlow {
			n++
		}
	}
	return n
}

func (a *app) checkingMounts() bool {
	for _, d := range a.allDirs() {
		if a.mountStateOf(d) == mountUnknown {
			return true
		}
	}
	return false
}

// ── 目录与配置选择 ────────────────────────────────────────────────────────

// browse 在后台弹出目录选择框（它会阻塞），选好后回到主线程写入。
func (a *app) browse(title string, apply func(path string)) {
	go func() {
		if p := a.pickDir(title); p != "" {
			a.update(func() {
				if a.running {
					a.toast = "运行中不能修改设置"
					return
				}
				apply(p)
			})
		}
	}()
}

func (a *app) addDir(p *dirPanel) {
	a.browse("添加图库目录", func(path string) {
		if slices.Contains(a.allDirs(), path) {
			a.toast = "这个目录已经在图库里了"
			return
		}
		*p.dirs = append(*p.dirs, path)
		a.setMountState(path, mountOK) // 刚从对话框选出来，一定可访问
	})
}

// addDropped 把拖进来的文件夹加进图库（文件、已经在图库里的跳过）。
func (a *app) addDropped(p *dirPanel, paths []string) {
	added, skipped := 0, 0
	for _, path := range paths {
		if st, err := os.Stat(path); err != nil || !st.IsDir() || slices.Contains(a.allDirs(), path) {
			skipped++
			continue
		}
		*p.dirs = append(*p.dirs, path)
		a.setMountState(path, mountOK)
		added++
	}
	switch {
	case added > 0 && skipped > 0:
		a.toast = fmt.Sprintf("已添加 %d 个目录，跳过 %d 个（不是文件夹或已经在图库里）", added, skipped)
	case added > 0:
		a.toast = fmt.Sprintf("已添加 %d 个目录", added)
	default:
		a.toast = "没有可添加的文件夹（只能拖文件夹，已经在图库里的会跳过）"
	}
}

func (a *app) removeDir(p *dirPanel, dir string) {
	*p.dirs = slices.DeleteFunc(*p.dirs, func(d string) bool { return d == dir })
	p.chosen.Clear()
}

func (a *app) removeChosen(p *dirPanel) {
	*p.dirs = slices.DeleteFunc(*p.dirs, func(d string) bool { return p.chosen.Has(d) })
	p.chosen.Clear()
}

func (a *app) importConfig() {
	go func() {
		path := a.pickFile("导入配置（选择一个 config.json）")
		if path == "" {
			return
		}
		cfg, err := core.LoadConfig(path)
		if err != nil {
			a.showErr("导入失败", err.Error())
			return
		}
		a.update(func() {
			if a.running {
				a.toast = "运行中不能导入配置"
				return
			}
			a.setConfig(cfg)
			a.syncMenuKeys()
			a.checkMounts()
			a.toast = "已导入配置"
			a.appendLog("📥 已导入配置: " + path)
		})
	}()
}
