// Package core 实现拾景的核心流程：筛选删除 → 采样复制/归档 → 刷新系统壁纸。
package core

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode/utf8"
)

// Profile 是一套配置方案（场景预设），保存一组图库目录、张数、画质与常用采样设置。
type Profile struct {
	Name                string   `json:"name"`
	FilterAndSampleDirs []string `json:"filter_and_sample_dirs"`
	SampleOnlyDirs      []string `json:"sample_only_dirs"`
	DestDir             string   `json:"dest_dir,omitempty"`
	SampleCount         int      `json:"sample_count"`
	MinWidth            int      `json:"min_width"`
	MinHeight           int      `json:"min_height"`
	Mode                string   `json:"mode,omitempty"`
	BalanceFirst        bool     `json:"balance_first"`
	PreferUnseen        bool     `json:"prefer_unseen"`
	DeleteDuringFilter  bool     `json:"delete_during_filter"`
}

// Config 保存桌面端与命令行共用的配置，持久化在 config.json 中。
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
	// RemoteEnabled：允许同一局域网里配对过的 iPhone 遥控（看进度、换一批、停止）。只有拾景界面用。
	RemoteEnabled bool `json:"remote_enabled,omitempty"`
	// ActiveProfile 是当前套用的配置方案名，空表示未选中方案。
	ActiveProfile string `json:"active_profile,omitempty"`
	// Profiles 是保存的多套配置方案（场景预设），可在桌面端与手机端一键切换。
	Profiles []Profile `json:"profiles,omitempty"`
}

const (
	DefaultMinWidth       = 3840
	DefaultMinHeight      = 2160
	DefaultMaxAspectRatio = 1.1 // 宽高比大于此值才算横屏
	DefaultArchiveSubdir  = "_WallpaperArchive"
	MaxProfileNameRunes   = 40
)

// Defaults 返回默认配置，GUI 和 CLI 共用，避免两份漂移。
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
	for i := range cfg.Profiles {
		cfg.Profiles[i] = normalizeProfile(cfg.Profiles[i])
	}
	if cfg.ActiveProfile != "" {
		if _, ok := cfg.FindProfile(cfg.ActiveProfile); !ok {
			cfg.ActiveProfile = ""
		}
	}
	return cfg, nil
}

func normalizeProfile(p Profile) Profile {
	p.Name = strings.TrimSpace(p.Name)
	if p.FilterAndSampleDirs == nil {
		p.FilterAndSampleDirs = []string{}
	}
	if p.SampleOnlyDirs == nil {
		p.SampleOnlyDirs = []string{}
	}
	if p.Mode != "copy" && p.Mode != "symlink" {
		p.Mode = "copy"
	}
	if p.SampleCount < 1 {
		p.SampleCount = Defaults().SampleCount
	}
	if p.MinWidth < 1 {
		p.MinWidth = DefaultMinWidth
	}
	if p.MinHeight < 1 {
		p.MinHeight = DefaultMinHeight
	}
	return p
}

// Clone 深拷贝一份方案，切片独立。
func (p Profile) Clone() Profile {
	p.FilterAndSampleDirs = nonNilClone(p.FilterAndSampleDirs)
	p.SampleOnlyDirs = nonNilClone(p.SampleOnlyDirs)
	return p
}

func nonNilClone(s []string) []string {
	if len(s) == 0 {
		return []string{}
	}
	return slices.Clone(s)
}

// Equal 比较两套方案的内容是否完全一致。
func (p Profile) Equal(o Profile) bool {
	return p.Name == o.Name &&
		p.DestDir == o.DestDir &&
		p.SampleCount == o.SampleCount &&
		p.MinWidth == o.MinWidth &&
		p.MinHeight == o.MinHeight &&
		p.Mode == o.Mode &&
		p.BalanceFirst == o.BalanceFirst &&
		p.PreferUnseen == o.PreferUnseen &&
		p.DeleteDuringFilter == o.DeleteDuringFilter &&
		slices.Equal(p.FilterAndSampleDirs, o.FilterAndSampleDirs) &&
		slices.Equal(p.SampleOnlyDirs, o.SampleOnlyDirs)
}

// WillDelete 返回套用这套方案后手动运行是否会删除不合格原图。
func (p Profile) WillDelete() bool {
	return p.DeleteDuringFilter && len(p.FilterAndSampleDirs) > 0
}

// CloneProfiles 深拷贝方案列表。
func CloneProfiles(src []Profile) []Profile {
	if len(src) == 0 {
		return nil
	}
	out := make([]Profile, len(src))
	for i, p := range src {
		out[i] = p.Clone()
	}
	return out
}

// ProfilesEqual 比较两个方案列表是否一致。
func ProfilesEqual(a, b []Profile) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].Equal(b[i]) {
			return false
		}
	}
	return true
}

