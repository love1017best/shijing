package main

// 手机遥控：局域网里配对过的 iPhone 通过 HTTP 看进度、换一批壁纸、停止运行。
//
//   - 只有设置里打开「允许手机遥控」才监听端口（默认 remotePort，被占用时随便挑一个），
//     并用 macOS 自带的 dns-sd 广播 Bonjour 服务 _shijing._tcp，手机不用填 IP。
//   - 第一次连接要配对：手机请求后桌面弹出 6 位配对码，手机输对了拿到令牌，
//     之后每个请求都带 Authorization: Bearer <令牌>。令牌只存 SHA-256，在数据目录的 remote_devices.json。
//   - 界面状态只在主线程改：要改状态的请求（运行、停止）通过 app.update 回主线程做；
//     读状态的请求读主线程发布的快照（publishRemote），不用等主线程。
//   - 手机端用 /api/events（SSE）实时收状态快照，状态变了才推。

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	"desktop/core"
)

const (
	remotePort    = 52819
	bonjourType   = "_shijing._tcp"
	pairCodeTTL   = 2 * time.Minute
	pairMaxFails  = 5
	remoteAPIVer  = 1 // 接口有不兼容的改动时加 1，手机端据此提示升级
	sseKeepAlive  = 15 * time.Second
	mainThreadMax = 10 * time.Second
)

// remoteDevice 是一台配对过的手机。
type remoteDevice struct {
	Name      string    `json:"name"`
	TokenHash string    `json:"token_sha256"`
	PairedAt  time.Time `json:"paired_at"`
}

// pairRequest 是正在进行的配对：桌面上显示 code，手机要在过期前输对。
type pairRequest struct {
	device  string
	code    string
	expires time.Time
	fails   int
}

type remoteServer struct {
	a    *app
	file string // remote_devices.json
	host string // 广播和显示用的电脑名
	// advertise 广播 Bonjour 服务，返回停止函数；为 nil 时不广播（测试）。
	advertise func(name string, port int, txt []string) (stop func())
	listen    func() (net.Listener, error)

	mu        sync.Mutex
	enabled   bool // 上一次 setEnabled 的值，只在变化时开关服务
	devices   []remoteDevice
	online    map[string]int // 设备名 → 正连着的事件流个数
	pair      *pairRequest
	state     []byte
	subs      map[chan struct{}]struct{}
	srv       *http.Server
	port      int
	listenErr string
	stopAd    func()
}

func newRemoteServer(a *app, file string) *remoteServer {
	rs := &remoteServer{
		a: a, file: file, host: "Mac",
		online: map[string]int{},
		subs:   map[chan struct{}]struct{}{},
		listen: func() (net.Listener, error) {
			ln, err := net.Listen("tcp", fmt.Sprintf(":%d", remotePort))
			if err != nil {
				ln, err = net.Listen("tcp", ":0") // 默认端口被占用：随便挑一个，Bonjour 会告诉手机
			}
			return ln, err
		},
	}
	if data, err := os.ReadFile(file); err == nil {
		_ = json.Unmarshal(data, &rs.devices)
	}
	return rs
}

// ── 开关 ──────────────────────────────────────────────────────────────────

// setEnabled 由界面每帧调用（主线程），只在值变化时启动或关闭服务。
func (rs *remoteServer) setEnabled(on bool) {
	rs.mu.Lock()
	if on == rs.enabled {
		rs.mu.Unlock()
		return
	}
	rs.enabled = on
	rs.mu.Unlock()
	if on {
		rs.start()
	} else {
		rs.stop()
	}
}

func (rs *remoteServer) start() {
	ln, err := rs.listen()
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if err != nil {
		rs.listenErr = err.Error()
		return
	}
	rs.listenErr = ""
	rs.port = ln.Addr().(*net.TCPAddr).Port
	rs.srv = &http.Server{Handler: rs.handler(), ReadHeaderTimeout: 10 * time.Second}
	go func(srv *http.Server) { _ = srv.Serve(ln) }(rs.srv)
	if rs.advertise != nil {
		rs.stopAd = rs.advertise(rs.host, rs.port, []string{
			fmt.Sprintf("api=%d", remoteAPIVer),
			"version=" + rs.a.version,
		})
	}
}

// stop 关掉服务和广播；退出应用时也要调，不然 dns-sd 子进程会留下来。
func (rs *remoteServer) stop() {
	rs.mu.Lock()
	srv, stopAd := rs.srv, rs.stopAd
	rs.srv, rs.stopAd, rs.pair, rs.port = nil, nil, nil, 0
	rs.mu.Unlock()
	if stopAd != nil {
		stopAd()
	}
	if srv != nil {
		_ = srv.Close()
	}
}

