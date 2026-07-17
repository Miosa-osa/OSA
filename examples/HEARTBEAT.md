# Heartbeat Tasks

OSA checks this file every 30 minutes and runs every unchecked checkbox item (`- [ ] ...`)
through the agent loop. Write each task as a plain-English instruction on its own `- [ ]` line —
the agent uses its available tools to complete it. Lines that are not unchecked checkboxes
(headings, prose, HTML comments) are ignored, so you can freely annotate this file.

When OSA finishes a task it flips that line's checkbox to `- [x]` **in place** and appends a
completion timestamp — it does not move the line anywhere. Re-check it to `- [ ]` to run it again.

A task that fails 3 times in a row is automatically disabled (circuit breaker).
To re-enable it, flip it back to `- [ ]`.

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

## How Completed Tasks Look

<!-- After a task runs, OSA marks its checkbox [x] in place and appends a timestamp.
     A completed line looks like this (it stays where it was written):
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
