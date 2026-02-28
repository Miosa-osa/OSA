package model

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
)

const (
	collapseThreshold = 5
	collapseShow      = 3
)

// AgentInfo holds live state for a single agent in the orchestrator swarm.
type AgentInfo struct {
	Name          string
	Role          string
	Model         string
	Status        string // "running" | "completed" | "failed"
	CurrentAction string
	ToolUses      int
	TokensUsed    int
}

// AgentsModel renders multi-agent progress with wave tracking.
// It is inactive until Start is called.
type AgentsModel struct {
	agents      map[string]*AgentInfo
	agentOrder  []string // insertion order for deterministic rendering
	currentWave int
	totalWaves  int
	active      bool
	expanded    bool
}

// NewAgents returns a zero-value AgentsModel.
func NewAgents() AgentsModel {
	return AgentsModel{
		agents: make(map[string]*AgentInfo),
	}
}

// Start activates the agents panel.
func (m *AgentsModel) Start() {
	m.active = true
}

// Stop deactivates the agents panel.
func (m *AgentsModel) Stop() {
	m.active = false
}

// IsActive reports whether the agents panel is currently visible.
func (m *AgentsModel) IsActive() bool {
	return m.active
}

// Reset clears all agent state and deactivates the panel.
func (m *AgentsModel) Reset() {
	m.agents = make(map[string]*AgentInfo)
	m.agentOrder = nil
	m.currentWave = 0
	m.totalWaves = 0
	m.active = false
	m.expanded = false
}

// Update handles orchestrator and UI messages.
func (m AgentsModel) Update(message tea.Msg) (AgentsModel, tea.Cmd) {
	switch ev := message.(type) {

	case msg.OrchestratorWaveStarted:
		m.currentWave = ev.WaveNumber
		m.totalWaves = ev.TotalWaves

	case msg.OrchestratorAgentStarted:
		if _, exists := m.agents[ev.AgentName]; !exists {
			m.agentOrder = append(m.agentOrder, ev.AgentName)
		}
		m.agents[ev.AgentName] = &AgentInfo{
			Name:   ev.AgentName,
			Role:   ev.Role,
			Model:  ev.Model,
			Status: "running",
		}

	case msg.OrchestratorAgentProgress:
		if agent, ok := m.agents[ev.AgentName]; ok {
			agent.CurrentAction = ev.CurrentAction
			agent.ToolUses = ev.ToolUses
			agent.TokensUsed = ev.TokensUsed
		}

	case msg.OrchestratorAgentCompleted:
		if agent, ok := m.agents[ev.AgentName]; ok {
			agent.Status = "completed"
			agent.ToolUses = ev.ToolUses
			agent.TokensUsed = ev.TokensUsed
			agent.CurrentAction = ""
		}

	case msg.OrchestratorAgentFailed:
		if agent, ok := m.agents[ev.AgentName]; ok {
			agent.Status = "failed"
			agent.ToolUses = ev.ToolUses
			agent.TokensUsed = ev.TokensUsed
			agent.CurrentAction = ""
		}

	case msg.OrchestratorTaskCompleted:
		m.Stop()

	case msg.ToggleExpand:
		m.expanded = !m.expanded
	}

	return m, nil
}

// View renders the agents panel. Returns an empty string when inactive.
func (m AgentsModel) View() string {
	if !m.active {
		return ""
	}

	var sb strings.Builder
	count := len(m.agentOrder)

	// Header: "Running N agents…" or "▶ Wave 2/4 — 5 agents"
	if m.totalWaves > 0 {
		sb.WriteString(style.WaveLabel.Render(
			fmt.Sprintf("  ▶ Wave %d/%d", m.currentWave, m.totalWaves),
		))
		sb.WriteString(style.AgentRole.Render(
			fmt.Sprintf(" — %d agent%s", count, pluralS(count)),
		))
	} else {
		sb.WriteString(style.Faint.Render(
			fmt.Sprintf("  Running %d agent%s…", count, pluralS(count)),
		))
	}
	if !m.expanded && count > collapseThreshold {
		sb.WriteString(style.Hint.Render(" (ctrl+o to expand)"))
	}
	sb.WriteByte('\n')

	// Determine which agents to display.
	visible := m.agentOrder
	truncated := 0
	if !m.expanded && count > collapseThreshold {
		visible = m.agentOrder[:collapseShow]
		truncated = count - collapseShow
	}

	last := len(visible) - 1
	for i, name := range visible {
		agent, ok := m.agents[name]
		if !ok {
			continue
		}

		isLast := (i == last) && truncated == 0

		var branch, continuation string
		if isLast {
			branch = "   └─ "
			continuation = "      "
		} else {
			branch = "   ├─ "
			continuation = "   │  "
		}

		// Agent line: ├─ ⏺ researcher (backend) · 14 tool uses · 70.8k tokens
		sb.WriteString(renderAgentLine(branch, agent))
		sb.WriteByte('\n')

		// Sub-status with ⎿ connector
		subStatus := agentSubStatus(agent)
		if subStatus != "" {
			sb.WriteString(continuation)
			sb.WriteString(style.Connector.Render("⎿"))
			sb.WriteString("  ")
			sb.WriteString(subStatus)
			sb.WriteByte('\n')
		}
	}

	// Collapse hint.
	if truncated > 0 {
		sb.WriteString(style.Hint.Render(
			fmt.Sprintf("   └─ +%d more agent%s (ctrl+o to expand)", truncated, pluralS(truncated)),
		))
		sb.WriteByte('\n')
	}

	return strings.TrimRight(sb.String(), "\n")
}

// renderAgentLine builds one agent row with status prefix, e.g.:
//
//	├─ ⏺ researcher (backend) · 14 tool uses · 70.8k tokens
func renderAgentLine(branch string, agent *AgentInfo) string {
	var sb strings.Builder

	sb.WriteString(style.AgentRole.Render(branch))

	// Status prefix
	switch agent.Status {
	case "completed":
		sb.WriteString(style.PrefixDone.Render("✓ "))
	case "failed":
		sb.WriteString(style.ErrorText.Render("✘ "))
	default:
		sb.WriteString(style.PrefixActive.Render("⏺ "))
	}

	sb.WriteString(style.AgentName.Render(agent.Name))

	// Show role in parentheses if available
	if agent.Role != "" {
		sb.WriteString(style.AgentRole.Render(fmt.Sprintf(" (%s)", agent.Role)))
	}

	sb.WriteString(style.AgentRole.Render(
		fmt.Sprintf(" · %d tool uses · %s tokens", agent.ToolUses, formatTokens(agent.TokensUsed)),
	))

	return sb.String()
}

// agentSubStatus returns the contextual sub-status for an agent.
func agentSubStatus(agent *AgentInfo) string {
	switch agent.Status {
	case "completed":
		sub := "Done"
		if agent.Model != "" {
			sub += " · model: " + agent.Model
		}
		return style.Faint.Render(sub)
	case "failed":
		sub := "Failed"
		if agent.Model != "" {
			sub += " · model: " + agent.Model
		}
		return style.ErrorText.Render(sub)
	default:
		if agent.CurrentAction != "" {
			return style.Faint.Render(agent.CurrentAction)
		}
		return ""
	}
}

// formatTokens converts a raw token count to a compact display string.
// Examples: 800 → "800", 4200 → "4.2k", 91100 → "91.1k", 1200000 → "1.2M"
func formatTokens(n int) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.1fk", float64(n)/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

func pluralS(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
