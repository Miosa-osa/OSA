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
    /// Inline `← for agents` roster focus (CC FleetView): the composer yields
    /// keyboard focus to the under-composer roster WITHOUT opening the
    /// full-screen dashboard. Renders inline (NOT an overlay / fullscreen state).
    FleetSelect,
    Rewind,
    Status,
    ThemePicker,
    Keybindings,
    Tools,
    ContextBreakdown,
    Trust,
    PermissionsManager,
    Hooks,
    Mcp,
    Cost,
    Skills,
    Channels,
    Memory,
    Persona,
    Sandbox,
    Metrics,
    Tasks,
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
                | (Idle, FleetSelect)
                | (FleetSelect, Idle)
                | (FleetSelect, Processing)
                | (Idle, Rewind)
                | (Idle, Status)
                | (Idle, ThemePicker)
                | (Idle, Keybindings)
                | (Idle, Tools)
                | (Idle, ContextBreakdown)
                | (Idle, Trust)
                | (Idle, PermissionsManager)
                | (Idle, Hooks)
                | (Idle, Mcp)
                | (Idle, Cost)
                | (Idle, Skills)
                | (Idle, Channels)
                | (Idle, Memory)
                | (Idle, Persona)
                | (Idle, Sandbox)
                | (Idle, Metrics)
                | (Idle, Tasks)
                // Recording transitions
                | (Recording, Idle)
                // Processing transitions
                | (Processing, Idle)
                | (Processing, PlanReview)
                | (Processing, Permissions)
                | (Processing, Survey)
                | (Processing, Quit)
                | (Processing, AgentsDashboard)
                // `← for agents` is only SHOWN while subagents are running,
                // which is always Processing. Without this edge the hint was
                // advertised in the one state where the key could not work.
                | (Processing, FleetSelect)
                | (Processing, Rewind)
                | (Processing, Status)
                | (Processing, ThemePicker)
                | (Processing, Keybindings)
                | (Processing, Tools)
                | (Processing, ContextBreakdown)
                | (Processing, Trust)
                | (Processing, PermissionsManager)
                | (Processing, Hooks)
                | (Processing, Mcp)
                | (Processing, Cost)
                | (Processing, Skills)
                | (Processing, Channels)
                | (Processing, Memory)
                | (Processing, Persona)
                | (Processing, Sandbox)
                | (Processing, Metrics)
                | (Processing, Tasks)
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
                | (ThemePicker, Idle)
                | (ThemePicker, Processing)
                | (Keybindings, Idle)
                | (Keybindings, Processing)
                | (Tools, Idle)
                | (Tools, Processing)
                | (ContextBreakdown, Idle)
                | (ContextBreakdown, Processing)
                | (Trust, Idle)
                | (Trust, Processing)
                | (PermissionsManager, Idle)
                | (PermissionsManager, Processing)
                | (Hooks, Idle)
                | (Hooks, Processing)
                | (Mcp, Idle)
                | (Mcp, Processing)
                | (Cost, Idle)
                | (Cost, Processing)
                | (Skills, Idle)
                | (Skills, Processing)
                | (Channels, Idle)
                | (Channels, Processing)
                | (Memory, Idle)
                | (Memory, Processing)
                | (Persona, Idle)
                | (Persona, Processing)
                | (Sandbox, Idle)
                | (Sandbox, Processing)
                | (Metrics, Idle)
                | (Metrics, Processing)
                | (Tasks, Idle)
                | (Tasks, Processing)
                | (Onboarding, Idle)
                // Emergency: any state can go to Connecting (reconnect)
                | (_, Connecting)
        )
    }

    pub fn is_overlay(&self) -> bool {
        matches!(
            self,
            AppState::Palette
                // PlanReview is intentionally NOT an overlay: like Permissions, it
                // renders INLINE in the stream band (see event_loop draw_inline /
                // desired_inline_height), not via the full-viewport overlay path.
                // Reserving the full viewport for it forced a viewport mode switch
                // — part of the mid-turn rebuild / re-anchor churn the fixed-height
                // inline cure removes.
                | AppState::Quit
                | AppState::Sessions
                | AppState::ModelPicker
                // Survey is intentionally NOT an overlay: like Permissions and
                // PlanReview it renders INLINE, in its own reserved band above
                // the composer (see event_loop `survey_slot` / `draw_inline`).
                // `ask_user` blocks the whole turn on the operator, and hiding
                // the conversation behind a full-screen modal is exactly what
                // the user cannot afford while deciding how to answer.
                | AppState::AgentsDashboard
                | AppState::Rewind
                | AppState::Status
                | AppState::ThemePicker
                | AppState::Keybindings
                | AppState::Tools
                | AppState::ContextBreakdown
                | AppState::Trust
                | AppState::PermissionsManager
                | AppState::Hooks
                | AppState::Mcp
                | AppState::Cost
                | AppState::Skills
                | AppState::Channels
                | AppState::Memory
                | AppState::Persona
                | AppState::Sandbox
                | AppState::Metrics
                | AppState::Tasks
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
            AppState::FleetSelect => write!(f, "Fleet Select"),
            AppState::Rewind => write!(f, "Rewind"),
            AppState::Status => write!(f, "Status"),
            AppState::ThemePicker => write!(f, "Theme"),
            AppState::Keybindings => write!(f, "Keybindings"),
            AppState::Tools => write!(f, "Tools"),
            AppState::ContextBreakdown => write!(f, "Context"),
            AppState::Trust => write!(f, "Trust"),
            AppState::PermissionsManager => write!(f, "Permissions"),
            AppState::Hooks => write!(f, "Hooks"),
            AppState::Mcp => write!(f, "MCP"),
            AppState::Cost => write!(f, "Cost"),
            AppState::Skills => write!(f, "Skills"),
            AppState::Channels => write!(f, "Channels"),
            AppState::Memory => write!(f, "Memory"),
            AppState::Persona => write!(f, "Persona"),
            AppState::Sandbox => write!(f, "Sandbox"),
            AppState::Metrics => write!(f, "Metrics"),
            AppState::Tasks => write!(f, "Tasks"),
        }
    }
}

