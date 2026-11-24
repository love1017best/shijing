package core

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"math/rand/v2"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// ErrNoImages 在扫描不到任何符合条件的图片时返回，此时不会改动目标目录。
var ErrNoImages = errors.New("未找到符合条件的图片文件（源目录可能未挂载）；目标目录未被改动")

// CopyOptions 是 CopySamples 的采样复制配置。
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

	// SelectionFile 记录这一轮选中的原图路径；下一轮据此算有多少张和上一轮重复，并复用未变化的重合文件。为空则不记录。
	SelectionFile string
	// HistoryFile 记录这一轮轮换里换上过的原图；PreferUnseen 时优先选不在里面的。
	HistoryFile  string
	StateFile    string // 增量状态文件，用于缓存「仅采样目录」的分辨率检查结果；为空则不缓存
	Incremental  bool   // 为 true 且 StateFile 非空时，对未变动的「仅采样目录」复用缓存的分辨率检查结果
	PreferUnseen bool
	Excluded     []string // 不参与采样的原图（「不再选」）
	Rejected     []string // 筛选查出不合格、但这次没删的原图（SortResult.Remaining），同样不参与采样
}

// sourceImage 是一张候选图片：它来自哪个源目录、文件路径是什么。
type sourceImage struct {
	sourceDir string
	path      string
}

// imagePool 封装一次扫描得到的候选图片：扁平列表和按叶子文件夹分组的视图。
type imagePool struct {
	all       []sourceImage
	grouped   map[string][]sourceImage
	leafOrder []string
}

// drop 从候选池里移除指定路径的图片，返回过滤后的池和移除张数。
func (p imagePool) drop(paths []string) (imagePool, int) {
	excluded := make(map[string]bool, len(paths))
	for _, path := range paths {
		excluded[path] = true
	}
	next := p.subset(func(img sourceImage) bool { return !excluded[img.path] })
	return next, len(p.all) - len(next.all)
}

// subset 按 keep 过滤候选池的三种视图，去掉过滤后为空的叶子文件夹。
func (p imagePool) subset(keep func(sourceImage) bool) imagePool {
	var outAll []sourceImage
	for _, img := range p.all {
		if keep(img) {
			outAll = append(outAll, img)
		}
	}
	outGrouped := map[string][]sourceImage{}
	var outLeaves []string
	for _, leaf := range p.leafOrder {
		var here []sourceImage
		for _, img := range p.grouped[leaf] {
			if keep(img) {
				here = append(here, img)
			}
		}
		if len(here) > 0 {
			outGrouped[leaf] = here
			outLeaves = append(outLeaves, leaf)
		}
	}
	return imagePool{all: outAll, grouped: outGrouped, leafOrder: outLeaves}
}

// sampleBalanced 先给每个叶子文件夹选 1 张，再从剩下的图片里随机补足。
// 第一轮之前打乱文件夹顺序，避免叶子文件夹多于采样数时靠后的文件夹始终选不到。
func (p imagePool) sampleBalanced(total int, r *rand.Rand) []sourceImage {
	leaves := append([]string(nil), p.leafOrder...)
	r.Shuffle(len(leaves), func(i, j int) { leaves[i], leaves[j] = leaves[j], leaves[i] })

	var selected []sourceImage
	chosen := map[string]bool{}
	for _, leaf := range leaves {
		if len(selected) >= total {
			return selected
		}
		imgs := p.grouped[leaf]
		img := imgs[r.IntN(len(imgs))]
		selected = append(selected, img)
		chosen[img.path] = true
	}
	var rest []sourceImage
	for _, leaf := range p.leafOrder {
		for _, img := range p.grouped[leaf] {
			if !chosen[img.path] {
				rest = append(rest, img)
			}
		}
	}
	return append(selected, sampleN(rest, total-len(selected), r)...)
}

// sample 从候选池里选出 n 张；平衡模式下若叶子目录图数不足，再从非叶子目录补齐。
func (p imagePool) sample(n int, balanceFirst bool, r *rand.Rand) []sourceImage {
	if !balanceFirst {
		return sampleN(p.all, n, r)
	}
	sel := p.sampleBalanced(n, r)
	need := n - len(sel)
	if need <= 0 {
		return sel
	}
	inGrouped := make(map[string]bool, len(sel))
	for _, leaf := range p.leafOrder {
		for _, img := range p.grouped[leaf] {
			inGrouped[img.path] = true
		}
	}
	var extra []sourceImage
	for _, img := range p.all {
		if !inGrouped[img.path] {
			extra = append(extra, img)
		}
	}
	if len(extra) > 0 {
		sel = append(sel, sampleN(extra, need, r)...)
	}
	return sel
}

