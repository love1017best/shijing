package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"
)

// 壁纸页：「壁纸」文件夹里的全部图片，可以按文件名搜索、按原图目录筛选，和手机上的「全部壁纸」页对齐。
// 点一张看大图，右键是同一组整理操作；点「选择」进入多选，可以一次移出 / 不再选一批。
// 网格用 GridView（只构建看得见的行），几百张也不至于每帧把所有格子都排一遍。
const (
	browseThumbWidth = 240 // 壁纸页缩略图的宽度（像素）：格子最窄 168 DIP，够看又不占太多内存
	browseMinCol     = 168 // 一格最窄多宽（DIP），据此算列数
	browseBatch      = 48  // 每次后台解码几张，解完触发重绘再补下一批
)

func (a *app) wallsPage(c *ui.Context) {
	// 换了一批之后，上次筛的那个目录可能已经不在了
	if a.wallFolder != "" {
		if _, counts := a.wallFolders(); counts[a.wallFolder] == 0 {
			a.wallFolder = ""
		}
	}
	a.pruneWallSel()
	list := a.filteredWalls()

	head := ui.Column(c).Gap(22).Children(func() {
		pageHeader(c, "壁纸", a.wallsSummary(list), func() {
			if a.wallSelecting {
				if ui.Button(c, "完成").Clicked() {
					a.endWallSelection()
				}
			} else if ui.Button(c, "选择").Clicked() {
				a.wallSelecting = true
			}
			if ui.Button(c, "打开文件夹").Clicked() {
				a.openWallpapers()
			}
		})
		a.wallsFilterBar(c)
	})
	a.wallHeadH = head.LayoutBounds().H

	switch {
	case len(a.walls.all) == 0 && a.walls.loading:
		muted(c, "正在读取壁纸文件夹…")
		return
	case len(a.walls.all) == 0:
		muted(c, "壁纸文件夹里还没有图片。在概览页换一批试试。")
		return
	case len(list) == 0:
		muted(c, "没有匹配的壁纸。")
		return
	}

	// 筛选变了就把网格滚回顶部（否则停在上一次的位置，看起来像空了）
	key := a.wallQuery + "\x00" + a.wallFolder
	if key != a.wallFilterKey {
		a.wallFilterKey = key
		a.wallGrid.ScrollTo(0, ui.Start)
	}
	if a.wallSelecting && c.Shortcut(0, ui.KeyEscape) {
		a.endWallSelection()
	}

	a.loadBrowseThumbs(list)
	// 编号按 all 的完整顺序算：和大图预览的「N / 总数」、数字键跳转对得上（筛选后也不变）
	numbers := make(map[string]int, len(a.walls.all))
	for i, p := range a.walls.all {
		numbers[p] = i + 1
	}

	// 网格占满窗口剩下的高度，自己滚动；行高按这一帧的宽度算（和 GridView 的列宽同一套算法）
	gap := c.Theme().Space(2)
	gw := max(200, a.viewW-72)
	cols := max(2, int((gw+gap)/(browseMinCol+gap)))
	cellH := (gw - gap*float32(cols-1)) / float32(cols) / stripAspect
	gridH := a.viewH - a.wallHeadH - 22 - 32 - a.wallBarH
	if a.wallSelecting {
		gridH -= 22
	}
	gridH = max(160, gridH)

	grid := ui.GridView(c, &a.wallGrid, len(list), browseMinCol, cellH, func(i int) {
		a.wallCell(c, list[i], numbers[list[i]])
	}).Height(gridH)
	if a.running {
		grid.Disabled(true).Opacity(0.4).Tooltip("正在换壁纸，这是上一批")
	}
	a.wallsSelectionBar(c, list)
}

