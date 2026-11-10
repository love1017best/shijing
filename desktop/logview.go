package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/egoist/mygo/ui"
)

// 日志在 core 里是给命令行看的纯文本（带 emoji、分隔线、绝对路径）。界面上逐行解析成
// 不同的类型来排版：分隔线和空行不显示，阶段和来源目录做成小标题，警告、错误、删除用图标标出。
// 复制到剪贴板的仍是原文。

type logKind int

const (
	logSkip    logKind = iota // 空行、==== / ──── 分隔线
	logRun                    // ▶ 2026-11-09 18:58:24 开始运行
	logStage                  // 开始筛选 / 开始采样复制 / 扫描 / 开始处理
	logSource                 // 📁 /Volumes/Media0/xxx
	logFolder                 // 📂 处理文件夹: set0
	logSummary                // └─ set0: 处理 2 张，删除 1 张
	logCopy                   // 复制: a.jpg ➡️ b.jpg
	logInfo
	logSuccess
	logWarn
	logError
	logDelete // 待删除 / 已删除
	logStop
)

type logEntry struct {
	kind   logKind
	indent int
	text   string
	detail string // 第二段文字（来源目录的上级路径、复制的目标名、删除文件所在的文件夹），淡色显示
	label  string // 删除行的「待删除 / 已删除」
}

// isProblem 是「只看问题」时保留的行。
func (e logEntry) isProblem() bool {
	return e.kind == logWarn || e.kind == logError || e.kind == logDelete || e.kind == logStop
}

var stageMarks = []string{"开始筛选目录", "开始采样复制", "扫描图片文件", "开始处理图片"}

func parseLogLine(line string) logEntry {
	raw := strings.TrimSpace(line)
	if raw == "" || strings.HasPrefix(raw, "===") || strings.HasPrefix(raw, "───") {
		return logEntry{kind: logSkip}
	}
	text := strings.TrimSpace(cleanLogLine(raw))
	e := logEntry{kind: logInfo, text: text}
	if strings.HasPrefix(line, "  ") || strings.HasPrefix(line, "\t") {
		e.indent = 1
	}
	switch {
	case strings.HasPrefix(raw, "▶"):
		e.kind, e.indent = logRun, 0
		ts := strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(raw, "▶"), "开始运行"))
		if at, err := time.ParseInLocation("2006-01-02 15:04:05", ts, time.Local); err == nil {
			e.text = at.Format("1月2日 15:04:05")
		}
	case strings.HasPrefix(raw, "[") && (strings.Contains(raw, "🔥") || strings.Contains(raw, "🗑️")):
		// 「[set0] 🗑️ 待删除: x.jpg」/「[set0] 🔥 已删除: x.jpg」
		e.kind, e.indent = logDelete, 2
		folder, rest, _ := strings.Cut(strings.TrimPrefix(raw, "["), "] ")
		label, name, _ := strings.Cut(strings.TrimSpace(cleanLogLine(rest)), ":")
		e.label, e.text, e.detail = strings.TrimSpace(label), strings.TrimSpace(name), folder
	case strings.Contains(raw, "❌") || strings.HasPrefix(text, "失败:") || strings.HasPrefix(text, "归档失败"):
		e.kind = logError
	case strings.Contains(raw, "⚠️"):
		e.kind = logWarn
	case strings.Contains(raw, "⏹️"):
		e.kind = logStop
	case strings.Contains(raw, "✅"):
		e.kind, e.indent = logSuccess, 0
	case strings.HasPrefix(raw, "📁 /") || strings.HasPrefix(raw, "📁 ~"):
		e.kind, e.indent = logSource, 0
		e.text, e.detail = filepath.Base(text), tildify(filepath.Dir(text))
	case strings.HasPrefix(raw, "📂"):
		e.kind, e.indent = logFolder, 1
		e.text = strings.TrimSpace(strings.TrimPrefix(text, "处理文件夹:"))
	case strings.HasPrefix(raw, "└─") || strings.HasPrefix(raw, "├─"):
		e.kind, e.indent = logSummary, 2
		e.text = strings.TrimSpace(cleanLogLine(strings.TrimSpace(raw[len("└─"):])))
	case strings.HasPrefix(text, "复制:") || strings.HasPrefix(text, "软链接:"):
		e.kind, e.indent = logCopy, 1
		body := strings.TrimSpace(text[strings.Index(text, ":")+1:])
		src, dst, ok := strings.Cut(body, "➡️")
		e.text = strings.TrimSpace(src)
		if ok {
			e.detail = strings.TrimSpace(dst)
		}
	default:
		for _, m := range stageMarks {
			if strings.Contains(raw, m) {
				e.kind, e.indent = logStage, 0
			}
		}
	}
	e.text = stripEmoji(e.text)
	if e.kind != logSource {
		e.text = tildifyIn(e.text)
	}
	return e
}

