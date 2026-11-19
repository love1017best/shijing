package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

// remoteHarness 是开着手机遥控的假应用，监听本机随机端口。
type remoteHarness struct {
	*fakeApp
	tt   *ui.Tester
	base string
}

func newRemoteHarness(t *testing.T) *remoteHarness {
	t.Helper()
	f, tt := newFakeApp(t)
	f.remote.host = "测试 Mac"
	f.remote.listen = func() (net.Listener, error) { return net.Listen("tcp", "127.0.0.1:0") }
	f.cfg.FilterAndSampleDirs = []string{"/Volumes/Media0/A"}
	f.cfg.DestDir = "/tmp/wall"
	f.cfg.RemoteEnabled = true
	tt.Frame()
	port, errText := f.remote.status()
	if port == 0 {
		t.Fatalf("没有开始监听: %s", errText)
	}
	t.Cleanup(f.remote.stop)
	return &remoteHarness{f, tt, "http://127.0.0.1:" + strconv.Itoa(port)}
}

// do 在后台发请求，同时在测试 goroutine 上执行排队的主线程更新，直到拿到响应。
func (h *remoteHarness) do(t *testing.T, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	type result struct {
		code int
		data map[string]any
		err  error
	}
	done := make(chan result, 1)
	go func() {
		var rd io.Reader
		if body != nil {
			b, _ := json.Marshal(body)
			rd = strings.NewReader(string(b))
		}
		req, _ := http.NewRequest(method, h.base+path, rd)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			done <- result{err: err}
			return
		}
		defer resp.Body.Close()
		var data map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&data)
		done <- result{code: resp.StatusCode, data: data}
	}()
	var res result
	h.settle(t, h.tt, func() bool {
		select {
		case res = <-done:
			return true
		default:
			return false
		}
	})
	if res.err != nil {
		t.Fatal(res.err)
	}
	return res.code, res.data
}

// pair 走一遍配对，返回令牌。
func (h *remoteHarness) pair(t *testing.T, device string) string {
	t.Helper()
	return h.pairDevice(t, device, "")
}

// pairDevice 走一遍配对，带上手机的固定标识（旧的手机端不带）。
func (h *remoteHarness) pairDevice(t *testing.T, device, id string) string {
	t.Helper()
	body := map[string]string{"device": device}
	if id != "" {
		body["id"] = id
	}
	if code, _ := h.do(t, "POST", "/api/pair/start", "", body); code != 200 {
		t.Fatalf("pair/start = %d", code)
	}
	h.tt.Frame()
	dev, pin, ok := h.remote.currentPair()
	if !ok || dev != device || len(pin) != 6 {
		t.Fatalf("配对请求 = %q %q %v", dev, pin, ok)
	}
	if _, ok := h.tt.Access("配对码 " + pin); !ok {
		t.Fatal("桌面上没有显示配对码")
	}
	code, data := h.do(t, "POST", "/api/pair/finish", "", pairBody(pin, id))
	if code != 200 {
		t.Fatalf("pair/finish = %d %v", code, data)
	}
	tok, _ := data["token"].(string)
	if tok == "" || data["name"] != "测试 Mac" {
		t.Fatalf("配对结果 = %v", data)
	}
	return tok
}

func pairBody(code, id string) map[string]string {
	b := map[string]string{"code": code}
	if id != "" {
		b["id"] = id
	}
	return b
}

// 两台都叫「iPhone」的手机要能同时配对：后配的那台不能把先配的令牌顶掉。
func TestRemoteTwoPhonesWithSameName(t *testing.T) {
	h := newRemoteHarness(t)
	first := h.pairDevice(t, "iPhone", "phone-a")
	second := h.pairDevice(t, "iPhone", "phone-b")
	if first == second {
		t.Fatal("两台手机的令牌相同")
	}
	if code, _ := h.do(t, "GET", "/api/state", first, nil); code != 200 {
		t.Fatalf("先配的那台被顶掉了: %d", code)
	}
	if code, _ := h.do(t, "GET", "/api/state", second, nil); code != 200 {
		t.Fatalf("后配的那台连不上: %d", code)
	}
	names := []string{}
	for _, d := range h.remote.deviceList() {
		names = append(names, d.Name)
	}
	if strings.Join(names, ",") != "iPhone,iPhone 2" {
		t.Fatalf("配对的手机 = %v", names)
	}

	// 同一台手机重新配对（名字改成「小明的 iPhone」）只留一条，令牌换新
	again := h.pairDevice(t, "小明的 iPhone", "phone-a")
	if code, _ := h.do(t, "GET", "/api/state", again, nil); code != 200 {
		t.Fatalf("重新配对后的令牌不可用: %d", code)
	}
	if code, _ := h.do(t, "GET", "/api/state", first, nil); code != 401 {
		t.Fatalf("重新配对后旧令牌还能用: %d", code)
	}
	names = names[:0]
	for _, d := range h.remote.deviceList() {
		names = append(names, d.Name)
	}
	if strings.Join(names, ",") != "iPhone 2,小明的 iPhone" {
		t.Fatalf("重新配对后配对的手机 = %v", names)
	}
}

