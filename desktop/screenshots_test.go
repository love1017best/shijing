package main

// 给 README 生成截图（示意风景图 + 演示数据，不读真实图库）：
// SHOTS_DIR=$PWD/../docs/screenshots CGO_ENABLED=0 go test -run TestScreenshots .

import (
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"desktop/core"

	"github.com/egoist/mygo/ui"
)

type pal struct{ skyTop, skyBot, sun, far, mid, near color.RGBA }

func rgb(r, g, b uint8) color.RGBA { return color.RGBA{r, g, b, 255} }

var pals = []pal{
	{rgb(255, 170, 120), rgb(255, 222, 170), rgb(255, 245, 210), rgb(214, 130, 120), rgb(150, 80, 100), rgb(70, 40, 70)},
	{rgb(40, 70, 140), rgb(130, 170, 220), rgb(240, 245, 255), rgb(90, 120, 170), rgb(50, 80, 120), rgb(25, 40, 70)},
	{rgb(20, 24, 60), rgb(80, 60, 120), rgb(250, 230, 200), rgb(70, 60, 110), rgb(40, 35, 75), rgb(15, 15, 40)},
	{rgb(120, 190, 230), rgb(220, 240, 250), rgb(255, 255, 240), rgb(130, 180, 160), rgb(70, 130, 110), rgb(30, 80, 70)},
	{rgb(250, 120, 90), rgb(250, 200, 120), rgb(255, 240, 200), rgb(200, 100, 80), rgb(120, 60, 60), rgb(50, 25, 35)},
	{rgb(170, 200, 230), rgb(240, 225, 235), rgb(255, 250, 245), rgb(160, 160, 200), rgb(110, 110, 160), rgb(60, 60, 100)},
	{rgb(10, 40, 70), rgb(40, 110, 140), rgb(220, 250, 255), rgb(30, 90, 110), rgb(15, 60, 80), rgb(5, 30, 45)},
	{rgb(230, 150, 60), rgb(250, 220, 140), rgb(255, 250, 220), rgb(180, 120, 60), rgb(110, 70, 40), rgb(50, 35, 25)},
}

func lerp(a, b color.RGBA, t float64) color.RGBA {
	f := func(x, y uint8) uint8 { return uint8(float64(x) + (float64(y)-float64(x))*t) }
	return color.RGBA{f(a.R, b.R), f(a.G, b.G), f(a.B, b.B), 255}
}

// landscape 画一张「天空渐变 + 太阳 + 三层山」的示意风景，代替真实壁纸。
func landscape(w, h int, p pal, seed float64) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	sx, sy, sr := float64(w)*(0.25+0.5*math.Mod(seed*0.37, 1)), float64(h)*0.42, float64(h)*0.08
	ridge := func(x float64, base, amp, freq, ph float64) float64 {
		return float64(h) * (base - amp*(0.6*math.Sin(x*freq+ph)+0.3*math.Sin(x*freq*2.3+ph*1.7)+0.1*math.Sin(x*freq*5.1+ph*0.3)))
	}
	for y := range h {
		sky := lerp(p.skyTop, p.skyBot, float64(y)/float64(h)*1.4)
		for x := range w {
			c := sky
			if d := math.Hypot(float64(x)-sx, float64(y)-sy); d < sr {
				c = p.sun
			} else if d < sr*2.5 {
				c = lerp(p.sun, sky, (d-sr)/(sr*1.5))
			}
			fx := float64(x) / float64(w)
			if float64(y) > ridge(fx, 0.62, 0.10, 6, seed) {
				c = p.far
			}
			if float64(y) > ridge(fx, 0.74, 0.09, 4, seed*2+1) {
				c = p.mid
			}
			if float64(y) > ridge(fx, 0.86, 0.07, 3, seed*3+2) {
				c = p.near
			}
			img.SetRGBA(x, y, c)
		}
	}
	return img
}

// frame 给截图加上圆角窗口和红绿灯。
func frame(src *image.RGBA, scale float32) *image.RGBA {
	b := src.Bounds()
	out := image.NewRGBA(b)
	r := float64(10 * scale)
	w, h := float64(b.Dx()), float64(b.Dy())
	for y := range b.Dy() {
		for x := range b.Dx() {
			fx, fy := float64(x)+0.5, float64(y)+0.5
			cx, cy := math.Max(r-fx, math.Max(0, fx-(w-r))), math.Max(r-fy, math.Max(0, fy-(h-r)))
			a := 1.0
			if cx > 0 && cy > 0 {
				a = math.Max(0, math.Min(1, r-math.Hypot(cx, cy)+0.5))
			}
			c := src.RGBAAt(x, y)
			out.SetRGBA(x, y, color.RGBA{uint8(float64(c.R) * a), uint8(float64(c.G) * a), uint8(float64(c.B) * a), uint8(255 * a)})
		}
	}
	lights := []color.RGBA{rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)}
	for i, c := range lights {
		cx, cy, rr := float64(20+20*i)*float64(scale), float64(titleBarHeight/2)*float64(scale), 6*float64(scale)
		for y := int(cy - rr - 2); y <= int(cy+rr+2); y++ {
			for x := int(cx - rr - 2); x <= int(cx+rr+2); x++ {
				a := math.Max(0, math.Min(1, rr-math.Hypot(float64(x)+0.5-cx, float64(y)+0.5-cy)+0.5))
				if a == 0 {
					continue
				}
				o := out.RGBAAt(x, y)
				out.SetRGBA(x, y, lerp(o, c, a))
			}
		}
	}
	return out
}

