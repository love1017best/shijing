package core

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

// destName 是原图复制到壁纸文件夹后的名字（不重名时）：「上级文件夹-原名」。
func destName(src string) string {
	return filepath.Base(filepath.Dir(src)) + "-" + filepath.Base(src)
}

// generateFilename 生成「上层目录名-原文件名」，冲突时加 _1、_2… 后缀。
// taken 记录本轮已经分配出去、但可能还没真正写到磁盘上的名字（复制是并发的，
// 只看磁盘会给两张同名图片分到同一个目标路径）；生成的名字会加进 taken。taken 可以为 nil。
func generateFilename(src, destDir string, taken map[string]bool) string {
	return generateFilenameInSet(src, destDir, taken, true)
}

func generateFilenameInSet(src, destDir string, taken map[string]bool, checkDisk bool) string {
	name := filepath.Base(src)
	parent := filepath.Base(filepath.Dir(src))
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	dest := filepath.Join(destDir, destName(src))
	// macOS 默认 APFS 及大多数 SMB 卷大小写不敏感，taken 按小写归一化去重，
	// 避免仅大小写不同的两张图被并发写入同一文件。
	for i := 1; taken[strings.ToLower(dest)] || (checkDisk && lexists(dest)); i++ {
		dest = filepath.Join(destDir, fmt.Sprintf("%s-%s_%d%s", parent, stem, i, ext))
	}
	if taken != nil {
		taken[strings.ToLower(dest)] = true
	}
	return dest
}

// clearDirectoryContents 清空目录内的条目而不删目录本身：
// 网络卷上或正被 Finder 打开的目录，删除目录自身容易触发 Resource busy。
func clearDirectoryContents(dir string) error {
	return syncDestDir(dir, nil)
}

// syncDestDir 保留目录内属于 keepNames（按小写归一化）的条目，删除其余条目；
// 不删除目录本身（避免网络卷或被 Finder 打开的目录报 Resource busy）。
func syncDestDir(dir string, keepNames map[string]bool) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if keepNames != nil && keepNames[strings.ToLower(e.Name())] {
			continue
		}
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
// 用于建归档硬链接（硬链接要求两端在同一个挂载点）。
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
// （NAS 文件带 SF_ARCHIVED 等 flags 时修改元数据可能报错；Go 不复制 st_flags，只还原 mode 与时间戳）。
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
		_ = os.Remove(dst)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(dst)
		return err
	}
	if st, err := in.Stat(); err == nil {
		_ = os.Chmod(dst, st.Mode().Perm())
		_ = os.Chtimes(dst, st.ModTime(), st.ModTime())
	}
	return nil
}

func relSymlink(target, linkDir, linkPath string) error {
	base := linkDir
	if realDir, err := filepath.EvalSymlinks(linkDir); err == nil {
		base = realDir
	}
	tgt := target
	if realParent, err := filepath.EvalSymlinks(filepath.Dir(target)); err == nil {
		tgt = filepath.Join(realParent, filepath.Base(target))
	}
	rel, err := filepath.Rel(base, tgt)
	if err != nil {
		rel = target
	}
	return os.Symlink(rel, linkPath)
}

// copyJob 是一张图片要做的全部事情，在串行的准备阶段算好，执行阶段并发跑。
type copyJob struct {
	img         sourceImage
	dest        string
	reuse       bool  // 目标壁纸文件夹已有相同原图且大小/修改时间未变，原地保留不重拷
	reuseBytes  int64 // 复用文件的字节数
	archiveDir  string
	archivePath string
	archiveErr  string // 准备阶段就确定无法归档的原因（日志用）
}

// planDestJobs 串行地为本批图片分配目标文件名（不查磁盘旧文件，因非复用条目随后会被清理）。
func planDestJobs(images []sourceImage, destDir string) []copyJob {
	jobs := make([]copyJob, len(images))
	takenDest := map[string]bool{}
	for i, img := range images {
		jobs[i] = copyJob{img: img, dest: generateFilenameInSet(img.path, destDir, takenDest, false)}
	}
	return jobs
}

// markReusableJobs 检查哪些选中的图片已存在于目标壁纸目录且内容未变，标记为原地复用。
// 仅在 copy 模式且上一批记录了精确的「原图 → 目标文件名」映射时启用。
func markReusableJobs(jobs []copyJob, prevDestBySrc map[string]string, mode string) (keepNames map[string]bool, reusable int) {
	if mode != "copy" || len(prevDestBySrc) == 0 {
		return nil, 0
	}
	type candidate struct {
		idx     int
		dstSize int64
		dstMod  time.Time
	}
	var cands []candidate
	for i, j := range jobs {
		base := filepath.Base(j.dest)
		prevName, ok := prevDestBySrc[j.img.path]
		if !ok || !strings.EqualFold(prevName, base) {
			continue
		}
		dstInfo, err := os.Lstat(j.dest)
		if err != nil || !dstInfo.Mode().IsRegular() {
			continue
		}
		cands = append(cands, candidate{idx: i, dstSize: dstInfo.Size(), dstMod: dstInfo.ModTime()})
	}
	if len(cands) == 0 {
		return nil, 0
	}
	matched := make([]bool, len(cands))
	parallelFor(len(cands), metaWorkers, func(k int) {
		c := cands[k]
		srcInfo, err := os.Stat(jobs[c.idx].img.path)
		if err != nil || !srcInfo.Mode().IsRegular() {
			return
		}
		if srcInfo.Size() != c.dstSize {
			return
		}
		diff := srcInfo.ModTime().Sub(c.dstMod)
		if diff < 0 {
			diff = -diff
		}
		if diff < time.Second {
			matched[k] = true
		}
	})
	keepNames = map[string]bool{}
	for k, ok := range matched {
		if !ok {
			continue
		}
		c := cands[k]
		jobs[c.idx].reuse = true
		jobs[c.idx].reuseBytes = c.dstSize
		keepNames[strings.ToLower(filepath.Base(jobs[c.idx].dest))] = true
		reusable++
	}
	if reusable == 0 {
		return nil, 0
	}
	return keepNames, reusable
}

