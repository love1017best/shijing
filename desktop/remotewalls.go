package main

// 手机遥控第 2 期：手机上看壁纸文件夹里的图（缩略图、大图），并做和桌面预览一样的三种操作：
// 移出（只删壁纸文件夹里那份）、移出并不再选、删除图库里的原图（手机上已经二次确认过）。
//
//   - 壁纸列表在主线程上随状态快照一起发布（publishWalls），列表变了 walls_rev 跟着变，手机据此重新拉列表。
//   - 图片在请求的 goroutine 里解码：缩略图和桌面共用磁盘缓存（cachedScaled，同样的宽度），
//     大图不缓存，同时最多解码 remoteDecodeWorkers 张（原图可能几千万像素）。
//   - 操作回主线程调桌面现成的 removeWallpaper / deleteOriginal，桌面上照样能 ⌘Z 撤销移出。
//     那两个函数出错时弹桌面的错误框，这里临时换掉 showErr，把错误带回给手机。

import (
	"fmt"
	"hash/fnv"
	"image"
	"image/jpeg"
	"net/http"
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
	Name   string `json:"name"`             // 壁纸文件夹里的文件名，也是接口路径里的 id
	Source string `json:"source,omitempty"` // 原图路径（~ 缩写）；旧版本换上的没有记录，只能移出
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

// wallsRev 是壁纸列表的指纹：换了一批、移出了几张都会变。
func wallsRev(all []string) string {
	h := fnv.New64a()
	for _, p := range all {
		h.Write([]byte(filepath.Base(p)))
		h.Write([]byte{0})
	}
	return strconv.FormatUint(h.Sum64(), 36)
}

// publishWalls 由主线程调用：列表变了才重建。
func (rs *remoteServer) publishWalls(rev string, w *wallpapers) {
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
		s.list = append(s.list, remoteWall{Name: name, Source: tildify(src)})
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

// handleWallImage 返回缩小后的 JPEG。文件名带进缓存键，同一张图在手机上缓存住就不用再要。
func (rs *remoteServer) handleWallImage(width int, cached bool) func(http.ResponseWriter, *http.Request, string) {
	return func(w http.ResponseWriter, r *http.Request, _ string) {
		name := r.PathValue("name")
		path, ok := rs.wallsNow().paths[name]
		if !ok {
			writeErr(w, http.StatusNotFound, "这张壁纸已经不在壁纸文件夹里了")
			return
		}
		rs.decodeSem <- struct{}{}
		var out image.Image
		if cached {
			out = cachedScaled(path, width)
		} else {
			out = loadScaled(path, width)
		}
		<-rs.decodeSem
		if out == nil {
			writeErr(w, http.StatusUnprocessableEntity, "这张图读不了")
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "private, max-age=86400")
		_ = jpeg.Encode(w, out, &jpeg.Options{Quality: 82})
	}
}

// wallAction 在主线程上对一张壁纸做操作：确认它还在列表里，桌面的错误框临时改成把错误带回来。
func (rs *remoteServer) wallAction(w http.ResponseWriter, r *http.Request, act func(path string) string) {
	name := r.PathValue("name")
	var msg string
	ok := rs.onMain(func() {
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
		show := a.showErr
		a.showErr = func(title, message string) { msg = title + "：" + message }
		defer func() { a.showErr = show }()
		if m := act(path); m != "" && msg == "" {
			msg = m
		}
	})
	switch {
	case !ok:
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
	case msg != "":
		writeErr(w, http.StatusConflict, msg)
	default:
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(rs.snapshot())
	}
}

func (rs *remoteServer) handleWallRemove(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		Exclude bool `json:"exclude"`
	}
	if err := readBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	rs.wallAction(w, r, func(path string) string {
		a := rs.a
		if body.Exclude && a.wallSource(path) == "" {
			return "这张是之前的版本换上的，找不到原图，只能移出"
		}
		before := len(a.walls.all)
		a.removeWallpaper(path, body.Exclude)
		if len(a.walls.all) < before {
			what := "移出了"
			if body.Exclude {
				what = "移出并不再选"
			}
			a.appendLog(fmt.Sprintf("📱 「%s」%s %s", dev, what, filepath.Base(path)))
		}
		return ""
	})
}

func (rs *remoteServer) handleWallDelete(w http.ResponseWriter, r *http.Request, dev string) {
	rs.wallAction(w, r, func(path string) string {
		a := rs.a
		if a.wallSource(path) == "" {
			return "这张是之前的版本换上的，找不到原图"
		}
		before := len(a.walls.all)
		a.deleteOriginal(path)
		if len(a.walls.all) < before {
			a.appendLog(fmt.Sprintf("📱 「%s」删除了原图（%s）", dev, filepath.Base(path)))
		}
		return ""
	})
}
