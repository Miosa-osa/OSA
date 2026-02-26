# User Profile

OSA reads this file at startup to personalize its behavior.
Fill in the sections relevant to you — leave anything blank that does not apply.
The more context you provide, the less the agent has to infer or ask.

---

## About You

<!-- Your basic profile. The agent uses this to calibrate tone and depth. -->

<!-- name: Your Name -->
<!-- role: Your Role / Title -->
<!-- organization: Company or team name -->
<!-- expertise: Your technical level — beginner | intermediate | advanced -->
<!-- languages: Languages you work in (e.g., English, Spanish) -->

---

## Communication Preferences

<!-- How should the agent communicate with you by default? -->

- Response length: adaptive
  <!-- concise (short answers, headlines) | detailed (full explanations) | adaptive (match the request) -->

- Tone: professional
  <!-- casual | professional | technical -->

- Code output: show examples
  <!-- explain only | show examples | both -->

- Proactivity: medium
  <!-- low (only do what's asked) | medium (surface relevant context) | high (suggest actions proactively) -->

- Confirm before actions: yes
  <!-- yes (always confirm before writes/sends) | no (execute directly) | destructive-only -->

---

## Working Hours

<!-- When should scheduled tasks and alerts be active? -->

- Timezone: UTC
  <!-- e.g., America/New_York, Europe/London, Asia/Tokyo -->

- Active hours: 09:00 - 18:00
  <!-- Format: HH:MM - HH:MM in your local timezone -->

- Weekend mode: minimal
  <!-- minimal (critical alerts only) | normal (full operation) | off (no scheduled tasks) -->

- Morning briefing time: 08:00
  <!-- What time should the daily briefing run, if configured in HEARTBEAT.md? -->

---

## Active Projects

<!-- List your current projects so the agent has context without asking. -->
<!-- Format: ProjectName: /path/to/project — Brief description -->

<!-- - MyApp: ~/projects/myapp — Main SaaS product, TypeScript/React/Go -->
<!-- - ClientSite: ~/work/client — Consulting project, deadline end of quarter -->

---

## Tools and Technology

<!-- What tools, languages, and platforms do you use? -->
<!-- The agent uses this to give relevant examples and avoid suggesting tools you don't use. -->

<!-- Languages: TypeScript, Go, Python -->
<!-- Frameworks: React, SvelteKit, Echo -->
<!-- Databases: PostgreSQL, SQLite -->
<!-- Infrastructure: Docker, GitHub Actions -->
<!-- Editor: VS Code -->
<!-- Shell: zsh -->

---

## Integrations

<!-- Which channels are active for this agent? -->
<!-- Remove the comment markers for any you have configured. -->

<!-- - telegram: @yourusername -->
<!-- - slack: workspace-name / #channel -->
<!-- - discord: server-name / #channel -->

---

## Recurring Tasks

<!-- Any tasks you do regularly that the agent should be aware of? -->
<!-- These can be added to HEARTBEAT.md for automation, or just kept here as context. -->

<!-- - Every Monday: review the weekly pipeline report -->
<!-- - Every Friday: send team status update -->
<!-- - First of month: generate invoices from time tracking data -->

---

## Key Contacts

<!-- People the agent should recognize by name in communications. -->
<!-- Format: Name: role / relationship — relevant context -->

<!-- - Sarah Chen: Head of Product — primary stakeholder for feature decisions -->
<!-- - Marco Rodriguez: Lead Engineer — reviews all architecture changes -->
<!-- - Acme Corp: key client — high priority, Q3 contract renewal in progress -->

---

## Memory Notes

<!-- Anything the agent should always remember across all sessions. -->
<!-- These are permanent preferences, not session context. -->

<!-- - I prefer TypeScript over JavaScript for all new projects -->
<!-- - Always check memory before asking a question I may have answered before -->
<!-- - Do not suggest Jira — we use Linear -->
<!-- - All file output should go to ~/.osa/output/ unless I specify otherwise -->
