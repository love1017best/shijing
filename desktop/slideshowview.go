package main

import (
	"fmt"
	"path/filepath"
	"time"

	"github.com/egoist/mygo/plugins/glass"
	"github.com/egoist/mygo/ui"
)

// slideshowOverlay 渲染铺满整个窗口的幻灯片层：纯黑底、双槽交叉淡入淡出、液态玻璃时钟卡与自动隐藏控制胶囊。
func (a *app) slideshowOverlay(c *ui.Context) {
	if !a.slideOpen {
		return
	}
	if a.running || len(a.walls.all) == 0 {
		a.closeSlideshow(true)
		return
	}
	idx, list := a.slideIndex()
	if idx < 0 || len(list) == 0 {
		a.closeSlideshow(true)
		return
	}
	a.pumpPreview()

	now := a.slideNow
	if now.IsZero() {
		now = time.Now()
	}
	wall := a.slidePath
	white := ui.RGB(255, 255, 255)
	inFS := a.isFullScreen != nil && a.isFullScreen()

	// 幻灯片快捷键
	switch {
	case c.Shortcut(0, ui.KeyEscape):
		a.closeSlideshow(true)
		return
	case c.Shortcut(0, ui.KeySpace):
		a.toggleSlidePlay(now)
	case c.Shortcut(0, ui.KeyRight), c.Shortcut(0, ui.KeyDown):
		a.slideStep(1, now)
		a.touchSlideHUD(now)
	case c.Shortcut(0, ui.KeyLeft), c.Shortcut(0, ui.KeyUp):
		a.slideStep(-1, now)
		a.touchSlideHUD(now)
	case c.Shortcut(0, ui.KeyF):
		a.toggleSlideFullScreen(now)
	case c.Shortcut(0, ui.KeyI):
		a.slideShowInfo = !a.slideShowInfo
		a.touchSlideHUD(now)
		a.saveUIState()
	}

	root := ui.Box(c).Absolute().Top(0).Left(0).Right(0).Bottom(0).
		Background(ui.RGB(0, 0, 0)).Clip().
		Label("幻灯片").Focusable().FocusRing(false).AutoFocus().
		HandleInput(func(ev ui.InputEvent) bool {
			if a.wheelStep(ev, func(d int) {
				a.slideStep(d, now)
				a.touchSlideHUD(now)
			}) {
				return true
			}
			if ev.Kind == ui.InputPointerMove {
				if !a.slideHasPtr || abs32(ev.X-a.slideLastX) >= 3 || abs32(ev.Y-a.slideLastY) >= 3 {
					a.slideLastX, a.slideLastY, a.slideHasPtr = ev.X, ev.Y, true
					a.touchSlideHUD(now)
				}
			}
			return false
		})

	hudWant := a.slideHudHover || !a.slidePlaying || now.Before(a.slideHudUntil)
	hudTarget := float32(0)
	if hudWant {
		hudTarget = 1
	}
	hudAlpha := root.AnimateWith("slide-hud", hudTarget, 260*time.Millisecond, ui.EaseOut)

	fit := ui.Contain
	if a.slideCover {
		fit = ui.Cover
	}

	root.Children(func() {
		// 1. A/B 双槽交叉淡入淡出图片层
		for slot := range 2 {
			target := float32(0)
			if slot == a.slideSlot {
				target = 1
			}
			layer := ui.Box(c).Absolute().Top(0).Left(0).Right(0).Bottom(0)
			alpha := layer.AnimateWith(fmt.Sprintf("slide-slot-%d", slot), target, slideFadeDur, ui.EaseInOut)
			layer.Opacity(alpha)
			p := a.slideSlots[slot]
			if p != "" && alpha > 0.005 {
				bmp := a.previewBitmap(p)
				layer.Children(func() {
					if bmp != nil {
						ui.Image(c, bmp).Absolute().Top(0).Left(0).Right(0).Bottom(0).Fit(fit)
					} else {
						ui.Box(c).Fill().Center().Children(func() {
							ui.Text(c, "正在载入…").FontSize(13).TextColor(white.Alpha(0.7))
						})
					}
				})
			}
		}

		// 2. 背景点击热区：单击空白画面切换控制条显示
		bgTap := ui.Box(c).Absolute().Top(0).Left(0).Right(0).Bottom(0)
		if bgTap.Clicked() {
			if hudWant && a.slidePlaying {
				a.slideHudUntil = time.Time{}
			} else {
				a.touchSlideHUD(now)
			}
		}

		// 非系统全屏时顶部留拖动条，方便窗口模式下移动位置
		if !inFS {
			ui.Box(c).Absolute().Top(0).Left(0).Right(0).Height(max(c.TitleBar().Height, 28)).DragWindow()
		}

		// 3. 自动隐藏的右上角页码胶囊与底部液态玻璃控制条
		if hudAlpha > 0.02 {
			a.slideStatusPill(c, idx, len(list), inFS, hudAlpha)

			// 底部控制胶囊：显示时钟且窄窗时贴右下，宽窗居中；自身不遮挡左下角信息卡
			vw, _ := c.Size()
			if a.slideShowInfo && vw < 1160 {
				a.slideControlBar(c, ui.Row(c).Absolute().Bottom(24).Right(24).Opacity(hudAlpha), now, inFS)
			} else {
				ui.Row(c).Absolute().Bottom(24).Left(0).Right(0).Justify(ui.Center).Opacity(hudAlpha).Children(func() {
					a.slideControlBar(c, ui.Row(c), now, inFS)
				})
			}
		}

		// 4. 左下角常驻液态玻璃时钟与文件名卡片（画在控制条之上，点击直接退出幻灯片并打开常规预览整理）
		if a.slideShowInfo {
			a.slideInfoCard(c, wall, now)
		}
	})
}

