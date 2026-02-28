// Package anim provides a gradient-animated spinner for OSA TUI v2.
//
// Features:
//   - Braille-dot spinner with per-frame gradient color interpolation
//   - Pre-rendered frame cache (recomputed only when colors change)
//   - Staggered birth offset so multiple concurrent spinners don't phase-lock
//   - Configurable label with optional label color
//   - Ellipsis animation cycling through "", ".", "..", "..." at 400ms per state
//   - 20 FPS tick rate (50ms per frame)
package anim

import (
	"image/color"
	"math"
	"sync/atomic"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// ---------------------------------------------------------------------------
// Constants & package-level state
// ---------------------------------------------------------------------------

const (
	fps           = 20
	frameDuration = time.Second / fps // 50ms
	// ellipsisFrames is how many animation frames elapse per ellipsis state (8 × 50ms = 400ms).
	ellipsisFrames = 8
)

// frames is the Braille-dot spinner sequence.
var frames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// ellipsisStates cycles through the four ellipsis states.
var ellipsisStates = []string{"", ".", "..", "..."}

// idCounter is a global monotonic counter used to give each Model instance a
// unique ID so TickMsg events don't cross-talk between spinners.
var idCounter atomic.Int64

// ---------------------------------------------------------------------------
// TickMsg
// ---------------------------------------------------------------------------

// TickMsg is sent to the Bubble Tea program every animation frame.
// The ID field ensures that only the intended spinner model responds.
type TickMsg struct {
	ID int64
}

// ---------------------------------------------------------------------------
// Opts
// ---------------------------------------------------------------------------

// Opts configures the appearance and behaviour of the spinner.
type Opts struct {
	// Label is the text rendered to the right of the spinner glyph.
	Label string

	// LabelColor is the color applied to the label. Defaults to terminal default
	// when zero-valued.
	LabelColor color.Color

	// GradColorA is the starting gradient color (frame 0). Defaults to #7C3AED.
	GradColorA color.Color

	// GradColorB is the ending gradient color (frame len-1). Defaults to #06B6D4.
	GradColorB color.Color

	// BirthOffset delays the first tick by up to 1 second so that multiple
	// spinners started at the same time appear staggered rather than
	// phase-locked.
	BirthOffset time.Duration
}

// ---------------------------------------------------------------------------
// frameCache
// ---------------------------------------------------------------------------

// frameCache stores pre-rendered spinner strings for the current color pair.
type frameCache struct {
	colorA color.Color
	colorB color.Color
	frames []string // len == len(frames), one per braille glyph
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

// Model is a gradient-animated Braille spinner that implements the Bubble Tea
// component pattern (value receiver Update/View, pointer receiver mutators).
type Model struct {
	id          int64
	opts        Opts
	spinning    bool
	frame       int // current index into frames[]
	ellipsisIdx int // current index into ellipsisStates[]
	cache       frameCache
}

// New creates a new Model from opts. Unset color fields get sensible defaults.
func New(opts Opts) Model {
	if opts.GradColorA == nil {
		opts.GradColorA = lipgloss.Color("#7C3AED") // violet
	}
	if opts.GradColorB == nil {
		opts.GradColorB = lipgloss.Color("#06B6D4") // cyan
	}

	m := Model{
		id:   idCounter.Add(1),
		opts: opts,
	}
	m.cache = m.buildCache()
	return m
}

// ---------------------------------------------------------------------------
// Bubble Tea interface
// ---------------------------------------------------------------------------

// Init satisfies the tea.Model convention. It starts the animation immediately.
func (m Model) Init() (Model, tea.Cmd) {
	m.spinning = true
	return m, m.tick()
}

// Update advances the animation state on each TickMsg addressed to this model.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	tick, ok := msg.(TickMsg)
	if !ok || tick.ID != m.id || !m.spinning {
		return m, nil
	}

	// Advance spinner frame.
	m.frame = (m.frame + 1) % len(frames)

	// Advance ellipsis state every ellipsisFrames ticks.
	if m.frame%ellipsisFrames == 0 {
		m.ellipsisIdx = (m.ellipsisIdx + 1) % len(ellipsisStates)
	}

	return m, m.tick()
}

// View renders the current animation frame. Returns an empty string when the
// spinner is stopped.
func (m Model) View() string {
	if !m.spinning {
		return ""
	}

	glyph := m.cache.frames[m.frame%len(m.cache.frames)]

	if m.opts.Label == "" {
		return glyph + ellipsisStates[m.ellipsisIdx]
	}

	label := m.opts.Label + ellipsisStates[m.ellipsisIdx]
	if m.opts.LabelColor != nil {
		label = lipgloss.NewStyle().Foreground(m.opts.LabelColor).Render(label)
	}

	return glyph + " " + label
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Tick returns a tea.Cmd that schedules the first animation frame. Subsequent
// frames are self-scheduled via Update. Call this when you want the spinner to
// start without going through Init (e.g. after Start()).
func (m Model) Tick() tea.Cmd {
	return m.tick()
}

// SetLabel changes the displayed label text without rebuilding the frame cache.
func (m *Model) SetLabel(s string) {
	m.opts.Label = s
}

// IsSpinning reports whether the animation is currently running.
func (m Model) IsSpinning() bool {
	return m.spinning
}

// Start begins the animation. Use Tick() to schedule the first frame command.
func (m *Model) Start() {
	m.spinning = true
}

// Stop halts the animation. The View() will return "" until Start() is called.
func (m *Model) Stop() {
	m.spinning = false
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// tick returns a tea.Cmd that fires a TickMsg for this model after one frame
// duration, respecting the BirthOffset on the very first tick.
func (m Model) tick() tea.Cmd {
	id := m.id
	delay := frameDuration

	// Apply birth offset only on the first frame (frame == 0 and ellipsisIdx == 0
	// is the freshly initialised state).
	if m.frame == 0 && m.ellipsisIdx == 0 && m.opts.BirthOffset > 0 {
		offset := m.opts.BirthOffset
		if offset > time.Second {
			offset = time.Second // cap at 1s
		}
		delay += offset
	}

	return tea.Tick(delay, func(time.Time) tea.Msg {
		return TickMsg{ID: id}
	})
}

// buildCache pre-renders one colored string per braille frame for the current
// gradient colors. Call this whenever GradColorA or GradColorB change.
func (m Model) buildCache() frameCache {
	n := len(frames)
	rendered := make([]string, n)
	for i, glyph := range frames {
		t := 0.0
		if n > 1 {
			// Smooth oscillation: use a sine wave so the gradient bounces between
			// colorA and colorB rather than wrapping abruptly.
			t = (math.Sin(math.Pi*float64(i)/float64(n-1)) + 1) / 2
		}
		c := lerpColor(m.opts.GradColorA, m.opts.GradColorB, t)
		rendered[i] = lipgloss.NewStyle().Foreground(c).Render(glyph)
	}
	return frameCache{
		colorA: m.opts.GradColorA,
		colorB: m.opts.GradColorB,
		frames: rendered,
	}
}

// lerpColor interpolates linearly between two colors.
// t=0 returns a, t=1 returns b, values in between are blended.
func lerpColor(a, b color.Color, t float64) color.Color {
	ra, ga, ba, _ := a.RGBA()
	rb, gb, bb, _ := b.RGBA()
	return color.RGBA{
		R: uint8(float64(ra>>8)*(1-t) + float64(rb>>8)*t),
		G: uint8(float64(ga>>8)*(1-t) + float64(gb>>8)*t),
		B: uint8(float64(ba>>8)*(1-t) + float64(bb>>8)*t),
		A: 255,
	}
}
