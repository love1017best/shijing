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
	if code, _ := h.do(t, "POST", "/api/pair/start", "", map[string]string{"device": device}); code != 200 {
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
	code, data := h.do(t, "POST", "/api/pair/finish", "", map[string]string{"code": pin})
	if code != 200 {
		t.Fatalf("pair/finish = %d %v", code, data)
	}
	tok, _ := data["token"].(string)
	if tok == "" || data["name"] != "测试 Mac" {
		t.Fatalf("配对结果 = %v", data)
	}
	return tok
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

	if code, data := h.do(t, "POST", "/api/run", tok, map[string]bool{"delete": true}); code != 409 || !strings.Contains(data["error"].(string), "NAS") {
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
