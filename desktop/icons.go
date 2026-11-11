package main

import (
	"bytes"
	_ "embed"
	"image/png"

	"github.com/egoist/mygo/ui"
)

// 图标取自 Lucide（ISC 许可），只保留路径，统一用描边样式、跟随文字颜色。
func lucide(paths string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">` + paths + `</svg>`))
}

var (
	iconHome         = lucide(`<path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>`)
	iconFolder       = lucide(`<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>`)
	iconSliders      = lucide(`<line x1="21" x2="14" y1="4" y2="4"/><line x1="10" x2="3" y1="4" y2="4"/><line x1="21" x2="12" y1="12" y2="12"/><line x1="8" x2="3" y1="12" y2="12"/><line x1="21" x2="16" y1="20" y2="20"/><line x1="12" x2="3" y1="20" y2="20"/><line x1="14" x2="14" y1="2" y2="6"/><line x1="8" x2="8" y1="10" y2="14"/><line x1="16" x2="16" y1="18" y2="22"/>`)
	iconShuffle      = lucide(`<path d="m18 14 4 4-4 4"/><path d="m18 2 4 4-4 4"/><path d="M2 18h1.973a4 4 0 0 0 3.3-1.7l5.454-7.6a4 4 0 0 1 3.3-1.7H22"/><path d="M2 6h1.972a4 4 0 0 1 3.6 2.2"/><path d="M22 18h-6.041a4 4 0 0 1-3.3-1.8l-.359-.45"/>`)
	iconPlus         = lucide(`<path d="M5 12h14"/><path d="M12 5v14"/>`)
	iconTrash        = lucide(`<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>`)
	iconRefresh      = lucide(`<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>`)
	iconCheck        = lucide(`<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>`)
	iconAlert        = lucide(`<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>`)
	iconExternal     = lucide(`<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>`)
	iconFolderOpen   = lucide(`<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>`)
	iconCheckSmall   = lucide(`<path d="M20 6 9 17l-5-5"/>`)
	iconPhone        = lucide(`<rect width="14" height="20" x="5" y="2" rx="2" ry="2"/><path d="M12 18h.01"/>`)
	iconScissors     = lucide(`<circle cx="6" cy="6" r="3"/><path d="M8.12 8.12 12 12"/><path d="M20 4 8.12 15.88"/><circle cx="6" cy="18" r="3"/><path d="M14.8 14.8 20 20"/>`)
	iconHeart        = lucide(`<path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>`)
	iconStop         = lucide(`<rect width="14" height="14" x="5" y="5" rx="2"/>`)
	iconCircleStop   = lucide(`<circle cx="12" cy="12" r="10"/><rect x="9" y="9" width="6" height="6" rx="1"/>`)
	iconInfo         = lucide(`<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>`)
	iconUser         = lucide(`<circle cx="12" cy="8" r="5"/><path d="M20 21a8 8 0 0 0-16 0"/>`)
	iconTag          = lucide(`<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>`)
	iconCode         = lucide(`<path d="m16 18 6-6-6-6"/><path d="m8 6-6 6 6 6"/>`)
	iconPlay         = lucide(`<polygon points="6 3 20 12 6 21 6 3"/>`)
	iconChevronRight = lucide(`<path d="m9 18 6-6-6-6"/>`)
	iconChevronLeft  = lucide(`<path d="m15 18-6-6 6-6"/>`)
	iconXCircle      = lucide(`<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>`)
	iconKeyboard     = lucide(`<path d="M10 8h.01"/><path d="M12 12h.01"/><path d="M14 8h.01"/><path d="M16 12h.01"/><path d="M18 8h.01"/><path d="M6 8h.01"/><path d="M7 16h10"/><path d="M8 12h.01"/><rect width="20" height="16" x="2" y="4" rx="2"/>`)
	iconRotateCcw    = lucide(`<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>`)
	iconArrowRight   = lucide(`<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>`)
)

// icon256.png 是 resources/icon.png（1024 宽，mygo 拿它生成 .icns）缩到 256 宽的一份：界面上最大只画 256 宽，
// 嵌原图要多带 100 多 KB、启动时还得解两遍 1024 的 PNG。换图标时用 PIL 重新缩一份。
//
//go:embed icon256.png
var appIconPNG []byte

// appIcon 是侧边栏顶部的应用图标，aboutIcon 是「关于」页的大图标（都由 icon256.png 缩小）。
var appIcon, aboutIcon = appIconAt(96), appIconAt(256)

func appIconAt(width int) *ui.Bitmap {
	img, err := png.Decode(bytes.NewReader(appIconPNG))
	if err != nil {
		return nil
	}
	return ui.NewBitmap(shrink(img, width))
}
