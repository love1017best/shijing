package main

// 手机遥控第 3 期：手机上改常用设置、看完整日志和删除记录、管理「不再选」名单、撤销移出、拿原图分享。
//
//   - 常用设置随状态快照一起推（remoteState.Settings），手机改了走 POST /api/settings，只改传了的字段；
//     改的是界面状态（a.num、a.autoIdx、a.cfg.*），下一帧 autosave 照常写盘，和在电脑上改一样。
//   - 撤销移出用桌面现成的 undoRemove（同一个撤销栈：手机上撤销的可能是电脑上刚移出的那张，反过来也一样）。
//   - 删除记录直接读日志文件（不用主线程）；日志、不再选名单在主线程上读。

import (
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"time"

	"desktop/core"
)

// remoteSettings 是手机上能改的几项设置（都是电脑设置页里常调的）。
type remoteSettings struct {
	SampleCount  int   `json:"sample_count"`
	AutoRunHours int   `json:"auto_run_hours"` // 0 表示不自动换；配置里是别的值时原样给出
	AutoOptions  []int `json:"auto_options"`   // 可选的间隔（小时）
	Delete       bool  `json:"delete_during_filter"`
	PreferUnseen bool  `json:"prefer_unseen"`
	Refresh      bool  `json:"refresh_wallpaper"`
}

const (
	remoteLogLines     = 400 // /api/log 最多给多少行
	remoteDeleteShown  = 300 // /api/deletions 最多给多少条
	remoteMaxSampleCnt = 9999
)

func (a *app) remoteSettings() *remoteSettings {
	hours := a.cfg.AutoRunHours
	if a.autoIdx >= 0 {
		hours = autoRunHours[a.autoIdx]
	}
	return &remoteSettings{
		SampleCount: int(a.num), AutoRunHours: hours, AutoOptions: autoRunHours,
		Delete: a.cfg.DeleteDuringFilter, PreferUnseen: a.cfg.PreferUnseen, Refresh: a.cfg.RefreshWallpaper,
	}
}

// undoName 是最近一次可以撤销的移出（壁纸文件名），没有时为空。
func (a *app) undoName() string {
	if len(a.undo) == 0 {
		return ""
	}
	return filepath.Base(a.undo[len(a.undo)-1].wall)
}

func (rs *remoteServer) extraRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/settings", rs.authed(rs.handleSettings))
	mux.HandleFunc("GET /api/log", rs.authed(rs.handleLog))
	mux.HandleFunc("POST /api/undo", rs.authed(rs.handleUndo))
	mux.HandleFunc("GET /api/excluded", rs.authed(rs.handleExcluded))
	mux.HandleFunc("POST /api/excluded/restore", rs.authed(rs.handleExcludedRestore))
	mux.HandleFunc("GET /api/deletions", rs.authed(rs.handleDeletions))
	mux.HandleFunc("GET /api/wallpapers/{name}/original", rs.authed(rs.handleWallOriginal))
}

// writeSnapshot 回一份最新的状态快照（改了东西的接口都这样回，手机不用再拉一次）。
func (rs *remoteServer) writeSnapshot(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(rs.snapshot())
}

// handleSettings 改常用设置：只改请求里带了的字段。
func (rs *remoteServer) handleSettings(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		SampleCount  *int  `json:"sample_count"`
		AutoRunHours *int  `json:"auto_run_hours"`
		Delete       *bool `json:"delete_during_filter"`
		PreferUnseen *bool `json:"prefer_unseen"`
		Refresh      *bool `json:"refresh_wallpaper"`
	}
	if err := readBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	if n := body.SampleCount; n != nil && (*n < 1 || *n > remoteMaxSampleCnt) {
		writeErr(w, http.StatusBadRequest, "每次张数要在 1 到 9999 之间")
		return
	}
	idx := -1
	if h := body.AutoRunHours; h != nil {
		if idx = slices.Index(autoRunHours, *h); idx < 0 {
			writeErr(w, http.StatusBadRequest, "不支持这个自动换的间隔")
			return
		}
	}
	var changed []string
	ok := rs.onMain(func() {
		a := rs.a
		if n := body.SampleCount; n != nil && int(a.num) != *n {
			a.num = float64(*n)
			changed = append(changed, "每次张数 "+strconv.Itoa(*n))
		}
		if idx >= 0 && a.autoIdx != idx {
			a.autoIdx = idx
			changed = append(changed, "自动换 "+autoRunLabel(autoRunHours[idx]))
		}
		set := func(p *bool, v *bool, name string) {
			if v != nil && *p != *v {
				*p = *v
				changed = append(changed, name+onOff(*v))
			}
		}
		set(&a.cfg.DeleteDuringFilter, body.Delete, "删除不合格原图")
		set(&a.cfg.PreferUnseen, body.PreferUnseen, "优先选没换上过的")
		set(&a.cfg.RefreshWallpaper, body.Refresh, "刷新系统壁纸")
		if len(changed) > 0 {
			a.appendLog("📱 「" + dev + "」改了设置：" + joinCN(changed))
		}
	})
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
		return
	}
	rs.writeSnapshot(w)
}

func onOff(v bool) string {
	if v {
		return "：打开"
	}
	return "：关闭"
}

