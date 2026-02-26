# Heartbeat Tasks

OSA checks this file every 30 minutes and executes any unchecked items through the agent loop.
Write tasks as plain English instructions — the agent will use its available tools to complete them.

A task that fails 3 times in a row is automatically disabled (circuit breaker).
To re-enable it, just uncheck it again.

---

## Morning Routine (runs once daily)

- [ ] Generate today's daily briefing: weather in San Francisco, calendar summary, top 3 news items in AI/SaaS, and task priorities. Save to ~/.osa/briefings/today.md
- [ ] Check calendar for tomorrow's meetings and prepare a one-page briefing document for each meeting with new attendees. Save to ~/.osa/meetings/

## Sales Pipeline (runs every 30 min)

- [ ] Check the sales pipeline for any deals that have been stalled for more than 7 days or have overdue follow-ups. If any are found, write a brief alert to ~/.osa/alerts/pipeline.md
- [ ] If it is Friday, generate a weekly pipeline summary with total pipeline value, weighted forecast, and deals that moved this week. Save to ~/.osa/reports/pipeline-weekly.md

## Email and Follow-ups (runs every 30 min)

- [ ] Check for overdue follow-ups saved in memory. If any are more than 2 days overdue, list them in ~/.osa/alerts/followups.md
- [ ] If new emails have been saved to ~/.osa/inbox/, triage them and write a summary of urgent items to ~/.osa/alerts/email-urgent.md

## Content (runs daily)

- [ ] Search the web for 5 trending topics in our industry and save content ideas to ~/.osa/content/ideas.md
- [ ] Check if any scheduled content in ~/.osa/content/calendar/ is due for publishing in the next 2 days. If so, write a reminder to ~/.osa/alerts/content-due.md

## System Health (runs every 30 min)

- [ ] Check that Ollama is running by searching for "ollama" in the process list. If not running, write an alert to ~/.osa/alerts/system.md
- [ ] Check disk space on the home directory. If less than 10GB free, write an alert to ~/.osa/alerts/system.md

---

## Completed Tasks

<!-- Tasks move here after completion. The agent marks them automatically. -->
<!-- Example:
- [x] Generate today's daily briefing (completed 2026-02-24T08:30:00Z)
- [x] Check sales pipeline for stalled deals (completed 2026-02-24T09:00:00Z)
-->

---

## Tips

- **Keep tasks specific.** "Check email" is vague. "Check for overdue follow-ups in memory and list any more than 2 days overdue" is actionable.
- **Include file paths.** Tell the agent where to save output. Otherwise it will respond but the output goes nowhere.
- **Use conditional logic.** "If it is Friday, generate a weekly report" prevents the task from running uselessly on other days.
- **One action per task.** Do not combine multiple unrelated actions in a single task line.
- **Test tasks manually first.** Before adding a task to HEARTBEAT.md, try it as a regular chat message to make sure the agent can handle it.
