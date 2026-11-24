package main

// 手机遥控第 2 期：手机上看壁纸文件夹里的图（缩略图、大图），并做和桌面预览一样的三种操作：
// 移出（只删壁纸文件夹里那份）、移出并不再选、删除图库里的原图（手机上已经二次确认过）。
//
//   - 壁纸列表在主线程上随状态快照一起发布（publishWalls），列表变了 walls_rev 跟着变，手机据此重新拉列表。
//   - 图片在请求的 goroutine 里解码：缩略图和桌面共用磁盘缓存（cachedScaled，同样的宽度），
//     大图不缓存，同时最多解码 remoteDecodeWorkers 张（原图可能几千万像素）。
//   - 操作回主线程调桌面现成的 removeWallpaper / deleteOriginal，桌面上照样能 ⌘Z 撤销移出。
//     它们返回的错误直接写进响应（409），不弹桌面的错误框。

import (
	"fmt"
	"hash/fnv"
	"image"
	"image/jpeg"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

const (
	remoteThumbWidth    = thumbWidth // 和桌面缩略图同宽，直接命中磁盘缓存
	remoteImageWidth    = 2732       // 大图宽度：覆盖 iPhone Duo 内屏（2853 像素宽）的绝大部分，离线缓存也按这个宽度存
	remoteDecodeWorkers = 2
)

// remoteWall 是发给手机的一张壁纸。
type remoteWall struct {
	Name       string `json:"name"`                  // 壁纸文件夹里的文件名，也是接口路径里的 id
	Source     string `json:"source,omitempty"`      // 原图路径（~ 缩写）；旧版本换上的没有记录，只能移出
	SampleOnly bool   `json:"sample_only,omitempty"` // 原图位于「仅采样」目录：不可删除原图，只能移出或不再选
}

// wallsSnapshot 是主线程发布的壁纸列表。
type wallsSnapshot struct {
	rev     string
	dir     string
	paths   map[string]string // 文件名 → 完整路径
	list    []remoteWall
	sources map[string]string // 文件名 → 原图完整路径
	hero    string            // 横幅图的文件名（和桌面概览顶部那张一样），没有时为空
}

// wallsRev 是壁纸列表的指纹：换了一批、移出了几张或横幅换了都会变。
func wallsRev(all []string, heroPath string) string {
	h := fnv.New64a()
	for _, p := range all {
		h.Write([]byte(filepath.Base(p)))
		h.Write([]byte{0})
	}
	if heroPath != "" {
		h.Write([]byte("hero:"))
		h.Write([]byte(filepath.Base(heroPath)))
	}
	return strconv.FormatUint(h.Sum64(), 36)
}

// remoteWallsRev 返回发给手机的壁纸列表指纹：在列表与横幅基础上纳入各图是否属于「仅采样」目录，
// 这样目录配置变动后手机端能及时刷新 sample_only 标记。
func (a *app) remoteWallsRev() string {
	w := &a.walls
	base := w.cachedRev()
	if w.remoteRevCache != "" && w.remoteRevBase == base && w.remoteRevCfg == a.cfgRev && w.remoteRevSrc == len(w.sources) {
		return w.remoteRevCache
	}
	var sampleOnly []string
	for _, p := range w.all {
		name := filepath.Base(p)
		if src := w.sources[name]; src != "" && a.isSampleOnlySource(src) {
			sampleOnly = append(sampleOnly, name)
		}
	}
	rev := base
	if len(sampleOnly) > 0 {
		h := fnv.New64a()
		h.Write([]byte(base))
		h.Write([]byte("|so:"))
		for _, name := range sampleOnly {
			h.Write([]byte(name))
			h.Write([]byte{0})
		}
		rev = strconv.FormatUint(h.Sum64(), 36)
	}
	w.remoteRevCache = rev
	w.remoteRevBase = base
	w.remoteRevCfg = a.cfgRev
	w.remoteRevSrc = len(w.sources)
	return rev
}

// publishWalls 由主线程调用：列表变了才重建。
func (rs *remoteServer) publishWalls(rev string, w *wallpapers, isSampleOnly func(string) bool) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	hero := ""
	if w.heroPath != "" {
		hero = filepath.Base(w.heroPath)
	}
	if rs.walls.rev == rev && rs.walls.dir == w.dir && rs.walls.hero == hero {
		return
	}
	s := wallsSnapshot{rev: rev, dir: w.dir, hero: hero, paths: map[string]string{}, sources: map[string]string{}}
	for _, p := range w.all {
		name := filepath.Base(p)
		src := w.sources[name]
		s.paths[name] = p
		if src != "" {
			s.sources[name] = src
		}
		sampleOnly := src != "" && isSampleOnly != nil && isSampleOnly(src)
		s.list = append(s.list, remoteWall{Name: name, Source: tildify(src), SampleOnly: sampleOnly})
	}
	rs.walls = s
}

