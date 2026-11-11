package main

import (
	"fmt"
	"path/filepath"

	"github.com/egoist/mygo/ui"
)

// ── 设置 ──────────────────────────────────────────────────────────────────

// pathInput 是「输入框 + 选择按钮」。
func (a *app) pathInput(c *ui.Context, value *string, label, dialogTitle string) {
	ui.Row(c).Gap(8).Children(func() {
		ui.TextInput(c, value).Grow(1).Label(label)
		if ui.Button(c, "选择…").Label(label + " 选择").Clicked() {
			a.browse(dialogTitle, func(p string) { *value = p })
		}
	})
}

func (a *app) settingsPage(c *ui.Context) {
	t := c.Theme()
	pageHeader(c, "设置", "改动会立即自动保存，下次运行生效。", nil)
	a.columns(c, 24, func() {
		group(c, "输出", "",
			func() {
				wideRow(c, "壁纸文件夹", "每次运行会先清空这个文件夹，再放入新选出的图片。系统壁纸幻灯片指向这里。", func() {
					a.pathInput(c, &a.cfg.DestDir, "壁纸文件夹", "选择壁纸文件夹")
				})
			},
			func() {
				settingRow(c, "存放方式", "复制占用磁盘空间但可以脱离图库使用；软链接省空间，但图库没挂载时壁纸会失效。", func(ui.Element) {
					ui.Segmented(c, &a.modeIdx, "复制", "软链接")
				})
			})

		group(c, "采样", "",
			func() {
				desc := ""
				if per, total := a.estimateBytes(int(a.num)); total > 0 && a.modeIdx == 0 {
					desc = fmt.Sprintf("按上一轮平均每张 %s 算，大约占 %s", humanBytes(per), humanBytes(total))
				}
				settingRow(c, "每次张数", desc, func(ui.Element) {
					ui.NumberInput(c, &a.num, 1, 9999, 10).Width(150).Label("每次张数")
				})
			},
			func() {
				settingRow(c, "平衡采样", "优先让每个子文件夹至少入选一张，避免少数几个大文件夹占满名额。", func(l ui.Element) {
					ui.Switch(c, &a.cfg.BalanceFirst).LabelledBy(l)
				})
			},
			func() {
				desc := "先从这一轮里还没换上过的图里选，整个图库都换上过一遍后再开始新一轮，减少和前几次重复。"
				if g := a.lastGood; g != nil && g.Copy.Rotated > 0 && g.Copy.Candidates > 0 {
					desc += fmt.Sprintf("\n这一轮已换上过 %s / %s 张（%.0f%%）。", humanCount(g.Copy.Rotated), humanCount(g.Copy.Candidates),
						float64(g.Copy.Rotated)/float64(g.Copy.Candidates)*100)
				}
				settingRow(c, "优先选没换上过的", desc, func(l ui.Element) {
					ui.Switch(c, &a.cfg.PreferUnseen).LabelledBy(l)
				})
			})

		custom := a.preset >= len(resPresets)
		resRows := []func(){
			func() {
				desc := fmt.Sprintf("%d × %d", int(a.minW), int(a.minH))
				if custom {
					desc = "在下面填写宽和高"
				}
				settingRow(c, "最低分辨率", desc, func(ui.Element) {
					labels := make([]string, 0, len(resPresets)+1)
					for _, p := range resPresets {
						labels = append(labels, p.label)
					}
					labels = append(labels, "自定义")
					if ui.Segmented(c, &a.preset, labels...).Changed() && a.preset < len(resPresets) {
						a.minW, a.minH = float64(resPresets[a.preset].w), float64(resPresets[a.preset].h)
					}
				})
			},
		}
		if custom {
			resRows = append(resRows, func() {
				settingRow(c, "宽 × 高", "单位是像素。", func(ui.Element) {
					ui.NumberInput(c, &a.minW, 1, 99999, 1).Width(130).Label("最小宽度")
					ui.Text(c, "×").TextColor(t.TextMuted)
					ui.NumberInput(c, &a.minH, 1, 99999, 1).Width(130).Label("最小高度")
				})
			})
		}
		group(c, "画质要求", "只有横屏（宽高比大于 1.1）且不低于这个分辨率的图片才会被选中。", resRows...)
		a.archiveGroup(c)
	}, func() {

		group(c, "筛选", "只作用于「筛选 + 采样」目录。",
			func() {
				desc := "关闭后只是模拟运行：日志里列出哪些图片不合格，但不删除文件。"
				if a.cfg.DeleteDuringFilter {
					desc = "已开启：不合格的原图会被直接删除，不可撤销。关闭后只模拟运行。"
				}
				settingRow(c, "删除不合格原图", desc, func(l ui.Element) {
					if a.cfg.DeleteDuringFilter {
						ui.Icon(c, iconAlert).FontSize(14).TextColor(t.Warning)
					}
					ui.Switch(c, &a.cfg.DeleteDuringFilter).LabelledBy(l)
				})
			},
			func() {
				settingRow(c, "增量筛选", "跳过上次检查后没有变化的文件夹，只检查新增或修改过的。", func(l ui.Element) {
					ui.Switch(c, &a.cfg.Incremental).LabelledBy(l)
				})
			})

		group(c, "自动换壁纸", "应用开着时（关掉窗口后会在后台继续运行）按这个间隔自动换一批。自动运行不会删除原图，筛选只模拟；删除只在手动点「换一批壁纸」时发生。",
			func() {
				desc := "从上次运行开始计时。"
				if next := a.nextAutoRun(); !next.IsZero() {
					desc = "下一次：" + next.Format("1月2日 15:04")
				}
				settingRow(c, "间隔", desc, func(ui.Element) {
					labels := make([]string, len(autoRunHours))
					for i, h := range autoRunHours {
						labels[i] = autoRunLabel(h)
					}
					ui.Segmented(c, &a.autoIdx, labels...).Label("自动换壁纸间隔")
				})
			})

		group(c, "系统", "",
			func() {
				settingRow(c, "刷新系统壁纸", "换完一批后重启 macOS 的壁纸服务。系统设置里用这个文件夹随机切换壁纸时，不刷新的话系统会一直轮换已经删掉的旧图。", func(l ui.Element) {
					ui.Switch(c, &a.cfg.RefreshWallpaper).LabelledBy(l)
				})
			})

		group(c, "配置文件", "",
			func() {
				settingRow(c, "config.json", a.cfgPath, func(ui.Element) {
					iconButton(c, iconExternal, "在 Finder 中显示", false).OnClick(func() {
						a.openPath(filepath.Dir(a.cfgPath))
					})
					ui.Button(c, "导入配置…").OnClick(a.importConfig)
				})
			})

		a.remoteGroup(c)
	}).Disabled(a.running)
}

