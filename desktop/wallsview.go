package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"
)

// 壁纸页：「壁纸」文件夹里的全部图片，可以按文件名搜索、按原图目录筛选，和手机上的「全部壁纸」页对齐。
// 点一张看大图，右键是同一组整理操作。
const (
	browseThumbWidth = 240 // 壁纸页缩略图的宽度（像素）：格子最窄 168 DIP，够看又不占太多内存
	browseMinCol     = 168 // 一格最窄多宽（DIP），据此算列数
	browseGap        = 12
	browseBatch      = 48 // 每次后台解码几张，解完触发重绘再补下一批
)

func (a *app) wallsPage(c *ui.Context) {
	t := c.Theme()
	// 换了一批之后，上次筛的那个目录可能已经不在了
	if a.wallFolder != "" {
		if _, counts := a.wallFolders(); counts[a.wallFolder] == 0 {
			a.wallFolder = ""
		}
	}
	list := a.filteredWalls()
	pageHeader(c, "壁纸", a.wallsSummary(list), func() {
		if ui.Button(c, "打开文件夹").Clicked() {
			a.openWallpapers()
		}
	})
	a.wallsFilterBar(c)

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

	a.loadBrowseThumbs(list)
	// 编号按 all 的完整顺序算：和大图预览的「N / 总数」、数字键跳转对得上（筛选后也不变）
	numbers := make(map[string]int, len(a.walls.all))
	for i, p := range a.walls.all {
		numbers[p] = i + 1
	}
	grid := ui.Grid(c).Gap(browseGap).Disabled(a.running)
	cols := 6
	if w := grid.LayoutBounds().W; w > 0 {
		cols = max(2, int((w+browseGap)/(browseMinCol+browseGap)))
	}
	if a.running {
		grid.Opacity(0.4).Tooltip("正在换壁纸，这是上一批")
	}
	grid.Columns(cols)
	grid.Children(func() {
		for _, p := range list {
			bmp, tried := a.walls.browse[p]
			cell := ui.Box(c).AspectRatio(stripAspect).Radius(9).Clip().Background(hairline(t)).
				Label(fmt.Sprintf("第 %d 张 %s", numbers[p], filepath.Base(p))).
				Tooltip(fmt.Sprintf("第 %d 张 · %s", numbers[p], filepath.Base(p)))
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
			if a.running {
				continue
			}
			cell.ContextMenu(func(m *ui.Menu) { a.wallMenu(m, p) })
			if cell.Clicked() {
				a.openPreviewOf(p)
			}
		}
	})
}

// wallsSummary 是页面标题下的说明：一共几张、筛选出几张。
func (a *app) wallsSummary(list []string) string {
	if len(a.walls.all) == 0 {
		return ""
	}
	hint := "点一张看大图，右键整理。"
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
