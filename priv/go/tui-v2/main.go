package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/miosa/osa-tui/app"
	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/style"
)

var version = "dev"

func main() {
	profileFlag := flag.String("profile", "", "Named profile for state isolation (~/.osa/profiles/<name>)")
	devFlag := flag.Bool("dev", false, "Dev mode (alias for --profile dev, port 19001)")
	noColor := flag.Bool("no-color", false, "Disable ANSI colors")
	showVersion := flag.Bool("version", false, "Show version and exit")
	flag.BoolVar(showVersion, "V", false, "Show version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("osa %s\n", version)
		os.Exit(0)
	}

	if *noColor {
		// Caller can set NO_COLOR=1 in the shell to disable colors.
		os.Setenv("NO_COLOR", "1")
	}

	baseURL := os.Getenv("OSA_URL")
	if baseURL == "" {
		baseURL = "http://localhost:8089"
	}
	token := os.Getenv("OSA_TOKEN")

	profile := *profileFlag
	if *devFlag {
		profile = "dev"
		if baseURL == "http://localhost:8089" {
			baseURL = "http://localhost:19001"
		}
	}

	var refreshToken string

	if profile != "" {
		home, _ := os.UserHomeDir()
		app.ProfileDir = filepath.Join(home, ".osa", "profiles", profile)
		os.MkdirAll(app.ProfileDir, 0755)

		if token == "" {
			if data, err := os.ReadFile(filepath.Join(app.ProfileDir, "token")); err == nil {
				token = strings.TrimSpace(string(data))
			}
		}
		if data, err := os.ReadFile(filepath.Join(app.ProfileDir, "refresh_token")); err == nil {
			refreshToken = strings.TrimSpace(string(data))
		}
	} else {
		home, _ := os.UserHomeDir()
		app.ProfileDir = filepath.Join(home, ".osa")
		if token == "" {
			if data, err := os.ReadFile(filepath.Join(app.ProfileDir, "token")); err == nil {
				token = strings.TrimSpace(string(data))
			}
		}
		if data, err := os.ReadFile(filepath.Join(app.ProfileDir, "refresh_token")); err == nil {
			refreshToken = strings.TrimSpace(string(data))
		}
	}

	// Auto-detect terminal background and set theme before any rendering.
	if lipgloss.HasDarkBackground(os.Stdin, os.Stdout) {
		style.SetTheme("dark")
	} else {
		style.SetTheme("light")
	}

	c := client.New(baseURL)
	if token != "" {
		c.SetToken(token)
	}

	m := app.New(c)
	if refreshToken != "" {
		m.SetRefreshToken(refreshToken)
	}

	// In bubbletea v2, WithAltScreen and WithMouseCellMotion are no longer
	// ProgramOptions. They are configured on the View struct returned by the
	// model's View() method. Pass no options here.
	p := tea.NewProgram(m)

	go func() {
		p.Send(app.ProgramReady{Program: p})
	}()

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "osa: %v\n", err)
		os.Exit(1)
	}
}
