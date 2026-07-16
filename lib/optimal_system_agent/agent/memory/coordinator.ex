defmodule OptimalSystemAgent.Agent.Memory.Coordinator do
  @moduledoc """
  Three-tier memory coordinator — a thin façade over OSA's existing memory
  primitives, giving the agent one interface for *remember / recall /
  consolidate* across a MemGPT-style tier hierarchy.

  ## The three tiers (all pre-existing modules; this is orchestration only)

    * **CORE** — `Agent.ProgressLedger`. Volatile per-session working notes: the
      current goal and a rolling log. Survives context resets, discarded per
      session. (MemGPT "main context".)
    * **EPISODIC** — `Agent.Memory.EpisodicStore`. Durable, timestamped task
      attempts + outcomes + Reflexion reflections, scored for retrieval by
      recency + importance + relevance (Generative Agents).
    * **SEMANTIC** — `Store.SkillLibrary`. Distilled, verified, reusable
      procedures ("skills") that generalise across sessions and projects.

  Tiers stay as **separate modules**; the coordinator never reaches into their
  storage — it only calls their public APIs. This keeps each tier independently
  testable and swappable.

  ## API

    * `remember/2` — route an event to the right tier(s).
    * `recall/2`   — gather and merge the most relevant memories across all
      three tiers into a compact, ranked list.
    * `consolidate/1` — Mem0-style extract-on-write: scan a session's episodes
      for a recurring successful pattern and *promote* it into the semantic
      skill library.

  ## Injection helper

  `recall_block/2` renders the merged recall into a compact markdown block ready
  to inject as a system pre-directive at task start (see
  `Agent.Loop.MessageHandler.maybe_add_memory_directive/2`).
  """

  require Logger

  alias OptimalSystemAgent.Agent.Memory.EpisodicStore
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Store.SkillLibrary

  # How many episodes of the same tag-signature must recur before consolidate/1
  # promotes them to a semantic skill.
  @promotion_threshold 3

  # Default number of items surfaced per tier by recall/2.
  @default_limit 3

  @type event :: %{optional(atom() | String.t()) => term()}

  # ── remember ──────────────────────────────────────────────────────────

  @doc """
  Record an event into the appropriate tier(s).

  `event` is a map. Its `:kind` (or `"kind"`) decides routing:

    * `:goal`     — set the CORE ledger goal (`:goal` / `:text`).
    * `:note`     — append a CORE ledger log entry (`:text`).
    * `:episode`  — persist an EPISODIC task attempt. Recognises `:task`,
      `:outcome`, `:reflection`, `:tags`, `:tools`, `:importance`, `:project`.
    * `:skill`    — upsert a SEMANTIC skill (delegates to `SkillLibrary`).

  Unknown kinds default to an episodic note. Every branch is best-effort and
  never raises to the caller.
  """
  @spec remember(String.t(), event()) :: {:ok, term()} | {:error, term()}
  def remember(session_id, event) when is_binary(session_id) and is_map(event) do
    event = atomize_shallow(event)

    case event[:kind] do
      :goal ->
        ProgressLedger.set_goal(session_id, to_string(event[:goal] || event[:text] || ""))

      :note ->
        ProgressLedger.append_entry(session_id, to_string(event[:text] || ""))

      :skill ->
        SkillLibrary.save_skill(event)

      _ ->
        EpisodicStore.record(session_id, event)
    end
  rescue
    e ->
      Logger.warning("[memory.coordinator] remember failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ── recall ────────────────────────────────────────────────────────────

  @doc """
  Recall the most relevant memories for `query`, merged across all three tiers.

  Returns a map:

      %{
        core:     String.t() | nil,   # progress-ledger recap (session goal + log)
        episodic: [episode_map],      # top scored episodes
        semantic: [skill_map],        # top matching skills
        empty?:   boolean()
      }

  Options:
    * `:limit`   — max items per retrieval tier (default #{@default_limit}).
    * `:project` — restrict episodic recall to a project path.
  """
  @spec recall(String.t(), keyword()) :: map()
  def recall(session_id, query, opts \\ [])

  def recall(session_id, query, opts) when is_binary(session_id) and is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)

    # Wrap the CORE tier in safe/2 like the EPISODIC/SEMANTIC tiers below, so a
    # corrupt/unreadable progress ledger (which can raise inside summarize) can't
    # escape recall/3 and break its documented best-effort contract.
    core =
      safe(fn ->
        case ProgressLedger.summarize(session_id) do
          {:ok, summary} -> summary
          _ -> nil
        end
      end, nil)

    episodic =
      safe(fn ->
        EpisodicStore.recall(query, Keyword.merge([limit: limit], Keyword.take(opts, [:project])))
      end, [])

    semantic = safe(fn -> SkillLibrary.find_skills(query, limit: limit) end, [])

    %{
      core: core,
      episodic: episodic,
      semantic: semantic,
      empty?: is_nil(core) and episodic == [] and semantic == []
    }
  end

  @doc """
  Render `recall/3`'s merged result as a compact markdown block suitable for
  injection at task start, or `nil` when nothing relevant is found.
  """
  @spec recall_block(String.t(), String.t(), keyword()) :: String.t() | nil
  def recall_block(session_id, query, opts \\ []) do
    result = recall(session_id, query, opts)

    if result.empty? do
      nil
    else
      sections =
        [
          format_episodic(result.episodic),
          format_semantic(result.semantic)
        ]
        |> Enum.reject(&is_nil/1)

      # Core (progress ledger) is already injected separately by the ledger
      # directive, so recall_block focuses on episodic + semantic to avoid
      # duplicating the ledger recap.
      case sections do
        [] -> nil
        parts -> "Relevant memory (recalled for this task):\n\n" <> Enum.join(parts, "\n\n")
      end
    end
  end

  # ── consolidate ───────────────────────────────────────────────────────

  @doc """
  Mem0-style consolidation: scan a session's episodes for a **recurring
  successful pattern** (same tag-signature seen ≥ #{@promotion_threshold} times)
  and promote it into the SEMANTIC skill library.

  Returns `{:promoted, [slug, ...]}` with the skills created/updated, or
  `{:ok, :nothing_to_promote}`.
  """
  @spec consolidate(String.t()) :: {:promoted, [String.t()]} | {:ok, :nothing_to_promote}
  def consolidate(session_id) when is_binary(session_id) do
    episodes = EpisodicStore.list(session_id)

    promoted =
      episodes
      |> Enum.filter(&(&1["outcome"] == "success"))
      |> Enum.group_by(&tag_signature/1)
      |> Enum.filter(fn {sig, group} -> sig != "" and length(group) >= @promotion_threshold end)
      |> Enum.map(fn {_sig, group} -> promote_group(group) end)
      |> Enum.reject(&is_nil/1)

    case promoted do
      [] -> {:ok, :nothing_to_promote}
      slugs -> {:promoted, slugs}
    end
  rescue
    e ->
      Logger.warning("[memory.coordinator] consolidate failed: #{Exception.message(e)}")
      {:ok, :nothing_to_promote}
  end

  # Promote a group of same-signature successful episodes into one skill.
  defp promote_group([exemplar | _] = group) do
    tags = List.wrap(exemplar["tags"])
    title = "Recurring approach: " <> (exemplar["task"] |> to_string() |> String.slice(0, 60))

    reflections =
      group
      |> Enum.map(&to_string(&1["reflection"]))
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.uniq()
      |> Enum.take(5)

    body = """
    Consolidated from #{length(group)} successful episodes in the same area.

    Representative task: #{exemplar["task"]}

    What worked (reflections):
    #{if reflections == [], do: "- (no reflections recorded)", else: Enum.map_join(reflections, "\n", &("- " <> &1))}
    """

    attrs = %{
      title: title,
      description: "Auto-consolidated pattern from recurring successful episodes.",
      when_to_use: "When tackling tasks tagged: #{Enum.join(tags, ", ")}",
      body: body,
      tags: tags
    }

    case SkillLibrary.save_skill(attrs) do
      {:ok, skill} -> skill["slug"]
      _ -> nil
    end
  end

  defp promote_group(_), do: nil

  # ── Formatting helpers ────────────────────────────────────────────────

  defp format_episodic([]), do: nil

  defp format_episodic(episodes) do
    lines =
      Enum.map_join(episodes, "\n", fn ep ->
        outcome = ep["outcome"] || "?"
        task = ep["task"] |> to_string() |> String.slice(0, 100)
        refl = ep["reflection"] |> to_string() |> String.slice(0, 160)
        refl_part = if String.trim(refl) == "", do: "", else: " — #{refl}"
        "- [#{outcome}] #{task}#{refl_part}"
      end)

    "Past attempts (episodic):\n" <> lines
  end

  defp format_semantic([]), do: nil

  defp format_semantic(skills) do
    lines =
      Enum.map_join(skills, "\n", fn skill ->
        title = skill["title"] |> to_string() |> String.slice(0, 80)
        when_to = skill["when_to_use"] |> to_string() |> String.slice(0, 100)
        when_part = if String.trim(when_to) == "", do: "", else: " (#{when_to})"
        "- #{title}#{when_part}"
      end)

    "Known procedures (semantic skills):\n" <> lines
  end

  # ── misc ──────────────────────────────────────────────────────────────

  defp tag_signature(episode) do
    episode["tags"]
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.join("|")
  end

  defp atomize_shallow(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Only map to atoms we already use, so arbitrary keys don't leak into the
  # atom table.
  @known_keys ~w(kind goal text task outcome reflection tags tools importance project
                 title description when_to_use body slug)a
  @known_lookup Map.new(@known_keys, fn a -> {Atom.to_string(a), a} end)

  defp safe_atom(str), do: Map.get(@known_lookup, str, str)

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
