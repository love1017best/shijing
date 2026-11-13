package main

import (
	"image"
	"path/filepath"
	"testing"
	"time"
)

// 窗口关着时 view 不会重画，换完一批也要马上重读壁纸文件夹：
// 手机拿到的 walls_rev 和列表都来自这里，只靠「下一帧 view」会一直停在上一批。
func TestRunEndReloadsWallsWhileHidden(t *testing.T) {
	f, tt := newFakeApp(t)
	dest := t.TempDir()
	f.cfg.DestDir = dest
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Media0/Fav"}
	files := []string{filepath.Join(dest, "旧-1.jpg")}
	f.scanWallpapers = func(dir string) scannedWallpapers {
		return scannedWallpapers{dir: dir, all: append([]string(nil), files...), thumbs: map[string]image.Image{}}
	}

	// 只在主线程上执行排队的更新，不渲染：模拟窗口关着
	pump := func() bool {
		f.mu.Lock()
		q := f.queue
		f.queue = nil
		f.mu.Unlock()
		for _, fn := range q {
			fn()
		}
		return len(q) > 0
	}
	settle := func(want func() bool) {
		t.Helper()
		for range 300 {
			pump()
			if want() {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("等待超时")
	}

	tt.Frame() // 打开应用，读第一次
	settle(func() bool { return len(f.walls.all) == 1 })

	// 换完一批：内容变了，然后跑一次（假的流程直接返回成功）
	files = []string{filepath.Join(dest, "新-1.jpg"), filepath.Join(dest, "新-2.jpg")}
	f.startRun()
	settle(func() bool { return !f.running })
	settle(func() bool { return len(f.walls.all) == 2 })

	if got := filepath.Base(f.walls.all[0]); got != "新-1.jpg" && got != "新-2.jpg" {
		t.Fatalf("换完一批后没有重读壁纸文件夹: %q", f.walls.all)
	}
}