// archiveGroup 是设置里的「归档」分组：开关一行，打开后才显示位置和跨挂载点换算。
func (a *app) archiveGroup(c *ui.Context) {
	rows := []func(){
		func() {
			settingRow(c, "启用归档", "把每次选中的图片在图库旁边额外留一份链接，长期保留历史而不占双倍空间。优先硬链接，不支持时降级为软链接；每次运行前清空上一批。", func(l ui.Element) {
				ui.Switch(c, &a.cfg.ArchiveEnabled).LabelledBy(l)
			})
		},
	}
	if a.cfg.ArchiveEnabled {
		rows = append(rows,
			func() {
				settingRow(c, "归档文件夹名", "建在每个归档位置下的子文件夹。", func(ui.Element) {
					ui.TextInput(c, &a.cfg.ArchiveSubdirName).Width(220).Label("归档文件夹名")
				})
			},
			func() {
				wideRow(c, "归档位置", "可选。留空时放在每个图库目录的上级路径下；填了下面的 NFS 路径则默认放在那里。", func() {
					a.pathInput(c, &a.cfg.ArchiveDirOverride, "归档位置", "选择归档位置（留空则自动使用各源目录的上级路径）")
				})
			},
			func() {
				wideRow(c, "跨挂载点硬链接", "可选，两项都留空则不换算。硬链接要求图片和链接在同一个挂载点：图库走 SMB 时建不了硬链接；"+
					"同一份数据还有 NFS 挂载点的话，填这两项就在 NFS 下建真正的硬链接，Windows 也能读。采样和复制始终走图库里配置的路径。", func() {
					ui.Column(c).Gap(10).Children(func() {
						mountFlow(c, a.cfg.ArchiveSMBRoot, a.cfg.ArchiveNFSRoot)
						a.pathInput(c, &a.cfg.ArchiveSMBRoot, "SMB 根路径", "选择图库所在的 SMB 挂载根路径")
						a.pathInput(c, &a.cfg.ArchiveNFSRoot, "NFS 根路径", "选择同一份数据的 NFS 挂载根路径")
					})
				})
			})
	}
	group(c, "归档", "", rows...)
}

// mountFlow 画出 SMB → NFS 的换算关系。
func mountFlow(c *ui.Context, smb, nfs string) {
	t := c.Theme()
	node := func(kind, path string, color ui.Color) {
		ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(2).Padding(10, 12).Radius(9).
			Background(color.Alpha(0.08)).Border(1, color.Alpha(0.22)).Children(func() {
			ui.Text(c, kind).FontSize(11).Bold().TextColor(color)
			if path == "" {
				path = "未设置"
			}
			ui.Text(c, path).FontSize(12.5).SingleLine()
		})
	}
	ui.Row(c).Gap(10).AlignItems(ui.Center).Children(func() {
		node("SMB · 采样和复制", smb, t.TextMuted)
		ui.Icon(c, iconArrowRight).FontSize(16).TextColor(t.TextMuted)
		node("NFS · 建归档硬链接", nfs, t.Accent)
	})
}
