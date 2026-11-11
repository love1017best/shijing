package main

import (
	"fmt"

	"github.com/egoist/mygo/ui"
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
	group(c, "手机遥控",
		"配对过的 iPhone 在同一个局域网里可以看进度、换一批壁纸、停止运行。手机上换一批时会先问要不要删除不合格原图。",
		rows...)
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
