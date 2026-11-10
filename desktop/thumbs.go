package main

import (
	"image"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sync"

	"desktop/core"

	"github.com/egoist/mygo/ui"
	"golang.org/x/image/draw"
)

// 概览页展示当前壁纸：一张做横幅背景，其余做缩略图条。
// 只读本地的壁纸文件夹（dest_dir），不碰 NAS；解码和缩小都在后台完成。
const (
	stripThumbs = 5    // 缩略图条显示几张（最后再加一格「+N」）
	heroWidth   = 1600 // 横幅图缩到的宽度（像素，Retina 下约 800 DIP）
	thumbWidth  = 360  // 缩略图宽度（像素）
)

// wallpapers 是壁纸文件夹的快照。
type wallpapers struct {
	dir     string
	total   int          // 文件夹里的图片数
	hero    *ui.Bitmap   // 横幅背景；没有图片时为 nil
	thumbs  []*ui.Bitmap // 缩略图
	paths   []string     // 每张缩略图对应的文件，点击时打开
	loading bool
}

// scannedWallpapers 是后台扫描的结果（image.Image 在主线程上才转成 Bitmap）。
type scannedWallpapers struct {
	dir    string
	total  int
	hero   image.Image
	thumbs []image.Image
	paths  []string
}

// scanWallpapers 列出文件夹里的图片，随机挑几张解码、缩小。读不了的图片直接跳过。
func scanWallpapers(dir string) scannedWallpapers {
	res := scannedWallpapers{dir: dir}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return res
	}
	var files []string
	for _, e := range entries {
		if e.IsDir() || !core.IsValidImage(e.Name()) || e.Name()[0] == '.' {
			continue
		}
		files = append(files, filepath.Join(dir, e.Name()))
	}
	res.total = len(files)
	rand.Shuffle(len(files), func(i, j int) { files[i], files[j] = files[j], files[i] })

	// 多挑几张备用：个别文件解码失败时仍能凑满
	pick := files[:min(len(files), stripThumbs+4)]
	decoded := make([]image.Image, len(pick))
	var wg sync.WaitGroup
	for i, f := range pick {
		wg.Add(1)
		go func() {
			defer wg.Done()
			width := thumbWidth
			if i == 0 {
				width = heroWidth
			}
			decoded[i] = loadScaled(f, width)
		}()
	}
	wg.Wait()
	for i, img := range decoded {
		switch {
		case img == nil:
		case res.hero == nil && img.Bounds().Dx() >= thumbWidth*2:
			res.hero = img
		case len(res.thumbs) < stripThumbs:
			res.thumbs = append(res.thumbs, shrink(img, thumbWidth))
			res.paths = append(res.paths, pick[i])
		}
	}
	return res
}

// loadScaled 解码一张图片并缩到 width 像素宽（不放大）。
func loadScaled(path string, width int) image.Image {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		return nil
	}
	return shrink(img, width)
}

// shrink 先用快速的近似双线性缩到目标的两倍，再用 Catmull-Rom 精缩：
// 直接对几千万像素的原图做高质量缩放太慢，只用近似算法又有锯齿。
func shrink(img image.Image, width int) image.Image {
	b := img.Bounds()
	if b.Dx() <= width {
		return img
	}
	h := max(1, b.Dy()*width/b.Dx())
	if b.Dx() > width*2 {
		mid := image.NewRGBA(image.Rect(0, 0, width*2, h*2))
		draw.ApproxBiLinear.Scale(mid, mid.Bounds(), img, b, draw.Src, nil)
		img, b = mid, mid.Bounds()
	}
	out := image.NewRGBA(image.Rect(0, 0, width, h))
	draw.CatmullRom.Scale(out, out.Bounds(), img, b, draw.Src, nil)
	return out
}

// loadWallpapers 在后台重新读取壁纸文件夹，读完在主线程上更新界面。
func (a *app) loadWallpapers() {
	if a.scanWallpapers == nil || a.walls.loading {
		return
	}
	dir := core.ExpandUser(a.cfg.DestDir)
	a.walls.loading = true
	go func() {
		s := a.scanWallpapers(dir)
		a.update(func() {
			w := wallpapers{dir: s.dir, total: s.total, paths: s.paths}
			if s.hero != nil {
				w.hero = ui.NewBitmap(s.hero)
			}
			for _, t := range s.thumbs {
				w.thumbs = append(w.thumbs, ui.NewBitmap(t))
			}
			a.walls = w
			// 加载期间改了壁纸文件夹：按新路径再读一次
			if core.ExpandUser(a.cfg.DestDir) != dir {
				a.loadWallpapers()
			}
		})
	}()
}
