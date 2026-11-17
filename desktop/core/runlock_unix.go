//go:build unix

package core

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// ErrBusy 表示另一个拾景（桌面版或命令行）正在更换壁纸。
var ErrBusy = errors.New("另一个拾景正在更换壁纸（桌面版或命令行），等它完成后再运行")

// lockRun 对锁文件加非阻塞的排他锁（flock）。进程退出（包括崩溃）时系统自动释放，不会留下死锁。
// 锁文件本身留在数据目录里，不删：删了的话另一个进程可能锁住一个已经被删掉的旧文件。
func lockRun(path string) (unlock func(), err error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("打开运行锁失败: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrBusy
		}
		return nil, fmt.Errorf("加运行锁失败: %w", err)
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}
