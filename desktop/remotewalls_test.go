package main

import (
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// writeJPEG 写一张 w×h 的纯色 JPEG。
func writeJPEG(t *testing.T, path string, w, h int) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := range img.Pix {
		img.Pix[i] = 200
	}
	img.Set(0, 0, color.Black)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := jpeg.Encode(f, img, nil); err != nil {
		t.Fatal(err)
	}
}

// withWalls 在假应用里放 3 张壁纸：a、b 有原图记录，c 是旧版本换上的（没有原图）。
func withWalls(t *testing.T, h *remoteHarness) (dest, lib string) {
	t.Helper()
	dest, lib = t.TempDir(), t.TempDir()
	var all []string
	sources := map[string]string{}
	for _, n := range []string{"风景-a.jpg", "风景-b.jpg", "c.jpg"} {
		p := filepath.Join(dest, n)
		writeJPEG(t, p, 800, 450)
		all = append(all, p)
		if n != "c.jpg" {
			src := filepath.Join(lib, strings.TrimPrefix(n, "风景-"))
			writeJPEG(t, src, 800, 450)
			sources[n] = src
		}
	}
	h.walls.dir, h.walls.all, h.walls.sources = dest, all, sources
	h.cfg.DestDir = dest
	h.tt.Frame()
	return dest, lib
}

func TestRemoteWallpaperList(t *testing.T) {
	h := newRemoteHarness(t)
	withWalls(t, h)
	tok := h.pair(t, "iPhone")

	_, st := h.do(t, "GET", "/api/state", tok, nil)
	if st["wallpapers"] != float64(3) || st["walls_rev"] == "" {
		t.Fatalf("state = %v", st)
	}
	code, data := h.do(t, "GET", "/api/wallpapers", tok, nil)
	items, _ := data["items"].([]any)
	if code != 200 || len(items) != 3 || data["rev"] != st["walls_rev"] {
		t.Fatalf("wallpapers = %d %v", code, data)
	}
	first := items[0].(map[string]any)
	if first["name"] != "风景-a.jpg" || !strings.HasSuffix(first["source"].(string), "a.jpg") {
		t.Fatalf("第一张 = %v", first)
	}
	if third := items[2].(map[string]any); third["source"] != nil {
		t.Fatalf("没有原图记录的不该有 source: %v", third)
	}
	if code, _ := h.do(t, "GET", "/api/wallpapers", "", nil); code != 401 {
		t.Fatalf("没配对能拿列表: %d", code)
	}
}

func TestRemoteWallpaperImages(t *testing.T) {
	h := newRemoteHarness(t)
	withWalls(t, h)
	tok := h.pair(t, "iPhone")
	get := func(path string) (*http.Response, []byte) {
		t.Helper()
		req, _ := http.NewRequest("GET", h.base+path, nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, b
	}
	resp, body := get("/api/wallpapers/" + "%E9%A3%8E%E6%99%AF-a.jpg" + "/thumb")
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "image/jpeg" {
		t.Fatalf("thumb = %d %s", resp.StatusCode, body)
	}
	img, err := jpeg.Decode(strings.NewReader(string(body)))
	if err != nil || img.Bounds().Dx() != thumbWidth {
		t.Fatalf("缩略图宽度 = %v %v，应该是 %d", img.Bounds(), err, thumbWidth)
	}
	resp, body = get("/api/wallpapers/c.jpg/image")
	if img, err := jpeg.Decode(strings.NewReader(string(body))); resp.StatusCode != 200 || err != nil || img.Bounds().Dx() != 800 {
		t.Fatalf("大图 = %d（小于 %d 的不放大，应该是原尺寸 800）", resp.StatusCode, remoteImageWidth)
	}
	if resp, _ := get("/api/wallpapers/nope.jpg/thumb"); resp.StatusCode != 404 {
		t.Fatalf("不存在的 = %d", resp.StatusCode)
	}
	if resp, _ := get("/api/wallpapers/..%2Fconfig.json/image"); resp.StatusCode != 404 {
		t.Fatalf("路径穿越 = %d", resp.StatusCode)
	}
}

func TestRemoteWallpaperActions(t *testing.T) {
	h := newRemoteHarness(t)
	dest, lib := withWalls(t, h)
	tok := h.pair(t, "iPhone")
	_, st := h.do(t, "GET", "/api/state", tok, nil)
	rev := st["walls_rev"]

	// 移出并不再选：壁纸文件夹里没了，原图还在，进了排除名单；日志里写是谁遥控的
	code, data := h.do(t, "POST", "/api/wallpapers/风景-a.jpg/remove", tok, map[string]bool{"exclude": true})
	if code != 200 || data["wallpapers"] != float64(2) || data["walls_rev"] == rev {
		t.Fatalf("remove = %d %v", code, data)
	}
	if _, err := os.Stat(filepath.Join(dest, "风景-a.jpg")); !os.IsNotExist(err) {
		t.Fatal("壁纸文件夹里还在")
	}
	if _, err := os.Stat(filepath.Join(lib, "a.jpg")); err != nil {
		t.Fatal("移出不该动原图")
	}
	if !slices.Contains(h.cfg.Excluded, filepath.Join(lib, "a.jpg")) {
		t.Fatalf("没进排除名单: %v", h.cfg.Excluded)
	}
	if !strings.Contains(strings.Join(h.log, "\n"), "「iPhone」移出并不再选 风景-a.jpg") {
		t.Fatal("日志里没写是谁移出的")
	}
	if _, data := h.do(t, "GET", "/api/wallpapers", tok, nil); len(data["items"].([]any)) != 2 {
		t.Fatalf("列表没更新: %v", data)
	}
	// 同一张再移一次
	if code, _ := h.do(t, "POST", "/api/wallpapers/风景-a.jpg/remove", tok, map[string]bool{}); code != 409 {
		t.Fatalf("移出不存在的 = %d", code)
	}

	// 正在换壁纸时不让整理（壁纸文件夹正在被清空、重新复制）
	h.running = true
	if code, data := h.do(t, "POST", "/api/wallpapers/风景-b.jpg/remove", tok, map[string]bool{}); code != 409 || !strings.Contains(data["error"].(string), "正在换壁纸") {
		t.Fatalf("运行中移出 = %d %v", code, data)
	}
	h.running = false

	// 没有原图记录的只能移出
	if code, data := h.do(t, "POST", "/api/wallpapers/c.jpg/delete", tok, nil); code != 409 || !strings.Contains(data["error"].(string), "找不到原图") {
		t.Fatalf("删没有原图的 = %d %v", code, data)
	}
	if code, _ := h.do(t, "POST", "/api/wallpapers/c.jpg/remove", tok, map[string]bool{"exclude": true}); code != 409 {
		t.Fatalf("不再选没有原图的 = %d", code)
	}

	// 删除原图：原图和壁纸文件夹里的都没了，记进删除日志
	if code, data := h.do(t, "POST", "/api/wallpapers/风景-b.jpg/delete", tok, nil); code != 200 || data["wallpapers"] != float64(1) {
		t.Fatalf("delete = %d %v", code, data)
	}
	if _, err := os.Stat(filepath.Join(lib, "b.jpg")); !os.IsNotExist(err) {
		t.Fatal("原图没删掉")
	}
	logData, _ := os.ReadFile(h.paths.DeleteLog)
	if !strings.Contains(string(logData), filepath.Join(lib, "b.jpg")) {
		t.Fatalf("删除日志里没有: %s", logData)
	}
}