// status 是设置页显示的监听状态：端口（0 表示没在监听）和监听失败的原因。
func (rs *remoteServer) status() (port int, errText string) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return rs.port, rs.listenErr
}

// ── 设备 ──────────────────────────────────────────────────────────────────

type deviceInfo struct {
	remoteDevice
	online bool
}

func (rs *remoteServer) deviceList() []deviceInfo {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	out := make([]deviceInfo, len(rs.devices))
	for i, d := range rs.devices {
		out[i] = deviceInfo{d, rs.online[d.Name] > 0}
	}
	return out
}

// unpair 取消一台手机的配对，它的令牌立刻失效（已经连着的事件流在下一次推送时断开）。
func (rs *remoteServer) unpair(name string) {
	rs.mu.Lock()
	rs.devices = slices.DeleteFunc(rs.devices, func(d remoteDevice) bool { return d.Name == name })
	devs := slices.Clone(rs.devices)
	rs.mu.Unlock()
	rs.saveDevices(devs)
}

func (rs *remoteServer) saveDevices(devs []remoteDevice) {
	data, err := json.MarshalIndent(devs, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(rs.file, data, 0o600)
}

func hashToken(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// deviceFor 返回令牌对应的设备名，令牌无效时返回 ""。
func (rs *remoteServer) deviceFor(r *http.Request) string {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || tok == "" {
		return ""
	}
	h := hashToken(tok)
	rs.mu.Lock()
	defer rs.mu.Unlock()
	for _, d := range rs.devices {
		if subtle.ConstantTimeCompare([]byte(d.TokenHash), []byte(h)) == 1 {
			return d.Name
		}
	}
	return ""
}

// ── 配对 ──────────────────────────────────────────────────────────────────

// currentPair 是正在等桌面这边看的配对请求（过期的不算）。
func (rs *remoteServer) currentPair() (device, code string, ok bool) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if p := rs.pair; p != nil && time.Now().Before(p.expires) {
		return p.device, p.code, true
	}
	return "", "", false
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

// ── 状态快照 ──────────────────────────────────────────────────────────────

// publish 由主线程调用：快照变了才通知各个事件流。
func (rs *remoteServer) publish(state []byte) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if bytes.Equal(state, rs.state) {
		return
	}
	rs.state = state
	for ch := range rs.subs {
		select {
		case ch <- struct{}{}:
		default: // 还有一个没发的通知，发的时候会带上最新的快照
		}
	}
}

func (rs *remoteServer) snapshot() []byte {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return rs.state
}

// onMain 在主线程上执行 fn 并等它跑完；主线程太久没反应时返回 false。
func (rs *remoteServer) onMain(fn func()) bool {
	done := make(chan struct{})
	rs.a.update(func() {
		fn()
		rs.a.publishRemote() // 响应里带的快照要反映 fn 的结果
		close(done)
	})
	select {
	case <-done:
		return true
	case <-time.After(mainThreadMax):
		return false
	}
}

// redraw 让界面重画一帧（设备上下线、配对请求来了），并重新发布快照。
func (rs *remoteServer) redraw() { rs.a.update(func() {}) }

// ── HTTP ──────────────────────────────────────────────────────────────────

func (rs *remoteServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/info", rs.handleInfo)
	mux.HandleFunc("POST /api/pair/start", rs.handlePairStart)
	mux.HandleFunc("POST /api/pair/finish", rs.handlePairFinish)
	mux.HandleFunc("GET /api/state", rs.authed(rs.handleState))
	mux.HandleFunc("GET /api/events", rs.authed(rs.handleEvents))
	mux.HandleFunc("POST /api/run", rs.authed(rs.handleRun))
	mux.HandleFunc("POST /api/stop", rs.authed(rs.handleStop))
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func readBody(r *http.Request, v any) error {
	return json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(v)
}

func (rs *remoteServer) authed(h func(w http.ResponseWriter, r *http.Request, device string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		dev := rs.deviceFor(r)
		if dev == "" {
			writeErr(w, http.StatusUnauthorized, "这台手机还没有配对，或者配对已在电脑上取消")
			return
		}
		h(w, r, dev)
	}
}

// handleInfo 不需要令牌：手机连上后先看看是不是拾景、令牌还有没有效。
func (rs *remoteServer) handleInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"app":     "拾景",
		"name":    rs.host,
		"api":     remoteAPIVer,
		"version": rs.a.version,
		"paired":  rs.deviceFor(r) != "",
	})
}

