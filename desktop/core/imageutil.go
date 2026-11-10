package core

import (
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	_ "golang.org/x/image/bmp"
	_ "golang.org/x/image/tiff"
	_ "golang.org/x/image/webp"
)

// 与 image_utils.VALID_IMAGE_EXTENSIONS 一致。
var validImageExtensions = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true,
	".bmp": true, ".tiff": true, ".webp": true,
}

// Logf 是各步骤输出日志的方式（对应 Python 版的 print/logger.info）。
type Logf func(format string, args ...any)

// IsValidImage 只按扩展名判断是否为支持的图片格式。
func IsValidImage(path string) bool {
	return validImageExtensions[strings.ToLower(filepath.Ext(path))]
}

// CheckImageResolution 判断图片是否横屏（宽高比 > 1.1）且不小于最小分辨率。
// image.DecodeConfig 只解析文件头，不解码整张图（PIL 的 Image.open 同样是惰性读取）。
// 打不开/解析失败的图片视为不合格，与 Python 版一致。
func CheckImageResolution(path string, minWidth, minHeight int) bool {
	ok, _ := ImageVerdict(path, minWidth, minHeight)
	return ok
}

// ImageVerdict 和 CheckImageResolution 一样判断，另外给出不合格的原因（写进删除日志、显示在界面上）。
func ImageVerdict(path string, minWidth, minHeight int) (ok bool, reason string) {
	f, err := os.Open(path)
	if err != nil {
		return false, "打不开"
	}
	defer f.Close()
	cfg, _, err := image.DecodeConfig(f)
	if err != nil || cfg.Height == 0 {
		return false, "无法解析"
	}
	size := fmt.Sprintf("%d×%d", cfg.Width, cfg.Height)
	switch ratio := float64(cfg.Width) / float64(cfg.Height); {
	case ratio < 1/DefaultMaxAspectRatio:
		return false, "竖屏 " + size
	case ratio <= DefaultMaxAspectRatio:
		return false, "接近正方形 " + size
	case cfg.Width < minWidth || cfg.Height < minHeight:
		return false, "分辨率不足 " + size
	}
	return true, ""
}

// walk 按 Python os.walk(top, followlinks=False) 的语义遍历目录：
// 自顶向下，dirs 里包含指向目录的软链接但不下钻，读目录出错的子树静默跳过。
// Python 的 os.walk 默认 onerror=None，同样是静默跳过。
//
// 读目录是并发的（SMB 冷缓存时每次 readdir 要几十毫秒，串行遍历几百个文件夹要二十多秒，
// 见 CLAUDE.md 坑 12），但 fn 仍在调用方的 goroutine 里按先序遍历的顺序逐个调用，
// 某个目录读完、它前面的都回调过了就立刻回调，调用方可以边遍历边上报进度。
func walk(root string, fn func(dir string, dirs, files []string)) {
	type node struct {
		path        string
		dirs, files []string
		children    []*node
		ok          bool
		done        chan struct{}
	}
	sem := make(chan struct{}, metaWorkers)
	var read func(n *node)
	read = func(n *node) {
		sem <- struct{}{}
		dirs, files, descend, err := readDirSplit(n.path)
		<-sem
		if err == nil {
			n.ok, n.dirs, n.files = true, dirs, files
			for _, d := range descend {
				c := &node{path: filepath.Join(n.path, d), done: make(chan struct{})}
				n.children = append(n.children, c)
				go read(c)
			}
		}
		close(n.done)
	}
	top := &node{path: root, done: make(chan struct{})}
	go read(top)
	var visit func(n *node)
	visit = func(n *node) {
		<-n.done
		if !n.ok {
			return
		}
		fn(n.path, n.dirs, n.files)
		for _, c := range n.children {
			visit(c)
		}
	}
	visit(top)
}

// readDirSplit 读一个目录，按 os.walk 的方式分出子目录（含指向目录的软链接）、文件，
// 以及需要下钻的子目录（不含软链接）。
func readDirSplit(dir string) (dirs, files, descend []string, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, nil, err
	}
	for _, e := range entries {
		isDir := e.IsDir()
		if !isDir && e.Type()&fs.ModeSymlink != 0 {
			// os.walk 用 entry.is_dir()（跟随软链接）分类，但 followlinks=False 不下钻
			if st, err := os.Stat(filepath.Join(dir, e.Name())); err == nil && st.IsDir() {
				dirs = append(dirs, e.Name())
				continue
			}
		}
		if isDir {
			dirs = append(dirs, e.Name())
			descend = append(descend, e.Name())
		} else {
			files = append(files, e.Name())
		}
	}
	return dirs, files, descend, nil
}

// resolvePath 等价于 Path.resolve()（strict=False）：解析存在的那部分路径里的软链接，
// 不存在的尾部原样接上（macOS 的 /var → /private/var 这类前缀也要解析，否则比较会失配）。
func resolvePath(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		abs = filepath.Clean(p)
	}
	var tail []string
	for cur := abs; ; {
		if r, err := filepath.EvalSymlinks(cur); err == nil {
			for i := len(tail) - 1; i >= 0; i-- {
				r = filepath.Join(r, tail[i])
			}
			return r
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return abs
		}
		tail = append(tail, filepath.Base(cur))
		cur = parent
	}
}

// 访问 NAS 时的并发数。SMB 上每次 stat / 打开文件都是一次网络往返，冷缓存下约 1ms，
// 串行时几乎全部时间都在等网络；并发能把这些等待重叠起来（实测见 CLAUDE.md 坑 12）。
const (
	metaWorkers = 8 // stat、读图片文件头
	copyWorkers = 6 // 复制整张图片：再多带宽也不涨了
)

// parallelFor 用最多 workers 个 goroutine 对 0..n-1 调用 fn，全部完成后返回。
// fn 只能写各自下标对应的结果，顺序相关的处理（日志、删除）留给调用方事后串行做。
func parallelFor(n, workers int, fn func(i int)) {
	workers = min(workers, n)
	if workers <= 1 {
		for i := range n {
			fn(i)
		}
		return
	}
	var next atomic.Int64
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				fn(i)
			}
		}()
	}
	wg.Wait()
}

// checkResolutions 并发检查一批图片，返回与 paths 一一对应的结果。
func checkResolutions(paths []string, minWidth, minHeight int) []bool {
	ok, _ := checkVerdicts(paths, minWidth, minHeight)
	return ok
}

// checkVerdicts 同 checkResolutions，另外返回不合格的原因。
func checkVerdicts(paths []string, minWidth, minHeight int) (ok []bool, reasons []string) {
	ok, reasons = make([]bool, len(paths)), make([]string, len(paths))
	parallelFor(len(paths), metaWorkers, func(i int) {
		ok[i], reasons[i] = ImageVerdict(paths[i], minWidth, minHeight)
	})
	return ok, reasons
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// lexists 不跟随软链接：断掉的软链接也算"已存在"，生成目标文件名时用它避免撞名。
func lexists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}
