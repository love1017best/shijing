package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"slices"
	"strings"
	"time"
)

// ── 配对协议与频控 ────────────────────────────────────────────────────────

// pairRequest 是正在进行的配对：桌面上显示 code，手机要在过期前输对。
type pairRequest struct {
	device  string
	id      string
	code    string
	expires time.Time
	fails   int
	qr      bool // 电脑上显示二维码发起的（手机扫码直接提交，不用在电脑上点确认）
}

// currentPair 是正在等桌面这边看的配对请求（过期的不算）。扫码发起的不算：那一种是电脑主动开的，不用再确认。
func (rs *remoteServer) currentPair() (device, code string, ok bool) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if p := rs.pair; p != nil && !p.qr && rs.clock().Before(p.expires) {
		return p.device, p.code, true
	}
	return "", "", false
}

// qrPair 是电脑上显示二维码的那个配对码（过期的不算）。
func (rs *remoteServer) qrPair() (code string, ok bool) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if p := rs.pair; p != nil && p.qr && rs.clock().Before(p.expires) {
		return p.code, true
	}
	return "", false
}

// startPair 建一个配对请求。qr 为 true 时是电脑上显示二维码发起的，id 是手机的固定标识。
func (rs *remoteServer) startPair(device, id string, qr bool) pairRequest {
	rs.mu.Lock()
	rs.pair = &pairRequest{device: device, id: id, code: randomCode(), expires: rs.clock().Add(pairCodeTTL), qr: qr}
	p := *rs.pair
	rs.mu.Unlock()
	time.AfterFunc(pairCodeTTL+time.Second, rs.redraw) // 过期后画一帧让弹层消失
	return p
}

// takePaired 判断 code 这次配对是不是刚成功（每次成功只回答一次，弹层据此收起）。
func (rs *remoteServer) takePaired(code string) bool {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if code != "" && rs.pairedCode == code {
		rs.pairedCode = ""
		return true
	}
	return false
}

// cancelPair 取消正在进行的配对（桌面上点了「拒绝」）。
func (rs *remoteServer) cancelPair() {
	rs.mu.Lock()
	rs.pair = nil
	rs.mu.Unlock()
}

func randomCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		panic(err)
	}
	return fmt.Sprintf("%06d", n.Int64())
}

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err == nil && host != "" {
		return host
	}
	return strings.TrimSpace(r.RemoteAddr)
}

func (rs *remoteServer) handlePairStart(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Device string `json:"device"`
		// ID 是手机的固定标识，旧版手机端不带
		ID string `json:"id"`
	}
	if !readBodyOrFail(w, r, &body) {
		return
	}
	ip := clientIP(r)
	now := rs.clock()
	dev := sanitizeDevice(body.Device)
	id := sanitizeDeviceID(body.ID)

	rs.mu.Lock()
	if until, ok := rs.pairLockUntil[ip]; ok && now.Before(until) {
		rs.mu.Unlock()
		writeErr(w, http.StatusTooManyRequests, "尝试次数过多，请稍后再试")
		return
	}
	if p := rs.pair; p != nil && now.Before(p.expires) && p.qr {
		rs.mu.Unlock()
		writeErr(w, http.StatusConflict, "电脑上正在显示配对二维码，请先完成或关闭后再试")
		return
	}
	// 按客户端 IP 做滑动窗口频控，防止局域网内恶意高频调用抢占桌面焦点
	recent := rs.pairStarts[ip][:0]
	for _, ts := range rs.pairStarts[ip] {
		if now.Sub(ts) < pairStartWindow {
			recent = append(recent, ts)
		}
	}
	if len(recent) >= pairStartLimit {
		rs.pairStarts[ip] = recent
		rs.mu.Unlock()
		writeErr(w, http.StatusTooManyRequests, "请求过于频繁，请一分钟后再试")
		return
	}
	if p := rs.pair; p != nil && now.Before(p.expires) && p.fails > 0 {
		// 同一设备离开配对页再进时，复用当前未过期的配对码并保留已累计的错误次数（不换码、不重置计数），
		// 让手机端重新显示 6 位码输入框继续输入；其他设备仍拒绝，防止绕过错误上限。
		same := (id != "" && p.id == id) || (id == "" && p.id == "" && p.device == dev)
		if same {
			rs.pairStarts[ip] = append(recent, now)
			remain := max(1, int(p.expires.Sub(now).Seconds()))
			rs.mu.Unlock()
			writeJSON(w, http.StatusOK, map[string]any{"expires_in": remain})
			return
		}
		rs.mu.Unlock()
		writeErr(w, http.StatusTooManyRequests, "当前配对码已输错，请继续输入或等过期后再试")
		return
	}
	rs.pairStarts[ip] = append(recent, now)
	hadActive := rs.pair != nil && !rs.pair.qr && now.Before(rs.pair.expires)
	rs.pair = &pairRequest{device: dev, id: id, code: randomCode(), expires: now.Add(pairCodeTTL), qr: false}
	rs.mu.Unlock()
	time.AfterFunc(pairCodeTTL+time.Second, rs.redraw)
	// 仅在桌面还没有打开配对弹层时才拉起窗口，避免反复抢焦点
	rs.a.update(func() {
		if !hadActive && rs.a.showWindow != nil {
			rs.a.showWindow()
		}
	})
	writeJSON(w, http.StatusOK, map[string]any{"expires_in": int(pairCodeTTL.Seconds())})
}

