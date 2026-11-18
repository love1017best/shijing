package main

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

// 横幅轮播：按 all 的顺序往后换，太窄的跳过，轮回到 heroPath 时退回 hero；heroPath 本身不变（手机遥控按它）。
func TestAdvanceHeroRotates(t *testing.T) {
	f, _ := newFakeApp(t)
	dir := t.TempDir()
	write := func(name string, w int) string {
		p := filepath.Join(dir, name)
		img := image.NewRGBA(image.Rect(0, 0, w, w*10/16))
		for i := range img.Pix {
			img.Pix[i] = 200
		}
		img.Set(0, 0, color.Black)
		out, err := os.Create(p)
		if err != nil {
			t.Fatal(err)
		}
		defer out.Close()
		if err := png.Encode(out, img); err != nil {
			t.Fatal(err)
		}
		return p
	}
	a, b, narrow, c := write("a.png", 800), write("b.png", 800), write("narrow.png", 300), write("c.png", 800)
	hero := ui.NewBitmap(image.NewRGBA(image.Rect(0, 0, 16, 10)))
	f.page = pageOverview
	f.walls = wallpapers{dir: dir, all: []string{a, b, narrow, c}, hero: hero, heroPath: a, thumbs: map[string]*ui.Bitmap{}}

	step := func() string {
		t.Helper()
		f.advanceHero()
		for range 300 {
			f.mu.Lock()
			q := f.queue
			f.queue = nil
			f.mu.Unlock()
			for _, fn := range q {
				fn()
			}
			if !f.walls.sliding {
				_, p := f.walls.shownHero()
				return filepath.Base(p)
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("等待超时")
		return ""
	}
	for i, want := range []string{"b.png", "c.png", "a.png", "b.png"} {
		if got := step(); got != want {
			t.Fatalf("第 %d 次轮播显示 %s，应为 %s", i+1, got, want)
		}
		if f.walls.heroPath != a {
			t.Fatalf("轮播不该改 heroPath: %s", f.walls.heroPath)
		}
	}
	if f.walls.slidePath == "" {
		t.Fatal("轮到 b 时应显示 slide")
	}
	// 移出正在显示的那张：退回 hero
	f.dropWall(b)
	if bmp, p := f.walls.shownHero(); p != a || bmp != hero {
		t.Fatalf("移出轮播中的图后应退回 hero，现在是 %s", p)
	}
	// 不在概览页时不换
	f.page = pageWalls
	f.advanceHero()
	if f.walls.sliding {
		t.Fatal("不在概览页时不该轮播")
	}
}