// wallCell 是壁纸页的一格：缩略图、勾选圈（选择模式下）、右键菜单。
func (a *app) wallCell(c *ui.Context, p string, number int) {
	t := c.Theme()
	bmp, tried := a.walls.browse[p]
	selected := a.wallSel[p]
	cell := ui.Box(c).Fill().Radius(9).Clip().Background(hairline(t)).
		Label(fmt.Sprintf("第 %d 张 %s", number, filepath.Base(p))).
		Tooltip(fmt.Sprintf("第 %d 张 · %s", number, filepath.Base(p)))
	if selected {
		cell.Border(2, t.Accent)
	} else if a.wallSelecting {
		cell.Border(1, hairline(t))
	}
	if bmp != nil {
		cell.Cursor(ui.CursorPointer).Children(func() {
			ui.Image(c, bmp).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(ui.Cover)
		})
	} else if tried {
		// 解码过了但读不了：说明白，别留一块空白
		cell.Center().Children(func() {
			ui.Text(c, "读不了").FontSize(11).TextColor(t.TextMuted)
		})
	}
	if a.wallSelecting {
		ui.Box(c).Absolute().Top(6).Right(6).Size(20, 20).Radius(10).Border(1, ui.RGBA(255, 255, 255, 0.85)).
			Background(selectedBg(selected, t)).Center().Children(func() {
			if selected {
				ui.Icon(c, iconCheckSmall).FontSize(12).TextColor(ui.RGB(255, 255, 255))
			}
		})
	}
	if a.running {
		return
	}
	cell.ContextMenu(func(m *ui.Menu) {
		a.wallMenu(m, p)
		m.Separator()
		if m.Item("批量选择…").Chosen() {
			a.wallSelecting = true
			a.wallSel = map[string]bool{p: true}
		}
	})
	if cell.Clicked() {
		if a.wallSelecting {
			a.toggleWallSel(p)
		} else {
			a.openPreviewOf(p)
		}
	}
}

// selectedBg 是勾选圈的底色：选中是强调色，没选是半透明黑。
func selectedBg(selected bool, t *ui.Theme) ui.Color {
	if selected {
		return t.Accent
	}
	return ui.RGBA(0, 0, 0, 0.35)
}

// wallsSelectionBar 是多选时的操作条：全选 / 取消 / 批量移出 / 批量不再选。不做批量删除原图，不可撤销的事一张一张来。
func (a *app) wallsSelectionBar(c *ui.Context, list []string) {
	if !a.wallSelecting {
		a.wallBarH = 0
		return
	}
	n := len(a.wallSel)
	bar := panel(c).Row().AlignItems(ui.Center).Gap(10).Padding(10, 14).Children(func() {
		ui.Text(c, fmt.Sprintf("已选 %d 张", n)).FontSize(13).Bold()
		ui.Spacer(c)
		if ui.Button(c, "全选").Tooltip("选中当前筛选出来的全部壁纸").Clicked() {
			if a.wallSel == nil {
				a.wallSel = map[string]bool{}
			}
			for _, p := range list {
				a.wallSel[p] = true
			}
		}
		if ui.Button(c, "取消").Clicked() {
			a.endWallSelection()
		}
		remove := ui.Button(c, fmt.Sprintf("移出 %d 张", n)).Disabled(n == 0)
		if remove.Clicked() {
			a.removeSelectedWalls(false)
		}
		exclude := ui.Button(c, fmt.Sprintf("不再选 %d 张", n)).Disabled(n == 0)
		if exclude.Clicked() {
			a.removeSelectedWalls(true)
		}
	})
	a.wallBarH = bar.LayoutBounds().H
}

// toggleWallSel 勾选 / 取消勾选一张。
func (a *app) toggleWallSel(p string) {
	if a.wallSel == nil {
		a.wallSel = map[string]bool{}
	}
	if a.wallSel[p] {
		delete(a.wallSel, p)
	} else {
		a.wallSel[p] = true
	}
}

// pruneWallSel 去掉已经不在壁纸文件夹里的勾选（单张移出、换了一批之后）。
func (a *app) pruneWallSel() {
	if len(a.wallSel) == 0 {
		return
	}
	live := make(map[string]bool, len(a.walls.all))
	for _, p := range a.walls.all {
		live[p] = true
	}
	for p := range a.wallSel {
		if !live[p] {
			delete(a.wallSel, p)
		}
	}
}

// endWallSelection 退出选择模式并清掉勾选。
func (a *app) endWallSelection() {
	a.wallSelecting = false
	a.wallSel = nil
}