func TestRemoteDisabledByDefault(t *testing.T) {
	f, tt := newFakeApp(t)
	tt.Frame()
	if port, _ := f.remote.status(); port != 0 {
		t.Fatalf("没打开遥控却在监听端口 %d", port)
	}
}

func TestRemotePairingAndAuth(t *testing.T) {
	h := newRemoteHarness(t)

	if code, data := h.do(t, "GET", "/api/info", "", nil); code != 200 || data["app"] != "拾景" || data["paired"] != false {
		t.Fatalf("info = %d %v", code, data)
	}
	if code, _ := h.do(t, "GET", "/api/state", "", nil); code != 401 {
		t.Fatalf("没配对就能读状态: %d", code)
	}
	if code, _ := h.do(t, "GET", "/api/state", "bogus", nil); code != 401 {
		t.Fatalf("假令牌能读状态: %d", code)
	}

	// 输错几次会提示剩余次数，错太多次这次配对作废
	h.do(t, "POST", "/api/pair/start", "", map[string]string{"device": "坏人的手机"})
	_, pin, _ := h.remote.currentPair()
	wrong := "000000"
	if pin == wrong {
		wrong = "111111"
	}
	for i := range pairMaxFails {
		code, data := h.do(t, "POST", "/api/pair/finish", "", map[string]string{"code": wrong})
		if code != 403 {
			t.Fatalf("第 %d 次输错 = %d", i+1, code)
		}
		if i == pairMaxFails-1 && !strings.Contains(data["error"].(string), "太多") {
			t.Fatalf("错太多次的提示 = %v", data)
		}
	}
	if code, _ := h.do(t, "POST", "/api/pair/finish", "", map[string]string{"code": pin}); code != 410 {
		t.Fatalf("作废后再输对 = %d，应该要重新开始", code)
	}
	// 输错满次后进入冷却期，不能立刻重新刷配对码绕过锁定
	if code, _ := h.do(t, "POST", "/api/pair/start", "", map[string]string{"device": "坏人的手机"}); code != 429 {
		t.Fatalf("输错满次冷却期内应返回 429，实际 %d", code)
	}
	future := time.Now().Add(pairFailCooldown + time.Second)
	h.remote.mu.Lock()
	h.remote.now = func() time.Time { return future }
	h.remote.mu.Unlock()

	tok := h.pair(t, "小明的 iPhone")
	if code, data := h.do(t, "GET", "/api/info", tok, nil); code != 200 || data["paired"] != true {
		t.Fatalf("配对后 info = %v", data)
	}
	code, data := h.do(t, "GET", "/api/state", tok, nil)
	if code != 200 || data["running"] != false || data["library_dirs"] != float64(1) {
		t.Fatalf("state = %d %v", code, data)
	}
	// 令牌只存哈希
	raw, _ := os.ReadFile(filepath.Join(filepath.Dir(h.cfgPath), "remote_devices.json"))
	if strings.Contains(string(raw), tok) || !strings.Contains(string(raw), hashToken(tok)) {
		t.Fatalf("remote_devices.json 里应该只有令牌的哈希: %s", raw)
	}

	// 设置页能看到这台手机，取消配对后令牌立刻失效
	click(t, h.tt, "设置")
	h.tt.SetSize(1040, 1800) // 遥控分组在设置页最下面
	h.tt.Frame()
	if _, ok := h.tt.Access("小明的 iPhone"); !ok {
		t.Fatal("设置页没有列出配对的手机")
	}
	click(t, h.tt, "取消和「小明的 iPhone」的配对")
	if code, _ := h.do(t, "GET", "/api/state", tok, nil); code != 401 {
		t.Fatalf("取消配对后令牌仍然有效: %d", code)
	}
}