// stripEmoji 去掉文字中间的 emoji（如「set0: ⏭️ 已跳过」），类型已经由图标表达。
func stripEmoji(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.Is(unicode.So, r) || r == 0xFE0F || r == 0x200D {
			continue
		}
		b.WriteRune(r)
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

// tildifyIn 把一行文字里出现的家目录换成 ~。
func tildifyIn(s string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return s
	}
	return strings.ReplaceAll(s, home+string(filepath.Separator), "~/")
}

// logView 是解析后可显示的行（下标指向 a.log），按「只看问题」过滤。
func (a *app) logView() []int {
	if len(a.logParsed) > len(a.log) || (len(a.logParsed) > 0 && a.logParsedFirst != firstOr(a.log)) {
		a.logParsed = nil // 日志被清空或截断过，重新解析
	}
	for i := len(a.logParsed); i < len(a.log); i++ {
		a.logParsed = append(a.logParsed, parseLogLine(a.log[i]))
	}
	a.logParsedFirst = firstOr(a.log)
	var out []int
	for i, e := range a.logParsed {
		switch {
		case e.kind == logSkip:
		case a.logProblemsOnly && !e.isProblem() && e.kind != logRun:
		default:
			out = append(out, i)
		}
	}
	return out
}

func firstOr(s []string) string {
	if len(s) == 0 {
		return ""
	}
	return s[0]
}

func (a *app) logRow(c *ui.Context, e logEntry) {
	t := c.Theme()
	if e.kind == logRun {
		ui.Row(c).Gap(10).AlignItems(ui.Center).Padding(12, 16, 6, 16).Children(func() {
			ui.Icon(c, iconPlay).FontSize(11).TextColor(t.Accent)
			ui.Text(c, "开始运行").FontSize(12).Bold().TextColor(t.Accent).SingleLine()
			ui.Text(c, e.text).FontSize(12).TextColor(t.TextMuted).SingleLine()
			ui.Box(c).Height(1).Grow(1).Background(hairline(t))
		})
		return
	}
	var icon *ui.SVG
	color, size, bold := t.Text.Alpha(0.86), float32(12.5), false
	switch e.kind {
	case logStage:
		icon, color, bold = iconChevronRight, t.Text, true
	case logSource:
		icon, color, bold = iconFolder, t.Text, true
	case logFolder:
		icon, color = iconFolderOpen, t.Text.Alpha(0.75)
	case logSummary, logCopy:
		color, size = t.TextMuted, 12
	case logSuccess:
		icon, color = iconCheck, t.Success
	case logWarn:
		icon, color = iconAlert, t.Warning
	case logError:
		icon, color = iconXCircle, t.Danger
	case logDelete:
		icon, color = iconTrash, t.Danger
	case logStop:
		icon, color = iconCircleStop, t.TextMuted
	}
	top := float32(2)
	if e.kind == logStage || e.kind == logSource {
		top = 8
	}
	ui.Row(c).Gap(8).AlignItems(ui.Start).Padding(top, 16, 2, 16+float32(e.indent)*18).Children(func() {
		ib := ui.Box(c).Size(14, 17).Center().Shrink(0)
		if icon != nil {
			iconColor := color
			if e.kind == logStage || e.kind == logSource {
				iconColor = t.Accent
			}
			ib.Children(func() { ui.Icon(c, icon).FontSize(12).TextColor(iconColor) })
		}
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).AlignItems(ui.Baseline).Wrap().Children(func() {
			if e.kind == logDelete && e.label != "" {
				pill(c, e.label, color)
			}
			txt := ui.Text(c, e.text).FontSize(size).TextColor(color).Wrap()
			if bold {
				txt.Bold()
			}
			if e.kind == logCopy || e.kind == logDelete {
				txt.Font("Menlo").FontSize(11.5)
			}
			switch {
			case e.kind == logCopy && e.detail != "":
				ui.Text(c, "→").FontSize(11.5).TextColor(t.TextMuted.Alpha(0.7))
				ui.Text(c, e.detail).Font("Menlo").FontSize(11.5).TextColor(t.TextMuted).Wrap()
			case e.kind == logDelete && e.detail != "":
				ui.Text(c, "在 "+e.detail).FontSize(11.5).TextColor(t.TextMuted).SingleLine()
			case e.detail != "":
				ui.Text(c, e.detail).FontSize(11.5).TextColor(t.TextMuted).SingleLine()
			}
		})
	})
}
