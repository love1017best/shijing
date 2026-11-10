package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
)

// ErrNoImages 对应 Python 版的 CopyError：扫描不到图片时不动目标目录。
var ErrNoImages = errors.New("未找到符合条件的图片文件（源目录可能未挂载）；目标目录未被改动")

// CopyOptions 对应 image_copyer.run_copy 的 cfg（只保留 run.py 用到的字段）。
type CopyOptions struct {
	Sources       []string
	Dest          string
	Mode          string // "copy" | "symlink"
	Num           int
	BalanceFirst  bool
	FilterSources []string // 采样时需要按分辨率过滤的源目录（即「仅采样目录」）
	MinWidth      int
	MinHeight     int

	ArchiveEnabled     bool
	ArchiveSubdirName  string
	ArchiveDirOverride string
	ArchiveSMBRoot     string
	ArchiveNFSRoot     string

	// SelectionFile 记录这一轮选中的原图路径；下一轮据此算有多少张和上一轮重复。为空则不记录。
	SelectionFile string
	// HistoryFile 记录这一轮轮换里换上过的原图；PreferUnseen 时优先选不在里面的。
	HistoryFile  string
	PreferUnseen bool
	Excluded     []string // 不参与采样的原图
}

// sourceImage 是一张候选图片：它来自哪个源目录、文件路径是什么。
type sourceImage struct {
	sourceDir string
	path      string
}

// scanImages 一次遍历同时得到扁平列表和按叶子文件夹（没有子目录的文件夹）分组的结果
// （CLAUDE.md 坑 9：以前遍历两遍）。filter 里的源目录才做分辨率检查。
//
// 分两步：先遍历拿到全部候选图片，再把需要检查分辨率的那些一次性并发检查
// （逐张串行打开 NAS 上的图片曾经占了扫描阶段九成的时间），最后按遍历顺序组装结果。
func scanImages(sources []string, filter map[string]bool, minW, minH int, onDir func(n int)) ([]sourceImage, map[string][]sourceImage, []string) {
	type dirScan struct {
		root   string
		isLeaf bool
		imgs   []sourceImage
		check  bool
	}
	var scanned []dirScan
	var toCheck []string
	seen := 0
	for _, src := range sources {
		if st, err := os.Stat(src); err != nil || !st.IsDir() {
			continue
		}
		needCheck := filter[resolvePath(src)]
		walk(src, func(root string, dirs, files []string) {
			seen++
			if onDir != nil {
				onDir(seen)
			}
			d := dirScan{root: root, isLeaf: len(dirs) == 0, check: needCheck}
			for _, f := range files {
				if p := filepath.Join(root, f); IsValidImage(p) {
					d.imgs = append(d.imgs, sourceImage{src, p})
					if needCheck {
						toCheck = append(toCheck, p)
					}
				}
			}
			if len(d.imgs) > 0 {
				scanned = append(scanned, d)
			}
		})
	}
	ok := checkResolutions(toCheck, minW, minH)

	var all []sourceImage
	grouped := map[string][]sourceImage{}
	var leafOrder []string
	k := 0 // toCheck / ok 的下标，与遍历顺序一致
	for _, d := range scanned {
		var here []sourceImage
		for _, img := range d.imgs {
			if d.check {
				pass := ok[k]
				k++
				if !pass {
					continue
				}
			}
			here = append(here, img)
		}
		all = append(all, here...)
		if d.isLeaf && len(here) > 0 {
			if _, seen := grouped[d.root]; !seen {
				leafOrder = append(leafOrder, d.root)
			}
			grouped[d.root] = append(grouped[d.root], here...)
		}
	}
	return all, grouped, leafOrder
}