func TestRemotePairRejectedOnDesktop(t *testing.T) {
	h := newRemoteHarness(t)
	h.do(t, "POST", "/api/pair/start", "", map[string]string{"device": "iPhone"})
	h.tt.Frame()
	_, pin, _ := h.remote.currentPair()
	click(t, h.tt, "拒绝")
	h.tt.Frame()
	if _, _, ok := h.remote.currentPair(); ok {
		t.Fatal("拒绝后配对请求还在")
	}
	if code, _ := h.do(t, "POST", "/api/pair/finish", "", map[string]string{"code": pin}); code != 410 {
		t.Fatalf("拒绝后还能配对: %d", code)
	}
}

func TestRemotePairByQRCode(t *testing.T) {
	if len(localIPs()) == 0 {
		t.Skip("这台机器没有局域网 IPv4 地址")
	}
	h := newRemoteHarness(t)
	click(t, h.tt, "设置")
	h.tt.SetSize(1040, 1800) // 遥控分组在设置页最下面
	h.tt.Frame()
	click(t, h.tt, "显示二维码")
	h.tt.Frame()
	if !h.qrOpen {
		t.Fatalf("点了显示二维码但弹层没打开：%s", h.toast)
	}
	if !strings.HasPrefix(h.qrURL, "shijing://pair?") || !strings.Contains(h.qrURL, "c="+h.qrCode) {
		t.Fatalf("二维码里的地址 = %q", h.qrURL)
	}
	if _, ok := h.tt.Access("配对二维码"); !ok {
		t.Fatal("弹层里没有二维码")
	}
	// 扫码发起的配对不用在电脑上再确认：不该同时弹出「请求遥控」那个配对码弹层
	if _, _, ok := h.remote.currentPair(); ok || h.pairOpen {
		t.Fatal("扫码配对不该再弹配对码确认框")
	}
	pin, ok := h.remote.qrPair()
	if !ok {
		t.Fatal("没有正在进行的扫码配对")
	}
	status, data := h.do(t, "POST", "/api/pair/finish", "", map[string]string{"code": pin, "device": "扫描的手机"})
	if status != 200 {
		t.Fatalf("pair/finish = %d %v", status, data)
	}
	h.tt.Frame()
	if h.qrOpen {
		t.Fatal("配对成功后二维码弹层应该收起")
	}
	found := false
	for _, d := range h.remote.deviceList() {
		if d.Name == "扫描的手机" {
			found = true
		}
	}
	if !found {
		t.Fatal("配对后设备列表里没有这台手机")
	}
	if tok, _ := data["token"].(string); tok == "" {
		t.Fatalf("配对结果 = %v", data)
	}
}

func TestRemoteRunWithoutDeletingAndStop(t *testing.T) {
	h := newRemoteHarness(t)
	h.cfg.DeleteDuringFilter = true
	h.tt.Frame()
	tok := h.pair(t, "iPhone")

	_, st := h.do(t, "GET", "/api/state", tok, nil)
	if st["will_delete"] != true || !strings.Contains(st["delete_note"].(string), "不可撤销") {
		t.Fatalf("会删原图时手机要能拿到说明: %v", st)
	}

	h.release = make(chan struct{})
	code, data := h.do(t, "POST", "/api/run", tok, map[string]bool{"delete": false})
	if code != 200 || data["running"] != true {
		t.Fatalf("run = %d %v（响应里的状态应该已经是运行中）", code, data)
	}
	h.settle(t, h.tt, func() bool { return len(h.runCfgs) == 1 })
	if h.runCfgs[0].DeleteDuringFilter {
		t.Fatal("手机上选了只模拟，却真删了")
	}
	if !h.cfg.DeleteDuringFilter {
		t.Fatal("只模拟这一次，不应该改掉设置")
	}
	if !strings.Contains(strings.Join(h.log, "\n"), "由「iPhone」遥控运行，这次只模拟筛选") {
		t.Fatalf("日志里没写是谁遥控的: %v", h.log)
	}
	if code, data := h.do(t, "POST", "/api/run", tok, map[string]bool{"delete": false}); code != 409 || data["error"] != "正在运行" {
		t.Fatalf("运行中再点 = %d %v", code, data)
	}

	if code, _ := h.do(t, "POST", "/api/stop", tok, nil); code != 200 {
		t.Fatalf("stop = %d", code)
	}
	h.settle(t, h.tt, func() bool { return !h.running })
	_, st = h.do(t, "GET", "/api/state", tok, nil)
	last, _ := st["last"].(map[string]any)
	if last["status"] != "stopped" {
		t.Fatalf("停止后的状态 = %v", st)
	}
}