// sanitizeDevice 是手机上来的设备名：空的用 iPhone，太长截断。
func sanitizeDevice(dev string) string {
	dev = strings.TrimSpace(dev)
	if dev == "" {
		return "iPhone"
	}
	if r := []rune(dev); len(r) > 40 {
		dev = string(r[:40])
	}
	return dev
}

// sanitizeDeviceID 是手机上来的固定标识：只留常见的 UUID 字符，太长截断。
func sanitizeDeviceID(id string) string {
	id = strings.TrimSpace(id)
	if r := []rune(id); len(r) > 64 {
		id = string(r[:64])
	}
	for _, c := range id {
		if !(c == '-' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return ""
		}
	}
	return id
}

// uniqueDeviceName 在一台手机要用的名字已经被别的手机占用时加序号：「iPhone」→「iPhone 2」。
func uniqueDeviceName(devs []remoteDevice, name string) string {
	taken := func(n string) bool {
		return slices.ContainsFunc(devs, func(d remoteDevice) bool { return d.Name == n })
	}
	if !taken(name) {
		return name
	}
	for i := 2; ; i++ {
		if n := fmt.Sprintf("%s %d", name, i); !taken(n) {
			return n
		}
	}
}

func (rs *remoteServer) handlePairFinish(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
		// Device 和 ID 只在扫码配对时带：二维码里的请求是电脑发起的，手机报上自己的名字和标识
		Device string `json:"device"`
		ID     string `json:"id"`
	}
	if !readBodyOrFail(w, r, &body) {
		return
	}
	ip := clientIP(r)
	now := rs.clock()
	rs.mu.Lock()
	p := rs.pair
	switch {
	case p == nil || now.After(p.expires):
		rs.pair = nil
		rs.mu.Unlock()
		writeErr(w, http.StatusGone, "配对码已过期或被拒绝，请重新开始配对")
		return
	case now.Before(rs.pairLockUntil[ip]):
		rs.mu.Unlock()
		writeErr(w, http.StatusTooManyRequests, "尝试次数过多，请稍后再试")
		return
	case subtle.ConstantTimeCompare([]byte(strings.TrimSpace(body.Code)), []byte(p.code)) != 1:
		p.fails++
		msg := fmt.Sprintf("配对码不对，还可以再试 %d 次", pairMaxFails-p.fails)
		if p.fails >= pairMaxFails {
			rs.pair = nil
			rs.pairLockUntil[clientIP(r)] = now.Add(pairFailCooldown)
			msg = "错误次数太多，这次配对已取消，请重新开始"
		}
		rs.mu.Unlock()
		rs.redraw()
		writeErr(w, http.StatusForbidden, msg)
		return
	}
	name := p.device
	if d := strings.TrimSpace(body.Device); d != "" {
		name = sanitizeDevice(d)
	}
	id := p.id
	if d := sanitizeDeviceID(body.ID); d != "" {
		id = d
	}
	tok := randomToken()
	// 同一台手机重新配对时替换掉旧的那条，免得越积越多；别的手机名字撞了就加个序号，
	// 不能按名字替换——两台手机默认名字都叫「iPhone」，后配的会把先配的令牌顶掉。
	if id != "" {
		rs.devices = slices.DeleteFunc(rs.devices, func(d remoteDevice) bool { return d.ID == id })
	} else {
		// 旧版手机端没有标识，只能按名字认
		rs.devices = slices.DeleteFunc(rs.devices, func(d remoteDevice) bool { return d.ID == "" && d.Name == name })
	}
	name = uniqueDeviceName(rs.devices, name)
	rs.devices = append(rs.devices, remoteDevice{Name: name, ID: id, TokenHash: hashToken(tok), PairedAt: now})
	rs.saveDevicesLocked()
	rs.pairedCode = p.code
	rs.pair = nil
	rs.mu.Unlock()
	rs.a.update(func() { rs.a.toast = fmt.Sprintf("已和「%s」配对", name) })
	writeJSON(w, http.StatusOK, map[string]any{
		"token":     tok,
		"name":      rs.host,
		"server_id": rs.serverID,
	})
}
