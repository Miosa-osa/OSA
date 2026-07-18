/// App states — 12-state machine with validated transitions
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppState {
    Connecting,
    Idle,
    Processing,
    PlanReview,
    ModelPicker,
    Palette,
    Permissions,
    Quit,
    Sessions,
    Onboarding,
    Survey,
    Recording,
    AgentsDashboard,
    Rewind,
    Status,
}

impl AppState {
    /// Check if transition is valid
    pub fn can_transition_to(&self, target: AppState) -> bool {
        use AppState::*;
        matches!(
            (self, target),
            // Connecting goes directly to Idle or Onboarding
            (Connecting, Idle)
                | (Connecting, Connecting)
                | (Connecting, Onboarding)
                // Idle can go to many states
                | (Idle, Processing)
                | (Idle, ModelPicker)
                | (Idle, Palette)
                | (Idle, Permissions)
                | (Idle, Survey)
                | (Idle, Quit)
                | (Idle, Sessions)
                | (Idle, Onboarding)
                | (Idle, Recording)
                | (Idle, AgentsDashboard)
                | (Idle, Rewind)
                | (Idle, Status)
                // Recording transitions
                | (Recording, Idle)
                // Processing transitions
                | (Processing, Idle)
                | (Processing, PlanReview)
                | (Processing, Permissions)
                | (Processing, Survey)
                | (Processing, Quit)
                | (Processing, AgentsDashboard)
                | (Processing, Rewind)
                | (Processing, Status)
                // Agents dashboard returns to whichever state opened it
                | (AgentsDashboard, Idle)
                | (AgentsDashboard, Processing)
                // Survey
                | (Survey, Processing)
                | (Survey, Idle)
                // PlanReview
                | (PlanReview, Processing)
                | (PlanReview, Idle)
                // Overlays return to previous state (simplified to Idle)
                | (ModelPicker, Idle)
                | (Palette, Idle)
                | (Palette, Processing)
                | (Permissions, Processing)
                | (Permissions, Idle)
                | (Quit, Idle)
                | (Sessions, Idle)
                | (Rewind, Idle)
                | (Rewind, Processing)
                | (Status, Idle)
                | (Status, Processing)
                | (Onboarding, Idle)
                // Emergency: any state can go to Connecting (reconnect)
                | (_, Connecting)
        )
    }

    pub fn is_overlay(&self) -> bool {
        matches!(
            self,
            AppState::Palette
                | AppState::Permissions
                | AppState::PlanReview
                | AppState::Quit
                | AppState::Sessions
                | AppState::ModelPicker
                | AppState::Survey
                | AppState::AgentsDashboard
                | AppState::Rewind
                | AppState::Status
        )
    }

    /// Full-screen states that replace the entire layout (no normal UI behind them).
    pub fn is_fullscreen(&self) -> bool {
        matches!(self, AppState::Connecting | AppState::Onboarding)
    }

    pub fn allows_input(&self) -> bool {
        matches!(self, AppState::Idle | AppState::Processing | AppState::Recording)
    }

    pub fn is_processing(&self) -> bool {
        matches!(self, AppState::Processing)
    }
}

impl std::fmt::Display for AppState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AppState::Connecting => write!(f, "Connecting"),
            AppState::Idle => write!(f, "Idle"),
            AppState::Processing => write!(f, "Processing"),
            AppState::PlanReview => write!(f, "Plan Review"),
            AppState::ModelPicker => write!(f, "Model Picker"),
            AppState::Palette => write!(f, "Command Palette"),
            AppState::Permissions => write!(f, "Permissions"),
            AppState::Quit => write!(f, "Quit"),
            AppState::Sessions => write!(f, "Sessions"),
            AppState::Onboarding => write!(f, "Onboarding"),
            AppState::Survey => write!(f, "Survey"),
            AppState::Recording => write!(f, "Recording"),
            AppState::AgentsDashboard => write!(f, "Agent Dashboard"),
            AppState::Rewind => write!(f, "Rewind"),
            AppState::Status => write!(f, "Status"),
        }
    }
}
