package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Config holds persistent TUI settings stored at <profileDir>/tui.json.
type Config struct {
	Theme        string `json:"theme,omitempty"`
	DefaultModel string `json:"default_model,omitempty"`
	BackendURL   string `json:"backend_url,omitempty"`
}

const filename = "tui.json"

// Load reads <profileDir>/tui.json and returns the parsed Config.
// If the file is absent or unreadable, a default Config is returned.
func Load(profileDir string) Config {
	cfg := defaults()
	data, err := os.ReadFile(filepath.Join(profileDir, filename))
	if err != nil {
		return cfg
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return defaults()
	}
	return cfg
}

// Save writes cfg to <profileDir>/tui.json, creating the directory if needed.
func Save(profileDir string, cfg Config) error {
	if err := os.MkdirAll(profileDir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(profileDir, filename), data, 0o644)
}

func defaults() Config {
	return Config{
		Theme:        "dark",
		BackendURL:   "",
		DefaultModel: "",
	}
}
