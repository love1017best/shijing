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

// wallpapers 是壁纸文件夹的快照。
type wallpapers struct {
	dir     string
	total   int          // 文件夹里的图片数
	hero    *ui.Bitmap   // 横幅背景；没有图片时为 nil
	thumbs  []*ui.Bitmap // 缩略图
	paths   []string     // 每张缩略图对应的文件，点击时打开
	rest    []string     // 还没解码的文件（已打乱），需要更多缩略图时从这里取
	loading bool
	more    bool // 正在后台解码更多缩略图
}

// scannedWallpapers 是后台扫描的结果（image.Image 在主线程上才转成 Bitmap）。
type scannedWallpapers struct {
	dir    string
	total  int
	hero   image.Image
	thumbs []image.Image
	paths  []string
	rest   []string
}

// scanWallpapers 列出文件夹里的图片，打乱后解码横幅图和前几张缩略图。读不了的图片直接跳过。
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

	// 横幅图要够宽；第一张不够宽（或读不了）就往后找，最多试几张
	for len(files) > 0 && res.hero == nil {
		f := files[0]
		files = files[1:]
		img := loadScaled(f, heroWidth)
		if img == nil {
			continue
		}
		if img.Bounds().Dx() >= thumbWidth*2 {
			res.hero = img
			break
		}
		res.thumbs, res.paths = append(res.thumbs, shrink(img, thumbWidth)), append(res.paths, f)
	}
	thumbs, paths, rest := decodeThumbs(files, initialThumbs-len(res.thumbs))
	res.thumbs, res.paths, res.rest = append(res.thumbs, thumbs...), append(res.paths, paths...), rest
	return res
}

// decodeThumbs 从 files 里按顺序解码出 n 张缩略图（读不了的跳过、往后补），返回剩下没碰过的文件。
func decodeThumbs(files []string, n int) (thumbs []image.Image, paths, rest []string) {
	for n > 0 && len(files) > 0 {
		batch := files[:min(len(files), n)]
		files = files[len(batch):]
		decoded := make([]image.Image, len(batch))
		sem := make(chan struct{}, decodeWorkers)
		var wg sync.WaitGroup
		for i, f := range batch {
			wg.Add(1)
			sem <- struct{}{}
			go func() {
				defer func() { <-sem; wg.Done() }()
				decoded[i] = loadScaled(f, thumbWidth)
			}()
		}
		wg.Wait()
		for i, img := range decoded {
			if img != nil {
				thumbs, paths = append(thumbs, img), append(paths, batch[i])
				n--
			}
		}
	}
	return thumbs, paths, files
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
			w := wallpapers{dir: s.dir, total: s.total, paths: s.paths, rest: s.rest}
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

// loadMoreThumbs 在后台再解码几张缩略图，凑够 want 张（窗口拉大、网格放得下更多时）。
func (a *app) loadMoreThumbs(want int) {
	w := &a.walls
	need := min(want, maxThumbs) - len(w.thumbs)
	if need <= 0 || len(w.rest) == 0 || w.more || w.loading || a.update == nil {
		return
	}
	w.more = true
	dir, files, before := w.dir, w.rest, len(w.thumbs)
	go func() {
		thumbs, paths, rest := decodeThumbs(files, need)
		a.update(func() {
			w := &a.walls
			if w.dir != dir || !w.more || len(w.thumbs) != before { // 期间重新读过壁纸文件夹，这批作废
				return
			}
			w.more = false
			for _, t := range thumbs {
				w.thumbs = append(w.thumbs, ui.NewBitmap(t))
			}
			w.paths, w.rest = append(w.paths, paths...), rest
		})
	}()
}
