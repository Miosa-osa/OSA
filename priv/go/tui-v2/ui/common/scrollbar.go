// Package common — dedicated scrollbar component for OSA TUI v2.
package common

import (
	"strings"

	"github.com/miosa/osa-tui/style"
)

const (
	scrollTrackChar = "│"
	scrollThumbChar = "█"
)

// ScrollbarModel tracks the dimensions needed to render a vertical scrollbar.
type ScrollbarModel struct {
	viewportHeight int
	contentHeight  int
	offset         int
}

// NewScrollbar creates a ScrollbarModel with the given dimensions.
func NewScrollbar(viewportHeight, contentHeight, offset int) ScrollbarModel {
	return ScrollbarModel{
		viewportHeight: viewportHeight,
		contentHeight:  contentHeight,
		offset:         offset,
	}
}

// SetDimensions updates the scrollbar dimensions.
func (s *ScrollbarModel) SetDimensions(viewportHeight, contentHeight, offset int) {
	s.viewportHeight = viewportHeight
	s.contentHeight = contentHeight
	s.offset = offset
}

// View renders a vertical scrollbar as a single column of characters.
//
// The track occupies viewportHeight rows. The thumb is positioned and sized
// proportionally to the visible region within the total content. When the
// content fits within the viewport the returned string is empty.
func (s ScrollbarModel) View() string {
	vh := s.viewportHeight
	ch := s.contentHeight

	if vh <= 0 || ch <= vh {
		// No scrollbar needed.
		return ""
	}

	// Thumb height — at least 1 row.
	thumbH := vh * vh / ch
	if thumbH < 1 {
		thumbH = 1
	}
	if thumbH > vh {
		thumbH = vh
	}

	// Thumb top position within the track.
	scrollable := ch - vh
	thumbTop := 0
	if scrollable > 0 {
		thumbTop = (s.offset * (vh - thumbH)) / scrollable
	}
	if thumbTop+thumbH > vh {
		thumbTop = vh - thumbH
	}
	if thumbTop < 0 {
		thumbTop = 0
	}

	rows := make([]string, vh)
	for i := range rows {
		if i >= thumbTop && i < thumbTop+thumbH {
			rows[i] = style.ScrollbarThumb.Render(scrollThumbChar)
		} else {
			rows[i] = style.ScrollbarTrack.Render(scrollTrackChar)
		}
	}
	return strings.Join(rows, "\n")
}

// Scrollbar is a convenience function that builds a one-shot scrollbar string
// without creating a persistent model.
func Scrollbar(viewportHeight, contentHeight, offset int) string {
	m := NewScrollbar(viewportHeight, contentHeight, offset)
	return m.View()
}
