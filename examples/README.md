# Customize Your OSA

OSA ships with sensible defaults and works out of the box. These examples show how to
make it **yours** — your identity, your schedule, your skills, your channels. Every file
here is a template: copy the ones you want into `~/.osa/`, edit them, and restart OSA to
pick up the changes.

Configuration lives in `~/.osa/`. Secrets (API keys, bot tokens) live only in
`~/.osa/.env` — never in the JSON config files.

## What each example does

| Example | Copy to | Purpose |
|---------|---------|---------|
| `config.json` | `~/.osa/config.json` | Provider/model, working dir, `machines` skill sets, `os.scan_paths`, `budgets`, and `channels`. Only known keys are read; secrets stay in `.env`. |
| `.env.example` | `~/.osa/.env` | LLM provider API keys and channel bot tokens. Only the provider section is required to start. |
| `bootstrap/IDENTITY.md` | `~/.osa/IDENTITY.md` | The agent's personal identity — name, creature, vibe, emoji. Short and evolves over time. |
| `bootstrap/SOUL.md` | `~/.osa/SOUL.md` | The agent's voice and values — how it talks, what it never says, how it calibrates to signal weight. |
| `bootstrap/USER.md` | `~/.osa/USER.md` | Your profile — role, preferences, working hours, projects, contacts. OSA reads it at boot and fills in blanks as it learns you. |
| `HEARTBEAT.md` | `~/.osa/HEARTBEAT.md` | Proactive checkbox tasks. OSA runs every unchecked `- [ ]` line every 30 minutes, then flips it to `- [x]` in place. |
| `CRONS.json` | `~/.osa/CRONS.json` | Scheduled jobs on a 5-field cron. Each job is type `agent`, `command`, or `webhook`. |
| `TRIGGERS.json` | `~/.osa/TRIGGERS.json` | Event-driven jobs — either an internal bus event, or an external `POST /webhooks/<id>` on port `9089`. |
| `skills/<name>/SKILL.md` | `~/.osa/skills/<name>/SKILL.md` | A reusable skill: YAML frontmatter (`name`, `description`, `tools`) plus a Markdown instruction body. |
| `workflows/<id>.json` | `~/.osa/workflows/<id>.json` | A multi-step template — an ordered `steps[]` array of `name`, `description`, `tools_needed`, `acceptance_criteria`. |

> `SYSTEM.md` is the bundled primary prompt (it lives in `priv/prompts/`). IDENTITY, SOUL,
> and USER are injected into it via `{{IDENTITY_PROFILE}}`, and `{{USER_PROFILE}}` slots —
> you don't copy SYSTEM.md yourself.

## The building blocks in detail

**Scheduling — `CRONS.json`.** Time-based jobs. `agent` jobs run a plain-English `job`
through the agent loop; `command` jobs run a shell `command`; `webhook` jobs hit a `url`
and can hand off to the agent `on_failure`. A job that fails 3 times in a row is
auto-disabled (circuit breaker).

**Reacting — `TRIGGERS.json`.** Event-based jobs. Internal-bus triggers fire on OSA events
(e.g. `channel_connected`, `algedonic_alert`, `doom_loop_halt`). External triggers fire when
you POST a JSON body to `http://<host>:9089/webhooks/<id>`. Job templates support
`{{payload}}`, `{{payload.key}}`, and `{{timestamp}}`.

**Being proactive — `HEARTBEAT.md`.** The lowest-friction automation: just write tasks as
`- [ ]` lines with a clear action and an output file path. Checked every 30 minutes.

**Skills** package repeatable expertise (the bundled set includes `daily-briefing`,
`email-assistant`, `sales-pipeline`, `customer-support`, `meeting-prep`, `research-assistant`,
`content-writer`, `code-review`). **Workflows** encode multi-step processes with acceptance
criteria (`code-review`, `debug-production-issue`, `build-rest-api`, `build-fullstack-app`,
`content-campaign`).

## Quickest start

1. **Configure the provider.**
   ```
   cp examples/config.json ~/.osa/config.json
   cp examples/.env.example ~/.osa/.env
   ```
   Set `provider` and `model` in `config.json`, and the matching API key in `.env`.
   (Defaults to local Ollama — free, no key needed.)

2. **Make it yours.** Copy `bootstrap/IDENTITY.md` and `bootstrap/USER.md` into `~/.osa/`
   and fill them in — even just your name, role, and timezone. OSA evolves both files as it
   learns you, so blanks get filled over time.

3. **Give it one job.** Pick either:
   - a skill — `cp -r examples/skills/daily-briefing ~/.osa/skills/`, or
   - a heartbeat task — add one `- [ ]` line to `~/.osa/HEARTBEAT.md`, e.g.
     `- [ ] Check disk space; if under 10GB free, write an alert to ~/.osa/alerts/system.md`

4. **Restart OSA.** Config and identity are re-read on start, so your changes take effect.

Add crons, triggers, more skills, and channels incrementally — nothing here is required
all at once. Start small; grow the harness as you learn what you want OSA to do.
