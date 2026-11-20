// wallpaper 是拾景的命令行入口：读取配置，依次执行筛选、采样复制与刷新系统壁纸。
//
//	go run ./cmd/wallpaper                      # 使用桌面版同一份配置
//	go run ./cmd/wallpaper -config ../config.json
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"desktop/core"
)

const appName = "拾景" // 与桌面版一致，共用数据目录

func main() {
	dataDir, err := core.DataDir(appName)
	if err != nil {
		fmt.Fprintln(os.Stderr, "❌", err)
		os.Exit(1)
	}
	configPath := flag.String("config", filepath.Join(dataDir, "config.json"), "配置文件路径")
	flag.Parse()

	cfg, err := core.LoadConfig(*configPath)
	if errors.Is(err, os.ErrNotExist) {
		fmt.Fprintf(os.Stderr, "❌ 配置文件不存在: %s\n", *configPath)
		os.Exit(1)
	} else if err != nil {
		fmt.Fprintln(os.Stderr, "❌", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logf := func(format string, args ...any) { fmt.Printf(format+"\n", args...) }
	core.ValidateConfig(cfg, logf)
	rep := core.Reporter{
		Log:  logf,
		Stop: func() bool { return ctx.Err() != nil },
	}
	if _, err := core.RunPipeline(cfg, core.PathsIn(dataDir), rep, nil); err != nil {
		if errors.Is(err, core.ErrCanceled) {
			fmt.Fprintln(os.Stderr, "⏹️ 已收到中断信号，已安全停止")
			os.Exit(130)
		}
		fmt.Fprintln(os.Stderr, "❌", err)
		os.Exit(1)
	}
}
