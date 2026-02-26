# Use Cases

Real-world applications of OSA for business owners and developers. Each use case includes what it does, which machines and skills to enable, example prompts, and expected behavior.

---

## 1. Personal AI Assistant

**What it does:** Your daily operating system. Briefings every morning, email triage, task management, calendar awareness, and proactive follow-up reminders — all running locally on your machine.

### Setup

**Machines to enable:**

```json
{
  "machines": {
    "productivity": true,
    "research": true
  }
}
```

**Skills to install:**

- `daily-briefing/` — Morning briefings with weather, calendar, news, priorities
- `email-assistant/` — Inbox triage, thread summaries, reply drafting
- `meeting-prep/` — Attendee research, talking points, post-meeting notes

Copy from `examples/skills/` to `~/.osa/skills/`.

**HEARTBEAT.md tasks:**

```markdown
- [ ] Generate daily briefing and save to ~/.osa/briefings/today.md
- [ ] Check for overdue follow-ups and list any that need attention
- [ ] Scan calendar for tomorrow's meetings and prepare briefing documents
```

### Example Prompts

```
Give me my morning briefing

Triage my inbox — what needs attention today?

I have a call with Sarah Chen at 2 PM — prep me

Remind me to follow up with Mike Torres about the contract next Tuesday

What are my top 3 priorities this week?

Summarize this email thread and tell me what I need to do
```

### Expected Behavior

The agent becomes a daily operating rhythm:

1. **Morning:** HEARTBEAT triggers the daily briefing. You open it and know exactly what matters today.
2. **Email:** You forward or paste emails. The agent triages them, highlights what is urgent, and drafts replies.
3. **Before meetings:** HEARTBEAT prepares briefing docs for tomorrow's meetings. You walk in knowing who you are talking to and what to discuss.
4. **End of day:** Ask "what did I miss today?" and the agent reviews unaddressed items.

**Signal classification impact:** When you forward a newsletter to the agent, it is classified as low-weight (noise) and filtered. When you forward a client escalation, it is classified as high-weight (critical signal) and processed immediately. You pay for AI compute only on what matters.

---

## 2. Business Operations

**What it does:** Sales pipeline monitoring, client follow-ups, revenue forecasting, and deal tracking. The agent watches your pipeline and alerts you when deals need attention — before you have to ask.

### Setup

**Machines to enable:**

```json
{
  "machines": {
    "productivity": true,
    "research": true,
    "communication": true
  }
}
```

**Skills to install:**

- `sales-pipeline/` — Pipeline overview, deal tracking, revenue forecasting
- `meeting-prep/` — Client meeting preparation
- `email-assistant/` — Client email drafting

**HEARTBEAT.md tasks:**

```markdown
- [ ] Check sales pipeline for stalled deals and overdue follow-ups — alert if any found
- [ ] Generate weekly pipeline summary and save to ~/.osa/reports/pipeline-weekly.md
- [ ] Research any new companies added to the pipeline this week
```

### Example Prompts

```
Show me the pipeline

Which deals are at risk this week?

Update the Acme deal — they accepted our proposal, value is now $135K

What's our revenue forecast for Q1?

Research Delta Co — I have a call with them tomorrow

Draft a follow-up email to Sarah about the contract terms we discussed

What follow-ups are overdue?
```

### Expected Behavior

The agent becomes your sales operations layer:

1. **Pipeline visibility:** Ask "show me the pipeline" and get a formatted table of all deals with stage, value, days in stage, next action, and risk level.
2. **Proactive alerts:** HEARTBEAT checks every 30 minutes. If a $100K deal has gone 14 days without activity, you get an alert before you even ask.
3. **Deal research:** Before a client call, the agent researches the company, finds recent news, and prepares talking points.
4. **Revenue forecasting:** Weighted pipeline calculation with best case, worst case, and comparison to targets.

**Signal classification impact:** "Update the Acme deal to $135K" is classified as Mode=EXECUTE, Genre=DECIDE, Weight=0.85 — high-priority state change. "thanks for the update" is Weight=0.2 — filtered as noise.

---

## 3. Content Operations

**What it does:** Blog drafting, social media content creation, email campaigns, and content calendar planning. Research-driven writing that matches your brand voice.

### Setup

**Machines to enable:**

```json
{
  "machines": {
    "research": true
  }
}
```

**Skills to install:**

- `content-writer/` — Blog posts, social media, email campaigns, content calendars

**HEARTBEAT.md tasks:**

```markdown
- [ ] Research trending topics in our industry and save 5 content ideas to ~/.osa/content/ideas.md
- [ ] Check if any scheduled content is due for publishing this week
```

### Example Prompts

