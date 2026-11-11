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

// TestNoTeamIDInProject 防止开发团队 ID 进公开仓库：在 Xcode 里选 Team 会把它写进工程文件，
// 应该挪到 gitignore 的 ios/ShiJing/Local.xcconfig 再重新 xcodegen（见 ios/README.md）。
func TestNoTeamIDInProject(t *testing.T) {
	for _, p := range []string{"../ios/ShiJing.xcodeproj/project.pbxproj", "../ios/project.yml", "../ios/ShiJing/Signing.xcconfig"} {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if m := regexp.MustCompile(`DEVELOPMENT_TEAM\s*[=:]\s*"?[A-Z0-9]{10}`).Find(raw); m != nil {
			t.Errorf("%s 里有开发团队 ID，要挪到 ios/ShiJing/Local.xcconfig 后重新 xcodegen", p)
		}
	}
}
