package main

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

// TestIOSCoreLogic 编译并运行 iOS 共享层核心纯逻辑单元测试（Models.swift / CoreLogic.swift）：
// 覆盖离线队列去重与撤销恢复、离线图片缓存淘汰、小组件缓存池清理以及重连退避。
func TestIOSCoreLogic(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("iOS 纯逻辑测试仅在 macOS 上运行")
	}
	bin := filepath.Join(t.TempDir(), "ios_logic_test")
	cmd := exec.Command(
		"xcrun", "swiftc", "-parse-as-library",
		"../ios/ShiJing/Shared/Models.swift",
		"../ios/ShiJing/Shared/CoreLogic.swift",
		"testdata/ios_logic_test.swift",
		"-o", bin,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("编译 iOS 纯逻辑测试失败: %v\n%s", err, out)
	}
	if out, err := exec.Command(bin).CombinedOutput(); err != nil {
		t.Fatalf("iOS 纯逻辑测试失败: %v\n%s", err, out)
	}
}
