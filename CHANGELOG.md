# Changelog

All notable changes to OSA are documented here. This file tracks
release-level changes; the day-to-day build ledger lives in
[`docs/BACKLOG.md`](docs/BACKLOG.md).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## [1.0.55] — displays as `v1.0.055`

### Fixed — resizing the terminal left permanent duplicate copies of the screen in scrollback

- **Every resize deposited a full snapshot of the screen into your scroll history.**
  Dragging a window edge through fifteen columns left fifteen stacked copies above
  the session, each one column narrower than the last — most visibly as a cascade of
  a table's horizontal rules, and it is the same mechanism behind the older reports
  of the composer duplicating down the screen. The copies were permanent and did not
  reflow. The cause: the resize path erased the screen with `ESC[2J`, which looks
  identical to an erase — blank screen, cursor home — but on the VTE family (GNOME
  Terminal and every other libvte embedder) is implemented by *scrolling* the screen
  into the scrollback buffer rather than wiping it. **The resize clear now homes the
  cursor and erases forward**, which clears the same ground without touching scroll
  history.

- **`/clear` handed one last screenful back to the history it had just emptied.** It
  purged the scroll history first and only then emitted the same `ESC[2J`, so the
  final visible screen was scrolled straight back into the buffer that was meant to
  be empty. The screen is now erased before the history is purged, so a `/clear`
  leaves nothing scrollable behind it.

- **Regaining focus now forces a repaint.** An outer layer can repaint OSA's pane
  with no terminal resize at all — tmux redrawing a pane, an nvim `:terminal`
  restoring a window, a multiplexer client re-attaching. Only changed cells are
  rewritten, so rows damaged that way stayed damaged until something else happened
  to move them; focus is regained on essentially every path that causes such damage,
  so it is now taken as the cue to repaint the live region. It repaints only that
  region and can never reach the transcript above it.

---

## [1.0.54] — displays as `v1.0.054`

### Fixed — on Google and Replicate, OSA stopped listening to itself mid-turn

- **A course correction OSA gave itself was filed as background reading instead of
  read as an instruction.** OSA steers itself while a turn is running — keep going,
  write the code, run the verification you promised, stop and check before claiming
  done — and each of those nudges is written to be the last thing the model reads.
  On Google and on Replicate, every such nudge was being lifted out of the
  conversation and folded into the system prompt, arriving as standing context from
  before the turn began rather than as a correction to what was just said. The model
  could therefore keep going in a direction it had already been told to abandon,
  finish a turn it had been told to continue, or skip a check it had been told to
  run. **Mid-turn steering now stays where it was put**, at the end of the
  conversation, so it lands as an instruction about what to do next.

- **Nothing reported this, which is why it lasted.** The same defect on the Claude
  models produced a hard error and was fixed in 1.0.50; here both providers accepted
  the malformed request happily and returned a perfectly ordinary answer, so the only
  visible symptom was an agent that seemed not to take direction. Instructions that
  genuinely belong to the system prompt — the ones present before the conversation
  starts — are still sent exactly as they were.

- **Tool calls are untouched.** Google requires the conversation to alternate
  speakers, so keeping a nudge in place can put two turns from the same side next to
  each other; those are now merged rather than dropped. The merge is limited to plain
  text, so a turn carrying a tool call or a tool result is passed through byte for
  byte and the tool round-trip behaves exactly as before.

## [1.0.53] — displays as `v1.0.053`

### Changed — you can read a reply while it is still being written

- **A long answer was unreadable until the turn ended.** The whole reply was held in
  a bounded live region at the bottom of the screen, so as soon as it grew past that
  region the beginning scrolled out of it — and tool activity rendering underneath
  pushed what was left further out of view. Nothing was in the terminal's own
  scrollback yet, so scrolling up did not bring it back either. The answer arrived in
  one lump at the end, which is exactly when you no longer need to read it slowly.
  **Finished blocks now land in scrollback as they finish**: a paragraph, a list, a
  code block or a table is committed the moment it is complete, so on a typical reply
  around nine tenths of the text is readable — and scrollable, and selectable — before
  the turn is over.

- **Only the still-unfinished tail stays in the live region.** The block currently
  being written keeps updating in place as before, so you still see text appear as it
  arrives; it is only the part that can no longer change that moves out. A code fence
  that has not closed counts as unfinished and stays in the tail, so a partial block
  is never committed in a state it will not end in.

- **Completion no longer replays the answer.** Because everything already settled was
  subtracted from what the end of a turn commits, finishing reveals only the last
  unfinished block rather than reprinting the message you have been reading all along
  — and when a reply happens to end exactly on a block boundary, it reveals nothing at
  all. Interrupting mid-reply closes the open block cleanly, so the interrupt notice
  reads as its own paragraph instead of running into the text above it.

### Changed — the multi-agent view now reads as a hierarchy

- **Five surfaces competed for attention at the same visual weight.** The roster, the
  tool feed, the plan checklist, their headers and their chrome were all drawn with
  roughly equal emphasis, so nothing on screen told you where to look and the one row
  that was actually live had to be found by reading. **There is now a three-tier
  ladder**: the accent belongs only to what is genuinely happening right now — the
  running tool, the active plan step — arguments, paths and durations sit a tier below
  in a muted tone, and every label, header and separator recedes into the quietest
  tier. Section titles are labels for the block beneath them, and are now styled that
  way rather than as content.

- **Paths are shown relative to your workspace, with shared prefixes elided.** A trail
  of file operations in one directory printed the same long absolute prefix on every
  row, spending most of the width on the part that never changed. The prefix is
  dropped when doing so hides nothing, so what remains is the part that distinguishes
  one row from the next.

- **Four rows of noise are gone without losing any information.** Batch labels that
  restated what the rows below them already said are suppressed, the "+N earlier"
  count is folded into the row it describes instead of occupying a row of its own, and
  the idle `main` entry — which was on screen permanently whether or not it was doing
  anything — is folded into the roster header. On a representative screen this is four
  fewer rows for the same content.

### Changed — the README and docs describe what OSA actually ships

- **The tool and provider lists were wrong in both directions.** The README advertised
  seven tools that are deliberately not registered — calling one could only ever
  produce a runtime error — and listed seven providers when twenty-seven are offered.
  Named OpenAI models that the picker excludes were presented as available. Two
  keyboard bindings were documented incorrectly, and forty-two slash commands were
  missing entirely. All of it now matches the shipped build.

- **Homebrew instructions have been removed rather than version-bumped.** The release
  tarball contains the Elixir backend only — no Rust TUI and no launcher — so a
  Homebrew install cannot attach a terminal interface at all, and a working formula
  was never one version bump away. `Formula/osa.rb` now carries a header comment
  recording why, so the gap is not mistaken for staleness and "fixed" by bumping a
  version.

## [1.0.52] — displays as `v1.0.052`

### Fixed — popups and notifications no longer paint over the conversation

- **A notification could cover the top of the reply you were reading.** Toasts were
  drawn on top of the first three rows of the streaming area, so for the four to six
  seconds one was on screen the beginning of the answer underneath it was simply
  gone — and it came back only once the toast expired. **Toasts now occupy a
  reserved region of their own**, above the reply rather than across it, so nothing
  a notification says costs you the text it lands on.

