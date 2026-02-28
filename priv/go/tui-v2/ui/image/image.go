// Package image provides terminal image rendering for OSA TUI v2.
// It detects the best available protocol (Kitty, iTerm2, Sixel) and falls
// back to a styled text placeholder when none is supported.
package image

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// Protocol identifies the terminal image rendering protocol.
type Protocol int

const (
	ProtocolNone   Protocol = iota // no image support; use placeholder
	ProtocolKitty                  // Kitty graphics protocol (APC escape)
	ProtocolITerm2                 // iTerm2 inline images (OSC 1337)
	ProtocolSixel                  // DEC Sixel graphics
)

// String returns a human-readable name for the protocol.
func (p Protocol) String() string {
	switch p {
	case ProtocolKitty:
		return "Kitty"
	case ProtocolITerm2:
		return "iTerm2"
	case ProtocolSixel:
		return "Sixel"
	default:
		return "None"
	}
}

// DetectProtocol checks environment variables to determine which image
// rendering protocol the running terminal supports.
//
// Priority: Kitty (WezTerm/Ghostty) > iTerm2 > Sixel > None.
func DetectProtocol() Protocol {
	switch os.Getenv("TERM_PROGRAM") {
	case "WezTerm", "ghostty":
		return ProtocolKitty
	case "iTerm.app", "iTerm2.app":
		return ProtocolITerm2
	}

	term := os.Getenv("TERM")
	if strings.Contains(term, "sixel") {
		return ProtocolSixel
	}

	// Some terminals advertise Kitty support via TERM alone.
	if strings.Contains(term, "kitty") {
		return ProtocolKitty
	}

	return ProtocolNone
}

// Render encodes raw image bytes and emits the appropriate terminal escape
// sequence for inline display. Falls back to Placeholder when the detected
// protocol is ProtocolNone.
//
// maxWidth and maxHeight are advisory cell dimensions; the terminal controls
// actual scaling.
func Render(data []byte, filename string, maxWidth, maxHeight int) string {
	return renderWithProtocol(DetectProtocol(), data, filename, maxWidth, maxHeight)
}

// RenderBase64 is like Render but accepts an already-encoded base64 string.
func RenderBase64(b64 string, filename string, maxWidth, maxHeight int) string {
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return Placeholder(filename, maxWidth, maxHeight)
	}
	return Render(data, filename, maxWidth, maxHeight)
}

// Placeholder returns a styled text stand-in used when image rendering is
// unavailable or the image cannot be decoded.
func Placeholder(filename string, width, height int) string {
	name := filepath.Base(filename)
	return style.Faint.Render(fmt.Sprintf("[Image: %s (%dx%d)]", name, width, height))
}

// renderWithProtocol dispatches to the correct encoder based on protocol.
// Exposed as a separate function to simplify testing.
func renderWithProtocol(proto Protocol, data []byte, filename string, maxWidth, maxHeight int) string {
	switch proto {
	case ProtocolKitty:
		return renderKitty(data, maxWidth)
	case ProtocolITerm2:
		return renderITerm2(data, filename, maxWidth)
	case ProtocolSixel:
		// Sixel encoding requires pixel-level image manipulation which is
		// out of scope here. Emit a placeholder indicating Sixel would be
		// used — callers that need real Sixel support should pre-encode the
		// data and pass it as a raw escape string.
		return Placeholder(filename, maxWidth, maxHeight)
	default:
		return Placeholder(filename, maxWidth, maxHeight)
	}
}

// renderKitty emits a Kitty Graphics Protocol APC sequence for an image.
// The payload is a single base64 chunk (a=T means transmit-and-display,
// f=100 means PNG, C=1 moves the cursor to the next line after rendering).
func renderKitty(data []byte, maxWidth int) string {
	b64 := base64.StdEncoding.EncodeToString(data)

	// The Kitty protocol supports chunked payloads for large images. For
	// simplicity we send a single chunk; terminals are required to buffer it.
	// m=0 means this is the only (final) chunk.
	return fmt.Sprintf("\033_Ga=T,f=100,c=%d,m=0;%s\033\\", maxWidth, b64)
}

// renderITerm2 emits an iTerm2 OSC 1337 inline-image escape sequence.
// The filename is base64-encoded per the iTerm2 specification.
func renderITerm2(data []byte, filename string, maxWidth int) string {
	b64Data := base64.StdEncoding.EncodeToString(data)
	b64Name := base64.StdEncoding.EncodeToString([]byte(filepath.Base(filename)))
	size := len(data)

	return fmt.Sprintf(
		"\033]1337;File=name=%s;size=%d;inline=1;width=%d:%s\007",
		b64Name, size, maxWidth, b64Data,
	)
}