// attachArchivePlans 在归档目录清空后，串行地为每张图分配归档路径。
func attachArchivePlans(jobs []copyJob, o CopyOptions, archiveOverride string) {
	if !o.ArchiveEnabled {
		return
	}
	takenArchive := map[string]bool{}
	dirReady := map[string]string{} // archiveDir → "" 可用，否则为不可用原因
	for i := range jobs {
		ad := resolveArchiveDir(jobs[i].img.sourceDir, archiveOverride, o.ArchiveSubdirName)
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
			jobs[i].archiveErr = reason
		} else {
			jobs[i].archiveDir = ad
			jobs[i].archivePath = generateFilename(jobs[i].img.path, ad, takenArchive)
		}
	}
}

// processImages 并发复制/链接选中的图片，返回成功数、失败数和归档成功数。
// 6 路并发可以把 SMB 的往返等待重叠起来，显著提升吞吐。
// dests 与 jobs 一一对应，是复制/复用成功后在壁纸文件夹里的文件名（失败为空）；bytes 是总字节数。
func processImages(jobs []copyJob, destDir string, o CopyOptions, rep Reporter) (copied, failed, archived int, dests []string, bytes int64) {
	rep = rep.synced()
	logf := rep.logf
	action := "  复制"
	if o.Mode != "copy" {
		action = "软链接"
	}
	var nCopied, nFailed, nArchived, nDone, nBytes atomic.Int64
	dests = make([]string, len(jobs))
	// 先登记所有原地复用的文件，即使复制中途停止，savePartialSelection 也能保留它们的映射。
	for i, j := range jobs {
		if j.reuse {
			dests[i] = filepath.Base(j.dest)
		}
	}
	rep.progress(StageCopy, 0, len(jobs))
	parallelForStop(len(jobs), copyWorkers, rep.stopped, func(i int) {
		j := jobs[i]
		defer func() { rep.progress(StageCopy, int(nDone.Add(1)), len(jobs)) }()
		srcName, destName := filepath.Base(j.img.path), filepath.Base(j.dest)

		if j.reuse {
			nCopied.Add(1)
			nBytes.Add(j.reuseBytes)
			logf("  ♻️ 复用: %s", destName)
		} else {
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
		}

		switch {
		case !o.ArchiveEnabled:
			return
		case j.archiveErr != "":
			logf("%s", j.archiveErr)
			return
		}
		archiveSrc := translateSourceForArchive(j.img.path, o.ArchiveSMBRoot, o.ArchiveNFSRoot)
		// 优先硬链接；SMB 上不支持硬链接，失败时降级为相对路径软链接
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

// validArchiveSubdir 检查归档子目录名必须是单个普通子目录名，禁止 "."、".." 或路径分隔符，
// 防止后续 clearDirectoryContents 清空归档父目录。
func validArchiveSubdir(name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	return !strings.ContainsAny(name, "/\\")
}

// prepareOutputDirs 同步壁纸目标目录（保留复用文件，删除其余旧条目）并清空各归档目录。
func prepareOutputDirs(destDir string, keepNames map[string]bool, o CopyOptions, archiveOverride string, logf Logf) error {
	if exists(destDir) {
		if len(keepNames) > 0 {
			logf("🔄 清理目标目录（原地保留 %d 张重合壁纸）...", len(keepNames))
		} else {
			logf("🔄 清空目标目录...")
		}
		if err := syncDestDir(destDir, keepNames); err != nil {
			return fmt.Errorf("清空目标目录失败: %w", err)
		}
	} else if err := os.MkdirAll(destDir, 0o755); err != nil {
		return fmt.Errorf("创建目标目录失败: %w", err)
	}
	if !o.ArchiveEnabled {
		return nil
	}
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
	return nil
}

// savePartialSelection 在复制中途停止时，按实际已写入或复用的文件重写选图映射，
// 避免保留上一批映射导致后续「删除原图」删错文件。
func savePartialSelection(file, destDir string, selected []sourceImage, dests []string, logf Logf) {
	doneSrc := make([]string, 0, len(dests))
	doneDst := make([]string, 0, len(dests))
	for i, d := range dests {
		if d != "" {
			doneSrc = append(doneSrc, selected[i].path)
			doneDst = append(doneDst, d)
		}
	}
	saveSelection(file, destDir, doneSrc, doneDst, logf)
}
