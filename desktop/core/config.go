// Package core 是拾景的核心流程：筛选删除 → 采样复制/归档 → 清理壁纸缓存。
// 最初从 Python 版（已不再维护）移植而来，踩坑记录见仓库根目录 CLAUDE.md。
package core

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Config 与 Python 版 config.json 的字段一一对应，两个版本可以互相读写同一份文件。
type Config struct {
	FilterAndSampleDirs []string `json:"filter_and_sample_dirs"`
	SampleOnlyDirs      []string `json:"sample_only_dirs"`
	DestDir             string   `json:"dest_dir"`
	SampleCount         int      `json:"sample_count"`
	MinWidth            int      `json:"min_width"`
	MinHeight           int      `json:"min_height"`
	Mode                string   `json:"mode"` // "copy" | "symlink"
	BalanceFirst        bool     `json:"balance_first"`
	Incremental         bool     `json:"incremental"`
	DeleteDuringFilter  bool     `json:"delete_during_filter"`
	// RefreshWallpaper：复制完后重启 macOS 的壁纸服务，让文件夹轮换立刻用上新的一批。
	// JSON 键沿用以前「清除壁纸缓存」的名字，老配置里的开关继续生效。
	RefreshWallpaper   bool   `json:"clear_wallpaper_cache"`
	ArchiveEnabled     bool   `json:"archive_enabled"`
	ArchiveSubdirName  string `json:"archive_subdir_name"`
	ArchiveDirOverride string `json:"archive_dir_override"`
	ArchiveSMBRoot     string `json:"archive_smb_root"`
	ArchiveNFSRoot     string `json:"archive_nfs_root"`

	// PreferUnseen：优先选这一轮轮换里还没换上过的图，整个图库都换上过一遍再开始新一轮。
	PreferUnseen bool `json:"prefer_unseen"`
	// Excluded 是不再参与采样的原图（在概览页缩略图上「不再选它」）。
	Excluded []string `json:"excluded"`
	// AutoRunHours 大于 0 时，应用开着（包括关窗后在后台）每隔这么多小时自动换一批；
	// 自动运行不删除原图（筛选只模拟），删除只在手动运行时发生。
	AutoRunHours int `json:"auto_run_hours"`
	// Shortcuts 是界面里改过的快捷键（操作 id → "Cmd+Shift+Backspace"，空字符串表示不用快捷键）；
	// 没出现的用默认值。只有拾景界面用，命令行不管。
	Shortcuts map[string]string `json:"shortcuts,omitempty"`
}

const (
	DefaultMinWidth       = 3840
	DefaultMinHeight      = 2160
	DefaultMaxAspectRatio = 1.1 // 宽高比大于此值才算横屏
	DefaultArchiveSubdir  = "_WallpaperArchive"
)

// Defaults 对应 run.DEFAULTS，GUI 和 CLI 都从这里取默认值，避免两份漂移。
func Defaults() Config {
	return Config{
		FilterAndSampleDirs: []string{},
		SampleOnlyDirs:      []string{},
		DestDir:             "~/Pictures/Wallpapers0",
		SampleCount:         300,
		MinWidth:            DefaultMinWidth,
		MinHeight:           DefaultMinHeight,
		Mode:                "copy",
		BalanceFirst:        true,
		Incremental:         true,
		DeleteDuringFilter:  true,
		RefreshWallpaper:    true,
		ArchiveEnabled:      false,
		ArchiveSubdirName:   DefaultArchiveSubdir,
		PreferUnseen:        true,
		Excluded:            []string{},
	}
}

// LoadConfig 读取配置文件，缺失的字段用默认值补齐（等价于 {**DEFAULTS, **data}）。
// 文件不存在时返回默认值和 os.ErrNotExist 包装的错误，调用方自行决定是否当作错误。
func LoadConfig(path string) (Config, error) {
	cfg := Defaults()
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Defaults(), fmt.Errorf("配置文件 JSON 格式错误: %w", err)
	}
	if cfg.FilterAndSampleDirs == nil {
		cfg.FilterAndSampleDirs = []string{}
	}
	if cfg.SampleOnlyDirs == nil {
		cfg.SampleOnlyDirs = []string{}
	}
	if cfg.Excluded == nil {
		cfg.Excluded = []string{}
	}
	return cfg, nil
}

// SaveConfig 以与 Python 版相同的格式（2 空格缩进、不转义中文）写回配置。
func SaveConfig(path string, cfg Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ExpandUser 等价于 os.path.expanduser：只展开开头的 ~ 或 ~/。
func ExpandUser(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[1:])
		}
	}
	return p
}

// expanded 返回展开了 ~ 的副本（对应 run.load_config 里的那几处 expanduser）。
func (c Config) expanded() Config {
	c.DestDir = ExpandUser(c.DestDir)
	c.ArchiveDirOverride = ExpandUser(c.ArchiveDirOverride)
	c.ArchiveSMBRoot = ExpandUser(c.ArchiveSMBRoot)
	c.ArchiveNFSRoot = ExpandUser(c.ArchiveNFSRoot)
	return c
}

// DataDir 是 Go 版存放配置、增量状态、删除日志的目录：
// macOS 上为 ~/Library/Application Support/<appName>，与 MyGo 的 PathUserData 一致，
// 这样 GUI 和 CLI 不依赖可执行文件所在位置就能找到同一份文件。
func DataDir(appName string) (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, appName), nil
}

// MigrateDataDir 在改名后把旧数据目录搬到新位置：只在新目录还不存在、旧目录存在时才搬，
// 已经有新目录就什么都不做，不会覆盖。返回是否搬了。
func MigrateDataDir(oldDir, newDir string) (bool, error) {
	if lexists(newDir) || !exists(oldDir) {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(newDir), 0o755); err != nil {
		return false, err
	}
	return true, os.Rename(oldDir, newDir)
}
