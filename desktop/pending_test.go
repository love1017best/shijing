package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"desktop/core"
)

// 图库没连上时点「删除原图」：不报错，记进队列，壁纸文件夹里那份照样移出（可以 ⌘Z 撤销）。
func TestDeleteOriginalQueuesWhenLibraryOffline(t *testing.T) {
	f, tt := newFakeApp(t)
	dir := t.TempDir()
	wall := filepath.Join(dir, "壁纸.jpg")
	if err := os.WriteFile(wall, []byte("wall"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Offline/Fav"}
	f.checkMounts()
	f.settle(t, tt, func() bool { return f.unmountedCount() == 1 })

	src := "/Volumes/Offline/Fav/原图.jpg"
	f.walls.all = []string{wall}
	f.walls.sources = map[string]string{"壁纸.jpg": src}
	f.deleteOriginal(wall)

	if len(f.pending) != 1 || f.pending[0].Path != src {
		t.Fatalf("应当排一条队: %+v", f.pending)
	}
	if got := core.LoadPending(f.paths.Pending); len(got) != 1 || got[0].Path != src {
		t.Errorf("队列应当写到磁盘: %+v", got)
	}
	if _, err := os.Stat(wall); !os.IsNotExist(err) {
		t.Errorf("壁纸文件夹里那份应当已经移出: %v", err)
	}
	if len(f.undo) != 1 {
		t.Errorf("移出应当可以 ⌘Z 撤销，撤销栈里有 %d 条", len(f.undo))
	}
	if !slices.ContainsFunc(f.log, func(s string) bool { return strings.Contains(s, "排队删除原图") }) {
		t.Errorf("运行日志里应当记一条排队: %v", f.log)
	}
}

// 图库连上以后（挂载检查通过）自动执行队列，并记进删除记录。
func TestPendingRunsWhenLibraryBack(t *testing.T) {
	f, tt := newFakeApp(t)
	dir := t.TempDir()
	src := filepath.Join(dir, "原图.jpg")
	if err := os.WriteFile(src, []byte("img"), 0o644); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(src)
	if err != nil {
		t.Fatal(err)
	}
	f.cfg.SampleOnlyDirs = []string{dir}
	f.mounts[dir] = mountOK
	f.pending = []core.PendingDelete{{Path: src, AddedAt: time.Now(), Size: fi.Size(), ModTime: fi.ModTime()}}

	f.maybeProcessPending()
	f.settle(t, tt, func() bool { return len(f.pending) == 0 })

	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Errorf("连上后应当把排队的原图删掉: %v", err)
	}
	recs := core.ReadDeleteLog(f.paths.DeleteLog)
	if len(recs) != 1 || recs[0].Path != src || !recs[0].Manual() {
		t.Errorf("应当记进删除记录: %+v", recs)
	}
}

// 图库还没连上时不执行，队列原样留着。
func TestPendingWaitsWhileLibraryOffline(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Offline/Fav"}
	f.checkMounts()
	f.settle(t, tt, func() bool { return f.unmountedCount() == 1 })
	f.pending = []core.PendingDelete{{Path: "/Volumes/Offline/Fav/原图.jpg"}}

	f.maybeProcessPending()
	tt.Frame()
	if len(f.pending) != 1 {
		t.Errorf("图库没连上时不该动队列: %+v", f.pending)
	}
}

// 排队期间文件被改过：不删，提示一句，队列里也不再留（不再自动重试）。
func TestPendingSkipsFileChangedAfterQueuing(t *testing.T) {
	f, tt := newFakeApp(t)
	dir := t.TempDir()
	src := filepath.Join(dir, "原图.jpg")
	if err := os.WriteFile(src, []byte("img"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.cfg.SampleOnlyDirs = []string{dir}
	f.mounts[dir] = mountOK
	f.pending = []core.PendingDelete{{Path: src, Size: 999, ModTime: time.Now().Add(-time.Hour)}}

	f.maybeProcessPending()
	f.settle(t, tt, func() bool { return len(f.pending) == 0 })

	if _, err := os.Stat(src); err != nil {
		t.Errorf("改过的文件不该删: %v", err)
	}
	if !tt.HasText("在排队期间被改过，没有删除") {
		t.Errorf("应当提示没删: %v", tt.Texts())
	}
}

// 概览上的队列提示，点开能逐条取消。
func TestPendingBarCancel(t *testing.T) {
	f, tt := newFakeApp(t)
	f.pending = []core.PendingDelete{
		{Path: "/Volumes/Media0/a/1.jpg", Wall: "1.jpg"},
		{Path: "/Volumes/Media0/a/2.jpg", Wall: "2.jpg"},
	}
	tt.Frame()
	if !tt.HasText("2 项原图等着删除") {
		t.Fatalf("概览应当有队列提示: %v", tt.Texts())
	}
	click(t, tt, "查看")
	if !tt.HasText("待删除的原图") {
		t.Fatalf("应当打开弹层: %v", tt.Texts())
	}
	click(t, tt, "取消")
	tt.Frame()
	if len(f.pending) != 1 {
		t.Errorf("应当只剩一条: %+v", f.pending)
	}
	click(t, tt, "全部取消")
	tt.Frame()
	if len(f.pending) != 0 {
		t.Errorf("应当全部取消: %+v", f.pending)
	}
	if got := core.LoadPending(f.paths.Pending); len(got) != 0 {
		t.Errorf("磁盘上的队列也要清掉: %+v", got)
	}
}
