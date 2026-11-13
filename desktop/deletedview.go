package main

import (
	"fmt"
	"path/filepath"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

// deletedShown 是删除记录页最多列出多少条（更早的在日志文件里）。
const deletedShown = 500

// deletedPage 列出删除日志里的记录：删掉的是 NAS 上的原图、不可撤销，需要能回头查删了什么、在哪、为什么。
// 顶上两个标签可以只看筛选删的、只看手动删的（也能都选，等于全看），每天的记录点标题能收起来。
func (a *app) deletedPage(c *ui.Context) {
	t := c.Theme()
	recs := a.deleteRecords()
	pageHeader(c, "删除记录", "筛选和手动删除的原图都记在这里。删除不可撤销，需要恢复时按路径到备份里找。", func() {
		iconButton(c, iconExternal, "显示日志文件", false).OnClick(func() { a.openPath(filepath.Dir(a.paths.DeleteLog)) })
	})
	if len(recs) == 0 {
		panel(c).Children(func() {
			ui.Column(c).Height(120).Center().Gap(6).Children(func() {
				ui.Icon(c, iconTrash).FontSize(22).TextColor(t.TextMuted)
				ui.Text(c, "还没有删除过图片").FontSize(13).TextColor(t.TextMuted)
			})
		})
		return
	}

	// 两个类型标签（点一下只看这类，再点取消）+ 数量和最近一次
	byFilter, manual := core.CountDeletions(recs)
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		a.delTypeChip(c, "筛选删除", byFilter, &a.delFilter, "筛选时按规则删掉的（竖屏、接近正方形、分辨率不足）")
		a.delTypeChip(c, "手动删除", manual, &a.delManual, "在预览、右键菜单或手机上点「删除图库里的原图」删掉的")
		ui.Spacer(c)
		muted(c, fmt.Sprintf("共 %s 张 · 最近一次 %s", humanCount(len(recs)), recs[0].At.Format("2006年1月2日 15:04")))
	})

	shownRecs := recs
	if a.delFilter || a.delManual {
		shownRecs = nil
		for _, r := range recs {
			if (r.Manual() && a.delManual) || (!r.Manual() && a.delFilter) {
				shownRecs = append(shownRecs, r)
			}
		}
		if len(shownRecs) == 0 {
			panel(c).Children(func() {
				ui.Column(c).Height(96).Center().Children(func() { muted(c, "没有符合筛选的记录。") })
			})
			return
		}
	}

	shown := shownRecs[:min(len(shownRecs), deletedShown)]
	for start := 0; start < len(shown); {
		day := shown[start].At.Format("2006-01-02")
		end := start
		for end < len(shown) && shown[end].At.Format("2006-01-02") == day {
			end++
		}
		group := shown[start:end]
		closed := a.delClosed[day]
		c.Key(day)
		ui.Column(c).Gap(8).Children(func() {
			state := "点击收起"
			if closed {
				state = "点击展开"
			}
			// ToggleBase 就是「能点、能按空格」的一行，样子自己画：箭头跟着 a.delClosed 走
			head := ui.ToggleBase(c, &closed).Row().Gap(8).AlignItems(ui.Center).Padding(0, 4).
				Cursor(ui.CursorPointer).
				Label(fmt.Sprintf("%s，%d 张，%s", group[0].At.Format("1月2日"), len(group), state))
			head.Children(func() {
				ui.Text(c, group[0].At.Format("1月2日")).FontSize(13).Bold()
				ui.Text(c, fmt.Sprintf("%d 张", len(group))).FontSize(12).TextColor(t.TextMuted)
				ui.Spacer(c)
				icon := iconChevronDown
				if closed {
					icon = iconChevronRight
				}
				ui.Icon(c, icon).FontSize(13).TextColor(t.TextMuted)
			})
			if closed != a.delClosed[day] {
				if a.delClosed == nil {
					a.delClosed = map[string]bool{}
				}
				a.delClosed[day] = closed
			}
			if closed {
				return
			}
			panel(c).Padding(4, 0).Children(func() {
				for i, r := range group {
					c.Key(i)
					a.deletedRow(c, r)
				}
			})
		})
		start = end
	}
	if rest := len(shownRecs) - len(shown); rest > 0 {
		muted(c, fmt.Sprintf("还有 %d 条更早的记录，在日志文件里", rest)).Padding(0, 4)
	}
}