// ProfileSnapshot 按当前配置生成一套方案（不修改原 Config）。
func (c Config) ProfileSnapshot(name string) Profile {
	return normalizeProfile(Profile{
		Name:                strings.TrimSpace(name),
		FilterAndSampleDirs: nonNilClone(c.FilterAndSampleDirs),
		SampleOnlyDirs:      nonNilClone(c.SampleOnlyDirs),
		DestDir:             c.DestDir,
		SampleCount:         c.SampleCount,
		MinWidth:            c.MinWidth,
		MinHeight:           c.MinHeight,
		Mode:                c.Mode,
		BalanceFirst:        c.BalanceFirst,
		PreferUnseen:        c.PreferUnseen,
		DeleteDuringFilter:  c.DeleteDuringFilter,
	})
}

// FindProfile 按名称查找方案。
func (c Config) FindProfile(name string) (Profile, bool) {
	for _, p := range c.Profiles {
		if p.Name == name {
			return p, true
		}
	}
	return Profile{}, false
}

// SaveProfile 把当前配置存为指定名称的方案（同名则覆盖更新），并设为当前激活方案。
func (c *Config) SaveProfile(name string) (Profile, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return Profile{}, fmt.Errorf("方案名称不能为空")
	}
	if utf8.RuneCountInString(name) > MaxProfileNameRunes {
		return Profile{}, fmt.Errorf("方案名称最多 %d 个字符", MaxProfileNameRunes)
	}
	p := c.ProfileSnapshot(name)
	if i := slices.IndexFunc(c.Profiles, func(it Profile) bool { return it.Name == name }); i >= 0 {
		c.Profiles[i] = p
	} else {
		c.Profiles = append(c.Profiles, p)
	}
	c.ActiveProfile = name
	return p.Clone(), nil
}

// ApplyProfile 把指定方案应用到当前配置，并设为当前激活方案。
func (c *Config) ApplyProfile(name string) (Profile, bool) {
	i := slices.IndexFunc(c.Profiles, func(it Profile) bool { return it.Name == name })
	if i < 0 {
		return Profile{}, false
	}
	p := normalizeProfile(c.Profiles[i]).Clone()
	c.FilterAndSampleDirs = nonNilClone(p.FilterAndSampleDirs)
	c.SampleOnlyDirs = nonNilClone(p.SampleOnlyDirs)
	if strings.TrimSpace(p.DestDir) != "" {
		c.DestDir = p.DestDir
	}
	c.SampleCount = p.SampleCount
	c.MinWidth = p.MinWidth
	c.MinHeight = p.MinHeight
	c.Mode = p.Mode
	c.BalanceFirst = p.BalanceFirst
	c.PreferUnseen = p.PreferUnseen
	c.DeleteDuringFilter = p.DeleteDuringFilter
	c.ActiveProfile = p.Name
	return p, true
}

// DeleteProfile 删除指定名称的方案；若正处于激活状态，一并清空 ActiveProfile。
func (c *Config) DeleteProfile(name string) bool {
	i := slices.IndexFunc(c.Profiles, func(it Profile) bool { return it.Name == name })
	if i < 0 {
		return false
	}
	c.Profiles = slices.Delete(c.Profiles, i, i+1)
	if len(c.Profiles) == 0 {
		c.Profiles = nil
	}
	if c.ActiveProfile == name {
		c.ActiveProfile = ""
	}
	return true
}

// ActiveProfileModified 返回当前配置相对已激活方案是否有未保存的改动。
func (c Config) ActiveProfileModified() bool {
	if c.ActiveProfile == "" {
		return false
	}
	p, ok := c.FindProfile(c.ActiveProfile)
	if !ok {
		return false
	}
	cur := c.ProfileSnapshot(p.Name)
	return !normalizeProfile(p).Equal(cur)
}

// SaveConfig 以 2 空格缩进、不转义中文的 JSON 格式写回配置。
func SaveConfig(path string, cfg Config) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return WriteFileAtomic(path, data, 0o644)
}

// BackupBadConfig 把读不了的配置文件改名成 config.json.bad-<时间> 留着：
// 读失败后界面用的是默认值，下一次自动保存就会把原文件覆盖掉，图库目录、排除名单都会丢。
// 返回备份的路径；文件不存在或改名失败返回空字符串。
func BackupBadConfig(path string) string {
	if !exists(path) {
		return ""
	}
	bak := path + ".bad-" + time.Now().Format("20060102-150405")
	if err := os.Rename(path, bak); err != nil {
		return ""
	}
	return bak
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

// expandDirs 展开目录列表中每一项开头的 ~。
func expandDirs(dirs []string) []string {
	if len(dirs) == 0 {
		return dirs
	}
	out := make([]string, len(dirs))
	for i, d := range dirs {
		out[i] = ExpandUser(d)
	}
	return out
}

// expanded 返回展开了 ~ 的副本（涵盖源目录、目标目录与归档相关路径）。
func (c Config) expanded() Config {
	c.FilterAndSampleDirs = expandDirs(c.FilterAndSampleDirs)
	c.SampleOnlyDirs = expandDirs(c.SampleOnlyDirs)
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
