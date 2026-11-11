package main

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"desktop/core"
)

func TestRemoteSettings(t *testing.T) {
	h := newRemoteHarness(t)
	tok := h.pair(t, "iPhone")
	_, st := h.do(t, "GET", "/api/state", tok, nil)
	set, _ := st["settings"].(map[string]any)
	if set == nil || set["auto_options"] == nil {
		t.Fatalf("状态里没有设置: %v", st)
	}

	// 只改传了的字段
	code, data := h.do(t, "POST", "/api/settings", tok, map[string]any{"sample_count": 120, "auto_run_hours": 24, "prefer_unseen": true})
	if code != 200 {
		t.Fatalf("settings = %d %v", code, data)
	}
	got := data["settings"].(map[string]any)
	if got["sample_count"] != float64(120) || got["auto_run_hours"] != float64(24) || got["prefer_unseen"] != true {
		t.Fatalf("响应里的设置没变: %v", got)
	}
	h.tt.Frame() // 下一帧自动保存
	cfg := h.buildConfig()
	if cfg.SampleCount != 120 || cfg.AutoRunHours != 24 || !cfg.PreferUnseen {
		t.Fatalf("配置 = %+v", cfg)
	}
	saved, err := core.LoadConfig(h.cfgPath)
	if err != nil || saved.SampleCount != 120 {
		t.Fatalf("没写盘: %v %+v", err, saved)
	}
	if !strings.Contains(strings.Join(h.log, "\n"), "「iPhone」改了设置：每次张数 120，自动换 每天") {
		t.Fatalf("日志: %v", h.log)
	}

	for _, bad := range []map[string]any{{"sample_count": 0}, {"auto_run_hours": 5}} {
		if code, _ := h.do(t, "POST", "/api/settings", tok, bad); code != 400 {
			t.Fatalf("%v = %d，应该拒绝", bad, code)
		}
	}
}

func TestRemoteUndoAndExcluded(t *testing.T) {
	h := newRemoteHarness(t)
	dest, lib := withWalls(t, h)
	tok := h.pair(t, "iPhone")

	if code, data := h.do(t, "POST", "/api/undo", tok, nil); code != 409 || !strings.Contains(data["error"].(string), "没有可以撤销") {
		t.Fatalf("没东西时撤销 = %d %v", code, data)
	}
	_, data := h.do(t, "POST", "/api/wallpapers/风景-a.jpg/remove", tok, map[string]bool{"exclude": true})
	if data["undo_name"] != "风景-a.jpg" || data["excluded"] != float64(1) {
		t.Fatalf("移出后的状态 = %v", data)
	}
	// 撤销：放回壁纸文件夹，也从排除名单里去掉
	code, data := h.do(t, "POST", "/api/undo", tok, nil)
	if code != 200 || data["wallpapers"] != float64(3) || data["excluded"] != float64(0) || data["undo_name"] != nil {
		t.Fatalf("undo = %d %v", code, data)
	}
	if _, err := os.Stat(filepath.Join(dest, "风景-a.jpg")); err != nil {
		t.Fatal("没放回壁纸文件夹")
	}

	// 排除名单：列出、恢复一张、全部恢复
	h.do(t, "POST", "/api/wallpapers/风景-a.jpg/remove", tok, map[string]bool{"exclude": true})
	h.do(t, "POST", "/api/wallpapers/风景-b.jpg/remove", tok, map[string]bool{"exclude": true})
	_, data = h.do(t, "GET", "/api/excluded", tok, nil)
	items := data["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("excluded = %v", data)
	}
	a := filepath.Join(lib, "a.jpg")
	_, data = h.do(t, "POST", "/api/excluded/restore", tok, map[string]any{"paths": []string{a}})
	if len(data["items"].([]any)) != 1 || slices.Contains(h.cfg.Excluded, a) {
		t.Fatalf("恢复一张 = %v / %v", data, h.cfg.Excluded)
	}
	_, data = h.do(t, "POST", "/api/excluded/restore", tok, map[string]any{"all": true})
	if len(data["items"].([]any)) != 0 || len(h.cfg.Excluded) != 0 {
		t.Fatalf("全部恢复 = %v", data)
	}
	if code, _ := h.do(t, "POST", "/api/excluded/restore", tok, map[string]any{}); code != 400 {
		t.Fatalf("空请求 = %d", code)
	}
}

func TestRemoteLogDeletionsOriginal(t *testing.T) {
	h := newRemoteHarness(t)
	withWalls(t, h)
	tok := h.pair(t, "iPhone")

	h.appendLog("第一行\n第二行")
	_, data := h.do(t, "GET", "/api/log", tok, nil)
	lines := data["lines"].([]any)
	if len(lines) < 2 || lines[len(lines)-1] != "第二行" {
		t.Fatalf("log = %v", data)
	}

	core.LogDeletion(h.paths.DeleteLog, "/Volumes/Media0/Lib/set1/p.jpg", 3840, 2160, "竖屏 1080×1920")
	_, data = h.do(t, "GET", "/api/deletions", tok, nil)
	items := data["items"].([]any)
	if data["total"] != float64(1) || len(items) != 1 {
		t.Fatalf("deletions = %v", data)
	}
	if d := items[0].(map[string]any); d["name"] != "p.jpg" || d["reason"] != "竖屏 1080×1920" || d["at"].(float64) <= 0 {
		t.Fatalf("记录 = %v", d)
	}

	req, _ := http.NewRequest("GET", h.base+"/api/wallpapers/c.jpg/original", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	want, _ := os.ReadFile(filepath.Join(h.walls.dir, "c.jpg"))
	if resp.StatusCode != 200 || string(body) != string(want) || resp.Header.Get("Content-Type") != "image/jpeg" {
		t.Fatalf("original = %d %s %d 字节", resp.StatusCode, resp.Header.Get("Content-Type"), len(body))
	}
}
