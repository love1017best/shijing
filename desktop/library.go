package main

import (
	"fmt"
	"path/filepath"

	"github.com/egoist/mygo/ui"
)

// ── 图库 ──────────────────────────────────────────────────────────────────

func (a *app) libraryPage(c *ui.Context) {
	pageHeader(c, "图库", "两类目录都会参与采样，区别在于是否先删除不合格的图片。", func() {
		iconButton(c, iconRefresh, "重新检查挂载", false).OnClick(a.checkMounts)
	})
	a.columns(c, 26, func() {
		a.dirSection(c, "filter", "筛选 + 采样", iconScissors,
			"先删除竖屏、正方形、分辨率不足的图片，再参与采样。会直接删除原图，删除记录写在数据目录的删除日志里。", &a.filter)
	}, func() {
		a.dirSection(c, "sample", "仅采样", iconHeart,
			"不删除任何文件，采样时跳过不合格的图片。适合收藏夹这类不想动的目录。", &a.sample)
		a.excludedSection(c)
	}).Disabled(a.running)
}

// commonParent 返回所有目录共同的上级目录（由配置里的目录算出来，不是写死的）；不一致时返回 ""。
func commonParent(dirs []string) string {
	if len(dirs) == 0 {
		return ""
	}
	p := filepath.Dir(filepath.Clean(dirs[0]))
	for _, d := range dirs[1:] {
		if filepath.Dir(filepath.Clean(d)) != p {
			return ""
		}
	}
	return p
}

func (a *app) dirSection(c *ui.Context, key, title string, icon *ui.SVG, desc string, p *dirPanel) {
	t := c.Theme()
	c.Key(key)
	dirs := *p.dirs
	parent := commonParent(dirs)
	sec := ui.Column(c).Gap(10)
	if dropped := sec.DroppedFiles(); len(dropped) > 0 && !a.running {
		a.addDropped(p, dropped)
	}
	sec.Children(func() {
		ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
			ui.Box(c).Size(28, 28).Radius(8).Center().Background(t.Accent.Alpha(0.12)).Children(func() {
				ui.Icon(c, icon).FontSize(15).TextColor(t.Accent)
			})
			ui.Text(c, title).FontSize(16).Bold()
			ui.Text(c, fmt.Sprint(len(dirs))).FontSize(12).TextColor(t.TextMuted)
			ui.Spacer(c)
			if n := p.chosen.Len(); n > 0 {
				remove := "移除"
				if n > 1 {
					remove = fmt.Sprintf("移除 %d 项", n)
				}
				iconButton(c, iconTrash, remove, false).Label(title + " 移除").OnClick(func() { a.removeChosen(p) })
			}
			iconButton(c, iconPlus, "添加目录…", false).Label(title + " 添加").OnClick(func() { a.addDir(p) })
		})
		muted(c, desc).Padding(0, 0, 2, 38)
		// 共同的上级目录单独一行、不折行：拼进说明文字里，长路径会在中间断开
		if parent != "" && len(dirs) > 1 {
			ui.Row(c).Gap(6).AlignItems(ui.Center).Padding(0, 0, 0, 38).Children(func() {
				ui.Icon(c, iconFolderOpen).FontSize(12).TextColor(t.TextMuted)
				ui.Text(c, "都位于 "+parent).FontSize(12).TextColor(t.TextMuted).SingleLine().Tooltip(parent)
			})
		}

		p.list.Key = func(i int) any { return dirs[i] }
		p.list.Label = func(i int) string { return dirs[i] }
		p.list.Selection = &p.chosen
		box := panel(c).Clip()
		if len(dirs) == 0 {
			box.Children(func() {
				ui.Column(c).Height(84).Center().Gap(4).Children(func() {
					ui.Text(c, "还没有目录").FontSize(13).TextColor(t.TextMuted)
					muted(c, "点右上角的「添加目录…」，或者把文件夹拖到这里")
				})
			})
			return
		}
		box.Children(func() {
			ui.List(c, &p.list, len(dirs), func(i int) {
				d := dirs[i]
				ui.Row(c).Gap(12).AlignItems(ui.Center).Padding(9, 14).ContextMenu(func(m *ui.Menu) {
					if m.Item("在 Finder 中打开").Chosen() {
						a.openPath(d)
					}
					m.Separator()
					// 右键的是已选中的多项之一：一起移除；否则只移除这一项
					if n := p.chosen.Len(); n > 1 && p.chosen.Has(d) {
						if m.Item(fmt.Sprintf("移除选中的 %d 项", n)).Danger().Chosen() {
							a.removeChosen(p)
						}
					} else if m.Item("移除").Danger().Chosen() {
						a.removeDir(p, d)
					}
				}).Children(func() {
					ui.Icon(c, iconFolder).FontSize(17).TextColor(t.Accent.Alpha(0.85))
					ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(1).Children(func() {
						ui.Text(c, filepath.Base(d)).FontSize(13.5).SingleLine()
						if parent == "" || len(dirs) == 1 {
							ui.Text(c, filepath.Dir(filepath.Clean(d))).FontSize(11).TextColor(t.TextMuted).SingleLine()
						}
					})
					if st, ok := a.sourceStat(d); ok {
						parts := fmt.Sprintf("%s 张 · %d 个文件夹", humanCount(st.Images), st.Folders)
						if n := a.deletedIn(d); n > 0 {
							parts += fmt.Sprintf(" · 删过 %d 张", n)
						}
						ui.Text(c, parts).FontSize(11.5).TextColor(t.TextMuted).SingleLine().Shrink(0).
							Tooltip("上次成功运行时扫描到的、符合画质要求的图片；删过的张数来自删除记录")
					}
					switch a.mounts[d] {
					case mountOK:
						pill(c, "可访问", t.Success)
					case mountMissing:
						pill(c, "未挂载", t.Danger)
					case mountSlow:
						pill(c, "无响应", t.Warning)
					default:
						pill(c, "检查中", t.TextMuted)
					}
				})
			}).Height(listHeight(len(dirs), parent == "" || len(dirs) == 1)).Padding(4, 0)
		})
		if len(dirs) > 1 {
			muted(c, "按住 ⌘ 点击可以多选；右键可以在 Finder 中打开或移除；也可以把文件夹拖进来添加").Padding(0, 4)
		}
	})
}

// listHeight 让列表按行数长高、全部显示：页面本身会滚动，列表里再套一层滚动会露出半行。
func listHeight(rows int, twoLine bool) float32 {
	row := float32(35)
	if twoLine {
		row = 46
	}
	return float32(rows)*row + 8
}
