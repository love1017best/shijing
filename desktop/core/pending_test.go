package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// mkfile 建一个临时文件并返回它的指纹。
func mkfile(t *testing.T, dir, name, content string) (string, int64, time.Time) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return p, fi.Size(), fi.ModTime()
}

func TestRunPendingDeletesMatchingFiles(t *testing.T) {
	dir := t.TempDir()
	p, size, mod := mkfile(t, dir, "a.jpg", "hello")
	res := RunPending([]PendingDelete{{Path: p, Size: size, ModTime: mod}}, nil)
	if len(res.Deleted) != 1 || len(res.Kept)+len(res.Stale)+len(res.Gone) != 0 {
		t.Fatalf("应该删掉: %+v", res)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("文件还在: %v", err)
	}
}

// 排队时看到的是 A，执行时那个路径已经是别的文件了：不删。
func TestRunPendingSkipsChangedFile(t *testing.T) {
	dir := t.TempDir()
	p, size, _ := mkfile(t, dir, "a.jpg", "hello")
	res := RunPending([]PendingDelete{{Path: p, Size: size, ModTime: time.Now().Add(-time.Hour)}}, nil)
	if len(res.Stale) != 1 || len(res.Deleted) != 0 {
		t.Fatalf("修改时间对不上时应当留着: %+v", res)
	}
	if _, err := os.Stat(p); err != nil {
		t.Errorf("不应删掉改过的文件: %v", err)
	}
}

// 排队时没拿到指纹（全零）：只要求文件还在。
func TestRunPendingWithoutFingerprint(t *testing.T) {
	dir := t.TempDir()
	p, _, _ := mkfile(t, dir, "a.jpg", "hello")
	res := RunPending([]PendingDelete{{Path: p}}, nil)
	if len(res.Deleted) != 1 {
		t.Fatalf("没有指纹时文件还在就删: %+v", res)
	}
}

func TestRunPendingWaitsForUnmounted(t *testing.T) {
	dir := t.TempDir()
	p, size, mod := mkfile(t, dir, "a.jpg", "hello")
	res := RunPending([]PendingDelete{{Path: p, Size: size, ModTime: mod}}, func(string) bool { return false })
	if len(res.Kept) != 1 || len(res.Deleted) != 0 {
		t.Fatalf("目录还没挂上时应当留到下次: %+v", res)
	}
	if _, err := os.Stat(p); err != nil {
		t.Errorf("不该动文件: %v", err)
	}
}

// 文件已经不在了、所在目录还在：当作删掉了；目录都没了：多半是卷断开，留着。
func TestRunPendingMissingFile(t *testing.T) {
	dir := t.TempDir()
	res := RunPending([]PendingDelete{{Path: filepath.Join(dir, "gone.jpg")}}, nil)
	if len(res.Gone) != 1 || len(res.Kept) != 0 {
		t.Fatalf("文件没了、目录还在：当作已删除: %+v", res)
	}

	missingDir := filepath.Join(dir, "unmounted", "gone.jpg")
	res = RunPending([]PendingDelete{{Path: missingDir}}, nil)
	if len(res.Kept) != 1 || len(res.Gone) != 0 {
		t.Fatalf("目录都没了：留着等下次: %+v", res)
	}
}

func TestPendingSaveLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pending.json")
	if got := LoadPending(path); got != nil {
		t.Errorf("文件不存在时应当是空队列: %+v", got)
	}
	list := []PendingDelete{{Path: "/a/b.jpg", Size: 3, ModTime: time.Unix(1700000000, 0), Wall: "b.jpg"}}
	if err := SavePending(path, list); err != nil {
		t.Fatal(err)
	}
	got := LoadPending(path)
	if len(got) != 1 || got[0].Path != "/a/b.jpg" || !got[0].ModTime.Equal(list[0].ModTime) {
		t.Errorf("读回来的不对: %+v", got)
	}
	// 空队列时删掉文件，数据目录里不留空壳
	if err := SavePending(path, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("空队列应当删掉文件: %v", err)
	}
}