```
Write a blog post about why small businesses should invest in AI automation

Turn that blog post into 3 LinkedIn posts and a Twitter thread

Create a 5-email welcome sequence for new subscribers

Plan our content calendar for March — we have a product launch on March 15

Research what our competitors published this week about AI agents

Draft an email newsletter about our latest feature update
```

### Expected Behavior

1. **Research-first writing:** The agent searches the web before writing anything. Blog posts include real data points, not generic claims.
2. **Multi-platform adaptation:** One blog post becomes LinkedIn posts, Twitter threads, and email newsletters — each formatted for the platform.
3. **Brand voice learning:** After the first few interactions, the agent saves your brand voice profile to memory and applies it consistently.
4. **Content calendar:** Monthly planning tied to business goals, events, and launches.

**Signal classification impact:** "Write a blog post about AI automation" is classified as Mode=BUILD, Weight=0.85 — this is a substantial creation request. "can you make it shorter?" is Mode=ASSIST, Weight=0.65 — still processed but recognized as a refinement, not a new task.

---

## 4. Customer Support

**What it does:** Support ticket triage using signal classification, auto-response drafting, escalation routing, and knowledge base management. This is where the 5-tuple classification shows its full value.

### Setup

**Machines to enable:**

```json
{
  "machines": {
    "communication": true,
    "research": true
  }
}
```

**Custom skills to create:**

Create `~/.osa/skills/support-triage/SKILL.md`:

```markdown
---
name: support-triage
description: Triage customer support tickets by urgency and category
tools:
  - file_read
  - file_write
  - web_search
  - memory_save
---

## Instructions

Classify each support ticket using these categories:

Priority:
- P0: Production down, data loss, security breach
- P1: Feature broken, blocking workflow, deadline-sensitive
- P2: Feature degraded, workaround available
- P3: Question, feature request, minor issue

Category:
- Bug, Feature Request, Billing, Account, Integration, Documentation

For each ticket: classify, draft a response, and route to the right team.
Save resolution patterns to memory for future reference.
```

**HEARTBEAT.md tasks:**

```markdown
- [ ] Scan support queue for unresolved P0/P1 tickets and alert immediately
- [ ] Generate daily support metrics: open tickets, avg response time, resolution rate
```

### Example Prompts

```
Triage these 15 support tickets and tell me which ones are P0/P1

Draft a response for ticket #4521 — the user can't log in after the update

What are the most common issues this week?

Create a knowledge base article for the login issue we've been seeing

Escalate ticket #4523 to the engineering team with a summary
```

### Expected Behavior

1. **Signal classification shines here.** A ticket saying "URGENT: Production is completely down, all customers affected" gets Weight=0.95, Mode=EXECUTE. A ticket saying "hey, just wondering if you could add dark mode sometime" gets Weight=0.55, Mode=ASSIST. The triage is automatic.
2. **Pattern detection:** After seeing the same login issue three times, the agent suggests creating a knowledge base article and offers to draft it.
3. **Response drafting:** For common issues, the agent drafts responses referencing the knowledge base. For complex issues, it escalates with a structured summary.
4. **Metrics:** HEARTBEAT generates daily support metrics without anyone asking.

---

## 5. Development Workflow

**What it does:** Code review assistance, bug triage, sprint planning context, and development documentation. The agent reads your codebase, understands your patterns, and assists with the cognitive overhead of software development.

### Setup

**Machines to enable:**

```json
{
  "machines": {
    "research": true
  }
}
```

**Custom skills to create:**

Create `~/.osa/skills/code-review/SKILL.md`:

```markdown
---
name: code-review
description: Review code changes for bugs, style issues, and improvement opportunities
tools:
  - file_read
  - shell_execute
  - memory_save
---

## Instructions

When asked to review code:
1. Read the file(s) specified
2. Check for: bugs, security issues, performance problems, style violations
3. Provide specific, actionable feedback with line references
4. Suggest improvements with code examples
5. Note what was done well (not just problems)

Severity levels: CRITICAL, MAJOR, MINOR, SUGGESTION
```

Create `~/.osa/skills/bug-triage/SKILL.md`:

```markdown
---
name: bug-triage
description: Analyze bug reports, reproduce steps, and suggest root causes
tools:
  - file_read
  - shell_execute
  - web_search
  - memory_save
---

## Instructions

When given a bug report:
1. Identify the symptom and expected behavior
2. Search the codebase for relevant code (file_read, shell_execute with grep)
3. Form 2-3 hypotheses for root cause
4. Suggest reproduction steps
5. Recommend a fix approach
6. Save the pattern to memory for future reference
```

### Example Prompts