// sampleBalanced 先给每个叶子文件夹选 1 张，再从剩下的图片里随机补足。
// 第一轮之前必须打乱文件夹顺序（CLAUDE.md 坑 8），否则叶子文件夹多于采样数时
// 遍历顺序靠后的文件夹永远选不到。
func sampleBalanced(grouped map[string][]sourceImage, leafOrder []string, total int, r *rand.Rand) []sourceImage {
	leaves := append([]string(nil), leafOrder...)
	r.Shuffle(len(leaves), func(i, j int) { leaves[i], leaves[j] = leaves[j], leaves[i] })

	var selected []sourceImage
	chosen := map[string]bool{}
	for _, leaf := range leaves {
		if len(selected) >= total {
			return selected
		}
		imgs := grouped[leaf]
		img := imgs[r.IntN(len(imgs))]
		selected = append(selected, img)
		chosen[img.path] = true
	}
	var rest []sourceImage
	for _, leaf := range leafOrder {
		for _, img := range grouped[leaf] {
			if !chosen[img.path] {
				rest = append(rest, img)
			}
		}
	}
	return append(selected, sampleN(rest, total-len(selected), r)...)
}

// sampleN 等价于 random.sample：不放回地随机取 n 个（n 超过长度时取全部）。
func sampleN(items []sourceImage, n int, r *rand.Rand) []sourceImage {
	if n <= 0 {
		return nil
	}
	pool := append([]sourceImage(nil), items...)
	if n > len(pool) {
		n = len(pool)
	}
	for i := 0; i < n; i++ {
		j := i + r.IntN(len(pool)-i)
		pool[i], pool[j] = pool[j], pool[i]
	}
	return pool[:n]
}

// generateFilename 生成「上层目录名-原文件名」，冲突时加 _1、_2… 后缀。
// taken 记录本轮已经分配出去、但可能还没真正写到磁盘上的名字（复制是并发的，
// 只看磁盘会给两张同名图片分到同一个目标路径）；生成的名字会加进 taken。taken 可以为 nil。
// destName 是原图复制到壁纸文件夹后的名字（不重名时）：「上级文件夹-原名」。
func destName(src string) string {
	return filepath.Base(filepath.Dir(src)) + "-" + filepath.Base(src)
}

func generateFilename(src, destDir string, taken map[string]bool) string {
	name := filepath.Base(src)
	parent := filepath.Base(filepath.Dir(src))
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	dest := filepath.Join(destDir, destName(src))
	for i := 1; taken[dest] || lexists(dest); i++ {
		dest = filepath.Join(destDir, fmt.Sprintf("%s-%s_%d%s", parent, stem, i, ext))
	}
	if taken != nil {
		taken[dest] = true
	}
	return dest
}

// cleanDirectory 删除目录再重建（只用于本地的 dest_dir）。
func cleanDirectory(dir string) error {
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	return os.MkdirAll(dir, 0o755)
}

// clearDirectoryContents 只清空内容、不删目录本身（CLAUDE.md 坑 3）：
// 网络卷上或正被 Finder 打开的目录，rmdir 自身容易 Resource busy。
func clearDirectoryContents(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

// resolveArchiveDir：有覆盖路径就用它，否则用源目录自身的上级路径，再接归档子文件夹名。
func resolveArchiveDir(sourceDir, override, subdir string) string {
	parent := override
	if parent == "" {
		parent = filepath.Dir(resolvePath(sourceDir))
	}
	return filepath.Join(parent, subdir)
}

// translateSourceForArchive 把 SMB 挂载点下的源路径换算成 NFS 挂载点下的等价路径，
// 只用于建归档硬链接（CLAUDE.md 坑 5：硬链接两端必须在同一个挂载点）。
func translateSourceForArchive(src, smbRoot, nfsRoot string) string {
	if smbRoot == "" || nfsRoot == "" {
		return src
	}
	rel, err := filepath.Rel(resolvePath(smbRoot), resolvePath(src))
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return src
	}
	return filepath.Join(nfsRoot, rel)
}

// cleanupNFSAppleDoubleSidecar 删除 macOS NFS 客户端在 link() 后自动生成的 ._<文件名>。
func cleanupNFSAppleDoubleSidecar(path string) {
	sidecar := filepath.Join(filepath.Dir(path), "._"+filepath.Base(path))
	if lexists(sidecar) {
		_ = os.Remove(sidecar)
	}
}

