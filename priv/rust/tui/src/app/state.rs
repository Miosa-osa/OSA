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

// ── an affordance must be routed in the state that advertises it ────────────
//
// Two reports of "the arrow keys don't work", both at the moment the roster was
// on screen saying they do. `↓ to manage` and `← for agents` are shown whenever
// there are agent rows, and agents run during Processing — but both key arms
// lived only in `handle_idle_key`, so during a live turn neither key was ever
// routed. The transition table permitted both; nothing dispatched them.
#[cfg(test)]
mod processing_affordances {
    use super::AppState::*;

    #[test]
    fn processing_can_reach_both_agent_surfaces() {
        assert!(
            Processing.can_transition_to(AgentsDashboard),
            "`↓ to manage` is shown during Processing, so it must be reachable from it"
        );
        assert!(
            Processing.can_transition_to(FleetSelect),
            "`← for agents` is shown during Processing, so it must be reachable from it"
        );
    }

    #[test]
    fn both_surfaces_hand_a_running_turn_back() {
        // They return via `exit_overlay`, so closing one must land on the live
        // turn rather than dropping it to Idle.
        assert!(FleetSelect.can_transition_to(Processing));
        assert!(AgentsDashboard.can_transition_to(Processing));
    }

    #[test]
    fn the_processing_handler_routes_both_keys() {
        // Source assertion, deliberately: the transition being legal is not the
        // same as a key reaching it, and that gap is exactly what shipped.
        let src = include_str!("update.rs");

        let handler = src
            .split("fn handle_processing_key")
            .nth(1)
            .expect("handle_processing_key exists");
        // Bound the search to this handler, not the whole file.
        let handler = &handler[..handler.len().min(4000)];

        assert!(
            handler.contains("KeyCode::Down") && handler.contains("open_agents_dashboard"),
            "Processing does not route ↓ to the dashboard"
        );
        assert!(
            handler.contains("KeyCode::Left") && handler.contains("enter_fleet_select"),
            "Processing does not route ← to the roster"
        );
    }
}

// ── no state may drop keys through a catch-all ──────────────────────────────
//
// `App::handle_key` matched on `self.state` and ended in `_ => false`. Exactly
// one variant fell into it — `Connecting` — and the consequence was that while
// the TUI was connecting to the backend EVERY key was silently discarded,
// Ctrl+C and Ctrl+D included. Connect is not instantaneous (twelve health
// retries against a backend that will not start), so that is up to a minute of
// a user pressing keys into a void with no way out, which is the same trapped-
// user class as a turn that cannot be interrupted.
//
// The catch-all is gone: the match is exhaustive, so the COMPILER now refuses a
// new `AppState` that nothing routes keys for. These tests pin that the arm
// cannot come back — an exhaustive match plus a re-added `_ => false` compiles
// perfectly happily and silently restores the defect.
#[cfg(test)]
mod key_routing_is_exhaustive {
    /// The body of `App::handle_key`, from the `match self.state {` that routes
    /// by state to the end of that match.
    fn state_match_body() -> &'static str {
        let src = include_str!("update.rs");
        let after = src
            .split("fn handle_key")
            .nth(1)
            .expect("App::handle_key exists");
        let body = after
            .split("match self.state {")
            .nth(1)
            .expect("handle_key dispatches on self.state");
        // Bounded to the dispatch match: the first `fn ` after it is the next
        // handler, and every arm of interest is above that.
        let end = body.find("\n    /// ").or_else(|| body.find("\n    fn "));
        &body[..end.unwrap_or(body.len())]
    }

    #[test]
    fn no_catch_all_arm_swallows_a_state() {
        let body = state_match_body();
        assert!(
            !body.contains("_ => false"),
            "`handle_key` has a catch-all arm again. Every AppState must route \
             keys deliberately; a state that falls through one drops EVERY key \
             the user presses, quit keys included, and shows nothing to say so. \
             That shipped as `Connecting`."
        );
    }

    #[test]
    fn connecting_routes_keys() {
        let body = state_match_body();
        assert!(
            body.contains("AppState::Connecting => self.handle_connecting_key"),
            "the connect splash must route keys — it is where a user who \
             cannot reach Idle is stuck"
        );
    }

    /// The two keys a trapped user reaches for. Asserted against the handler's
    /// source because there is no in-process seam that can drive `App` through
    /// a real `Connecting` — the PTY suite proves the behaviour end to end
    /// (`test_connecting_splash_does_not_trap_the_user`), and this is the cheap
    /// guard that fails first if the arm is gutted.
    #[test]
    fn the_connecting_handler_can_quit() {
        let src = include_str!("update.rs");
        let handler = src
            .split("fn handle_connecting_key")
            .nth(1)
            .expect("handle_connecting_key exists");
        let handler = &handler[..handler.len().min(1200)];
        assert!(
            handler.contains("KeyCode::Char('c')") && handler.contains("KeyCode::Char('d')"),
            "Ctrl+C and Ctrl+D must quit from the connect splash"
        );
        assert!(
            handler.contains("is_typed_text"),
            "typing during connect must be buffered into the composer, not dropped"
        );
        assert!(
            !handler.contains("KeyCode::Enter"),
            "Enter must NOT be routed while connecting — a buffered draft must \
             not be submittable, nor a `/command` executable, before the \
             session exists"
        );
    }
}