func TestRemoteRunRechecksMounts(t *testing.T) {
	h := newRemoteHarness(t)
	h.cfg.FilterAndSampleDirs = []string{"/Volumes/Offline/A"}
	h.checkMounts()
	h.settle(t, h.tt, func() bool { return h.unmountedCount() == 1 })
	tok := h.pair(t, "iPhone")

	if code, data := h.do(t, "POST", "/api/run", tok, map[string]bool{"delete": true}); code != 409 || !strings.Contains(data["error"].(string), "图库可能没有挂载") {
		t.Fatalf("图库都没挂载时 = %d %v", code, data)
	}
	// NAS 后来挂上了：遥控运行前会重新检查，不用等桌面上重新查
	h.statDir = func(string) bool { return true }
	if code, data := h.do(t, "POST", "/api/run", tok, map[string]bool{"delete": true}); code != 200 {
		t.Fatalf("挂上后 = %d %v", code, data)
	}
	h.settle(t, h.tt, func() bool { return len(h.runCfgs) == 1 && !h.running })
	if !h.runCfgs[0].DeleteDuringFilter {
		t.Fatal("手机上确认了删除，这次应该真删")
	}
}

func TestRemoteEventsStream(t *testing.T) {
	h := newRemoteHarness(t)
	tok := h.pair(t, "iPhone")

	req, _ := http.NewRequest("GET", h.base+"/api/events", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("Content-Type = %q", ct)
	}
	events := make(chan map[string]any, 16)
	go func() {
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			if data, ok := strings.CutPrefix(sc.Text(), "data: "); ok {
				var m map[string]any
				if json.Unmarshal([]byte(data), &m) == nil {
					events <- m
				}
			}
		}
		close(events)
	}()
	next := func(want func(map[string]any) bool) map[string]any {
		t.Helper()
		deadline := time.After(3 * time.Second)
		for {
			h.settle(t, h.tt, func() bool { return true })
			select {
			case m, ok := <-events:
				if !ok {
					t.Fatal("事件流断了")
				}
				if want(m) {
					return m
				}
			case <-deadline:
				t.Fatal("等事件超时")
			case <-time.After(20 * time.Millisecond):
			}
		}
	}
	next(func(m map[string]any) bool { return m["running"] == false })

	// 桌面上换一批：手机收到运行中和结束两种状态
	h.release = make(chan struct{})
	click(t, h.tt, "换一批壁纸")
	next(func(m map[string]any) bool { return m["running"] == true && m["stage"] == "copy" })
	close(h.release)
	m := next(func(m map[string]any) bool { return m["running"] == false && m["last"] != nil })
	if last := m["last"].(map[string]any); last["status"] != "ok" || last["copied"] != float64(2) {
		t.Fatalf("结束后的状态 = %v", m)
	}

	// 设置页显示这台手机已连接
	click(t, h.tt, "设置")
	h.tt.SetSize(1040, 1800)
	h.settle(t, h.tt, func() bool { _, ok := h.tt.Access("已连接"); return ok })

	// 取消配对后，空闲的 SSE 连接应当立刻断开
	h.remote.unpair("iPhone")
	select {
	case _, ok := <-events:
		if ok {
			t.Fatal("取消配对后不应继续推送状态事件")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("取消配对后空闲 SSE 连接未及时断开")
	}
}