func (a *app) slideStatusPill(c *ui.Context, idx, total int, inFS bool, hudAlpha float32) {
	white := ui.RGB(255, 255, 255)
	topY := float32(20)
	if !inFS {
		topY = max(c.TitleBar().Height, 28) + 6
	}
	ui.Row(c).Absolute().Top(topY).Right(24).Gap(8).AlignItems(ui.Center).
		Opacity(hudAlpha).Radius(16).Padding(6, 12).
		Material(glass.Glass{Tint: ui.RGBA(0, 0, 0, 0.24)}).
		Border(1, white.Alpha(0.16)).Children(func() {
		status := "播放中"
		if !a.slidePlaying {
			status = "已暂停"
		}
		ui.Text(c, fmt.Sprintf("%s · %d / %d", status, idx+1, total)).
			FontSize(12).TextColor(white.Alpha(0.92)).SingleLine()
	})
}

func (a *app) slideControlBar(c *ui.Context, bar ui.Element, now time.Time, inFS bool) {
	white := ui.RGB(255, 255, 255)
	bar.Gap(4).AlignItems(ui.Center).Padding(7, 12).Radius(24).
		Material(glass.Glass{Tint: ui.RGBA(0, 0, 0, 0.28)}).
		Border(1, white.Alpha(0.18))
	a.slideHudHover = bar.Hovered()
	bar.Children(func() {
		slideIconBtn(c, iconChevronLeft, "上一张", "上一张（←）", false).OnClick(func() {
			a.slideStep(-1, now)
			a.touchSlideHUD(now)
		})
		if a.slidePlaying {
			slideIconBtn(c, iconPause, "暂停", "暂停播放（空格）", true).OnClick(func() {
				a.toggleSlidePlay(now)
			})
		} else {
			slideIconBtn(c, iconPlay, "播放", "继续播放（空格）", false).OnClick(func() {
				a.toggleSlidePlay(now)
			})
		}
		slideIconBtn(c, iconChevronRight, "下一张", "下一张（→）", false).OnClick(func() {
			a.slideStep(1, now)
			a.touchSlideHUD(now)
		})

		slideSep(c)

		// 切图间隔
		slideTextBtn(c, slideIntervalLabel(a.slideIntervalSec), "切换间隔",
			"当前每 "+slideIntervalLabel(a.slideIntervalSec)+"切换一张，点击调整间隔", false).OnClick(func() {
			a.cycleSlideInterval(now)
		})
		// 随机播放
		slideIconBtn(c, iconShuffle, "随机播放", "顺序 / 随机播放切换", a.slideShuffle).OnClick(func() {
			a.toggleSlideShuffle(now)
		})
		// 铺满 / 完整显示
		fitTip := "当前铺满画面，点击改为完整显示"
		if !a.slideCover {
			fitTip = "当前完整显示，点击改为铺满画面"
		}
		slideIconBtn(c, iconFrame, "填充方式", fitTip, a.slideCover).OnClick(func() {
			a.slideCover = !a.slideCover
			a.touchSlideHUD(now)
			a.saveUIState()
		})
		// 时钟与文件名
		slideIconBtn(c, iconClock, "时钟与文件名", "显示或隐藏左下角时钟与文件名（I）", a.slideShowInfo).OnClick(func() {
			a.slideShowInfo = !a.slideShowInfo
			a.touchSlideHUD(now)
			a.saveUIState()
		})
		// 防息屏
		awakeTip := "播放期间保持屏幕常亮（已开启）"
		if !a.slideKeepAwake {
			awakeTip = "播放期间允许系统息屏（点击开启防息屏）"
		}
		slideIconBtn(c, iconSun, "防息屏", awakeTip, a.slideKeepAwake).OnClick(func() {
			a.slideKeepAwake = !a.slideKeepAwake
			a.touchSlideHUD(now)
			a.syncSlideKeepAwake()
			a.saveUIState()
		})

		slideSep(c)

		// 跳转常规大图预览整理
		slideTextBtn(c, "整理", "整理当前壁纸", "退出幻灯片并打开这张壁纸的大图预览", false).OnClick(func() {
			a.openPreviewFromSlideshow()
		})

		// 切换系统全屏
		if a.setFullScreen != nil {
			fsIcon := iconMaximize
			fsTip := "进入全屏（F）"
			if inFS {
				fsIcon = iconMinimize
				fsTip = "退出全屏（F）"
			}
			slideIconBtn(c, fsIcon, "全屏", fsTip, inFS).OnClick(func() {
				a.toggleSlideFullScreen(now)
			})
		}

		// 退出幻灯片
		slideIconBtn(c, iconX, "退出幻灯片", "退出幻灯片（Esc）", false).OnClick(func() {
			a.closeSlideshow(true)
		})
	})
}

