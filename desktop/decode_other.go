//go:build !darwin

package main

import "image"

// systemDecode 只在 macOS 上有（ImageIO），别的平台用纯 Go 解码。
func systemDecode(string, int) image.Image { return nil }
