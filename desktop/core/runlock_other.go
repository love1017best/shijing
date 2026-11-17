//go:build !unix

package core

import "errors"

// ErrBusy 表示另一个拾景正在更换壁纸；这个平台上不加锁，不会返回。
var ErrBusy = errors.New("另一个拾景正在更换壁纸（桌面版或命令行），等它完成后再运行")

func lockRun(string) (func(), error) { return func() {}, nil }
