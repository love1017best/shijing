package main

import (
	"testing"
	"time"

	"desktop/core"
)

func TestDeletedPageFilterChipsAndCollapse(t *testing.T) {
	f, tt := newFakeApp(t)
	core.LogDeletion(f.paths.DeleteLog, "/Volumes/Media0/Lib/a.jpg", 3840, 2160, "竖屏")
	core.LogDeletion(f.paths.DeleteLog, "/Volumes/Media0/Lib/b.jpg", 3840, 2160, "分辨率不足")
	core.LogDeletion(f.paths.DeleteLog, "/Volumes/Media0/Lib/c.jpg", 3840, 2160, core.ReasonManual)
	tt.Frame()
	click(t, tt, "删除记录")
	tt.Frame()
	for _, s := range []string{"a.jpg", "b.jpg", "c.jpg", "共 3 张"} {
		if !tt.HasText(s) {
			t.Fatalf("删除记录页应显示 %q: %q", s, tt.Texts())
		}
	}

	// 只看手动删除
	click(t, tt, "手动删除 1 张")
	tt.Frame()
	if !f.delManual || f.delFilter || tt.HasText("a.jpg") || !tt.HasText("c.jpg") {
		t.Errorf("只看手动删除时应只剩 c.jpg: filter=%v manual=%v %q", f.delFilter, f.delManual, tt.Texts())
	}

	// 再选上筛选删除：两个都选就是全看
	click(t, tt, "筛选删除 2 张")
	tt.Frame()
	if !tt.HasText("a.jpg") || !tt.HasText("c.jpg") {
		t.Errorf("两个标签都选时应看全部: %q", tt.Texts())
	}

	// 两个都取消也回到全部
	click(t, tt, "手动删除 1 张")
	click(t, tt, "筛选删除 2 张")
	tt.Frame()
	if f.delFilter || f.delManual || !tt.HasText("a.jpg") {
		t.Errorf("取消标签后应显示全部: filter=%v manual=%v %q", f.delFilter, f.delManual, tt.Texts())
	}

	// 点日期标题收起、再点展开
	day := time.Now().Format("1月2日")
	click(t, tt, day+"，3 张，点击收起")
	tt.Frame()
	if tt.HasText("a.jpg") || !tt.HasText("点击展开") {
		t.Errorf("点日期标题应收起当天的记录: %q", tt.Texts())
	}
	click(t, tt, day+"，3 张，点击展开")
	tt.Frame()
	if !tt.HasText("a.jpg") || !tt.HasText("点击收起") {
		t.Errorf("再点一次应该展开: %q", tt.Texts())
	}
}
