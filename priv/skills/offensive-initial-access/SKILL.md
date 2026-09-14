---
name: offensive-initial-access
description: "Initial access techniques checklist: phishing (spear/smishing), credential stuffing, exposed service exploitation, supply chain attacks, watering hole, VPN/RDP brute force, public-facing application exploitation. Maps to MITRE ATT&CK TA0001. Use when planning initial access phases of red team engagements."
category: security
triggers:
  - "initial access"
  - "offensive initial access"
  - "infrastructure"
  - "infrastructure attack"
  - "infrastructure exploitation"
  - "initial access methodology"
tools:
  - file_read
  - file_glob
  - file_grep
  - file_write
  - file_edit
  - dir_list
  - shell_execute
  - web_fetch
  - web_search
  - delegate
---

# SKILL: Modern Initial Access

## Metadata
- **Skill Name**: initial-access
- **Folder**: offensive-initial-access
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/initial-access.md

## Description
Initial access techniques checklist: phishing (spear/smishing), credential stuffing, exposed service exploitation, supply chain attacks, watering hole, VPN/RDP brute force, public-facing application exploitation. Maps to MITRE ATT&CK TA0001. Use when planning initial access phases of red team engagements.

## Trigger Phrases
Use this skill when the conversation involves any of:
`initial access, phishing, spear phishing, credential stuffing, exposed service, supply chain, watering hole, VPN brute force, RDP attack, MITRE TA0001, initial foothold`


<!-- progressive-disclosure -->
## Methodology references

Read the relevant sections below before following a technique. Read them in order
for the complete original methodology. Confirm the target and testing scope with
the user before performing any active checks.

- [Full Methodology](references/methodology-01.md) — part 1; consult for this stage and its examples.
- [Windows Script Host](references/methodology-02.md) — part 2; consult for this stage and its examples.
- [Installation](references/methodology-03.md) — part 3; consult for this stage and its examples.
- [RAG (Retrieval Augmented Generation) Database Poisoning](references/methodology-04.md) — part 4; consult for this stage and its examples.
