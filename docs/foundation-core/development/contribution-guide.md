# Contribution Guide

Audience: anyone who wants to contribute code, skills, commands, agents, or documentation to OSA.

## Contribution Types

| Type | Elixir Required | Review Speed |
|------|----------------|--------------|
| SKILL.md skill | No | Fast |
| Command template | No | Fast |
| Agent definition | No | Fast |
| Swarm pattern | No | Fast |
| Documentation | No | Fast |
| Hook | Yes | Moderate |
| Elixir module skill | Yes | Moderate |
| Bug fix | Yes | Fast |
| New LLM provider | Yes | Moderate |
| New channel adapter | Yes | Slower |
| Core engine change | Yes | Careful review |

No-code contributions (skills, commands, agent definitions) are the most impactful path for most contributors. A well-written SKILL.md that solves a real workflow problem is more valuable to the community than many code changes.

## Fork and Branch Workflow

1. Fork the repository on GitHub.
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/OSA.git
   cd OSA
   ```
3. Add the upstream remote:
   ```bash
   git remote add upstream https://github.com/Miosa-osa/OSA.git
   ```
4. Create a feature branch from `main`. Use a name that reflects the change:
   ```bash
   git checkout -b feat/groq-provider
   git checkout -b fix/nil-session-id-loop
   git checkout -b skill/invoice-generator
   ```
5. Keep your branch up to date with upstream before opening a PR:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

## Before You Commit

Run these two commands before every commit:

```bash
mix format       # Reformats all .ex and .exs files in place
mix test         # Must pass with 0 failures
```

There are no pre-commit hooks in the repository. It is your responsibility to run these before pushing.

## Commit Message Format

Use the prefix format from `CONTRIBUTING.md`:

```
[type] Short imperative description under 72 characters

Optional longer explanation in the body. Wrap at 72 characters.
Reference issues with: Closes #123
```

Valid types:

| Prefix | When to use |
|--------|------------|
| `[skill]` | Adding or updating a SKILL.md or Elixir skill module |
| `[hook]` | Adding or modifying a hook |
| `[agent]` | Adding or modifying an agent definition |
| `[cmd]` | Adding or modifying a slash command template |
| `[fix]` | Bug fix |
| `[feat]` | New feature |
| `[docs]` | Documentation only |
| `[refactor]` | Code restructuring without behaviour change |
| `[test]` | Tests only |
| `[chore]` | Dependency bumps, CI changes, build scripts |

Examples:

```
[feat] Add Groq provider with tool_use support
[fix] Handle nil session_id in Loop.process_message
[skill] Add invoice-generator skill with PDF output
[docs] Document Vault memory lifecycle
```

## Opening a Pull Request

1. Push your branch to your fork:
   ```bash
   git push -u origin feat/groq-provider
   ```
2. Open a PR against `main` on the upstream repository.
3. Fill in the PR description with:
   - **What** the change does
   - **Why** it is needed (link to an issue if one exists)
   - **How you tested it** (test output, manual steps)

Keep PRs focused. One feature or fix per PR. Reviewers can review focused changes faster and with higher quality.

## Code Review Expectations

### For authors

- Address all review comments before marking conversations as resolved.
- If you disagree with a comment, explain your reasoning. Discussion is welcome.
- Do not push force-over your branch after a review round starts unless asked to rebase.

### For reviewers

Reviews check:

- Correctness — does the code do what the description claims?
- Tests — are new behaviours covered? Are edge cases tested?
- Style — does the code follow the conventions in `coding-standards.md`?
- Docs — are new public functions documented with `@doc` and `@spec`?
- No regressions — `mix test` passes on the branch.

## CI Requirements

There is no automatic CI on pull requests at present. The CI pipeline (`release.yml`) runs on version tags only and produces release binaries for Linux (x64), macOS (arm64), and Windows (x64).

Contributors must verify locally before opening a PR:

```bash
mix test        # 0 failures required
mix format      # no diff after formatting
```

If you are adding a Go tokenizer change, also verify:

```bash
cd priv/go/tokenizer
CGO_ENABLED=0 go build -o osa-tokenizer .
```

## Adding a Skill (Elixir Module)

1. Create `lib/optimal_system_agent/skills/builtins/your_skill.ex`.
2. Implement the four callbacks from `OptimalSystemAgent.Skills.Behaviour`: `name/0`, `description/0`, `parameters/0`, `execute/1`.
3. Register in `lib/optimal_system_agent/skills/registry.ex` → `load_builtin_skills/0`.
4. Add a dispatch clause in `dispatch_builtin/2`.
5. Write tests in `test/optimal_system_agent/skills/builtins/your_skill_test.exs`.

The `execute/1` function must return `{:ok, String.t()}` or `{:error, String.t()}`. The agent renders these directly in conversation.

## Adding a SKILL.md (No Code)

Drop a markdown file in `priv/skills/` (shipped with the application) or `~/.osa/skills/your-skill/SKILL.md` (user-local). Files in `priv/skills/` must be submitted via PR.

Required frontmatter:

```yaml
---
name: your-skill-name
description: One sentence the LLM reads to decide when to activate this skill.
tools:
  - file_read
  - web_search
triggers:
  - "keyword phrase"
priority: 50
---
```

Checklist before submitting:

- [ ] Name is descriptive and lowercase-hyphenated
- [ ] Description is one specific sentence (the model reads it for routing)
- [ ] Instructions are under 500 words
- [ ] Examples cover at least 3 scenarios
- [ ] Tools list includes only what the skill actually needs
- [ ] Tested locally with `mix chat`

## Adding a Slash Command

Command templates live in `priv/commands/{category}/`. The filename (without extension) becomes the slash command name. Add your `.md` file and wire the command name in `lib/optimal_system_agent/commands.ex`.

Categories: `workflow/`, `context/`, `security/`, `memory/`, `utility/`.

## Community

- Bug reports and feature requests: [GitHub Issues](https://github.com/Miosa-osa/OSA/issues)
- Questions and ideas: [GitHub Discussions](https://github.com/Miosa-osa/OSA/discussions)
- Skills showcase: submit to `priv/skills/` or `examples/skills/` via PR

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