func joinCN(s []string) string {
	out := ""
	for i, x := range s {
		if i > 0 {
			out += "，"
		}
		out += x
	}
	return out
}

// handleLog 给最近的运行日志（和电脑上「日志」里看到的一样，按行）。
func (rs *remoteServer) handleLog(w http.ResponseWriter, r *http.Request, _ string) {
	var lines []string
	if !rs.onMain(func() {
		lines = slices.Clone(rs.a.log[max(0, len(rs.a.log)-remoteLogLines):])
	}) {
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
		return
	}
	if lines == nil {
		lines = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"lines": lines})
}

// handleUndo 撤销最近一次移出（电脑上 ⌘Z 的同一个操作）。
func (rs *remoteServer) handleUndo(w http.ResponseWriter, r *http.Request, dev string) {
	var msg string
	ok := rs.onMain(func() {
		a := rs.a
		switch {
		case a.running:
			msg = "正在换壁纸，等换完再撤销"
		case len(a.undo) == 0:
			msg = "没有可以撤销的移出"
		default:
			name := a.undoName()
			show := a.showErr
			a.showErr = func(title, message string) { msg = title + "：" + message }
			before := len(a.walls.all)
			a.undoRemove()
			a.showErr = show
			if msg == "" && len(a.walls.all) == before {
				msg = a.toast // 同名文件已经在壁纸文件夹里之类
			}
			if msg == "" {
				a.appendLog("📱 「" + dev + "」撤销了移出 " + name)
			}
		}
	})
	switch {
	case !ok:
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
	case msg != "":
		writeErr(w, http.StatusConflict, msg)
	default:
		rs.writeSnapshot(w)
	}
}

type remoteExcluded struct {
	Path    string `json:"path"`    // 完整路径（恢复时原样传回来）
	Display string `json:"display"` // ~ 缩写的路径
}

func (rs *remoteServer) handleExcluded(w http.ResponseWriter, r *http.Request, _ string) {
	var list []remoteExcluded
	if !rs.onMain(func() {
		for _, p := range rs.a.cfg.Excluded {
			list = append(list, remoteExcluded{Path: p, Display: tildify(p)})
		}
	}) {
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
		return
	}
	if list == nil {
		list = []remoteExcluded{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": list})
}

// handleExcludedRestore 把原图从「不再选」名单里拿掉：{"paths": [...]} 或 {"all": true}。
func (rs *remoteServer) handleExcludedRestore(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		Paths []string `json:"paths"`
		All   bool     `json:"all"`
	}
	if err := readBody(r, &body); err != nil || (!body.All && len(body.Paths) == 0) {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	var list []remoteExcluded
	ok := rs.onMain(func() {
		a := rs.a
		before := len(a.cfg.Excluded)
		if body.All {
			a.cfg.Excluded = []string{}
		} else {
			a.cfg.Excluded = slices.DeleteFunc(slices.Clone(a.cfg.Excluded), func(p string) bool { return slices.Contains(body.Paths, p) })
		}
		if n := before - len(a.cfg.Excluded); n > 0 {
			a.appendLog("📱 「" + dev + "」恢复了 " + strconv.Itoa(n) + " 张不再选的图片")
		}
		for _, p := range a.cfg.Excluded {
			list = append(list, remoteExcluded{Path: p, Display: tildify(p)})
		}
	})
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
		return
	}
	if list == nil {
		list = []remoteExcluded{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": list})
}

type remoteDeletion struct {
	At     int64  `json:"at"` // Unix 秒
	Name   string `json:"name"`
	Dir    string `json:"dir"` // ~ 缩写
	Reason string `json:"reason,omitempty"`
}

// handleDeletions 给删除记录（新的在前），读日志文件，不占主线程。
func (rs *remoteServer) handleDeletions(w http.ResponseWriter, r *http.Request, _ string) {
	recs := core.ReadDeleteLog(rs.a.paths.DeleteLog)
	items := make([]remoteDeletion, 0, min(len(recs), remoteDeleteShown))
	for _, d := range recs[:min(len(recs), remoteDeleteShown)] {
		items = append(items, remoteDeletion{At: d.At.Unix(), Name: filepath.Base(d.Path), Dir: tildify(filepath.Dir(d.Path)), Reason: d.Reason})
	}
	byFilter, manual := core.CountDeletions(recs)
	writeJSON(w, http.StatusOK, map[string]any{"total": len(recs), "filter": byFilter, "manual": manual, "items": items})
}

// handleWallOriginal 给壁纸文件夹里这张图的原文件（手机上分享、存到相册用）。
func (rs *remoteServer) handleWallOriginal(w http.ResponseWriter, r *http.Request, _ string) {
	name := r.PathValue("name")
	path, ok := rs.wallsNow().paths[name]
	if !ok {
		writeErr(w, http.StatusNotFound, "这张壁纸已经不在壁纸文件夹里了")
		return
	}
	f, err := os.Open(path) // 软链接模式下壁纸是链接，Open 会跟过去读原图
	if err != nil {
		writeErr(w, http.StatusNotFound, "读不了这张图："+err.Error())
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		writeErr(w, http.StatusNotFound, "读不了这张图")
		return
	}
	http.ServeContent(w, r, name, st.ModTime().Truncate(time.Second), f)
}
