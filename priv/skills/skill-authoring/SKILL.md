---
name: skill-authoring
description: Create or improve reusable OSA skills with progressive disclosure, precise selection descriptions, supporting resources, and realistic evaluations. Use when users ask to create, package, test, optimize, or maintain a skill or skill library.
tools:
  - file_read
  - file_glob
  - file_grep
  - file_write
  - file_edit
  - shell_execute
triggers:
  - create a skill
  - write a skill
  - improve this skill
  - skill library
---

# Skill Authoring

Create focused procedural knowledge that improves behavior beyond the base agent.

## Progressive disclosure

1. Keep the name and concise selection description in the always-visible catalog.
2. Put the core workflow in SKILL.md and keep it under 500 lines when practical.
3. Put detailed references, templates, scripts, and assets in supporting directories.
4. Tell the agent exactly when each supporting file should be loaded.

## Procedure

1. Define what the skill enables, when it should be selected, and expected outputs.
2. Inspect adjacent skills to prevent overlap or contradictory ownership.
3. Write a description containing both capability and selection conditions.
4. Explain why the workflow matters instead of relying on excessive rigid language.
5. Use tool names and commands that exist in OSA.
6. Add two or three realistic positive prompts and difficult near-miss prompts.
7. Compare behavior with and without the skill when practical.
8. Revise instructions that create wasted work, ambiguity, or brittle overfitting.
9. Verify discovery from a clean OSA installation and selective loading through `skill_view`.

## Creation rule

Do not manufacture a skill merely because a task used many tools.
Create one when the user requests it or when a completed, reusable workflow has durable value.
