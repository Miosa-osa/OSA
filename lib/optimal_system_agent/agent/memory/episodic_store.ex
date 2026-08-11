defmodule OptimalSystemAgent.Agent.Memory.EpisodicStore do
  @moduledoc """
  Durable **episodic** memory tier — a persistent record of task *attempts*,
  their *outcomes*, and a short Reflexion-style *reflection* (what worked / what
  failed). This is the long-term counterpart to the fast, ephemeral ETS event
  log in `OptimalSystemAgent.Agent.Memory.Episodic`: that module tracks raw
  tool-use events for the current run; this one persists distilled *episodes*
  across sessions and restarts.

  ## Research lineage

    * **MemGPT tiers** — episodic sits between the volatile *core* working memory
      (`Agent.ProgressLedger`) and the compact *semantic* store
      (`Store.SkillLibrary`). The coordinator promotes recurring episodes upward.
    * **Generative Agents retrieval** — `recall/2` ranks memories by a weighted
      sum of **recency** (exponential decay), **importance** (1–10), and
      **relevance** (keyword overlap with the query), returning the top-K.
    * **Reflexion** — every episode carries a short natural-language reflection
      summarising the lesson, so future recall surfaces *why* an attempt worked
      or failed, not just that it happened.

  ## Storage

  One JSON file per session at `~/.osa/memory/episodic/<safe_session>.json`,
  holding a JSON array of episode maps (append-on-write, newest last). Keeping
  episodes grouped by session keeps per-session reads cheap while cross-session
  recall simply loads every file. The layout mirrors `Store.SkillLibrary`'s flat
  JSON convention so both tiers stay inspectable on disk.

  An episode map has the shape:

      %{
        "id"         => "ep-9f3...",
        "session_id" => "cli:abc",
        "project"    => "/home/user/proj",
        "task"       => "Fix the failing gateway auth test",
        "outcome"    => "success",            # success | failure | partial
        "reflection" => "Token skew was the cause; widen DEVICE_SIGNATURE_SKEW_MS",
        "tags"       => ["gateway", "auth", "test"],
        "importance" => 7,                     # 1..10
        "tools"      => ["file_edit", "shell_execute"],
        "created_at" => "2026-07-16T09:00:00Z"
      }
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.System.AtomicFile

  @type episode :: %{optional(String.t()) => term()}

  @default_dir "~/.osa/memory/episodic"

  # Generative-Agents retrieval weights (recency, importance, relevance).
  @w_recency 1.0
  @w_importance 1.0
  @w_relevance 1.0

  # Recency decay: importance halves every N hours of age.
  @decay_half_life_hours 24.0

  # Per-session cap; oldest episodes are pruned beyond this.
  @max_episodes_per_session 500

  @valid_outcomes ~w(success failure partial)

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Record a task attempt as a durable episode.

  Accepts a map with string or atom keys. Required: `:task`. Everything else is
  optional and defaulted. `:importance` is clamped to 1..10; when omitted it is
  derived heuristically from the outcome and reflection length.

  Returns `{:ok, episode}` or `{:error, reason}`.
  """
  @spec record(String.t(), map()) :: {:ok, episode()} | {:error, String.t()}
  def record(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    task = attrs["task"] |> to_string() |> String.trim()

    if task == "" do
      {:error, "episode requires a non-empty :task"}
    else
      outcome = normalize_outcome(attrs["outcome"])
      reflection = to_string(attrs["reflection"] || "")

      episode = %{
        "id" => "ep-" <> Integer.to_string(System.unique_integer([:positive]), 36),
        "session_id" => session_id,
        "project" => to_string(attrs["project"] || cwd()),
        "task" => task,
        "outcome" => outcome,
        "reflection" => reflection,
        "tags" => normalize_tags(attrs["tags"]),
        "tools" => normalize_tags(attrs["tools"]),
        "importance" => clamp_importance(attrs["importance"], outcome, reflection),
        "created_at" => now_iso()
      }

      append(session_id, episode)
    end
  end

  def record(_, _), do: {:error, "record/2 requires (session_id, attrs_map)"}

  @doc """
  Retrieve the top-K episodes for a free-text query, ranked by the
  Generative-Agents score = recency + importance + relevance.

  Options:
    * `:limit`      — max results (default 5)
    * `:session_id` — restrict to one session (default: search all sessions)
    * `:project`    — restrict to one project path

  Each returned episode carries an extra `"score"` float for transparency.
  """
  @spec recall(String.t(), keyword()) :: [episode()]
  def recall(query, opts \\ [])

  def recall(query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 5)
    session_id = Keyword.get(opts, :session_id)
    project = Keyword.get(opts, :project)

    keywords = tokenize(query)
    now = DateTime.utc_now()

    load_episodes(session_id)
    |> filter_project(project)
    |> Enum.map(fn ep -> Map.put(ep, "score", score(ep, keywords, now)) end)
    |> Enum.sort_by(& &1["score"], :desc)
    |> Enum.take(limit)
  end

  def recall(_, _), do: []

  @doc "List every episode for a session, newest first."
  @spec list(String.t()) :: [episode()]
  def list(session_id) when is_binary(session_id) do
    load_episodes(session_id) |> Enum.sort_by(& &1["created_at"], :desc)
  end

  @doc "Aggregate stats across all persisted episodes."
  @spec stats() :: map()
  def stats do
    all = load_episodes(nil)

    %{
      total: length(all),
      by_outcome: Enum.frequencies_by(all, & &1["outcome"]),
      sessions: all |> Enum.map(& &1["session_id"]) |> Enum.uniq() |> length()
    }
  end

  # ── Scoring (Generative Agents) ───────────────────────────────────────

  @doc """
  Score a single episode against query keywords at reference time `now`.

  score = w_r·recency + w_i·importance_norm + w_v·relevance, each component
  normalised to 0..1 so weights are directly comparable.
  """
  @spec score(episode(), [String.t()], DateTime.t()) :: float()
  def score(episode, keywords, now \\ DateTime.utc_now()) do
    recency = recency_weight(episode["created_at"], now)
    importance = normalize_importance(episode["importance"])
    relevance = relevance_weight(episode, keywords)

    (@w_recency * recency + @w_importance * importance + @w_relevance * relevance)
    |> Float.round(4)
  end

  # Exponential decay on age in hours.
  defp recency_weight(created_at, now) do
    case parse_iso(created_at) do
      {:ok, dt} ->
        hours = max(DateTime.diff(now, dt, :second), 0) / 3600.0
        :math.pow(0.5, hours / @decay_half_life_hours)

      :error ->
        0.0
    end
  end

  defp normalize_importance(importance) do
    imp = to_int(importance, 5)
    max(min(imp, 10), 1) / 10.0
  end

  # Fraction of query keywords found across the episode's searchable text,
  # with tag hits weighted slightly higher.
  defp relevance_weight(_episode, []), do: 0.0

  defp relevance_weight(episode, keywords) do
    text =
      [episode["task"], episode["reflection"], Enum.join(List.wrap(episode["tags"]), " ")]
      |> Enum.join(" ")
      |> String.downcase()

    tag_text = List.wrap(episode["tags"]) |> Enum.join(" ") |> String.downcase()

    hits =
      Enum.reduce(keywords, 0.0, fn kw, acc ->
        cond do
          String.contains?(tag_text, kw) -> acc + 1.2
          String.contains?(text, kw) -> acc + 1.0
          true -> acc
        end
      end)

    min(hits / length(keywords), 1.0)
  end

  # ── Persistence ───────────────────────────────────────────────────────

  defp append(session_id, episode) do
    dir = episodic_dir()
    File.mkdir_p!(dir)
    path = session_path(session_id)

    # Serialize the read-modify-write per session so two concurrent record/2
    # calls can't both read the same base array and clobber each other's episode
    # (an APPEND under last-writer-wins silently DROPS a just-recorded episode).
    # :global.trans acquires a cluster-wide lock keyed by the session and runs
    # the critical section exclusively, retrying until it wins the lock.
    :global.trans(
      {{:osa_episodic_append, session_id}, self()},
      fn -> do_append(path, episode) end
    )
  rescue
    e ->
      Logger.warning("[episodic_store] append failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp do_append(path, episode) do
    episodes = (read_file(path) ++ [episode]) |> cap()

    case Jason.encode(episodes, pretty: true) do
      {:ok, json} ->
        # Atomic write-then-rename so a crash mid-write can't truncate the whole
        # session's episode array (which read_file would then silently drop).
        # Unique temp path per writer prevents a shared ".tmp" inode from being
        # re-truncated mid-flight and torn.
        AtomicFile.write!(path, json)
        emit_recorded(episode)
        {:ok, episode}

      {:error, reason} ->
        {:error, "failed to encode episode: #{inspect(reason)}"}
    end
  end

  # Load episodes: a single session file, or every session file when session_id
  # is nil.
  defp load_episodes(session_id) when is_binary(session_id) do
    read_file(session_path(session_id))
  end

  defp load_episodes(nil) do
    dir = episodic_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.flat_map(fn f -> read_file(Path.join(dir, f)) end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp read_file(path) do
    with {:ok, json} <- File.read(path),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      Enum.filter(list, &is_map/1)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp cap(episodes) when length(episodes) > @max_episodes_per_session do
    Enum.take(episodes, -@max_episodes_per_session)
  end

  defp cap(episodes), do: episodes

  defp filter_project(episodes, nil), do: episodes

  defp filter_project(episodes, project) do
    Enum.filter(episodes, &(&1["project"] == project))
  end

  # ── Heuristics / helpers ──────────────────────────────────────────────

  # Heuristic importance when the caller doesn't supply one: failures and rich
  # reflections are more worth remembering than routine successes.
  defp clamp_importance(nil, outcome, reflection) do
    base =
      case outcome do
        "failure" -> 7
        "partial" -> 6
        _ -> 4
      end

    bonus = if String.length(String.trim(reflection)) > 40, do: 2, else: 0
    max(min(base + bonus, 10), 1)
  end

  defp clamp_importance(value, _outcome, _reflection) do
    max(min(to_int(value, 5), 10), 1)
  end

  defp normalize_outcome(value) do
    v = value |> to_string() |> String.downcase() |> String.trim()
    if v in @valid_outcomes, do: v, else: "partial"
  end

  defp tokenize(query) do
    query
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp normalize_tags(nil), do: []

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(tags) when is_binary(tags) do
    tags |> String.split(~r/[,\s]+/, trim: true) |> normalize_tags()
  end

  defp normalize_tags(_), do: []

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp to_int(value, default) do
    cond do
      is_integer(value) ->
        value

      is_float(value) ->
        round(value)

      is_binary(value) ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> default
        end

      true ->
        default
    end
  end

  defp parse_iso(nil), do: :error

  defp parse_iso(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_iso(_), do: :error

  defp cwd do
    File.cwd!()
  rescue
    _ -> "."
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp session_path(session_id), do: Path.join(episodic_dir(), safe_id(session_id) <> ".json")

  defp safe_id(session_id), do: Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")

  defp episodic_dir do
    Application.get_env(:optimal_system_agent, :episodic_dir, @default_dir)
    |> Path.expand()
  end

  defp emit_recorded(episode) do
    Bus.emit(:system_event, %{
      event: :episodic_recorded,
      id: episode["id"],
      session_id: episode["session_id"],
      outcome: episode["outcome"],
      importance: episode["importance"]
    })

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
