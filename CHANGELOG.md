# Changelog

All notable changes to OSA are documented here. This file tracks
release-level changes; the day-to-day build ledger lives in
[`docs/BACKLOG.md`](docs/BACKLOG.md).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## [1.0.71] — displays as `v1.0.071`

Dragging the window no longer leaves a stack of composers behind. This one has
been reported repeatedly and "fixed" several times; it survived because nothing
that could fail was watching.

### Fixed — a width drag stranded one copy of the live region per resize

- **The cause is tmux, not the terminal.** Reports came from sessions running
  `TERM=tmux-256color`. tmux is not a passthrough: it is its own emulator with
  its own screen model, it does not reflow on a width change, and the live
  region scrolls into its PANE HISTORY as it redraws at each new width. An
  erase — any erase — cannot reach scroll history, so the existing ED0 clear
  wiped the visible screen and left every abandoned copy exactly where it was.
- The copy count tracked the *rebuild* count precisely: a 12-step drag left 13
  copies, a fast (coalesced) drag left 5. That is why raising the settle window
  reduced the symptom without ever removing it.
- `ESC[3J` is the only sequence that reaches pane history, and it now runs on
  resize **inside a multiplexer only**.

### Why previous fixes could not have worked

- The layout harness renders with `pyte`, which does not reflow on resize.
  Real terminals do. A drag that stacked copies on the user's screen rendered
  as clean in the harness, so every fix shipped green.
- Two new harnesses close that gap. `test/pty/vte_resize.py` embeds real
  libvte through GObject introspection — the library GNOME Terminal links —
  and verifies its own resizes actually reach the child before asserting
  anything. `test/pty/tmux_resize.py` drives a real tmux pane on a dedicated
  server and reads history back with `capture-pane`. The tmux one reproduced
  the defect on demand; the VTE one shows libvte reflow never stranded
  anything, which is what scopes the fix.
- A discarded hypothesis, recorded so it is not re-tried: the rebuild's DSR
  cursor query being dropped by tmux. Resizing the viewport in place instead of
  reconstructing it — removing the query entirely — changed nothing. Still 13
  copies. The copies arrive through ordinary scrolling, not through anchoring.

### The trade-off, stated plainly

- **Resizing inside tmux discards that pane's scroll history.** The
  conversation is not lost — every finalized message stays in the transcript
  viewer (Ctrl+O) — but scrolling the pane back past a resize will not show it.
- Outside a multiplexer nothing changes at all: the added code returns
  immediately, so Ghostty, WezTerm, kitty, Alacritty and every plain terminal
  take byte-for-byte the path they took in 1.0.70. A test pins that scoping in
  both directions so the exception cannot be widened by accident.

---

## [1.0.70] — displays as `v1.0.070`

The provider and model pickers now tell you what you are actually looking at:
which models your plan can run, which concrete model an alias resolves to, and
why a sign-in was refused.

### Fixed — a model your Claude plan can run was never offered

- **`fable` was missing from the Claude Code model list.** `claude --help`
  names its own aliases as "'fable', 'opus', or 'sonnet'"; OSA carried
  `sonnet`, `opus`, `haiku`. A subscriber could run Fable and OSA never showed
  it. Read back off the installed binary, which is the only source that cannot
  disagree with the CLI actually present.

### Fixed — provider descriptions silently disappeared

- **The picker was pinned to 82 columns** regardless of terminal width, and its
  rows are two-column (name + status on the left, description right-aligned)
  with the description dropped when what remains is too narrow to read. On a
  long row — "Claude subscription (via Claude Code)  ✓ signed in as
  you@example.com" — the description vanished with no ellipsis while 60 columns
  of screen sat unused beside the dialog. The dialog now grows to 120 columns.
  The drop is still by design (a truncated status is worse than a missing
  description) but is now a last resort on a genuinely narrow terminal.

### Added — the picker names the concrete model

- Claude Code resolves an alias downstream and reports the real id back on the
  first call. That was recorded and shown only in the CLI header, never in the
  TUI, so `/model` said "Opus" and nothing more. The alias row now reads
  "Most capable · now claude-opus-4-5-20260101" once known. Only the alias that
  actually resolved is annotated, and the resolved id is never substituted into
  the model `id` — the alias is what the CLI accepts.

### Fixed — a refused sign-in explains itself

- The device-code endpoint's error body was discarded, leaving a bare status
  number. Device code authorization is an account/organization security setting
  that ships **off** for some ChatGPT accounts, and when it is off the endpoint
  refuses before any code exists — so the user saw a number and had no way to
  learn that a checkbox in their own settings was the entire problem. The
  provider's reason is now surfaced, along with what to enable.
- Deliberately NOT repeated: the provider's verification page says to re-run
  *its own CLI* afterwards. That instruction is wrong inside OSA. The setting
  is the actionable half and is the same setting whichever tool asks.

### Note on 1.0.69

That release went out with a red Rust test: `VERSION` was bumped after the Rust
suite had already run, so the Cargo.toml drift guard fired one release late.
Both version files are now bumped together and the suite re-run afterwards,
which is the order that guard requires to be useful.

---

## [1.0.69] — displays as `v1.0.069`

Two things that made a signed-in account unusable: OSA told you to quit and run
a different program to fix an error you were looking at, and it offered ChatGPT
models your plan stopped carrying three releases ago.

### Fixed — errors no longer send you out of the session

- **29 user-facing strings instructed the user to run `osa setup`.** The one
  most people hit is the *shared* `:not_connected` message in
  `Auth.Subscription` — every subscription provider reuses it, which is why
  this looked like a different bug on each provider and was in fact one string.
  Auth errors now name `/login` (sign in with an account) or `/provider` (add
  or change an API key). The CLI still exists; it is no longer the advice.
- Same treatment for expired sign-ins, revoked tokens, 401/403, missing keys,
  the Bedrock and Anthropic messages, the Claude-subscription entry, and the
  "Ollama is not running" hint.
