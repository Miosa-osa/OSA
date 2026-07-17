# OSA Recipe System — Reference Guide

> **⚠️ STATUS: PLANNED / NOT YET IMPLEMENTED.** As of v1.0.3 there is **no recipe
> loader, runner, or `/recipe` command in `lib/`** — no `Recipe` module exists and
> nothing reads the recipe files. The recipe **JSON definitions do exist** on disk
> (`priv/recipes/*.json`, `examples/workflows/*.json`), but they are inert data with
> no code to execute them. Everything below describes the *intended* design of the
> recipe system, not shipping behavior. The `/recipe`, `/recipe <slug>`, and
> `/recipe-create` commands are not wired up.

> Recipes are multi-step guided workflows that run in a **fresh session** with full context available.  
> Run any recipe with: `/recipe <slug>` *(planned)*  
> List all recipes with: `/recipe` *(planned)*

---

## How Recipes Work

1. You type `/recipe <slug>` in the TUI
2. OSA creates a **brand-new session** (0% context) so history never bleeds in
3. The recipe prompt is submitted — compact single-line format, ~50 tokens
4. The agent works through each step using the tools defined in the recipe JSON
5. Each step has an **acceptance criteria** — the agent knows when a step is done before moving on
6. On completion, a `recipe_completed` event is emitted to the event bus

**Session flow:**
```
/recipe → new_session_prompt → SessionCreated → start_sse() → SseConnected → submit_prompt
```

---

## Recipe Resolution Order

Recipes are resolved in priority order (first match wins):

| Priority | Location | Purpose |
|---|---|---|
| 1 | `~/.osa/recipes/` | Your personal custom recipes |
| 2 | `.osa/recipes/` | Project-specific recipes |
| 3 | `priv/recipes/` | OSA built-in canonical recipes |
| 4 | `examples/workflows/` | Example/demo recipes (fallback) |

---

## Signal Modes

Each step declares a signal mode that controls how the agent reasons:

| Mode | Meaning |
|---|---|
| `ANALYZE` | Read, reason, document — no code written |
| `BUILD` | Write code, create files, implement |
| `EXECUTE` | Run commands, deploy, verify |
| `ASSIST` | Compile findings, write summaries, provide feedback |

---

## Built-In Recipes

### `/recipe code-review`
**File:** `examples/workflows/code-review.json`  
**Description:** Systematic code review — understand changes, check correctness, audit security, review performance, deliver structured feedback.

| # | Step | Mode | Tools |
|---|---|---|---|
| 1 | Understand the Changes | ANALYZE | file_read, shell_execute |
| 2 | Check Correctness | ANALYZE | file_read |
| 3 | Security Audit | ANALYZE | file_read, web_search |
| 4 | Performance Review | ANALYZE | file_read |
| 5 | Provide Feedback | ASSIST | file_write |

**Prompt sent:** `Run recipe: Code Review. Steps in order: Understand the Changes, Check Correctness, Security Audit, Performance Review, Provide Feedback. Start with step 1.`

---

### `/recipe build-rest-api`
**File:** `examples/workflows/build-rest-api.json`  
**Description:** Build a complete REST API from requirements to deployment.

| # | Step | Mode | Tools |
|---|---|---|---|
| 1 | Requirements Gathering | ANALYZE | file_read, web_search |
| 2 | Architecture Design | BUILD | file_write |
| 3 | Project Setup | EXECUTE | shell_execute, file_write |
| 4 | Data Models | BUILD | file_write, shell_execute |
| 5 | API Endpoints | BUILD | file_write, file_read |
| 6 | Authentication | BUILD | file_write, file_read |
| 7 | Testing | BUILD | file_write, shell_execute |
| 8 | Documentation | BUILD | file_write |
| 9 | Deployment Setup | EXECUTE | file_write, shell_execute |

**Prompt sent:** `Run recipe: Build a REST API. Steps in order: Requirements Gathering, Architecture Design, Project Setup, Data Models, API Endpoints, Authentication, Testing, Documentation, Deployment Setup. Start with step 1.`

---

### `/recipe build-fullstack-app`
**File:** `examples/workflows/build-fullstack-app.json`  
**Description:** Build a complete full-stack application with frontend, backend, database, and deployment.