// copyFile 先复制内容，再尽力还原权限和时间戳。还原失败不算复制失败
// （CLAUDE.md 坑 4：NAS 文件带 SF_ARCHIVED 等 flags 时 copystat 会假性报错）。
// Go 本来就不复制 st_flags，这里只还原 mode 和 mtime/atime。
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	if st, err := in.Stat(); err == nil {
		_ = os.Chmod(dst, st.Mode().Perm())
		_ = os.Chtimes(dst, st.ModTime(), st.ModTime())
	}
	return nil
}

func relSymlink(target, linkDir, linkPath string) error {
	rel, err := filepath.Rel(linkDir, target)
	if err != nil {
		rel = target
	}
	return os.Symlink(rel, linkPath)
}

// copyJob 是一张图片要做的全部事情，在串行的准备阶段算好，执行阶段并发跑。
type copyJob struct {
	img         sourceImage
	dest        string
	archiveDir  string // 为空表示不归档
	archivePath string
	archiveErr  string // 准备阶段就确定无法归档的原因（日志用）
}

// planCopies 串行地为每张图分配目标文件名和归档路径。名字冲突检测依赖"之前分配过哪些名字"，
// 必须在并发复制之前一次算完；归档目录的存在检查和 MkdirAll 也每个目录只做一次。
func planCopies(images []sourceImage, destDir string, o CopyOptions, archiveOverride string) []copyJob {
	jobs := make([]copyJob, len(images))
	takenDest := map[string]bool{}
	takenArchive := map[string]bool{}
	dirReady := map[string]string{} // archiveDir → "" 可用，否则为不可用原因
	for i, img := range images {
		j := copyJob{img: img, dest: generateFilename(img.path, destDir, takenDest)}
		if o.ArchiveEnabled {
			ad := resolveArchiveDir(img.sourceDir, archiveOverride, o.ArchiveSubdirName)
			reason, seen := dirReady[ad]
			if !seen {
				switch parent := filepath.Dir(ad); {
				case !exists(parent):
					reason = "⚠️ 归档父路径不存在，跳过: " + parent
				default:
					if err := os.MkdirAll(ad, 0o755); err != nil {
						reason = "归档失败: " + err.Error()
					}
				}
				dirReady[ad] = reason
			}
			if reason != "" {
				j.archiveErr = reason
			} else {
				j.archiveDir = ad
				j.archivePath = generateFilename(img.path, ad, takenArchive)
			}
		}
		jobs[i] = j
	}
	return jobs
}

// processImages 并发复制/链接选中的图片，返回成功数、失败数和归档成功数。
// 实测串行复制只有约 60 MB/s，6 路并发能到 110~120 MB/s（CLAUDE.md 坑 12）。
// dests 与 images 一一对应，是复制成功后在壁纸文件夹里的文件名（失败为空）；bytes 是复制的总字节数。
func processImages(images []sourceImage, destDir string, o CopyOptions, archiveOverride string, rep Reporter) (copied, failed, archived int, dests []string, bytes int64) {
	jobs := planCopies(images, destDir, o, archiveOverride)
	rep = rep.synced()
	logf := rep.logf
	action := "  复制"
	if o.Mode != "copy" {
		action = "软链接"
	}
	var nCopied, nFailed, nArchived, nDone, nBytes atomic.Int64
	dests = make([]string, len(jobs))
	rep.progress(StageCopy, 0, len(jobs))
	parallelFor(len(jobs), copyWorkers, func(i int) {
		j := jobs[i]
		if rep.stopped() {
			return // 不再开始新的图片，已经在复制的会复制完
		}
		defer func() { rep.progress(StageCopy, int(nDone.Add(1)), len(jobs)) }()
		srcName, destName := filepath.Base(j.img.path), filepath.Base(j.dest)
		msg := fmt.Sprintf("%s: %s", action, srcName)
		if destName != srcName {
			msg += "  ➡️ " + destName
		}
		logf("%s", msg)

		var err error
		if o.Mode == "copy" {
			err = copyFile(j.img.path, j.dest)
		} else {
			err = relSymlink(j.img.path, destDir, j.dest)
		}
		if err != nil {
			logf("失败: %s - %v", destName, err)
			nFailed.Add(1)
			return
		}
		nCopied.Add(1)
		dests[i] = destName
		if o.Mode == "copy" {
			if st, err := os.Stat(j.dest); err == nil {
				nBytes.Add(st.Size())
			}
		}

		switch {
		case !o.ArchiveEnabled:
			return
		case j.archiveErr != "":
			logf("%s", j.archiveErr)
			return
		}
		archiveSrc := translateSourceForArchive(j.img.path, o.ArchiveSMBRoot, o.ArchiveNFSRoot)
		// 优先硬链接；SMB 上必然失败（CLAUDE.md 坑 1），降级为相对路径软链接
		if err := os.Link(archiveSrc, j.archivePath); err == nil {
			cleanupNFSAppleDoubleSidecar(archiveSrc)
			nArchived.Add(1)
			logf("  🔗 归档硬链接: %s  (%s)", filepath.Base(j.archivePath), j.archiveDir)
		} else if err := relSymlink(archiveSrc, j.archiveDir, j.archivePath); err == nil {
			nArchived.Add(1)
			logf("  🔀 归档软链接(硬链接不支持，已降级): %s  (%s)", filepath.Base(j.archivePath), j.archiveDir)
		} else {
			logf("归档失败: %s - %v", srcName, err)
		}
	})
	return int(nCopied.Load()), int(nFailed.Load()), int(nArchived.Load()), dests, nBytes.Load()
}