- **The `@`-mention list overwrote the rows above the composer.** Typing `@` drew the
  file and agent matches upward from the input line into rows that belonged to the
  hint line and whatever sat above it, wiping them for as long as the list was open.
  The same was true of the `/` command popup. **Both now sit in a region the layout
  reserves for them**, so opening either one moves the conversation up rather than
  drawing over it, and closing it gives the rows straight back.

- **The mention list now scrolls to follow your selection.** It always drew the first
  five matches while offering up to ten, so pressing ↓ past the fifth highlighted an
  entry that was not on screen — the list looked frozen while the selection kept
  moving invisibly. The visible window now follows the highlight, so the entry you
  are about to accept is always the one you can see.

- **Long paths and names are measured in screen columns.** Every row of these popups
  and of the toasts is now fitted by display width rather than by character count, so
  a mention of a path containing CJK text or an emoji can no longer overrun the width
  it was given and push a row out of shape.

## [1.0.51] — displays as `v1.0.051`

### Changed — tables now render as a proper bordered grid

- **A markdown table had no frame and no separation between its rows.** OSA already
  sized each column to its content, wrapped long values inside the cell rather than
  cutting them off, grew a row to the height of its tallest cell, and accented the
  header — everything except the thing that makes a table read as a table. There was
  no top or bottom border at all, and a single rule under the header was the only
  horizontal line in the whole table, so once a row wrapped onto a second line you
  could no longer tell where one row ended and the next began. **Tables are now drawn
  as a closed grid**: a full outer frame, and a rule between every pair of data rows,
  so wrapped cells stay visually bound to the row they belong to.

- **The grid follows your theme instead of picking its own colours.** The frame and
  rules use the theme's neutral border colour, the header its accent, and the
  "there's more" marker its muted tone — nothing is hardcoded, so a table reads
  correctly in every theme and in both light and dark terminals. The `▼` beneath a
  table now appears only when content was genuinely cut short, rather than as
  decoration, and it is centred under the table it belongs to.

- **Narrow terminals are unaffected.** The borders occupy the space between columns
  that was already reserved, so they cost no horizontal room, and the existing
  fallback ladder for widths too small to hold a table is unchanged.

### Fixed — a finished answer now settles cleanly instead of rendering twice

- **The streaming preview was stuck in a small fixed window no matter how tall your
  terminal was.** A reply in progress was shown through a permanent ten-row
  letterbox, so on any normal-sized screen most of the terminal sat empty while the
  answer scrolled past inside a slot a fraction of its size. **The preview now grows
  with the reply**, in steps, up to half the screen, and only ever grows within a
  turn — so it opens up for a long answer without flickering between sizes as the
  text arrives.

- **The working chrome outlived the answer it belonged to.** The spinner, the tool
  feed, the reasoning box and the agent roster all stayed on screen for several ticks
  after the reply had already landed, so the finished answer appeared with the
  machinery of producing it still running underneath — and the roster of active
  agents was never cleared on the normal completion path at all, only when a turn
  ended some other way. **Teardown now happens as the answer lands**: the chrome is
  retired, the viewport shrinks back and the finished reply is committed to
  scrollback together, in one pass, so a completed turn resolves once instead of
  visibly redrawing itself.

## [1.0.50] — displays as `v1.0.050`

### Fixed — turns died outright on the Claude 5 models

- **On Opus 5, Sonnet 5 and Fable 5, a turn could stop dead with
  `This model does not support assistant message prefill`.** OSA steers itself
  mid-turn — a short nudge to keep going, to write the code, to run the verification
  it promised — and those nudges are meant to be the last thing the model reads.
  Instead they were being lifted out of the conversation entirely and folded into the
  system prompt, which left the request ending on OSA's own words. The Claude 5 family
  removed the ability to end a request that way, so it was rejected before the model
  ever saw it. The steering was lost AND the turn was lost. **The nudges now stay in
  the conversation where they belong**, so they do the job they were written for, and
  a request can no longer end on the wrong speaker — checked at the last possible
  moment, keeping whatever had already been written rather than discarding it. Models
  that still accept the old shape are sent exactly what they were sent before.

- **The error told you to switch models, which could not possibly have helped.** The
  failure was in the shape of the request OSA built, so every model would have
  rejected it identically — the one suggestion offered was the one thing guaranteed
  not to work. **OSA now recognises a request it built wrong** and says so plainly,
  instead of blaming the model you chose.

### Fixed — "What's new" was empty after updating

- **A source-checkout update printed an empty release-notes section.** It was reading
  a changelog that stops at 0.9.0 and contains no 1.0 releases at all, so there was
  never anything to find. It now reads the changelog releases are actually written to.

## [1.0.49] — displays as `v1.0.049`

### Fixed — you no longer have to restart anything after an update

- **OSA kept a backend running from before the update and quietly served you the old
  build.** OSA's backend deliberately outlives the TUI so the next `osa` is instant —
  but that also means a backend started before an update keeps running the OLD code
  from memory while the new code sits on disk. The version you saw was the running
  one, so a successful update looked like it had never shipped, and the advice was to
  go and run `osa stop` first. That is not an instruction anyone should ever be given,
  and "daemon" is not a word anyone should have to learn. **OSA now detects a backend
  older than the build on disk and refreshes it itself, on launch, in one line** — not
  only after `osa update`, since a plain rebuild produces exactly the same skew.
  A backend that is genuinely mid-turn is left alone rather than having its work
  destroyed; it is refreshed once it is idle. If a stale backend refuses to stop, OSA
  now stops with a clear error instead of attaching to the wrong build.

### Fixed — the updater could not apply its own fixes

- **`osa update` fetched a fixed updater and then ran the old one anyway.** The
  updater IS the script being updated, and the shell has already read it into memory
  before the first byte is downloaded — so a run that collected a fix could not use
  it, and you needed a second, entirely separate update before it took effect. This
  was not hypothetical: the previous release pulled both the backend-restart fix and
  the release-notes fix, then skipped the restart and printed `[Unreleased]`, because
  the code doing the work was the pre-fix code. **The update now hands itself over to
  the version it just installed and finishes there**, so a fix applies on the run that
  delivers it. Nothing is downloaded twice, your local changes travel across the
  hand-off untouched, and handing over more than once is refused outright.

### Fixed — installed copies never received launcher updates at all

- **On the standard one-line install, `osa update` replaced the backend and the TUI
  but never the `osa` command itself.** Every improvement to the launcher — including
  all of the above — reached only the people who happened to re-run the installer by
  hand. That is not a delay; it is permanent, and invisible, and it gets worse the
  longer it goes unnoticed. **`osa update` now also updates the launcher**, taking it
  from the release being installed rather than from whatever is newest, so it always
  matches the binaries beside it. It is refused unless it downloads whole, parses as a
  valid script, and is recognisably OSA's, so a half-finished download or an error page
  cannot replace a working command; the previous one is kept and put back if anything
  goes wrong. Same story as above once installed, the new launcher takes over and
  finishes the update itself.
  - Upgrading **from 1.0.48 or earlier still needs the installer run once** — the old
    launcher has no way to replace itself. From this release onward it is automatic.

