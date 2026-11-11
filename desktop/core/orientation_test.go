package core

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeJPEGOrient 写一张 w×h 像素的 JPEG，EXIF 里带方向标记 orient（0 表示不带 EXIF）。
func writeJPEGOrient(t *testing.T, path string, w, h, orient int, bo binary.ByteOrder) {
	t.Helper()
	var img bytes.Buffer
	if err := jpeg.Encode(&img, image.NewGray(image.Rect(0, 0, w, h)), nil); err != nil {
		t.Fatal(err)
	}
	out := img.Bytes()
	if orient > 0 {
		// TIFF 头 + 一个 IFD：先放一个无关的标记，再放 Orientation，确认会往后找
		tiff := make([]byte, 8+2+2*12+4)
		if bo == binary.BigEndian {
			copy(tiff, "MM")
		} else {
			copy(tiff, "II")
		}
		bo.PutUint16(tiff[2:], 42)
		bo.PutUint32(tiff[4:], 8)
		bo.PutUint16(tiff[8:], 2)
		for i, e := range [][2]int{{0x010F, 0}, {0x0112, orient}} {
			p := 10 + i*12
			bo.PutUint16(tiff[p:], uint16(e[0]))
			bo.PutUint16(tiff[p+2:], 3) // SHORT
			bo.PutUint32(tiff[p+4:], 1)
			bo.PutUint16(tiff[p+8:], uint16(e[1]))
		}
		seg := append([]byte("Exif\x00\x00"), tiff...)
		app1 := []byte{0xFF, 0xE1, 0, 0}
		binary.BigEndian.PutUint16(app1[2:], uint16(len(seg)+2))
		// 放在 SOI 后面、在 JPEG 自己的段之后也行；这里插在 SOI 后面再加一个无关的 APP0 前面
		out = append(append(append([]byte{0xFF, 0xD8}, app1...), seg...), out[2:]...)
	}
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestImageVerdictUsesExifOrientation(t *testing.T) {
	dir := t.TempDir()
	for _, c := range []struct {
		name          string
		w, h, orient  int
		bo            binary.ByteOrder
		ok            bool
		reasonContain string
	}{
		{"横拍.jpg", 300, 200, 0, nil, true, ""},
		{"转90度显示.jpg", 300, 200, 8, binary.LittleEndian, false, "竖屏 200×300"},
		{"转90度显示-大端.jpg", 300, 200, 6, binary.BigEndian, false, "竖屏 200×300"},
		{"转180度.jpg", 300, 200, 3, binary.LittleEndian, true, ""},
		{"竖着存转回横的.jpg", 200, 300, 6, binary.LittleEndian, true, ""},
	} {
		p := filepath.Join(dir, c.name)
		writeJPEGOrient(t, p, c.w, c.h, c.orient, c.bo)
		ok, reason := ImageVerdict(p, 100, 100)
		if ok != c.ok || !strings.Contains(reason, c.reasonContain) {
			t.Errorf("%s: 应 ok=%v（%q），实际 ok=%v（%q）", c.name, c.ok, c.reasonContain, ok, reason)
		}
	}
}

func TestTiffOrientationBadInput(t *testing.T) {
	for _, b := range [][]byte{nil, []byte("II"), []byte("XX\x2a\x00\x08\x00\x00\x00"), []byte("II\x2a\x00\xff\xff\x00\x00")} {
		if o := tiffOrientation(b); o != 1 {
			t.Errorf("坏数据应当作 1: %q → %d", b, o)
		}
	}
}