| # | Step | Mode | Tools |
|---|---|---|---|
| 1 | Requirements & User Stories | ANALYZE | file_write, web_search |
| 2 | Architecture & Tech Stack | BUILD | file_write, web_search |
| 3 | Database Design & Setup | BUILD | file_write, shell_execute |
| 4 | Backend API Implementation | BUILD | file_write, shell_execute, file_read |
| 5 | Frontend Scaffolding & Routing | BUILD | file_write, shell_execute |
| 6 | Frontend UI Implementation | BUILD | file_write, file_read |
| 7 | Frontend-Backend Integration | BUILD | file_write, file_read, shell_execute |
| 8 | Testing Suite | BUILD | file_write, shell_execute |
| 9 | Polish & Error Handling | BUILD | file_write, file_read |
| 10 | Deployment & DevOps | EXECUTE | file_write, shell_execute |

**Prompt sent:** `Run recipe: Build a Full-Stack Application. Steps in order: Requirements & User Stories, Architecture & Tech Stack, Database Design & Setup, Backend API Implementation, Frontend Scaffolding & Routing, Frontend UI Implementation, Frontend-Backend Integration, Testing Suite, Polish & Error Handling, Deployment & DevOps. Start with step 1.`

---

### `/recipe debug-production-issue`
**File:** `examples/workflows/debug-production-issue.json`  
**Description:** Systematic debugging — reproduce, isolate, hypothesize, test, fix, verify, prevent.

| # | Step | Mode | Tools |
|---|---|---|---|
| 1 | Reproduce the Issue | ANALYZE | shell_execute, file_read, web_search |
| 2 | Isolate the Scope | ANALYZE | shell_execute, file_read |
| 3 | Form Hypotheses | ANALYZE | file_read, web_search |
| 4 | Test Hypotheses | EXECUTE | shell_execute, file_write, file_read |
| 5 | Implement Fix | BUILD | file_write, file_read |
| 6 | Verify Fix | EXECUTE | shell_execute |
| 7 | Write Regression Test | BUILD | file_write, shell_execute |
| 8 | Post-Mortem | ASSIST | file_write |

**Prompt sent:** `Run recipe: Debug a Production Issue. Steps in order: Reproduce the Issue, Isolate the Scope, Form Hypotheses, Test Hypotheses, Implement Fix, Verify Fix, Write Regression Test, Post-Mortem. Start with step 1.`

---

### `/recipe content-campaign`
**File:** `examples/workflows/content-campaign.json`  
**Description:** Plan and execute a content marketing campaign from research through promotion and analysis.

| # | Step | Mode | Tools |
|---|---|---|---|
| 1 | Audience Research | ANALYZE | web_search, file_write |
| 2 | Content Strategy & Outline | BUILD | file_write |
| 3 | Draft Content | BUILD | file_write, web_search |
| 4 | Edit & Refine | ANALYZE | file_read, file_write |
| 5 | Publish & Schedule | EXECUTE | file_write, shell_execute |
| 6 | Promote & Distribute | EXECUTE | web_search, file_write |
| 7 | Analyze & Report | ANALYZE | web_search, file_write, memory_save |

**Prompt sent:** `Run recipe: Content Marketing Campaign. Steps in order: Audience Research, Content Strategy & Outline, Draft Content, Edit & Refine, Publish & Schedule, Promote & Distribute, Analyze & Report. Start with step 1.`

---

### `/recipe refactor`
**File:** `priv/recipes/refactor.json`  
**Description:** Systematically refactor a module — understand design, identify smells, plan, write tests first, implement, verify.

| # | Step | Mode | Tools |
|---|---|---|---|
| 1 | Understand Current Design | ANALYZE | file_read, shell_execute |
| 2 | Identify Code Smells | ANALYZE | file_read |
| 3 | Plan Refactoring | ANALYZE | file_write |
| 4 | Write Tests First | BUILD | file_write, shell_execute |
| 5 | Implement Refactoring | BUILD | file_write, file_read, shell_execute |
| 6 | Verify and Review | ANALYZE | shell_execute, file_write |

**Prompt sent:** `Run recipe: Refactor Module. Steps in order: Understand Current Design, Identify Code Smells, Plan Refactoring, Write Tests First, Implement Refactoring, Verify and Review. Start with step 1.`

