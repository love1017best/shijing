package main

import (
	"fmt"
	"hash/fnv"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 缩略图和横幅图的磁盘缓存：缩小后的图存成 JPEG 放在数据目录的 thumbs/ 里，下次打开应用直接读，
// 不用再从几十 MB 的原图解码。按「路径 + 大小 + 修改时间 + 宽度」算文件名，图片换了自然对不上；
// 每次读壁纸文件夹时把不属于现在这批的删掉（pruneThumbCache），所以不会越攒越多。
// thumbCacheDir 为空时不缓存（测试里不设）。
var thumbCacheDir string

func thumbCacheKey(path string, fi os.FileInfo, width int) string {
	h := fnv.New64a()
	fmt.Fprintf(h, "%s\x00%d\x00%d\x00%d", path, fi.Size(), fi.ModTime().UnixNano(), width)
	return fmt.Sprintf("%016x.jpg", h.Sum64())
}

// thumbCacheFile 返回这张图在指定宽度下的磁盘缓存文件路径；未启用缓存或源文件不可读时返回 ""。
func thumbCacheFile(path string, width int) string {
	if thumbCacheDir == "" {
		return ""
	}
	fi, err := os.Stat(path)
	if err != nil {
		return ""
	}
	return filepath.Join(thumbCacheDir, thumbCacheKey(path, fi, width))
}

// cachedScaled 和 loadScaled 一样，但先查磁盘缓存，解码后写进缓存。
func cachedScaled(path string, width int) image.Image {
	file := thumbCacheFile(path, width)
	if file == "" {
		return loadScaled(path, width)
	}
	if f, err := os.Open(file); err == nil {
		img, err := jpeg.Decode(f)
		f.Close()
		if err == nil {
			return img
		}
	}
	img := loadScaled(path, width)
	if img != nil {
		writeThumbCache(file, img)
	}
	return img
}

// writeThumbCache 先写临时文件再改名，两个解码同时写同一张也不会读到写了一半的。
func writeThumbCache(file string, img image.Image) bool {
	if os.MkdirAll(filepath.Dir(file), 0o755) != nil {
		return false
	}
	tmp, err := os.CreateTemp(filepath.Dir(file), ".tmp-*")
	if err != nil {
		return false
	}
	err = jpeg.Encode(tmp, img, &jpeg.Options{Quality: 88})
	if tmp.Close() != nil || err != nil {
		os.Remove(tmp.Name())
		return false
	}
	if os.Rename(tmp.Name(), file) != nil {
		os.Remove(tmp.Name())
		return false
	}
	return true
}

// pruneThumbCache 删掉不属于 files 的缓存（换了一批、移出了的）。
// 软链接模式下 NAS 断网会让所有 os.Stat 失败：此时跳过清理，避免把本地缓存全部清空；
// 同时跳过 1 分钟内的 .tmp-*，避免删掉其他协程正在写入的临时文件。
func pruneThumbCache(files []string) {
	if thumbCacheDir == "" {
		return
	}
	entries, err := os.ReadDir(thumbCacheDir)
	if err != nil {
		return
	}
	keep := map[string]bool{}
	statted := 0
	for _, f := range files {
		if fi, err := os.Stat(f); err == nil {
			statted++
			keep[thumbCacheKey(f, fi, thumbWidth)] = true
			keep[thumbCacheKey(f, fi, heroWidth)] = true
			keep[thumbCacheKey(f, fi, browseThumbWidth)] = true
		}
	}
	if len(files) > 0 && statted == 0 {
		return
	}
	now := time.Now()
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".tmp-") {
			if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) < time.Minute {
				continue
			}
			os.Remove(filepath.Join(thumbCacheDir, name))
			continue
		}
		if !keep[name] {
			os.Remove(filepath.Join(thumbCacheDir, name))
		}
	}
}
