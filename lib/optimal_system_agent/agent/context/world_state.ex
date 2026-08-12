defmodule OptimalSystemAgent.Agent.Context.WorldState do
  @moduledoc """
  Diffed world state — the per-session ledger of injected context sections.

  Ported from Codex's `core/src/session/world_state.rs`. The idea: OSA does not
  re-concatenate every context block on every turn. Instead each block is a
  **section** with

    * a **stable id** (`:tool_process`, `:agents_md`, …) that never changes,
    * a **marker** (`<ws id="...">…</ws>`) so injected text can later be FOUND
      and stripped from persisted history without a side channel,
    * a **snapshot** (the rendered body), and
    * a **diff** against the snapshot emitted on the previous turn.

  A section is emitted **only when it changed since the last turn**. Unchanged
  sections are replayed byte-for-byte from the ledger, which keeps the prompt
  prefix stable so the provider's prefix / KV cache stays warm — an unchanged
  section costs zero *new* tokens and zero *new* prefill.

  ## Section semantics

  A section must be able to say it went away, not just that it changed:

    * `:added`     — first emission, body verbatim.
    * `:changed`   — body, prefixed with the section's replacement notice
                     ("These AGENTS.md instructions replace all previously
                     provided AGENTS.md instructions."). Without this the model
                     sees two contradictory copies in history and has no way to
                     know which one wins.
    * `:removed`   — the body becomes the removal notice ("The previously
                     provided AGENTS.md instructions no longer apply."). A
                     capability or mode disappearing silently is the worst
                     failure mode.
    * `:unchanged` — nothing emitted.

  ## Marker registry discipline

  `@sections` is append-only. You NEVER delete a section type — you retire its
  producer (`retired: true`) and keep its matcher forever, so sessions
  persisted before the retirement still parse and still strip cleanly. See
  `markers/0` and `strip/1`.

  ## Ledger

  Emitted payloads are kept per session in ETS, in emission order. Replaying
  them verbatim is what makes the prefix byte-stable. The ledger compacts back
  to a single fresh snapshot once it exceeds `@max_payloads` deltas, so a
  section that churns cannot grow the prompt without bound.
  """

  require Logger

  @ledger_table :osa_world_state_ledger

  # Compact the ledger to one fresh full snapshot after this many delta
  # payloads. Bounds growth when a section churns turn over turn.
  @max_payloads 6

  @typedoc "Outcome of diffing one section against the previous turn."
  @type change :: :added | :changed | :removed | :unchanged

  # ---------------------------------------------------------------------------
  # Section registry — ORDERED, APPEND-ONLY
  # ---------------------------------------------------------------------------
  #
  # Order mirrors Codex's world-state ordering, mapped onto OSA's blocks:
  #
  #   ModelInstructions → Personality → ContextWindowGuidance → Realtime →
  #   AgentsMd → Permissions → CollaborationMode → Environments → Apps →
  #   Tools → skills
  #
  # `:label` is the block label produced by `Agent.Context.gather_dynamic_blocks/1`.
  # `:name` is the human phrase used in the replacement / removal notices.
  # `:semantics` is `:replace` when a new body supersedes the old one (the model
  # must be told), or `:plain` when the body stands alone.
  # `:retired` marks a section that no longer has a producer. Its matcher is
  # kept forever so old persisted sessions still parse.
  #
  # `:rank` decides who WINS THE BUDGET when the dynamic budget is too small for
  # everything (lower wins first); the emission ORDER above is unaffected, so the
  # prompt prefix stays stable. Rank exists because the historical failure was
  # exactly this: plan mode — the thing that defines what the turn is allowed to
  # DO — lost a budget race to longer advisory prose and vanished without a word.
  # Operating mode and tool doctrine are rank 0 and can never lose to a catalog.
  @sections [
    %{
      id: :bootstrap,
      label: "bootstrap",
      name: "onboarding instructions",
      semantics: :plain,
      rank: 1
    },
    %{
      id: :personality,
      label: "personality",
      name: "personality overlay",
      semantics: :replace,
      rank: 2
    },
    %{
      id: :context_guidance,
      label: "scratchpad",
      name: "scratchpad guidance",
      semantics: :plain,
      rank: 2
    },
    %{id: :agents_md, label: "project_context", name: "AGENTS.md", semantics: :replace, rank: 1},
    %{
      id: :agents_md_nested,
      label: "project_instructions",
      name: "directory AGENTS.md",
      semantics: :replace,
      rank: 1
    },
    %{
      id: :collaboration_mode,
      label: "plan_mode",
      name: "collaboration mode",
      semantics: :replace,
      rank: 0
    },
    %{
      id: :environment,
      label: "environment",
      name: "environment",
      semantics: :replace,
      rank: 1
    },
    %{id: :apps, label: "commands", name: "slash-command catalog", semantics: :plain, rank: 3},
    %{id: :tools, label: "tool_process", name: "tool-usage", semantics: :replace, rank: 0},
    %{id: :agent_roles, label: "agent_roles", name: "subagent roster", semantics: :plain, rank: 3}
  ]

  @doc """
  The ordered section registry, including retired sections.
  """
  @spec sections() :: [map()]
  def sections, do: @sections

  @doc """
  Block labels that are world-state managed (i.e. removed from the per-turn
  dynamic tail and diffed instead). Retired sections have no live producer.
  """
  @spec managed_labels() :: [String.t()]
  def managed_labels do
    @sections |> Enum.reject(&Map.get(&1, :retired, false)) |> Enum.map(& &1.label)
  end

  @doc """
  Every marker regex this module has EVER emitted, retired ones included.

  Used to find and strip injected world-state text from persisted history. This
  list is append-only on purpose: a session persisted before a section was
  retired must still parse.
  """
  @spec markers() :: [Regex.t()]
  def markers do
    Enum.map(@sections, fn %{id: id} ->
      Regex.compile!("<ws id=\"#{id}\">.*?</ws>", "s")
    end)
  end

  @doc """
  Strips all injected world-state sections from `text`.

  Because every section carries its marker, persisted history can be cleaned
  without a side channel recording what was injected where.
  """
  @spec strip(String.t() | nil) :: String.t()
  def strip(nil), do: ""

  def strip(text) when is_binary(text) do
    markers()
    |> Enum.reduce(text, fn re, acc -> Regex.replace(re, acc, "") end)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Per-turn assembly
  # ---------------------------------------------------------------------------

  @doc """
  Diffs this turn's world state against the previous turn and returns the text
  to place in the prompt plus a diff summary.

      {text, summary} = WorldState.assemble(session_id, blocks)

  `blocks` is the `{content, priority, label}` list from
  `Agent.Context.gather_dynamic_blocks/1`; only labels in `managed_labels/0` are
  consumed.

  `parts` is the full replayed ledger (previously emitted chunks, byte-for-byte)
  followed by this turn's delta, as an ordered `[{section_id, chunk}]` list.
  Keeping it split per section — rather than one blob — is what lets the caller
  fit it against a budget and drop WHOLE sections (loudly) instead of severing
  one mid-sentence. `text/1` rejoins it into the exact string.

  `summary` is `%{changes: %{id => change}, emitted: [id], payloads: n}`.

  Options:

    * `:emit` (default `true`) — when `false`, diff and render WITHOUT mutating
      the ledger. `Agent.Context.token_budget/1` uses this so inspecting the
      budget can never perturb the next real turn.
  """
  @spec assemble(String.t() | nil, [{String.t() | nil, integer(), String.t()}], keyword()) ::
          {[{atom(), String.t()}], map()}
  def assemble(session_id, blocks, opts \\ [])

  def assemble(nil, blocks, opts), do: assemble("default", blocks, opts)

  def assemble(session_id, blocks, opts) when is_binary(session_id) do
    emit? = Keyword.get(opts, :emit, true)

    current =
      blocks
      |> Enum.reduce(%{}, fn {content, _priority, label}, acc ->
        case section_for_label(label) do
          nil -> acc
          %{id: id} -> if blank?(content), do: acc, else: Map.put(acc, id, content)
        end
      end)

    {prev_digests, payloads} = ledger(session_id)

    changes = diff(prev_digests, current)
    delta = render_delta(changes, current)

    {payloads, changes, delta} =
      if delta != [] and length(payloads) >= @max_payloads do
        # Compaction: collapse to ONE fresh full snapshot. Every live section is
        # re-emitted as `:added` so the model still sees the whole world, and the
        # ledger stops growing when a section churns turn over turn.
        all_added = Map.new(current, fn {id, _} -> {id, :added} end)
        {[], all_added, render_delta(all_added, current)}
      else
        {payloads, changes, delta}
      end

    payloads = if delta == [], do: payloads, else: payloads ++ [delta]

    if emit?, do: put_ledger(session_id, digests(current), payloads)

    emitted = changes |> Enum.reject(fn {_id, c} -> c == :unchanged end) |> Enum.map(&elem(&1, 0))

    if emit? and emitted != [] do
      Logger.debug(
        "[WorldState] session=#{session_id} emitted=#{inspect(emitted)} " <>
          "unchanged=#{Enum.count(changes, fn {_, c} -> c == :unchanged end)} " <>
          "payloads=#{length(payloads)}"
      )
    end

    {List.flatten(payloads), %{changes: changes, emitted: emitted, payloads: length(payloads)}}
  end

  @doc """
  Budget rank for a section id (lower wins the budget first). Unknown ids sort
  last, so a section from a future version can never starve a known one.
  """
  @spec rank(atom()) :: integer()
  def rank(id) do
    case Enum.find(@sections, &(&1.id == id)) do
      nil -> 99
      spec -> Map.get(spec, :rank, 2)
    end
  end

  @doc """
  Rejoins `assemble/3` parts into the prompt string.
  """
  @spec text([{atom(), String.t()}]) :: String.t()
  def text(parts) do
    parts
    |> Enum.map(&elem(&1, 1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Marks sections as NOT actually delivered to the model this turn.

  When the budget evicts a world-state section, the ledger must forget it — an
  unchanged-looking digest would otherwise suppress it forever and the model
  would silently lose that section for the rest of the session. Called by
  `Agent.Context` with whatever the budget dropped.
  """
  @spec invalidate(String.t() | nil, [atom()]) :: :ok
  def invalidate(_session_id, []), do: :ok
  def invalidate(nil, ids), do: invalidate("default", ids)

  def invalidate(session_id, ids) when is_list(ids) do
    {digests, payloads} = ledger(session_id)
    kept_ids = MapSet.new(ids)

    Logger.warning(
      "[WorldState] session=#{session_id} sections #{inspect(ids)} were evicted by the " <>
        "context budget and will be re-emitted next turn — the model did NOT see them."
    )

    put_ledger(
      session_id,
      Map.drop(digests, ids),
      Enum.map(payloads, fn payload ->
        Enum.reject(payload, fn {id, _} -> MapSet.member?(kept_ids, id) end)
      end)
    )
  end

  @doc "Drops a session's world-state ledger (new session / context reset)."
  @spec reset(String.t() | nil) :: :ok
  def reset(nil), do: :ok

  def reset(session_id) do
    ensure_table()
    :ets.delete(@ledger_table, session_id)
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Diff + render
  # ---------------------------------------------------------------------------

  defp diff(prev_digests, current) do
    current_digests = digests(current)

    ids =
      (Map.keys(prev_digests) ++ Map.keys(current_digests))
      |> Enum.uniq()

    Map.new(ids, fn id ->
      {id,
       case {Map.get(prev_digests, id), Map.get(current_digests, id)} do
         {nil, nil} -> :unchanged
         {nil, _} -> :added
         {_, nil} -> :removed
         {same, same} -> :unchanged
         {_, _} -> :changed
       end}
    end)
  end

  # Render this turn's delta in stable registry order, as `[{id, chunk}]`.
  # Sections whose change is `:unchanged` contribute nothing — that is the whole
  # point: an unchanged section costs zero new tokens.
  defp render_delta(changes, current) do
    @sections
    |> Enum.map(fn spec ->
      case Map.get(changes, spec.id, :unchanged) do
        :unchanged -> nil
        :added -> {spec.id, wrap(spec, Map.fetch!(current, spec.id))}
        :changed -> {spec.id, wrap(spec, replace_notice(spec) <> Map.fetch!(current, spec.id))}
        :removed -> {spec.id, wrap(spec, removal_notice(spec))}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp wrap(%{id: id}, body), do: "<ws id=\"#{id}\">\n#{body}\n</ws>"

  # Codex's exact semantics: a changed section must announce that it supersedes
  # the copy already sitting in history.
  #
  # This is what makes the strict prefix hold STRUCTURALLY. The ledger is
  # append-only — an earlier payload is never edited — so the only way the model
  # can know which of two copies of a section wins is for the newer one to say
  # so. There is nothing to assert and no invariant to regress: the notice IS
  # the mechanism.
  defp replace_notice(%{semantics: :replace, name: name}),
    do: "These #{name} instructions replace all previously provided #{name} instructions.\n\n"

  # `:plain` sections were previously re-emitted with NO notice, which is the
  # one place the append-only shape leaked: history ended up holding two
  # contradictory copies of the same `<ws id="...">` section with nothing
  # saying which is current, and the model had to guess (or, worse, honor the
  # stale one — the failure Codex's supersession contract exists to prevent).
  # `:plain` only means the body stands alone, not that a superseded copy may
  # be left standing, so a changed plain section supersedes too — in its own
  # weaker wording, since there is nothing to "replace instructions" about.
  defp replace_notice(%{name: name}),
    do:
      "The previously provided #{name} no longer applies. It is superseded by the following.\n\n"

  defp replace_notice(_), do: ""

  defp removal_notice(%{name: name}),
    do: "The previously provided #{name} instructions no longer apply."

  defp digests(current),
    do: Map.new(current, fn {id, body} -> {id, :erlang.phash2(body)} end)

  defp section_for_label(label), do: Enum.find(@sections, &(&1.label == label))

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

  # ---------------------------------------------------------------------------
  # Ledger (ETS)
  # ---------------------------------------------------------------------------

  defp ledger(session_id) do
    ensure_table()

    case :ets.lookup(@ledger_table, session_id) do
      [{^session_id, digests, payloads}] -> {digests, payloads}
      _ -> {%{}, []}
    end
  rescue
    _ -> {%{}, []}
  end

  defp put_ledger(session_id, digests, payloads) do
    ensure_table()
    :ets.insert(@ledger_table, {session_id, digests, payloads})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@ledger_table) do
      :undefined -> :ets.new(@ledger_table, [:named_table, :public, :set])
      ref -> ref
    end
  rescue
    ArgumentError -> @ledger_table
  end
end
