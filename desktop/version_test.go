package main

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestVersionsInSync 检查 macOS 和 iOS 两端的版本号一致（每次发布两端一起发，见 CLAUDE.md）：
// mygo.json 的 version = project.yml 和生成的 Xcode 工程里的 MARKETING_VERSION，
// CURRENT_PROJECT_VERSION = 版本号的 Z。改版本号用 scripts/bump-version.sh。
func TestVersionsInSync(t *testing.T) {
	data, err := os.ReadFile("mygo.json")
	if err != nil {
		t.Fatal(err)
	}
	var mg struct{ Version string }
	if err := json.Unmarshal(data, &mg); err != nil {
		t.Fatal(err)
	}
	z := mg.Version[strings.LastIndex(mg.Version, ".")+1:]

	for _, f := range []struct{ path, marketing, build string }{
		{"../ios/project.yml", `MARKETING_VERSION: "([^"]*)"`, `CURRENT_PROJECT_VERSION: "([^"]*)"`},
		{"../ios/ShiJing.xcodeproj/project.pbxproj", `MARKETING_VERSION = ([^;]*);`, `CURRENT_PROJECT_VERSION = ([^;]*);`},
	} {
		raw, err := os.ReadFile(f.path)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range []struct{ re, want string }{{f.marketing, mg.Version}, {f.build, z}} {
			ms := regexp.MustCompile(c.re).FindAllStringSubmatch(string(raw), -1)
			if len(ms) == 0 {
				t.Fatalf("%s 里找不到 %s", f.path, c.re)
			}
			for _, m := range ms {
				if m[1] != c.want {
					t.Errorf("%s: %s 是 %q，应该是 %q（用 scripts/bump-version.sh 同时改两端）", f.path, strings.TrimSuffix(strings.Fields(c.re)[0], ":"), m[1], c.want)
				}
			}
		}
	}
}
