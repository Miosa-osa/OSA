package app

// State represents the current application state.
type State int

const (
	StateConnecting  State = iota // Waiting for backend health check
	StateBanner                   // Showing startup banner
	StateIdle                     // Ready for user input
	StateProcessing               // Waiting for agent response
	StatePlanReview               // Reviewing a plan (approve/reject/edit)
	StateModelPicker              // Browsing model list (arrow keys + enter)
	StatePalette                  // Command palette overlay (Ctrl+K)
)

func (s State) String() string {
	switch s {
	case StateConnecting:
		return "connecting"
	case StateBanner:
		return "banner"
	case StateIdle:
		return "idle"
	case StateProcessing:
		return "processing"
	case StatePlanReview:
		return "plan_review"
	case StateModelPicker:
		return "model_picker"
	case StatePalette:
		return "palette"
	default:
		return "unknown"
	}
}