// CopySamples 扫描 → 采样 → 确认选出图片后才清空目标/归档目录并复制（CLAUDE.md 坑 10）。
func CopySamples(o CopyOptions, rep Reporter, r *rand.Rand) (CopyResult, error) {
	logf := rep.logf
	var res CopyResult
	if r == nil {
		r = rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64()))
	}
	destDir := ExpandUser(o.Dest)
	res.Dest = destDir
	if o.ArchiveSubdirName == "" {
		o.ArchiveSubdirName = DefaultArchiveSubdir
	}
	o.ArchiveSMBRoot = ExpandUser(o.ArchiveSMBRoot)
	o.ArchiveNFSRoot = ExpandUser(o.ArchiveNFSRoot)
	// 没单独指定归档父路径时，配置了 NFS 根路径就默认归档到 NFS 挂载点下
	archiveOverride := ExpandUser(o.ArchiveDirOverride)
	if archiveOverride == "" {
		archiveOverride = o.ArchiveNFSRoot
	}

	resolvedSources := map[string]bool{}
	for _, s := range o.Sources {
		resolvedSources[resolvePath(s)] = true
	}
	filter := map[string]bool{}
	for _, s := range o.FilterSources {
		rs := resolvePath(s)
		if !resolvedSources[rs] {
			logf("⚠️ filter_sources 中的目录 %s 不在 sources 中，已忽略", rs)
			continue
		}
		filter[rs] = true
	}

	logf("🔍 扫描图片文件...")
	rep.progress(StageScan, 0, 0)
	if len(filter) > 0 {
		logf("   分辨率筛选目录: %d 个 (最小 %dx%d, 横屏)", len(filter), o.MinWidth, o.MinHeight)
	}
	all, grouped, leafOrder := scanImages(o.Sources, filter, o.MinWidth, o.MinHeight, func(n int) { rep.progress(StageScan, n, 0) })
	if len(o.Excluded) > 0 {
		var dropped int
		all, grouped, leafOrder, dropped = dropExcluded(all, grouped, leafOrder, o.Excluded)
		if dropped > 0 {
			logf("🚫 跳过 %d 张已排除的图片", dropped)
		}
	}
	res.Candidates, res.LeafFolders = len(all), len(grouped)
	res.Sources = sourceStats(o.Sources, all)
	if len(all) == 0 {
		return res, ErrNoImages
	}
	if o.Num <= 0 {
		return res, errors.New("采样数量必须大于 0")
	}
	sampleSize := min(o.Num, len(all))
	logf("🎯 随机选择 %d 张图片", sampleSize)

	// 优先选这一轮轮换里还没换上过的：没换上过的够数就只从里面选，不够就全选上、差的从换上过的里补，
	// 并开始新一轮（历史只留这一批）
	var history map[string]bool
	poolAll, poolGrouped, poolLeaves := all, grouped, leafOrder
	var fillAll []sourceImage
	var fillGrouped map[string][]sourceImage
	var fillLeaves []string
	if o.PreferUnseen && o.HistoryFile != "" {
		history = loadHistory(o.HistoryFile)
		unseen := func(img sourceImage) bool { return !history[img.path] }
		uAll, uGrouped, uLeaves := subsetImages(all, grouped, leafOrder, unseen)
		switch {
		case len(uAll) >= sampleSize:
			poolAll, poolGrouped, poolLeaves = uAll, uGrouped, uLeaves
		default:
			res.NewCycle = len(history) > 0
			if res.NewCycle {
				logf("🌀 没换上过的只剩 %d 张，全部选上，整个图库轮换完一遍，开始新一轮", len(uAll))
			}
			poolAll, poolGrouped, poolLeaves = uAll, uGrouped, uLeaves
			fillAll, fillGrouped, fillLeaves = subsetImages(all, grouped, leafOrder, func(img sourceImage) bool { return history[img.path] })
		}
	}
	sample := func(all []sourceImage, grouped map[string][]sourceImage, leaves []string, n int) []sourceImage {
		if o.BalanceFirst {
			return sampleBalanced(grouped, leaves, n, r)
		}
		return sampleN(all, n, r)
	}
	selected := sample(poolAll, poolGrouped, poolLeaves, sampleSize)
	if need := sampleSize - len(selected); need > 0 && len(fillAll) > 0 {
		selected = append(selected, sample(fillAll, fillGrouped, fillLeaves, need)...)
	}
	res.Selected = len(selected)
	if o.BalanceFirst {
		leafCount := len(grouped)
		logf("⚖️ 平衡采样：%d 个叶子文件夹，共 %d 张符合条件的图片", leafCount, len(all))
		if sampleSize < leafCount {
			logf("⚠️ 采样数量 (%d) 少于叶子文件夹数量 (%d)，无法保证每文件夹都选中", sampleSize, leafCount)
		}
		covered := map[string]bool{}
		for _, img := range selected {
			covered[filepath.Dir(img.path)] = true
		}
		coverage := 0.0
		if leafCount > 0 {
			coverage = float64(len(covered)) / float64(leafCount) * 100
		}
		logf("📊 叶子文件夹覆盖率: %d/%d (%.1f%%)", len(covered), leafCount, coverage)
		res.CoveredFolders = len(covered)
	}

	// 清空壁纸目录之前是最后一个"什么都没动"的时刻
	if rep.stopped() {
		return res, ErrCanceled
	}
	prev := loadPrevSelection(o.SelectionFile, destDir)
	if exists(destDir) {
		logf("🔄 清空目标目录...")
		if err := cleanDirectory(destDir); err != nil {
			return res, fmt.Errorf("清空目标目录失败: %w", err)
		}
	}
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return res, fmt.Errorf("创建目标目录失败: %w", err)
	}

	if o.ArchiveEnabled {
		seen := map[string]bool{}
		var valid []string
		for _, s := range o.Sources {
			ad := resolveArchiveDir(s, archiveOverride, o.ArchiveSubdirName)
			if seen[ad] {
				continue
			}
			seen[ad] = true
			if !exists(filepath.Dir(ad)) {
				logf("⚠️ 归档父路径不存在，跳过: %s", filepath.Dir(ad))
				continue
			}
			valid = append(valid, ad)
		}
		logf("🔄 清空归档目录 (%d 个)...", len(valid))
		for _, ad := range valid {
			if err := clearDirectoryContents(ad); err != nil {
				logf("⚠️ 清空归档目录失败，跳过（可能被 Finder 或其他程序占用）: %s - %v", ad, err)
			}
		}
	}

	logf("🚀 开始处理图片...")
	var dests []string
	res.Copied, res.Failed, res.Archived, dests, res.Bytes = processImages(selected, destDir, o, archiveOverride, rep)
	if rep.stopped() && res.Copied+res.Failed < len(selected) {
		logf("⏹️ 已停止：壁纸目录里保留已复制的 %d 张", res.Copied)
		return res, ErrCanceled
	}
	compareSelection(o.SelectionFile, destDir, prev, selected, dests, &res, logf)
	if o.PreferUnseen && o.HistoryFile != "" {
		if res.NewCycle {
			history = map[string]bool{}
		}
		for _, img := range selected {
			history[img.path] = true
		}
		if err := saveHistory(o.HistoryFile, history); err != nil {
			logf("⚠️ 记录轮换进度失败: %v", err)
		}
		for _, img := range all {
			if history[img.path] {
				res.Rotated++
			}
		}
		logf("🌀 图库轮换进度：已换上过 %d / %d 张（%.0f%%）", res.Rotated, len(all), float64(res.Rotated)/float64(max(1, len(all)))*100)
	}
	logf("✅ 完成! 已处理 %d 张图片", len(selected))
	logf("💾 目标目录: %s", destDir)
	if o.ArchiveEnabled {
		logf("🔗 归档副本已创建 (子文件夹名: %s，优先硬链接，不支持时自动降级为软链接)", o.ArchiveSubdirName)
	}
	return res, nil
}

