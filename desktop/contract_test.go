package main

import (
	"context"
	"encoding/json"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"desktop/core"
)

// compileIOSContract 把 iOS 共享层生产代码（Models.swift / APIClient.swift）与契约测试驱动一起编成可执行文件。
func compileIOSContract(t *testing.T) string {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("iOS 契约测试仅在 macOS 上运行")
	}
	bin := filepath.Join(t.TempDir(), "ios_contract")
	cmd := exec.Command(
		"xcrun", "swiftc", "-parse-as-library",
		"../ios/ShiJing/Shared/Models.swift",
		"../ios/ShiJing/Shared/APIClient.swift",
		"testdata/ios_contract.swift",
		"-o", bin,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("编译 iOS 契约测试失败: %v\n%s", err, out)
	}
	return bin
}

func writeContractJSON(t *testing.T, dir, name string, v any) {
	t.Helper()
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatalf("序列化 %s 失败: %v", name, err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), b, 0o600); err != nil {
		t.Fatalf("写入 %s 失败: %v", name, err)
	}
}

// TestIOSContract 验证 macOS 桌面端 remoteServer 与 iOS 共享层（Models.swift / APIClient.swift）的协议契约：
//   - Schema：逐字段核对桌面端 JSON 响应与 iOS Codable 模型严格一致，防止字段改名、漏映射或悄悄漂移；
//   - Live：用真实 iOS APIClient 直连本机 remoteServer，端到端跑通鉴权、配对、快照、壁纸、图片、设置、记录、条件请求与 SSE。
func TestIOSContract(t *testing.T) {
	bin := compileIOSContract(t)

	t.Run("Schema", func(t *testing.T) {
		dir := t.TempDir()

		writeContractJSON(t, dir, "info.json", map[string]any{
			"app":       "拾景",
			"name":      "测试 Mac",
			"server_id": "11111111-2222-4333-8444-555555555555",
			"api":       remoteAPIVer,
			"version":   "0.4.27",
			"paired":    true,
		})

		fullState := remoteState{
			Version:      "0.4.27",
			Eyebrow:      "正在更换",
			Title:        "复制壁纸中",
			Running:      true,
			Stopping:     true,
			Steps:        []string{"filter", "scan", "copy", "refresh"},
			Stage:        "copy",
			Done:         3,
			Total:        10,
			Fraction:     0.3,
			Label:        "正在复制 3 / 10",
			LastLine:     "已复制 风景-a.jpg",
			RunDelete:    true,
			Rejected:     4,
			Deleted:      3,
			DeleteFailed: 1,
			Blocked:      "正在运行",
			Unmounted:    1,
			WillDelete:   true,
			DeleteNote:   "会删除不符合条件的原图",
			Last: &remoteLast{
				At:       1700000000,
				Status:   "failed",
				Error:    "部分图片复制失败",
				Selected: 10,
				Copied:   9,
				Failed:   1,
				Elapsed:  2.5,
				Brief:    "已换 9 张",
				Detail:   "跳过 1 张无法读取的图片",
			},
			NextAuto:   1700086400,
			Wallpapers: 3,
			WallsRev:   "rev-123",
			Dest:       "~/Pictures/Wallpapers0",
			Sample:     20,
			Library:    2,
			Settings: &remoteSettings{
				SampleCount:    20,
				AutoRunHours:   24,
				AutoOptions:    autoRunHours,
				Delete:         true,
				PreferUnseen:   true,
				Refresh:        true,
				BalanceFirst:   true,
				Incremental:    true,
				Mode:           "copy",
				MinWidth:       3840,
				MinHeight:      2160,
				MinPresets:     []remotePreset{{Label: "4K", W: 3840, H: 2160}},
				ArchiveEnabled: true,
				ArchiveSubdir:  "archive",
				ArchiveDir:     "~/Pictures/Archive",
			},
			UndoName: "风景-a.jpg",
			Excluded: 2,
			Pending:  1,
			PendingList: []remotePendingItem{
				{Path: "/Volumes/Media0/A/p.jpg", Display: "/Volumes/Media0/A/p.jpg", Wall: "风景-p.jpg", At: 1700000100},
			},
			Dirs: []remoteDir{
				{Path: "/Volumes/Media0/A", Filter: true, Mount: "ok", Images: 120, Folders: 6, Deleted: 2},
				{Path: "/Volumes/Media0/B", Filter: false, Mount: "missing", Images: 40, Folders: 2, Deleted: 0},
			},
			ActiveProfile:         "日常风景",
			ActiveProfileModified: true,
			Profiles: []remoteProfile{
				{Name: "日常风景", SampleCount: 20, MinWidth: 3840, MinHeight: 2160, LibraryDirs: 2, Mode: "copy", WillDelete: true},
				{Name: "暗色极简", SampleCount: 10, MinWidth: 2560, MinHeight: 1440, LibraryDirs: 1, Mode: "symlink", WillDelete: false},
			},
		}
		writeContractJSON(t, dir, "state_full.json", fullState)

		minimalState := remoteState{
			Version:    "0.4.27",
			Eyebrow:    "就绪",
			Title:      "尚未更换",
			Steps:      []string{"scan", "copy", "refresh"},
			Fraction:   -1,
			WallsRev:   "",
			Dest:       "~/Pictures/Wallpapers0",
			Sample:     10,
			Library:    0,
			Excluded:   0,
			Pending:    0,
			Wallpapers: 0,
		}
		writeContractJSON(t, dir, "state_minimal.json", minimalState)

		writeContractJSON(t, dir, "wallpapers.json", map[string]any{
			"rev":  "rev-123",
			"hero": "风景-a.jpg",
			"items": []remoteWall{
				{Name: "风景-a.jpg", Source: "/Volumes/Media0/A/a.jpg"},
				{Name: "精选-s.jpg", Source: "/Volumes/Media0/S/s.jpg", SampleOnly: true},
				{Name: "c.jpg"},
			},
		})

		writeContractJSON(t, dir, "deletions.json", map[string]any{
			"total":  2,
			"filter": 1,
			"manual": 1,
			"items": []remoteDeletion{
				{At: 1700000200, Name: "p.jpg", Dir: "/Volumes/Media0/A", Reason: "竖屏 1080×1920"},
				{At: 1700000100, Name: "q.jpg", Dir: "/Volumes/Media0/A"},
			},
		})

		writeContractJSON(t, dir, "excluded.json", map[string]any{
			"items": []remoteExcluded{
				{Path: "/Volumes/Media0/A/x.jpg", Display: "/Volumes/Media0/A/x.jpg"},
			},
		})

		writeContractJSON(t, dir, "log.json", map[string]any{
			"lines": []string{"第一行", "第二行"},
		})

		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, bin, "--mode", "schema", dir)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("Schema 契约校验失败: %v\n%s", err, out)
		}
	})

	t.Run("Live", func(t *testing.T) {
		h := newRemoteHarness(t)
		dest, lib := withWalls(t, h)
		sampleDir := t.TempDir()
		h.cfg.FilterAndSampleDirs = []string{lib}
		h.cfg.SampleOnlyDirs = []string{sampleDir}
		h.syncShadowFromConfig()
		if err := h.saveProfile("日常风景"); err != nil {
			t.Fatal(err)
		}
		h.cfg.FilterAndSampleDirs = []string{}
		h.cfg.SampleOnlyDirs = []string{sampleDir}
		h.cfg.SampleCount = 15
		h.cfg.MinWidth = 2560
		h.cfg.MinHeight = 1440
		h.cfg.DeleteDuringFilter = false
		h.syncShadowFromConfig()
		if err := h.saveProfile("暗色极简"); err != nil {
			t.Fatal(err)
		}
		if err := h.applyProfile("日常风景"); err != nil {
			t.Fatal(err)
		}
		h.settle(t, h.tt, func() bool { return !h.checkingMounts() })
		h.walls.heroPath = filepath.Join(dest, "风景-a.jpg")
		h.appendLog("契约测试日志行")

		core.LogDeletion(h.paths.DeleteLog, filepath.Join(lib, "del-filter.jpg"), 3840, 2160, "竖屏 1080×1920")
		core.LogDeletion(h.paths.DeleteLog, filepath.Join(lib, "del-manual.jpg"), 3840, 2160, core.ReasonManual)

		pendingFirst := filepath.Join(lib, "pending-1.jpg")
		h.pending = []core.PendingDelete{
			{Path: pendingFirst, Wall: "pending-1.jpg", AddedAt: time.Now().Add(-time.Minute)},
			{Path: filepath.Join(lib, "pending-2.jpg"), Wall: "pending-2.jpg", AddedAt: time.Now()},
		}

		release := make(chan struct{})
		h.release = release
		closedRelease := false
		closeRelease := func() {
			if !closedRelease {
				closedRelease = true
				close(release)
			}
		}
		t.Cleanup(closeRelease)

		qr := h.remote.startPair("扫码配对", "", true)
		h.tt.Frame()

		u, err := url.Parse(h.base)
		if err != nil {
			t.Fatal(err)
		}
		host, port, err := net.SplitHostPort(u.Host)
		if err != nil {
			t.Fatal(err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, bin, "--mode", "live")
		cmd.Env = append(os.Environ(),
			"CONTRACT_HOST="+host,
			"CONTRACT_PORT="+port,
			"CONTRACT_QR_CODE="+qr.code,
			"CONTRACT_PENDING_FIRST="+pendingFirst,
			"CONTRACT_EXCLUDED_A="+filepath.Join(lib, "offline-a.jpg"),
			"CONTRACT_EXCLUDED_B="+filepath.Join(lib, "offline-b.jpg"),
		)

		type runOut struct {
			out []byte
			err error
		}
		done := make(chan runOut, 1)
		go func() {
			out, err := cmd.CombinedOutput()
			done <- runOut{out: out, err: err}
		}()

		// 主测试 goroutine 持续泵送 fakeApp 的主线程队列并渲染帧，使 remoteServer 的 onMain 与 publishRemote 正常工作。
		var res runOut
	loop:
		for {
			h.mu.Lock()
			q := h.queue
			h.queue = nil
			h.mu.Unlock()
			for _, fn := range q {
				fn()
			}
			h.tt.Frame()

			select {
			case res = <-done:
				break loop
			case <-time.After(10 * time.Millisecond):
			}
		}

		// 确保可能仍在收尾的后台运行 goroutine 退出后再结束测试（避免 -race 期间清理冲突）。
		closeRelease()
		h.settle(t, h.tt, func() bool { return !h.running })

		if res.err != nil {
			t.Fatalf("Live 契约测试失败: %v\n%s", res.err, res.out)
		}
	})
}
