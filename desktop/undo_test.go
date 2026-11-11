package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"desktop/core"
	"github.com/egoist/mygo/ui"
)

// previewFixture 准备 n 张壁纸（各有原图）并打开预览，停在第一张。
func previewFixture(t *testing.T, names ...string) (*fakeApp, *ui.Tester, []string, map[string]string) {
	f, tt := newFakeApp(t)
	dir := t.TempDir()
	var walls []string
	srcs := map[string]string{}
	for _, n := range names {
		w, s := filepath.Join(dir, "wall", n), filepath.Join(dir, "lib", n)
		for _, p := range []string{w, s} {
			os.MkdirAll(filepath.Dir(p), 0o755)
			os.WriteFile(p, []byte("x"), 0o644)
		}
		walls, srcs[n] = append(walls, w), s
	}
	f.walls = wallpapers{dir: core.ExpandUser(f.cfg.DestDir), total: len(walls), all: slices.Clone(walls), sources: srcs}
	f.wallsLoadedGen = f.wallsGen
	f.preview, f.previewIdx = true, 0
	tt.Frame()
	return f, tt, walls, srcs
}

func TestUndoRemove(t *testing.T) {
	f, tt, walls, srcs := previewFixture(t, "u-a.jpg", "u-b.jpg", "u-c.jpg")
	tt.Key(0, ui.KeyRight)
	tt.Frame()
	tt.Key(0, ui.KeyJ) // 移出 b
	tt.Frame()
	tt.Key(0, ui.KeyK) // 移出 c 并不再选
	tt.Frame()
	if len(f.walls.all) != 1 || !slices.Contains(f.cfg.Excluded, srcs["u-c.jpg"]) {
		t.Fatalf("J、K 后应只剩一张: %q", f.walls.all)
	}
	tt.Key(ui.Cmd, ui.KeyZ)
	tt.Frame()
	if _, err := os.Stat(walls[2]); err != nil || slices.Contains(f.cfg.Excluded, srcs["u-c.jpg"]) {
		t.Fatalf("⌘Z 应放回 c 并去掉不再选: excluded=%q err=%v", f.cfg.Excluded, err)
	}
	if !f.preview || f.walls.all[f.previewIdx] != walls[2] {
		t.Errorf("撤销后预览应停在放回的那张: %q idx=%d", f.walls.all, f.previewIdx)
	}
	tt.Key(ui.Cmd, ui.KeyZ)
	tt.Frame()
	if !slices.Equal(f.walls.all, walls) || f.walls.total != 3 || f.walls.all[f.previewIdx] != walls[1] {
		t.Fatalf("再按 ⌘Z 应放回 b、顺序复原: %q idx=%d", f.walls.all, f.previewIdx)
	}
	tt.Key(ui.Cmd, ui.KeyZ) // 没有可撤销的了，不应出错
	tt.Frame()
	if len(f.walls.all) != 3 {
		t.Error("没有可撤销的移出时 ⌘Z 不应有动作")
	}

	// 关掉预览也能撤销（缩略图右键菜单移出的）
	f.removeWallpaper(walls[0], false)
	f.preview = false
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyZ)
	tt.Frame()
	if _, err := os.Stat(walls[0]); err != nil || len(f.walls.all) != 3 {
		t.Errorf("预览关着时 ⌘Z 也应撤销: %v", err)
	}

	// 开始换一批之后不能再撤销
	f.removeWallpaper(walls[0], false)
	f.clearUndo()
	if _, err := os.Stat(f.undoDir()); !os.IsNotExist(err) || len(f.undo) != 0 {
		t.Error("clearUndo 应清掉暂存")
	}
}

func TestPreviewJumpToNumber(t *testing.T) {
	names := make([]string, 12)
	for i := range names {
		names[i] = string(rune('a'+i)) + ".jpg"
	}
	f, tt, _, _ := previewFixture(t, names...)
	tt.Key(0, ui.Key1)
	tt.Key(0, ui.Key1)
	tt.Frame()
	if f.previewIdx != 0 || !tt.HasText("跳到第 11 张 ↩") {
		t.Fatalf("输入编号时应先显示、不跳: idx=%d %q", f.previewIdx, tt.Texts())
	}
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if f.previewIdx != 10 || f.jumpBuf != "" {
		t.Fatalf("回车应跳到第 11 张: idx=%d", f.previewIdx)
	}
	tt.Key(0, ui.Key9)
	tt.Key(0, ui.Key9)
	tt.Key(0, ui.KeyBackspace)
	tt.Frame()
	if f.jumpBuf != "9" || len(f.walls.all) != 12 {
		t.Fatalf("⌫ 应删掉一位而不是移出: buf=%q", f.jumpBuf)
	}
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	if f.jumpBuf != "" || !f.preview {
		t.Fatal("Esc 应只放弃输入的编号，不关预览")
	}
	tt.Key(0, ui.Key5)
	tt.Key(0, ui.Key0)
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if f.previewIdx != 10 {
		t.Errorf("超出范围的编号不应跳: idx=%d", f.previewIdx)
	}
	tt.Key(0, ui.Key0) // 开头的 0 不算
	tt.Key(0, ui.Key3)
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if f.previewIdx != 2 {
		t.Errorf("应跳到第 3 张: idx=%d", f.previewIdx)
	}
	tt.Key(0, ui.KeyEscape)
	tt.Frame()
	if f.preview {
		t.Error("没在输入编号时 Esc 应关闭预览")
	}
}