// savedSelection 是 Paths.Selection 文件的内容。
type savedSelection struct {
	Dest    string   `json:"dest"`
	Sources []string `json:"sources"`
	Dests   []string `json:"dests,omitempty"` // 与 Sources 一一对应：壁纸文件夹里的文件名（复制失败为空）
}

// WallpaperSources 返回壁纸文件夹里每个文件（文件名）对应的原图路径，界面上对缩略图做「不再选它」
// 「删除原图」时用。没有记录或记录不是这个壁纸文件夹时返回 nil。
func WallpaperSources(selectionFile, destDir string) map[string]string {
	var saved savedSelection
	data, err := os.ReadFile(selectionFile)
	if err != nil || json.Unmarshal(data, &saved) != nil || saved.Dest != destDir || len(saved.Dests) != len(saved.Sources) {
		return nil
	}
	out := make(map[string]string, len(saved.Dests))
	for i, d := range saved.Dests {
		if d != "" {
			out[d] = saved.Sources[i]
		}
	}
	return out
}

// prevSelection 是上一轮选了哪些图，用来算这一轮新换上几张。
type prevSelection struct {
	keys   map[string]bool
	n      int
	byName bool // 没有记录，按壁纸文件夹里原有的文件名比（近似）
}

// loadPrevSelection 必须在清空壁纸文件夹之前调用。有上一轮的记录（且是同一个壁纸文件夹）就按原图路径比；
// 没有记录（第一次运行、换了壁纸文件夹）就退而看壁纸文件夹里现有的图片文件名——复制时命名为
// 「上级文件夹-原名」（destName），只有重名才加 _1，所以按这个名字比基本准确，只是上级文件夹同名、
// 文件也同名的两张图会被当成同一张。都没有返回 nil。
func loadPrevSelection(file, destDir string) *prevSelection {
	if file == "" {
		return nil
	}
	var saved savedSelection
	if data, err := os.ReadFile(file); err == nil && json.Unmarshal(data, &saved) == nil && saved.Dest == destDir && len(saved.Sources) > 0 {
		p := &prevSelection{keys: make(map[string]bool, len(saved.Sources)), n: len(saved.Sources)}
		for _, s := range saved.Sources {
			p.keys[s] = true
		}
		return p
	}
	entries, err := os.ReadDir(destDir)
	if err != nil {
		return nil
	}
	p := &prevSelection{keys: map[string]bool{}, byName: true}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || e.IsDir() || !IsValidImage(name) {
			continue
		}
		p.keys[name] = true
		p.n++
	}
	if p.n == 0 {
		return nil
	}
	return p
}

