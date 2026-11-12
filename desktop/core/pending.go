package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// PendingDelete 是一条「图库现在连不上，等连上再删」的原图。
//
// 记录大小和修改时间是执行前的指纹：排队时看到的是 A，执行时那个路径上可能已经是别的文件了
// （NAS 上的图片被改名、删掉后又被新建），对不上就不删，留给用户判断。
// 排队时拿不到文件信息（多半就是这个原因才排队的），Size 和 ModTime 为零，执行时只确认文件还在。
type PendingDelete struct {
	Path    string    `json:"path"`
	Size    int64     `json:"size,omitempty"`
	ModTime time.Time `json:"mod_time,omitempty"`
	Wall    string    `json:"wall,omitempty"` // 壁纸文件夹里的文件名，只用来显示
	AddedAt time.Time `json:"added_at"`
}

// PendingResult 是一次尝试执行的结果。
type PendingResult struct {
	Deleted []PendingDelete // 删掉了
	Gone    []PendingDelete // 已经不在了，当作删掉
	Stale   []PendingDelete // 文件变了（大小或修改时间对不上），没有删
	Kept    []PendingDelete // 目录还连不上或者出错了，留在队列里下次再试
}

// LoadPending 读取待办队列；文件不存在或者读不懂都当成空队列（下次保存时会覆盖掉坏文件）。
func LoadPending(path string) []PendingDelete {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var list []PendingDelete
	if json.Unmarshal(data, &list) != nil {
		return nil
	}
	return list
}

// SavePending 写回待办队列（空列表时删掉文件，不在数据目录里留个空壳）。
func SavePending(path string, list []PendingDelete) error {
	if len(list) == 0 {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// RunPending 逐条校验并删除。mounted 判断某个原图所在的图库目录现在能不能访问
// （调用方按挂载状态给，连不上的直接留着，免得对着断掉的网络卷发一堆会阻塞的请求）。
// 返回的 Stale 已经做过判断，调用方应当从队列里去掉，提示用户这张没删。
func RunPending(entries []PendingDelete, mounted func(path string) bool) PendingResult {
	var res PendingResult
	for _, e := range entries {
		if mounted != nil && !mounted(e.Path) {
			res.Kept = append(res.Kept, e)
			continue
		}
		fi, err := os.Stat(e.Path)
		if err != nil {
			if !os.IsNotExist(err) {
				res.Kept = append(res.Kept, e) // 读不了：可能是临时的 I/O 错误，下次再试
				continue
			}
			if dirMissing(e.Path) {
				res.Kept = append(res.Kept, e) // 连所在目录都没了：卷多半是断开了
				continue
			}
			res.Gone = append(res.Gone, e)
			continue
		}
		if !fingerprintMatch(e, fi.Size(), fi.ModTime()) {
			res.Stale = append(res.Stale, e)
			continue
		}
		if err := os.Remove(e.Path); err != nil {
			if os.IsNotExist(err) {
				res.Gone = append(res.Gone, e)
			} else {
				res.Kept = append(res.Kept, e)
			}
			continue
		}
		res.Deleted = append(res.Deleted, e)
	}
	return res
}

// fingerprintMatch 判断文件还是排队时看到的那一个。排队时没拿到指纹（全零）就只要求文件还在。
func fingerprintMatch(e PendingDelete, size int64, mod time.Time) bool {
	if e.Size == 0 && e.ModTime.IsZero() {
		return true
	}
	return e.Size == size && e.ModTime.Equal(mod)
}

// dirMissing 判断文件所在的目录是不是根本不存在（网络卷断开时整条路径都 stat 不到）。
func dirMissing(path string) bool {
	_, err := os.Lstat(filepath.Dir(path))
	return os.IsNotExist(err)
}