func (rs *remoteServer) handlePairStart(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Device string `json:"device"`
	}
	if err := readBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	dev := strings.TrimSpace(body.Device)
	if dev == "" {
		dev = "iPhone"
	}
	if r := []rune(dev); len(r) > 40 {
		dev = string(r[:40])
	}
	rs.mu.Lock()
	rs.pair = &pairRequest{device: dev, code: randomCode(), expires: time.Now().Add(pairCodeTTL)}
	rs.mu.Unlock()
	// 弹出配对码；过期后再画一帧让弹层消失
	rs.a.update(func() {
		if rs.a.showWindow != nil {
			rs.a.showWindow()
		}
	})
	time.AfterFunc(pairCodeTTL+time.Second, rs.redraw)
	writeJSON(w, http.StatusOK, map[string]any{"expires_in": int(pairCodeTTL.Seconds())})
}

func (rs *remoteServer) handlePairFinish(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if err := readBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	rs.mu.Lock()
	p := rs.pair
	switch {
	case p == nil || time.Now().After(p.expires):
		rs.pair = nil
		rs.mu.Unlock()
		writeErr(w, http.StatusGone, "配对码已过期或被拒绝，请重新开始配对")
		return
	case subtle.ConstantTimeCompare([]byte(strings.TrimSpace(body.Code)), []byte(p.code)) != 1:
		p.fails++
		msg := fmt.Sprintf("配对码不对，还可以再试 %d 次", pairMaxFails-p.fails)
		if p.fails >= pairMaxFails {
			rs.pair = nil
			msg = "错误次数太多，这次配对已取消，请重新开始"
		}
		rs.mu.Unlock()
		rs.redraw()
		writeErr(w, http.StatusForbidden, msg)
		return
	}
	tok := randomToken()
	// 同名的手机重新配对时替换掉旧的那条，免得越积越多
	rs.devices = slices.DeleteFunc(rs.devices, func(d remoteDevice) bool { return d.Name == p.device })
	rs.devices = append(rs.devices, remoteDevice{Name: p.device, TokenHash: hashToken(tok), PairedAt: time.Now()})
	devs := slices.Clone(rs.devices)
	dev := p.device
	rs.pair = nil
	rs.mu.Unlock()
	rs.saveDevices(devs)
	rs.a.update(func() { rs.a.toast = fmt.Sprintf("已和「%s」配对", dev) })
	writeJSON(w, http.StatusOK, map[string]any{"token": tok, "name": rs.host})
}

func (rs *remoteServer) handleState(w http.ResponseWriter, r *http.Request, _ string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(rs.snapshot())
}

// handleEvents 是 SSE 事件流：连上先发一次当前状态，之后状态变了就发，空闲时定期发注释行保活。
func (rs *remoteServer) handleEvents(w http.ResponseWriter, r *http.Request, dev string) {
	fl, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "不支持事件流")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	ch := make(chan struct{}, 1)
	rs.mu.Lock()
	rs.subs[ch] = struct{}{}
	rs.online[dev]++
	rs.mu.Unlock()
	rs.redraw()
	defer func() {
		rs.mu.Lock()
		delete(rs.subs, ch)
		if rs.online[dev]--; rs.online[dev] <= 0 {
			delete(rs.online, dev)
		}
		rs.mu.Unlock()
		rs.redraw()
	}()

	send := func() bool {
		if rs.deviceFor(r) == "" { // 在电脑上取消了配对
			return false
		}
		_, err := fmt.Fprintf(w, "data: %s\n\n", rs.snapshot())
		fl.Flush()
		return err == nil
	}
	if !send() {
		return
	}
	keep := time.NewTicker(sseKeepAlive)
	defer keep.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-ch:
			if !send() {
				return
			}
		case <-keep.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			fl.Flush()
		}
	}
}