// compareSelection 算这一轮选中的图里有几张上一轮也选过，再把这一轮按原图路径记下来。
// 文件名会因为重名改写（generateFilename），所以有记录时按原图路径比，不看壁纸文件夹里的文件名。
func compareSelection(file, destDir string, prev *prevSelection, selected []sourceImage, dests []string, res *CopyResult, logf Logf) {
	if file == "" {
		return
	}
	cur := make([]string, len(selected))
	for i, img := range selected {
		cur[i] = img.path
	}
	if prev != nil && len(cur) > 0 {
		for _, p := range cur {
			key := p
			if prev.byName {
				key = destName(p)
			}
			if prev.keys[key] {
				res.Repeated++
			}
		}
		res.PrevSelected = prev.n
		res.PrevByName = prev.byName
		note := ""
		if prev.byName {
			note = "，按文件名比较"
		}
		logf("🔁 和上一轮相比：新换上 %d 张，重复 %d 张（重合率 %.0f%%%s）",
			len(cur)-res.Repeated, res.Repeated, float64(res.Repeated)/float64(len(cur))*100, note)
	}
	data, err := json.Marshal(savedSelection{Dest: destDir, Sources: cur, Dests: dests})
	if err == nil {
		_ = os.MkdirAll(filepath.Dir(file), 0o755)
		err = os.WriteFile(file, data, 0o644)
	}
	if err != nil {
		logf("⚠️ 记录本轮选中的图片失败: %v", err)
	}
}

