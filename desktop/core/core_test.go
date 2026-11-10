package core

import (
	"errors"
	"fmt"
	"image"
	"image/png"
	"io/fs"
	"math/rand/v2"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/image/bmp"
	"golang.org/x/image/tiff"
)

// 测试用的阈值：40x20，宽高比 > 1.1 才合格。
const tw, th = 40, 20

func writePNG(t *testing.T, path string, w, h int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, image.NewRGBA(image.Rect(0, 0, w, h))); err != nil {
		t.Fatal(err)
	}
}

var quiet = Reporter{}

func collect(lines *[]string) Logf {
	return func(f string, a ...any) { *lines = append(*lines, fmt.Sprintf(f, a...)) }
}

func TestCheckImageResolution(t *testing.T) {
	d := t.TempDir()
	cases := []struct {
		name string
		w, h int
		want bool
	}{
		{"landscape.png", 80, 40, true},
		{"exact.png", 40, 20, true},
		{"portrait.png", 40, 80, false},
		{"square.png", 60, 60, false},
		{"nearly-square.png", 55, 50, false}, // 1.1，不大于阈值
		{"small.png", 30, 15, false},
	}
	for _, c := range cases {
		p := filepath.Join(d, c.name)
		writePNG(t, p, c.w, c.h)
		if got := CheckImageResolution(p, tw, th); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
	// bmp / tiff 解码器已注册
	img := image.NewRGBA(image.Rect(0, 0, 80, 40))
	for name, enc := range map[string]func(*os.File) error{
		"a.bmp":  func(f *os.File) error { return bmp.Encode(f, img) },
		"a.tiff": func(f *os.File) error { return tiff.Encode(f, img, nil) },
	} {
		p := filepath.Join(d, name)
		f, _ := os.Create(p)
		if err := enc(f); err != nil {
			t.Fatal(err)
		}
		f.Close()
		if !CheckImageResolution(p, tw, th) {
			t.Errorf("%s 应该能读出分辨率", name)
		}
	}
	bad := filepath.Join(d, "broken.jpg")
	os.WriteFile(bad, []byte("not an image"), 0o644)
	if CheckImageResolution(bad, tw, th) {
		t.Error("损坏的图片应视为不合格")
	}
	if !IsValidImage("X.JPEG") || IsValidImage("a.heic") || IsValidImage("a.txt") {
		t.Error("扩展名判断不对")
	}
}

func TestSortImagesDeletesAndLogs(t *testing.T) {
	src := t.TempDir()
	data := t.TempDir()
	good := filepath.Join(src, "a", "good.png")
	bad := filepath.Join(src, "a", "bad.png")
	writePNG(t, good, 80, 40)
	writePNG(t, bad, 40, 80)
	os.WriteFile(filepath.Join(src, "a", "note.txt"), []byte("x"), 0o644)
	paths := PathsIn(data)

	// 模拟运行不删
	SortImages(SortOptions{Sources: []string{src}, MinWidth: tw, MinHeight: th}, quiet)
	if !exists(bad) {
		t.Fatal("模拟运行不应删除文件")
	}

	SortImages(SortOptions{Sources: []string{src}, MinWidth: tw, MinHeight: th, Delete: true,
		StateFile: paths.StateFile, DeleteLog: paths.DeleteLog}, quiet)
	if exists(bad) || !exists(good) || !exists(filepath.Join(src, "a", "note.txt")) {
		t.Fatal("应只删除不合格的图片")
	}
	log, _ := os.ReadFile(paths.DeleteLog)
	if !strings.Contains(string(log), bad) || !strings.Contains(string(log), "40x20") {
		t.Errorf("删除日志内容不对: %q", log)
	}
}

func TestSortImagesIncremental(t *testing.T) {
	src := t.TempDir()
	paths := PathsIn(t.TempDir())
	dir := filepath.Join(src, "set")
	writePNG(t, filepath.Join(dir, "good.png"), 80, 40)
	old := time.Now().Add(-48 * time.Hour)
	os.Chtimes(filepath.Join(dir, "good.png"), old, old)

	run := func(minW int) []string {
		var lines []string
		SortImages(SortOptions{Sources: []string{src}, MinWidth: minW, MinHeight: th,
			Incremental: true, StateFile: paths.StateFile}, Reporter{Log: collect(&lines)})
		return lines
	}
	skippedIn := func(lines []string) bool {
		for _, l := range lines {
			if strings.Contains(l, "已跳过") {
				return true
			}
		}
		return false
	}

	if skippedIn(run(tw)) {
		t.Fatal("第一次运行不应跳过")
	}
	if !skippedIn(run(tw)) {
		t.Fatal("没有变化的目录第二次应跳过")
	}
	// AppleDouble 影子文件、NAS 索引目录不算变化（坑 7）
	os.WriteFile(filepath.Join(dir, "._good.png"), []byte("x"), 0o644)
	os.MkdirAll(filepath.Join(dir, "@eaDir", "good.png"), 0o755)
	os.WriteFile(filepath.Join(dir, ".DS_Store"), []byte("x"), 0o644)
	if !skippedIn(run(tw)) {
		t.Fatal("噪声文件不应让目录被重新扫描")
	}
	// 新增真实图片要重新扫描
	writePNG(t, filepath.Join(dir, "new.png"), 80, 40)
	if skippedIn(run(tw)) {
		t.Fatal("新增图片后应重新扫描")
	}
	if !skippedIn(run(tw)) {
		t.Fatal("重新扫描后应再次跳过")
	}
	// 阈值变化让缓存失效（坑 10）
	lines := run(tw + 1)
	if skippedIn(lines) {
		t.Fatal("阈值变化后应全量重新检查")
	}
	if !strings.Contains(strings.Join(lines, "\n"), "增量缓存已失效") {
		t.Error("阈值变化应提示缓存失效")
	}
}

func TestCopySamplesNoImagesKeepsDest(t *testing.T) {
	dest := t.TempDir()
	keep := filepath.Join(dest, "old.png")
	os.WriteFile(keep, []byte("x"), 0o644)
	_, err := CopySamples(CopyOptions{Sources: []string{filepath.Join(t.TempDir(), "missing")},
		Dest: dest, Mode: "copy", Num: 3}, quiet, nil)
	if !errors.Is(err, ErrNoImages) {
		t.Fatalf("应返回 ErrNoImages，实际 %v", err)
	}
	if !exists(keep) {
		t.Fatal("扫描不到图片时不能清空目标目录")
	}
}

// 叶子文件夹多于采样数时，不同的随机种子要覆盖到不同的文件夹（坑 8）。
func TestSampleBalancedShuffle(t *testing.T) {
	src := t.TempDir()
	for i := range 20 {
		writePNG(t, filepath.Join(src, fmt.Sprintf("f%02d", i), "a.png"), 80, 40)
	}
	_, grouped, order := scanImages([]string{src}, nil, tw, th, nil)
	if len(grouped) != 20 {
		t.Fatalf("叶子文件夹数 %d", len(grouped))
	}
	union := map[string]bool{}
	sets := map[string]bool{}
	for seed := range uint64(8) {
		sel := sampleBalanced(grouped, order, 5, rand.New(rand.NewPCG(seed, seed)))
		if len(sel) != 5 {
			t.Fatalf("应选 5 张，实际 %d", len(sel))
		}
		var key []string
		for _, s := range sel {
			union[filepath.Dir(s.path)] = true
			key = append(key, filepath.Dir(s.path))
		}
		sets[strings.Join(key, ",")] = true
	}
	if len(sets) < 2 || len(union) <= 5 {
		t.Errorf("不同种子覆盖的文件夹应不同：%d 种组合，并集 %d 个", len(sets), len(union))
	}
}

func TestCopySamplesBalancedFillsAndNames(t *testing.T) {
	src := t.TempDir()
	dest := filepath.Join(t.TempDir(), "dest")
	for i := range 3 {
		for j := range 4 {
			writePNG(t, filepath.Join(src, fmt.Sprintf("set%d", i), fmt.Sprintf("p%d.png", j)), 80, 40)
		}
	}
	// 非叶子目录里的图片也参与扁平列表，但不构成叶子分组
	writePNG(t, filepath.Join(src, "top.png"), 80, 40)

	_, err := CopySamples(CopyOptions{Sources: []string{src}, Dest: dest, Mode: "copy", Num: 7,
		BalanceFirst: true}, quiet, rand.New(rand.NewPCG(1, 2)))
	if err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(dest)
	if len(entries) != 7 {
		t.Fatalf("应复制 7 张，实际 %d", len(entries))
	}
	folders := map[string]bool{}
	for _, e := range entries {
		if !e.Type().IsRegular() {
			t.Errorf("copy 模式应为普通文件: %s", e.Name())
		}
		prefix, _, ok := strings.Cut(e.Name(), "-")
		if !ok || !strings.HasPrefix(prefix, "set") {
			t.Errorf("文件名应以上层目录名为前缀: %s", e.Name())
		}
		folders[prefix] = true
	}
	if len(folders) != 3 {
		t.Errorf("平衡采样应覆盖全部 3 个叶子文件夹，实际 %d", len(folders))
	}
}

func TestCopySamplesSymlinkAndFilterSources(t *testing.T) {
	root := t.TempDir()
	filterSrc := filepath.Join(root, "filtered")
	sampleOnly := filepath.Join(root, "fav")
	writePNG(t, filepath.Join(filterSrc, "a", "ok.png"), 80, 40)
	writePNG(t, filepath.Join(sampleOnly, "b", "ok.png"), 80, 40)
	writePNG(t, filepath.Join(sampleOnly, "b", "portrait.png"), 40, 80)
	dest := filepath.Join(root, "dest")

	_, err := CopySamples(CopyOptions{Sources: []string{filterSrc, sampleOnly}, Dest: dest,
		Mode: "symlink", Num: 10, FilterSources: []string{sampleOnly},
		MinWidth: tw, MinHeight: th}, quiet, nil)
	if err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(dest)
	if len(entries) != 2 {
		t.Fatalf("仅采样目录里的竖屏图应被过滤，实际 %d 张", len(entries))
	}
	for _, e := range entries {
		link := filepath.Join(dest, e.Name())
		target, err := os.Readlink(link)
		if err != nil || filepath.IsAbs(target) {
			t.Errorf("应为相对路径软链接: %s -> %q (%v)", e.Name(), target, err)
		}
		if !exists(link) {
			t.Errorf("软链接指向的文件应存在: %s", e.Name())
		}
	}
}

func TestArchiveHardLinkWithTranslation(t *testing.T) {
	// smb/ 与 nfs/ 模拟同一份数据的两个挂载点：采样走 smb，归档链接换算到 nfs
	root := t.TempDir()
	smb := filepath.Join(root, "smb")
	nfs := filepath.Join(root, "nfs")
	writePNG(t, filepath.Join(smb, "lib", "set", "a.png"), 80, 40)
	writePNG(t, filepath.Join(nfs, "lib", "set", "a.png"), 80, 40)
	// 归档目录里的旧内容应被清空，但目录本身保留
	archive := filepath.Join(nfs, DefaultArchiveSubdir)
	writePNG(t, filepath.Join(archive, "stale.png"), 80, 40)
	before, _ := os.Stat(archive)

	_, err := CopySamples(CopyOptions{Sources: []string{filepath.Join(smb, "lib")},
		Dest: filepath.Join(root, "dest"), Mode: "copy", Num: 1,
		ArchiveEnabled: true, ArchiveSMBRoot: smb, ArchiveNFSRoot: nfs}, quiet, nil)
	if err != nil {
		t.Fatal(err)
	}
	if exists(filepath.Join(archive, "stale.png")) {
		t.Error("归档目录旧内容应被清空")
	}
	after, _ := os.Stat(archive)
	if !os.SameFile(before, after) {
		t.Error("归档目录本身不应被删除重建")
	}
	linked, err := os.Stat(filepath.Join(archive, "set-a.png"))
	if err != nil {
		t.Fatal(err)
	}
	nfsSrc, _ := os.Stat(filepath.Join(nfs, "lib", "set", "a.png"))
	if !os.SameFile(linked, nfsSrc) {
		t.Error("归档应是指向 NFS 路径源文件的硬链接")
	}
}

func TestTranslateSourceForArchive(t *testing.T) {
	root := t.TempDir()
	smb := filepath.Join(root, "smb")
	os.MkdirAll(filepath.Join(smb, "x"), 0o755)
	if got := translateSourceForArchive(filepath.Join(smb, "x", "a.png"), smb, "/nfs"); got != "/nfs/x/a.png" {
		t.Errorf("got %s", got)
	}
	other := filepath.Join(root, "smb2", "a.png")
	if got := translateSourceForArchive(other, smb, "/nfs"); got != other {
		t.Errorf("不在 SMB 根路径下应原样返回，got %s", got)
	}
	if got := translateSourceForArchive("/a/b.png", "", "/nfs"); got != "/a/b.png" {
		t.Errorf("未配置时应原样返回，got %s", got)
	}
}

func TestGenerateFilenameConflicts(t *testing.T) {
	dest := t.TempDir()
	src := "/lib/set/a.png"
	first := generateFilename(src, dest, nil)
	os.WriteFile(first, nil, 0o644)
	second := generateFilename(src, dest, nil)
	os.Symlink("/nonexistent", second) // 断掉的软链接也算占用
	third := generateFilename(src, dest, nil)
	if filepath.Base(first) != "set-a.png" || filepath.Base(second) != "set-a_1.png" || filepath.Base(third) != "set-a_2.png" {
		t.Errorf("got %s %s %s", first, second, third)
	}
}

func TestLoadConfigMergesDefaultsAndReadsPythonConfig(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(p, []byte(`{"sample_count": 12, "archive_enabled": true}`), 0o644)
	cfg, err := LoadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SampleCount != 12 || !cfg.ArchiveEnabled || cfg.MinWidth != DefaultMinWidth || cfg.Mode != "copy" || !cfg.BalanceFirst {
		t.Errorf("默认值合并不对: %+v", cfg)
	}
	if _, err := LoadConfig(filepath.Join(t.TempDir(), "none.json")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("缺失文件应返回 ErrNotExist: %v", err)
	}
	// 仓库里的 Python 版配置可以直接读，保存后字段名不变
	if py, err := LoadConfig("../../config.json"); err == nil {
		out := filepath.Join(t.TempDir(), "c.json")
		if err := SaveConfig(out, py); err != nil {
			t.Fatal(err)
		}
		back, _ := LoadConfig(out)
		if fmt.Sprint(back) != fmt.Sprint(py) {
			t.Error("保存再读取后配置应一致")
		}
	}
	home, _ := os.UserHomeDir()
	if ExpandUser("~/x") != filepath.Join(home, "x") || ExpandUser("/a/~") != "/a/~" {
		t.Error("ExpandUser 不对")
	}
}

func TestMigrateDataDir(t *testing.T) {
	root := t.TempDir()
	oldDir, newDir := filepath.Join(root, "old"), filepath.Join(root, "new")
	if moved, err := MigrateDataDir(oldDir, newDir); moved || err != nil {
		t.Fatalf("旧目录不存在时不应迁移: %v %v", moved, err)
	}
	os.MkdirAll(oldDir, 0o755)
	os.WriteFile(filepath.Join(oldDir, "config.json"), []byte("{}"), 0o644)
	if moved, err := MigrateDataDir(oldDir, newDir); !moved || err != nil {
		t.Fatalf("应迁移: %v %v", moved, err)
	}
	if !exists(filepath.Join(newDir, "config.json")) || exists(oldDir) {
		t.Fatal("迁移后文件应在新目录")
	}
	os.MkdirAll(oldDir, 0o755)
	if moved, _ := MigrateDataDir(oldDir, newDir); moved {
		t.Fatal("新目录已存在时不应覆盖")
	}
}

func TestRunPipelineEndToEnd(t *testing.T) {
	root := t.TempDir()
	lib := filepath.Join(root, "lib")
	fav := filepath.Join(root, "fav")
	writePNG(t, filepath.Join(lib, "s1", "good.png"), 80, 40)
	writePNG(t, filepath.Join(lib, "s1", "bad.png"), 30, 60)
	writePNG(t, filepath.Join(fav, "s2", "good.png"), 80, 40)
	refreshed := 0
	stubRefresh(t, func() error { refreshed++; return nil })

	cfg := Defaults()
	cfg.FilterAndSampleDirs = []string{lib}
	cfg.SampleOnlyDirs = []string{fav}
	cfg.DestDir = filepath.Join(root, "dest")
	cfg.MinWidth, cfg.MinHeight = tw, th
	var lines []string
	stages := map[Stage]bool{}
	copyDone, copyTotal := 0, 0
	rep := Reporter{Log: collect(&lines), Progress: func(s Stage, done, total int) {
		stages[s] = true
		if s == StageCopy {
			copyDone, copyTotal = done, total
		}
	}}
	sum, err := RunPipeline(cfg, PathsIn(filepath.Join(root, "data")), rep, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(stages) != 4 || copyDone != 2 || copyTotal != 2 {
		t.Errorf("进度上报不完整: stages=%v copy=%d/%d", stages, copyDone, copyTotal)
	}
	if sum.Sort.Deleted != 1 || sum.Sort.Rejected != 1 || sum.Copy.Copied != 2 || sum.Copy.Selected != 2 ||
		sum.Copy.Failed != 0 || !sum.WallpaperRefreshed || refreshed != 1 || sum.Elapsed <= 0 {
		t.Errorf("运行结果不对: %+v", sum)
	}
	if exists(filepath.Join(lib, "s1", "bad.png")) {
		t.Error("筛选步骤应删除不合格图片")
	}
	if entries, _ := os.ReadDir(cfg.DestDir); len(entries) != 2 {
		t.Errorf("目标目录应有 2 张，实际 %d", len(entries))
	}
	if lines[len(lines)-1] != "✅ 所有操作完成 - 壁纸已更新" {
		t.Errorf("最后一行: %q", lines[len(lines)-1])
	}
}

// 复制是并发的：同一批里两张"上层目录名-文件名"相同的图片必须分到不同的目标名，
// 不能都看磁盘上还不存在而写到同一个文件。
func TestCopySamplesSameNameInOneBatch(t *testing.T) {
	root := t.TempDir()
	var sources []string
	for _, lib := range []string{"libA", "libB", "libC"} {
		src := filepath.Join(root, lib)
		writePNG(t, filepath.Join(src, "set", "a.png"), 80, 40)
		sources = append(sources, src)
	}
	dest := filepath.Join(root, "dest")
	res, err := CopySamples(CopyOptions{Sources: sources, Dest: dest, Mode: "copy", Num: 3}, quiet, rand.New(rand.NewPCG(1, 1)))
	if err != nil || res.Copied != 3 || res.Failed != 0 {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	entries, _ := os.ReadDir(dest)
	if len(entries) != 3 {
		t.Fatalf("目标目录应有 3 个文件，got %d", len(entries))
	}
}

// 分辨率检查改成并发后，扫描结果的顺序和过滤结果必须和串行时一致。
func TestScanImagesKeepsOrderWithParallelChecks(t *testing.T) {
	root := t.TempDir()
	var want []string
	for i := range 40 {
		p := filepath.Join(root, fmt.Sprintf("d%02d", i%5), fmt.Sprintf("img%02d.png", i))
		if i%3 == 0 {
			writePNG(t, p, 40, 80) // 竖屏，应被过滤
			continue
		}
		writePNG(t, p, 80, 40)
	}
	walk(root, func(dir string, _, files []string) {
		for _, f := range files {
			p := filepath.Join(dir, f)
			if CheckImageResolution(p, tw, th) {
				want = append(want, p)
			}
		}
	})
	all, grouped, leaves := scanImages([]string{root}, map[string]bool{resolvePath(root): true}, tw, th, nil)
	var got []string
	for _, img := range all {
		got = append(got, img.path)
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("顺序或内容不一致:\ngot  %v\nwant %v", got, want)
	}
	if len(grouped) != 5 || len(leaves) != 5 {
		t.Fatalf("应有 5 个叶子文件夹，got %d / %d", len(grouped), len(leaves))
	}
}

// 停止：筛选到一半停下时，没检查的文件夹不记入增量状态，壁纸目录原样保留；
// 复制阶段停下时不再开始新的图片。
func TestRunPipelineStop(t *testing.T) {
	root := t.TempDir()
	lib := filepath.Join(root, "lib")
	for _, d := range []string{"a", "b", "c"} {
		writePNG(t, filepath.Join(lib, d, "good.png"), 80, 40)
	}
	dest := filepath.Join(root, "dest")
	writePNG(t, filepath.Join(dest, "old.png"), 80, 40)

	cfg := Defaults()
	cfg.FilterAndSampleDirs = []string{lib}
	cfg.DestDir = dest
	cfg.MinWidth, cfg.MinHeight = tw, th
	cfg.RefreshWallpaper = false
	paths := PathsIn(filepath.Join(root, "data"))

	// 第一个文件夹检查完就停
	stop := false
	rep := Reporter{
		Progress: func(s Stage, done, total int) {
			if s == StageFilter && total > 0 && done == 1 {
				stop = true
			}
		},
		Stop: func() bool { return stop },
	}
	sum, err := RunPipeline(cfg, paths, rep, nil)
	if !errors.Is(err, ErrCanceled) || sum.Sort.Dirs != 1 {
		t.Fatalf("应在筛选第一个文件夹后停止: err=%v sort=%+v", err, sum.Sort)
	}
	if entries, _ := os.ReadDir(dest); len(entries) != 1 {
		t.Errorf("停止后壁纸目录应原样保留，实际 %d 项", len(entries))
	}
	if st := loadState(paths.StateFile); len(st.Dirs) != 1 {
		t.Errorf("增量状态只应记录检查过的 1 个文件夹: %v", st.Dirs)
	}

	// 复制第一张之后停（图片数要比并发数多，才看得出"不再开始新的"）
	lib2 := filepath.Join(root, "lib2")
	for i := range 40 {
		writePNG(t, filepath.Join(lib2, fmt.Sprintf("d%02d", i), "good.png"), 80, 40)
	}
	stop = false
	cfg.FilterAndSampleDirs, cfg.SampleOnlyDirs = nil, []string{lib2}
	var mu sync.Mutex
	rep = Reporter{
		Progress: func(s Stage, done, _ int) {
			mu.Lock()
			defer mu.Unlock()
			if s == StageCopy && done == 1 {
				stop = true
			}
		},
		Stop: func() bool { mu.Lock(); defer mu.Unlock(); return stop },
	}
	sum, err = RunPipeline(cfg, paths, rep, nil)
	if !errors.Is(err, ErrCanceled) || sum.Copy.Copied == 0 || sum.Copy.Copied >= 40 {
		t.Fatalf("应在复制中途停止: err=%v copy=%+v", err, sum.Copy)
	}
}

// 并发读目录后回调顺序仍要和串行的先序遍历一致（采样、日志、增量状态都依赖这个顺序）。
func TestWalkOrderMatchesSerial(t *testing.T) {
	root := t.TempDir()
	for _, p := range []string{"b/y/1.jpg", "b/x/2.jpg", "a/3.jpg", "a/z/q/4.jpg", "c/5.jpg", "6.jpg"} {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var want []string
	filepath.WalkDir(root, func(p string, d fs.DirEntry, _ error) error {
		if d.IsDir() {
			want = append(want, p)
		}
		return nil
	})
	for range 20 {
		var got []string
		walk(root, func(dir string, _, _ []string) { got = append(got, dir) })
		if !slices.Equal(got, want) {
			t.Fatalf("遍历顺序不对:\n got %v\nwant %v", got, want)
		}
	}
}

// stubRefresh 替换掉重启系统壁纸服务的操作，测试结束后还原。
func stubRefresh(t *testing.T, fn func() error) {
	old := RefreshWallpaper
	RefreshWallpaper = fn
	t.Cleanup(func() { RefreshWallpaper = old })
}
