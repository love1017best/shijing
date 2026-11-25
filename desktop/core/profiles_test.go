package core

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestConfigProfilesLifecycle(t *testing.T) {
	cfg := Defaults()
	cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/风景"}
	cfg.SampleOnlyDirs = []string{"/Volumes/Media0/精选"}
	cfg.DestDir = "~/Pictures/Wallpapers0"
	cfg.SampleCount = 120
	cfg.MinWidth = 3840
	cfg.MinHeight = 2160
	cfg.Mode = "copy"
	cfg.BalanceFirst = true
	cfg.PreferUnseen = true
	cfg.DeleteDuringFilter = true

	// 名称校验
	if _, err := cfg.SaveProfile("   "); err == nil {
		t.Fatal("空白方案名应该报错")
	}
	if _, err := cfg.SaveProfile(strings.Repeat("景", MaxProfileNameRunes+1)); err == nil {
		t.Fatal("超长方案名应该报错")
	}

	// 保存第一套方案
	p1, err := cfg.SaveProfile(" 日常风景 ")
	if err != nil {
		t.Fatalf("SaveProfile 失败: %v", err)
	}
	if p1.Name != "日常风景" || cfg.ActiveProfile != "日常风景" || len(cfg.Profiles) != 1 {
		t.Fatalf("保存后状态异常: p1=%+v active=%q len=%d", p1, cfg.ActiveProfile, len(cfg.Profiles))
	}
	if cfg.ActiveProfileModified() {
		t.Fatal("刚保存的方案不应被标记为已修改")
	}
	if !p1.WillDelete() {
		t.Fatal("开启删除且有筛选目录时 WillDelete 应为 true")
	}

	// 修改当前配置：触发已修改，且不能污染已保存的 p1
	cfg.FilterAndSampleDirs = []string{}
	cfg.SampleOnlyDirs = []string{"/Volumes/Media0/暗色"}
	cfg.SampleCount = 60
	cfg.MinWidth = 5120
	cfg.MinHeight = 2880
	cfg.Mode = "symlink"
	cfg.DeleteDuringFilter = false
	if !cfg.ActiveProfileModified() {
		t.Fatal("修改参数后 ActiveProfileModified 应为 true")
	}
	savedP1, ok := cfg.FindProfile("日常风景")
	if !ok || savedP1.SampleCount != 120 || len(savedP1.FilterAndSampleDirs) != 1 {
		t.Fatalf("修改当前配置不应污染已保存方案: %+v", savedP1)
	}

	// 保存第二套方案
	p2, err := cfg.SaveProfile("暗色极简")
	if err != nil {
		t.Fatalf("SaveProfile(暗色极简) 失败: %v", err)
	}
	if p2.WillDelete() {
		t.Fatal("暗色极简关闭了删除且无筛选目录，WillDelete 应为 false")
	}
	if cfg.ActiveProfile != "暗色极简" || len(cfg.Profiles) != 2 {
		t.Fatalf("第二套方案保存异常: active=%q len=%d", cfg.ActiveProfile, len(cfg.Profiles))
	}

	// 切回第一套方案
	applied, ok := cfg.ApplyProfile("日常风景")
	if !ok {
		t.Fatal("ApplyProfile(日常风景) 应成功")
	}
	if cfg.ActiveProfile != "日常风景" || cfg.SampleCount != 120 || cfg.MinWidth != 3840 || cfg.Mode != "copy" ||
		!slices.Equal(cfg.FilterAndSampleDirs, []string{"/Volumes/Media0/风景"}) ||
		!slices.Equal(cfg.SampleOnlyDirs, []string{"/Volumes/Media0/精选"}) ||
		cfg.ActiveProfileModified() {
		t.Fatalf("套用方案后配置不匹配: applied=%+v cfg=%+v", applied, cfg)
	}

	// 持久化往返
	path := filepath.Join(t.TempDir(), "config.json")
	if err := SaveConfig(path, cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	loaded, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if loaded.ActiveProfile != "日常风景" || !ProfilesEqual(loaded.Profiles, cfg.Profiles) {
		t.Fatalf("持久化往返不一致: loaded=%+v", loaded)
	}

	// 同名覆盖更新
	loaded.SampleCount = 180
	if _, err := loaded.SaveProfile("日常风景"); err != nil {
		t.Fatalf("覆盖更新失败: %v", err)
	}
	if len(loaded.Profiles) != 2 || loaded.ActiveProfileModified() {
		t.Fatalf("覆盖更新后列表长度或修改标记异常: len=%d mod=%v", len(loaded.Profiles), loaded.ActiveProfileModified())
	}

	// 删除当前激活方案应清空 ActiveProfile
	if !loaded.DeleteProfile("日常风景") {
		t.Fatal("DeleteProfile 应返回 true")
	}
	if loaded.ActiveProfile != "" || len(loaded.Profiles) != 1 {
		t.Fatalf("删除当前方案后状态异常: active=%q len=%d", loaded.ActiveProfile, len(loaded.Profiles))
	}
	if loaded.DeleteProfile("不存在") {
		t.Fatal("删除不存在方案应返回 false")
	}
}

func TestLoadConfigClearsOrphanActiveProfile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	cfg := Defaults()
	cfg.ActiveProfile = "已删掉的方案"
	if err := SaveConfig(path, cfg); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ActiveProfile != "" {
		t.Fatalf("悬空 active_profile 应自动清空，实际 %q", loaded.ActiveProfile)
	}
}
