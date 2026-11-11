package main

import (
	"fmt"
	"strings"

	"github.com/egoist/mygo/ui"
)

// 可以自定义的快捷键。配置里只存改过的（core.Config.Shortcuts，id → "Cmd+Shift+Backspace" 这种写法，
// 空字符串表示不用快捷键），没改过的用这里的默认值。写法和菜单栏的 Accelerator 一致，菜单项可以直接用。
type keyAction struct {
	id, label, desc string
	menu            bool // 菜单栏里的命令：任何页面都能用，必须带 ⌘ 或 ⌃
	def             string
}

var keyActions = []keyAction{
	{"run", "换一批壁纸", "从菜单栏「壁纸」里触发，任何页面都能用。", true, "Cmd+R"},
	{"stop", "停止运行", "", true, "Cmd+."},
	{"open_dest", "打开壁纸文件夹", "", true, "Cmd+O"},
	{"prev", "上一张", "⇧空格也是上一张（固定）。", false, "Left"},
	{"next", "下一张", "空格也是下一张（固定）。", false, "Right"},
	{"remove", actRemove, "原图保留。", false, "J"},
	{"exclude", actExclude, "原图保留，以后采样跳过它。", false, "K"},
	{"delete", "删除图库里的原图", "会先弹确认，回车确认、Esc 取消。", false, "L"},
	{"open", "用默认应用打开", "", false, "O"},
	{"reveal", "在 Finder 中显示原图", "", false, "F"},
}

func findKeyAction(id string) (keyAction, bool) {
	for _, k := range keyActions {
		if k.id == id {
			return k, true
		}
	}
	return keyAction{}, false
}

// keyCombo 是一个按键加修饰键。
type keyCombo struct {
	mods ui.Modifiers
	key  ui.Key
}

// 键名：和 MyGo 菜单快捷键的写法一致（字母大写）；glyph 是界面上显示的符号。
var keyTable = func() []struct {
	key         ui.Key
	name, glyph string
} {
	type row = struct {
		key         ui.Key
		name, glyph string
	}
	var t []row
	for k := ui.KeyA; k <= ui.KeyZ; k++ {
		s := string(rune('A' + k - ui.KeyA))
		t = append(t, row{k, s, s})
	}
	for k := ui.Key0; k <= ui.Key9; k++ {
		s := string(rune('0' + k - ui.Key0))
		t = append(t, row{k, s, s})
	}
	for k := ui.KeyF1; k <= ui.KeyF12; k++ {
		s := fmt.Sprintf("F%d", k-ui.KeyF1+1)
		t = append(t, row{k, s, s})
	}
	return append(t,
		row{ui.KeyBackspace, "Backspace", "⌫"}, row{ui.KeyDelete, "Delete", "⌦"},
		row{ui.KeyEnter, "Enter", "↩"}, row{ui.KeyEscape, "Escape", "Esc"},
		row{ui.KeyTab, "Tab", "⇥"}, row{ui.KeySpace, "Space", "空格"},
		row{ui.KeyLeft, "Left", "←"}, row{ui.KeyRight, "Right", "→"},
		row{ui.KeyUp, "Up", "↑"}, row{ui.KeyDown, "Down", "↓"},
		row{ui.KeyHome, "Home", "↖"}, row{ui.KeyEnd, "End", "↘"},
		row{ui.KeyPageUp, "PageUp", "⇞"}, row{ui.KeyPageDown, "PageDown", "⇟"},
		row{ui.KeyMinus, "-", "-"}, row{ui.KeyEqual, "=", "="}, row{ui.KeyComma, ",", ","},
		row{ui.KeyPeriod, ".", "."}, row{ui.KeySlash, "/", "/"}, row{ui.KeySemicolon, ";", ";"},
		row{ui.KeyQuote, "'", "'"}, row{ui.KeyBracketLeft, "[", "["}, row{ui.KeyBracketRight, "]", "]"},
		row{ui.KeyBackslash, "\\", "\\"}, row{ui.KeyBackquote, "`", "`"},
	)
}()

var keyMods = []struct {
	mod         ui.Modifiers
	name, glyph string
}{{ui.Ctrl, "Ctrl", "⌃"}, {ui.Alt, "Alt", "⌥"}, {ui.Shift, "Shift", "⇧"}, {ui.Super, "Cmd", "⌘"}}

func keyRow(k ui.Key) (name, glyph string, ok bool) {
	for _, r := range keyTable {
		if r.key == k {
			return r.name, r.glyph, true
		}
	}
	return "", "", false
}

// parseCombo 解析 "Cmd+Shift+Backspace"；大小写不敏感。
func parseCombo(s string) (keyCombo, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return keyCombo{}, false
	}
	parts := strings.Split(s, "+")
	if strings.HasSuffix(s, "++") { // 键本身是 +（没有这个键名，这里只是别解析错）
		return keyCombo{}, false
	}
	var c keyCombo
	for _, p := range parts[:len(parts)-1] {
		found := false
		for _, m := range keyMods {
			if strings.EqualFold(p, m.name) || (m.mod == ui.Super && (strings.EqualFold(p, "Super") || strings.EqualFold(p, "CmdOrCtrl"))) {
				c.mods |= m.mod
				found = true
			}
		}
		if !found {
			return keyCombo{}, false
		}
	}
	last := parts[len(parts)-1]
	for _, r := range keyTable {
		if strings.EqualFold(r.name, last) {
			c.key = r.key
			return c, true
		}
	}
	return keyCombo{}, false
}