// ── a dialog state whose dialog is gone must not keep the keyboard ──────────
//
// The second half of the same audit. Fifteen states route every key into an
// `Option<Dialog>`, and most of them reach their close path only through an
// action that dialog RETURNS — so with the Option unset, no key at all leaves
// the state. Same trap as the missing `Connecting` arm, different route.
#[cfg(test)]
mod overlay_dialog_lost_is_complete {
    use super::AppState;

    /// Every state that `is_overlay()` claims, plus the two inline dialog
    /// states, checked against the escape hatch's list. A new dialog state that
    /// forgets `overlay_dialog_lost` is a new way to trap a user.
    #[test]
    fn every_option_backed_dialog_state_is_listed() {
        let src = include_str!("update.rs");
        let body = src
            .split("fn overlay_dialog_lost")
            .nth(1)
            .expect("overlay_dialog_lost exists");
        let body = &body[..body.len().min(2000)];

        // The states whose key handling is `self.<dialog>.as_mut()…` with no
        // fallback of their own. Named here so the list is reviewable next to
        // the enum rather than only inside the function.
        for state in [
            AppState::Trust,
            AppState::ThemePicker,
            AppState::Keybindings,
            AppState::Tools,
            AppState::PermissionsManager,
            AppState::Hooks,
            AppState::Mcp,
            AppState::Cost,
            AppState::Skills,
            AppState::Channels,
            AppState::Memory,
            AppState::Metrics,
            AppState::Tasks,
            AppState::Persona,
            AppState::Sandbox,
        ] {
            let arm = format!("AppState::{state:?} =>");
            assert!(
                body.contains(&arm),
                "{state:?} routes every key into an Option<Dialog> but is not \
                 listed in overlay_dialog_lost — with that Option unset there \
                 is no key, Esc or Ctrl+C included, that can leave the state"
            );
        }
    }

    /// The guard has to run BEFORE the per-state dispatch, or the trapped
    /// states swallow the key on the way past it.
    #[test]
    fn the_guard_runs_before_the_state_dispatch() {
        let src = include_str!("update.rs");
        let after = src.split("fn handle_key").nth(1).expect("handle_key exists");
        let guard = after.find("self.overlay_dialog_lost()");
        let dispatch = after.find("match self.state {");
        assert!(
            guard.is_some() && dispatch.is_some() && guard < dispatch,
            "the lost-dialog escape hatch must be checked before keys are \
             dispatched by state"
        );
    }
}