#[cfg(test)]
mod fleet_select_transition_tests {
    use super::AppState::*;

    #[test]
    fn idle_can_enter_fleet_select() {
        // A — pressing `←` on an empty composer transitions Idle → FleetSelect
        // (enter_fleet_select guards on this). It must be an allowed edge.
        assert!(Idle.can_transition_to(FleetSelect));
    }

    #[test]
    fn fleet_select_returns_to_idle() {
        // C / F — Enter-on-main (detach) and →/Esc/q (exit) both drop back to Idle.
        assert!(FleetSelect.can_transition_to(Idle));
    }

    #[test]
    fn fleet_select_can_start_processing() {
        // Submitting from the composer after leaving FleetSelect must be reachable
        // (the roster mode never traps the user out of a turn).
        assert!(FleetSelect.can_transition_to(Processing));
    }

    #[test]
    fn a_running_turn_can_open_the_roster_it_advertises() {
        // The reported bug: `← for agents` is only SHOWN while subagents are
        // running, and subagents run during Processing — so the hint was
        // advertised in the exact state where the edge did not exist and the
        // key silently did nothing. The dashboard's `↓ to manage` edge was
        // there all along, which is why one hint worked and the other did not.
        assert!(
            Processing.can_transition_to(FleetSelect),
            "`← for agents` is shown during Processing, so it must be reachable from it"
        );
        assert!(Processing.can_transition_to(AgentsDashboard));
    }

    #[test]
    fn the_roster_can_hand_a_running_turn_back() {
        // Leaving the roster returns to whoever opened it via exit_overlay, so
        // a turn opened it must be able to receive it back.
        assert!(FleetSelect.can_transition_to(Processing));
    }

    #[test]
    fn fleet_select_does_not_open_full_dashboard_directly() {
        // A guarantees the inline roster is distinct from the full-screen
        // dashboard: there is no FleetSelect → AgentsDashboard edge.
        assert!(!FleetSelect.can_transition_to(AgentsDashboard));
    }
}
