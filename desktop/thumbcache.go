package main

import (
	"fmt"
	"hash/fnv"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
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

// cachedScaled 和 loadScaled 一样，但先查磁盘缓存，解码后写进缓存。
func cachedScaled(path string, width int) image.Image {
	fi, err := os.Stat(path)
	if thumbCacheDir == "" || err != nil {
		return loadScaled(path, width)
	}
	file := filepath.Join(thumbCacheDir, thumbCacheKey(path, fi, width))
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
func writeThumbCache(file string, img image.Image) {
	if os.MkdirAll(filepath.Dir(file), 0o755) != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(file), ".tmp-*")
	if err != nil {
		return
	}
	err = jpeg.Encode(tmp, img, &jpeg.Options{Quality: 88})
	if tmp.Close() != nil || err != nil {
		os.Remove(tmp.Name())
		return
	}
	if os.Rename(tmp.Name(), file) != nil {
		os.Remove(tmp.Name())
	}
}

// pruneThumbCache 删掉不属于 files 的缓存（换了一批、移出了的）。
func pruneThumbCache(files []string) {
	if thumbCacheDir == "" {
		return
	}
	entries, err := os.ReadDir(thumbCacheDir)
	if err != nil {
		return
	}
	keep := map[string]bool{}
	for _, f := range files {
		if fi, err := os.Stat(f); err == nil {
			keep[thumbCacheKey(f, fi, thumbWidth)] = true
			keep[thumbCacheKey(f, fi, heroWidth)] = true
			keep[thumbCacheKey(f, fi, browseThumbWidth)] = true
		}
	}
	for _, e := range entries {
		if !keep[e.Name()] || strings.HasPrefix(e.Name(), ".tmp-") {
			os.Remove(filepath.Join(thumbCacheDir, e.Name()))
		}
	}
}
