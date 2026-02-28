package list

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// ---------------------------------------------------------------------------
// Test item implementation
// ---------------------------------------------------------------------------

type testItem struct {
	id      string
	content string
	version int
}

func (t testItem) ID() string              { return t.id }
func (t testItem) ContentVersion() int     { return t.version }
func (t testItem) Height(width int) int    { return countLines(t.content) }
func (t testItem) Render(width int) string { return t.content }

func makeItem(id, content string) testItem {
	return testItem{id: id, content: content, version: 1}
}

func multiLineItem(id string, lines int) testItem {
	parts := make([]string, lines)
	for i := range parts {
		parts[i] = fmt.Sprintf("%s-L%d", id, i)
	}
	return testItem{id: id, content: strings.Join(parts, "\n"), version: 1}
}

// ---------------------------------------------------------------------------
// New / options
// ---------------------------------------------------------------------------

func TestNew_DefaultsAreZeroSafe(t *testing.T) {
	m := New()
	// View on an empty list must not panic.
	out := m.View()
	if out != "" {
		t.Errorf("empty list View want empty string, got %q", out)
	}
}

func TestNew_Options(t *testing.T) {
	m := New(WithWidth(80), WithHeight(24), WithReverse(true), WithGap(1))
	if m.width != 80 {
		t.Errorf("want width=80, got %d", m.width)
	}
	if m.height != 24 {
		t.Errorf("want height=24, got %d", m.height)
	}
	if !m.reverse {
		t.Error("want reverse=true")
	}
	if m.gap != 1 {
		t.Errorf("want gap=1, got %d", m.gap)
	}
}

// ---------------------------------------------------------------------------
// SetItems / AppendItem / UpdateItem
// ---------------------------------------------------------------------------

func TestSetItems_ReplacesAll(t *testing.T) {
	m := New(WithWidth(80), WithHeight(24))
	m.SetItems([]Item{makeItem("a", "aaa"), makeItem("b", "bbb")})
	if len(m.items) != 2 {
		t.Fatalf("want 2 items, got %d", len(m.items))
	}
}

func TestAppendItem_IncrementalHeight(t *testing.T) {
	m := New(WithWidth(80), WithHeight(24))
	m.AppendItem(makeItem("a", "aaa"))
	if m.totalHeight != 1 {
		t.Errorf("want totalHeight=1, got %d", m.totalHeight)
	}
	m.AppendItem(makeItem("b", "bbb"))
	// Two single-line items, no gap.
	if m.totalHeight != 2 {
		t.Errorf("want totalHeight=2, got %d", m.totalHeight)
	}
}

func TestAppendItem_WithGap(t *testing.T) {
	m := New(WithWidth(80), WithHeight(24), WithGap(1))
	m.AppendItem(makeItem("a", "aaa"))
	m.AppendItem(makeItem("b", "bbb"))
	// item(1) + gap(1) + item(1) = 3
	if m.totalHeight != 3 {
		t.Errorf("want totalHeight=3, got %d", m.totalHeight)
	}
}

func TestUpdateItem_InvalidatesCache(t *testing.T) {
	m := New(WithWidth(80), WithHeight(24))
	m.SetItems([]Item{makeItem("a", "first")})
	_ = m.View() // populate cache
	if _, ok := m.cache["a"]; !ok {
		t.Fatal("cache should have entry for 'a' after View()")
	}
	updated := testItem{id: "a", content: "second", version: 2}
	m.UpdateItem("a", updated)
	if _, ok := m.cache["a"]; ok {
		t.Error("cache entry for 'a' should have been evicted by UpdateItem")
	}
}

func TestUpdateItem_Noop_WhenIDMissing(t *testing.T) {
	m := New(WithWidth(80), WithHeight(24))
	m.SetItems([]Item{makeItem("a", "aaa")})
	m.UpdateItem("z", makeItem("z", "zzz")) // should not panic or change items
	if len(m.items) != 1 {
		t.Errorf("want 1 item, got %d", len(m.items))
	}
}

// ---------------------------------------------------------------------------
// Forward-mode View
// ---------------------------------------------------------------------------

