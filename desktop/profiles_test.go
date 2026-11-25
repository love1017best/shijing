package main

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"desktop/core"

	"github.com/egoist/mygo"
)

func TestProfilesUIAndTray(t *testing.T) {
	f, tt := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/A"}
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Media0/S"}
	f.cfg.SampleCount = 150
	f.cfg.MinWidth = 3840
	f.cfg.MinHeight = 2160
	f.syncShadowFromConfig()
	f.page = pageSettings

	tt.Frame()

	// 通过设置页保存第一套方案
	f.profileDraft = "日常风景"
	tt.Frame()
	click(t, tt, "保存方案")
	tt.Frame()

	if f.cfg.ActiveProfile != "日常风景" || len(f.cfg.Profiles) != 1 || f.profileDraft != "" {
		t.Fatalf("保存方案失败: active=%q len=%d draft=%q", f.cfg.ActiveProfile, len(f.cfg.Profiles), f.profileDraft)
	}

	// 修改参数并保存第二套方案
	n := 40
	w, h := 2560, 1440
	f.applySettings(settingsPatch{SampleCount: &n, MinWidth: &w, MinHeight: &h})
	f.cfg.FilterAndSampleDirs = []string{}
	f.cfg.SampleOnlyDirs = []string{"/Volumes/Media0/Dark"}
	tt.Frame()
	if !f.cfg.ActiveProfileModified() {
		t.Fatal("修改配置后应显示已修改")
	}

	f.profileDraft = "暗色极简"
	tt.Frame()
	click(t, tt, "保存方案")
	tt.Frame()
	if f.cfg.ActiveProfile != "暗色极简" || len(f.cfg.Profiles) != 2 {
		t.Fatalf("第二套方案保存失败: active=%q len=%d", f.cfg.ActiveProfile, len(f.cfg.Profiles))
	}

	// 验证菜单栏子菜单与状态行
	status := strings.Join(f.trayStatus(), "\n")
	if !strings.Contains(status, "当前方案：暗色极简") {
		t.Fatalf("trayStatus 缺少当前方案: %s", status)
	}
	items := f.trayItems()
	var profMenu *mygo.MenuItem
	for _, it := range items {
		if strings.HasPrefix(it.Label, "配置方案") {
			profMenu = it
			break
		}
	}
	if profMenu == nil || len(profMenu.Submenu) < 4 {
		t.Fatalf("菜单栏未找到配置方案子菜单: %+v", profMenu)
	}
	// 点「仅切换方案」子菜单里的「日常风景」
	onlySub := profMenu.Submenu[len(profMenu.Submenu)-1]
	if onlySub.Label != "仅切换方案" || len(onlySub.Submenu) != 2 {
		t.Fatalf("仅切换子菜单异常: %+v", onlySub)
	}
	onlySub.Submenu[0].Click(onlySub.Submenu[0], nil)
	f.settle(t, tt, func() bool { return f.cfg.ActiveProfile == "日常风景" })
	if f.cfg.ActiveProfile != "日常风景" || int(f.num) != 150 || int(f.minW) != 3840 ||
		!slices.Equal(f.cfg.FilterAndSampleDirs, []string{"/Volumes/Media0/A"}) {
		t.Fatalf("菜单栏切换方案未生效: active=%q num=%v minW=%v dirs=%v", f.cfg.ActiveProfile, f.num, f.minW, f.cfg.FilterAndSampleDirs)
	}

	// 点菜单栏一级项「暗色极简」触发切换并换一批
	profMenu = nil
	for _, it := range f.trayItems() {
		if strings.HasPrefix(it.Label, "配置方案") {
			profMenu = it
			break
		}
	}
	// Submenu[0] 是禁用小标题，Submenu[1] 是日常风景，Submenu[2] 是暗色极简
	profMenu.Submenu[2].Click(profMenu.Submenu[2], nil)
	f.settle(t, tt, func() bool { return !f.running && f.last != nil })
	if f.cfg.ActiveProfile != "暗色极简" || int(f.num) != 40 {
		t.Fatalf("切换并换一批未切到暗色极简: active=%q num=%v", f.cfg.ActiveProfile, f.num)
	}
	if f.last == nil || f.last.err != nil {
		t.Fatalf("切换并换一批运行失败: %+v", f.last)
	}
}