// directImagesSig 计算单个目录内图片列表的轻量签名（文件名、大小、修改时间）。
// 任何图片增删、改名或内容变化都会改变签名；任一文件 stat 失败则返回空字符串。
func directImagesSig(imgs []sourceImage) string {
	h := fnv.New64a()
	var buf [16]byte
	for _, img := range imgs {
		info, err := os.Lstat(img.path)
		if err != nil {
			return ""
		}
		h.Write([]byte(filepath.Base(img.path)))
		h.Write([]byte{0})
		binary.LittleEndian.PutUint64(buf[:8], uint64(info.Size()))
		binary.LittleEndian.PutUint64(buf[8:], uint64(info.ModTime().UnixNano()))
		h.Write(buf[:])
	}
	return strconv.FormatUint(h.Sum64(), 16)
}

// scanImages 一次遍历同时得到扁平列表和按叶子文件夹（没有子目录的文件夹）分组的结果。
// filter 里的源目录才做分辨率检查：先遍历拿到全部候选图片，再并发检查分辨率，最后按遍历顺序组装。
func scanImages(sources []string, filter map[string]bool, minW, minH int, onDir func(n int), stop func() bool) imagePool {
	return scanImagesCached(sources, filter, minW, minH, "", false, onDir, stop, nil)
}

