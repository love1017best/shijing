package main

import (
	"hash/fnv"
	"image"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

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
	previewWidth  = 3200 // 大图预览解码到的宽度（像素）：全屏预览时也不糊
	thumbWidth    = 360  // 缩略图宽度（像素）

	heroInterval = 10 * time.Second // 概览横幅轮播的间隔
	heroTries    = 8                // 轮播时往后最多试几张（太窄、读不了的跳过）
)

// wallpapers 是壁纸文件夹的快照。all 是全部图片（shuffleStable 排过的固定顺序，横幅图也在内），大图预览按它翻；
// 缩略图网格按 all 的顺序排、去掉读不了的（grid）。缩略图按路径存在 thumbs 里，还没解码的不在里面。
type wallpapers struct {
	dir      string
	hero     *ui.Bitmap // 横幅背景；没有图片时为 nil
	heroPath string     // 横幅图对应的文件，点横幅打开它的大图
	// 轮播换上的那张（advanceHero）。heroPath 保持不变：手机遥控的横幅、缩略图网格都按它；
	// 轮回到 heroPath 时清空，显示 hero。
	slide     *ui.Bitmap
	slidePath string
	sliding   bool // 后台正在解码下一张
	all       []string
	thumbs    map[string]*ui.Bitmap // 解码过的缩略图；值为 nil 表示读不了
	browse    map[string]*ui.Bitmap // 壁纸页用的更小的缩略图（browseThumbWidth），按需分批解码
	sources   map[string]string     // 壁纸文件名 → 原图路径（core.WallpaperSources）；旧版本换上的为 nil
	loading   bool
	more      bool   // 正在后台解码更多缩略图
	browsing  bool   // 正在后台解码壁纸页的缩略图
	browseSeq uint64 // 壁纸页缩略图批次序号：快速切页来回时防止旧批次清掉新批次的 browsing 标志
	// 派生缓存：避免每次重绘或发布快照都重新哈希整份壁纸列表、重算目录分组
	revCache     string
	revLen       int
	revHero      string
	folderRev    string
	folderSrcLen int
	folders      []string
	folderCounts map[string]int
}

// invalidateRev 在就地增删 all 或切换 heroPath 后清掉列表指纹和目录分组缓存。
func (w *wallpapers) invalidateRev() {
	w.revCache = ""
	w.folderRev = ""
}

// cachedRev 返回壁纸列表指纹；all 与 heroPath 未变时直接复用缓存。
func (w *wallpapers) cachedRev() string {
	if w.revCache != "" && w.revLen == len(w.all) && w.revHero == w.heroPath {
		return w.revCache
	}
	w.revCache = wallsRev(w.all, w.heroPath)
	w.revLen = len(w.all)
	w.revHero = w.heroPath
	return w.revCache
}

// shownHero 是横幅现在显示的那张：轮播换过就是 slide，否则是 hero。
func (w *wallpapers) shownHero() (*ui.Bitmap, string) {
	if w.slide != nil && w.slidePath != "" {
		return w.slide, w.slidePath
	}
	return w.hero, w.heroPath
}

// firstWideImage 从候选路径中解码出第一张宽度不小于 thumbWidth*2 的图片（用于横幅）。
func firstWideImage(candidates []string) (image.Image, string) {
	for _, f := range candidates {
		if im := cachedScaled(f, heroWidth); im != nil && im.Bounds().Dx() >= thumbWidth*2 {
			return im, f
		}
	}
	return nil, ""
}

// storeBitmaps 在主线程上把后台解码好的图片批量写入 dst（只写入仍在 all 中的条目）。
func storeBitmaps(dst *map[string]*ui.Bitmap, all []string, imgs map[string]image.Image) {
	if *dst == nil {
		*dst = map[string]*ui.Bitmap{}
	}
	for p, img := range imgs {
		if !slices.Contains(all, p) {
			continue
		}
		if img != nil {
			(*dst)[p] = ui.NewBitmap(img)
		} else {
			(*dst)[p] = nil
		}
	}
}

