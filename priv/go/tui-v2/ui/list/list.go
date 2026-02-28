// Package list provides a lazy-rendered, offset-based scrollable list widget
// for OSA TUI v2. It is designed for chat-style UIs where content grows
// downward and the viewport should track the newest item at the bottom.
//
// Key properties:
//   - Per-item height calculation and content cache, invalidated on width or
//     content-version changes.
//   - Offset-based scrolling: offsetIdx is the index of the topmost visible
//     item; offsetLine is the sub-item line offset for partial-top-item display.
//   - Reverse mode: items are rendered bottom-up so the last item is always
//     at the bottom of the viewport (chat-grows-upward UX).
//   - Only the items that fall within the visible viewport are rendered on
//     each View() call — everything else is skipped entirely.
//   - Gap lines between items are configurable and factored into all
//     height/scroll calculations.
package list

import (
	"strings"

	tea "charm.land/bubbletea/v2"
)

// ---------------------------------------------------------------------------
// Public interfaces
// ---------------------------------------------------------------------------

// Item is anything the list can render.
type Item interface {
	// ID returns a unique, stable identifier used for cache keying and
	// targeted cache invalidation.
	ID() string

	// ContentVersion returns a monotonically increasing integer. When this
	// value changes the cached render for this item is discarded.
	ContentVersion() int

	// Height returns the rendered height in terminal lines for the given width.
	// The result must be stable for the same (width, ContentVersion) pair.
	Height(width int) int

	// Render returns the rendered string for the given width.
	// The result must be stable for the same (width, ContentVersion) pair.
	Render(width int) string
}

// MouseClickable items can handle click events.
type MouseClickable interface {
	HandleClick(x, y int) tea.Cmd
}

// MatchSettable items support fuzzy match highlighting.
type MatchSettable interface {
	SetMatches(positions []int)
}

