---
name: offensive-xxe
description: "XML External Entity injection testing checklist: classic XXE, blind XXE (out-of-band), XXE via file upload (SVG/docx), XXE in SOAP/REST, error-based XXE, XInclude attacks, and XXE filter bypass. Use for web app XXE testing and bug bounty."
category: security
triggers:
  - "xxe"
  - "offensive xxe"
  - "web"
  - "web attack"
  - "web exploitation"
  - "xxe methodology"
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

# SKILL: XML External Entity (XXE) Injection

## Metadata
- **Skill Name**: xxe
- **Folder**: offensive-xxe
- **Source**: https://github.com/SnailSploit/offensive-checklist/blob/main/xxe.md

## Description
XML External Entity injection testing checklist: classic XXE, blind XXE (out-of-band), XXE via file upload (SVG/docx), XXE in SOAP/REST, error-based XXE, XInclude attacks, and XXE filter bypass. Use for web app XXE testing and bug bounty.

## Trigger Phrases
Use this skill when the conversation involves any of:
`XXE, XML external entity, blind XXE, out-of-band XXE, XXE file upload, SVG XXE, SOAP XXE, XInclude, entity bypass, XXE SSRF, XXE file read`


<!-- progressive-disclosure -->
## Methodology references

Read the relevant sections below before following a technique. Read them in order
for the complete original methodology. Confirm the target and testing scope with
the user before performing any active checks.

- [Full Methodology](references/methodology-01.md) — part 1; consult for this stage and its examples.
- [Parameter Entity Testing](references/methodology-02.md) — part 2; consult for this stage and its examples.
- [PHP Wrapper inside XXE](references/methodology-03.md) — part 3; consult for this stage and its examples.
- [Apigee Edge](references/methodology-04.md) — part 4; consult for this stage and its examples.