func TestRemoteProfileSwitch(t *testing.T) {
	h := newRemoteHarness(t)
	tok := h.pair(t, "iPhone")

	dirA := t.TempDir()
	dirB := t.TempDir()
	h.cfg.FilterAndSampleDirs = []string{dirA}
	h.cfg.SampleOnlyDirs = []string{}
	h.cfg.SampleCount = 100
	h.cfg.MinWidth = 3840
	h.cfg.MinHeight = 2160
	h.syncShadowFromConfig()
	if err := h.saveProfile("风景"); err != nil {
		t.Fatal(err)
	}

	h.cfg.FilterAndSampleDirs = []string{}
	h.cfg.SampleOnlyDirs = []string{dirB}
	h.cfg.SampleCount = 25
	h.cfg.MinWidth = 2560
	h.cfg.MinHeight = 1440
	h.cfg.DeleteDuringFilter = false
	h.syncShadowFromConfig()
	if err := h.saveProfile("暗色"); err != nil {
		t.Fatal(err)
	}
	h.tt.Frame()

	// 检查 /api/state 包含方案列表
	code, st := h.do(t, "GET", "/api/state", tok, nil)
	if code != 200 || st["active_profile"] != "暗色" {
		t.Fatalf("state = %d %v", code, st)
	}
	profs, _ := st["profiles"].([]any)
	if len(profs) != 2 {
		t.Fatalf("profiles 应为 2 项: %v", st["profiles"])
	}

	// 参数校验与不存在的方案
	if code, _ := h.do(t, "POST", "/api/profiles/switch", tok, map[string]any{"name": ""}); code != 400 {
		t.Fatalf("空方案名 = %d，应返回 400", code)
	}
	if code, _ := h.do(t, "POST", "/api/profiles/switch", tok, map[string]any{"name": "不存在"}); code != 404 {
		t.Fatalf("不存在方案 = %d，应返回 404", code)
	}

	// 仅切换方案
	code, st = h.do(t, "POST", "/api/profiles/switch", tok, map[string]any{"name": "风景", "run": false})
	if code != 200 || st["active_profile"] != "风景" || st["sample_count"] != float64(100) {
		t.Fatalf("仅切换失败: %d %v", code, st)
	}
	saved, err := core.LoadConfig(h.cfgPath)
	if err != nil || saved.ActiveProfile != "风景" || saved.SampleCount != 100 {
		t.Fatalf("切换后应立即落盘: err=%v cfg=%+v", err, saved)
	}

	// 切换并立即换一批
	release := make(chan struct{})
	h.release = release
	code, st = h.do(t, "POST", "/api/profiles/switch", tok, map[string]any{"name": "暗色", "run": true, "delete": false})
	if code != 200 || st["active_profile"] != "暗色" || st["running"] != true {
		t.Fatalf("切换并运行失败: %d %v", code, st)
	}
	// 运行中禁止再切方案
	if code, _ := h.do(t, "POST", "/api/profiles/switch", tok, map[string]any{"name": "风景"}); code != 409 {
		t.Fatalf("运行中切换 = %d，应返回 409", code)
	}
	close(release)
	h.settle(t, h.tt, func() bool { return !h.running })

	// 切到目录均未挂载的方案并立即运行：方案已切换，但运行应返回 409
	h.cfg.FilterAndSampleDirs = []string{}
	h.cfg.SampleOnlyDirs = []string{filepath.Join(t.TempDir(), "missing")}
	h.syncShadowFromConfig()
	if err := h.saveProfile("离线图库"); err != nil {
		t.Fatal(err)
	}
	h.statDir = func(p string) bool { return !strings.HasSuffix(p, "missing") }
	_ = h.applyProfile("暗色")
	h.tt.Frame()
	code, data := h.do(t, "POST", "/api/profiles/switch", tok, map[string]any{"name": "离线图库", "run": true})
	if code != 409 || !strings.Contains(data["error"].(string), "无法访问") {
		t.Fatalf("离线图库切换并运行应返回 409: %d %v", code, data)
	}
	if h.cfg.ActiveProfile != "离线图库" {
		t.Fatalf("方案本身应已切换成功，实际 %q", h.cfg.ActiveProfile)
	}
	_ = time.Now()
}