- **A class guard was added** rather than only fixing the strings. These
  messages are written per provider, so the next provider added would have
  reintroduced the problem. `in_harness_guidance_test.exs` strips comments,
  sweeps the auth/provider sources for shell-exit phrasing, and checks every
  provider in `Subscription.supported()`.
- Six tests asserted the old behaviour — one was named `auth errors point at
  \`osa setup\``, with a comment explaining that `/login` had been dropped when
  OSA was briefly API-key-only after the Anthropic sign-in removal. That
  premise ended when account sign-in landed. They now pin the general
  invariant: an auth error names a slash command and never names a shell.

### Fixed — the ChatGPT model list was three generations stale

- OSA offered `gpt-5.2-codex`, `gpt-5.1-codex-max`, `gpt-5.1-codex-mini` and
  `gpt-5.2`. **None of those ids appear in the Codex picker any more**, so a
  user who signed in was defaulted onto a model their plan no longer carries.
- Replaced with the current line-up — `gpt-5.6-sol` (now the default, matching
  Codex's own current selection), `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`,
  `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark`.
- The catalogue test now pins *the default model is present in the catalogue*
  instead of one hardcoded id, so it fails when the list ages out rather than
  passing while pointing at nothing.

### Known gaps, unchanged from 1.0.67

- No call has been made to a live provider endpoint from this build.
- Stacked chrome after a terminal resize is still unreproduced. The test
  harness does not reflow on resize; real terminals do.
- `claude_cli` still requires Claude Code to be installed and signed in first.
- Account/plan/quota is collected from provider response headers and shown by
  `/usage`, but is not yet drawn in the model picker. It has nothing to draw
  until a turn succeeds.

---

## [1.0.67] — displays as `v1.0.067`

You can now sign in to a provider with an account you already pay for, from
inside OSA, and use it. Before this release you could not: clicking any
provider answered `Failed to load models: HTTP 401`, `/login` did nothing, and
providers that have no API key to paste were labelled "needs key" — a dead end.
Three separate bugs produced that one experience, and all three are fixed.

The picker is now organised the way the choice actually divides: **Connect an
account** for providers you sign in to, **Paste an API key** for providers you
hand a credential. A provider offering both lets you switch between them.

### Fixed — every provider returned HTTP 401 when listing models

- **The models route rejected requests it was supposed to sanitise.** The
  handler's own comment said it strips credential parameters once setup is
  complete; the code rejected the whole request instead. Because the TUI reads
  this route without auth, every provider with a dynamic model catalog answered
  `401` on every set-up machine. This was never specific to ChatGPT — the same
  call failed identically for `anthropic`, `miosa` and `ollama_local`.
- **The same branch could answer with another request's body.** It discarded
  the result of `Plug.Conn.halt/1` and then sent a second response on a conn
  that had already been sent, so concurrent probes could return the *previous*
  request's payload.
- **A keyless provider was treated as a configured one.** Sign-in-only
  providers declare `requires_key: false`, which the picker read as "ready",
  then drilled into a model list for an account nobody had signed into.
  Readiness now comes from the backend's auth state. Keyless is not configured.

### Fixed — a signed-in ChatGPT account silently ran against local Ollama

- **`config/runtime.exs` had no provider-map entry for the account
  providers.** `openai_codex`, `claude_cli`, `copilot_cli` and `bedrock` were
  all absent, and the lookup fell back to `:ollama`. So you could sign in,
  select `gpt-5.2-codex`, restart OSA, and have it ask your local Ollama daemon
  for a model that daemon has never heard of.

### Fixed — reasoning effort did nothing on the Codex transport

- **Only three literal values were accepted.** `low|medium|high` passed;
  `:fast`, `:xhigh` and `:ultra` were dropped silently. Nothing on the turn
  path passed the option through in the first place.
- **Every GPT-5.x model was classified as non-reasoning.** The fallback check
  matched o-series prefixes only, despite a comment claiming GPT-5.x was
  covered — so models whose ids begin with `gpt` answered `false` and were sent
  `temperature` instead of `reasoning_effort`.

### Added — sign in from the TUI

- **`PickerMode::AccountLogin`** renders the verification URL and the device
  code on their own lines, with a live spinner, the provider's anti-phishing
  warning, and Esc-to-cancel that works even before a session id exists.
- **`Auth.LoginBroker`** runs sign-in out of band so the interface never
  blocks: start returns in milliseconds, status polls, cancel goes through the
  existing cooperative cancellation flag. One in-flight sign-in per provider.
  It publishes the user code and URL only — never a token.
- **`OpenAICodex.login/1` gained an `on_verification` callback.** The device
  code was previously recoverable only by scraping it out of console text,
  which is why sign-in worked from `osa setup` and from nowhere else.
- **`/login` opens the provider surface**, `/logout` shares one implementation
  with the CLI, and **`/provider`** now exists.
- **A second, hardcoded capability list was removed.** The Rust picker decided
  auth methods with a `match` on provider id defaulting to "paste a key",
  disagreeing with the backend. Auth methods now derive from `auth_modes`.

### Added — AWS Bedrock

- Sign in with the AWS credentials you already have: environment, or
  `~/.aws/credentials` with `AWS_PROFILE`. A bearer token
  (`AWS_BEARER_TOKEN_BEDROCK`) is the second mode on the same entry.
- **SigV4 is implemented on `:crypto` with no new dependency, and verified
  byte-for-byte against AWS's published `get-vanilla` test vector.**
- **OSA stores no AWS secret.** The marker holds the source, region, pinned
  base URL and the last four characters of the (non-secret) key id;
  credentials are re-read per request, so revoking them ends OSA's access.
- Every credential source is named when resolution fails, including the case
  where a profile uses SSO, `credential_process` or `role_arn` — which OSA
  does not implement — with the command that exports usable credentials.
  A missing region is a hard failure, never a guessed `us-east-1`.
- Uses Bedrock's `Converse` API rather than per-family `invoke` bodies, so one
  request shape covers every model family. Streaming is deliberately not yet
  implemented and falls back to sync.

### Added — Ollama Cloud as an account

- **Selecting Ollama Cloud without a key used to write an unusable config.**
  It set the base URL to `https://ollama.com` with no credential, which fails
  authentication on the first turn. Account mode now resolves to the local
  daemon, so leaving the key blank works.
- The model list comes from the signed-in daemon rather than the shipped
  catalog, because the daemon knows what your account can actually reach.
- OSA reads no private key and signs nothing itself; the daemon remains the
  holder of that credential. `osa` forgetting the account leaves
  `ollama signout` untouched.

### Known gaps in this release

- **No call has been made to a live provider endpoint from this build.** The
  flows, credential shapes and request bodies are verified against stubs and
  recorded fixtures. A completed turn against a real signed-in account is not
  among the evidence.
- **Stacked chrome after a terminal resize is not fixed.** A regression test
  reproducing the reported shape was added and it passes, because the test
  harness does not reflow on resize while real terminals do. Unreproduced,
  not repaired.
- **`claude_cli` still requires Claude Code to be installed and signed in
  beforehand.** Driving that login from inside OSA needs a PTY-backed
  subprocess pane and is not built yet.
- Reversibility — signing out and back in, switching a provider between key
  and account — is not yet exercised end to end.

---

## [1.0.64] — displays as `v1.0.064`

Typing a message that began with the letter `y` lost that letter. So did a
message beginning with `?`. The cause was a pair of undocumented shortcuts —
bare `y` copied the last message, bare `?` opened help — each guarded on "the
composer is empty", which is exactly the state you are in when you start
typing. Only the first character of a message was ever affected, which made it
read as the terminal dropping input rather than as anything OSA did. Both are
fixed, and fixed as a class: printable text now reaches the composer ahead of
every shortcut, so no future binding can take a character out of what you type.

### Fixed — the first letter of a message no longer disappears

- **Printable keys are routed to the composer first.** A key with a printable
  character and no modifier beyond Shift now goes to the composer *before* the
  keybinding map and before every hardcoded shortcut arm. Previously each
  shortcut decided for itself whether to yield, and two of them decided wrong.
  The rule replaces the judgement: an empty composer is no longer a licence for
  anything to claim a typed character.

- **Chord continuations still work.** Only a bare keystroke is treated as text.
  `ctrl+x y` still completes as a chord, because the non-text prefix has
  already established that you meant a command and not a letter.

- **`keybindings.json` now rejects a binding that starts with a plain
  character.** Such a binding could never fire under the new router, so it is
  refused with an explanation — add ctrl/alt, or use a function key — rather
  than accepted and silently ignored.

- **Confirmations are unaffected.** A permission prompt that is on screen and
  waiting for an answer is a distinct state, and its `y`/`n` quick keys consume
  those keys and confirm exactly as before.

### Changed — two shortcuts moved

- **Copy last message is now `F2`, not `y`.** It remains rebindable as
  `chat:copyLast`.

- **`?` no longer opens help from an empty composer.** Help is on `F1` and
  `/help`; `?` now always types a question mark.

- **A wrong line was removed from the in-app shortcut list.** It advertised
  `j`/`k` as scroll keys on an empty input. They never scrolled — they fell
  through to the composer and typed — so the help text described behaviour that
  did not exist.

### Tests

- A sweep over **every printable ASCII character**, unmodified and
  Shift-modified, asserts each one is classified as text and reaches the input
  buffer. Spot-checking `y` and `?` would have left the next letter someone
  binds; the sweep is what keeps this from recurring on a different key.
- Companion tests hold the boundary from the other side: modified characters
  and non-`Char` keys stay shortcuts, terminals that deliver Enter or Tab as
  `Char` are still routed as control keys, no shipped default binding starts
  with a typable character, and a displayed permission prompt still confirms on
  `y` and declines on `n`.

## [1.0.63] — displays as `v1.0.063`

You can now run OSA on a ChatGPT Plus/Pro plan instead of an API key: pick the
provider, choose "connect account", approve in the browser, done. Provider setup
grew a general notion of *how* you want to connect, so a provider that offers
both a sign-in and a key asks once and every setup surface asks it the same way.
Two live security issues are fixed — an Anthropic sign-in OSA should never have
shipped, and two secrets that were readable out of `ps` by any local user. And
the in-app `/setup` provider picker, broken in v1.0.62, works again.

### Added — sign in with your ChatGPT plan

- **`ChatGPT (Codex)` is a new provider entry.** Choose it in `osa setup`, in
  `mix osa.setup.wizard` or in the TUI picker, choose "Sign in with ChatGPT",
  approve in the browser, and the credential is stored and refreshed for you.
  Inference bills against your existing subscription rather than per-token API
  credit.

- **It is a separate provider, not a second auth mode on `openai`.** The two
  differ in more than the credential: a different base URL, a different wire
  protocol, and a Codex-only model list. Same reasoning as the existing
  `ollama_local` / `ollama_cloud` split. The `openai` provider and
  `openai_compat.ex` are byte-for-byte untouched — an OpenAI API key still
  belongs on the `openai` entry, and still behaves exactly as it did.

- **A new Responses-API transport** (`providers/openai_responses.ex`) sits
  alongside the existing chat/completions one rather than replacing it. The two
  protocols disagree on request shape, streaming events and usage keys; a
  working path quietly reshaped by a change aimed at something else is the
  failure mode this project has been bitten by most often.

- **Sign-in runs over the OAuth device flow** (`auth/device_flow.ex`,
  `auth/providers/openai_codex.ex`), with tokens in a 0600 credential store
  separate from your keys, refreshed on use and never written to argv or logs.
  A signed-in provider is badged as configured in the picker exactly like a
  provider with a key in the environment.

- **On the borrowed client id, plainly:** OpenAI publishes no registration path
  for third-party clients here, so this uses the Codex CLI's client id, as every
  other tool offering ChatGPT-plan sign-in does. That is tolerated, not
  licensed, and OpenAI can invalidate it at any time. Unlike the Anthropic flow
  removed in this same release, it is not a documented terms violation and is
  not blocked server-side — that distinction is the whole reason one was deleted
  and this one exists. OSA also sends `osa` as its originator rather than
  claiming to be the Codex CLI.

### Added — provider setup asks how you want to connect

- **`auth_modes` on each provider entry is the single source of truth.** One
  shared fork now drives `osa setup`, `mix osa.setup.wizard` and the TUI picker,
  computed by pure functions (`Onboarding.auth_options/1`, `auth_route_for/2`)
  that all three call. The alternative — one "which providers support sign-in"
  list per surface — is how the tool this was modelled on ended up with three
  lists that disagreed with each other.

- **All 27 existing providers are unchanged.** A provider that declares nothing
  defaults to `[:api_key]` and gets `[]` options back, meaning *do not prompt at
  all*: no extra question, no extra keystroke, identical to before the field
  existed. Verified against a fixture of the pre-change catalog output
  (`test/support/fixtures/providers_list_baseline.exs`), so a future provider
  cannot silently acquire a sign-in prompt it has no implementation for.

- **A failed sign-in never silently switches your billing model.** If sign-in
  fails you are told exactly what happened and, when the provider also takes a
  key, offered that route explicitly. There is no automatic fallback.

### Security — the Anthropic subscription sign-in has been removed

- **OSA shipped an OAuth flow it had no right to ship.** It authenticated
  against `console.anthropic.com` using **Claude Code's first-party client id**
  and sent the subscription request fingerprint. Anthropic's Consumer Terms
  permit automated access only via an Anthropic API key, so the agreement being
  breached was the *user's*, and the account carrying the risk was the user's.
  Anthropic has also blocked it server-side since 2026-01-09, and the token
  endpoint it pointed at now 404s. It has been removed entirely — from
  `osa setup`, `/setup`, `/login`, `/logout`, the HTTP onboarding routes, the
  TUI picker, the desktop onboarding and the Anthropic provider's header
  builder.

- **Stored tokens are deleted on upgrade, with an explanation.** A stale bearer
  credential for a banned, blocked, 404ing flow is worth nothing and is not
  something to leave sitting in a home directory, so `~/.osa/oauth.json` is
  purged at boot and by `osa doctor`. Anyone who was signed in this way gets a
  message naming the API-key replacement rather than an unexplained wall, from
  `osa doctor`, from `/login`, and from the provider's own "no key" error.

- **Anthropic API-key auth is untouched** and is the supported path. The four
  removed HTTP routes answer `410 Gone` with that explanation instead of being
  deleted, so an older desktop or TUI build still calling them says something
  useful rather than 404ing.

- **A duplicate-header bug went with it.** The removed OAuth clause emitted its
  own `anthropic-beta` header, so any request with another beta active carried
  two of them. Betas are now collected in one place and emitted as a single
  comma-joined header, by construction.

### Security — two secrets were readable from `ps`

- **`/proc/<pid>/cmdline` is world-readable on Linux**, and `ps` shows the full
  argument vector to every local user on the machine. Two call sites put a live
  credential there.

- **The Ollama Cloud bearer token, on every single request.** It was passed as
  `-H "Authorization: Bearer <token>"` in curl's argv. It now goes in a 0600
  curl config file passed by path; argv carries nothing sensitive. Both temp
  files are created 0600 *before* anything is written, closing the window in
  which the default umask exposed their contents.

- **The GitHub Actions runner registration token.** It was passed as
  `--token <token>` to `config.sh`. It now travels in
  `ACTIONS_RUNNER_INPUT_TOKEN` — the runner's own documented mechanism, masked
  in its logs and unset after it is read — and a process's environment block is
  owner-readable only.

- **Tree-wide scanners were added so this cannot recur**
  (`test/optimal_system_agent/security/no_secrets_in_argv_test.exs`). They
  assert on the *constructed command*, not on whether the request succeeds: a
  request that works while leaking the token is exactly the bug.

### Fixed — the in-app `/setup` provider picker was broken

- **It was handed `nil` instead of the provider catalog.** `cli/setup.ex` read
  `@providers`, an undefined module attribute that evaluates to `nil` rather
  than failing, so the first step of `/setup` had nothing to list. It now calls
  `providers()`, and a regression test pins the picker's input to the real
  catalog.

---

## [1.0.62] — displays as `v1.0.062`

A community release: three outside contributors found and fixed real bugs. A
fresh install of a prebuilt release now boots against your own home directory
instead of the machine that built it, a session that hit a context compaction
stops failing on every provider forever after, and slash commands work again
over HTTP and in the TUI.

### Fixed — a prebuilt install pointed at the build machine's home

- **Every `~/.osa` path except `config_dir` was frozen at build time.** Found
  and fixed by [@scottlibrando2020](https://github.com/scottlibrando2020) in
  [#99](https://github.com/Miosa-osa/OSA/pull/99). `config/config.exs` derives
  `skills_dir`, `episodic_dir`, `mcp_config_path`, `bootstrap_dir`, `data_dir`,
  `sessions_dir` and the SQLite database path from `Path.expand("~/.osa/...")`,
  which is evaluated during `mix release` on the build host.
  `config/runtime.exs` re-resolved only `config_dir`, so the other seven kept
  the CI runner's home on every install: Exqlite failed to open the database
  with `enoent`, the backend crash-looped before it could persist anything from
  onboarding, and `osa doctor` reported seeded workspace files as missing
  because it was looking in the wrong place. All of them are now derived from
  the same runtime-resolved `config_dir`.

- **The same bug had the test suite writing into your real `~/.osa`.** With
  `config_dir` pointed at a per-run tmp home but `sessions_dir` still frozen to
  `~/.osa/sessions`, every run wrote real session ledgers, briefs and plans into
  the operator's actual home — thousands of files on a developer box. Because
  those files are keyed by an integer unique only within one VM, a later run
  could collide with a leftover ledger and read back a goal it never set, which
  is a genuine cross-run flake source rather than only a tidiness problem.

### Fixed — one context compaction could break a session permanently

- **Compaction wrote a string where every provider requires an object.** Found
  and fixed by [@700steven-png](https://github.com/700steven-png) in
  [#100](https://github.com/Miosa-osa/OSA/pull/100). The compactor stripped
  heavy tool-call arguments by replacing the arguments map with the literal
  string `[args stripped]`. Compacted history is persisted, so the damage was
  permanent and provider-independent: Anthropic answered
  `tool_use.input: Input should be an object`, Ollama answered
  `Value looks like object, but can't find closing '}' symbol`, and because the
  primary provider failed and then every provider in the fallback chain failed
  on the same message, the only error shown was the last hop's — an Ollama parse
  error on a session configured for Anthropic, which switching models could not
  clear.

- **Fixed at the source and at the boundary.** The compactor now writes an empty
  object, and the provider boundary coerces a non-object `arguments` on the way
  out, so sessions already carrying the placeholder on disk heal when they are
  next loaded rather than staying bricked.

- **A fallback hop no longer asks the wrong provider for the wrong model.**
  `opts[:model]` is resolved for the provider the turn started on; forwarding it
  across a hop asked Ollama for `claude-sonnet-5`, so the hop failed for a
  reason unrelated to the original fault — and that impostor was the error
  reported. The model is now dropped on every cross-provider hop while the head
  of the chain keeps it.

- **Ollama no longer crashes on a resumed session's tool calls.** Its message
  formatter used struct-style dot access, which raises `KeyError` on the
  string-keyed tool calls that come back from a persisted session, killing the
  turn before any HTTP request was made.

- **The streaming fallback chain now honours the same non-transient policy as
  the sync path.** An invalid request, bad request shape, auth failure or
  model-not-found is not provider-specific, so re-sending it only produces a
  second, unrelated error from the next provider.

### Fixed — slash commands 500'd over HTTP and in the TUI

- **Every slash command over HTTP crashed.** Found and fixed by
  [@PAMF2](https://github.com/PAMF2) in
  [#98](https://github.com/Miosa-osa/OSA/pull/98). `StringIO.close/1` returns
  `{:ok, {input, output}}`, and the command handler destructured it as
  `{_, captured}`. That matches — `_` binds `:ok` and `captured` binds the inner
  tuple — so nothing failed at the match; it failed one line later in
  `String.replace/4`, which sits outside the surrounding `try/rescue` and so
  escaped as a 500 rather than being converted to an error message. The TUI
  posts every command it does not handle locally to this endpoint.

- **Reattaching to a folder left the session without a live loop.** Also from
  [@PAMF2](https://github.com/PAMF2) in
  [#98](https://github.com/Miosa-osa/OSA/pull/98). A directory-scoped resume
  returned the saved session as `resumed` without starting its loop. Messages
  self-healed, but every route gated on a live loop did not: `GET /:id/context`
  and `POST /:id/steer` both 404'd, so the TUI's context meter died the moment
  it reconnected to its own working directory. The resume path now starts the
  loop, and reports a failure to do so instead of answering `resumed` anyway.

### Fixed — the port preflight's own regression test could never pass

- **The `TIME_WAIT` test from v1.0.60 asserted something the kernel never
  promised.** Linux only lets a bind step over a `TIME_WAIT` when `SO_REUSEADDR`
  is set on both the socket binding now and the socket that left the `TIME_WAIT`
  behind. The fixture created its listener without it, so it failed regardless
  of whether `Port.available?/1` was correct. It now mirrors ThousandIsland,
  which hard-defaults `reuseaddr: true` — the actual production condition — and
  the assertion discriminates: it passes with the fix and fails without it.

---

## [1.0.61] — displays as `v1.0.061`

Auto-extracted memories stopped inventing preferences you never stated.

### Fixed — memory auto-extraction was tuned the wrong way round

- **A false positive is permanent; a false negative costs nothing.** Extracted
  memories are injected into every later turn's context, and the agent can
  always call `memory_save` explicitly, so the extractor is now biased to
  precision. In [#102](https://github.com/Miosa-osa/OSA/pull/102).

- **Machine-authored text is no longer stored as a user preference.** The turn
  pipeline also runs for subagent sessions, where the "user message" is a task
  brief OSA wrote itself; those were being recorded as things you said about
  yourself. Patterns now require explicit standing-preference phrasing — bare
  "I am", "I need", "I want" and "actually" match ordinary task requests far
  more often than durable facts — and only the matching sentence is stored,
  bounded to 12–300 characters, never the whole message.

---

## [1.0.60] — displays as `v1.0.060`

`osa update` can restart the backend again. Two bugs kept a successful rebuild
from ever going live.

### Fixed — a successful update reported that it could not start

- **The stop path killed the launcher and left the BEAM holding the port.** In
  [#101](https://github.com/Miosa-osa/OSA/pull/101). `stop_daemon` signalled the
  pidfile PID's process group, but `mix` can re-exec `beam.smp` into a group of
  its own: the launcher died, the group kill found nothing left to reap, and the
  BEAM kept the listener on `:9089`. The update then correctly refused to claim
  it was live, and the user was told to run `osa stop` by hand — after seeing
  "Backend stopped" immediately above. The port, not the PID, is the contract,
  so the stop path now reclaims it by ownership and waits on the LISTEN socket
  rather than on `/health`.

- **The boot preflight then rejected the restart anyway.** `Port.available?/1`
  probed without `SO_REUSEADDR` while ThousandIsland hard-defaults it to `true`,
  so a `TIME_WAIT` left by a closed connection counted as an occupied port for
  roughly 30 seconds after every restart.

---

## [1.0.59] — displays as `v1.0.059`

An idle OSA now costs essentially nothing. Leaving the daemon running no longer
shows up as a busy core on your machine — it sits at a tenth of a percent of one
CPU instead of pinning several, with no change to how fast it answers.

### Fixed — an idle daemon was burning CPU on every platform

- **A daemon that was doing nothing still ran hot.** Reported by
  [@jmanhype](https://github.com/jmanhype) in
  [#66](https://github.com/Miosa-osa/OSA/issues/66) as 850% CPU on macOS with no
  work in flight. The cause was not OSA's own loops: the BEAM's scheduler
  busy-wait flags were set nowhere in the tree, so every OSA daemon everywhere
  ran on stock OTP defaults, where idle schedulers spin looking for work rather
  than sleeping. On a machine with many cores that is one hot spin loop per
  core, forever, for an agent sitting at a prompt.

- **The flags are now set on every path a real daemon starts from** — the
  release environment script, its Windows equivalent, and the source-tree
  launcher. That last one mattered most and is easy to miss: it never sources
  the release environment at all, and it was the reporter's own reproduction
  path, so a fix applied only to the release would have left the bug exactly
  where it was found. Measured on Linux, idle CPU falls from 0.32% to 0.10%,
  with request latency unchanged within noise.

- **The old behaviour is one environment variable away.** Set
  `OSA_BEAM_BUSY_WAIT=1` to restore spinning schedulers, for the rare workload
  that would rather pay the idle cost to shave scheduler wake-up latency.

### Fixed — the test suite was writing into your real `~/.osa`, and reading it back

- **A goal from one test run could reappear inside a later one.** The suite goes
  to considerable lengths to keep out of the operator's home — the database,
  permissions, the durable log and the bootstrap directory are all redirected to
  temporary paths — but the runtime configuration re-pointed the config directory
  at the real `~/.osa` after all of that had been decided, silently undoing it.
  Session ledgers, briefs and plans were being written into the operator's own
  session directory on every run, thousands of them; and because those files are
  keyed by an identifier that is only unique *within* one VM, a later run could
  draw an identifier that already had a file on disk and read back a goal it had
  never set. That is what made the goal-verifier's "no goal anywhere" gate fail
  in a full run and pass on its own. **The suite now gets its own per-run home
  under the temporary directory**, wiped at load and swept for stale runs, using
  the same scheme the per-run test database already used. Nothing about how OSA
  resolves its home outside of tests changes.

- **Six test files hardcoded `~/.osa` themselves**, as compile-time paths — the
  exact "frozen home" pattern OSA has a dedicated regression test to forbid in
  its own modules. They now resolve the directory at runtime like everything
  else, so they assert against the suite's home rather than the operator's.

- **Cross-turn goal state no longer lives on a borrowed process.** The table
  holding each session's goal status, lifetime run cap and stall breaker was
  created lazily by whichever process anchored a goal first — usually a
  transient one. When that process exited the table went with it, and an
  autonomous run lost its circuit breaker without anything failing loudly. It is
  now created at startup, owned by the application, alongside the other shared
  tables that were moved there for the same reason.

---

## [1.0.58] — displays as `v1.0.058`

OSA's context handling, its tool surface and its record of what a session did
are no longer fixed at compile time: each is now something that can be swapped,
extended or switched on. Nothing here changes what OSA does by default — the two
new capabilities are off until you turn them on. Alongside that, the interface
gains a test lane that drives the real binary on a real terminal, the last
hand-written layout measurements are gone, and a turn that dies no longer takes
its spend with it.

> **This release supersedes `v1.1.000` and `v1.1.001`, which have been
> withdrawn.** Those two were published briefly and carried exactly the content
> below under an incorrect version number; the minor bump was a mistake, and
> OSA's numbering continues on the `1.0.x` line. If you installed OSA in that
> window you are running this same code under a version string that no longer
> exists — reinstall, or pin `OSA_VERSION=v1.0.058`, so that update checks and
> bug reports line up with a release that is actually published.

### Added — the context engine is now a contract, not a single hardcoded implementation

- **Everything that manages the conversation window now goes through one
  interface.** Compaction — deciding when a session has grown too large, what to
  summarize, and what to keep verbatim — was reachable only as one concrete
  module, called directly from seven places. It is now expressed as a behaviour
  with a router in front of it, resolved from application config or
  `config.toml`, so an alternative strategy can be supplied without touching the
  call sites. The existing compactor is unchanged in behaviour and remains the
  default; a no-op engine ships alongside it as a reference implementation.

- **The contract states the units it actually uses.** While wiring this up, the
  declared interface was found to disagree with the code on both sides of it:
  utilization was documented as a fraction while every implementation and every
  reader treated it as a percentage, and the summary formatter was declared to
  return a message list while both implementations returned a string. An engine
  written against the old description would have read a full session as roughly
  one percent full and never compacted. The declaration now matches reality, and
  a router that could not resolve a model's real context window no longer falls
  back to a fabricated one — it reports that the figure is unknown rather than a
  confident wrong number.

### Added — plugins, off by default and verified before anything is loaded

- **OSA can discover and load tools and context engines from
  `~/.osa/plugins/`.** This is **opt-in and disabled by default**: it must be
  enabled explicitly through application config, `[plugins]` in
  `~/.osa/config.toml`, or the user-level `settings.json`. When it is off, no
  directory is created and nothing is read.

- **A project cannot switch it on for you.** The opt-in is read from the *user*
  settings layer only, never the merged cascade — a repository that shipped both
  the flag and a plugin file would otherwise have gained code execution the
  moment you changed directory into it. Workspace-supplied settings cannot
  enable plugin loading at any trust level.

- **Files are verified before they are compiled.** The plugin directory must
  exist, be a directory, be owned by you, and not be writable by anyone else;
  files must be regular, owned by you, and within a size limit; symlinks are
  resolved and refused when they point outside the directory. Every refusal is
  logged with the file and the reason, and the ownership check fails closed when
  it cannot determine the answer.

- **A plugin cannot impersonate a built-in or grant itself privileges.** A
  plugin tool whose name collides with a registered tool is refused rather than
  replacing it, built-in engine ids cannot be claimed, and plugin-contributed
  tools are tracked by provenance and forced onto the approval path regardless
  of the safety level they declare for themselves. A plugin that fails to
  register now costs only itself: registration failures are contained, including
  the timeout case, which previously escaped and would have taken the boot down
  with it.

### Added — trajectory recording, off by default and redacted

- **Each LLM round-trip in a session can be recorded to
  `~/.osa/trajectories/`** — tokens, cost, tool calls and results — for replaying
  or auditing what a session actually did. Like plugins, it is **opt-in and off
  by default**, with a retention window that prunes old files at boot.

- **Credentials are stripped before anything is written.** Tool arguments, tool
  results and assistant responses pass through redaction — provider keys, GitHub
  and Slack tokens, AWS key ids, JWTs, `Bearer`/`Basic` headers and
  credential-shaped assignments — and redaction runs before truncation, so a
  secret cannot survive by being cut in half.

### Added — a layout suite that drives the real binary on a real terminal

- **The worst bug of the last release passed a thousand tests.** A terminal
  resize left one stranded copy of the interface behind at every step of a drag,
  and the existing suite structurally could not see it: it renders through a
  perfect in-process emulator that answers the cursor query from its own model,
  so the re-anchor always lands on the right row and the failure cannot
  materialise. Tests were not missing. The class was unreachable.

- **`test/pty/` closes that from the outside.** It gives the built `osagent` a
  real kernel PTY, resizes it for real — the same signal a window drag delivers —
  renders the resulting byte stream through an independent emulator, and asserts
  that exactly one composer, one hint row and one status bar survive. Three
  cases ship: a width drag, a height drag, and a viewport squeezed to eight rows
  where the composer must still be there. It runs in CI as the `PTY layout`
  workflow, on a plain runner — a PTY is not a GUI, so no display server is
  needed.

- **It was verified by putting the bug back.** Reintroducing the defect turns
  the suite red with several stacked composers, which is what a test that cannot
  fail is missing.

- **What a green run does not prove.** The emulator the harness renders through
  does not re-wrap existing lines when the terminal narrows; GNOME Terminal and
  the other libvte-backed terminals do. So this reproduces the re-anchor half of
  the problem — the half that produced the stacked copies — and under-reproduces
  the reflow half. Concretely, the deliberate choice of clear sequence at the
  resize site, which exists because one of them pushes a snapshot of the live
  region into unreflowable scrollback on a real terminal, would not turn this
  suite red if it were reverted. Changes touching reflow, scrollback or clear
  semantics still want a human looking at a real terminal. The limitation is
  written down in `test/pty/README.md` rather than left to be discovered.

### Changed — one arbiter measures the layout, and the tests can no longer disagree with it

- **The last hand-written band-height helpers are gone.** Four of them survived
  the previous release as test-only functions, each re-stating in a second place
  how tall one band should be. A test that mirrors an expression production has
  stopped using does not check production — it checks the mirror, and passes
  while the screen is wrong. Every measurement now goes through the single
  arbiter the running program uses.

- **The small-height assertions came out stronger, not weaker.** Where the
  mirror sized a band against the rows it *asked* for, it now sizes against the
  rows the arbiter *granted*. On a short viewport those differ, and sizing
  against the request is exactly how a band ends up drawing into rows nothing
  reserved for it.

### Fixed — recording that was supposed to be off was always on

- **The trajectory opt-in never guarded anything.** The check was written as an
  expression whose result was evaluated and then discarded, so the write ran
  unconditionally: trajectory recording was **always on for every user**, despite
  being documented and configured as disabled by default. Since each entry
  carries the assistant response along with raw tool arguments and results, every
  session was appending unredacted conversation content to disk with no way to
  turn it off. The guard is now a real branch, and the content it writes is
  redacted.

### Fixed — every turn was recorded as having cost nothing

- **The transcript recorded zero tokens for all of them.** Per-turn token counts
  are now written as the turn completes, cached tokens included — without those,
  a large turn was recorded as a small one and the figure *fell* as the cache
  warmed, which is exactly backwards. Plan-mode turns, which are often the most
  expensive in a session, recorded nothing at all and are now counted like any
  other. This is groundwork: the figures are recorded, but nothing reads them
  yet, so `/cost` and `/status` are unchanged for now.

### Fixed — a reconnect announced a coordinator change that never happened

- **Losing and regaining the connection raised a notification about a switch
  that had not occurred.** The reconnect path re-announced the coordinator mode
  unconditionally rather than only when it had actually changed. Because an
  identical notification refreshes its dwell instead of stacking, a flapping
  connection could hold a phantom notification on screen indefinitely, and each
  one rebuilt the viewport twice. The announcement is now made only on a real
  change.

### Fixed — a turn that crashed took its spend with it

- **Tokens that had been paid for vanished from the accounting.** When a turn
  errored partway through, the error path returned the state from before the
  turn began — every intermediate state having been carried off by the unwind —
  so a turn that completed three billed round-trips and then failed on the
  fourth was recorded as having cost nothing. The transcript wrote a zero, the
  live spend readout never moved, and the session budget cap went on believing
  the money was still there.

- **The accounting now survives the crash.** Each round-trip's absolute totals
  are surrendered outside the state thread and merged back if the turn dies, so
  the spend that happened is the spend that gets reported. Absolute figures, not
  increments, so a repeated merge cannot double-bill; and the stash is cleared at
  the top of every turn so a turn that fails before spending anything cannot
  inherit the previous one's numbers.

- **Deliberately not recovered: the conversation.** Only the accounting is
  merged back. A message list interrupted mid-cycle can be structurally invalid
  — an assistant tool call with no matching result — and restoring it would
  poison the next request to the provider. Recovering history is a separate and
  larger problem; recovering the money is not, and the money is what was
  silently wrong.

---

## [1.0.57] — displays as `v1.0.057`

### Fixed — resizing the terminal left a stranded copy of the interface behind at every step

- **A single drag could leave nine stacked composers on screen.** Widening the
  window by nine columns left nine copies of the live region, each one column wider
  than the one above it, all of them stale and none of them reflowing. Two separate
  causes, both fixed. First, OSA only learned that the terminal had changed size
  when the resize *event* arrived — but the kernel had already changed the size, and
  every frame drawn in that gap was reconciled behind OSA's back by ratatui, which
  re-anchors the live region and clears only the *new* rectangle, leaving the old
  one painted on the screen. **OSA now takes the size directly from the kernel at
  the top of every frame**, so it is always the first to know rather than the last.

- **A drag now settles before anything is drawn or committed.** Dragging a window
  edge emits a size for every intermediate width, and OSA was rebuilding — and
  committing finished output — at each one, at widths that had already ceased to
  exist by the time the ink landed. The intermediate sizes are now absorbed and only
  the size the drag comes to rest at is drawn.

### Fixed — the interface now fits any terminal

- **Regions could overlap, overdraw, and disagree about their own size.** Each of
  the ten regions of the live area claimed its rows independently, with nothing
  deciding what actually fit in the space available; in a short or narrow terminal
  that produced a checklist painted on top of the reply, a roster reserving thirty
  rows and drawing thirty-four, and a dropdown painting into rows nothing had set
  aside. **All ten regions are now measured by a single arbiter** that grants rows
  and, when space runs out, sheds the least important surfaces in a fixed order —
  never the composer, which is always kept.

- **Heights are measured once and the rectangles derived from them**, so a region's
  reservation and its paint cannot drift apart. The property is enforced by tests
  rather than by discipline: the bands are swept across a range of widths, heights
  and content states and asserted to tile the region exactly — no row shared, no row
  lost — and a check over the source tree fails the build if the terminal size is
  read anywhere other than the one place permitted to read it.

### Fixed — the startup banner could name a model OSA was not running

- **The banner reported `anthropic / llama3.2:latest` directly above a status bar
  reading `claude-opus-5`.** Provider and model were resolved from different sources
  at boot, so a provider chosen from the environment could be paired with a model
  persisted in the config file for an entirely different provider. A model saved for
  one provider is no longer stapled onto another; when it does not apply, OSA falls
  back to that provider's own default, so the pair is coherent by construction.

- **The same false pair reached everything else that names the model.** The settings
  dialog, the dashboard, the model picker and the agent's own prompt each rebuilt the
  answer by hand, and each fell back to an Ollama model — down to a hardcoded
  `llama3.2:latest` — regardless of which provider was serving the turn. **Every
  identity surface now reads one resolver**, so what the banner, the status bar, the
  picker and the agent believe about the running model cannot disagree.

---

## [1.0.56] — displays as `v1.0.056`

### Fixed — replies start faster, because the unchanging part of every prompt is finally cached

- **Every request to the Claude models was re-reading the entire prompt from scratch.**
  The large, unchanging preamble OSA sends on every turn — the instructions, your
  project's context, the tool descriptions, tens of thousands of tokens of it — is
  meant to be cached by the provider and skipped on the next turn. None of it ever
  was. The cache hit rate was a flat zero for every request OSA has ever sent, so
  each turn paid the full cost, in time and in tokens, of material that had not
  changed since the previous one. **That prefix is now genuinely cached**, so a reply
  begins sooner and the repeated part of the prompt is no longer billed at full
  price on every turn.

- **The cause was a timestamp buried inside the cached region.** OSA builds the
  prompt as three parts — a static base, a slowly-changing world state, and a
  volatile tail carrying the clock and the turn count — precisely so the first two
  can be cached and the third cannot. Two separate steps on the way to the wire
  undid that: one dropped the cache markers, and the next flattened all three parts
  into a single block, which was then marked as cacheable *as a whole*. Since that
  now-cached block contained a microsecond-resolution timestamp, every request
  differed from the last by a few bytes at exactly the point where a cache lookup
  needs them to be identical, and nothing could ever match. The three parts now stay
  three parts, the volatile tail sits outside every cached region, and the timestamp
  is rounded to the second.

- **Verified on the wire, not inferred.** Two consecutive real requests are captured
  and the cached prefix compared byte for byte: 137,974 bytes, identical, same
  sha256 — with a control assertion that the volatile tail *does* differ between
  them, so the comparison cannot pass by accident.

### Fixed — image attachments and provider fallback no longer fail outside the Claude models

- **Attaching an image crashed every non-Claude provider.** Images are packaged in
  the Claude models' structured format regardless of which provider is actually
  serving the request, and the other five providers accept only plain text; handed a
  structured block, they raised outright. Any turn with an image attached failed on
  OpenAI, Google, Ollama, Cohere and Replicate — not degraded, crashed.

- **Provider fallback was dead in the one situation it exists for.** When Claude
  returns a 5xx, OSA is supposed to retry the request on another provider. It handed
  that provider the already-built message list, which crashed it the same way, and
  each crash was swallowed and reported as the generic "All providers failed" — so
  an outage at one provider took the whole turn down instead of falling through to a
  working one.

- **Content is now translated at the provider boundary.** Structured content is
  flattened losslessly for the providers that need plain text and passed through
  untouched for the ones that do not. A flattened prompt is byte-identical to what
  those providers received before, so nothing about their behaviour changes. An
  image, which has no text equivalent, becomes an explicit note that it was omitted
  — the model is told the image is missing rather than left to invent it.

### Fixed — a rate-limiter test that could fail on timing alone

- **The HTTP rate limiter's test suite raced the wall clock and intermittently
  reddened an otherwise green run.** The limiter refills its budget in proportion to
  elapsed time, which at the default 60-per-minute limit hands back a whole request
  for every whole second that passes. A test that spent 60 requests and then checked
  the 61st was refused would get an extra one for free whenever those 60 requests
  happened to straddle a second tick — likely on a loaded machine — and the request
  that should have been refused sailed through. **The limiter's clock is now
  injectable**, so the tests pin it and step it deliberately rather than depending on
  how fast the machine happens to be. The limiter's behaviour in production is
  unchanged; two new tests cover refill over time explicitly.

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