### Fixed — two tests that could fail for no reason

- Timing-dependent MCP progress and terminal tests now wait on the condition they
  actually care about instead of on the clock, so a slow machine no longer produces a
  failure that says nothing about the code.

---

## [1.0.48] — displays as `v1.0.048`

### Fixed — web page fetching was completely broken

- **Every successful fetch raised internally, and the crash message was handed back
  as the page.** Response headers arrive as a map of lists; the code assumed a
  string. So a fetch that had genuinely succeeded — the page was retrieved, the
  bytes were there — blew up on the way out, and the resulting error text was
  returned in the slot where the page content belongs. The agent then read that
  error message as though it were the documentation it had asked for, and reasoned
  from it. Nothing signalled that anything had gone wrong.
- Along with the crash, the fetch path was missing most of what real sites require:
  - A **browser User-Agent** is now sent; many hosts refuse the default outright.
  - **303 redirects** are followed, and a **relative `Location`** is resolved
    against the request URL instead of being treated as a whole address.
  - **Empty bodies and bot-challenge pages now report failure** rather than being
    passed upward as legitimate content — an interstitial is not the page you asked
    for, and the agent should not be reasoning over one.

### Fixed — `/model` could switch you to the wrong provider entirely

- **`claude-opus-5` resolved through Azure to OpenAI**, which does not serve it, so
  the session 404'd on every single turn after the switch. You asked for one vendor's
  model and were connected to another's endpoint. Provider resolution is now
  deterministic and prefers the vendor that actually owns the model.

### Fixed — context was compacted at roughly 11% of a large window

- **Compaction divided by a hardcoded 128k instead of the model's real context
  window.** On a large-window model that meant compaction fired at around **11% of
  the space actually available**, over and over — and compaction is lossy and
  irreversible, so each premature run permanently discarded conversation fidelity
  that never needed to go. The real window is now used.

### Fixed — prompt blocks were silently evicted on small-context models

- **Plan-mode instructions, tool doctrine and the runtime block were being dropped
  from the prompt with no signal anywhere.** Two faults drove the budget negative:
  the reserve held back for the response **did not scale with the window**, and a
  truncation helper **overshot its target**, cutting further than it was asked to.
  On a small-context model the remaining budget went below zero and essential blocks
  simply fell out — the agent stopped behaving as if it were in plan mode, and
  nothing said why.

### Fixed — asking you a question deadlocked the turn

- The question now renders **inline in the transcript** rather than blocking the
  turn: keyboard selection for the offered choices, **free-text entry** for anything
  else, and **Esc to decline**, which is delivered to the waiting tool immediately so
  the turn continues.

### Fixed — the long-session guard was ending sessions early

- **The guard read successful edits as failures and distinct edits as repetition.**
  It keyed on the **first 100 characters of a tool result**, which are identical for
  every edit to the same file, so a run of different successful edits looked like one
  action repeated; and it then judged those successes as *failures*. Both halves of
  its verdict were wrong at once, and it ended sessions that were going fine.

### Fixed — session saves were dropped, and tool work was discarded

- **Session saves were silently dropped while the agent was busy.** The save was
  simply skipped, with no error and no retry, so work performed during a busy stretch
  never reached disk.
- **A dropped model connection discarded tool work that had already executed.** Tools
  that ran to completion — with real side effects — had their results thrown away
  because the connection carrying the turn went down afterwards.

### Fixed — worktrees silently omitted submodule and nested-repo contents

- A worktree created for isolated work came up **missing the contents of submodules
  and nested repositories**, so the agent operated on an incomplete tree while
  believing it had the whole project.

### Security

- **A checked-in project settings file could grant itself permissions before any
  trust prompt.** A repository could ship a settings file that took effect on the way
  in — before you were ever asked whether you trusted that workspace.
- **"Allow always" could persist a rule that disabled the command classifier
  entirely.** A single approval could be stored in a form broad enough to switch off
  the classification of subsequent commands, well past the scope of what was approved.
- **The permission "ask" tier was dead code**, so a decision path that was meant to
  stop and ask never did.
- **A refusal could be retried through a different tool.** Denying an action in one
  tool did not prevent the same action being carried out via another route.

### Added

- **Session resume.** `osa resume <id>` picks a previous session back up, and the id
  is printed on exit so it is available when you need it.
- **`--model` and `--provider` flags** for selecting both from the command line.
- **`/map`**, which renders the structure of a monorepo — including submodules and
  nested repositories — rather than stopping at the top-level tree.

### Changed — providers

- **Added:** the Claude 5 family (**Opus 5, Sonnet 5, Fable 5, Haiku 4.5**),
  **GPT-5.6**, **kimi-k3** and **gemma4**.
- **Retired model ids removed** across Google, Groq, Cohere, DeepSeek, xAI, Mistral,
  Replicate, Cerebras and Fireworks, so the catalog no longer offers models that no
  longer answer.
- **Gemini thinking configuration and tool round-trip both fixed** — each was broken,
  so thinking settings did not apply and tool calls did not complete their loop.
- **Onboarding validates keys against each provider's own API**, so a key that will
  not work is caught while you are setting it up rather than at first use.

### Changed — resource growth and timestamps

- **Unbounded memory and disk growth is now bounded** across transcripts, embeddings,
  background task files and several ETS tables, each of which previously grew without
  limit for the life of the process or the install.
- **Timestamps render in local time** instead of leaving you to convert.

## [1.0.47] — displays as `v1.0.047`

### Fixed — asking you a question deadlocked the turn

- **The agent could not ask you anything.** The ask-user event was missing from the
  event-forwarder's allowlist, so a question raised by the agent never reached the
  TUI at all. The TUI already contained a complete survey dialog — it was simply
  unreachable, with no path by which it could ever be shown. Every ask therefore
  blocked for the tool's full **five-minute timeout** and then failed, which read as
  the agent hanging mid-turn for no reason.
  - The event is now forwarded, so the dialog appears when the agent asks.
  - **Esc now declines cleanly** instead of leaving the turn stuck: the decline is
    delivered to the waiting tool immediately, and the agent continues with the
    knowledge that you chose not to answer.

### Fixed — work the agent did was invisible or looked like it produced nothing

- **The task checklist never appeared.** Tasks were broadcast on a hardcoded
  `"default"` session id rather than the session that actually requested them, so
  they were published to a topic nobody was listening on. The tool reported success
  and nothing rendered — the most confusing possible failure, because there was no
  error to notice. Broadcasts now carry the real session id.

- **Delegated subagents appeared to return nothing.** Two separate defects
  compounded:
  - Results led with a status header, and the collapsed tool cell shows only the
    first line — so every delegation displayed its status banner and hid the actual
    report underneath it. The report now leads.
  - A child agent that finished without a closing message had **all of its work
    discarded**, so genuine completed work was thrown away rather than returned.