// delTypeChip 是删除记录页的一个类型标签：点一下（或聚焦后按空格）只看这类，再点取消；两个都关着等于全部。
func (a *app) delTypeChip(c *ui.Context, title string, n int, on *bool, tip string) {
	t := c.Theme()
	bg, fg := t.TextMuted.Alpha(0.12), t.Text
	if *on {
		bg, fg = t.Accent, ui.RGB(255, 255, 255)
	}
	chip := ui.ToggleBase(c, on).Row().AlignItems(ui.Center).Gap(6).Padding(5, 10).Radius(14).
		Background(bg).Cursor(ui.CursorPointer).Tooltip(tip).Label(fmt.Sprintf("%s %d 张", title, n))
	chip.Children(func() {
		ui.Text(c, title).FontSize(12).Bold().TextColor(fg)
		ui.Text(c, fmt.Sprint(n)).FontSize(11).TextColor(fg.Alpha(0.82))
	})
}

func (a *app) deletedRow(c *ui.Context, r core.DeleteRecord) {
	t := c.Theme()
	dir := filepath.Dir(r.Path)
	row := ui.Row(c).Gap(10).AlignItems(ui.Center).Padding(7, 14)
	row.ContextMenu(func(m *ui.Menu) {
		if m.Item("在 Finder 中打开所在文件夹").Chosen() {
			a.openPath(dir)
		}
		if m.Item("拷贝完整路径").Chosen() {
			c.WriteClipboard(r.Path)
			a.toast = "已拷贝路径"
		}
	}).Children(func() {
		ui.Icon(c, iconTrash).FontSize(12).TextColor(t.Danger.Alpha(0.8))
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(1).Children(func() {
			ui.Row(c).Gap(8).AlignItems(ui.Baseline).MinWidth(0).Children(func() {
				ui.Text(c, filepath.Base(r.Path)).Font("Menlo").FontSize(12).SingleLine().Shrink(1)
				if r.Reason != "" {
					ui.Text(c, r.Reason).FontSize(11.5).TextColor(t.Warning).SingleLine().Shrink(0)
				}
			})
			ui.Text(c, tildify(dir)).FontSize(11).TextColor(t.TextMuted).SingleLine().Tooltip(dir)
		})
		ui.Text(c, r.At.Format("15:04")).FontSize(11.5).TextColor(t.TextMuted).Shrink(0)
	})
}

// excludedSection 是图库页底部的排除名单：在概览页缩略图上「不再选它」的原图，可以恢复。
func (a *app) excludedSection(c *ui.Context) {
	t := c.Theme()
	if len(a.cfg.Excluded) == 0 {
		return
	}
	c.Key("excluded")
	ui.Column(c).Gap(10).Children(func() {
		ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
			ui.Box(c).Size(28, 28).Radius(8).Center().Background(t.TextMuted.Alpha(0.12)).Children(func() {
				ui.Icon(c, iconXCircle).FontSize(15).TextColor(t.TextMuted)
			})
			ui.Text(c, "不再选的图片").FontSize(16).Bold()
			ui.Text(c, fmt.Sprint(len(a.cfg.Excluded))).FontSize(12).TextColor(t.TextMuted)
			ui.Spacer(c)
			ui.Button(c, "全部恢复").OnClick(func() { a.cfg.Excluded = []string{} })
		})
		muted(c, "在概览页缩略图上选了「移除并不再选它」的原图，采样时会跳过。原图没有删除。").Padding(0, 0, 2, 38)
		panel(c).Padding(4, 0).Children(func() {
			for i, p := range a.cfg.Excluded {
				c.Key(p)
				ui.Row(c).Gap(10).AlignItems(ui.Center).Padding(7, 14).Children(func() {
					ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(1).Children(func() {
						ui.Text(c, filepath.Base(p)).Font("Menlo").FontSize(12).SingleLine()
						ui.Text(c, tildify(filepath.Dir(p))).FontSize(11).TextColor(t.TextMuted).SingleLine().Tooltip(p)
					})
					ui.Button(c, "恢复").Label("恢复 " + filepath.Base(p)).OnClick(func() {
						a.cfg.Excluded = append(a.cfg.Excluded[:i:i], a.cfg.Excluded[i+1:]...)
					})
				})
			}
		})
	})
}