func scanImagesCached(sources []string, filter map[string]bool, minW, minH int, stateFile string, incremental bool, onDir func(n int), stop func() bool, logf Logf) imagePool {
	stopped := func() bool { return stop != nil && stop() }
	type dirScan struct {
		root   string
		isLeaf bool
		imgs   []sourceImage
		check  bool
	}
	var scanned []dirScan
	var checkIdxs []int
	seen := 0
	for _, src := range sources {
		if stopped() {
			return imagePool{}
		}
		if st, err := os.Stat(src); err != nil || !st.IsDir() {
			continue
		}
		needCheck := filter[resolvePath(src)]
		walkStop(src, stop, func(root string, dirs, files []string) {
			seen++
			if onDir != nil {
				onDir(seen)
			}
			d := dirScan{root: root, isLeaf: len(dirs) == 0, check: needCheck}
			for _, f := range files {
				if p := filepath.Join(root, f); IsValidImage(p) {
					d.imgs = append(d.imgs, sourceImage{src, p})
				}
			}
			if len(d.imgs) > 0 {
				if needCheck {
					checkIdxs = append(checkIdxs, len(scanned))
				}
				scanned = append(scanned, d)
			}
		})
	}
	if stopped() {
		return imagePool{}
	}

	useCache := incremental && stateFile != "" && len(checkIdxs) > 0
	var state sorterState
	stateDirty := false
	sigs := make([]string, len(scanned))
	cachedHit := make([]bool, len(scanned))
	cachedRejected := make([]map[string]bool, len(scanned))

	if useCache {
		state = loadState(stateFile)
		th := thresholds{MinWidth: minW, MinHeight: minH, Rules: verdictRules}
		if state.Thresholds == nil || *state.Thresholds != th {
			if len(state.Dirs) > 0 || len(state.Rejected) > 0 || len(state.SampleCache) > 0 {
				stateDirty = true
			}
			state = sorterState{Thresholds: &th}
		}
		parallelForStop(len(checkIdxs), metaWorkers, stop, func(n int) {
			idx := checkIdxs[n]
			sigs[idx] = directImagesSig(scanned[idx].imgs)
		})
		if stopped() {
			return imagePool{}
		}
		hits := 0
		for _, idx := range checkIdxs {
			d := scanned[idx]
			sig := sigs[idx]
			if sig == "" {
				continue
			}
			if entry, ok := state.SampleCache[d.root]; ok && entry.Sig == sig {
				cachedHit[idx] = true
				hits++
				if len(entry.Rejected) > 0 {
					m := make(map[string]bool, len(entry.Rejected))
					for _, name := range entry.Rejected {
						m[name] = true
					}
					cachedRejected[idx] = m
				}
			}
		}
		if hits > 0 && logf != nil {
			logf("   ⏭️ 仅采样目录缓存命中 %d/%d 个文件夹", hits, len(checkIdxs))
		}
	}

	var toCheck []string
	for _, idx := range checkIdxs {
		if cachedHit[idx] {
			continue
		}
		for _, img := range scanned[idx].imgs {
			toCheck = append(toCheck, img.path)
		}
	}

	ok := checkResolutions(toCheck, minW, minH, stop)
	if stopped() {
		return imagePool{}
	}

	var all []sourceImage
	grouped := map[string][]sourceImage{}
	var leafOrder []string
	k := 0 // toCheck / ok 的下标，与遍历顺序一致
	for idx, d := range scanned {
		var here []sourceImage
		var rejectedNames []string
		for _, img := range d.imgs {
			if d.check {
				if cachedHit[idx] {
					if cachedRejected[idx][filepath.Base(img.path)] {
						continue
					}
				} else {
					pass := ok[k]
					k++
					if !pass {
						rejectedNames = append(rejectedNames, filepath.Base(img.path))
						continue
					}
				}
			}
			here = append(here, img)
		}
		if useCache && d.check && !cachedHit[idx] && sigs[idx] != "" {
			if state.SampleCache == nil {
				state.SampleCache = map[string]sampleDirCache{}
			}
			state.SampleCache[d.root] = sampleDirCache{Sig: sigs[idx], Rejected: rejectedNames}
			stateDirty = true
		}
		all = append(all, here...)
		if d.isLeaf && len(here) > 0 {
			if _, seen := grouped[d.root]; !seen {
				leafOrder = append(leafOrder, d.root)
			}
			grouped[d.root] = append(grouped[d.root], here...)
		}
	}

	if useCache && stateDirty {
		if err := saveState(stateFile, state); err != nil && logf != nil {
			logf("⚠️ 保存仅采样目录缓存失败: %v", err)
		}
	}
	return imagePool{all: all, grouped: grouped, leafOrder: leafOrder}
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

// normalizeCopyOptions 补齐默认值并展开路径，返回目标目录和归档覆盖父路径。
func normalizeCopyOptions(o CopyOptions) (CopyOptions, string, string) {
	destDir := ExpandUser(o.Dest)
	o.ArchiveSubdirName = strings.TrimSpace(o.ArchiveSubdirName)
	if o.ArchiveSubdirName == "" {
		o.ArchiveSubdirName = DefaultArchiveSubdir
	}
	o.ArchiveSMBRoot = ExpandUser(o.ArchiveSMBRoot)
	o.ArchiveNFSRoot = ExpandUser(o.ArchiveNFSRoot)
	// 未单独指定归档父路径时，配置了 NFS 根路径就默认归档到 NFS 挂载点下
	archiveOverride := ExpandUser(o.ArchiveDirOverride)
	if archiveOverride == "" {
		archiveOverride = o.ArchiveNFSRoot
	}
	return o, destDir, archiveOverride
}

// buildFilterSet 构建需要按分辨率过滤的源目录集合，忽略不在 sources 中的条目。
func buildFilterSet(sources, filterSources []string, logf Logf) map[string]bool {
	resolvedSources := make(map[string]bool, len(sources))
	for _, s := range sources {
		resolvedSources[resolvePath(s)] = true
	}
	filter := map[string]bool{}
	for _, s := range filterSources {
		rs := resolvePath(s)
		if !resolvedSources[rs] {
			logf("⚠️ filter_sources 中的目录 %s 不在 sources 中，已忽略", rs)
			continue
		}
		filter[rs] = true
	}
	return filter
}

// selectFromPool 结合轮换历史和平衡模式从候选池选出 sampleSize 张图。
func selectFromPool(pool imagePool, sampleSize int, o CopyOptions, r *rand.Rand, logf Logf) (selected []sourceImage, history map[string]bool, newCycle bool) {
	primary := pool
	var fallback imagePool
	if o.PreferUnseen && o.HistoryFile != "" {
		history = loadHistory(o.HistoryFile)
		unseen := pool.subset(func(img sourceImage) bool { return !history[img.path] })
		if len(unseen.all) >= sampleSize {
			primary = unseen
		} else {
			newCycle = len(history) > 0
			if newCycle {
				logf("🌀 未更换过的只剩 %d 张，全部选中，整个图库已轮换完一遍，开始新一轮", len(unseen.all))
			}
			primary = unseen
			fallback = pool.subset(func(img sourceImage) bool { return history[img.path] })
		}
	}
	selected = primary.sample(sampleSize, o.BalanceFirst, r)
	if need := sampleSize - len(selected); need > 0 && len(fallback.all) > 0 {
		selected = append(selected, fallback.sample(need, o.BalanceFirst, r)...)
	}
	return selected, history, newCycle
}

// reportBalanceCoverage 统计并输出平衡模式下的叶子文件夹覆盖率。
func reportBalanceCoverage(pool imagePool, selected []sourceImage, sampleSize int, logf Logf) int {
	leafCount := len(pool.grouped)
	logf("⚖️ 平衡采样：%d 个叶子文件夹，共 %d 张符合条件的图片", leafCount, len(pool.all))
	if sampleSize < leafCount {
		logf("⚠️ 采样数量 (%d) 少于叶子文件夹数量 (%d)，无法保证每文件夹都选中", sampleSize, leafCount)
	}
	covered := map[string]bool{}
	for _, img := range selected {
		dir := filepath.Dir(img.path)
		if _, ok := pool.grouped[dir]; ok {
			covered[dir] = true
		}
	}
	coverage := 0.0
	if leafCount > 0 {
		coverage = float64(len(covered)) / float64(leafCount) * 100
	}
	logf("📊 叶子文件夹覆盖率: %d/%d (%.1f%%)", len(covered), leafCount, coverage)
	return len(covered)
}

// updateRotationHistory 更新图库轮换历史并返回本轮累计已更换张数。
func updateRotationHistory(o CopyOptions, history map[string]bool, newCycle bool, selected, all []sourceImage, logf Logf) int {
	if !o.PreferUnseen || o.HistoryFile == "" {
		return 0
	}
	if newCycle || history == nil {
		history = map[string]bool{}
	}
	for _, img := range selected {
		history[img.path] = true
	}
	if err := saveHistory(o.HistoryFile, history); err != nil {
		logf("⚠️ 记录轮换进度失败: %v", err)
	}
	rotated := 0
	for _, img := range all {
		if history[img.path] {
			rotated++
		}
	}
	logf("🌀 图库轮换进度：已更换 %d / %d 张（%.0f%%）", rotated, len(all), float64(rotated)/float64(max(1, len(all)))*100)
	return rotated
}

// CopySamples 扫描 → 采样 → 确认选出图片后才同步目标目录/清空归档目录并复制。
func CopySamples(o CopyOptions, rep Reporter, r *rand.Rand) (CopyResult, error) {
	logf := rep.logf
	var res CopyResult
	if r == nil {
		r = rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64()))
	}
	var destDir, archiveOverride string
	o, destDir, archiveOverride = normalizeCopyOptions(o)
	res.Dest = destDir
	if o.ArchiveEnabled && !validArchiveSubdir(o.ArchiveSubdirName) {
		return res, fmt.Errorf("归档子文件夹名不合法: %q（只能是单个普通目录名）", o.ArchiveSubdirName)
	}

	filter := buildFilterSet(o.Sources, o.FilterSources, logf)

	logf("🔍 扫描图片文件...")
	rep.progress(StageScan, 0, 0)
	if len(filter) > 0 {
		logf("   分辨率筛选目录: %d 个 (最小 %dx%d, 横屏)", len(filter), o.MinWidth, o.MinHeight)
	}
	pool := scanImagesCached(o.Sources, filter, o.MinWidth, o.MinHeight, o.StateFile, o.Incremental, func(n int) { rep.progress(StageScan, n, 0) }, rep.stopped, logf)
	if rep.stopped() {
		logf("\n⏹️ 已停止扫描")
		return res, ErrCanceled
	}
	if len(o.Excluded) > 0 {
		var dropped int
		pool, dropped = pool.drop(o.Excluded)
		if dropped > 0 {
			logf("🚫 跳过 %d 张已排除的图片", dropped)
		}
	}
	if len(o.Rejected) > 0 {
		var dropped int
		pool, dropped = pool.drop(o.Rejected)
		if dropped > 0 {
			logf("🚫 跳过 %d 张不合格的图片（筛选查出来、这次没有删除）", dropped)
		}
	}
	res.Candidates, res.LeafFolders = len(pool.all), len(pool.grouped)
	res.Sources = sourceStats(o.Sources, pool.all)
	if len(pool.all) == 0 {
		return res, ErrNoImages
	}
	if o.Num <= 0 {
		return res, errors.New("采样数量必须大于 0")
	}
	sampleSize := min(o.Num, len(pool.all))
	logf("🎯 随机选择 %d 张图片", sampleSize)

	selected, history, newCycle := selectFromPool(pool, sampleSize, o, r, logf)
	res.NewCycle = newCycle
	res.Selected = len(selected)
	if len(selected) == 0 {
		logf("⚠️ 未能选出任何可用图片，保留现有壁纸目录不变")
		return res, ErrNoImages
	}
	if o.BalanceFirst {
		res.CoveredFolders = reportBalanceCoverage(pool, selected, sampleSize, logf)
	}

	// 清空/同步壁纸目录之前是最后一个未改动任何文件的检查点
	if rep.stopped() {
		return res, ErrCanceled
	}
	prev := loadPrevSelection(o.SelectionFile, destDir)
	jobs := planDestJobs(selected, destDir)
	var prevDestBySrc map[string]string
	if prev != nil {
		prevDestBySrc = prev.destBySrc
	}
	keepNames, _ := markReusableJobs(jobs, prevDestBySrc, o.Mode)
	if err := prepareOutputDirs(destDir, keepNames, o, archiveOverride, logf); err != nil {
		return res, err
	}
	attachArchivePlans(jobs, o, archiveOverride)

	logf("🚀 开始处理图片...")
	var dests []string
	res.Copied, res.Failed, res.Archived, dests, res.Bytes = processImages(jobs, destDir, o, rep)
	if rep.stopped() && res.Copied+res.Failed < len(selected) {
		savePartialSelection(o.SelectionFile, destDir, selected, dests, logf)
		logf("⏹️ 已停止：壁纸目录里保留已处理的 %d 张", res.Copied)
		return res, ErrCanceled
	}
	compareSelection(o.SelectionFile, destDir, prev, selected, dests, &res, logf)
	res.Rotated = updateRotationHistory(o, history, newCycle, selected, pool.all, logf)
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