// String 是存进配置、交给菜单栏的写法。
func (k keyCombo) String() string {
	name, _, ok := keyRow(k.key)
	if !ok {
		return ""
	}
	var b strings.Builder
	for _, m := range []int{3, 0, 1, 2} { // Cmd+Ctrl+Alt+Shift
		if k.mods&keyMods[m].mod != 0 {
			b.WriteString(keyMods[m].name + "+")
		}
	}
	return b.String() + name
}

// Label 是界面上显示的写法，修饰键按 macOS 的顺序 ⌃⌥⇧⌘。
func (k keyCombo) Label() string {
	_, glyph, ok := keyRow(k.key)
	if !ok {
		return ""
	}
	var b strings.Builder
	for _, m := range keyMods {
		if k.mods&m.mod != 0 {
			b.WriteString(m.glyph)
		}
	}
	return b.String() + glyph
}

// fixedKeys 是不能改、也不能被占用的快捷键（菜单栏和预览里写死的）。
var fixedKeys = []struct{ combo, label string }{
	{"Escape", "关闭预览 / 取消"},
	{"Space", "下一张"},
	{"Shift+Space", "上一张"},
	{"0", "预览里输入编号跳转"}, {"1", "预览里输入编号跳转"}, {"2", "预览里输入编号跳转"}, {"3", "预览里输入编号跳转"}, {"4", "预览里输入编号跳转"},
	{"5", "预览里输入编号跳转"}, {"6", "预览里输入编号跳转"}, {"7", "预览里输入编号跳转"}, {"8", "预览里输入编号跳转"}, {"9", "预览里输入编号跳转"},
	{"Enter", "确认"},
	{"Tab", "切换焦点"},
	{"Cmd+1", "概览"}, {"Cmd+2", "图库"}, {"Cmd+3", "设置"}, {"Cmd+4", "归档"}, {"Cmd+5", "删除记录"}, {"Cmd+6", "快捷键"},
	{"Cmd+,", "设置"},
	{"Cmd+W", "关闭窗口（后台继续运行）"},
	{"Cmd+Q", "退出"},
	{"Cmd+H", "隐藏"},
	{"Cmd+M", "最小化"},
	{"Cmd+C", "拷贝"}, {"Cmd+V", "粘贴"}, {"Cmd+X", "剪切"}, {"Cmd+A", "全选"}, {"Cmd+Z", "撤销"}, {"Cmd+Shift+Z", "重做"},
}

// combo 返回某个操作现在的快捷键；没有（被清除）时 ok 为 false。
func (a *app) combo(id string) (keyCombo, bool) {
	s, set := a.cfg.Shortcuts[id]
	if !set {
		k, _ := findKeyAction(id)
		s = k.def
	}
	return parseCombo(s)
}

// keyLabel 是按钮上显示的快捷键，没有时为空。
func (a *app) keyLabel(id string) string {
	if k, ok := a.combo(id); ok {
		return k.Label()
	}
	return ""
}

// accel 是菜单项用的快捷键写法（没有时为空，菜单项就不带快捷键）。
func (a *app) accel(id string) string {
	if k, ok := a.combo(id); ok {
		return k.String()
	}
	return ""
}

// pressed 报告这一帧是否按了 id 的快捷键。once 为 true 时不算按住不放的自动重复（移出、删除这类）。
func (a *app) pressed(c *ui.Context, id string, once bool) bool {
	k, ok := a.combo(id)
	if !ok || !c.Shortcut(k.mods, k.key) {
		return false
	}
	return !once || !c.ShortcutRepeated()
}

// checkCombo 检查能不能把 k 分给 id：返回空字符串表示可以，否则是给用户看的原因。
func (a *app) checkCombo(id string, k keyCombo) string {
	act, _ := findKeyAction(id)
	s := k.String()
	if s == "" {
		return "这个键不能用作快捷键"
	}
	for _, f := range fixedKeys {
		if fk, ok := parseCombo(f.combo); ok && fk == k {
			return fmt.Sprintf("「%s」是固定的快捷键（%s），换一个", k.Label(), f.label)
		}
	}
	if act.menu && k.mods&(ui.Super|ui.Ctrl) == 0 {
		return "菜单栏命令的快捷键要带 ⌘ 或 ⌃，不然打字时会误触"
	}
	for _, other := range keyActions {
		if other.id == id {
			continue
		}
		if ok2, ok := a.combo(other.id); ok && ok2 == k {
			return fmt.Sprintf("「%s」已经分给了「%s」", k.Label(), other.label)
		}
	}
	return ""
}

// setShortcut 改 id 的快捷键（s 为空表示不用快捷键），和默认值一样时从配置里去掉。
func (a *app) setShortcut(id, s string) {
	act, _ := findKeyAction(id)
	if a.cfg.Shortcuts == nil {
		a.cfg.Shortcuts = map[string]string{}
	}
	if s == act.def {
		delete(a.cfg.Shortcuts, id)
	} else {
		a.cfg.Shortcuts[id] = s
	}
	a.syncMenuKeys()
}

// syncMenuKeys 把菜单栏命令的快捷键同步给菜单（录制时先全部撤掉，免得按 ⌘R 真的开始运行）。
func (a *app) syncMenuKeys() {
	if a.setMenuKeys == nil {
		return
	}
	m := map[string]string{}
	for _, k := range keyActions {
		if k.menu && a.recording == "" {
			m[k.id] = a.accel(k.id)
		} else if k.menu {
			m[k.id] = ""
		}
	}
	a.setMenuKeys(m)
}