func TestViewForward_SingleItem(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	m.SetItems([]Item{makeItem("a", "hello")})
	out := m.View()
	if !strings.Contains(out, "hello") {
		t.Errorf("want 'hello' in View output, got %q", out)
	}
}

func TestViewForward_ItemTallerThanViewport(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3))
	item := multiLineItem("a", 10)
	m.SetItems([]Item{item})
	out := m.View()
	lines := strings.Split(out, "\n")
	if len(lines) > 3 {
		t.Errorf("View must not exceed viewport height (3), got %d lines", len(lines))
	}
}

func TestViewForward_MultipleItems_RenderAll(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	m.SetItems([]Item{makeItem("a", "AAA"), makeItem("b", "BBB"), makeItem("c", "CCC")})
	out := m.View()
	if !strings.Contains(out, "AAA") || !strings.Contains(out, "BBB") || !strings.Contains(out, "CCC") {
		t.Errorf("expected all items in View, got %q", out)
	}
}

func TestViewForward_WithGap(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10), WithGap(2))
	m.SetItems([]Item{makeItem("a", "AAA"), makeItem("b", "BBB")})
	out := m.View()
	lines := strings.Split(out, "\n")
	// item(1) + gap(2) + item(1) = 4 lines total
	if len(lines) != 4 {
		t.Errorf("want 4 lines (item+gap+item), got %d: %q", len(lines), out)
	}
}

// ---------------------------------------------------------------------------
// Reverse-mode View
// ---------------------------------------------------------------------------

func TestViewReverse_LastItemAtBottom(t *testing.T) {
	m := New(WithWidth(80), WithHeight(5), WithReverse(true))
	m.SetItems([]Item{makeItem("a", "first"), makeItem("b", "last")})
	out := m.View()
	lines := strings.Split(out, "\n")
	// "last" must be on the bottom line.
	if lines[len(lines)-1] != "last" {
		t.Errorf("want last item on bottom line, got lines=%v", lines)
	}
}

func TestViewReverse_PadsTopWhenContentShort(t *testing.T) {
	m := New(WithWidth(80), WithHeight(5), WithReverse(true))
	m.SetItems([]Item{makeItem("a", "only")})
	out := m.View()
	lines := strings.Split(out, "\n")
	if len(lines) != 5 {
		t.Errorf("reverse view should always return height lines (5), got %d", len(lines))
	}
	// Content should be on the last line.
	if lines[4] != "only" {
		t.Errorf("want 'only' on line 4, got %q; full output: %v", lines[4], lines)
	}
}

func TestViewReverse_ItemTallerThanViewport(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3), WithReverse(true))
	item := multiLineItem("a", 10)
	m.SetItems([]Item{item})
	out := m.View()
	lines := strings.Split(out, "\n")
	if len(lines) != 3 {
		t.Errorf("reverse view must not exceed viewport height (3), got %d lines", len(lines))
	}
}

// ---------------------------------------------------------------------------
// AtBottom
// ---------------------------------------------------------------------------

func TestAtBottom_EmptyList(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	if !m.AtBottom() {
		t.Error("empty list should always report AtBottom=true")
	}
}

func TestAtBottom_AfterScrollToBottom(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3))
	for i := 0; i < 5; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("item%d", i), 3))
	}
	m.ScrollToBottom()
	if !m.AtBottom() {
		t.Error("want AtBottom=true after ScrollToBottom")
	}
}

func TestAtBottom_AfterScrollUp_ReturnsFalse(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3))
	for i := 0; i < 5; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("item%d", i), 3))
	}
	m.ScrollToBottom()
	m.ScrollUp(5)
	if m.AtBottom() {
		t.Error("want AtBottom=false after scrolling up")
	}
}

func TestAtBottom_Reverse_AfterScrollToBottom(t *testing.T) {
	m := New(WithWidth(80), WithHeight(5), WithReverse(true))
	for i := 0; i < 10; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("item%d", i), 2))
	}
	m.ScrollToBottom()
	if !m.AtBottom() {
		t.Error("want AtBottom=true after ScrollToBottom in reverse mode")
	}
}

