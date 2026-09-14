# 1.0.200 consolidation and local-state audit

Audited 2026-09-14. The single open OSA pull request is #279. Main merging,
publishing, tagging, and deployment remain paused.

## Working copies and saved history

All five OSA worktrees had no modified or staged source files. The older
`integrate/1.0.100` worktree had one untracked `deps` symlink pointing to the
main checkout's dependency cache; it is not an unpublished source change.
Seven adjacent, separate OSA-family repositories also had clean Git status.
They remain separate repositories, not material to import into this PR.

The audit covered 24 local branches, 198 remote-tracking refs, the current
stash, 39 closed-but-unmerged PR records, and parked/rescue/WIP snapshots.
A private Git bundle was restored into a separate mirror: all 431 named refs
and 25 additional reflog-only commits were verified. A SHA-256 manifest and
checkout/PR inventories accompany the recovery archive. No branch, stash,
ignored file, or historical snapshot was deleted.

The current stash changes VERSION from 1.0.160 to 1.0.161 and sets machine-local
128K context, q4_0 KV cache, and disabled thinking defaults. It is preserved,
not applied over 1.0.200 or turned into defaults for every user. An ignored
July roadmap is also saved as historical material, not treated as the current
release plan. Personal SOUL, user/identity files, memory, configuration, skills,
authoring files, and a consistent SQLite backup are stored privately outside
the repository. Credentials and private preferences are not PR content.

## Prior pull requests

A closed PR without a GitHub merge record can still have been consolidated
elsewhere. The recent candidates are accounted for:

- #256 landed through #257 (`eedc3404`).
- #252 was included in release consolidation `444a2ff5`.
- #142, #177, #182, #183, and #191 were consolidated by #196 (`543c7bb9`).
- #193 was included in `16a0f003`.
- #203's head is an ancestor of this PR. The earlier September skills and
  repair PRs #276 and #277 are already on the PR's base history.

Other closed branches were checked using ancestry, patch equivalence, current
source, and owner closing comments. The LaTeX compiler part of #98, hot code
synthesis #31, and external vaos integrations #67/#68/#69 were deliberately
held or rejected. Their history is saved; this consolidation does not revive
those rejected designs. The independent HTTP fixes from #98 already landed.

Broad historical snapshots and #39/#70 include obsolete architectures and
later rewrites. Every old hunk is not certified equivalent to current code.
Likewise, the old local `OSA_SECURITY_POSTURE` toggle is retained in history,
not restored into today's changed security context. August's WIP snapshot
would undo later hardening; its useful memory-extraction change already
landed. Preserving such history does not mean applying every historical patch.

## Recovered operator-control instructions

The personal SOUL contained a HARD BRAKE section missing from both
`priv/prompts/SOUL.md` and `examples/bootstrap/SOUL.md`. This PR now carries the
portable instructions in both templates: stop immediately, save standing
preferences on their first statement, verify delegated output, honor model
restrictions, and constrain delegated work to named files/methods/tools.
Existing personalized SOUL files are not overwritten.

`test/soul/operator_control_test.exs` loads each template through the real
Soul loader and checks the assembled system prompt. It failed on both old
templates and passes after the recovery; all 47 Soul tests passed together.
This proves instruction delivery, **not** future model obedience, cancellation
of already-running work, or a code-enforced cloud-only launch policy. This
change does not claim new runtime enforcement for those behaviors.

Source VERSION, Mix's derived version, TUI manifest, and Cargo lockfile remain
1.0.200. CI results for the final revision are recorded in PR #279.
