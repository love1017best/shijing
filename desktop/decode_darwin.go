//go:build darwin

package main

import (
	"image"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// systemDecode 用 macOS 的 ImageIO 解码：读文件时就按目标尺寸解（JPEG 可以只解缩小后的版本），
// 比 Go 的 image/jpeg 先解出几千万像素再缩快好几倍；还会按 EXIF 方向转正、按色彩配置转成 sRGB。
// mygo 构建时关掉了 cgo（CGO_ENABLED=0），所以和 MyGo 自己一样用 purego 直接调系统框架。
// 失败返回 nil，调用方退回纯 Go 解码。
func systemDecode(path string, width int) image.Image {
	io := loadImageIO()
	if io == nil || path == "" {
		return nil
	}
	p := []byte(path)
	url := io.urlCreate(0, &p[0], len(p), false)
	if url == 0 {
		return nil
	}
	src := io.srcCreate(url, 0)
	io.release(url)
	if src == 0 {
		return nil
	}
	defer io.release(src)

	var pw, ph, orient int32 = 0, 0, 1
	if props := io.copyProps(src, 0, 0); props != 0 {
		io.number(props, io.kWidth, &pw)
		io.number(props, io.kHeight, &ph)
		io.number(props, io.kOrient, &orient)
		io.release(props)
	}
	if pw <= 0 || ph <= 0 {
		return nil
	}
	if orient >= 5 { // 转 90° 的方向：宽高互换
		pw, ph = ph, pw
	}
	// ThumbnailMaxPixelSize 限的是长边：按目标宽度换算成长边；不放大
	maxPix := int32(width)
	if ph > pw {
		maxPix = int32(int64(width) * int64(ph) / int64(pw))
	}
	if int32(width) >= pw {
		maxPix = max(pw, ph)
	}
	num := io.numCreate(0, cfNumberSInt32, unsafe.Pointer(&maxPix))
	keys := [4]uintptr{io.kAlways, io.kTransform, io.kMaxSize, io.kCacheNow}
	vals := [4]uintptr{io.kTrue, io.kTrue, num, io.kTrue}
	opts := io.dictCreate(0, unsafe.Pointer(&keys[0]), unsafe.Pointer(&vals[0]), 4, io.keyCallBacks, io.valCallBacks)
	img := io.thumb(src, 0, opts)
	io.release(opts)
	io.release(num)
	if img == 0 {
		return nil
	}
	defer io.release(img)

	w, h := io.imgW(img), io.imgH(img)
	if w == 0 || h == 0 {
		return nil
	}
	buf := io.malloc(w * h * 4) // 位图上下文在 C 那边一直拿着这块内存，用 C 的 malloc，不用 Go 的切片
	if buf == 0 {
		return nil
	}
	defer io.free(buf)
	cs := io.csCreate(io.kSRGB)
	ctx := io.ctxCreate(buf, w, h, 8, w*4, cs, cgImageAlphaPremultipliedLast|cgBitmapByteOrder32Big)
	io.release(cs)
	if ctx == 0 {
		return nil
	}
	io.draw(ctx, cgRect{W: float64(w), H: float64(h)}, img)
	io.release(ctx)
	out := image.NewRGBA(image.Rect(0, 0, int(w), int(h)))
	copy(out.Pix, unsafe.Slice((*byte)(ptr(buf)), len(out.Pix)))
	return out
}

const (
	cfNumberSInt32                = 3
	cgImageAlphaPremultipliedLast = 1
	cgBitmapByteOrder32Big        = 4 << 12
)

type cgRect struct{ X, Y, W, H float64 }

type imageIO struct {
	urlCreate  func(alloc uintptr, buf *byte, n int, isDir bool) uintptr
	srcCreate  func(url, opts uintptr) uintptr
	copyProps  func(src uintptr, i int, opts uintptr) uintptr
	dictGet    func(d, key uintptr) uintptr
	numGet     func(n uintptr, typ int, out unsafe.Pointer) bool
	numCreate  func(alloc uintptr, typ int, v unsafe.Pointer) uintptr
	dictCreate func(alloc uintptr, keys, vals unsafe.Pointer, n int, kcb, vcb uintptr) uintptr
	thumb      func(src uintptr, i int, opts uintptr) uintptr
	release    func(uintptr)
	imgW, imgH func(uintptr) uint
	csCreate   func(name uintptr) uintptr
	ctxCreate  func(data uintptr, w, h, bpc, bpr uint, cs uintptr, info uint32) uintptr
	draw       func(ctx uintptr, r cgRect, img uintptr)
	malloc     func(n uint) uintptr
	free       func(uintptr)

	kWidth, kHeight, kOrient                 uintptr
	kAlways, kTransform, kMaxSize, kCacheNow uintptr
	kTrue, kSRGB                             uintptr
	keyCallBacks, valCallBacks               uintptr
}

// number 读字典里的一个整数，没有这一项时保持原值。
func (io *imageIO) number(d, key uintptr, out *int32) {
	if n := io.dictGet(d, key); n != 0 {
		io.numGet(n, cfNumberSInt32, unsafe.Pointer(out))
	}
}

var (
	imageIOOnce sync.Once
	imageIOLib  *imageIO
)

// loadImageIO 第一次用时打开系统框架、查好函数和常量；打不开返回 nil（只用纯 Go 解码）。
func loadImageIO() *imageIO {
	imageIOOnce.Do(func() {
		defer func() {
			if recover() != nil { // 找不到符号时 purego 会 panic
				imageIOLib = nil
			}
		}()
		open := func(path string) uintptr {
			h, err := purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_GLOBAL)
			if err != nil {
				panic(err)
			}
			return h
		}
		cf := open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
		cg := open("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
		iio := open("/System/Library/Frameworks/ImageIO.framework/ImageIO")
		libc := open("/usr/lib/libSystem.B.dylib")
		// 常量是全局变量：Dlsym 拿到的是变量的地址，要再读一次才是 CFStringRef 本身
		constant := func(lib uintptr, name string) uintptr {
			addr, err := purego.Dlsym(lib, name)
			if err != nil {
				panic(err)
			}
			return *(*uintptr)(ptr(addr))
		}
		addr := func(lib uintptr, name string) uintptr {
			a, err := purego.Dlsym(lib, name)
			if err != nil {
				panic(err)
			}
			return a
		}
		io := &imageIO{}
		purego.RegisterLibFunc(&io.urlCreate, cf, "CFURLCreateFromFileSystemRepresentation")
		purego.RegisterLibFunc(&io.dictGet, cf, "CFDictionaryGetValue")
		purego.RegisterLibFunc(&io.numGet, cf, "CFNumberGetValue")
		purego.RegisterLibFunc(&io.numCreate, cf, "CFNumberCreate")
		purego.RegisterLibFunc(&io.dictCreate, cf, "CFDictionaryCreate")
		purego.RegisterLibFunc(&io.release, cf, "CFRelease")
		purego.RegisterLibFunc(&io.srcCreate, iio, "CGImageSourceCreateWithURL")
		purego.RegisterLibFunc(&io.copyProps, iio, "CGImageSourceCopyPropertiesAtIndex")
		purego.RegisterLibFunc(&io.thumb, iio, "CGImageSourceCreateThumbnailAtIndex")
		purego.RegisterLibFunc(&io.imgW, cg, "CGImageGetWidth")
		purego.RegisterLibFunc(&io.imgH, cg, "CGImageGetHeight")
		purego.RegisterLibFunc(&io.csCreate, cg, "CGColorSpaceCreateWithName")
		purego.RegisterLibFunc(&io.ctxCreate, cg, "CGBitmapContextCreate")
		purego.RegisterLibFunc(&io.draw, cg, "CGContextDrawImage")
		purego.RegisterLibFunc(&io.malloc, libc, "malloc")
		purego.RegisterLibFunc(&io.free, libc, "free")
		io.kWidth = constant(iio, "kCGImagePropertyPixelWidth")
		io.kHeight = constant(iio, "kCGImagePropertyPixelHeight")
		io.kOrient = constant(iio, "kCGImagePropertyOrientation")
		io.kAlways = constant(iio, "kCGImageSourceCreateThumbnailFromImageAlways")
		io.kTransform = constant(iio, "kCGImageSourceCreateThumbnailWithTransform")
		io.kMaxSize = constant(iio, "kCGImageSourceThumbnailMaxPixelSize")
		io.kCacheNow = constant(iio, "kCGImageSourceShouldCacheImmediately")
		io.kTrue = constant(cf, "kCFBooleanTrue")
		io.kSRGB = constant(cg, "kCGColorSpaceSRGB")
		io.keyCallBacks = addr(cf, "kCFTypeDictionaryKeyCallBacks")
		io.valCallBacks = addr(cf, "kCFTypeDictionaryValueCallBacks")
		imageIOLib = io
	})
	return imageIOLib
}

// ptr 把 C 那边的地址转成指针（malloc 的内存、Dlsym 查到的变量），不归 Go 的 GC 管。
func ptr(p uintptr) unsafe.Pointer { return *(*unsafe.Pointer)(unsafe.Pointer(&p)) }
