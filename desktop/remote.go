package main

// 手机遥控服务：局域网里配对过的 iPhone 通过 HTTP 查看进度、换一批壁纸、停止运行。
//
//   - 仅在开启「允许手机遥控」时监听端口（默认 remotePort，被占用时随机分配），
//     并用 macOS 自带的 dns-sd 广播 Bonjour 服务 _shijing._tcp。
//   - 配对协议在 remotepair.go，状态快照与遥控控制在 remotesnap.go，壁纸接口在 remotewalls.go，
//     设置与记录接口在 remoteextra.go。
//   - 界面状态只在主线程修改：写请求经 app.update 回主线程执行；读请求直接读取主线程发布的快照。

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"desktop/core"
)

const (
	remotePort       = 52819
	bonjourType      = "_shijing._tcp"
	pairCodeTTL      = 2 * time.Minute
	pairMaxFails     = 5
	pairStartWindow  = time.Minute
	pairStartLimit   = 6
	pairFailCooldown = 30 * time.Second
	remoteAPIVer     = 1 // 接口有不兼容改动时递增，手机端据此提示升级
	sseKeepAlive     = 15 * time.Second
	sseWriteTimeout  = 10 * time.Second
	mainThreadMax    = 10 * time.Second
)

// remoteDevice 是一台配对过的手机。
type remoteDevice struct {
	Name string `json:"name"`
	// ID 是手机首次配对时生成的固定标识：靠它认出「同一台手机重新配对」。
	// 手机默认名字都叫「iPhone」，只按名字认会让两台手机互相顶掉（旧版手机端没有这个字段）。
	ID        string    `json:"id,omitempty"`
	TokenHash string    `json:"token_sha256"`
	PairedAt  time.Time `json:"paired_at"`
}

type remoteServer struct {
	a        *app
	file     string // remote_devices.json
	host     string // 广播和显示用的电脑名
	serverID string // 持久化的本机唯一标识：电脑换 IP 或改名后手机仍能认出同一台 Mac
	// advertise 广播 Bonjour 服务，返回停止函数；为 nil 时不广播（测试）。
	advertise func(name string, port int, txt []string) (stop func())
	listen    func() (net.Listener, error)

	mu      sync.Mutex
	enabled bool // 上一次 setEnabled 的值，只在变化时开关服务
	devices []remoteDevice
	online  map[string]int // 令牌哈希 → 正连着的事件流个数（在电脑上改名不影响）
	pair    *pairRequest
	// pairedCode 是最近一次配对成功的 code：电脑上显示二维码的弹层靠它收起
	pairedCode    string
	pairStarts    map[string][]time.Time // 客户端 IP → 近期 /api/pair/start 请求时间戳（防频刷与抢焦点）
	pairLockUntil map[string]time.Time   // 客户端 IP → 输错满次后的冷却截止时间
	now           func() time.Time       // 当前时间，测试里可替换以验证冷却窗口
	state         []byte
	subs          map[chan struct{}]struct{}
	srv           *http.Server
	port          int
	listenErr     string
	stopAd        func()
	walls         wallsSnapshot // 壁纸列表（remotewalls.go），主线程发布
	decodeSem     chan struct{} // 限制同时解码的大图张数
	mainTimeout   time.Duration // onMain 等待主线程的超时（默认 mainThreadMax，测试可缩短）
	deletionsMu   sync.Mutex
	deletionsETag string
	deletionsBody []byte
}

