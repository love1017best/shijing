package core

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteFileAtomic(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "sub", "state.json")
	if err := WriteFileAtomic(p, []byte("one"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteFileAtomic(p, []byte("two"), 0o600); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(p)
	if err != nil || string(data) != "two" {
		t.Fatalf("内容 %q, %v", data, err)
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o600 {
		t.Fatalf("权限 %v", st.Mode().Perm())
	}
	ents, _ := os.ReadDir(filepath.Dir(p))
	if len(ents) != 1 {
		t.Fatalf("留下了临时文件: %v", ents)
	}
}

func TestBackupBadConfig(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "config.json")
	if BackupBadConfig(p) != "" {
		t.Fatal("文件不存在时不应备份")
	}
	if err := os.WriteFile(p, []byte("{坏"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(p); err == nil {
		t.Fatal("坏 JSON 应该报错")
	}
	bak := BackupBadConfig(p)
	if !strings.HasPrefix(filepath.Base(bak), "config.json.bad-") {
		t.Fatalf("备份名 %q", bak)
	}
	if data, _ := os.ReadFile(bak); string(data) != "{坏" {
		t.Fatalf("备份内容 %q", data)
	}
	if exists(p) {
		t.Fatal("原文件应该被挪走")
	}
}

func TestRunPipelineLock(t *testing.T) {
	dir := t.TempDir()
	paths := PathsIn(dir)
	unlock, err := lockRun(paths.Lock)
	if err != nil {
		t.Fatal(err)
	}
	_, err = RunPipeline(Defaults(), paths, Reporter{}, nil)
	if !errors.Is(err, ErrBusy) {
		t.Fatalf("另一个在运行时应返回 ErrBusy，实际 %v", err)
	}
	unlock()
	again, err := lockRun(paths.Lock)
	if err != nil {
		t.Fatalf("释放后应能再加锁: %v", err)
	}
	again()
}