---

## Creating Custom Recipes

### Via TUI
```
/recipe-create my-recipe-name
```
This generates a starter JSON in `.osa/recipes/my-recipe-name.json` which you edit.

### Manually
Drop a `.json` file in any of the resolution directories with this structure:

```json
{
  "name": "My Recipe",
  "description": "What this recipe does",
  "steps": [
    {
      "name": "Step Name",
      "description": "Detailed instructions for the agent",
      "signal_mode": "ANALYZE",
      "tools_needed": ["file_read", "shell_execute"],
      "acceptance_criteria": "How the agent knows this step is done"
    }
  ]
}
```

The slug (used in `/recipe <slug>`) is the filename without `.json`.

---

## Recipe System — Production Readiness Grade (aspirational)

> The grades below describe the *design intent* for the planned recipe runtime.
> They are **not** an assessment of shipping code — no recipe runtime exists yet
> (see the status banner at the top of this document).

**Target: B+ (82/100)**

| Area | Score | Notes |
|---|---|---|
| Architecture | A | Clean resolution order, event bus integration, proper OTP supervision |
| Context Management | A | Fresh session per recipe, 0% context on start (fixed March 2026) |
| Prompt Efficiency | A | Trimmed to ~50 tokens per recipe call |
| Error Handling | B | Step failures are caught and logged, but no retry logic |
| Test Coverage | C+ | No dedicated recipe unit tests; `commands_test.exs` exists but doesn't cover recipe paths |
| Observability | B+ | Bus events emitted for start/step/complete but no metrics dashboard |
| Custom Recipe UX | B | `/recipe-create` works but no schema validation feedback to user |
| Documentation | B | This file. Was missing before. |
| Performance | A- | SSE reconnect properly sequenced; occasional ~500ms delay on session create |
| Security | A | No injection surface; recipe JSON validated before execution |

**What's blocking an A:**
- No step-level retry on transient tool failures
- No test file for `Recipe` module directly
- No recipe timeout — a runaway step has no kill switch
- Custom recipe schema errors silently become bad runs

---

## 6 Tips: Making the Recipe System Elite

### 1. Brand It — Call Them "Playbooks"
Rename recipes to **Playbooks** in all UI surfaces. This is a known term in DevOps (Ansible), sports, and business strategy — instantly communicates "repeatable, proven process." Command becomes `/playbook code-review`. Add a `"author"` and `"version"` field to the JSON so playbooks feel like first-class published assets, not config files.

### 2. Step Progress Bar in the TUI
Right now the user only sees the flat prompt. Add a live step tracker in the sidebar or status bar: `[■■□□□] Step 2/5: Check Correctness`. The `recipe_step_started` and `recipe_step_completed` bus events are already emitted — wire them to a new `RecipeProgress` TUI component. This is the single biggest perceived quality upgrade.

### 3. Playbook Marketplace / Share Command
Add `/playbook publish` that packages a recipe JSON + metadata and pushes to a shared registry (even a GitHub Gist or your own S3). Add `/playbook install <url-or-slug>` to pull one down. This creates a community loop — users build and share playbooks, which drives retention and word-of-mouth. Call the registry **OSA Playbook Hub**.

### 4. Conditional Steps — `if` in JSON
Add an optional `"condition"` field to each step:
```json
{ "name": "Run Migrations", "condition": "file_exists:mix.exs" }
```
The runner checks the condition before executing the step, skipping it if false. This makes one playbook work across languages and project types instead of needing a separate recipe per stack.

### 5. Step Retry + Timeout Config
Add top-level `"max_retries": 2` and `"step_timeout_seconds": 120` fields to the JSON schema. The `run_step` function already runs an agent loop — wrapping it in a retry with exponential backoff takes ~20 lines. This closes the biggest production reliability gap: transient tool failures (shell timeouts, network blips) currently kill the whole recipe.

### 6. Playbook Templates via `/playbook-create --from <template>`
Pre-bake 5–6 blueprint templates (web-api, cli-tool, data-pipeline, microservice, mobile-app). When a user runs `/playbook-create my-api --from web-api`, they get a customized multi-step playbook pre-filled for their stack. Pair this with the `"author": "OSA"` branding on built-ins so users can clearly distinguish official playbooks from community ones.
