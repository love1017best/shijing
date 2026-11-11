package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"

	"github.com/egoist/mygo/ui"
)

// 「移出壁纸文件夹」「移出并不再选它」可以用 ⌘Z 撤销：移出时文件先挪进数据目录的 undo/ 暂存，
// 撤销时挪回原处、放回原来的位置（不再选的那条也去掉）。「删除图库里的原图」不能撤销。
// 暂存只在这次打开应用期间有效：启动时、开始换一批之前清空（换一批会清空壁纸文件夹，放回去也没意义）。

const maxUndo = 50

// removedWall 是一次可以撤销的移出。
type removedWall struct {
	wall, stash string
	idx         int        // 在 walls.all 里的位置
	thumbIdx    int        // 在缩略图里的位置，-1 表示没有缩略图
	thumb       *ui.Bitmap // 缩略图（放回时不用重新解码）
	excluded    string     // 这次加进「不再选」的原图，撤销时去掉；没加为空
}

func (a *app) undoDir() string { return filepath.Join(filepath.Dir(a.cfgPath), "undo") }

// clearUndo 清空撤销记录和暂存的文件。
func (a *app) clearUndo() {
	a.undo = nil
	_ = os.RemoveAll(a.undoDir())
}

// stashWall 把壁纸挪进暂存目录，返回暂存路径。
func (a *app) stashWall(wall string) (string, error) {
	dir := a.undoDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	a.undoSeq++
	stash := filepath.Join(dir, fmt.Sprintf("%d-%s", a.undoSeq, filepath.Base(wall)))
	return stash, moveFile(wall, stash)
}

// moveFile 先试 rename，跨卷（壁纸文件夹不在系统盘上）时退回复制 + 删除。
func moveFile(from, to string) error {
	if err := os.Rename(from, to); err == nil {
		return nil
	}
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.Create(to)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(to)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(to)
		return err
	}
	_ = os.Chtimes(to, st.ModTime(), st.ModTime())
	return os.Remove(from)
}

// pushUndo 记下一次移出（文件已经挪进 stash）。
func (a *app) pushUndo(r removedWall) {
	a.undo = append(a.undo, r)
	if len(a.undo) > maxUndo {
		_ = os.Remove(a.undo[0].stash)
		a.undo = slices.Delete(a.undo, 0, 1)
	}
}

// undoRemove 撤销最近一次移出：文件放回壁纸文件夹、回到原来的位置，预览开着时跳到它。
func (a *app) undoRemove() {
	if len(a.undo) == 0 || a.running {
		return
	}
	r := a.undo[len(a.undo)-1]
	a.undo = a.undo[:len(a.undo)-1]
	if _, err := os.Stat(r.wall); err == nil {
		a.toast = "壁纸文件夹里已经有同名文件，没法放回 " + filepath.Base(r.wall)
		return
	}
	if err := moveFile(r.stash, r.wall); err != nil {
		a.showErr("撤销失败", err.Error())
		return
	}
	if r.excluded != "" {
		a.cfg.Excluded = slices.DeleteFunc(a.cfg.Excluded, func(p string) bool { return p == r.excluded })
	}
	w := &a.walls
	i := min(max(r.idx, 0), len(w.all))
	w.all = slices.Insert(w.all, i, r.wall)
	if r.thumbIdx >= 0 && r.thumb != nil {
		j := min(r.thumbIdx, len(w.paths))
		w.paths = slices.Insert(w.paths, j, r.wall)
		w.thumbs = slices.Insert(w.thumbs, j, r.thumb)
	} else {
		w.rest = slices.Insert(w.rest, 0, r.wall)
	}
	w.total++
	if a.preview {
		a.previewIdx = i
	}
	msg := "已撤销，放回了壁纸文件夹"
	if r.excluded != "" {
		msg = "已撤销，放回了壁纸文件夹，也不再跳过它"
	}
	a.toast = msg
}

// undoKey 在有可撤销的移出时接 ⌘Z。注册了快捷键，「编辑」菜单的「撤销」才会亮、按键才会传到这里。
// 预览开着时要在 Modal 里面调（外面收不到），所以 view 和 previewKeys 各调一次，按 a.preview 分开。
func (a *app) undoKey(c *ui.Context) {
	if len(a.undo) > 0 && !a.running && c.Shortcut(ui.Cmd, ui.KeyZ) {
		a.undoRemove()
	}
}
