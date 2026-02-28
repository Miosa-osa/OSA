package activity

import (
	"math/rand"
)

// wittyPhrases are shown in the activity header while the agent works.
// Rotated every ~4 seconds. Keep them short enough for a terminal line.
var wittyPhrases = []string{
	// ── OSA / Signal Theory ──
	"Classifying signals…",
	"Filtering noise…",
	"Maximizing S/N ratio…",
	"Traversing the signal space…",
	"Resolving the 5-tuple…",
	"Encoding optimal intent…",
	"Applying Shannon constraints…",
	"Matching Ashby's requisite variety…",
	"Checking Beer's viable structure…",
	"Closing the Wiener feedback loop…",
	"Walking the path of least resistance…",
	"Calibrating signal weight…",

	// ── Elixir / BEAM ──
	"Spawning processes on the BEAM…",
	"Sending messages between GenServers…",
	"Pattern matching on your intent…",
	"Reducing over the possibilities…",
	"Supervising child processes…",
	"Hot-reloading a better answer…",
	"Let it crash… then recover gracefully…",
	"Pinning variables…",
	"Piping through the pipeline…",

	// ── Dev humor ──
	"Reticulating splines…",
	"Converting coffee into code…",
	"Trying to exit Vim…",
	"Looking for a misplaced semicolon…",
	"Rewriting in Rust for no particular reason…",
	"Searching for the correct USB orientation…",
	"Applying percussive maintenance…",
	"Resolving dependencies… and existential crises…",
	"Defragmenting memories… both RAM and personal…",
	"That's not a bug, it's an undocumented feature…",
	"Garbage collecting… be right back…",
	"Ensuring the magic smoke stays inside the wires…",
	"Compiling brilliance…",
	"Untangling neural nets…",
	"Polishing the algorithms…",
	"Brewing fresh bytes…",
	"Optimizing for ludicrous speed…",
	"Calibrating the flux capacitor…",
	"Constructing additional pylons…",
	"Herding digital cats…",
	"Engaging cognitive processors…",
	"Mining for more Dilithium crystals…",
	"Blowing on the cartridge…",
	"Pre-heating the servers…",
	"Dividing by zero… just kidding…",
	"Checking for syntax errors in the universe…",
	"Entangling quantum particles for a faster response…",

	// ── Pop culture ──
	"Don't panic…",
	"Following the white rabbit…",
	"Engaging the improbability drive…",
	"Finishing the Kessel Run in less than 12 parsecs…",
	"So say we all…",
	"The truth is in here… somewhere…",
	"Engage.",
	"Warp speed engaged…",
	"Pondering the orb…",
	"Channeling the Force…",
	"Is this the real life? Is this just fantasy?…",

	// ── Self-aware ──
	"Thinking harder than strictly necessary…",
	"Generating a response worthy of your patience…",
	"Almost there… probably…",
	"Letting the thoughts marinate…",
	"Warming up the AI hamsters…",
	"Our agents are working as fast as they can…",
	"Spinning up the hamster wheel…",
	"Just remembered where I put my keys…",
	"Asking the magic conch shell…",
	"Consulting the digital spirits…",
	"Summoning the cloud of wisdom…",
	"Buffering… because even AIs need a moment…",

	// ── Dev jokes ──
	"What do you call a fish with no eyes? A fsh…",
	"Why do programmers prefer dark mode? Light attracts bugs…",
	"Why did the developer go broke? Used up all their cache…",
}

// pickPhrase returns a random witty phrase, avoiding immediate repeats.
func pickPhrase(lastIndex int) (string, int) {
	if len(wittyPhrases) == 0 {
		return "Reasoning…", 0
	}
	idx := rand.Intn(len(wittyPhrases))
	// Avoid immediate repeat
	if idx == lastIndex && len(wittyPhrases) > 1 {
		idx = (idx + 1) % len(wittyPhrases)
	}
	return wittyPhrases[idx], idx
}
