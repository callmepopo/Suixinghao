package main

import (
	"os"
	"path/filepath"
	"strings"
)

// Service state belongs to the deployer's private appdata, outside the source tree.
func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func dataPath(name string) string {
	return filepath.Join(envOrDefault("VOICE_WEB_DATA_DIR", "/mnt/user/appdata/suixinghao"), name)
}