// prevSelection 是上一轮选了哪些图，用来算这一轮新换上几张，并定位可原地复用的目标文件。
type prevSelection struct {
	keys      map[string]bool
	destBySrc map[string]string // 原图路径 → 上一轮壁纸文件夹里的文件名
	n         int
	byName    bool // 没有记录，按壁纸文件夹里原有的文件名比（近似）
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
		p := &prevSelection{
			keys: make(map[string]bool, len(saved.Sources)),
			n:    len(saved.Sources),
		}
		for _, s := range saved.Sources {
			p.keys[s] = true
		}
		if len(saved.Dests) == len(saved.Sources) {
			p.destBySrc = make(map[string]string, len(saved.Sources))
			for i, d := range saved.Dests {
				if d != "" {
					p.destBySrc[saved.Sources[i]] = d
				}
			}
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
		logf("🔁 和上一轮相比：新更换 %d 张，重复 %d 张（重合率 %.0f%%%s）",
			len(cur)-res.Repeated, res.Repeated, float64(res.Repeated)/float64(len(cur))*100, note)
	}
	saveSelection(file, destDir, cur, dests, logf)
}

func saveSelection(file, destDir string, sources, dests []string, logf Logf) {
	if file == "" {
		return
	}
	if sources == nil {
		sources = []string{}
	}
	if dests == nil {
		dests = []string{}
	}
	data, err := json.Marshal(savedSelection{Dest: destDir, Sources: sources, Dests: dests})
	if err == nil {
		err = WriteFileAtomic(file, data, 0o644)
	}
	if err != nil {
		logf("⚠️ 记录本轮选中的图片失败: %v", err)
	}
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
	return WriteFileAtomic(file, data, 0o644)
}
