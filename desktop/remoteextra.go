package main

// 手机遥控第 3 期：手机上改常用设置、看完整日志和删除记录、管理「不再选」名单、撤销移出、拿原图分享。
//
//   - 常用设置随状态快照一起推（remoteState.Settings），手机改了通过 POST /api/settings 调用
//     app.applySettings 统一更新 a.cfg 与界面影子字段，再由 commitState 自动落盘。
//   - 撤销移出用桌面现成的 undoRemove（同一个撤销栈：手机上撤销的可能是电脑上刚移出的那张，反过来也一样）。
//   - 删除记录直接读日志文件（不用主线程）；日志、不再选名单在主线程上读。

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"desktop/core"
)

// remotePreset 是桌面「最低分辨率」的一个预设（手机上用同样的选项）。
type remotePreset struct {
	Label string `json:"label"`
	W     int    `json:"w"`
	H     int    `json:"h"`
}

// remoteSettings 是手机上能改的设置（都是电脑设置页里常调的）。
type remoteSettings struct {
	SampleCount  int   `json:"sample_count"`
	AutoRunHours int   `json:"auto_run_hours"` // 0 表示不自动换；配置里是别的值时原样给出
	AutoOptions  []int `json:"auto_options"`   // 可选的间隔（小时）
	Delete       bool  `json:"delete_during_filter"`
	PreferUnseen bool  `json:"prefer_unseen"`
	Refresh      bool  `json:"refresh_wallpaper"`
	// 第 5 期：手机上加的几项
	BalanceFirst   bool           `json:"balance_first"`
	Incremental    bool           `json:"incremental"`
	Mode           string         `json:"mode"` // copy / symlink
	MinWidth       int            `json:"min_width"`
	MinHeight      int            `json:"min_height"`
	MinPresets     []remotePreset `json:"min_presets"`
	ArchiveEnabled bool           `json:"archive_enabled"`
	ArchiveSubdir  string         `json:"archive_subdir"`        // 归档子文件夹名
	ArchiveDir     string         `json:"archive_dir,omitempty"` // 归档位置（~ 缩写）；留空 = 各图库目录的上级
}

const (
	remoteLogLines     = 400 // /api/log 最多给多少行
	remoteMaxSampleCnt = 9999
	remoteMaxPixels    = 99999
)

