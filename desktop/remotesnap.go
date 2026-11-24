package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"desktop/core"
)

// ── 遥控运行、停止、挂载与待办操作 ────────────────────────────────────────

// handleRun 开始换一批。delete 为 false 时这次只模拟筛选（手机上已经确认过要不要删原图）。
// 运行前重新检查一遍图库目录能不能访问：桌面上的挂载状态只在启动时查过，NAS 可能后来才挂上。
func (rs *remoteServer) handleRun(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		Delete bool `json:"delete"`
	}
	if !readBodyOrFail(w, r, &body) {
		return
	}
	var dirs []string
	if !rs.onMainOrFail(w, func() { dirs = rs.a.allDirs() }) {
		return
	}
	states := make([]mountState, len(dirs))
	var wg sync.WaitGroup
	for i, d := range dirs {
		wg.Go(func() { states[i] = probeMount(rs.a.statDir, d) })
	}
	wg.Wait()

	var runErr error
	if !rs.onMainOrFail(w, func() {
		for i, d := range dirs {
			rs.a.setMountState(d, states[i])
		}
		runErr = rs.a.remoteRun(dev, body.Delete)
	}) {
		return
	}
	if runErr != nil {
		writeErr(w, http.StatusConflict, runErr.Error())
		return
	}
	rs.writeSnapshot(w)
}

func (rs *remoteServer) handleStop(w http.ResponseWriter, r *http.Request, dev string) {
	if !rs.onMainOrFail(w, func() {
		if rs.a.running && !rs.a.stopReq.Load() {
			rs.a.appendLog(fmt.Sprintf("📱 「%s」请求停止", dev))
		}
		rs.a.stopRun()
	}) {
		return
	}
	rs.writeSnapshot(w)
}

// handleMountsCheck 让电脑重新检查每个图库目录能不能访问（手机上的「重新检查挂载」）。
// 检查在后台做（网络卷卡住时 stat 会阻塞），结果随状态快照推给手机。
func (rs *remoteServer) handleMountsCheck(w http.ResponseWriter, r *http.Request, dev string) {
	if !rs.onMainOrFail(w, func() {
		rs.a.appendLog("📱 「" + dev + "」重新检查了图库挂载")
		rs.a.checkMounts()
	}) {
		return
	}
	rs.writeSnapshot(w)
}

// handlePendingCancel 取消电脑上排队的删除原图：{"path": ...} 或 {"all": true}。
// 只取消队列，不动已经移出的壁纸（和电脑概览里的待删除条一样）。
func (rs *remoteServer) handlePendingCancel(w http.ResponseWriter, r *http.Request, dev string) {
	var body struct {
		Path string `json:"path"`
		All  bool   `json:"all"`
	}
	if err := readBody(r, &body); err != nil || (!body.All && body.Path == "") {
		writeErr(w, http.StatusBadRequest, "请求格式不对")
		return
	}
	var removed int
	if !rs.onMainOrFail(w, func() {
		a := rs.a
		if body.All {
			removed = len(a.pending)
			if removed > 0 {
				a.cancelAllPending()
			}
		} else if i := slices.IndexFunc(a.pending, func(e core.PendingDelete) bool { return e.Path == body.Path }); i >= 0 {
			a.cancelPending(i)
			removed = 1
		}
		if removed > 0 {
			a.appendLog(fmt.Sprintf("📱 「%s」取消了 %d 项排队删除", dev, removed))
		}
	}) {
		return
	}
	rs.writeSnapshot(w)
}

// ── 主线程状态快照与变更指纹 ──────────────────────────────────────────────

// remoteBlocked 是手机上「换一批」为什么点不了，能点时返回 ""。
// 不看挂载状态：遥控运行前会重新检查一遍（见 handleRun）。
func (a *app) remoteBlocked() string {
	switch {
	case a.running:
		return "正在运行"
	case len(a.allDirs()) == 0:
		return "尚未添加图库目录，请先在电脑上添加"
	case strings.TrimSpace(a.cfg.DestDir) == "":
		return "尚未设置壁纸文件夹，请先在电脑上设置"
	}
	return ""
}

