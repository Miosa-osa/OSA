package dialog

// PermissionDecision carries the user's response to a tool permission request.
type PermissionDecision struct {
	ToolCallID string
	Decision   string // "allow", "allow_session", "deny"
}

// SessionAction carries session management actions emitted by SessionsModel.
type SessionAction struct {
	Action    string // "switch", "rename", "delete", "create"
	SessionID string
	NewName   string // populated for "rename" actions
}

// ModelChoice carries model selection from ModelsModel.
type ModelChoice struct {
	Provider string
	Model    string
}

// ModelCancel is sent when the models dialog is dismissed without selecting.
type ModelCancel struct{}

// QuitConfirmed signals the user confirmed the quit prompt.
type QuitConfirmed struct{}

// QuitCancelled signals the user cancelled the quit prompt.
type QuitCancelled struct{}

// FilePickerResult carries the selected file path from FilePickerModel.
type FilePickerResult struct {
	Path string
}

// FilePickerCancel signals that the file picker was dismissed.
type FilePickerCancel struct{}

// OnboardingDone is emitted when the onboarding wizard completes.
type OnboardingDone struct {
	Provider    string
	Model       string
	APIKey      string
	EnvVar      string
	AgentName   string
	UserName    string
	UserContext string
	Machines    map[string]bool
	Channels    []string
	OSTemplate  map[string]string // nil if blank, {name, path} if selected
}