// dropExcluded 从扫描结果里去掉排除名单里的图片，返回去掉的张数。
func dropExcluded(all []sourceImage, grouped map[string][]sourceImage, leafOrder []string, excluded []string) ([]sourceImage, map[string][]sourceImage, []string, int) {
	ex := make(map[string]bool, len(excluded))
	for _, p := range excluded {
		ex[p] = true
	}
	a, g, l := subsetImages(all, grouped, leafOrder, func(img sourceImage) bool { return !ex[img.path] })
	return a, g, l, len(all) - len(a)
}

// subsetImages 按 keep 过滤扫描结果的三种视图，去掉过滤后为空的叶子文件夹。
func subsetImages(all []sourceImage, grouped map[string][]sourceImage, leafOrder []string, keep func(sourceImage) bool) ([]sourceImage, map[string][]sourceImage, []string) {
	var outAll []sourceImage
	for _, img := range all {
		if keep(img) {
			outAll = append(outAll, img)
		}
	}
	outGrouped := map[string][]sourceImage{}
	var outLeaves []string
	for _, leaf := range leafOrder {
		var here []sourceImage
		for _, img := range grouped[leaf] {
			if keep(img) {
				here = append(here, img)
			}
		}
		if len(here) > 0 {
			outGrouped[leaf] = here
			outLeaves = append(outLeaves, leaf)
		}
	}
	return outAll, outGrouped, outLeaves
}

// sourceStats 按图库目录统计可参与采样的图片数和含图片的文件夹数，顺序与 sources 一致。
func sourceStats(sources []string, all []sourceImage) []SourceStat {
	idx := map[string]int{}
	out := make([]SourceStat, 0, len(sources))
	folders := make([]map[string]bool, 0, len(sources))
	for _, s := range sources {
		if _, dup := idx[s]; dup {
			continue
		}
		idx[s] = len(out)
		out = append(out, SourceStat{Dir: s})
		folders = append(folders, map[string]bool{})
	}
	for _, img := range all {
		i, ok := idx[img.sourceDir]
		if !ok {
			continue
		}
		out[i].Images++
		folders[i][filepath.Dir(img.path)] = true
	}
	for i := range out {
		out[i].Folders = len(folders[i])
	}
	return out
}

// loadHistory 读这一轮轮换里换上过的原图；读不到就是空的。
func loadHistory(file string) map[string]bool {
	out := map[string]bool{}
	var paths []string
	if data, err := os.ReadFile(file); err == nil && json.Unmarshal(data, &paths) == nil {
		for _, p := range paths {
			out[p] = true
		}
	}
	return out
}

func saveHistory(file string, history map[string]bool) error {
	paths := make([]string, 0, len(history))
	for p := range history {
		paths = append(paths, p)
	}
	slices.Sort(paths)
	data, err := json.Marshal(paths)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	return os.WriteFile(file, data, 0o644)
}
