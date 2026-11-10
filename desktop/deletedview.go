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

	// 概要：一共删了多少、最近一次什么时候
	ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
		pill(c, fmt.Sprintf("共 %s 张", humanCount(len(recs))), t.Danger)
		muted(c, "最近一次 "+recs[0].At.Format("2006年1月2日 15:04"))
	})

	shown := recs[:min(len(recs), deletedShown)]
	for start := 0; start < len(shown); {
		day := shown[start].At.Format("2006-01-02")
		end := start
		for end < len(shown) && shown[end].At.Format("2006-01-02") == day {
			end++
		}
		group := shown[start:end]
		c.Key(day)
		ui.Column(c).Gap(8).Children(func() {
			ui.Row(c).Gap(8).AlignItems(ui.Baseline).Padding(0, 4).Children(func() {
				ui.Text(c, group[0].At.Format("1月2日")).FontSize(13).Bold()
				ui.Text(c, fmt.Sprintf("%d 张", len(group))).FontSize(12).TextColor(t.TextMuted)
			})
			panel(c).Padding(4, 0).Children(func() {
				for i, r := range group {
					c.Key(i)
					a.deletedRow(c, r)
				}
			})
		})
		start = end
	}
	if rest := len(recs) - len(shown); rest > 0 {
		muted(c, fmt.Sprintf("还有 %d 条更早的记录，在日志文件里", rest)).Padding(0, 4)
	}
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
