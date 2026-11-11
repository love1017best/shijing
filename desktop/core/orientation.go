package core

import (
	"bufio"
	"encoding/binary"
	"io"
)

// exifOrientation 读 JPEG / TIFF 里 EXIF 的方向标记（1–8，没有或读不出来时为 1）。
// 相机和修图软件常把竖拍的照片按横的像素存、再用这个标记让看图软件转 90°：
// 像素是 6240×4160，系统壁纸、Finder、预览里显示的却是 4160×6240 的竖图。
// 判断横竖屏要按显示出来的方向（ImageVerdict），只看像素宽高会把这种竖图当成横屏。
func exifOrientation(r io.Reader) int {
	br := bufio.NewReaderSize(r, 4096)
	head, err := br.Peek(4)
	if err != nil {
		return 1
	}
	switch {
	case head[0] == 'I' && head[1] == 'I' || head[0] == 'M' && head[1] == 'M': // TIFF：文件本身就是 EXIF 的格式
		data := make([]byte, 64*1024)
		n, _ := io.ReadFull(br, data)
		return tiffOrientation(data[:n])
	case head[0] == 0xFF && head[1] == 0xD8: // JPEG：在 SOS 之前的段里找 APP1「Exif」
		br.Discard(2)
		for {
			var m [4]byte
			if _, err := io.ReadFull(br, m[:]); err != nil || m[0] != 0xFF {
				return 1
			}
			marker, size := m[1], int(binary.BigEndian.Uint16(m[2:]))
			if marker == 0xDA || marker == 0xD9 || size < 2 { // 到图像数据了，没有 EXIF
				return 1
			}
			if marker != 0xE1 {
				if _, err := br.Discard(size - 2); err != nil {
					return 1
				}
				continue
			}
			seg := make([]byte, size-2)
			if _, err := io.ReadFull(br, seg); err != nil {
				return 1
			}
			if len(seg) > 6 && string(seg[:6]) == "Exif\x00\x00" {
				return tiffOrientation(seg[6:])
			}
		}
	}
	return 1
}

// tiffOrientation 在 TIFF 结构的第一个 IFD 里找 0x0112（Orientation）。
func tiffOrientation(b []byte) int {
	if len(b) < 8 {
		return 1
	}
	var bo binary.ByteOrder
	switch string(b[:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return 1
	}
	off := int(bo.Uint32(b[4:]))
	if off < 8 || off+2 > len(b) {
		return 1
	}
	n := int(bo.Uint16(b[off:]))
	for i := range n {
		e := off + 2 + i*12
		if e+12 > len(b) {
			return 1
		}
		if bo.Uint16(b[e:]) == 0x0112 {
			if v := int(bo.Uint16(b[e+8:])); v >= 1 && v <= 8 {
				return v
			}
			return 1
		}
	}
	return 1
}