// Highlightable items support text selection.
type Highlightable interface {
	SetHighlight(startLine, endLine, startCol, endCol int)
	ClearHighlight()
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

// Option is a functional option for New.
type Option func(*Model)

// WithWidth sets the initial viewport width.
func WithWidth(w int) Option {
	return func(m *Model) { m.width = w }
}

// WithHeight sets the initial viewport height (number of terminal lines
// visible at once).
func WithHeight(h int) Option {
	return func(m *Model) { m.height = h }
}

// WithReverse enables reverse (chat) mode: the last item is anchored to the
// bottom of the viewport and the list grows upward.
func WithReverse(r bool) Option {
	return func(m *Model) { m.reverse = r }
}

// WithGap sets the number of blank lines inserted between consecutive items.
func WithGap(g int) Option {
	return func(m *Model) {
		if g >= 0 {
			m.gap = g
		}
	}
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

type cachedRender struct {
	content string
	height  int
	width   int
	version int
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

// Model is a lazy-rendered scrollable list.
// The zero value is not usable; construct with New.
type Model struct {
	items  []Item
	width  int
	height int

	// reverse=true: newest item at bottom, list grows upward.
	reverse bool

	// gap is the number of blank lines between items.
	gap int

	// Scroll state.
	// offsetIdx  — index of the topmost visible item (forward mode) or the
	//               bottommost visible item (reverse mode).
	// offsetLine — how many lines of item[offsetIdx] are scrolled off the top
	//               (forward) or off the bottom (reverse).
	offsetIdx  int
	offsetLine int

	// totalHeight is the cached sum of all item heights + inter-item gaps.
	// Kept up-to-date after any mutation.
	totalHeight int

	// cache stores rendered output keyed by item ID.
	cache map[string]cachedRender
}

// New constructs a Model with the supplied options.
func New(opts ...Option) Model {
	m := Model{
		cache: make(map[string]cachedRender),
	}
	for _, o := range opts {
		o(&m)
	}
	return m
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

// SetSize updates the viewport dimensions. The cache is invalidated when
// width changes because every item must be re-rendered at the new width.
func (m *Model) SetSize(w, h int) {
	if w != m.width {
		m.cache = make(map[string]cachedRender)
	}
	m.width = w
	m.height = h
	m.clampScroll()
}

// SetGap updates the number of blank lines between items.
func (m *Model) SetGap(n int) {
	if n >= 0 {
		m.gap = n
		m.recomputeTotal()
		m.clampScroll()
	}
}

// SetReverse sets the reverse rendering mode.
func (m *Model) SetReverse(r bool) {
	m.reverse = r
}

// SetItems replaces the item slice wholesale and recomputes the total height.
// The cache is preserved: items whose ID+version are unchanged are not
// re-rendered.
func (m *Model) SetItems(items []Item) {
	m.items = items
	m.recomputeTotal()
	m.clampScroll()
}

// AppendItem adds a single item to the end of the list and updates the total
// height without touching the cache for existing items.
func (m *Model) AppendItem(item Item) {
	m.items = append(m.items, item)
	// Incrementally update total height instead of a full scan.
	extra := m.itemHeight(item)
	if len(m.items) > 1 {
		extra += m.gap
	}
	m.totalHeight += extra
	m.clampScroll()
}

// PrependItems inserts items at the beginning of the list (for loading history).
// The scroll position is adjusted to keep the currently-visible content stable.
func (m *Model) PrependItems(items []Item) {
	if len(items) == 0 {
		return
	}
	m.items = append(items, m.items...)
	// Adjust offsetIdx to account for the prepended items.
	m.offsetIdx += len(items)
	m.recomputeTotal()
	m.clampScroll()
}

// UpdateItem replaces the item with the given id in-place and invalidates
// its cache entry. If the id is not found, the call is a no-op.
func (m *Model) UpdateItem(id string, item Item) {
	for i, existing := range m.items {
		if existing.ID() == id {
			m.items[i] = item
			delete(m.cache, id)
			m.recomputeTotal()
			m.clampScroll()
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Scroll
// ---------------------------------------------------------------------------

// ScrollToBottom positions the viewport so the last item is fully visible.
func (m *Model) ScrollToBottom() {
	if len(m.items) == 0 {
		m.offsetIdx = 0
		m.offsetLine = 0
		return
	}
	if m.reverse {
		// In reverse mode, fully visible bottom = offsetIdx=0, offsetLine=0
		// (the last item is the anchor; walking from the end covers the view).
		m.offsetIdx = 0
		m.offsetLine = 0
		return
	}
	// Forward mode: we want the last item visible at the bottom. Walk
	// backward from the last item filling the viewport.
	m.offsetIdx, m.offsetLine = m.computeTopForBottom()
}

// ScrollToTop positions the viewport at the very first item.
func (m *Model) ScrollToTop() {
	m.offsetIdx = 0
	m.offsetLine = 0
}

// WrapToStart wraps navigation to the first item (circular navigation).
func (m *Model) WrapToStart() {
	m.ScrollToTop()
}

// WrapToEnd wraps navigation to the last item (circular navigation).
func (m *Model) WrapToEnd() {
	m.ScrollToBottom()
}

// ScrollDown scrolls the content down by lines lines (viewport moves down,
// content scrolls up — earlier items disappear from top, later items appear).
func (m *Model) ScrollDown(lines int) {
	if lines <= 0 || len(m.items) == 0 {
		return
	}
	if m.reverse {
		m.scrollReverseDown(lines)
	} else {
		m.scrollForwardDown(lines)
	}
	m.clampScroll()
}

// ScrollUp scrolls the content up by lines lines (viewport moves up, earlier
// content reappears at the top).
func (m *Model) ScrollUp(lines int) {
	if lines <= 0 || len(m.items) == 0 {
		return
	}
	if m.reverse {
		m.scrollReverseUp(lines)
	} else {
		m.scrollForwardUp(lines)
	}
	m.clampScroll()
}

// PageDown scrolls down by one full viewport height.
func (m *Model) PageDown() { m.ScrollDown(m.height) }

// PageUp scrolls up by one full viewport height.
func (m *Model) PageUp() { m.ScrollUp(m.height) }

// HalfPageDown scrolls down by half the viewport height.
func (m *Model) HalfPageDown() { m.ScrollDown(m.height / 2) }

// HalfPageUp scrolls up by half the viewport height.
func (m *Model) HalfPageUp() { m.ScrollUp(m.height / 2) }

// AtBottom reports whether the viewport is currently showing the bottom of
// the list (i.e., auto-scroll would be a no-op).
func (m Model) AtBottom() bool {
	if len(m.items) == 0 {
		return true
	}
	if m.reverse {
		return m.offsetIdx == 0 && m.offsetLine == 0
	}
	idx, line := m.computeTopForBottom()
	return m.offsetIdx == idx && m.offsetLine == line
}

// ---------------------------------------------------------------------------
// Position helpers
// ---------------------------------------------------------------------------

// ItemIndexAtPosition resolves a y coordinate (relative to the top of the
// viewport) to the index of the item rendered at that line. Returns -1 if
// the coordinate is out of range or falls on a gap line.
func (m Model) ItemIndexAtPosition(y int) int {
	if y < 0 || y >= m.height || len(m.items) == 0 {
		return -1
	}

	if m.reverse {
		return m.itemIndexAtPositionReverse(y)
	}
	return m.itemIndexAtPositionForward(y)
}

func (m Model) itemIndexAtPositionForward(y int) int {
	line := 0
	for i := m.offsetIdx; i < len(m.items) && line <= y; i++ {
		h := m.itemHeight(m.items[i])
		startLine := 0
		if i == m.offsetIdx {
			startLine = m.offsetLine
		}
		visibleLines := h - startLine
		if visibleLines <= 0 {
			continue
		}
		if y < line+visibleLines {
			return i
		}
		line += visibleLines
		// Gap lines.
		if i < len(m.items)-1 && m.gap > 0 {
			if y < line+m.gap {
				return -1 // gap
			}
			line += m.gap
		}
	}
	return -1
}

func (m Model) itemIndexAtPositionReverse(y int) int {
	// Build a layout matching viewReverse, then look up y.
	type entry struct {
		itemIdx    int // -1 for gap/padding
		lineInItem int
	}
	layout := make([]entry, m.height)
	for i := range layout {
		layout[i] = entry{itemIdx: -1}
	}

	remaining := m.height
	anchorIdx := len(m.items) - 1 - m.offsetIdx
	if anchorIdx < 0 {
		anchorIdx = 0
	}

	type seg struct {
		entries []entry
	}
	var segs []seg

	for i := anchorIdx; i >= 0 && remaining > 0; i-- {
		h := m.itemHeight(m.items[i])
		endLine := h
		if i == anchorIdx && m.offsetLine > 0 {
			endLine -= m.offsetLine
			if endLine < 0 {
				endLine = 0
			}
		}
		visLines := endLine
		startLine := 0
		if visLines > remaining {
			startLine = visLines - remaining
			visLines = remaining
		}
		entries := make([]entry, visLines)
		for j := 0; j < visLines; j++ {
			entries[j] = entry{itemIdx: i, lineInItem: startLine + j}
		}
		if len(entries) > 0 {
			segs = append(segs, seg{entries: entries})
			remaining -= len(entries)
		}
		if remaining > 0 && i > 0 && m.gap > 0 {
			gapLines := m.gap
			if gapLines > remaining {
				gapLines = remaining
			}
			gapEntries := make([]entry, gapLines)
			for j := range gapEntries {
				gapEntries[j] = entry{itemIdx: -1}
			}
			segs = append(segs, seg{entries: gapEntries})
			remaining -= gapLines
		}
	}

	// Assemble top-down: padding first, then segs in reverse.
	pos := 0
	if remaining > 0 {
		pos += remaining
	}
	for i := len(segs) - 1; i >= 0; i-- {
		for _, e := range segs[i].entries {
			if pos < m.height {
				layout[pos] = e
			}
			pos++
		}
	}

	if y < len(layout) {
		return layout[y].itemIdx
	}
	return -1
}

// VisibleItemIndices returns the indices of items currently in the viewport.
func (m Model) VisibleItemIndices() []int {
	if m.height <= 0 || len(m.items) == 0 {
		return nil
	}
	seen := make(map[int]bool)
	var result []int
	for y := 0; y < m.height; y++ {
		idx := m.ItemIndexAtPosition(y)
		if idx >= 0 && !seen[idx] {
			seen[idx] = true
			result = append(result, idx)
		}
	}
	return result
}

// ---------------------------------------------------------------------------
// Cache management
// ---------------------------------------------------------------------------

// InvalidateCache forces all cached renders to be discarded.
func (m *Model) InvalidateCache() {
	m.cache = make(map[string]cachedRender)
}

// InvalidateItem discards the cached render for the item with the given id.
func (m *Model) InvalidateItem(id string) {
	delete(m.cache, id)
}

// ---------------------------------------------------------------------------
// Update (bubbletea)
// ---------------------------------------------------------------------------

// Update handles mouse wheel events for scrolling. Callers forward whichever
// tea.Msg events they want the list to respond to.
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.MouseWheelMsg:
		switch msg.Button {
		case tea.MouseWheelUp:
			m.ScrollUp(3)
		case tea.MouseWheelDown:
			m.ScrollDown(3)
		}
	case tea.MouseClickMsg:
		// Forward click events to MouseClickable items.
		idx := m.ItemIndexAtPosition(msg.Y)
		if idx >= 0 && idx < len(m.items) {
			if mc, ok := m.items[idx].(MouseClickable); ok {
				return m, mc.HandleClick(msg.X, msg.Y)
			}
		}
	}
	return m, nil
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

// View renders only the items visible within the current viewport and returns
// the resulting string. Items outside the viewport are skipped entirely.
func (m Model) View() string {
	if m.height <= 0 || m.width <= 0 {
		return ""
	}
	if len(m.items) == 0 {
		return ""
	}

	if m.reverse {
		return m.viewReverse()
	}
	return m.viewForward()
}

// ---------------------------------------------------------------------------
// viewForward — standard top-down rendering
// ---------------------------------------------------------------------------

func (m Model) viewForward() string {
	// Collect rendered lines starting at offsetIdx:offsetLine, stopping when
	// the viewport is full.
	var lines []string
	remaining := m.height

	for i := m.offsetIdx; i < len(m.items) && remaining > 0; i++ {
		rendered := m.renderItem(m.items[i])
		itemLines := splitLines(rendered)

		startLine := 0
		if i == m.offsetIdx {
			startLine = m.offsetLine
			if startLine > len(itemLines) {
				startLine = len(itemLines)
			}
		}

		visible := itemLines[startLine:]
		if len(visible) > remaining {
			visible = visible[:remaining]
		}
		lines = append(lines, visible...)
		remaining -= len(visible)

		// Gap between items (not after the last item).
		if remaining > 0 && i < len(m.items)-1 && m.gap > 0 {
			gapLines := m.gap
			if gapLines > remaining {
				gapLines = remaining
			}
			for j := 0; j < gapLines; j++ {
				lines = append(lines, "")
			}
			remaining -= gapLines
		}
	}

	return strings.Join(lines, "\n")
}

// ---------------------------------------------------------------------------
// viewReverse — bottom-anchored rendering (chat mode)
// ---------------------------------------------------------------------------

// viewReverse renders items from the bottom of the viewport upward. The last
// item in m.items is at the bottom; earlier items fill upward.
//
// offsetIdx/offsetLine in reverse mode mean: how far from the bottom the
// anchor item is pushed. offsetIdx=0, offsetLine=0 means fully scrolled to
// bottom. As the user scrolls up, offsetIdx/offsetLine increase, shifting
// the visible window toward earlier items.
func (m Model) viewReverse() string {
	// We build a slice of rendered item-line-slices in reverse order
	// (newest first / bottom first), then flip them to produce top-down output.
	//
	// Strategy:
	//  1. Walk items from (last - offsetIdx) backward.
	//  2. First item may have offsetLine lines clipped from its bottom.
	//  3. Accumulate until we have `height` lines.
	//  4. Reverse the accumulated segments and join.

	type segment struct {
		lines []string
	}
	var segs []segment
	remaining := m.height

	// The anchor item index (the bottommost potentially-visible item).
	anchorIdx := len(m.items) - 1 - m.offsetIdx
	if anchorIdx < 0 {
		anchorIdx = 0
	}

	for i := anchorIdx; i >= 0 && remaining > 0; i-- {
		rendered := m.renderItem(m.items[i])
		itemLines := splitLines(rendered)

		endLine := len(itemLines) // exclusive upper bound of visible lines
		if i == anchorIdx && m.offsetLine > 0 {
			endLine -= m.offsetLine
			if endLine < 0 {
				endLine = 0
			}
		}

		visibleLines := itemLines[:endLine]
		if len(visibleLines) > remaining {
			// Trim from the top (earlier lines of this item are off-screen).
			visibleLines = visibleLines[len(visibleLines)-remaining:]
		}

		if len(visibleLines) > 0 {
			segs = append(segs, segment{lines: visibleLines})
			remaining -= len(visibleLines)
		}

		// Gap between items (only when there is a preceding item and room left).
		if remaining > 0 && i > 0 && m.gap > 0 {
			gapLines := m.gap
			if gapLines > remaining {
				gapLines = remaining
			}
			gapSeg := make([]string, gapLines)
			segs = append(segs, segment{lines: gapSeg})
			remaining -= gapLines
		}
	}

	// segs[0] = bottom segment, segs[last] = top segment — reverse them.
	// Then pad with empty lines at the top if content doesn't fill viewport.
	var allLines []string

	// Add top-padding when the content doesn't fill the full viewport.
	if remaining > 0 {
		for i := 0; i < remaining; i++ {
			allLines = append(allLines, "")
		}
	}

	for i := len(segs) - 1; i >= 0; i-- {
		allLines = append(allLines, segs[i].lines...)
	}

	return strings.Join(allLines, "\n")
}

// ---------------------------------------------------------------------------
// Internal scroll helpers — forward mode
// ---------------------------------------------------------------------------

// scrollForwardDown advances the scroll position by lines in forward mode.
func (m *Model) scrollForwardDown(lines int) {
	for lines > 0 && m.offsetIdx < len(m.items) {
		h := m.itemHeight(m.items[m.offsetIdx])
		linesInItem := h - m.offsetLine
		if lines < linesInItem {
			m.offsetLine += lines
			return
		}
		// Consume entire remainder of this item.
		lines -= linesInItem
		m.offsetIdx++
		m.offsetLine = 0
		// Consume gap lines.
		if m.offsetIdx < len(m.items) && m.gap > 0 {
			if lines < m.gap {
				// Gap partially consumed: gaps don't have sub-line offsets,
				// so round up to the next item.
				m.offsetLine = 0
				return
			}
			lines -= m.gap
		}
	}
}

// scrollForwardUp retracts the scroll position by lines in forward mode.
func (m *Model) scrollForwardUp(lines int) {
	for lines > 0 {
		if m.offsetLine > 0 {
			if lines <= m.offsetLine {
				m.offsetLine -= lines
				return
			}
			lines -= m.offsetLine
			m.offsetLine = 0
		}
		if m.offsetIdx == 0 {
			return
		}
		// Move back over the gap preceding the current item.
		if m.gap > 0 {
			if lines <= m.gap {
				// Land inside a gap: treat as top of the previous item.
				m.offsetIdx--
				m.offsetLine = 0
				return
			}
			lines -= m.gap
		}
		m.offsetIdx--
		h := m.itemHeight(m.items[m.offsetIdx])
		if lines < h {
			m.offsetLine = h - lines
			return
		}
		lines -= h
		m.offsetLine = 0
	}
}

// ---------------------------------------------------------------------------
// Internal scroll helpers — reverse mode
// ---------------------------------------------------------------------------

// scrollReverseDown scrolls toward the bottom (newer content) in reverse mode.
func (m *Model) scrollReverseDown(lines int) {
	for lines > 0 {
		if m.offsetLine > 0 {
			if lines <= m.offsetLine {
				m.offsetLine -= lines
				return
			}
			lines -= m.offsetLine
			m.offsetLine = 0
		}
		if m.offsetIdx == 0 {
			return
		}
		// Move to the next (newer) item.
		if m.gap > 0 {
			if lines <= m.gap {
				// Land in the gap — snap to the item.
				m.offsetIdx--
				m.offsetLine = 0
				return
			}
			lines -= m.gap
		}
		m.offsetIdx--
		anchorIdx := len(m.items) - 1 - m.offsetIdx
		if anchorIdx < 0 {
			m.offsetIdx = 0
			return
		}
		h := m.itemHeight(m.items[anchorIdx])
		if lines < h {
			m.offsetLine = h - lines
			return
		}
		lines -= h
		m.offsetLine = 0
	}
}

// scrollReverseUp scrolls toward the top (older content) in reverse mode.
func (m *Model) scrollReverseUp(lines int) {
	for lines > 0 && m.offsetIdx < len(m.items)-1 {
		anchorIdx := len(m.items) - 1 - m.offsetIdx
		if anchorIdx < 0 {
			return
		}
		h := m.itemHeight(m.items[anchorIdx])
		linesRemaining := h - m.offsetLine
		if lines < linesRemaining {
			m.offsetLine += lines
			return
		}
		lines -= linesRemaining
		m.offsetIdx++
		m.offsetLine = 0
		// Consume gap.
		if m.gap > 0 {
			if lines <= m.gap {
				return
			}
			lines -= m.gap
		}
	}
}

// ---------------------------------------------------------------------------
// computeTopForBottom — forward mode
// ---------------------------------------------------------------------------

// computeTopForBottom returns the (offsetIdx, offsetLine) pair that places
// the last item's last line at the bottom of the viewport in forward mode.
func (m Model) computeTopForBottom() (int, int) {
	if len(m.items) == 0 {
		return 0, 0
	}

	// Accumulate item heights from the bottom until we fill the viewport.
	remaining := m.height
	for i := len(m.items) - 1; i >= 0; i-- {
		h := m.itemHeight(m.items[i])
		if remaining <= 0 {
			// The entire viewport is filled; this item is completely off-screen.
			return i + 1, 0
		}
		remaining -= h
		if i > 0 && m.gap > 0 {
			remaining -= m.gap
		}
		if remaining <= 0 {
			// This item is partially visible at the top.
			// offsetLine = how many lines of it are hidden above the viewport.
			return i, -remaining // -remaining is the number of lines cut from top
		}
	}
	// All content fits without filling the viewport.
	return 0, 0
}

// ---------------------------------------------------------------------------
// clampScroll
// ---------------------------------------------------------------------------

// clampScroll ensures the scroll state is within valid bounds.
func (m *Model) clampScroll() {
	if len(m.items) == 0 {
		m.offsetIdx = 0
		m.offsetLine = 0
		return
	}

	if m.reverse {
		// offsetIdx must not exceed (len-1); offsetLine must not exceed
		// the anchor item's height.
		maxIdx := len(m.items) - 1
		if m.offsetIdx > maxIdx {
			m.offsetIdx = maxIdx
		}
		if m.offsetIdx < 0 {
			m.offsetIdx = 0
		}
		anchorIdx := len(m.items) - 1 - m.offsetIdx
		if anchorIdx >= 0 {
			h := m.itemHeight(m.items[anchorIdx])
			if m.offsetLine >= h {
				m.offsetLine = h - 1
			}
		}
		if m.offsetLine < 0 {
			m.offsetLine = 0
		}
		return
	}

	// Forward mode.
	if m.offsetIdx >= len(m.items) {
		m.offsetIdx = len(m.items) - 1
		m.offsetLine = 0
	}
	if m.offsetIdx < 0 {
		m.offsetIdx = 0
	}
	h := m.itemHeight(m.items[m.offsetIdx])
	if m.offsetLine >= h {
		m.offsetLine = h - 1
	}
	if m.offsetLine < 0 {
		m.offsetLine = 0
	}

	// If clamping puts us past the bottom, snap to the real bottom.
	bottomIdx, bottomLine := m.computeTopForBottom()
	if m.offsetIdx > bottomIdx || (m.offsetIdx == bottomIdx && m.offsetLine > bottomLine) {
		m.offsetIdx = bottomIdx
		m.offsetLine = bottomLine
	}
}

// ---------------------------------------------------------------------------
// Height helpers
// ---------------------------------------------------------------------------

// itemHeight returns the height of an item for the current width.
//
// It uses the cached render height when the cache entry is valid (same width
// and ContentVersion). Otherwise it delegates to item.Height() directly —
// intentionally not calling item.Render() here so that scroll arithmetic,
// recomputeTotal, clampScroll, and computeTopForBottom never pre-populate
// the render cache. The render cache is only written by renderItem, which is
// called exclusively from the View() path.
func (m Model) itemHeight(item Item) int {
	if m.width <= 0 {
		return 1
	}
	if cr, ok := m.cache[item.ID()]; ok {
		if cr.width == m.width && cr.version == item.ContentVersion() {
			return cr.height
		}
	}
	h := item.Height(m.width)
	if h <= 0 {
		h = 1
	}
	return h
}

// renderItem returns the cached or freshly rendered content for an item.
func (m Model) renderItem(item Item) string {
	if m.width <= 0 {
		return ""
	}
	id := item.ID()
	ver := item.ContentVersion()
	if cr, ok := m.cache[id]; ok {
		if cr.width == m.width && cr.version == ver {
			return cr.content
		}
	}
	rendered := item.Render(m.width)
	h := countLines(rendered)
	if h == 0 {
		h = 1
	}
	m.cache[id] = cachedRender{
		content: rendered,
		height:  h,
		width:   m.width,
		version: ver,
	}
	return rendered
}

// recomputeTotal recalculates m.totalHeight from scratch.
func (m *Model) recomputeTotal() {
	total := 0
	for i, item := range m.items {
		total += m.itemHeight(item)
		if i < len(m.items)-1 {
			total += m.gap
		}
	}
	m.totalHeight = total
}

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

// splitLines splits a rendered string into individual lines.
func splitLines(s string) []string {
	if s == "" {
		return []string{""}
	}
	return strings.Split(s, "\n")
}

// countLines counts the number of rendered lines in a string (number of \n + 1).
func countLines(s string) int {
	if s == "" {
		return 1
	}
	return strings.Count(s, "\n") + 1
}