- **Tool cells didn't say what they acted on.** Read, Edit and Write rendered with
  no file path, the task tool showed a bare verb with no subject, and live status
  lines dumped raw JSON or the schema's parameter names instead of the values. A
  transcript of a long session was effectively unreadable — a column of identical
  verbs. Cells now name their target.

- **Internal reminders leaked into visible tool output**, mixing OSA's own
  bookkeeping into the results you read. This included skill files belonging to
  *other* tools, discovered by a lookup that walked as far as **40 directories above
  the workspace** — well outside the project, picking up unrelated content from
  elsewhere on the machine.

### Fixed — the long-session guard was ending sessions that were going fine

- **The doom-loop detector aborted correct work.** It is meant to catch an agent
  stuck repeating a failing action, but it keyed on **the first 100 characters of a
  tool result** — which are identical for every edit to the same file — so a
  sequence of distinct, successful edits looked like one action repeated. It then
  classified those successes as *failures*, because the diff embedded in the result
  happened to contain words like "error". The guard concluded the agent was looping
  and instructed it to abandon work that was correct.
  - Detection is now keyed on the actual call arguments and the real outcome, so
    repetition and failure are each judged on what they are.

### Fixed — the context indicator reported a confident 0%

- Two independent faults stacked into one wrong number:
  - A **transport failure** while probing a model's context window was cached as if
    it were the answer, and cached **permanently** — one blip early on pinned that
    model's window to zero for the entire life of the process, with no recovery.
  - The TUI had **no branch for an unknown window**, so it divided by that zero and
    rendered a confident, precise, wrong `0%`.
- An unknown window now shows a **token count with no percentage**, and a failed
  probe is no longer cached as a result.

### Fixed — multi-agent view, model switching, and markdown tables

- **Multi-agent view** had four simultaneous timers running, a mangled label, raw
  internal session ids on screen, duplicated rows, and a widget drawing **34 rows
  into a 30-row reservation** — overflowing its own space and pushing the layout out
  of shape. One timer, real names, no duplicates, and the widget now fits.
- **Switching model returned 404 on a fresh session.** Sessions are now announced on
  stream subscribe, so the session is known by the time you can act on it. Also
  fixed the underlying cause of related disappearances: an ETS table with **no
  durable owner**, which silently dropped tracked sessions when its owner went away.
- **Markdown tables clipped every column to the same width**, regardless of the
  content, so wide columns lost their text while narrow ones sat mostly empty.
  Columns are now content-sized and wrap rather than truncate.

- **Plans were being invented from prose.** A hook scraped numbered lines out of the
  agent's answers and promoted them into checklist items — so ordinary prose that
  happened to be numbered became a plan the agent had never proposed. Removed.

### Added

- **`--model` and `--provider` flags**, so a run can select both from the command
  line. Relatedly, **unknown flags now error** instead of being silently ignored: a
  typo previously launched a normal session while quietly discarding the option you
  asked for.
- **Locally-installed model tags now take precedence over catalog attribution**, so
  a model you actually have installed is identified as such.
- **kimi-k3 and gemma4**, and Ollama Cloud model registration is consolidated into a
  **single source of truth**. Adding one model previously required coordinated edits
  in **seven separate places**, which is why the set drifted out of agreement.

### Changed

- Agent instructions steer away from re-running commands that overlap work already
  done, and toward **stopping once a question has been answered** rather than
  continuing to investigate past the point of an answer.

## [1.0.46] — displays as `v1.0.046`

### Security — a cloned repo could execute code just by having OSA run git in it

- **Every git invocation is now hardened against hostile repository config.** Git
  reads configuration *from the repository it is operating on*, and several of
  those settings name a program that git then executes. A repo you merely cloned
  could therefore set `core.hooksPath` (pointing at attacker-controlled hooks),
  `core.fsmonitor` (an arbitrary binary run on nearly every command), or clean/
  smudge filters (run on checkout and diff) and get **code execution the moment
  OSA ran any git command inside it** — including read-only ones like `git
  status` or `git diff`, which OSA runs routinely as part of context discovery.
  - Introduced `OptimalSystemAgent.Git`, a single choke point that neutralises
    these vectors, and routed **all 56 git call sites** through it — context refs
    (`diff`, `git_log`, `staged`), the worktree and fast-worktree machinery, the
    filesystem checkpoint server, the `git` tool handler, and the CLI.
  - No call site now shells out to `git` directly, so the hardening cannot be
    bypassed by a future caller forgetting to opt in.

- **Terminal titles are sanitised.** The TUI sets the terminal window title from
  session-derived text, which could carry **OSC escape sequences** (an escape
  injection that can drive the host terminal, and on some terminals can be echoed
  back into the input stream) or **Trojan-Source bidirectional control
  characters** (which reorder displayed text so what you read differs from what is
  actually there). Both classes are now stripped before the title is emitted.

### Fixed — `osa update` failed silently, then locked itself in permanently

- **The worst-behaved bug in the updater is gone.** `osa update` swapped the TUI
  binary **unchecked** and stamped the new version **regardless of whether any
  step had succeeded**. The result was a failure mode that hid itself and then
  became permanent: an update that had actually failed reported *success*, left
  the old binary in place, and — because the stamp now claimed the new version —
  every subsequent `osa update` answered **"Already up to date"** forever. The
  user was pinned to a stale build with no error and no way to notice.
  - Every step of the update is now verified before the next one runs.
  - The freshly installed TUI **must report the installed version** before the
    version stamp is written; if it cannot, the stamp is not written and the
    update fails loudly.
  - A stamp/binary mismatch is now **self-healing**: an installation that already
    lost this race detects the disagreement and re-runs the update rather than
    reporting it is current.
  - The identical defect in the **PowerShell installer** (`scripts/install.ps1`)
    was fixed the same way, so Windows is not left on the old behaviour.

### Fixed

- **The context bar no longer shows a percentage against a made-up window size.**
  Cloud models were never probed for their real context length, so the bar
  measured usage against a hardcoded default — a 1,000,000-token model was
  reported as a fraction of **128k**, making a nearly empty context look nearly
  full. Real context windows are now resolved from the provider; when a window
  genuinely cannot be determined, the bar renders the **token count with no
  percentage** rather than a confident wrong one.
- **Plan mode is no longer silently dropped on small-context models.** The context
  budget fitter evicted blocks in plain list order with no error, so on a tight
  budget the plan-mode instructions could simply vanish from the prompt — the
  model stopped behaving as if it were in plan mode, with nothing reported.
  Essential blocks are now **priority-ordered**, so they survive eviction.
- **Fixed a TUI crash** in the activity details block, which wrote outside the
  frame buffer.
- **`POST /:id/provider` returns 404, not 400, for an unknown session.** An
  unrecognised session id was reported as a malformed request.

### Changed

- **Tool errors are non-fatal where recovery is possible.** A failing tool call
  used to halt the turn; the model now receives the error and can correct course
  and continue, instead of the whole turn dying on a recoverable mistake.
- **Paste handling reworked** in the TUI for more reliable handling of large and
  bracketed pastes.
- **Agent instructions substantially expanded**, covering tool usage and
  workflow guidance in materially more detail.

## [1.0.41] — displays as `v1.0.041`

