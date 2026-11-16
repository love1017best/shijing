package main

import "testing"

// 说明气泡不跟着换页：切到别的页面再回来，不会还浮着上次打开的那一个。
func TestHelpPopoverClosesOnPageSwitch(t *testing.T) {
	_, tt := newFakeApp(t)
	tt.Frame()
	click(t, tt, "设置")
	tt.Frame()
	click(t, tt, "「存放方式」的说明")
	tt.Frame()
	open, ok := helpOpen["存放方式"]
	if !ok || !*open {
		t.Fatalf("点问号后说明气泡应打开")
	}
	click(t, tt, "概览")
	tt.Frame()
	if *open {
		t.Fatalf("切到别的页面后说明气泡应关上")
	}
}