// advanceHero 轮播概览横幅：按 all 的顺序换到当前这张后面第一张够宽的图（读不了、太窄的跳过）。
// 在后台解码（有磁盘缓存，第二次起几毫秒），解好再换上。只在概览页、没在运行、没开大图预览时换；
// 窗口隐藏时 main.go 不调它。
func (a *app) advanceHero() {
	w := &a.walls
	if a.page != pageOverview || a.running || a.preview || w.loading || w.sliding || w.heroPath == "" || len(w.all) < 2 {
		return
	}
	_, cur := w.shownHero()
	start := max(slices.Index(w.all, cur), 0)
	var candidates []string
	for i := 1; i < len(w.all) && len(candidates) < heroTries; i++ {
		candidates = append(candidates, w.all[(start+i)%len(w.all)])
	}
	dir, gen := w.dir, a.wallsGen
	w.sliding = true
	go func() {
		img, path := firstWideImage(candidates)
		a.update(func() {
			w := &a.walls
			w.sliding = false
			if w.dir != dir || a.wallsGen != gen || img == nil || !slices.Contains(w.all, path) {
				return // 期间换了一批、移出了这张，或者后面几张都读不了
			}
			if path == w.heroPath {
				w.slide, w.slidePath = nil, ""
				return
			}
			w.slide, w.slidePath = ui.NewBitmap(img), path
		})
	}()
}

