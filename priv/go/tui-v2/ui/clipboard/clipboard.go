// Package clipboard copies text to the system clipboard using the best
// available mechanism: OSC 52 escape sequences (works over SSH and in
// modern terminals) with a fallback to native OS commands.
package clipboard

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
)

// Copy copies text to the system clipboard.
// It tries OSC 52 first (works in iTerm2, kitty, and most modern terminals,
// including over SSH), then falls back to native OS commands (pbcopy on macOS,
// xclip/xsel on Linux, clip.exe on Windows).
func Copy(text string) error {
	// Attempt OSC 52 first — it requires no external process.
	if err := CopyOSC52(text); err == nil {
		return nil
	}
	return CopyNative(text)
}

// CopyOSC52 writes the OSC 52 clipboard escape sequence directly to the
// controlling terminal (/dev/tty). This works transparently over SSH and in
// any terminal that implements the OSC 52 sequence (iTerm2, kitty, WezTerm,
// foot, Alacritty with OSC-52 enabled, etc.).
func CopyOSC52(text string) error {
	encoded := base64.StdEncoding.EncodeToString([]byte(text))
	seq := fmt.Sprintf("\033]52;c;%s\a", encoded)

	// Write to /dev/tty rather than os.Stdout so that the sequence reaches the
	// terminal even when stdout is piped.
	tty, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
	if err != nil {
		// /dev/tty is unavailable (e.g. Windows or sandboxed env) — fall
		// back to stdout. If that also fails the caller will try native.
		_, err = fmt.Fprint(os.Stdout, seq)
		return err
	}
	defer tty.Close()

	_, err = fmt.Fprint(tty, seq)
	return err
}

// CopyNative uses the platform-specific clipboard command to copy text.
// On macOS it uses pbcopy; on Linux xclip (then xsel as fallback);
// on Windows it uses clip.exe.
func CopyNative(text string) error {
	cmd, args := detectClipboardCmd()
	if cmd == "" {
		return fmt.Errorf("clipboard: no native clipboard command found for %s", runtime.GOOS)
	}

	c := exec.Command(cmd, args...)
	stdin, err := c.StdinPipe()
	if err != nil {
		return fmt.Errorf("clipboard: open stdin pipe: %w", err)
	}

	if err := c.Start(); err != nil {
		return fmt.Errorf("clipboard: start %s: %w", cmd, err)
	}

	if _, err := io.WriteString(stdin, text); err != nil {
		_ = stdin.Close()
		_ = c.Wait()
		return fmt.Errorf("clipboard: write to %s: %w", cmd, err)
	}

	if err := stdin.Close(); err != nil {
		_ = c.Wait()
		return fmt.Errorf("clipboard: close stdin: %w", err)
	}

	if err := c.Wait(); err != nil {
		return fmt.Errorf("clipboard: %s exited: %w", cmd, err)
	}

	return nil
}

// detectClipboardCmd returns the native clipboard command and its arguments
// for the current operating system. Returns ("", nil) when none is available.
func detectClipboardCmd() (string, []string) {
	switch runtime.GOOS {
	case "darwin":
		return "pbcopy", nil

	case "windows":
		return "clip", nil

	case "linux", "freebsd", "openbsd", "netbsd":
		// Prefer xclip; fall back to xsel.
		if path, err := exec.LookPath("xclip"); err == nil {
			return path, []string{"-in", "-selection", "clipboard"}
		}
		if path, err := exec.LookPath("xsel"); err == nil {
			return path, []string{"--clipboard", "--input"}
		}
		// wl-copy for Wayland sessions.
		if path, err := exec.LookPath("wl-copy"); err == nil {
			return path, nil
		}
		return "", nil

	default:
		return "", nil
	}
}