```
Review the changes in lib/optimal_system_agent/agent/loop.ex

Triage this bug: users are getting 500 errors on the /api/v1/orchestrate endpoint when session_id contains special characters

What are the most common error patterns in our logs this week?

Help me plan the sprint — we have 8 tickets, here are the descriptions...

Explain how the goldrush event bus works in our codebase

Generate a test plan for the signal classifier
```

### Expected Behavior

1. **Code review:** The agent reads the specified files, identifies issues by severity, and provides specific feedback with line numbers and suggested fixes.
2. **Bug triage:** Given a bug report, the agent reads relevant source files, forms hypotheses, and suggests where to look. It saves the pattern so similar bugs are triaged faster next time.
3. **Sprint planning:** Given ticket descriptions, the agent estimates complexity, identifies dependencies, and suggests sprint order.
4. **Codebase knowledge:** The agent can explain any part of the codebase by reading the relevant files and providing a plain-language explanation.

---

## 6. Research Assistant

**What it does:** Deep web research, source summarization, comparative analysis, and knowledge management. The agent conducts research on your behalf and maintains an organized knowledge base.

### Setup

**Machines to enable:**

```json
{
  "machines": {
    "research": true
  }
}
```

**Custom skills to create:**

Create `~/.osa/skills/deep-research/SKILL.md`:

```markdown
---
name: deep-research
description: Conduct deep web research on a topic with source tracking and summarization
tools:
  - web_search
  - file_write
  - memory_save
---

## Instructions

When asked to research a topic:
1. Conduct 3-5 web searches with different angles
2. For each relevant source: note the URL, extract key findings, assess credibility
3. Synthesize findings into a structured report:
   - Executive summary (3-5 sentences)
   - Key findings (bulleted, with source citations)
   - Competing viewpoints (if any)
   - Gaps in available information
   - Recommended next steps
4. Save the report to ~/.osa/research/YYYY-MM-DD-topic.md
5. Save key facts to memory for future reference
```

### Example Prompts

```
Research the current state of AI agent frameworks — who are the main players and how do they compare?

Find everything you can about Acme Corp — I have a meeting with their CTO next week

What are the latest developments in Elixir/OTP for AI applications?

Compare the pricing models of the top 5 CRM platforms for a 50-person sales team

Summarize the three most important papers on signal processing in communication systems published this year

Build a competitive analysis of our product against NanoClaw, Nanobot, and OpenClaw
```

### Expected Behavior

1. **Multi-angle research:** The agent does not stop at one search query. It approaches the topic from multiple angles, cross-references sources, and notes conflicting information.
2. **Source tracking:** Every claim is attributed to a specific source. No fabricated citations.
3. **Structured output:** Research reports follow a consistent format: executive summary, key findings, analysis, gaps, next steps.
4. **Knowledge accumulation:** Research findings are saved to memory. When you ask about the same topic later, the agent has the previous research as context and can update it rather than starting from scratch.
5. **Credibility assessment:** The agent notes when a source is a primary source vs. secondary, peer-reviewed vs. blog post, recent vs. outdated.

**Signal classification impact:** "Research the current state of AI agent frameworks" is classified as Mode=ANALYZE, Genre=DIRECT, Weight=0.85 — a substantial research request. The agent allocates its full reasoning budget. "can you also check pricing?" is Mode=ANALYZE, Weight=0.65 — recognized as a follow-up query in the same research thread.

---

## Combining Use Cases

These use cases work best when combined. A business owner running OSA with all machines enabled and all example skills installed has:

- Morning briefings that include pipeline alerts and calendar prep (Personal + Business)
- Meeting prep that pulls deal history and attendee research (Business + Research)
- Content creation informed by industry research and client conversations (Content + Research)
- Support triage that learns from previous resolutions (Support + Research)
- Development reviews informed by bug history and code patterns (Dev + Research)

The signal classification layer ensures that no matter how many skills are active, only meaningful messages consume AI compute. The noise filter is the cost control mechanism.

---

## Deploying for Production

For production deployments:

1. **Enable authentication:** Set `OSA_SHARED_SECRET` and `OSA_REQUIRE_AUTH=true`
2. **Use a cloud provider:** Set `OSA_DEFAULT_PROVIDER=anthropic` for higher quality responses
3. **Run as a service:** Use the macOS LaunchAgent or a systemd service for always-on operation
4. **Set up HEARTBEAT.md:** Configure periodic tasks for proactive monitoring
5. **Reverse proxy:** Put Nginx or Caddy in front for TLS, rate limiting, and CORS
6. **Monitor:** Subscribe to the SSE firehose (`osa:events`) for operational monitoring

See `docs/getting-started.md` for detailed setup instructions and `docs/http-api.md` for the complete API reference.