### Fixed — switching the model failed before the first message

- **Switching provider/model no longer errors on a fresh session.** Session Loops are
  started **lazily** — the message path calls `ensure_loop` when the first turn
  arrives — but the provider-swap path only *looked up* a Loop and never started one.
  So the extremely common flow of *open OSA → pick a model → then start talking*
  returned `{:error, :not_found}` → HTTP **404 `session_not_found`** → a "switch
  failed" toast, every time. Swapping now materialises the Loop the same way every
  other session-scoped entry point does, so the choice lands on the Loop the first
  turn will use.
  - Verified against a live backend on a session with no Loop: **404
    `session_not_found` → 200 `ok`** (provider, model and context window returned).
  - Added a regression test asserting a switch on a not-yet-started session neither
    404s nor leaves the session unmaterialised.

## [1.0.40] — displays as `v1.0.040`

### Fixed — TUI audit: 14 rendering defects across 3 root causes

A full audit of the TUI (live-region geometry, text rendering, turn lifecycle)
found that most visible glitches traced to three structural gaps rather than
independent bugs. All three are now closed.

**Root cause 1 — the live region's height was computed twice, and some components
drew without being in the budget at all.**

- **Typing a `/` command no longer wipes the screen.** The completions popup
  recomputes its height on every keystroke, and that was aliased onto the "terminal
  resized" flag — so each character took the destructive full-screen clear path and
  re-anchored the viewport at row 0. Popup changes now commit promptly but clear
  *surgically*; only a real terminal resize takes the full wipe.
- **No more dead rows under the spinner.** The activity slot reserved a flat 6 rows
  and drew its accent rail across all of them, trailing bare rail glyphs down the
  empty rows. The slot is now sized exactly to the current verbosity and the content
  is bottom-anchored, so the spinner sits tight above the composer.
- **Verbose mode no longer silently drops tool rows** — it needs 9 rows and the flat
  cap gave it 6, clipping the three oldest feed entries.
- **Screen-reader mode no longer leaves 11 blank rows** above the composer (sizing
  reserved the expanded thinking box while drawing the 1-row plain-text line).
- The agents roster's reserved and drawn heights agree again, and it is
  bottom-anchored like the activity feed.

**Root cause 2 — no column-width primitive, so eight near-duplicate "fit to width"
helpers existed at three different correctness levels.**

- Added `util::fit_cols` / `util::cols` as the canonical column-aware fitters and
  routed session titles, file-picker names, toasts, and the agents roster through
  them. Previously these compared **byte** length (or char count) against a **column**
  budget, so any CJK/emoji text was cut to roughly a third of its space — and because
  toasts are right-aligned, they lost their *beginning*.
- **Every wrapped bullet in every reply was mis-indented.** The list renderer measured
  its `"• "` prefix in bytes (4) rather than columns (2), so continuation lines sat two
  columns right of their own first line and wrapped early.
- The welcome banner centred by byte length, so any non-ASCII name or path made the
  first screen lopsided.

**Root cause 3 — width-blind heights + unwrapped prose.**

- **Permission prompts no longer clip the backend's warning and reason.** These
  reserved exactly one row each and rendered unwrapped, so safety text the user is
  being asked to approve could be cut off mid-sentence. Both now wrap, and the
  reserved height is computed from the same wrap.
- Plan/checklist items no longer clip mid-word or show raw `**bold**`: subjects are
  markdown-stripped and fitted to the real render width (threaded through instead of
  guessed), so each occupies exactly the one row the cell reserves. The same three
  fixes were applied to the separate task panel.
- Markdown tables keep their right border — the width cap subtracted the borders but
  forgot the `" │ "` separators, leaving the capped table too wide to fit.

**Turn lifecycle**

- The plan snapshot is now flushed synchronously at turn end and the live checklist
  retired, fixing both the recap/plan ordering race (a ~400ms debounce could land the
  plan *after* "Worked for Ns") and a stale plan redrawing over the **next** turn's
  reply.

**Tests**

- Added the live-region slot invariant (reserved rows ≥ drawn rows, and exactly equal
  when saturated) across every verbosity and screen-reader mode. No test previously
  compared reservation against layout — which is why these regressions shipped green.

## [1.0.39] — displays as `v1.0.039`

### Added — action authority + OpenComputers remote client

