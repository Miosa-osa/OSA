package list

import (
	"strings"

	tea "charm.land/bubbletea/v2"
)

// ---------------------------------------------------------------------------
// FilterableList
// ---------------------------------------------------------------------------

// filteredItem pairs an Item with its fuzzy-match score and character positions.
type filteredItem struct {
	item    Item
	score   int
	indices []int // matched character positions within the item ID/label
}

// FilterableList wraps a List with fuzzy filtering support. When the filter
// string is empty, all items are shown in original order. When non-empty,
// only items whose rendered ID contains the filter (case-insensitive substring
// match) are shown, with matched character positions forwarded to any
// MatchSettable implementations.
type FilterableList struct {
	list     Model
	allItems []Item
	filter   string
	matches  []filteredItem
}

// NewFilterableList constructs a FilterableList with the given viewport dimensions.
func NewFilterableList(width, height int) FilterableList {
	return FilterableList{
		list: New(WithWidth(width), WithHeight(height)),
	}
}

// SetItems replaces the full item set and re-applies the current filter.
func (fl *FilterableList) SetItems(items []Item) {
	fl.allItems = make([]Item, len(items))
	copy(fl.allItems, items)
	fl.applyFilter()
}

// SetFilter updates the filter string and re-computes visible items.
func (fl *FilterableList) SetFilter(filter string) {
	fl.filter = filter
	fl.applyFilter()
}

// Filter returns the current filter string.
func (fl FilterableList) Filter() string {
	return fl.filter
}

// FilteredItems returns the items currently passing the filter (in order).
func (fl FilterableList) FilteredItems() []Item {
	if fl.filter == "" {
		result := make([]Item, len(fl.allItems))
		copy(result, fl.allItems)
		return result
	}
	result := make([]Item, len(fl.matches))
	for i, m := range fl.matches {
		result[i] = m.item
	}
	return result
}

// SelectedItem returns the item currently at the top of the visible list
// (index 0 of the filtered set). Returns nil if the list is empty.
func (fl FilterableList) SelectedItem() Item {
	items := fl.FilteredItems()
	if len(items) == 0 {
		return nil
	}
	// The first visible item corresponds to the current scroll top.
	visible := fl.list.VisibleItemIndices()
	if len(visible) > 0 && visible[0] < len(items) {
		return items[visible[0]]
	}
	return items[0]
}

// SetSize updates the viewport dimensions of the underlying list.
func (fl *FilterableList) SetSize(w, h int) {
	fl.list.SetSize(w, h)
}

// ScrollToBottom scrolls the underlying list to the bottom.
func (fl *FilterableList) ScrollToBottom() {
	fl.list.ScrollToBottom()
}

// ScrollToTop scrolls the underlying list to the top.
func (fl *FilterableList) ScrollToTop() {
	fl.list.ScrollToTop()
}

// Update forwards tea.Msg to the underlying list model.
func (fl FilterableList) Update(msg tea.Msg) (FilterableList, tea.Cmd) {
	var cmd tea.Cmd
	fl.list, cmd = fl.list.Update(msg)
	return fl, cmd
}

// View renders the filtered list.
func (fl FilterableList) View() string {
	return fl.list.View()
}

// ---------------------------------------------------------------------------
// Internal: filter application
// ---------------------------------------------------------------------------

// applyFilter rebuilds the matches slice and pushes the visible items into
// the underlying list model. Match positions are forwarded to MatchSettable
// items so they can highlight matched characters in their Render output.
func (fl *FilterableList) applyFilter() {
	if fl.filter == "" {
		// No filter — show all items, clear any stale match highlights.
		for _, item := range fl.allItems {
			if ms, ok := item.(MatchSettable); ok {
				ms.SetMatches(nil)
			}
		}
		fl.matches = nil
		fl.list.SetItems(fl.allItems)
		return
	}

	lower := strings.ToLower(fl.filter)
	fl.matches = fl.matches[:0]

	for _, item := range fl.allItems {
		id := strings.ToLower(item.ID())
		indices := substringIndices(id, lower)
		if indices == nil {
			// No match — clear any previous highlights.
			if ms, ok := item.(MatchSettable); ok {
				ms.SetMatches(nil)
			}
			continue
		}
		score := scoreMatch(id, lower, indices)
		if ms, ok := item.(MatchSettable); ok {
			ms.SetMatches(indices)
		}
		fl.matches = append(fl.matches, filteredItem{
			item:    item,
			score:   score,
			indices: indices,
		})
	}

	// Stable sort by score descending (higher = better match).
	sortFilteredItems(fl.matches)

	visible := make([]Item, len(fl.matches))
	for i, m := range fl.matches {
		visible[i] = m.item
	}
	fl.list.SetItems(visible)
}

// substringIndices returns the byte positions in s where the pattern p
// appears (first contiguous occurrence). Returns nil if not found.
// Uses case-insensitive matching (caller must lower-case both inputs).
func substringIndices(s, p string) []int {
	if p == "" {
		return []int{}
	}
	idx := strings.Index(s, p)
	if idx < 0 {
		return nil
	}
	positions := make([]int, len(p))
	for i := range p {
		positions[i] = idx + i
	}
	return positions
}

// scoreMatch assigns a quality score to a match. Higher is better.
//   - Prefix match (match starts at 0): +10
//   - Shorter string (less noise): +bonus
func scoreMatch(s, p string, indices []int) int {
	score := 100
	if len(indices) > 0 && indices[0] == 0 {
		score += 10 // prefix bonus
	}
	// Penalise longer strings (more noise).
	if len(s) > len(p) {
		score -= len(s) - len(p)
	}
	return score
}

// sortFilteredItems sorts matches by score descending using a simple insertion
// sort (lists are typically small).
func sortFilteredItems(items []filteredItem) {
	for i := 1; i < len(items); i++ {
		for j := i; j > 0 && items[j].score > items[j-1].score; j-- {
			items[j], items[j-1] = items[j-1], items[j]
		}
	}
}
