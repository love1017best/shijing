package main

import (
	"errors"
	"fmt"
	"slices"
	"strings"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

// ── 配置方案（场景预设）────────────────────────────────────────────────────

// saveProfile 把当前配置保存为指定名称的方案（同名则覆盖更新）。
func (a *app) saveProfile(name string) error {
	a.syncConfigFromShadow()
	p, err := a.cfg.SaveProfile(name)
	if err != nil {
		return err
	}
	a.profileErr = ""
	a.cfgRev++
	a.toast = "已保存方案「" + p.Name + "」"
	return nil
}

// applyProfile 切换到指定名称的配置方案；运行中拒绝切换。
func (a *app) applyProfile(name string) error {
	if a.running {
		return errors.New("正在更换壁纸，等完成后再切换方案")
	}
	a.syncConfigFromShadow()
	oldDest := a.cfg.DestDir
	oldDirs := a.allDirs()
	p, ok := a.cfg.ApplyProfile(name)
	if !ok {
		return fmt.Errorf("找不到配置方案「%s」", name)
	}
	a.filter.chosen.Clear()
	a.sample.chosen.Clear()
	a.prevDelete = a.cfg.DeleteDuringFilter
	a.syncShadowFromConfig()
	a.cfgRev++
	if a.cfg.DestDir != oldDest {
		a.wallsGen++
		a.loadWallpapers()
	}
	if !slices.Equal(oldDirs, a.allDirs()) {
		a.checkMounts()
	}
	a.toast = "已切换到方案「" + p.Name + "」"
	return nil
}

// switchProfileAndRun 切换到指定方案，随后触发换一批壁纸。
func (a *app) switchProfileAndRun(name string, fromTray bool) {
	if err := a.applyProfile(name); err != nil {
		a.toast = err.Error()
		return
	}
	if !a.canRun() {
		a.toast = "已切换到方案「" + name + "」，但当前无法运行"
		return
	}
	if fromTray {
		a.trayRun()
	} else {
		a.requestRun()
	}
}

// deleteProfile 删除指定名称的方案。
func (a *app) deleteProfile(name string) bool {
	if !a.cfg.DeleteProfile(name) {
		return false
	}
	a.cfgRev++
	a.toast = "已删除方案「" + name + "」"
	return true
}

// profileSummary 生成方案的一行简要参数（图库数、每次张数、最低分辨率）。
func profileSummary(p core.Profile) string {
	dirs := len(p.FilterAndSampleDirs) + len(p.SampleOnlyDirs)
	res := fmt.Sprintf("%d×%d", p.MinWidth, p.MinHeight)
	if idx := presetFor(p.MinWidth, p.MinHeight); idx < len(resPresets) {
		res = resPresets[idx].label
	}
	return fmt.Sprintf("%d 个图库 · %d 张 · %s", dirs, p.SampleCount, res)
}

// profilesGroup 是设置页顶部的「配置方案」分组。
func (a *app) profilesGroup(c *ui.Context) {
	t := c.Theme()
	a.syncConfigFromShadow()
	modified := a.cfg.ActiveProfileModified()

	var rows []func()
	for _, p := range a.cfg.Profiles {
		p := p
		active := p.Name == a.cfg.ActiveProfile
		rows = append(rows, func() {
			c.Key("profile:" + p.Name)
			ui.Row(c).Gap(12).AlignItems(ui.Center).Padding(12, 16).Children(func() {
				ui.Column(c).Grow(1).Shrink(1).Gap(3).MinWidth(0).Children(func() {
					ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
						ui.Text(c, p.Name).FontSize(13.5).Bold().SingleLine()
						if active && !modified {
							pill(c, "当前", t.Accent)
						} else if active && modified {
							pill(c, "已修改", t.Warning)
						}
					})
					muted(c, profileSummary(p)).FontSize(12).SingleLine()
				})
				ui.Row(c).Shrink(0).Gap(6).AlignItems(ui.Center).Children(func() {
					if active && modified {
						ui.Button(c, "更新").Tooltip("用当前设置覆盖这套方案").OnClick(func() {
							_ = a.saveProfile(p.Name)
						})
						ui.Button(c, "恢复").Tooltip("放弃未保存改动，恢复这套方案").OnClick(func() {
							_ = a.applyProfile(p.Name)
						})
					} else if !active {
						ui.Button(c, "切换").OnClick(func() {
							_ = a.applyProfile(p.Name)
						})
					}
					iconButton(c, iconShuffle, "换一批", false).
						Tooltip("切换到「" + p.Name + "」并立即换一批壁纸").
						OnClick(func() { a.switchProfileAndRun(p.Name, false) })
					ui.Button(c, "").Label("删除方案 " + p.Name).Tooltip("删除方案「" + p.Name + "」").
						Children(func() { ui.Icon(c, iconTrash).FontSize(13).TextColor(t.TextMuted) }).
						OnClick(func() { a.deleteProfile(p.Name) })
				})
			})
		})
	}

	rows = append(rows, func() {
		wideRow(c, "保存当前配置为方案", "保存当前的图库目录、壁纸文件夹、每次张数、画质与采样选项；在菜单栏和手机端都可以一键切换。", func() {
			ui.Column(c).Gap(6).Children(func() {
				ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
					inp := ui.TextInput(c, &a.profileDraft).Grow(1).Label("方案名称").Placeholder("例如：日常风景、暗色极简、带鱼屏")
					save := func() {
						name := strings.TrimSpace(a.profileDraft)
						if err := a.saveProfile(name); err != nil {
							a.profileErr = err.Error()
							return
						}
						a.profileDraft = ""
						a.profileErr = ""
					}
					if inp.Submitted() {
						save()
					}
					ui.PrimaryButton(c, "保存方案").Disabled(strings.TrimSpace(a.profileDraft) == "").OnClick(save)
				})
				if a.profileErr != "" {
					ui.Text(c, a.profileErr).FontSize(12).TextColor(t.Danger)
				}
			})
		})
	})

	group(c, "配置方案", "给不同的图库组合、张数和分辨率分别存成方案，在菜单栏和手机端都能一键切换并换一批。", rows...)
}