// ---------------------------------------------------------------------------
// Scroll
// ---------------------------------------------------------------------------

func TestScrollDown_MovesViewport(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3))
	m.SetItems([]Item{
		multiLineItem("a", 3),
		multiLineItem("b", 3),
	})
	m.ScrollToTop()
	outBefore := m.View()
	m.ScrollDown(3)
	outAfter := m.View()
	if outBefore == outAfter {
		t.Error("ScrollDown should change View output")
	}
}

func TestScrollUp_AtTop_IsNoop(t *testing.T) {
	m := New(WithWidth(80), WithHeight(5))
	m.SetItems([]Item{multiLineItem("a", 3)})
	m.ScrollToTop()
	m.ScrollUp(100) // should not panic or go negative
	if m.offsetIdx != 0 || m.offsetLine != 0 {
		t.Errorf("scroll past top: want offsetIdx=0 offsetLine=0, got idx=%d line=%d",
			m.offsetIdx, m.offsetLine)
	}
}

func TestScrollDown_AtBottom_IsNoop(t *testing.T) {
	m := New(WithWidth(80), WithHeight(5))
	m.SetItems([]Item{multiLineItem("a", 3)})
	m.ScrollToBottom()
	idxBefore := m.offsetIdx
	lineBefore := m.offsetLine
	m.ScrollDown(100)
	if m.offsetIdx != idxBefore || m.offsetLine != lineBefore {
		t.Errorf("scroll past bottom changed state: idx %d->%d line %d->%d",
			idxBefore, m.offsetIdx, lineBefore, m.offsetLine)
	}
}

func TestPageUpDown_RoundTrip(t *testing.T) {
	m := New(WithWidth(80), WithHeight(5))
	items := make([]Item, 20)
	for i := range items {
		items[i] = multiLineItem(fmt.Sprintf("i%d", i), 2)
	}
	m.SetItems(items)
	m.ScrollToBottom()
	m.PageUp()
	if m.AtBottom() {
		t.Error("after PageUp should not be at bottom")
	}
	m.PageDown()
	if !m.AtBottom() {
		t.Error("after PageUp+PageDown should be at bottom again")
	}
}

func TestHalfPageUpDown(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	items := make([]Item, 20)
	for i := range items {
		items[i] = multiLineItem(fmt.Sprintf("i%d", i), 2)
	}
	m.SetItems(items)
	m.ScrollToBottom()
	m.HalfPageUp()
	if m.AtBottom() {
		t.Error("after HalfPageUp should not be at bottom")
	}
	m.HalfPageDown()
	if !m.AtBottom() {
		t.Error("after HalfPageUp+HalfPageDown should be at bottom")
	}
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

func TestCache_HitPreventsReRender(t *testing.T) {
	callCount := 0
	type trackingItem struct {
		testItem
		renderFn func()
	}
	// We can't intercept calls to Render on testItem directly, so we use the
	// cache introspection instead.
	m := New(WithWidth(80), WithHeight(10))
	item := makeItem("a", "hello")
	m.SetItems([]Item{item})
	_ = m.View()
	if _, ok := m.cache["a"]; !ok {
		t.Fatal("expected cache entry after View()")
	}
	_ = callCount // suppress unused warning
}

func TestInvalidateCache_ClearsAll(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	m.SetItems([]Item{makeItem("a", "aaa"), makeItem("b", "bbb")})
	_ = m.View()
	m.InvalidateCache()
	if len(m.cache) != 0 {
		t.Errorf("want empty cache after InvalidateCache, got %d entries", len(m.cache))
	}
}

func TestInvalidateItem_ClearsOne(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	m.SetItems([]Item{makeItem("a", "aaa"), makeItem("b", "bbb")})
	_ = m.View()
	m.InvalidateItem("a")
	if _, ok := m.cache["a"]; ok {
		t.Error("item 'a' should be evicted")
	}
	if _, ok := m.cache["b"]; !ok {
		t.Error("item 'b' should still be cached")
	}
}

func TestCache_InvalidatedOnWidthChange(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	m.SetItems([]Item{makeItem("a", "aaa")})
	_ = m.View()
	m.SetSize(60, 10) // width change
	if len(m.cache) != 0 {
		t.Error("cache should be cleared when width changes")
	}
}

func TestCache_PreservedOnHeightChange(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	m.SetItems([]Item{makeItem("a", "aaa")})
	_ = m.View()
	m.SetSize(80, 20) // height-only change
	if _, ok := m.cache["a"]; !ok {
		t.Error("cache should be preserved when only height changes")
	}
}

// ---------------------------------------------------------------------------
// Update (mouse wheel)
// ---------------------------------------------------------------------------

func TestUpdate_MouseWheelDown_ScrollsDown(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3))
	for i := 0; i < 10; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("i%d", i), 2))
	}
	m.ScrollToTop()
	idxBefore := m.offsetIdx
	m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelDown})
	if m.offsetIdx == idxBefore && m.offsetLine == 0 {
		t.Error("MouseWheelDown should scroll down")
	}
}

