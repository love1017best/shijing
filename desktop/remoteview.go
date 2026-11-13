package main

import (
	"fmt"

	"github.com/egoist/mygo/ui"
	"github.com/skip2/go-qrcode"
)

// remoteGroup 是设置页的「手机遥控」分组：开关、监听地址、配对过的手机。
func (a *app) remoteGroup(c *ui.Context) {
	t := c.Theme()
	rows := []func(){
		func() {
			desc := "关闭时不监听任何端口。"
			if a.cfg.RemoteEnabled {
				switch port, errText := a.remote.status(); {
				case errText != "":
					desc = "无法监听端口：" + errText + "。关掉再打开可以重试。"
				case port > 0:
					desc = fmt.Sprintf("正在监听端口 %d。iPhone 上打开拾景 App 会自动找到这台 Mac", port)
					if ips := localIPs(); len(ips) > 0 {
						desc += fmt.Sprintf("；找不到时手动填 %s:%d", ips[0], port)
					}
					desc += "。"
				}
			}
			settingRow(c, "允许手机遥控", desc, func(l ui.Element) {
				ui.Switch(c, &a.cfg.RemoteEnabled).LabelledBy(l)
			})
		},
	}
	devs := a.remote.deviceList()
	for _, d := range devs {
		rows = append(rows, func() {
			desc := "配对于 " + d.PairedAt.Format("2006年1月2日 15:04")
			settingRow(c, d.Name, desc, func(ui.Element) {
				if d.online {
					pill(c, "已连接", t.Success)
				}
				ui.Button(c, "取消配对").Label("取消和「" + d.Name + "」的配对").OnClick(func() {
					a.remote.unpair(d.Name)
					a.toast = fmt.Sprintf("已取消和「%s」的配对", d.Name)
				})
			})
		})
	}
	if len(devs) == 0 && a.cfg.RemoteEnabled {
		rows = append(rows, func() {
			settingRow(c, "还没有配对的手机", "在 iPhone 上打开拾景 App、选这台 Mac，这里会弹出 6 位配对码。", func(ui.Element) {})
		})
	}
	if a.cfg.RemoteEnabled {
		rows = append(rows, func() {
			settingRow(c, "扫码配对", "在手机上打开拾景 › 添加其他 Mac › 扫描二维码，扫完直接连上，不用输配对码。",
				func(ui.Element) {
					ui.Button(c, "显示二维码").OnClick(a.openQRPair)
				})
		})
	}
	group(c, "手机遥控",
		"配对过的 iPhone 在同一个局域网里可以看进度、换一批壁纸、停止运行。手机上换一批时会先问要不要删除不合格原图。",
		rows...)
}

// openQRPair 生成一个配对请求并把二维码显示出来：手机扫一扫就完成配对（配对码就在二维码里），
// 不用电脑上再点一次确认。只有手机能在局域网里扫到，和手动输入配对码的安全性一样。
func (a *app) openQRPair() {
	if a.remote == nil {
		return
	}
	port, errText := a.remote.status()
	ips := localIPs()
	switch {
	case errText != "" || port == 0:
		a.toast = "手机遥控没有在监听，先打开「允许手机遥控」"
		return
	case len(ips) == 0:
		a.toast = "找不到这台 Mac 的局域网地址（没有连 Wi‑Fi 或网线？）"
		return
	}
	p := a.remote.startPair("iPhone", true)
	a.qrURL = fmt.Sprintf("shijing://pair?h=%s&p=%d&c=%s", ips[0], port, p.code)
	img, err := qrcode.New(a.qrURL, qrcode.Medium)
	if err != nil {
		a.toast = "生成二维码失败：" + err.Error()
		return
	}
	img.DisableBorder = false
	a.qrBitmap = ui.NewBitmap(img.Image(480))
	a.qrCode = p.code
	a.qrOpen = true
}

// qrPairModal 是「扫码配对」的二维码弹层。手机扫完并配对成功后自动收起。
func (a *app) qrPairModal(c *ui.Context) {
	if a.remote == nil {
		return
	}
	// 用户关掉了弹层：这次配对作废，二维码就不再有效（期间换成别的配对请求就不动它）
	if !a.qrOpen {
		if a.qrCode != "" {
			if _, ok := a.remote.qrPair(); ok {
				a.remote.cancelPair()
			}
			a.qrCode = ""
		}
		return
	}
	// 配对成功：收起弹层（成功时的提示由 handlePairFinish 弹出）；配对码过期也收起
	if a.remote.takePaired(a.qrCode) {
		a.qrOpen, a.qrCode = false, ""
		return
	}
	if _, ok := a.remote.qrPair(); !ok {
		a.qrOpen, a.qrCode = false, ""
		// 是被另一台手机的手动配对请求顶掉的就不提示过期（那种情况会弹配对码）
		if _, _, manual := a.remote.currentPair(); !manual {
			a.toast = "配对码过期了，需要的话再点一次「显示二维码」"
		}
		return
	}
	ui.Modal(c, &a.qrOpen, func() {
		ui.Column(c).Width(380).Gap(12).Padding(24).AlignItems(ui.Center).Children(func() {
			ui.Text(c, "扫码配对").FontSize(17).Bold()
			ui.Image(c, a.qrBitmap).Size(220, 220).Label("配对二维码")
			muted(c, "在手机上打开拾景 ›「添加其他 Mac」› 扫描二维码。").TextAlign(ui.Center)
			ui.Text(c, "或者手动输入配对码 "+spacedCode(a.qrCode)).FontSize(13)
			muted(c, "2 分钟内有效").TextAlign(ui.Center)
		})
	}).Label("扫码配对")
}

// pairModal 是手机请求配对时弹出的配对码。点「拒绝」或 Esc 取消这次配对。
func (a *app) pairModal(c *ui.Context) {
	if a.remote == nil {
		return
	}
	dev, code, ok := a.remote.currentPair()
	if !ok {
		a.pairOpen, a.pairCode = false, ""
		return
	}
	if code != a.pairCode { // 新的配对请求
		a.pairCode, a.pairOpen = code, true
	}
	t := c.Theme()
	ui.Modal(c, &a.pairOpen, func() {
		ui.Column(c).Width(380).Gap(14).Padding(24).AlignItems(ui.Center).Children(func() {
			ui.Icon(c, iconPhone).FontSize(30).TextColor(t.Accent)
			ui.Text(c, fmt.Sprintf("「%s」请求遥控拾景", dev)).FontSize(15).Bold().TextAlign(ui.Center)
			muted(c, "在手机上输入下面的配对码。不是你的手机就点拒绝。").TextAlign(ui.Center)
			ui.Text(c, spacedCode(code)).FontSize(34).Bold().Label("配对码 " + code)
			muted(c, "2 分钟内有效").TextAlign(ui.Center)
			ui.Button(c, "拒绝").OnClick(func() { a.pairOpen = false })
		})
	}).Label("手机配对")
	if !a.pairOpen {
		a.remote.cancelPair()
		a.pairCode = ""
		a.toast = "已拒绝配对"
	}
}

// spacedCode 把 123456 显示成「123 456」，好读。
func spacedCode(code string) string {
	if len(code) == 6 {
		return code[:3] + " " + code[3:]
	}
	return code
}
