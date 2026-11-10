package main

import (
	"os"
	"testing"

	"desktop/core"
)

// 测试里绝不能真的重启系统的壁纸服务。
func TestMain(m *testing.M) {
	core.RefreshWallpaper = func() error { return nil }
	os.Exit(m.Run())
}