func (rs *remoteServer) wallsNow() wallsSnapshot {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return rs.walls
}

func (rs *remoteServer) wallRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/wallpapers", rs.authed(rs.handleWalls))
	mux.HandleFunc("GET /api/wallpapers/{name}/thumb", rs.authed(rs.handleWallImage(remoteThumbWidth, true)))
	mux.HandleFunc("GET /api/wallpapers/{name}/image", rs.authed(rs.handleWallImage(remoteImageWidth, false)))
	// 横幅图尺寸（桌面概览顶部用的同一份磁盘缓存）：手机概览的横幅、主屏幕小组件的背景
	mux.HandleFunc("GET /api/wallpapers/{name}/hero", rs.authed(rs.handleWallImage(heroWidth, true)))
	mux.HandleFunc("POST /api/wallpapers/{name}/remove", rs.authed(rs.handleWallRemove))
	mux.HandleFunc("POST /api/wallpapers/{name}/delete", rs.authed(rs.handleWallDelete))
}

func (rs *remoteServer) handleWalls(w http.ResponseWriter, r *http.Request, _ string) {
	s := rs.wallsNow()
	list := s.list
	if list == nil {
		list = []remoteWall{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"rev": s.rev, "hero": s.hero, "items": list})
}

func serveCachedJPEG(w http.ResponseWriter, file string) bool {
	if file == "" {
		return false
	}
	f, err := os.Open(file)
	if err != nil {
		return false
	}
	defer f.Close()
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = io.Copy(w, f)
	return true
}

// handleWallImage 返回缩小后的 JPEG。文件名带进缓存键，同一张图在手机上缓存住就不用再要。
// 命中磁盘缓存直接流式发原 JPEG，不走二次编解码也不占解码信号量；未命中时排队监听请求取消。
func (rs *remoteServer) handleWallImage(width int, cached bool) func(http.ResponseWriter, *http.Request, string) {
	return func(w http.ResponseWriter, r *http.Request, _ string) {
		name := r.PathValue("name")
		path, ok := rs.wallsNow().paths[name]
		if !ok {
			writeErr(w, http.StatusNotFound, "这张壁纸已经不在壁纸文件夹里了")
			return
		}
		var cacheFile string
		if cached {
			cacheFile = thumbCacheFile(path, width)
			if serveCachedJPEG(w, cacheFile) {
				return
			}
		}
		select {
		case rs.decodeSem <- struct{}{}:
			defer func() { <-rs.decodeSem }()
		case <-r.Context().Done():
			return
		}
		if cached && serveCachedJPEG(w, cacheFile) {
			return
		}
		var out image.Image = loadScaled(path, width)
		if out == nil {
			writeErr(w, http.StatusUnprocessableEntity, "无法读取这张图片")
			return
		}
		if cached && cacheFile != "" && writeThumbCache(cacheFile, out) {
			if serveCachedJPEG(w, cacheFile) {
				return
			}
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "private, max-age=86400")
		_ = jpeg.Encode(w, out, &jpeg.Options{Quality: 82})
	}
}