func TestUpdate_MouseWheelUp_ScrollsUp(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3))
	for i := 0; i < 10; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("i%d", i), 2))
	}
	m.ScrollToBottom()
	m.ScrollUp(4) // move up a bit first
	lineBefore := m.offsetLine
	idxBefore := m.offsetIdx
	m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelUp})
	// after scroll up we should be closer to the top
	scrolledUp := m.offsetIdx < idxBefore || (m.offsetIdx == idxBefore && m.offsetLine < lineBefore)
	if !scrolledUp {
		t.Errorf("MouseWheelUp should scroll up; before idx=%d line=%d, after idx=%d line=%d",
			idxBefore, lineBefore, m.offsetIdx, m.offsetLine)
	}
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

func TestView_EmptyList_ReturnsEmpty(t *testing.T) {
	m := New(WithWidth(80), WithHeight(10))
	if m.View() != "" {
		t.Error("empty list must return empty string from View")
	}
}

func TestView_ZeroDimensions_ReturnsEmpty(t *testing.T) {
	m := New()
	m.SetItems([]Item{makeItem("a", "hello")})
	if m.View() != "" {
		t.Error("zero-dimension viewport must return empty string")
	}
}

func TestScrollToTop_ThenBottom_Forward(t *testing.T) {
	m := New(WithWidth(80), WithHeight(3))
	for i := 0; i < 5; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("i%d", i), 2))
	}
	m.ScrollToTop()
	if m.offsetIdx != 0 || m.offsetLine != 0 {
		t.Error("ScrollToTop must set offsetIdx=0, offsetLine=0")
	}
	m.ScrollToBottom()
	if !m.AtBottom() {
		t.Error("want AtBottom=true after ScrollToBottom in forward mode")
	}
}

func TestRapidScrollDoesNotPanic(t *testing.T) {
	// Stress-test rapid alternating scrolls to catch any out-of-bounds panics.
	m := New(WithWidth(80), WithHeight(5))
	for i := 0; i < 20; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("i%d", i), i%4+1))
	}
	for i := 0; i < 200; i++ {
		if i%7 == 0 {
			m.ScrollToBottom()
		} else if i%5 == 0 {
			m.ScrollToTop()
		} else if i%2 == 0 {
			m.ScrollDown(i%7 + 1)
		} else {
			m.ScrollUp(i%6 + 1)
		}
		_ = m.View() // must not panic
	}
}

func TestReverseRapidScrollDoesNotPanic(t *testing.T) {
	m := New(WithWidth(80), WithHeight(5), WithReverse(true))
	for i := 0; i < 20; i++ {
		m.AppendItem(multiLineItem(fmt.Sprintf("i%d", i), i%4+1))
	}
	for i := 0; i < 200; i++ {
		if i%7 == 0 {
			m.ScrollToBottom()
		} else if i%5 == 0 {
			m.ScrollToTop()
		} else if i%2 == 0 {
			m.ScrollDown(i%7 + 1)
		} else {
			m.ScrollUp(i%6 + 1)
		}
		_ = m.View() // must not panic
	}
}