func TestScreenshots(t *testing.T) {
	dir := os.Getenv("SHOTS_DIR")
	if dir == "" {
		t.Skip()
	}
	walls := t.TempDir()
	for i, p := range pals {
		f, _ := os.Create(filepath.Join(walls, "demo"+string(rune('a'+i))+".jpg"))
		jpeg.Encode(f, landscape(1920, 1080, p, float64(i)+0.3), &jpeg.Options{Quality: 90})
		f.Close()
	}

	for _, dark := range []bool{false, true} {
		suffix := ""
		if dark {
			suffix = "-dark"
		}
		f, _ := newFakeApp(t)
		f.version = "0.2.104"
		f.statDir = func(string) bool { return true }
		f.scanWallpapers = func(d string) scannedWallpapers { s := scanWallpapers(walls); s.dir = d; return s }
		f.cfg.FilterAndSampleDirs = []string{"/Volumes/NAS/Photos/风景", "/Volumes/NAS/Photos/旅行", "/Volumes/NAS/Photos/城市"}
		f.cfg.SampleOnlyDirs = []string{"/Volumes/NAS/Photos/精选"}
		f.cfg.DestDir = "~/Pictures/Wallpapers"
		f.cfg.SampleCount = 300
		f.num = 300
		sum := core.Summary{Elapsed: 14200 * time.Millisecond}
		sum.Sort = core.SortResult{Dirs: 3, Skipped: 412, Images: 186, Rejected: 4, Deleted: 4}
		sum.Copy = core.CopyResult{Candidates: 27650, Selected: 300, Copied: 300, LeafFolders: 474, CoveredFolders: 300, Dest: "~/Pictures/Wallpapers"}
		sum.WallpaperRefreshed = true
		f.last = &runResult{sum: sum, at: time.Now().Add(-25 * time.Minute)}
		f.log = []string{
			"▶ " + time.Now().Add(-26*time.Minute).Format("2006-01-02 15:04:05") + " 开始运行",
			"🗑️  开始筛选目录：3 个",
			"🔎 找到 415 个含图片的文件夹（共遍历 431 个）",
			"📁 /Volumes/NAS/Photos/风景",
			"  ├─ 冰岛 2024: ⏭️ 已跳过（无变化）",
			"  ├─ 北海道: ⏭️ 已跳过（无变化）",
			"📂 处理文件夹: 新疆 2026",
			"    [新疆 2026] 🗑️ 待删除: IMG_2231.jpg",
			"    [新疆 2026] 🔥 已删除: IMG_2231.jpg",
			"  └─ 新疆 2026: 处理 62 张，删除 1 张",
			"⚠️  目录不存在（可能卷未挂载）: /Volumes/Backup/旧照片",
			"🔍 扫描图片文件...",
			"🎯 随机选择 300 张图片",
			"⚖️ 使用平衡采样模式...",
			"  复制: IMG_0412.jpg  ➡️ IMG_0412.jpg",
			"  复制: DSC_7781.jpg  ➡️ DSC_7781.jpg",
			"🔄 已刷新系统壁纸",
			"✅ 所有操作完成 - 壁纸已更新",
		}
		f.checkMounts()
		tt := ui.NewTesterWith(f.view, 1040, 760, ui.TesterOptions{Dark: dark})
		tt.SetTitleBar(ui.TitleBar{Height: titleBarHeight, Left: 78})
		tt.SetScale(2)
		shot := func(name string) {
			f.settle(t, tt, func() bool {
				for _, d := range f.allDirs() {
					if f.mounts[d] != mountOK {
						return false
					}
				}
				return !f.walls.loading && f.walls.hero != nil
			})
			tt.Advance(2 * time.Second)
			tt.Frame()
			out, _ := os.Create(filepath.Join(dir, name+suffix+".png"))
			png.Encode(out, frame(tt.Image(), 2))
			out.Close()
		}
		shot("overview")
		click(t, tt, "图库")
		shot("library")
		click(t, tt, "设置")
		shot("settings")
		click(t, tt, "关于")
		shot("about")

		// 展开日志
		click(t, tt, "概览")
		f.logShown = true
		tt.SetSize(1040, 1030)
		tt.Advance(2 * time.Second)
		shot("log")
		f.logShown = false
		tt.SetSize(1040, 760)

		// 运行中
		click(t, tt, "概览")
		f.running = true
		f.prog = progress{core.StageFilter, 268, 415}
		f.log = append(f.log, "▶ "+time.Now().Format("2006-01-02 15:04:05")+" 开始运行", "  ├─ 北海道: ⏭️ 已跳过（无变化）")
		shot("running")
		f.running = false
	}
}
