# Goal handoff and user controls

An unfinished goal does not always need another agent turn. If the next useful
action belongs to a person, OSA can persist an `awaiting_user` request and stop
automatic pursuit without claiming completion. This lifecycle is shared across
providers; no provider-specific approval capability is required.

## User controls

- `/goal` shows the status and pending question, artifact scope, and request ID.
- `/goal approve <request_id>` records approval of that specific review scope.
- `/goal reject <request_id> <changes>` records rejection and the requested changes.
- Send a message after deciding to continue work or final verification.
- `/goal pause` pauses pursuit; `/goal resume` resumes an ordinary pause.
- `/goal clear` (also `/goal cancel`, `/goal off`, `/goal reset`) stops the running
  work and clears pursuit. History is retained with a `cleared` status, not
  misrepresented as completed. Start a new goal explicitly when ready.

Resume does not bypass an outstanding decision, and cannot revive a cleared,
completed, or abandoned goal. Ordinary messages are not approval. Old or duplicate
request IDs cannot approve a later request. Approval does not grant tool-action
permissions and does not directly mark the goal complete; independent verification
still checks the original contract and the scope/version of the approval.

## Model/harness contract

`update_goal(status: "awaiting_user")` requires `question`, `criterion`,
`work_summary`, and `artifact`. Each is a nonempty string, capped at 4000 characters.
Criteria must derive from the user's request: do not invent an approval gate.
Use the artifact field to identify the exact version or decision scope.
The request is a handoff, not proof that all other work has been completed.

The same structured classification is available to the verifier, including at
text-only goal continuation boundaries. Optional polishing or tool-call activity
is not a substitute for a human decision. Failed classification never grants
completion. The model cannot approve or reject its own request through this tool.

Text-only goals classified as candidate-complete are reviewed even when no file
writes occurred. The panel receives the latest assistant deliverable (bounded to
16,000 characters) and the explicit decision record; it does not have to infer
conversational work from a source-code diff. Truncated or insufficient evidence
must still be treated as insufficient, not as automatic success.

## Durability and races

Pending requests, decisions, and budget accounting persist in the goal sidecar.
Decision/control writes are serialized with verification commits. Verifier results
are checked against the goal identity, status, and timestamp captured before
classification/review, so late results cannot undo pause/clear or affect a new goal.
A failed decision-state write returns an error instead of claiming durable waiting.

Task-brief and progress-ledger context explicitly distinguish historical/inactive
goals. Clearing does not delete the audit history; the next goal gets a fresh brief.

## Limits

Classification still depends on model judgment; the harness prevents a waiting
claim from becoming approval, but cannot mechanically prove an arbitrary natural-
language criterion is correctly derived. Approval names a review scope; the
verifier must not extend it to a changed artifact. Files are not cryptographically
frozen by this workflow. Explicit command responses are supported; free-text
approval inference and multiple simultaneous decision cards are not introduced.

Regression tests cover waiting, restart, budgets, approval/rejection, stale and
duplicate decisions, stale verification, clear, text-only triage, and HTTP commands.
