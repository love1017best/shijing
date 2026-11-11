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

func writePNG(t *testing.T, path string, w, h int) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := range img.Pix { // 不透明的灰色 200
		img.Pix[i] = 200
		if i%4 == 3 {
			img.Pix[i] = 255
		}
	}
	img.Set(0, 0, color.RGBA{255, 0, 0, 255})
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
}

func TestThumbCache(t *testing.T) {
	thumbCacheDir = t.TempDir()
	defer func() { thumbCacheDir = "" }()
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a.png"), filepath.Join(dir, "b.png")
	writePNG(t, a, 800, 400)
	writePNG(t, b, 800, 400)

	img := cachedScaled(a, thumbWidth)
	if img == nil || img.Bounds().Dx() != thumbWidth {
		t.Fatalf("应缩到 %d 宽: %v", thumbWidth, img)
	}
	cachedScaled(b, thumbWidth)
	entries, _ := os.ReadDir(thumbCacheDir)
	if len(entries) != 2 {
		t.Fatalf("应缓存两张，实际 %d", len(entries))
	}
	// 读缓存：原图坏了也还能读到缓存（大小、时间没变就认）
	fi, _ := os.Stat(a)
	os.WriteFile(a, make([]byte, fi.Size()), 0o644)
	os.Chtimes(a, fi.ModTime(), fi.ModTime())
	if img := cachedScaled(a, thumbWidth); img == nil || img.Bounds().Dx() != thumbWidth {
		t.Fatal("缓存命中时应直接读缓存")
	}
	// 原图换了：对不上旧缓存，重新解码
	writePNG(t, a, 600, 300)
	os.Chtimes(a, time.Now().Add(time.Hour), time.Now().Add(time.Hour))
	cachedScaled(a, thumbWidth)
	if entries, _ := os.ReadDir(thumbCacheDir); len(entries) != 3 {
		t.Fatalf("原图换了应另存一份，实际 %d", len(entries))
	}
	// 只留属于现在这批的
	pruneThumbCache([]string{a})
	if entries, _ := os.ReadDir(thumbCacheDir); len(entries) != 1 {
		t.Fatalf("清理后应只剩 a 现在的那份，实际 %d", len(entries))
	}
}

func TestPreviewDecodesOneAtATime(t *testing.T) {
	f, tt, walls, _ := previewFixture(t, "p-a.png", "p-b.png", "p-c.png", "p-d.png", "p-e.png", "p-f.png", "p-g.png", "p-h.png")
	for _, w := range walls {
		writePNG(t, w, 64, 40)
	}
	f.big = nil
	tt.Frame()
	for range 4 { // 连续翻，解码还没回来
		tt.Key(0, ui.KeySpace)
		tt.Frame()
	}
	if !f.bigBusy {
		t.Fatal("应在后台解码")
	}
	// 回来之后接着解当前这张和前后几张，离得远的不留
	f.settle(t, tt, func() bool { return !f.bigBusy && len(f.big) == 4 })
	cur := walls[f.previewIdx]
	if f.big[cur] == nil || f.previewBitmap(cur) != f.big[cur] {
		t.Error("当前这张应显示解码好的大图")
	}
	if _, ok := f.big[walls[0]]; ok {
		t.Error("翻过去很远的那张不应留着")
	}
	f.preview = false
	tt.Frame()
	if f.big != nil {
		t.Error("关掉预览应放掉大图")
	}
}
