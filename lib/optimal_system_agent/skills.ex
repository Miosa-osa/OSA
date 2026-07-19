defmodule OptimalSystemAgent.Skills do
  @moduledoc """
  Skills subsystem - the facade and design note for how OSA captures, stores,
  ranks, surfaces, and invokes reusable know-how.

  # Design: a five-stage pipeline

      CAPTURE ─▶ STORE ─▶ RANK ─▶ SURFACE ─▶ INVOKE

  The goal is high signal: only reusable patterns get in, they are stored
  cleanly and deduped, retrieval ranks by relevance to the CURRENT task, only a
  small relevant set is ever shown, and the model pulls full bodies on demand.
  Each stage is a separate concern with a single owner:

    * **CAPTURE - `OptimalSystemAgent.Skills.Capture`.**
      A quality gate. Every write path (the model-invoked `save_skill` tool and
      the automatic `Memory.Coordinator` consolidation) runs candidate attrs
      through `Capture.validate/1` first. A skill is admitted only if it has a
      descriptive title, a real trigger (`when_to_use`/`description`), and a
      substantive body. Trivial one-offs are rejected at the door, so they never
      pollute retrieval or crowd out real procedures.

    * **STORE - `OptimalSystemAgent.Store.SkillLibrary`.**
      Persistence only. One JSON file per skill at `~/.osa/skills/<slug>.json`,
      deduped by slug (re-saving a slug updates in place and preserves the
      accumulated `uses` count and `created_at`). Knows nothing about ranking
      or admission policy - it delegates those out.

    * **RANK - `OptimalSystemAgent.Skills.Ranker`.**
      Relevance-first ordering. A skill is scored against the query with fuzzy,
      field-weighted token matching (title > tags > when_to_use > description >
      body), then boosted by recency (30-day half-life) and usage (log-saturated).
      Relevance is the gate: an unrelated skill scores zero and never surfaces no
      matter how recent or how used. This is the deliberate difference from the
      reference harnesses below.

    * **SURFACE - the reminder + context blocks.**
      Progressive disclosure. `Agent.Context.learned_skills_block/1` names only
      the top few relevant skills (title + slug + trigger) for the latest task;
      `Agent.Reminders` skill-discovery announces at most a handful of nearby
      `SKILL.md` files, now relevance-ordered before the cap rather than by disk
      proximity alone. Bodies are never dumped into context.

    * **INVOKE - `find_skill` / `use_skill`.**
      The model pulls a ranked set (or one slug) via `find_skill`, or runs a
      named `SKILL.md` skill via `use_skill`. Retrieval increments `uses`, so the
      library learns which procedures are actually valuable and the ranker's
      usage boost compounds.

  # How this compares to the reference harnesses

  Claude Code, grok, and opencode all surface author-curated `SKILL.md` files
  with **progressive disclosure** (metadata-only listing, body on invoke) but do
  **no query ranking** - they list every skill within a token budget, ordered by
  scope/precedence. That works because those skill sets are small and hand-made.

  OSA keeps that model for its shipped `SKILL.md` skills, but adds a second store
  the others do not have: a Voyager-style library the agent *writes to itself at
  runtime*. That store grows unbounded, so listing-everything would flood the
  context. Hence the two OSA-specific pieces the references lack: a **capture gate**
  (Capture) so the library stays high-signal, and **relevance ranking** (Ranker)
  so only the task-relevant few are ever surfaced. The capture gate mirrors the
  spirit of Claude Code's `/skillify` (deliberate, interview-quality capture)
  rather than dumping every action.

  This module is a thin facade over the components; callers may also use them
  directly.
  """

  alias OptimalSystemAgent.Skills.Capture
  alias OptimalSystemAgent.Skills.Ranker
  alias OptimalSystemAgent.Store.SkillLibrary

  @doc "CAPTURE + STORE: validate then persist a skill. See `SkillLibrary.save_skill/1`."
  @spec capture(map()) :: {:ok, map()} | {:error, String.t()}
  defdelegate capture(attrs), to: SkillLibrary, as: :save_skill

  @doc "CAPTURE gate only - does not persist. See `Capture.validate/1`."
  @spec validate(map()) :: :ok | {:error, String.t()}
  defdelegate validate(attrs), to: Capture

  @doc "RANK + retrieve: relevance-ranked skills for a query. See `SkillLibrary.find_skills/2`."
  @spec find(String.t(), keyword()) :: [map()]
  defdelegate find(query, opts \\ []), to: SkillLibrary, as: :find_skills

  @doc "RANK a supplied list of skills against a query. See `Ranker.rank/3`."
  @spec rank([map()], String.t(), keyword()) :: [map()]
  defdelegate rank(skills, query, opts \\ []), to: Ranker

  @doc "Score a raw text blob against a query. See `Ranker.relevance/2`."
  @spec relevance(String.t(), String.t()) :: float()
  defdelegate relevance(text, query), to: Ranker
end