// wallAction 在主线程上对一张壁纸做操作：确认它还在列表里，act 返回的错误带回手机。
func (rs *remoteServer) wallAction(w http.ResponseWriter, r *http.Request, act func(path string) error) {
	name := r.PathValue("name")
	var msg string
	if !rs.onMainOrFail(w, func() {
		a := rs.a
		if a.running {
			msg = "正在换壁纸，等换完再整理"
			return
		}
		path := filepath.Join(a.walls.dir, name)
		if strings.ContainsRune(name, '/') || !slices.Contains(a.walls.all, path) {
			msg = "这张壁纸已经不在壁纸文件夹里了"
			return
		}
		if err := act(path); err != nil {
			msg = err.Error()
		}
	}) {
		return
	}
	if msg != "" {
		writeErr(w, http.StatusConflict, msg)
		return
	}
	rs.writeSnapshot(w)
}

func (rs *remoteServer) handleWallRemove(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		Exclude bool `json:"exclude"`
	}
	if !readBodyOrFail(w, r, &body) {
		return
	}
	rs.wallAction(w, r, func(path string) error {
		a := rs.a
		if body.Exclude && a.wallSource(path) == "" {
			return softErr("这张由旧版本更换，找不到原图，无法删除，只能移出")
		}
		before := len(a.walls.all)
		err := a.removeWallpaper(path, body.Exclude)
		if len(a.walls.all) < before {
			what := "移出了"
			if body.Exclude {
				what = "移出并不再选"
			}
			a.appendLog(fmt.Sprintf("📱 「%s」%s %s", dev, what, filepath.Base(path)))
		}
		return err
	})
}

func (rs *remoteServer) handleWallDelete(w http.ResponseWriter, r *http.Request, dev string) {
	name := r.PathValue("name")
	var (
		msg      string
		path     string
		src      string
		gen      int
		queuedOK bool
	)
	if !rs.onMainOrFail(w, func() {
		a := rs.a
		if a.running {
			msg = "正在换壁纸，等换完再整理"
			return
		}
		path = filepath.Join(a.walls.dir, name)
		if strings.ContainsRune(name, '/') || !slices.Contains(a.walls.all, path) {
			msg = "这张壁纸已经不在壁纸文件夹里了"
			return
		}
		if a.deletingWalls[path] {
			msg = "正在删除这张原图，请稍候"
			return
		}
		src = a.wallSource(path)
		if src == "" {
			msg = "这张由旧版本更换，找不到原图"
			return
		}
		if a.isSampleOnlySource(src) {
			msg = "这张来自仅采样目录，不可删除原图"
			return
		}
		if a.sourceUnmounted(src) {
			before := len(a.walls.all)
			if err := a.queueDelete(path, src); err != nil {
				msg = err.Error()
			} else if len(a.walls.all) < before {
				a.appendLog(fmt.Sprintf("📱 「%s」删除了原图（%s）", dev, filepath.Base(path)))
			}
			queuedOK = true
			return
		}
		if a.deletingWalls == nil {
			a.deletingWalls = map[string]bool{}
		}
		a.deletingWalls[path] = true
		gen = a.wallsGen
	}) {
		return
	}
	if msg != "" {
		writeErr(w, http.StatusConflict, msg)
		return
	}
	if queuedOK {
		rs.writeSnapshot(w)
		return
	}
	// 在 HTTP 协程里执行 NAS 原图删除（带超时），避免挂起网络卷阻塞主线程
	outcome, permErr := removeSourceWithTimeout(src, deleteSrcTimeout)
	if !rs.onMainOrFail(w, func() {
		a := rs.a
		delete(a.deletingWalls, path)
		if err := a.finishDeleteOriginal(path, src, gen, outcome, permErr); err != nil {
			msg = err.Error()
			return
		}
		a.appendLog(fmt.Sprintf("📱 「%s」删除了原图（%s）", dev, filepath.Base(path)))
	}) {
		// 主线程回写超时时仍异步归还 deletingWalls，避免该路径永久锁死
		if rs.a.update != nil {
			rs.a.update(func() { delete(rs.a.deletingWalls, path) })
		}
		return
	}
	if msg != "" {
		writeErr(w, http.StatusConflict, msg)
		return
	}
	rs.writeSnapshot(w)
}
