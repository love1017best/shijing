//go:build darwin

package main

import (
	"path/filepath"
	"testing"
)

// 检查 ImageIO 解码的尺寸和颜色。
func TestSystemDecode(t *testing.T) {
	dir := t.TempDir()
	for _, c := range []struct{ w, h, wantW, wantH int }{
		{800, 400, 200, 100}, // 横图：按宽度缩
		{400, 800, 200, 400}, // 竖图：也是按宽度，不是按长边
		{100, 50, 100, 50},   // 比目标小：不放大
	} {
		p := filepath.Join(dir, "x.png")
		writePNG(t, p, c.w, c.h)
		img := systemDecode(p, 200)
		if img == nil {
			t.Fatalf("%dx%d 解码失败", c.w, c.h)
		}
		if b := img.Bounds(); b.Dx() != c.wantW || b.Dy() != c.wantH {
			t.Errorf("%dx%d 缩到 200 宽应是 %dx%d，实际 %v", c.w, c.h, c.wantW, c.wantH, b)
		}
		if r, g, b, _ := img.At(c.wantW/2, c.wantH/2).RGBA(); r>>8 < 190 || r>>8 > 210 || g != r || b != r {
			t.Errorf("中间应是灰色 200，实际 %d %d %d", r>>8, g>>8, b>>8)
		}
	}
	if systemDecode(filepath.Join(dir, "没有.jpg"), 200) != nil {
		t.Error("不存在的文件应返回 nil")
	}
}
