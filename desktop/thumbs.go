package main

import (
	"image"
	"maps"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sync"

	"desktop/core"

	"github.com/egoist/mygo/ui"
	"golang.org/x/image/draw"
)

// 概览页展示当前壁纸：一张做横幅背景，其余做缩略图网格。网格的行列数跟着窗口大小变（stripLayout），
// 先解码够一屏常见大小的缩略图，窗口拉大需要更多时再从剩下的文件里接着解码（loadMoreThumbs）。
// 只读本地的壁纸文件夹（dest_dir），不碰 NAS；解码和缩小都在后台完成。
const (
	initialThumbs = 11   // 第一次解码几张缩略图（默认窗口两行 × 6 列，减去「+N」那格）
	maxThumbs     = 71   // 最多显示几张（stripLayout 的上限：6 行 × 12 列 - 1）
	decodeWorkers = 4    // 同时解码几张：原图可能是几千万像素，全部同时解码内存吃不消
	heroWidth     = 1600 // 横幅图缩到的宽度（像素，Retina 下约 800 DIP）
	thumbWidth    = 360  // 缩略图宽度（像素）
)

// wallpapers 是壁纸文件夹的快照。all 是全部图片（打乱后的顺序，横幅图也在内），大图预览按它翻；
// 缩略图网格按 all 的顺序排、去掉横幅图和读不了的（grid）。缩略图按路径存在 thumbs 里，还没解码的不在里面。
type wallpapers struct {
	dir      string
	hero     *ui.Bitmap // 横幅背景；没有图片时为 nil
	heroPath string     // 横幅图对应的文件，点横幅打开它的大图
	all      []string
	thumbs   map[string]*ui.Bitmap // 解码过的缩略图；值为 nil 表示读不了
	sources  map[string]string     // 壁纸文件名 → 原图路径（core.WallpaperSources）；旧版本换上的为 nil
	loading  bool
	more     bool // 正在后台解码更多缩略图
}

// grid 是缩略图网格里的图片：all 去掉横幅图和读不了的。
func (w *wallpapers) grid() []string {
	g := make([]string, 0, len(w.all))
	for _, p := range w.all {
		if bmp, tried := w.thumbs[p]; p != w.heroPath && (!tried || bmp != nil) {
			g = append(g, p)
		}
	}
	return g
}

// scannedWallpapers 是后台扫描的结果（image.Image 在主线程上才转成 Bitmap）。
type scannedWallpapers struct {
	dir      string
	hero     image.Image
	heroPath string
	all      []string
	thumbs   map[string]image.Image // 值为 nil 表示读不了
}

// scanWallpapers 列出文件夹里的图片，打乱后解码横幅图和前几张缩略图。
func scanWallpapers(dir string) scannedWallpapers {
	res := scannedWallpapers{dir: dir, thumbs: map[string]image.Image{}}
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
	rand.Shuffle(len(files), func(i, j int) { files[i], files[j] = files[j], files[i] })
	res.all = files

	// 横幅图要够宽；不够宽的那张拿来当缩略图，读不了的记下来
	for _, f := range files {
		img := loadScaled(f, heroWidth)
		if img != nil && img.Bounds().Dx() >= thumbWidth*2 {
			res.hero, res.heroPath = img, f
			break
		}
		if img != nil {
			img = shrink(img, thumbWidth)
		}
		res.thumbs[f] = img
	}
	var todo []string
	for _, f := range files {
		if _, tried := res.thumbs[f]; !tried && f != res.heroPath && len(todo) < initialThumbs {
			todo = append(todo, f)
		}
	}
	maps.Copy(res.thumbs, decodeThumbs(todo))
	return res
}

// decodeThumbs 并发解码 files 的缩略图；读不了的值为 nil。
func decodeThumbs(files []string) map[string]image.Image {
	decoded := make([]image.Image, len(files))
	sem := make(chan struct{}, decodeWorkers)
	var wg sync.WaitGroup
	for i, f := range files {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			decoded[i] = loadScaled(f, thumbWidth)
		}()
	}
	wg.Wait()
	out := make(map[string]image.Image, len(files))
	for i, f := range files {
		out[f] = decoded[i]
	}
	return out
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
		sources := core.WallpaperSources(a.paths.Selection, dir)
		a.update(func() {
			w := wallpapers{dir: s.dir, heroPath: s.heroPath, all: s.all, thumbs: bitmaps(s.thumbs), sources: sources}
			if s.hero != nil {
				w.hero = ui.NewBitmap(s.hero)
			}
			a.walls = w
			// 加载期间改了壁纸文件夹：按新路径再读一次
			if core.ExpandUser(a.cfg.DestDir) != dir {
				a.loadWallpapers()
			}
		})
	}()
}

// bitmaps 把解码好的图在主线程上转成 Bitmap（读不了的保持 nil）。
func bitmaps(imgs map[string]image.Image) map[string]*ui.Bitmap {
	out := make(map[string]*ui.Bitmap, len(imgs))
	for p, img := range imgs {
		if img != nil {
			out[p] = ui.NewBitmap(img)
		} else {
			out[p] = nil
		}
	}
	return out
}

// loadMoreThumbs 在后台解码网格前 want 张里还没解码的（窗口拉大、网格放得下更多时）。
func (a *app) loadMoreThumbs(want int) {
	w := &a.walls
	if w.more || w.loading || a.update == nil {
		return
	}
	var todo []string
	for _, p := range w.grid()[:min(want, maxThumbs, len(w.grid()))] {
		if _, tried := w.thumbs[p]; !tried {
			todo = append(todo, p)
		}
	}
	if len(todo) == 0 {
		return
	}
	w.more = true
	dir := w.dir
	go func() {
		imgs := decodeThumbs(todo)
		a.update(func() {
			w := &a.walls
			if w.dir != dir || !w.more { // 期间重新读过壁纸文件夹，这批作废
				return
			}
			w.more = false
			if w.thumbs == nil {
				w.thumbs = map[string]*ui.Bitmap{}
			}
			maps.Copy(w.thumbs, bitmaps(imgs))
		})
	}()
}