- **Unified action authority (#93 + #94).** Governed tool execution now routes through one
  fail-closed control-plane authority: HTTP, MCP, scheduled/away-mode jobs, interactive
  agents, deferred tools, and sub-agents share exact capability identifiers and
  server-published versioned fingerprints, with one-time approvals bound to the exact
  parameters and execution surface. Purely local tools stay offline and ungoverned; OSA's
  local non-bypassable machine safety remains a separate earlier layer. Ships the canonical
  MIOSA capability contract (206 capabilities, SHA-pinned) plus the routing that enforces it.
  *(This is an evolving cross-repository feature; behaviour is fail-closed and gated.)*
- **OpenComputers account remote client (#92).** New `osa opencomputers remote hosts` /
  `remote exec --host <id> -- <command>` / `remote agent --host <id> --prompt <prompt>` — a
  versioned, TLS-only remote-client envelope that keeps the MIOSA account credential in memory
  (resolved from `miosa login` or `MIOSA_PLATFORM_API_KEY`, never persisted in host config).
  v1 supports one-shot exec/agent operations; no interactive PTY routing yet.

## [1.0.38] — displays as `v1.0.038`

### Fixed — TUI live-region stability (systematic pass, not one-off)

Following a full audit of every inline-viewport height contributor (cross-checked against
ratatui's `insert_before` source), three more instances of the same bug class were fixed so
the composer can no longer stack or the screen wipe during a turn:

- **Agents roster is now a fixed slot.** Like the activity feed and streaming preview, the
  multi-agent roster grew one row per spawned fleet node mid-turn, rebuilding the viewport and
  stacking chrome. It now reserves a constant slot whenever shown.
- **Thinking box is now a fixed slot when expanded.** Expanded reasoning grew the box
  line-by-line as it streamed (1→12 rows), rebuilding the viewport on every line. It now
  reserves its constant max; the header + last ≤10 lines render into it.
- **No more transcript wipe after a message flush.** `last_inline_top` (the anchor for the
  surgical height-change clear) was only refreshed at rebuild points, but `insert_before`
  (flushing finalized messages to scrollback) moves the viewport top down every time. The
  stale anchor made the next clear wipe the just-flushed transcript. It's now refreshed after
  every flush.

Known remaining edge (tracked): on terminals that *reliably* drop the cursor-position query,
a rebuild degrades to full-screen and finalized messages can be silently dropped rather than
shown — a separate fix.

## [1.0.37] — displays as `v1.0.037`

### Fixed — composer no longer stacks down the screen during an agent turn

- **The real fix for the mid-turn staircase.** As tools ran during a turn, the live
  activity/tool feed grew one row per tool (`pwd`, then `ls`, then `date`…), and that growth
  grew the inline viewport height **mid-turn** — each growth rebuilt the viewport (a DSR cursor
  re-anchor), stacking a fresh composer + status bar down the whole screen. The streaming
  preview was already given a fixed-height slot to prevent exactly this; the activity feed was
  not. It now reserves a **constant fixed slot** for the whole turn (the feed draws top-down
  into it), so the viewport height stays stable, no per-tool rebuild happens, and nothing
  stacks. **Validated live** against a real agent turn executing shell tools: single composer,
  no stacking, no crash.

## [1.0.36] — displays as `v1.0.036`

### Fixed — resize wipe was firing on every height change (regression)

- **The screen no longer wipes/stacks on notices, typing, or scrolling.** The DSR-free
  full-screen `ClearType::All` from the resize fix lived in the shared commit block, which
  fires on **any** inline-height change — not just terminal resizes. So a transient notice
  ("New session", "Coordinator mode off"), the composer growing, or scrolling all wiped the
  whole screen and re-anchored, stacking composers and clearing the transcript on every
  keystroke. Now the full-screen wipe runs **only on an actual terminal resize** (where reflow
  makes surgical clearing impossible); a pure height change clears surgically from the tracked
  region top, preserving the transcript above.

## [1.0.35] — displays as `v1.0.035`

### Fixed — update check hit a dead endpoint

- **The update checker no longer fails against a dead service.** `OpenComputers.Updater`
  (the background auto-check and `osa update check/apply`) queried
  `https://api.miosa.ai/api/v1/opencomputers/osa/latest`, which returns **503
  "version_not_configured"** — no release is published there — so every check failed and the
  background loop logged repeated failures. It now checks **GitHub Releases**
  (`/repos/Miosa-osa/OSA/releases/latest`), the same source the installer and the `osa update`
  launcher already use.
- The checker is now **check-only**: it detects a newer published release and reports
  `{:available, version}` (the actual `osa update` launcher applies it via the GitHub release
  tarball — this Elixir path only ever staged a single binary, which never matched how OSA
  ships). Also fixes version comparison against the zero-padded display tag (`v1.0.034`), which
  `Version.parse/1` had been rejecting as an invalid leading zero.

## [1.0.34] — displays as `v1.0.034`

### Fixed — Ollama Cloud onboarding (client-blocking)

- **Selecting "Ollama Cloud" with an API key now verifies against `https://ollama.com`, not
  a local daemon.** The onboarding health-check was **local-first**: it probed for a local
  Ollama daemon and only fell back to the cloud endpoint if none was found. So an explicit
  cloud selection could get hijacked to `http://localhost:11434` — which does not serve a
  `:cloud` model like `glm-5.2:cloud` — and verification died with
  `error sending request for url (http://localhost:11434…)`.

  Corrected priority: **cloud selection ⇒ cloud URL, always.** When a key is supplied, verify
  against `ollama.com` with the Bearer key. Only a **keyless** cloud selection falls back to a
  reachable local device-identity daemon. Every other provider was already correct (Anthropic →
  `api.anthropic.com`, OpenAI → `api.openai.com`, OpenRouter → `openrouter.ai`, Ollama Local →
  `localhost:11434`).

## [1.0.33] — displays as `v1.0.033`

### Fixed — TUI resize, for real this time (duplication AND crash)

- **Resizing the terminal no longer duplicates the composer or crashes.** On terminals
  that don't answer the cursor-position query (DSR) quickly during a resize — tmux, some
  SSH sessions, and others — the inline live region could not be located after the terminal
  reflowed, so earlier surgical-clear attempts either **stranded a staircase of old
  `N% context used` + divider rows**, or (when left to ratatui's auto-resize) crashed with
  `Error: The cursor position could not be read within a normal duration`.

  Since surgical clearing is impossible without a working DSR, the resize path now does a
  **DSR-free full-screen wipe** (`ClearType::All`) before rebuilding the region fresh —
  exactly one copy of the chrome can ever exist and the reflow position never matters.
  Validated against a DSR-dropping pane across widen / narrow / rapid-resize bursts: no
  duplicate, no crash.

  Trade-off: the on-screen transcript is cleared on resize (it repaints from the live region
  down). The finalized conversation still lives in the terminal's scrollback history and the
  in-app transcript viewer — only the on-screen copy is redrawn.

## [1.0.32] — displays as `v1.0.032`

### Fixed

- **TUI resize duplication — corrected anchor.** v1.0.31's fix anchored the inline-region
  clear to the *bottom* of the screen, which is only right when the region is pinned to the
  bottom (a screen full of transcript). In a fresh / near-empty session the live region sits
  high on the screen with blank space below it, so the bottom-anchored clear wiped empty rows
  and left the real composer/status untouched — the duplicate persisted. The clear now homes
  to the region's **actual tracked top** (`last_inline_top`, captured at startup and every
  rebuild), clamped into the resized screen, so it erases the on-screen chrome whether it sits
  high (empty session) or low (full screen); the rebuild re-anchors the fresh region at the
  same row, leaving exactly one copy.

## [1.0.31] — displays as `v1.0.031`

### Added — post-edit format + diagnostics loop (stop editing blind)

- **OSA no longer edits code blind.** After every `file_edit` / `multi_file_edit` /
  `file_write` / `file_create`, the touched file is run through a fast, single-file
  **format + diagnostics** pass and any syntax/parse error is injected back into the tool
  result the **same turn** — so the model sees the mistake it just made instead of
  discovering it 20 tool-calls later. This was the top convergent gap versus Claude Code,
  Codex, OpenCode and Grok (`docs/GAP_ANALYSIS.md` G1 + G2).
  - **Auto-format on write** — Elixir formats **in-process** via `Code.format_string!/2`
    (respecting `.formatter.exs` opts, no `mix` startup cost); Go/Rust/JS·TS/Python use
    their single-file formatter (`gofmt -w`, `rustfmt`, `prettier --write`, `ruff format`).
  - **Fast diagnostics** — Elixir syntax via `Code.string_to_quoted/2` (instant, in-process);
    Go via `gofmt -e`, Rust via `rustfmt`, JS via `node --check`, Python via `ruff check` /
    `py_compile`; TS/TSX parse errors surface through `prettier`.
  - Dependency-light and **degrades to a no-op** when a tool binary is absent; each command
    is time-boxed; a file that fails to parse is left byte-for-byte untouched and its error
    reported. Wired via the pluggable `:diagnostics_provider` seam; disable with
    `config :optimal_system_agent, post_edit_verify: [enabled: false]`.

### Fixed

- **TUI — resizing no longer duplicates the composer/status bar.** The inline-region rebuild
  cleared old chrome anchored to a `crossterm::cursor::position()` **DSR query**, which tmux
  and some emulators drop or answer with a stale row during a resize burst (a pane drag fires
  many `Resize` events) — stranding a duplicate composer while a fresh one drew below. The
  clear now anchors to the bottom-anchored region geometry derived from
  `crossterm::terminal::size()` (an ioctl reflecting the applied resize, no escape round-trip
  to drop): deterministic for grow/width-only changes, exact for shrink.

## [1.0.30] — displays as `v1.0.030`

### Fixed / robustness

- **A port conflict no longer crashes the whole app.** When `OSA_HTTP_PORT` (default 9089)
  was already in use, OSA hard-crashed on boot — Bandit failed to bind, the supervisor
  restarted it 10×/60s, and the entire OTP tree died with a cryptic dump. Now a boot
  **preflight** halts cleanly with an actionable message that distinguishes *another OSA
  instance already running* ("connect to it, or set `OSA_HTTP_PORT`") from *a foreign
  process holding the port* ("free it — `ss -ltnp | grep 9089` — or set `OSA_HTTP_PORT`"). A
  single shared `Net.Port` helper backs every surface below.
- **`osa doctor`** now reports three distinct states — OSA responding, OSA not running, and
  **port taken by a non-OSA process** (the case it previously misdiagnosed as "API not
  responding"). It also reads `OLLAMA_URL` (was `OLLAMA_HOST`, misaligned with the app).
- **Onboarding** warns if the HTTP port is already taken *before* you finish setup, instead
  of completing "successfully" and then crashing on first launch.
- **TUI** — the "backend unreachable" message now names the port and points at `osa doctor`
  instead of a vague dead-end.

## [1.0.29] — displays as `v1.0.029`

### Fixed

- **Context meter read far too high on Ollama Cloud models.** For a `:cloud` model running
  through the `:ollama` provider (e.g. `glm-5.2:cloud`), the usage denominator collapsed to
  the local Ollama KV-cache ceiling (`ollama_num_ctx`, ~32k → ~12.7k after the reserve)
  instead of the model's real context window (1,000,000) — so a normal ~15k-token turn read
  **over 100%** and the bar filled almost instantly. `effective_context_window/2` now skips
  the local KV cap for `:cloud` models, so the meter (and context budgeting + `num_ctx`
  sizing, one source of truth) use the true window. A ~50k-token session now reads ~5%
  instead of pinned-full.

## [1.0.28] — displays as `v1.0.028`

This cycle built an agent **fleet**: a Claude-Code-parity roster of full-power
sub-agents, dynamic multi-agent **workflows**, a renamed **effort ladder** that
gates them, and — the capstone — **self-orchestration** so OSA can decompose a
task into disjoint file-owned workstreams, fan out a collision-free wave in
isolated worktrees, verify it, and commit itself. See `docs/FLEETVIEW_DESIGN.md`,
`docs/FLEET_ORCHESTRATION.md`, and `docs/FLEET_EDGE_CASES.md`.

### Agent Fleet

- **FleetView roster** — a live, arrow-selectable panel under the composer: a
  green never-killable `main` root row plus one row per running node (agent-type,
  live activity, elapsed, `↓ tokens`). `←` browses, ↑/↓ select, Enter attaches a
  read-view of a node's stream, `x` stops it. Inline roster is bounded to 8 rows
  (`+K more`); the `/agents` dashboard lists all.
- **Full-power spawn** (`Fleet.spawn_fleet_node`) — each node is a complete OSA
  loop (full tools/MCP/memory/permissions) on its own session with its own
  custom-agent system prompt + tool allowlist, joined to the run tree. Not the
  restricted delegate path.
- **`fleet` tool** — the model auto-invokes it (`action: spawn | workflow`);
  spawning is automatic, `/fg` and `←` are optional viewing. Depth- and
  fleet-cap-guarded (spawn-bomb safe).
- **Dynamic workflows** (`Fleet.fan_out`) — fan out one full-power node per item
  through a 16-concurrent bounded pool with FIFO queue-drain, a 1000-node
  run-lifetime kill switch, and a live `N/16` roster counter. Per-node timeout,
  per-item error isolation, and a whole-tree budget guard that stops spawning when
  the fleet budget is exhausted. Nodes coordinate through the shared scratchpad.

### Effort

- **Ladder renamed** to `fast / medium / high / xhigh / ultra` (was
  `low/medium/high/max`), with a back-compat normalizer so persisted `:low`/`:max`
  settings keep working. Effort = how much it thinks; the current tier is shown
  live in the thinking indicator (e.g. *"thinking harder with ultra effort"*).
- **`ultra`** is the max tier and the gate for dynamic workflows. Effort drives the
  provider thinking budget across Anthropic / OpenAI / Gemini / Ollama (verified
  matrix); opus honors an explicit max budget at `ultra` instead of always adaptive.

### Self-orchestration

- **Worktree-per-node isolation** (`isolation: :worktree`) so parallel nodes edit
  their own worktrees and never collide.
- **`Fleet.Finalizer`** — merges disjoint node diffs, runs an authoritative gate,
  and commits when green (scoped `git add -- <file>`, attribution-clean, never pushes).
- **The loop is closed end-to-end** — `fan_out` waits for each node to complete before
  capturing its worktree diff (so the finalizer merges *real* changes), and the `fleet`
  tool exposes `isolation` + `finalize` (gate + commit) so the coordinator can run the
  whole recon → isolate → merge → gate → commit flow. (Unit-verified end to end; a
  live-repo integration test is the next follow-up.)
- **Fleet Orchestration playbook** (`priv/skills/fleet-orchestration`) — teaches the
  coordinator the disjoint-workstream method: recon → partition by file ownership →
  isolate → structured reports → finalize → checkpoint.

### Durability & recovery

- **Budget survives restart** — the `max_budget_usd` cap is persisted in the
  checkpoint and restored, so a crash can no longer reset it to zero.
- **Crash recovery** — stale `:running` rows are reconciled at boot; an opt-in
  resumer re-dispatches orphaned autonomous runs.

### Hardening

- Fleet edge cases across `fan_out` (timeout / error isolation / empty-huge items),
  fleet-tool argument validation, and scratchpad concurrency (cluster-serialized
  writes). Two provider thinking bugs fixed (OpenAI silently disabling reasoning on
  a bad effort value; Gemini `nil > 0` term-ordering emitting a bogus budget).
  FleetView keyboard navigation verified end-to-end. **TUI resize no longer duplicates
  content** — the inline-viewport clear now anchors to the actual cursor instead of
  ratatui's stale pre-resize geometry, which had been scrolling old chrome into
  scrollback on every resize. Intermittently-flaky tests stabilized at the root cause
  (session-scoped event capture; `async: false` where global app-env is shared). Full
  suite: 5116 tests, 0 failures.

## [1.0.10] — displays as `v1.0.010`

This cycle closed out the CC-parity backlog: 16 workstreams across the agent
loop, memory, delegation, tools, ops, and the Rust TUI. Grouped by area
below; see `docs/BACKLOG.md` for the item-by-item scoreboard and commit
references.

### Agent

- **Investigative plan mode** — `enter_plan_mode` / `exit_plan_mode` tools
  route through `Agent.Loop.enter_plan_mode/1`, gating the session to
  read-only tools until the plan is exited. The plan text is a **durable
  file** (`~/.osa/sessions/<id>.plan.md`, next to the progress ledger) rather
  than transient state, so a plan survives context resets, restarts, and the
  approve/reject/edit round-trip.
- **Goal-level verifier** (`Agent.Loop.GoalVerifier`) — an independent,
  read-only skeptic panel (N subagents, majority-refute vote) that judges
  whether the user's *goal* was met, not just whether a file compiles. Off by
  default; fail-closed to `:incomplete` on ties or missing data. Run-capped
  and stall-gated so it never spins forever.
- **Multi-turn goal orchestration** (`Agent.Loop.GoalTracker`) — a
  cross-turn, ETS-backed status machine (`:active | :paused | :completed |
  :off_track`) that survives across top-level turns. Auto-pauses on a
  cross-turn stall (two verification rounds citing the same gap) or a
  lifetime run cap, and gates the (expensive) verifier panel on a reverify
  cadence instead of every turn.
- **Reasoning-only doomloop detector** (`Agent.Loop.DoomLoop.ReasoningOnly`) —
  catches a model spinning in pure thought (zero tool calls) or repeatedly
  erroring, which the existing tool-call-keyed detectors can't see. Halts
  after a small consecutive-streak threshold and forwards to the existing
  `Resample` remedy.
- **Forced max-steps wrap-up** — hitting the iteration cap now triggers one
  final tools-disabled model turn that writes a real state summary/handoff
  instead of a canned line. Guarded so hitting the cap can never crash the
  turn.
- **Header-aware retry** — provider resilience honors a `Retry-After` header
  from the provider (capped at 60s) instead of blind exponential backoff,
  and can rebuild the HTTP/1.1 client / strip images on a header-driven
  retry decision.
- **First-failure self-correction** — the verification gate is *grounded*:
  it re-prompts only after an external check (build/test/lint) actually
  fails, following the CRITIC / "LLMs Cannot Self-Correct" research —
  ungrounded self-judgment is avoided.
- **Token-budget "work to target"** — `target_output_tokens` (state or app
  env) keeps the loop auto-continuing until a caller-specified output-token
  budget is met, capped at a small number of continues.

### Context / Memory

- **Hybrid RAG recall** — vector KNN (`Memory.Search`, cosine similarity)
  fused with MMR diversity re-ranking (`Memory.MMR`) and dependency-free
  query expansion (`Memory.QueryExpansion`, synonym table + stemming) for
  the lexical scoring path. Degrades gracefully to keyword-only scoring when
  no embedding provider is configured or a call fails.
- **Persisted vector store** — embeddings are now durably stored one row per
  memory id in a `memory_vectors` table in the same SQLite database the
  memory store uses, with an ETS warm-read cache in front. Content-hash
  invalidation re-embeds on content drift.
- **Compaction quality**:
  - Verbatim latest-user-query preservation — the most recent `user` message
    is wrapped in `<user_query>` tags and prepended to any generated
    summary, untouched by the summarizing LLM.
  - Token-budgeted, turn-aware tail selection — `preserve_recent_budget`
    (25% of the usable context window, clamped `[2_000, 8_000]`,
    operator-overridable) replaces a fixed message-count tail.
  - Prune tier — a non-LLM pass that erases old (out-of-budget) tool-result
    output outright rather than summarizing it, with a protected-tools
    allowlist and a minimum-reclaim gate before it bothers mutating anything.
  - Media-strip + overflow replay — on context-overflow retries, media
    blocks are stripped from messages before retrying, up to 3 overflow
    retries.
- **Post-compaction auto-continue** — after a compaction pass changes the
  message list, the loop can auto-continue the turn (gated by
  `ProactiveCompaction.continuation_enabled?/0`) instead of silently
  returning a truncated response.

### Delegation

- **Transitive cascading cancel** — `Loop.cancel/1` now BFS-walks the
  parent/child session tree and cancels every descendant sub-agent, plus
  batch-kills their background shell commands in one pass
  (`BackgroundManager.cancel_for_sessions/1`).
- **`task_wait` join-barrier depth ceiling** — a blocking wait on other
  agents' completion can no longer nest arbitrarily deep; `max_depth/0`
  (default 3, `:max_blocking_wait_depth`) is checked before a wait starts,
  denying requests that would exceed the ceiling instead of blocking and
  failing later.
- **Peer-resume (sibling handoff)** — a sub-agent run can be seeded from a
  sibling/peer's accumulated context (`resumed_from`) rather than starting
  fresh or forking from the parent; surfaced in run metadata for lineage.
- **Worktree durable snapshot** — `FastWorktree.snapshot_ref/2` commits any
  uncommitted worktree changes and writes a durable git ref
  (`refs/osa/subagent-snapshots/...` by default) before teardown, so a
  sub-agent's work stays inspectable/resumable without being merged or lost.

### Tools

- **Hashline drift-guard edits** (`FileEdit.DriftGuard`) — a second,
  independent content-hash guard on top of `FileState`'s `{mtime, size}`
  check, closing the blind spot where two different file states collide on
  the same size within the same wall-clock second. Only ever *stricter* than
  the existing guard; never blocks a legitimate re-read/edit cycle.
- **Output-shorten-to-file** (`Agent.Loop.ToolResultStorage`) — tool results
  over 50KB or 2,000 lines are persisted to `~/.osa/tool-results/<id>.txt`
  and replaced inline with a head/tail preview (40/20 lines) plus a file
  reference, preventing context bloat from huge shell/grep output.

### Ops

- **Rollback-safe self-update** (`osa update`, `bin/osa-update`) — dual
  symlink (`current` / `previous`) atomic swap: stage a fresh git-worktree
  checkout, build it, boot-probe its `/health` endpoint, and only then
  atomically repoint `current`. A post-swap health re-check auto-rolls-back
  to `previous` on failure. `osa update --staged`, `osa update --rollback`,
  and `--dry-run` are all supported; nothing is mutated on a dry run or a
  failed build/health gate.

### TUI

- **Composer** — structured `@`-mentions (file/dir/agent, with a per-kind
  glyph in the popup), ghost-text completion, `!`-prefixed bash submit mode,
  a huge-input pill for large pastes, and frecency-ranked mention recall.
- **Render** — LaTeX-to-Unicode conversion, richer table-cell markdown
  (nested quotes, tabs, soft breaks), bold-italic/setext heading support,
  and a raw-source toggle (`alt+r`).
- **Notifications / focus / clipboard** — terminal focus tracking (DECSET
  1004), OSC 9;4 progress reporting, a sleep inhibitor during long runs, an
  audio completion cue, kitty click-to-focus, a layered clipboard, and a
  configurable notification channel (`OSA_NOTIFY_CHANNEL`, opt-out via
  `OSA_NO_NOTIFY`).
- **Status / activity** — esc-again-to-interrupt, a watcher/background cue,
  a queued-message hint, usage-percent + low-balance indicator, an MCP
  status chip, width-gated spinner, and a subagent footer.
- **Fixed-height streaming viewport** — the inline chat viewport now holds a
  constant height while streaming instead of reflowing the terminal on every
  chunk.

### Deferred (documented, not dropped)

See `docs/BACKLOG.md` → "Deferred with rationale" for the reasoning behind
message-derived loop state (crash-resume), structured `@file`/`@agent` refs
on the wire, and the remaining crossterm-blocked mouse items.

---

## Older history

Earlier, pre-cycle entries live in [`docs/operations/changelog.md`](docs/operations/changelog.md).