// grid 是缩略图网格里的图片：all 去掉读不了的，从第一张开始。横幅会轮播整批，所以横幅图也在网格里。
func (w *wallpapers) grid() []string {
	g := make([]string, 0, len(w.all))
	for _, p := range w.all {
		if bmp, tried := w.thumbs[p]; !tried || bmp != nil {
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
	shuffleStable(files)
	res.all = files

	// 横幅图要够宽；不够宽的那张拿来当缩略图，读不了的记下来
	for _, f := range files {
		img := cachedScaled(f, heroWidth)
		if img != nil && img.Bounds().Dx() >= thumbWidth*2 {
			res.hero, res.heroPath = img, f
			res.thumbs[f] = shrink(img, thumbWidth) // 横幅图也在网格里，缩略图直接从它缩
			break
		}
		if img != nil {
			img = shrink(img, thumbWidth)
		}
		res.thumbs[f] = img
	}
	var todo []string
	for _, f := range files {
		if _, tried := res.thumbs[f]; !tried && len(todo) < initialThumbs {
			todo = append(todo, f)
		}
	}
	maps.Copy(res.thumbs, decodeThumbs(todo))
	pruneThumbCache(files)
	return res
}

// shuffleStable 把图片排成看起来随机、但每次打开都一样的顺序：按文件名的哈希排。
// 不换一批时顺序不变，方便一张张筛；移出一张也不会打乱其余的先后。每一批的文件名不同，所以每批的顺序各不相同。
func shuffleStable(files []string) {
	key := func(f string) uint64 {
		h := fnv.New64a()
		h.Write([]byte(filepath.Base(f)))
		return h.Sum64()
	}
	slices.SortStableFunc(files, func(x, y string) int {
		kx, ky := key(x), key(y)
		switch {
		case kx < ky:
			return -1
		case kx > ky:
			return 1
		}
		return 0
	})
}

// decodeThumbs 并发解码 files 的缩略图；读不了的值为 nil。
func decodeThumbs(files []string) map[string]image.Image {
	return decodeThumbsAt(files, thumbWidth)
}

func decodeThumbsAt(files []string, width int) map[string]image.Image {
	decoded := make([]image.Image, len(files))
	sem := make(chan struct{}, decodeWorkers)
	var wg sync.WaitGroup
	for i, f := range files {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			decoded[i] = cachedScaled(f, width)
		}()
	}
	wg.Wait()
	out := make(map[string]image.Image, len(files))
	for i, f := range files {
		out[f] = decoded[i]
	}
	return out
}

// loadScaled 解码一张图片并缩到 width 像素宽（不放大）。优先用系统的 ImageIO（systemDecode），不行再用纯 Go 解码。
func loadScaled(path string, width int) image.Image {
	if img := systemDecode(path, width); img != nil {
		return img
	}
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
// 换完一批后由 app.go 直接调用，不等下一帧 view——窗口关着时 view 不重画，
// 光靠它会一直显示上一批，手机那边（walls_rev 来自这里）也跟着不更新。
func (a *app) loadWallpapers() {
	if a.scanWallpapers == nil || a.walls.loading {
		return
	}
	dir := core.ExpandUser(a.cfg.DestDir)
	gen := a.wallsGen
	a.wallsLoadedGen = gen
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
			a.endWallSelection() // 换了一批，之前勾选的都对不上了
			// 加载期间改了壁纸文件夹、或者又跑完一批：按最新的再读一次
			if core.ExpandUser(a.cfg.DestDir) != dir || a.wallsGen != gen {
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

// reloadHero 横幅图被移出 / 删掉之后，按 all 的顺序挑一张够宽的重新当横幅。
// 只解这一张（scanWallpapers 会把整库缩略图再解一遍，为了一张横幅不值当）；
// 找不到够宽的就不设横幅，界面退回暮色插画。
func (a *app) reloadHero() {
	dir := a.walls.dir
	candidates := slices.Clone(a.walls.all)
	gen := a.wallsGen
	go func() {
		img, path := firstWideImage(candidates)
		a.update(func() {
			if a.walls.dir != dir || a.wallsGen != gen {
				return // 期间重新读过壁纸文件夹，那次会自己定横幅
			}
			// 候选图在解码期间也被移出了：不回写已删除路径，若列表还有图则继续挑下一张
			if path != "" && !slices.Contains(a.walls.all, path) {
				if len(a.walls.all) > 0 && a.walls.heroPath == "" {
					a.reloadHero()
				}
				return
			}
			a.walls.hero = nil
			a.walls.heroPath = path
			a.walls.invalidateRev()
			if img != nil {
				a.walls.hero = ui.NewBitmap(img)
			}
		})
	}()
}

// loadBrowseThumbs 给壁纸页补一批可视区附近的缩略图：每次后台解一批，解完触发重绘。
// 校验 wallsGen 和当前存在性，避免换批或移出后写入过期缩略图；超出上限时淘汰远离当前窗口的项。
func (a *app) loadBrowseThumbs(window []string, keepSet map[string]bool) {
	w := &a.walls
	if w.browsing || w.loading || a.update == nil {
		return
	}
	if len(w.browse) > browseMaxCached && len(keepSet) > 0 {
		for p := range w.browse {
			if !keepSet[p] {
				delete(w.browse, p)
			}
		}
	}
	var todo []string
	for _, p := range window {
		if _, tried := w.browse[p]; !tried {
			todo = append(todo, p)
			if len(todo) >= browseBatch {
				break
			}
		}
	}
	if len(todo) == 0 {
		return
	}
	w.browsing = true
	w.browseSeq++
	dir, gen, seq := w.dir, a.wallsGen, w.browseSeq
	go func() {
		imgs := decodeThumbsAt(todo, browseThumbWidth)
		a.update(func() {
			w := &a.walls
			if w.dir != dir || a.wallsGen != gen || a.page != pageWalls || w.browseSeq != seq { // 期间换批、切页或已被新批次取代
				return
			}
			w.browsing = false
			storeBitmaps(&w.browse, w.all, imgs)
		})
	}()
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
	dir, gen := w.dir, a.wallsGen
	go func() {
		imgs := decodeThumbs(todo)
		a.update(func() {
			w := &a.walls
			if w.dir != dir || a.wallsGen != gen || !w.more { // 期间重新读过壁纸文件夹，这批作废
				return
			}
			w.more = false
			storeBitmaps(&w.thumbs, w.all, imgs)
		})
	}()
}