func (a *app) remoteSettings() *remoteSettings {
	hours := a.cfg.AutoRunHours
	if a.autoIdx >= 0 {
		hours = autoRunHours[a.autoIdx]
	}
	presets := make([]remotePreset, len(resPresets))
	for i, p := range resPresets {
		presets[i] = remotePreset{Label: p.label, W: p.w, H: p.h}
	}
	return &remoteSettings{
		SampleCount: int(a.num), AutoRunHours: hours, AutoOptions: autoRunHours,
		Delete: a.cfg.DeleteDuringFilter, PreferUnseen: a.cfg.PreferUnseen, Refresh: a.cfg.RefreshWallpaper,
		BalanceFirst: a.cfg.BalanceFirst, Incremental: a.cfg.Incremental, Mode: modes[max(0, a.modeIdx)],
		MinWidth: int(a.minW), MinHeight: int(a.minH), MinPresets: presets,
		ArchiveEnabled: a.cfg.ArchiveEnabled, ArchiveSubdir: a.cfg.ArchiveSubdirName, ArchiveDir: tildify(a.cfg.ArchiveDirOverride),
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
	mux.HandleFunc("POST /api/excluded/add", rs.authed(rs.handleExcludedAdd))
	mux.HandleFunc("GET /api/deletions", rs.authed(rs.handleDeletions))
	mux.HandleFunc("GET /api/wallpapers/{name}/original", rs.authed(rs.handleWallOriginal))
}

// writeSnapshot 回一份最新的状态快照（改了东西的接口都这样回，手机不用再拉一次）。
func (rs *remoteServer) writeSnapshot(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(rs.snapshot())
}

// handleSettings 改常用设置：只改请求里带了的字段，统一通过 app.applySettings 落入状态。
func (rs *remoteServer) handleSettings(w http.ResponseWriter, r *http.Request, dev string) {
	var body settingsPatch
	if !readBodyOrFail(w, r, &body) {
		return
	}
	if n := body.SampleCount; n != nil && (*n < 1 || *n > remoteMaxSampleCnt) {
		writeErr(w, http.StatusBadRequest, "每次张数要在 1 到 9999 之间")
		return
	}
	if h := body.AutoRunHours; h != nil && slices.Index(autoRunHours, *h) < 0 {
		writeErr(w, http.StatusBadRequest, "不支持这个自动换的间隔")
		return
	}
	if m := body.Mode; m != nil && slices.Index(modes, *m) < 0 {
		writeErr(w, http.StatusBadRequest, "不支持这个存放方式")
		return
	}
	for _, p := range []*int{body.MinWidth, body.MinHeight} {
		if p != nil && (*p < 1 || *p > remoteMaxPixels) {
			writeErr(w, http.StatusBadRequest, "分辨率要在 1 到 99999 之间")
			return
		}
	}
	if !rs.onMainOrFail(w, func() {
		a := rs.a
		if changed := a.applySettings(body); len(changed) > 0 {
			a.appendLog("📱 「" + dev + "」改了设置：" + strings.Join(changed, "，"))
		}
	}) {
		return
	}
	rs.writeSnapshot(w)
}

// modeLabel 是存放方式的中文说法（和桌面设置页的分段控件一致）。
func modeLabel(mode string) string {
	if mode == "symlink" {
		return "软链接"
	}
	return "复制"
}

func onOff(v bool) string {
	if v {
		return "：打开"
	}
	return "：关闭"
}

// handleLog 给最近的运行日志（和电脑上「日志」里看到的一样，按行）。
func (rs *remoteServer) handleLog(w http.ResponseWriter, r *http.Request, _ string) {
	var lines []string
	if !rs.onMainOrFail(w, func() {
		lines = slices.Clone(rs.a.log[max(0, len(rs.a.log)-remoteLogLines):])
	}) {
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
	if !rs.onMainOrFail(w, func() {
		a := rs.a
		switch {
		case a.running:
			msg = "正在更换壁纸，等更换完成后再撤销"
		case len(a.undo) == 0:
			msg = "没有可以撤销的移出"
		default:
			name := a.undoName()
			if err := a.undoRemove(); err != nil {
				msg = err.Error() // 包括「同名文件已经在壁纸文件夹里」
			} else {
				a.appendLog("📱 「" + dev + "」撤销了移出 " + name)
			}
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

type remoteExcluded struct {
	Path    string `json:"path"`    // 完整路径（恢复时原样传回来）
	Display string `json:"display"` // ~ 缩写的路径
}

// excludedList 是「不再选」名单的手机版本：完整路径加 ~ 缩写。只在主线程上调。
// 返回非 nil，JSON 里是 [] 而不是 null。
func (rs *remoteServer) excludedList() []remoteExcluded {
	list := make([]remoteExcluded, 0, len(rs.a.cfg.Excluded))
	for _, p := range rs.a.cfg.Excluded {
		list = append(list, remoteExcluded{Path: p, Display: tildify(p)})
	}
	return list
}

func (rs *remoteServer) handleExcluded(w http.ResponseWriter, r *http.Request, _ string) {
	var list []remoteExcluded
	if !rs.onMainOrFail(w, func() {
		list = rs.excludedList()
	}) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": list})
}

// handleExcludedAdd 把原图加进「不再选」名单：手机离线时点了「不再选它」，
// 连上以后一次性补上——不需要那张壁纸还在这一批里（路径对以后的采样一直有效）。
func (rs *remoteServer) handleExcludedAdd(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		Paths []string `json:"paths"`
	}
	if err := readBody(r, &body); err != nil || len(body.Paths) == 0 {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	var list []remoteExcluded
	if !rs.onMainOrFail(w, func() {
		a := rs.a
		added := 0
		for _, p := range body.Paths {
			if p == "" || slices.Contains(a.cfg.Excluded, p) {
				continue
			}
			a.cfg.Excluded = append(a.cfg.Excluded, p)
			added++
		}
		if added > 0 {
			a.appendLog("📱 「" + dev + "」离线时记下的 " + strconv.Itoa(added) + " 张「不再选」已补上")
		}
		list = rs.excludedList()
	}) {
		return
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
	if !rs.onMainOrFail(w, func() {
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
		list = rs.excludedList()
	}) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": list})
}

type remoteDeletion struct {
	At     int64  `json:"at"` // Unix 秒
	Name   string `json:"name"`
	Dir    string `json:"dir"` // ~ 缩写
	Reason string `json:"reason,omitempty"`
}

// etagMatches 检查 If-None-Match 头是否命中当前 ETag（兼容 *、逗号列表与弱比较 W/ 前缀）。
func etagMatches(header, etag string) bool {
	if header == "" || etag == "" {
		return false
	}
	norm := func(s string) string {
		s = strings.TrimSpace(s)
		s = strings.TrimPrefix(s, "W/")
		return s
	}
	target := norm(etag)
	for _, part := range strings.Split(header, ",") {
		p := strings.TrimSpace(part)
		if p == "*" || norm(p) == target {
			return true
		}
	}
	return false
}

// handleDeletions 给删除记录（新的在前），读日志文件，不占主线程。
// 基于日志文件的 (size, mtime) 提供 ETag 条件请求（304）与内存 JSON 缓存，未变化时无需重读和重传。
// 全部给出去：手机在另一台机器上，没法去翻日志文件，截断只会让页面上的张数对不上。
func (rs *remoteServer) handleDeletions(w http.ResponseWriter, r *http.Request, _ string) {
	etag := `"empty"`
	if st, err := os.Stat(rs.a.paths.DeleteLog); err == nil {
		etag = fmt.Sprintf(`"%x-%x"`, st.Size(), st.ModTime().UnixNano())
	}
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache")
	if etagMatches(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}

	rs.deletionsMu.Lock()
	if rs.deletionsETag == etag && rs.deletionsBody != nil {
		body := rs.deletionsBody
		rs.deletionsMu.Unlock()
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
		return
	}
	rs.deletionsMu.Unlock()

	recs := core.ReadDeleteLog(rs.a.paths.DeleteLog)
	items := make([]remoteDeletion, 0, len(recs))
	for _, d := range recs {
		items = append(items, remoteDeletion{At: d.At.Unix(), Name: filepath.Base(d.Path), Dir: tildify(filepath.Dir(d.Path)), Reason: d.Reason})
	}
	byFilter, manual := core.CountDeletions(recs)
	body, err := json.Marshal(map[string]any{"total": len(recs), "filter": byFilter, "manual": manual, "items": items})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "序列化删除记录失败")
		return
	}
	body = append(body, '\n')

	rs.deletionsMu.Lock()
	rs.deletionsETag = etag
	rs.deletionsBody = body
	rs.deletionsMu.Unlock()

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
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
		writeErr(w, http.StatusNotFound, "无法读取这张图片："+err.Error())
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		writeErr(w, http.StatusNotFound, "无法读取这张图片")
		return
	}
	http.ServeContent(w, r, name, st.ModTime().Truncate(time.Second), f)
}
