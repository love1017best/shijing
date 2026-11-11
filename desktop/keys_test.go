package main

import (
	"strings"
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestComboRoundTrip(t *testing.T) {
	for _, c := range []struct{ in, str, label string }{
		{"Cmd+Shift+Backspace", "Cmd+Shift+Backspace", "⇧⌘⌫"},
		{"shift+cmd+backspace", "Cmd+Shift+Backspace", "⇧⌘⌫"},
		{"Left", "Left", "←"},
		{"Cmd+.", "Cmd+.", "⌘."},
		{"Ctrl+Alt+K", "Ctrl+Alt+K", "⌃⌥K"},
		{"F5", "F5", "F5"},
	} {
		k, ok := parseCombo(c.in)
		if !ok || k.String() != c.str || k.Label() != c.label {
			t.Errorf("parseCombo(%q) = %q %q %v", c.in, k.String(), k.Label(), ok)
		}
	}
	for _, bad := range []string{"", "Cmd+", "Hyper+K", "Cmd+Nope"} {
		if _, ok := parseCombo(bad); ok {
			t.Errorf("%q 不应解析成功", bad)
		}
	}
	for _, act := range keyActions {
		if _, ok := parseCombo(act.def); !ok {
			t.Errorf("%s 的默认快捷键 %q 解析不了", act.id, act.def)
		}
	}
}

func TestDefaultShortcutsDoNotClash(t *testing.T) {
	f, _ := newFakeApp(t)
	for _, act := range keyActions {
		k, _ := f.combo(act.id)
		if why := f.checkCombo(act.id, k); why != "" {
			t.Errorf("默认的 %s 不合规: %s", act.id, why)
		}
	}
}

func TestCheckCombo(t *testing.T) {
	f, _ := newFakeApp(t)
	must := func(s string) keyCombo { k, _ := parseCombo(s); return k }
	if why := f.checkCombo("next", must("O")); why == "" {
		t.Error("O 已经分给了「用默认应用打开」，应拒绝")
	}
	if why := f.checkCombo("next", must("Escape")); why == "" {
		t.Error("Esc 是固定的，应拒绝")
	}
	if why := f.checkCombo("run", must("R")); why == "" {
		t.Error("菜单命令不带 ⌘ / ⌃ 应拒绝")
	}
	if why := f.checkCombo("next", must("Cmd+R")); why == "" {
		t.Error("⌘R 是「换一批壁纸」的，应拒绝")
	}
	if why := f.checkCombo("next", must("N")); why != "" {
		t.Errorf("N 没人用，应允许: %s", why)
	}
	f.setShortcut("open", "")
	if why := f.checkCombo("next", must("O")); why != "" {
		t.Errorf("「打开」清除后 O 应能用: %s", why)
	}
}

func TestRecordShortcut(t *testing.T) {
	f, tt := newFakeApp(t)
	var menu map[string]string
	f.setMenuKeys = func(m map[string]string) { menu = m }
	f.page = pageKeys
	tt.Frame()
	if !tt.HasText("快捷键") || !tt.HasText("→") || !tt.HasText("⌘R") {
		t.Fatalf("快捷键页应列出默认快捷键: %q", tt.Texts())
	}
	click(t, tt, "下一张 快捷键")
	tt.Frame()
	if f.recording != "next" || menu["run"] != "" {
		t.Fatalf("应开始录制，并撤掉菜单快捷键: recording=%q menu=%q", f.recording, menu)
	}
	tt.KeyDown(ui.KeyO) // 已被「打开」占用
	tt.Frame()
	tt.KeyUp(ui.KeyO)
	tt.Frame()
	if f.recording != "" || f.keyErr == "" || !tt.HasText(f.keyErr) || f.keyLabel("next") != "→" {
		t.Fatalf("冲突时应拒绝并提示: err=%q next=%q", f.keyErr, f.keyLabel("next"))
	}
	click(t, tt, "下一张 快捷键")
	tt.Frame()
	tt.KeyDown(ui.KeyN)
	tt.Frame()
	tt.KeyUp(ui.KeyN)
	tt.Frame()
	if f.keyLabel("next") != "N" || f.buildConfig().Shortcuts["next"] != "N" || menu["run"] != "Cmd+R" {
		t.Fatalf("应改成 N 并恢复菜单快捷键: next=%q cfg=%q menu=%q", f.keyLabel("next"), f.buildConfig().Shortcuts, menu)
	}
	click(t, tt, "下一张 恢复默认")
	tt.Frame()
	if f.keyLabel("next") != "→" || len(f.cfg.Shortcuts) != 0 {
		t.Errorf("恢复默认后应回到 → 且配置里不再记录: %q", f.cfg.Shortcuts)
	}
	click(t, tt, "下一张 快捷键")
	tt.Frame()
	tt.KeyDown(ui.KeyEscape)
	tt.Frame()
	tt.KeyUp(ui.KeyEscape)
	tt.Frame()
	if f.recording != "" || f.keyLabel("next") != "→" {
		t.Error("Esc 应取消录制，不改快捷键")
	}
}

func TestPreviewUsesCustomShortcut(t *testing.T) {
	f, tt := newFakeApp(t)
	f.setShortcut("next", "N")
	f.walls = wallpapers{all: []string{"/w/a.jpg", "/w/b.jpg", "/w/c.jpg"}}
	f.preview, f.previewIdx = true, 0
	tt.Frame()
	tt.Key(0, ui.KeyRight)
	tt.Frame()
	if f.previewIdx != 0 {
		t.Error("改了以后 → 不应再翻页")
	}
	tt.Key(0, ui.KeyN)
	tt.Frame()
	if f.previewIdx != 1 {
		t.Errorf("N 应切到下一张: %d", f.previewIdx)
	}
	found := false
	for _, s := range tt.Texts() {
		found = found || strings.Contains(s, "← N 或空格切换图片")
	}
	if !found {
		t.Errorf("预览说明应显示新的快捷键: %q", tt.Texts())
	}
}