func newRemoteServer(a *app, file string) *remoteServer {
	rs := &remoteServer{
		a: a, file: file, host: "Mac",
		serverID:      loadOrCreateServerID(filepath.Dir(file)),
		online:        map[string]int{},
		pairStarts:    map[string][]time.Time{},
		pairLockUntil: map[string]time.Time{},
		now:           time.Now,
		decodeSem:     make(chan struct{}, remoteDecodeWorkers),
		subs:          map[chan struct{}]struct{}{},
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

// loadOrCreateServerID 读取或生成本机遥控服务的稳定标识（UUID v4），保存在应用数据目录的 remote_server_id。
func loadOrCreateServerID(dir string) string {
	idPath := filepath.Join(dir, "remote_server_id")
	if data, err := os.ReadFile(idPath); err == nil {
		if id := sanitizeDeviceID(string(data)); id != "" {
			return id
		}
	}
	id := randomUUIDv4()
	if dir != "" && dir != "." {
		_ = core.WriteFileAtomic(idPath, []byte(id+"\n"), 0o600)
	}
	return id
}

func randomUUIDv4() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func (rs *remoteServer) clock() time.Time {
	if rs.now != nil {
		return rs.now()
	}
	return time.Now()
}

// ── 服务启停 ──────────────────────────────────────────────────────────────

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
		txt := []string{
			fmt.Sprintf("api=%d", remoteAPIVer),
			"version=" + rs.a.version,
		}
		if rs.serverID != "" {
			txt = append(txt, "id="+rs.serverID)
		}
		rs.stopAd = rs.advertise(rs.host, rs.port, txt)
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

// ── 设备与鉴权 ────────────────────────────────────────────────────────────

type deviceInfo struct {
	remoteDevice
	online bool
}

func (rs *remoteServer) deviceList() []deviceInfo {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	out := make([]deviceInfo, len(rs.devices))
	for i, d := range rs.devices {
		out[i] = deviceInfo{d, rs.online[d.TokenHash] > 0}
	}
	return out
}

// renameDevice 改一台已配对手机在列表里显示的名字，返回改后的名字。
func (rs *remoteServer) renameDevice(old, name string) (string, bool) {
	rs.mu.Lock()
	i := slices.IndexFunc(rs.devices, func(d remoteDevice) bool { return d.Name == old })
	if i < 0 {
		rs.mu.Unlock()
		return "", false
	}
	name = sanitizeDevice(name)
	others := slices.Delete(slices.Clone(rs.devices), i, i+1)
	name = uniqueDeviceName(others, name)
	rs.devices[i].Name = name
	rs.saveDevicesLocked()
	rs.mu.Unlock()
	rs.redraw()
	return name, true
}

// unpair 取消一台手机的配对，它的令牌立刻失效并立即唤醒空闲事件流使其断开。
func (rs *remoteServer) unpair(name string) {
	rs.mu.Lock()
	rs.devices = slices.DeleteFunc(rs.devices, func(d remoteDevice) bool { return d.Name == name })
	rs.saveDevicesLocked()
	for ch := range rs.subs {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
	rs.mu.Unlock()
}

// saveDevicesLocked 在持有 rs.mu 时原子落盘，保证并发配对/改名/取消配对不会以旧快照覆盖新文件。
func (rs *remoteServer) saveDevicesLocked() {
	data, err := json.MarshalIndent(rs.devices, "", "  ")
	if err != nil {
		return
	}
	_ = core.WriteFileAtomic(rs.file, data, 0o600)
}

func hashToken(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// deviceKey 是设备在 online 里用的 key：令牌哈希，在电脑上改名也不变。
func (rs *remoteServer) deviceKey(r *http.Request) string {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || tok == "" {
		return ""
	}
	return hashToken(tok)
}

// deviceFor 返回令牌对应的设备名，令牌无效时返回 ""。
func (rs *remoteServer) deviceFor(r *http.Request) string {
	h := rs.deviceKey(r)
	if h == "" {
		return ""
	}
	rs.mu.Lock()
	defer rs.mu.Unlock()
	for _, d := range rs.devices {
		if subtle.ConstantTimeCompare([]byte(d.TokenHash), []byte(h)) == 1 {
			return d.Name
		}
	}
	return ""
}

// ── 状态发布与主线程调度 ──────────────────────────────────────────────────

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

// onMainOrFail 在主线程上执行 fn，主线程太久没反应时回 503 并返回 false。
func (rs *remoteServer) onMainOrFail(w http.ResponseWriter, fn func()) bool {
	if rs.onMain(fn) {
		return true
	}
	writeErr(w, http.StatusServiceUnavailable, "电脑上的拾景没有响应")
	return false
}

// onMain 在主线程上执行 fn 并等它跑完；主线程太久没反应时返回 false。
// 超时后若主线程尚未开始执行，通过原子状态取消排队的回调，防止返回 503 后仍产生写操作副作用。
func (rs *remoteServer) onMain(fn func()) bool {
	done := make(chan struct{})
	// 0: 排队中，1: 已开始执行，2: 已超时取消
	var state atomic.Int32
	rs.a.update(func() {
		if !state.CompareAndSwap(0, 1) {
			return
		}
		fn()
		rs.a.commitState() // 响应前落盘并发布最新快照（窗口隐藏时不依赖 view 重绘）
		close(done)
	})
	timeout := rs.mainTimeout
	if timeout <= 0 {
		timeout = mainThreadMax
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
		return true
	case <-timer.C:
		if state.CompareAndSwap(0, 2) {
			return false
		}
		// 恰好在超时临界点已进入主线程执行，短暂等待完成以保持响应与状态一致
		grace := time.NewTimer(200 * time.Millisecond)
		defer grace.Stop()
		select {
		case <-done:
			return true
		case <-grace.C:
			return false
		}
	}
}

// redraw 让界面重画一帧（设备上下线、配对请求来了），并重新发布快照。
func (rs *remoteServer) redraw() { rs.a.update(func() {}) }

// ── HTTP 路由与 SSE ───────────────────────────────────────────────────────

func (rs *remoteServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/info", rs.handleInfo)
	mux.HandleFunc("POST /api/pair/start", rs.handlePairStart)
	mux.HandleFunc("POST /api/pair/finish", rs.handlePairFinish)
	mux.HandleFunc("GET /api/state", rs.authed(rs.handleState))
	mux.HandleFunc("GET /api/events", rs.authed(rs.handleEvents))
	mux.HandleFunc("POST /api/run", rs.authed(rs.handleRun))
	mux.HandleFunc("POST /api/stop", rs.authed(rs.handleStop))
	mux.HandleFunc("POST /api/pending/cancel", rs.authed(rs.handlePendingCancel))
	mux.HandleFunc("POST /api/mounts/check", rs.authed(rs.handleMountsCheck))
	rs.wallRoutes(mux)
	rs.extraRoutes(mux)
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

// readBodyOrFail 读请求体；格式不对时回 400 并返回 false。
func readBodyOrFail(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := readBody(r, v); err != nil {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return false
	}
	return true
}

func (rs *remoteServer) authed(h func(w http.ResponseWriter, r *http.Request, device string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		dev := rs.deviceFor(r)
		if dev == "" {
			writeErr(w, http.StatusUnauthorized, "这台手机尚未配对，或配对已在电脑上取消")
			return
		}
		h(w, r, dev)
	}
}

// handleInfo 不需要令牌：手机连上后先看看是不是拾景、是不是同一台 Mac、令牌还有没有效。
func (rs *remoteServer) handleInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"app":       "拾景",
		"name":      rs.host,
		"server_id": rs.serverID,
		"api":       remoteAPIVer,
		"version":   rs.a.version,
		"paired":    rs.deviceFor(r) != "",
	})
}

func (rs *remoteServer) handleState(w http.ResponseWriter, r *http.Request, _ string) {
	rs.writeSnapshot(w)
}

// handleEvents 是 SSE 事件流：连上先发一次当前状态，之后状态变了就发，空闲时定期发注释行保活。
func (rs *remoteServer) handleEvents(w http.ResponseWriter, r *http.Request, _ string) {
	fl, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "不支持事件流")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	ch := make(chan struct{}, 1)
	key := rs.deviceKey(r)
	rs.mu.Lock()
	rs.subs[ch] = struct{}{}
	rs.online[key]++
	rs.mu.Unlock()
	rs.redraw()
	defer func() {
		rs.mu.Lock()
		delete(rs.subs, ch)
		if rs.online[key]--; rs.online[key] <= 0 {
			delete(rs.online, key)
		}
		rs.mu.Unlock()
		rs.redraw()
	}()

	rc := http.NewResponseController(w)
	send := func() bool {
		if rs.deviceFor(r) == "" { // 在电脑上取消了配对
			return false
		}
		_ = rc.SetWriteDeadline(time.Now().Add(sseWriteTimeout))
		_, err := fmt.Fprintf(w, "data: %s\n\n", rs.snapshot())
		if err != nil {
			return false
		}
		fl.Flush()
		return true
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
			if rs.deviceFor(r) == "" {
				return
			}
			_ = rc.SetWriteDeadline(time.Now().Add(sseWriteTimeout))
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			fl.Flush()
		}
	}
}

// ── Bonjour 与本机局域网地址 ──────────────────────────────────────────────

// advertiseBonjour 用系统自带的 dns-sd 注册服务（依赖 mDNSResponder）。
// 外面包一层 sh，拾景的 stdin 管道断了（包括崩溃）它就跟着退出，不会留下指向旧端口的广播。
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

const localIPsCacheTTL = 10 * time.Second

var (
	localIPsMu    sync.Mutex
	localIPsAt    time.Time
	localIPsValue []string
)

// cachedLocalIPs 在设置页高频重绘时复用 10 秒内的局域网 IP 列表，避免每帧枚举网卡。
func cachedLocalIPs() []string {
	localIPsMu.Lock()
	if !localIPsAt.IsZero() && time.Since(localIPsAt) < localIPsCacheTTL {
		out := slices.Clone(localIPsValue)
		localIPsMu.Unlock()
		return out
	}
	localIPsMu.Unlock()
	ips := localIPs()
	localIPsMu.Lock()
	localIPsValue = slices.Clone(ips)
	localIPsAt = time.Now()
	localIPsMu.Unlock()
	return ips
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