// handleRun 开始换一批。delete 为 false 时这次只模拟筛选（手机上已经确认过要不要删原图）。
// 运行前重新检查一遍图库目录能不能访问：桌面上的挂载状态只在启动时查过，NAS 可能后来才挂上。
func (rs *remoteServer) handleRun(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		Delete bool `json:"delete"`
	}
	if err := readBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	var dirs []string
	if !rs.onMain(func() { dirs = rs.a.allDirs() }) {
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
		return
	}
	states := make([]mountState, len(dirs))
	var wg sync.WaitGroup
	for i, d := range dirs {
		wg.Go(func() { states[i] = probeMount(rs.a.statDir, d) })
	}
	wg.Wait()

	var runErr error
	ok := rs.onMain(func() {
		for i, d := range dirs {
			rs.a.mounts[d] = states[i]
		}
		runErr = rs.a.remoteRun(dev, body.Delete)
	})
	switch {
	case !ok:
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
	case runErr != nil:
		writeErr(w, http.StatusConflict, runErr.Error())
	default:
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(rs.snapshot())
	}
}

func (rs *remoteServer) handleStop(w http.ResponseWriter, r *http.Request, dev string) {
	if !rs.onMain(func() {
		if rs.a.running && !rs.a.stopReq.Load() {
			rs.a.appendLog(fmt.Sprintf("📱 「%s」请求停止", dev))
		}
		rs.a.stopRun()
	}) {
		writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(rs.snapshot())
}

// ── 主线程上的部分 ────────────────────────────────────────────────────────

// remoteBlocked 是手机上「换一批」为什么点不了，能点时返回 ""。
// 不看挂载状态：遥控运行前会重新检查一遍（见 handleRun）。
func (a *app) remoteBlocked() string {
	switch {
	case a.running:
		return "正在运行"
	case len(a.allDirs()) == 0:
		return "还没有添加图库目录，请先在电脑上添加"
	case strings.TrimSpace(a.cfg.DestDir) == "":
		return "还没有设置壁纸文件夹，请先在电脑上设置"
	}
	return ""
}

// remoteRun 是手机上点了「换一批」（主线程）。
func (a *app) remoteRun(device string, allowDelete bool) error {
	if reason := a.remoteBlocked(); reason != "" {
		return errors.New(reason)
	}
	if !a.canRun() {
		return errors.New("图库目录都无法访问，NAS 可能没有挂载")
	}
	a.startRunWith(runOpts{noDelete: !allowDelete, from: device})
	return nil
}

// remoteState 是推给手机的状态快照，手机端的 RemoteState 与它一一对应。
type remoteState struct {
	Version  string `json:"version"`
	Eyebrow  string `json:"eyebrow"`
	Title    string `json:"title"`
	Running  bool   `json:"running"`
	Stopping bool   `json:"stopping"`
	// 运行中：这次会走哪几步（filter / scan / copy / refresh）、当前是哪一步、进度
	Steps    []string `json:"steps"`
	Stage    string   `json:"stage,omitempty"`
	Done     int      `json:"done"`
	Total    int      `json:"total"`
	Fraction float64  `json:"fraction"` // 0~1，-1 表示进度未知
	Label    string   `json:"label,omitempty"`
	LastLine string   `json:"last_line,omitempty"`
	// 筛选阶段的删除情况：真删时数已删除，模拟运行时数不合格
	RunDelete    bool `json:"run_delete"`
	Rejected     int  `json:"rejected"`
	Deleted      int  `json:"deleted"`
	DeleteFailed int  `json:"delete_failed"`

	Blocked    string      `json:"blocked,omitempty"` // 「换一批」点不了的原因
	Unmounted  int         `json:"unmounted"`         // 上次检查时访问不了的图库目录数
	WillDelete bool        `json:"will_delete"`       // 手动运行会删除不合格原图
	DeleteNote string      `json:"delete_note,omitempty"`
	Last       *remoteLast `json:"last,omitempty"`
	NextAuto   int64       `json:"next_auto,omitempty"` // Unix 秒，0 表示没开自动换
	Wallpapers int         `json:"wallpapers"`          // 壁纸文件夹里现在有几张
	Dest       string      `json:"dest"`
	Sample     int         `json:"sample_count"`
	Library    int         `json:"library_dirs"`
}

type remoteLast struct {
	At       int64   `json:"at"`     // Unix 秒（手机端解析起来最省事）
	Status   string  `json:"status"` // ok / stopped / failed
	Error    string  `json:"error,omitempty"`
	Selected int     `json:"selected"`
	Copied   int     `json:"copied"`
	Failed   int     `json:"failed"`
	Elapsed  float64 `json:"elapsed"` // 秒
	Brief    string  `json:"brief,omitempty"`
	Detail   string  `json:"detail,omitempty"`
}

var stageIDs = []string{"filter", "scan", "copy", "refresh"}

func (a *app) remoteSnapshot() remoteState {
	s := remoteState{
		Version: a.version, Eyebrow: a.heroEyebrow(), Title: a.heroTitle(),
		Running: a.running, Stopping: a.running && a.stopReq.Load(),
		Fraction:   -1,
		Blocked:    a.remoteBlocked(),
		Unmounted:  a.unmountedCount(),
		WillDelete: a.willDelete(),
		Wallpapers: len(a.walls.all),
		Dest:       tildify(a.cfg.DestDir),
		Sample:     int(a.num),
		Library:    len(a.allDirs()),
	}
	if s.WillDelete {
		s.DeleteNote = a.deleteNotice()
	}
	if len(a.cfg.FilterAndSampleDirs) > 0 {
		s.Steps = append(s.Steps, stageIDs[0])
	}
	s.Steps = append(s.Steps, stageIDs[1:]...)
	if a.running {
		p := a.prog
		s.Stage = stageIDs[p.stage]
		s.Done, s.Total = p.done, p.total
		if p.total > 0 && (p.stage == 0 || p.stage == 2) {
			s.Fraction = float64(p.done) / float64(p.total)
		}
		s.Label = a.progressLabel()
		s.LastLine = stripEmoji(cleanLogLine(a.lastLogLine()))
		s.RunDelete = a.runDelete
		s.Rejected, s.Deleted, s.DeleteFailed = a.runRejected, a.runDeleted, a.runDelFailed
	}
	if l := a.last; l != nil {
		rl := &remoteLast{At: l.at.Unix(), Status: "ok", Selected: l.sum.Copy.Selected, Copied: l.sum.Copy.Copied,
			Failed: l.sum.Copy.Failed, Elapsed: l.sum.Elapsed.Seconds()}
		switch {
		case errors.Is(l.err, core.ErrCanceled):
			rl.Status = "stopped"
		case l.err != nil:
			rl.Status, rl.Error = "failed", l.err.Error()
		default:
			rl.Brief, rl.Detail = a.resultBrief(), a.resultDetail()
		}
		s.Last = rl
	}
	if next := a.nextAutoRun(); !next.IsZero() {
		s.NextAuto = next.Unix()
	}
	return s
}

// publishRemote 在主线程上把最新状态交给手机遥控服务（没开启时什么都不做）。
func (a *app) publishRemote() {
	if a.remote == nil {
		return
	}
	a.remote.setEnabled(a.cfg.RemoteEnabled)
	if port, _ := a.remote.status(); port == 0 {
		return
	}
	data, err := json.Marshal(a.remoteSnapshot())
	if err != nil {
		return
	}
	a.remote.publish(data)
}

// ── Bonjour ───────────────────────────────────────────────────────────────

// advertiseBonjour 用系统自带的 dns-sd 注册服务（走 mDNSResponder，比自己实现 mDNS 可靠）。
// dns-sd 会一直运行直到被结束；外面包一层 sh，拾景的 stdin 管道断了（包括崩溃）它就跟着退出，
// 不会留下一个指向旧端口的广播。
func advertiseBonjour(name string, port int, txt []string) func() {
	args := []string{"-R", name, bonjourType, "local", fmt.Sprint(port)}
	args = append(args, txt...)
	quoted := make([]string, len(args))
	for i, s := range args {
		quoted[i] = "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
	}
	script := "/usr/bin/dns-sd " + strings.Join(quoted, " ") + " >/dev/null 2>&1 & pid=$!; read _; kill $pid"
	cmd := exec.Command("/bin/sh", "-c", script)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return func() {}
	}
	if err := cmd.Start(); err != nil {
		return func() {}
	}
	return func() {
		_ = stdin.Close()
		_ = cmd.Wait()
	}
}

// computerName 是「系统设置 › 通用 › 共享」里的电脑名。
func computerName() string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "/usr/sbin/scutil", "--get", "ComputerName").Output(); err == nil {
		if s := strings.TrimSpace(string(out)); s != "" {
			return s
		}
	}
	if h, err := os.Hostname(); err == nil {
		return strings.TrimSuffix(h, ".local")
	}
	return "Mac"
}

// localIPs 是本机的局域网 IPv4 地址，设置页上显示，Bonjour 找不到时手机可以手动填。
func localIPs() []string {
	var out []string
	ifaces, _ := net.Interfaces()
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, ad := range addrs {
			if ipn, ok := ad.(*net.IPNet); ok {
				if ip4 := ipn.IP.To4(); ip4 != nil && ip4.IsPrivate() {
					out = append(out, ip4.String())
				}
			}
		}
	}
	return out
}
