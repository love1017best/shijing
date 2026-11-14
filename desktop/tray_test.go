package main

import (
	"bytes"
	"errors"
	"image/png"
	"slices"
	"strings"
	"testing"
	"time"

	"desktop/core"

	"github.com/egoist/mygo"
)

func TestTrayStatusWithoutDirs(t *testing.T) {
	f, _ := newFakeApp(t)
	lines := f.trayStatus()
	if len(lines) != 2 || lines[0] != "图库：还没有添加目录" || lines[1] != "上次运行：还没有运行过" {
		t.Fatalf("状态 = %v", lines)
	}
}

func TestTrayStatusRunAndMounts(t *testing.T) {
	f, _ := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/A", "/Volumes/B"}
	f.cfg.DestDir = "/tmp/wall"
	f.mounts["/Volumes/A"] = mountOK
	f.mounts["/Volumes/B"] = mountMissing
	f.last = &runResult{
		at:  time.Date(2026, 11, 14, 8, 12, 0, 0, time.Local),
		sum: core.Summary{Copy: core.CopyResult{Copied: 400}},
	}
	lines := f.trayStatus()
	want := []string{"图库：1 个目录没连上", "上次运行：换上 400 张 · 11月14日 08:12"}
	if strings.Join(lines, "|") != strings.Join(want, "|") {
		t.Fatalf("状态 = %v", lines)
	}

	// 运行中显示进度，而不是上次结果
	f.running = true
	f.prog = progress{stage: core.StageCopy, done: 3, total: 10}
	lines = f.trayStatus()
	if len(lines) != 2 || lines[1] != "正在换壁纸 · 复制 3 / 10 张" {
		t.Fatalf("运行中的状态 = %v", lines)
	}

	// 上次被停止、失败
	f.running = false
	f.last = &runResult{at: time.Now(), err: core.ErrCanceled}
	if lines = f.trayStatus(); lines[1] != "上次运行：已停止 · "+f.last.at.Format("1月2日 15:04") {
		t.Fatalf("停止后的状态 = %v", lines)
	}
	f.last = &runResult{at: time.Now(), err: errors.New("图库没挂上")}
	if lines = f.trayStatus(); !strings.HasPrefix(lines[1], "上次运行：失败 · ") {
		t.Fatalf("失败后的状态 = %v", lines)
	}
}

func TestTrayStatusAutoRun(t *testing.T) {
	f, _ := newFakeApp(t)
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/A"}
	f.mounts["/Volumes/A"] = mountOK
	if lines := f.trayStatus(); len(lines) != 2 {
		t.Fatalf("没开自动换时不该有那一行: %v", lines)
	}
	f.autoIdx = slices.Index(autoRunHours, 24)
	lines := f.trayStatus()
	if len(lines) != 3 || !strings.HasPrefix(lines[2], "下次自动换：") {
		t.Fatalf("开了自动换的状态 = %v", lines)
	}
}

func TestTrayItems(t *testing.T) {
	f, _ := newFakeApp(t)
	labels := func(items []*mygo.MenuItem) string {
		out := make([]string, len(items))
		for i, it := range items {
			out[i] = it.Label
		}
		return strings.Join(out, "|")
	}

	// 还没有添加图库目录：换一批、打开壁纸文件夹都不能点
	f.cfg.DestDir = ""
	items := f.trayItems()
	want := "打开主界面||图库：还没有添加目录|上次运行：还没有运行过||换一批壁纸|打开壁纸文件夹||退出拾景"
	if got := labels(items); got != want {
		t.Fatalf("菜单 = %s", got)
	}
	if !items[5].Disabled || !items[6].Disabled {
		t.Fatalf("没配好时不该能点：换一批 %v、打开壁纸文件夹 %v", items[5].Disabled, items[6].Disabled)
	}

	// 图库连着、壁纸文件夹也设了：「换一批壁纸」「打开壁纸文件夹」能点
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/A"}
	f.cfg.DestDir = "/tmp/wall"
	f.mounts["/Volumes/A"] = mountOK
	items = f.trayItems()
	if items[5].Disabled || items[6].Disabled {
		t.Fatal("图库连着、设了壁纸文件夹时应该能点")
	}

	// 运行中换成「停止」
	f.running = true
	items = f.trayItems()
	if items[5].Label != "停止" {
		t.Fatalf("运行中的菜单 = %v", labels(items))
	}

	// 三个动作各自连到对的地方
	f.running = false
	shown, opened := 0, ""
	f.showWindow = func() { shown++ }
	f.openPath = func(p string) { opened = p }
	items = f.trayItems()
	items[0].Click(nil, nil)
	items[6].Click(nil, nil)
	if shown != 1 || opened != "/tmp/wall" {
		t.Fatalf("打开主界面 %d 次、打开壁纸文件夹 %q", shown, opened)
	}
}

func TestTrayIconIsTemplatePNG(t *testing.T) {
	data, err := trayIcon()
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if b := img.Bounds(); b.Dx() != 32 || b.Dy() != 32 {
		t.Fatalf("图标尺寸 = %v", b)
	}
	// 模板图：有画到的地方是黑的，其余透明；不能整张空白
	ink, clear := 0, 0
	for y := range img.Bounds().Dy() {
		for x := range img.Bounds().Dx() {
			r, g, b, a := img.At(x, y).RGBA()
			switch {
			case a == 0:
				clear++
			case r == 0 && g == 0 && b == 0:
				ink++
			default:
				t.Fatalf("(%d,%d) 不是黑 + 透明: %x", x, y, img.At(x, y))
			}
		}
	}
	if ink < 100 || clear < 100 {
		t.Fatalf("图标画得不对：黑 %d 个像素、透明 %d 个像素", ink, clear)
	}
}
