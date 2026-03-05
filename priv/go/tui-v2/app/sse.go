package app

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/ui/chat"
	"github.com/miosa/osa-tui/ui/status"
	"github.com/miosa/osa-tui/ui/toast"
)

// -- SSE management ----------------------------------------------------------

func (m *Model) startSSE() tea.Cmd {
	if m.program == nil || m.sessionID == "" {
		return nil
	}
	m.sse = client.NewSSE(m.client.BaseURL, m.client.Token, m.sessionID)
	return m.sse.ListenCmd(m.program)
}

func (m *Model) closeSSE() {
	if m.sse != nil {
		m.sse.Close()
		m.sse = nil
	}
	m.sseReconnecting = false
}

// -- Orchestration ------------------------------------------------------------

func (m Model) handleOrchestrate(r msg.OrchestrateResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		m.chat.AddSystemError(fmt.Sprintf("Error: %v", r.Err))
		return m, m.input.Focus()
	}

	// Extract session_id from the 202 accepted response.
	if r.SessionID != "" && m.sessionID != r.SessionID {
		m.sessionID = r.SessionID
	}

	// Ensure SSE is connected — all real output arrives via SSE.
	if m.sse == nil && m.program != nil && m.sessionID != "" {
		if cmd := m.startSSE(); cmd != nil {
			return m, cmd
		}
	}
	return m, nil
}

func (m Model) handleClientAgentResponse(r client.AgentResponseEvent) (Model, tea.Cmd) {
	// Drop if cancelled.
	if m.cancelled {
		return m, nil
	}

	if r.ResponseType == "plan" {
		m.plan.SetPlan(r.Response)
		m.state = StatePlanReview
		return m, nil
	}

	wasBackground := (m.state == StateIdle)
	m.activity.Stop()
	m.chat.ClearProcessingView()
	m.status.SetActive(false)
	m.state = StateIdle
	focusCmd := m.input.Focus()

	if wasBackground {
		m.chat.AddSystemMessage("Background task completed")
		if len(m.bgTasks) > 0 {
			m.bgTasks = m.bgTasks[1:]
		}
		m.status.SetBackgroundCount(len(m.bgTasks))
	}

	sig := clientSignalToChat(r.Signal)
	m.chat.AddAgentMessage(
		truncateResponse(r.Response), sig,
		time.Since(m.processingStart).Milliseconds(),
		m.header.ModelName(),
	)
	if sig != nil {
		m.status.SetSignal(&status.Signal{Mode: sig.Mode, Genre: sig.Genre, Type: sig.Type})
	}
	// If the user scrolled up to read older messages, notify them that a new
	// response arrived without yanking them back to the bottom.
	if !m.chat.AtBottom() {
		m.toasts.Add("↓ Nova resposta — End para ir", toast.ToastInfo)
		return m, tea.Batch(focusCmd, m.tickCmd())
	}
	return m, focusCmd
}

// -- Orchestrate commands ----------------------------------------------------

func (m Model) orchestrate(inputText string) tea.Cmd {
	return m.orchestrateWithOpts(inputText, false)
}

func (m Model) orchestrateWithOpts(inputText string, skipPlan bool) tea.Cmd {
	c := m.client
	sid := m.sessionID
	return func() tea.Msg {
		resp, err := c.Orchestrate(client.OrchestrateRequest{
			Input:     inputText,
			SessionID: sid,
			SkipPlan:  skipPlan,
		})
		if err != nil {
			return msg.OrchestrateResult{Err: err}
		}
		return msg.OrchestrateResult{
			SessionID: resp.SessionID,
			Status:    resp.Status,
		}
	}
}

// -- Signal conversion helpers ------------------------------------------------

// clientSignalToChat converts a *client.Signal (from SSE) to a *chat.Signal.
func clientSignalToChat(s *client.Signal) *chat.Signal {
	if s == nil {
		return nil
	}
	return &chat.Signal{
		Mode:    s.Mode,
		Genre:   s.Genre,
		Type:    s.Type,
		Format:  s.Format,
		Weight:  s.Weight,
		Channel: s.Channel,
	}
}