func (a *app) slideInfoCard(c *ui.Context, wall string, now time.Time) {
	white := ui.RGB(255, 255, 255)
	infoCard := ui.ButtonBase(c).Absolute().Left(24).Bottom(24).
		Radius(20).Padding(12, 18).
		Material(glass.Glass{Tint: ui.RGBA(0, 0, 0, 0.24), Interactive: true}).
		Border(1, white.Alpha(0.18)).
		Cursor(ui.CursorPointer).
		Label("查看并整理当前壁纸").
		Tooltip(filepath.Base(wall) + "（点击退出幻灯片并打开大图预览整理）")
	if infoCard.Hovered() {
		a.touchSlideHUD(now)
	}
	if infoCard.Clicked() {
		a.openPreviewFromSlideshow()
		return
	}
	infoCard.Children(func() {
		ui.Column(c).Gap(3).AlignItems(ui.Start).Children(func() {
			ui.Row(c).Gap(10).AlignItems(ui.End).Children(func() {
				ui.Text(c, now.Format("15:04")).FontSize(34).Bold().TextColor(white).SingleLine().
					TextShadow(0, 1, 6, ui.RGBA(0, 0, 0, 0.35))
				ui.Text(c, slideDateText(now)).FontSize(13).TextColor(white.Alpha(0.84)).SingleLine().Padding(0, 0, 5, 0)
			})
			ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
				ui.Text(c, slideFileTitle(wall)).FontSize(13).TextColor(white.Alpha(0.92)).SingleLine().MaxWidth(360)
				ui.Icon(c, iconChevronRight).FontSize(12).TextColor(white.Alpha(0.65))
			})
		})
	})
}

func slideIconBtn(c *ui.Context, icon *ui.SVG, label, tip string, active bool) ui.Element {
	white := ui.RGB(255, 255, 255)
	btn := ui.ButtonBase(c).Size(34, 34).Radius(17).Center().
		Label(label).Tooltip(tip).Cursor(ui.CursorPointer)
	bg := ui.Transparent
	fg := white.Alpha(0.88)
	if active {
		bg = white.Alpha(0.22)
		fg = white
	}
	if btn.Hovered() {
		bg = white.Alpha(0.28)
		fg = white
	}
	return btn.Background(bg).Children(func() {
		ui.Icon(c, icon).FontSize(15).TextColor(fg)
	})
}

func slideTextBtn(c *ui.Context, text, label, tip string, active bool) ui.Element {
	white := ui.RGB(255, 255, 255)
	btn := ui.ButtonBase(c).Height(34).Padding(0, 11).Radius(17).Center().
		Label(label).Tooltip(tip).Cursor(ui.CursorPointer)
	bg := ui.Transparent
	fg := white.Alpha(0.9)
	if active {
		bg = white.Alpha(0.22)
		fg = white
	}
	if btn.Hovered() {
		bg = white.Alpha(0.28)
		fg = white
	}
	return btn.Background(bg).Children(func() {
		ui.Text(c, text).FontSize(12.5).Bold().TextColor(fg).SingleLine()
	})
}

func slideSep(c *ui.Context) {
	ui.Box(c).Size(1, 18).Background(ui.RGBA(255, 255, 255, 0.2)).Margin(0, 4)
}