// removeSelectedWalls 把勾选的壁纸一次移出（原图保留，exclude 时还加进「不再选」）。
// 每张各推一条撤销记录，⌘Z 一次撤回一张。
func (a *app) removeSelectedWalls(exclude bool) {
	var todo []string
	for _, p := range a.walls.all {
		if a.wallSel[p] {
			todo = append(todo, p)
		}
	}
	if len(todo) == 0 {
		return
	}
	for _, p := range todo {
		a.removeWallpaper(p, exclude)
	}
	a.endWallSelection()
	if exclude {
		a.toast = fmt.Sprintf("已移出 %d 张，原图都还在图库里；以后采样会跳过它们", len(todo))
	} else {
		a.toast = fmt.Sprintf("已移出 %d 张，原图都还在图库里（⌘Z 一次撤回一张）", len(todo))
	}
}

// wallsSummary 是页面标题下的说明：一共几张、筛选出几张。
func (a *app) wallsSummary(list []string) string {
	if len(a.walls.all) == 0 {
		return ""
	}
	hint := "点一张看大图，右键整理。"
	if a.wallSelecting {
		hint = "点格子勾选，选好后用下面的按钮一次移出。"
	}
	if len(list) == len(a.walls.all) {
		return fmt.Sprintf("壁纸文件夹里一共 %d 张，%s", len(list), hint)
	}
	return fmt.Sprintf("筛选出 %d 张，一共 %d 张，%s", len(list), len(a.walls.all), hint)
}

// wallsFilterBar 是搜索框和目录筛选。
func (a *app) wallsFilterBar(c *ui.Context) {
	if len(a.walls.all) == 0 {
		return
	}
	folders, counts := a.wallFolders()
	ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
		ui.SearchField(c, &a.wallQuery).Grow(1).Label("按文件名搜索壁纸").Placeholder("按文件名搜索")
		label := "全部目录"
		if a.wallFolder != "" {
			label = fmt.Sprintf("%s（%d）", a.wallFolder, counts[a.wallFolder])
		}
		ui.MenuButton(c, label, func(m *ui.Menu) {
			if m.Item("全部目录").Checked(a.wallFolder == "").Chosen() {
				a.wallFolder = ""
			}
			if len(folders) > 0 {
				m.Separator()
			}
			for _, f := range folders {
				if m.Item(fmt.Sprintf("%s（%d）", f, counts[f])).Checked(a.wallFolder == f).Chosen() {
					a.wallFolder = f
				}
			}
		}).Label("按原图目录筛选")
		if a.wallQuery != "" || a.wallFolder != "" {
			if ui.Button(c, "清除筛选").Clicked() {
				a.wallQuery, a.wallFolder = "", ""
			}
		}
	})
}

// filteredWalls 是按搜索词和目录筛选后的壁纸，保持 all 的顺序。搜索按文件名、不区分大小写。
func (a *app) filteredWalls() []string {
	q := strings.ToLower(strings.TrimSpace(a.wallQuery))
	if q == "" && a.wallFolder == "" {
		return a.walls.all
	}
	out := make([]string, 0, len(a.walls.all))
	for _, p := range a.walls.all {
		if q != "" && !strings.Contains(strings.ToLower(filepath.Base(p)), q) {
			continue
		}
		if a.wallFolder != "" && a.wallFolderOf(p) != a.wallFolder {
			continue
		}
		out = append(out, p)
	}
	return out
}

// wallFolders 列出壁纸按原图目录分组的目录名和张数（筛选菜单用）。
func (a *app) wallFolders() ([]string, map[string]int) {
	counts := map[string]int{}
	var folders []string
	for _, p := range a.walls.all {
		f := a.wallFolderOf(p)
		if counts[f] == 0 {
			folders = append(folders, f)
		}
		counts[f]++
	}
	slices.Sort(folders)
	return folders, counts
}

// wallFolderOf 是这张壁纸的原图所在的图库目录：去掉 /Volumes/<卷名> 后最多留两级
// （和手机「全部壁纸」的 folderName 一样）。旧版本换上的没有原图记录，单独归一组。
func (a *app) wallFolderOf(wall string) string {
	src := a.wallSource(wall)
	if src == "" {
		return "未记录原图"
	}
	parts := strings.Split(filepath.Dir(src), "/")
	parts = slices.DeleteFunc(parts, func(s string) bool { return s == "" })
	if len(parts) >= 2 && parts[0] == "Volumes" {
		parts = parts[2:]
	}
	if len(parts) > 2 {
		parts = parts[len(parts)-2:]
	}
	if len(parts) == 0 {
		return "根目录"
	}
	return strings.Join(parts, "/")
}
