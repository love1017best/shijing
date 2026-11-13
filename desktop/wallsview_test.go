package main

import (
	"image"
	"testing"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

func TestWallFolderLabel(t *testing.T) {
	f, _ := newFakeApp(t)
	f.walls = wallpapers{sources: map[string]string{
		"a-1.jpg": "/Volumes/Media0/图库/风景/山/a-1.jpg",
		"a-2.jpg": "/Volumes/Media0/图库/人像/a-2.jpg",
		"a-3.jpg": "/Volumes/Media0/a-3.jpg",
		"a-4.jpg": "/Users/x/Pictures/旧/深/层/a-4.jpg",
	}}
	want := map[string]string{
		"a-1.jpg": "风景/山", // 去掉卷名后最多留两级（和手机一样取最后两级）
		"a-2.jpg": "图库/人像",
		"a-3.jpg": "根目录", // 就在卷根
		"a-4.jpg": "深/层",
	}
	for name, w := range want {
		if got := f.wallFolderOf("/w/" + name); got != w {
			t.Errorf("%s 的目录标签 = %q，想要 %q", name, got, w)
		}
	}
	if got := f.wallFolderOf("/w/没有记录.jpg"); got != "未记录原图" {
		t.Errorf("没有原图记录的壁纸应单独归一组，得到 %q", got)
	}
}

func TestWallsPageSearchFolderAndPreview(t *testing.T) {
	f, tt := newFakeApp(t)
	img := ui.NewBitmap(image.NewRGBA(image.Rect(0, 0, 16, 10)))
	all := []string{"/w/山-01.jpg", "/w/海-02.jpg", "/w/山-03.jpg", "/w/海-04.jpg"}
	browse := map[string]*ui.Bitmap{}
	for _, p := range all {
		browse[p] = img
	}
	f.walls = wallpapers{dir: core.ExpandUser(f.cfg.DestDir), all: all, browse: browse,
		thumbs: map[string]*ui.Bitmap{},
		sources: map[string]string{
			"山-01.jpg": "/Volumes/Media0/图库/风景/山-01.jpg",
			"海-02.jpg": "/Volumes/Media0/图库/风景/海-02.jpg",
			"山-03.jpg": "/Volumes/Media0/图库/人像/山-03.jpg",
			"海-04.jpg": "/Volumes/Media0/图库/人像/海-04.jpg",
		}}
	f.wallsLoadedGen = f.wallsGen
	f.page = pageWalls
	tt.Frame()

	if !tt.HasText("壁纸文件夹里一共 4 张") || !tt.HasText("第 1 张 山-01.jpg") {
		t.Fatalf("壁纸页应列出全部壁纸: %q", tt.Texts())
	}

	// 按文件名搜索
	click(t, tt, "按文件名搜索壁纸")
	tt.Type("山")
	tt.Frame()
	if !tt.HasText("筛选出 2 张，一共 4 张") || tt.HasText("第 2 张 海-02.jpg") {
		t.Errorf("搜索「山」应只剩 2 张，且编号仍按完整顺序: %q", tt.Texts())
	}
	if !tt.HasText("第 1 张 山-01.jpg") || !tt.HasText("第 3 张 山-03.jpg") {
		t.Errorf("搜出来的两张编号应是 1 和 3: %q", tt.Texts())
	}

	// 清除筛选，再按原图目录筛
	click(t, tt, "清除筛选")
	tt.Frame()
	click(t, tt, "全部目录")
	if err := tt.ChooseMenuItem("图库/人像（2）"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if f.wallFolder != "图库/人像" || !tt.HasText("筛选出 2 张，一共 4 张") || tt.HasText("第 1 张 山-01.jpg") {
		t.Errorf("按目录筛选应只剩人像那两张: folder=%q texts=%q", f.wallFolder, tt.Texts())
	}

	// 点一张看大图
	click(t, tt, "第 4 张 海-04.jpg")
	tt.Frame()
	tt.Frame()
	if !f.preview || f.previewIdx != 3 || !tt.HasText("4 / 4") {
		t.Errorf("点缩略图应打开对应的大图: preview=%v idx=%d texts=%q", f.preview, f.previewIdx, tt.Texts())
	}
}