func TestRemotePairStartGuardsAndWallsRevHero(t *testing.T) {
	h := newRemoteHarness(t)
	// 正在显示扫码配对时，外部 /api/pair/start 不能覆盖
	h.remote.startPair("", "", true)
	if code, _ := h.do(t, "POST", "/api/pair/start", "", map[string]string{"device": "抢占者"}); code != 409 {
		t.Fatalf("扫码配对进行中应返回 409，实际 %d", code)
	}
	h.remote.cancelPair()

	// 手动配对输错 1 次后，不能通过再次 /api/pair/start 清零错误次数
	if code, _ := h.do(t, "POST", "/api/pair/start", "", map[string]string{"device": "iPhone"}); code != 200 {
		t.Fatalf("首次 pair/start = %d", code)
	}
	_, pin, _ := h.remote.currentPair()
	wrong := "000000"
	if pin == wrong {
		wrong = "111111"
	}
	if code, _ := h.do(t, "POST", "/api/pair/finish", "", map[string]string{"code": wrong}); code != 403 {
		t.Fatalf("输错应返回 403，实际 %d", code)
	}
	if code, _ := h.do(t, "POST", "/api/pair/start", "", map[string]string{"device": "iPhone"}); code != 429 {
		t.Fatalf("有错误记录时重刷 pair/start 应返回 429，实际 %d", code)
	}

	// wallsRev 应包含 heroPath，换横幅后指纹必须变化
	r1 := wallsRev([]string{"/tmp/a.jpg", "/tmp/b.jpg"}, "/tmp/a.jpg")
	r2 := wallsRev([]string{"/tmp/a.jpg", "/tmp/b.jpg"}, "/tmp/b.jpg")
	if r1 == r2 {
		t.Fatalf("横幅变化后 wallsRev 未变化: %s", r1)
	}
}

func TestRemoteHandlerRejectsBadJSON(t *testing.T) {
	h := newRemoteHarness(t)
	srv := httptest.NewServer(h.remote.handler())
	defer srv.Close()
	resp, err := http.Post(srv.URL+"/api/pair/start", "application/json", strings.NewReader("{"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("坏 JSON = %d", resp.StatusCode)
	}
}

func TestRemoteOnMainTimeoutSkipsSideEffects(t *testing.T) {
	h := newRemoteHarness(t)
	h.remote.mainTimeout = 20 * time.Millisecond
	ran := false
	// 主线程队列没有被消费，onMain 应超时返回 false
	if ok := h.remote.onMain(func() { ran = true }); ok {
		t.Fatal("主线程未执行时 onMain 应超时返回 false")
	}
	// 之后主线程恢复并排空队列：已超时的写回调绝不能再执行
	h.settle(t, h.tt, func() bool { return true })
	if ran {
		t.Fatal("onMain 超时后排队的回调不应产生副作用")
	}
}

// 系统不把用户设置的设备名给 App（iOS 16 起要有 Apple 批准的授权），配对的手机默认都叫「iPhone」。
// 电脑上可以直接改名：只改这里的记录，手机上不用重新配对。
func TestRemoteRenameDevice(t *testing.T) {
	h := newRemoteHarness(t)
	tok := h.pairDevice(t, "iPhone", "phone-a")
	h.pairDevice(t, "iPhone", "phone-b")

	click(t, h.tt, "设置")
	h.tt.SetSize(1040, 1800) // 遥控分组在设置页最下面
	h.tt.Frame()
	click(t, h.tt, "重命名「iPhone」")
	h.tt.Frame()
	click(t, h.tt, "设备名称")
	h.tt.Key(ui.Cmd, ui.KeyA)
	h.tt.Type("小明的 iPhone")
	h.tt.Frame()
	click(t, h.tt, "保存")
	h.tt.Frame()

	names := []string{}
	for _, d := range h.remote.deviceList() {
		names = append(names, d.Name)
	}
	if strings.Join(names, ",") != "小明的 iPhone,iPhone 2" {
		t.Fatalf("改名后的手机 = %v", names)
	}
	if code, _ := h.do(t, "GET", "/api/state", tok, nil); code != 200 {
		t.Fatalf("改名后令牌不能用了: %d", code)
	}
	// 存进了 remote_devices.json，重启后还是这个名字
	raw, _ := os.ReadFile(filepath.Join(filepath.Dir(h.cfgPath), "remote_devices.json"))
	if !strings.Contains(string(raw), "小明的 iPhone") {
		t.Fatalf("remote_devices.json 里没有新名字: %s", raw)
	}
	// 名字被别的手机占了就加序号
	if got, ok := h.remote.renameDevice("iPhone 2", "小明的 iPhone"); !ok || got != "小明的 iPhone 2" {
		t.Fatalf("重名时 = %q %v", got, ok)
	}
}