// remoteRun 是手机上点了「换一批」（主线程）。
func (a *app) remoteRun(device string, allowDelete bool) error {
	if reason := a.remoteBlocked(); reason != "" {
		return errors.New(reason)
	}
	if !a.canRun() {
		return errors.New("图库目录都无法访问，图库可能没有挂载")
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
	// 运行中：这次会执行哪几步（filter / scan / copy / refresh）、当前步骤与进度
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
	WallsRev   string      `json:"walls_rev"`           // 壁纸列表的指纹，变了手机就重新拉 /api/wallpapers
	Dest       string      `json:"dest"`
	Sample     int         `json:"sample_count"`
	Library    int         `json:"library_dirs"`
	// 常用设置与记录统计（remoteextra.go）
	Settings *remoteSettings `json:"settings,omitempty"`  // 手机上能改的几项设置
	UndoName string          `json:"undo_name,omitempty"` // 最近一次可以撤销的移出
	Excluded int             `json:"excluded"`            // 「不再选」名单里有几张
	// 图库没连上时排队的删除原图（pending.go）；手机上显示「N 项等电脑连上图库后执行」，可以逐条取消
	Pending     int                 `json:"pending"`
	PendingList []remotePendingItem `json:"pending_items,omitempty"`
	// 图库目录（手机上只读显示）：路径、是筛选还是仅采样、挂载状态、统计
	Dirs []remoteDir `json:"dirs,omitempty"`
}

// remotePendingItem 是待删除队列里的一条（路径原样传回来取消）。
type remotePendingItem struct {
	Path    string `json:"path"`
	Display string `json:"display"` // ~ 缩写
	Wall    string `json:"wall,omitempty"`
	At      int64  `json:"at"` // Unix 秒
}

// remoteDir 是一个图库目录（只读）。
type remoteDir struct {
	Path    string `json:"path"`   // ~ 缩写
	Filter  bool   `json:"filter"` // true = 筛选 + 采样，false = 仅采样
	Mount   string `json:"mount"`  // ok / missing / slow / unknown
	Images  int    `json:"images"` // 上次成功运行时扫描到的合格图片数
	Folders int    `json:"folders"`
	Deleted int    `json:"deleted"` // 删除记录里这个目录下删过几张
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
		Fraction:    -1,
		Blocked:     a.remoteBlocked(),
		Unmounted:   a.unmountedCount(),
		WillDelete:  a.willDelete(),
		Wallpapers:  len(a.walls.all),
		WallsRev:    a.remoteWallsRev(),
		Dest:        tildify(a.cfg.DestDir),
		Sample:      int(a.num),
		Library:     len(a.allDirs()),
		Settings:    a.remoteSettings(),
		UndoName:    a.undoName(),
		Excluded:    len(a.cfg.Excluded),
		Pending:     len(a.pending),
		PendingList: a.remotePendingList(),
		Dirs:        a.remoteDirs(),
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

// remotePendingList 是待删除队列给手机看的那一份（主线程调用）。
func (a *app) remotePendingList() []remotePendingItem {
	items := make([]remotePendingItem, 0, len(a.pending))
	for _, e := range a.pending {
		items = append(items, remotePendingItem{Path: e.Path, Display: tildify(e.Path), Wall: e.Wall, At: e.AddedAt.Unix()})
	}
	return items
}

// remoteDirs 是图库目录列表（只读；主线程调用）。
func (a *app) remoteDirs() []remoteDir {
	dirs := make([]remoteDir, 0, len(a.cfg.FilterAndSampleDirs)+len(a.cfg.SampleOnlyDirs))
	add := func(d string, filter bool) {
		r := remoteDir{Path: tildify(d), Filter: filter, Mount: mountName(a.mountStateOf(d))}
		if st, ok := a.sourceStat(d); ok {
			r.Images, r.Folders = st.Images, st.Folders
		}
		r.Deleted = a.deletedIn(d)
		dirs = append(dirs, r)
	}
	for _, d := range a.cfg.FilterAndSampleDirs {
		add(d, true)
	}
	for _, d := range a.cfg.SampleOnlyDirs {
		add(d, false)
	}
	return dirs
}

// mountName 是挂载状态给手机的值。
func mountName(s mountState) string {
	switch s {
	case mountOK:
		return "ok"
	case mountMissing:
		return "missing"
	case mountSlow:
		return "slow"
	default:
		return "unknown"
	}
}

// remoteStamp 是 publishRemote 用来零开销判断是否需要重新生成与序列化状态快照的指纹。
// 所有影响 remoteSnapshot() 的状态都在这里以标量或短指针表达，未变化时直接短路。
type remoteStamp struct {
	port          int
	version       string
	cfgRev        uint64
	running       bool
	stopping      bool
	stage         core.Stage
	done, total   int
	runDelete     bool
	runRejected   int
	runDeleted    int
	runDelFailed  int
	logSeq        uint64
	runningSec    int64 // 运行中按秒刷新进度文案（如剩余时间），空闲时恒为 0
	last          *runResult
	lastGood      *core.Summary
	wallsDir      string
	wallsRev      string
	wallsSrcLen   int
	undoName      string
	pendingLen    int
	pendingFirst  string
	pendingLast   string
	pendingFirstT int64
	mountHash     uint64
	delSize       int64
	delMod        int64
	nextAuto      int64
}

func (a *app) currentRemoteStamp(port int) remoteStamp {
	var mountHash uint64
	for _, d := range a.cfg.FilterAndSampleDirs {
		mountHash = mountHash*31 + uint64(a.mountStateOf(d)) + 1
	}
	for _, d := range a.cfg.SampleOnlyDirs {
		mountHash = mountHash*31 + uint64(a.mountStateOf(d)) + 1
	}
	_ = a.deleteRecords() // 短 TTL 缓存，常规重绘无 syscall
	st := remoteStamp{
		port:        port,
		version:     a.version,
		cfgRev:      a.cfgRev,
		running:     a.running,
		stopping:    a.running && a.stopReq.Load(),
		last:        a.last,
		lastGood:    a.lastGood,
		wallsDir:    a.walls.dir,
		wallsRev:    a.remoteWallsRev(),
		wallsSrcLen: len(a.walls.sources),
		undoName:    a.undoName(),
		pendingLen:  len(a.pending),
		mountHash:   mountHash,
		delSize:     a.delCache.size,
		delMod:      a.delCache.mod.UnixNano(),
	}
	if a.running {
		st.stage, st.done, st.total = a.prog.stage, a.prog.done, a.prog.total
		st.runDelete = a.runDelete
		st.runRejected, st.runDeleted, st.runDelFailed = a.runRejected, a.runDeleted, a.runDelFailed
		st.logSeq = a.logSeq
		st.runningSec = time.Now().Unix()
	}
	if len(a.pending) > 0 {
		st.pendingFirst = a.pending[0].Path
		st.pendingLast = a.pending[len(a.pending)-1].Path
		st.pendingFirstT = a.pending[0].AddedAt.UnixNano()
	}
	if next := a.nextAutoRun(); !next.IsZero() {
		st.nextAuto = next.Unix()
	}
	return st
}

// publishRemote 在主线程上把最新状态交给手机遥控服务（没开启或状态未变化时跳过序列化）。
func (a *app) publishRemote() {
	if a.remote == nil {
		return
	}
	a.remote.setEnabled(a.cfg.RemoteEnabled)
	port, _ := a.remote.status()
	if port == 0 {
		a.remotePublished = false
		return
	}
	stamp := a.currentRemoteStamp(port)
	if a.remotePublished && stamp == a.lastRemoteStamp {
		return
	}
	snap := a.remoteSnapshot()
	a.remote.publishWalls(snap.WallsRev, &a.walls, a.isSampleOnlySource)
	data, err := json.Marshal(snap)
	if err != nil {
		return
	}
	a.remote.publish(data)
	a.lastRemoteStamp = stamp
	a.remotePublished = true
}
