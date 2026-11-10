// wallpaper 是拾景的命令行入口，等价于 python run.py：读取配置，依次筛选 → 采样复制 → 刷新系统壁纸。
//
//	go run ./cmd/wallpaper                      # 用桌面版同一份配置
//	go run ./cmd/wallpaper -config ../config.json
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

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

	logf := func(format string, args ...any) { fmt.Printf(format+"\n", args...) }
	core.ValidateConfig(cfg, logf)
	if _, err := core.RunPipeline(cfg, core.PathsIn(dataDir), core.Reporter{Log: logf}, nil); err != nil {
		fmt.Fprintln(os.Stderr, "❌", err)
		os.Exit(1)
	}
}
