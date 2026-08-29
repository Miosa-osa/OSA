defmodule OptimalSystemAgent.Skills.Curator do
  @moduledoc """
  Periodic skill lifecycle curator.

  Runs every 24h and classifies each installed skill by idleness:

    - No usage in #{14}+ days -> `:stale`
    - No usage in #{30}+ days AND <#{3} total uses -> `:archived`

  ## Why this is REPORT-ONLY by default

  Marking a skill `.archived` also writes `.disabled`, and `.disabled` is read
  by `Tools.Registry` / `Tools.Builtins.SkillManager` / `Agents.Registry` — i.e.
  it genuinely switches the skill OFF. This used to happen unconditionally, on a
  timer, with no eligibility check, no opt-out, and no way back: a skill the
  user hand-wrote and uses once a quarter was silently disabled, and nothing in
  the product ever said so.

  Curation is therefore **opt-in**:

      config :optimal_system_agent, :skill_curation, :report   # default
      config :optimal_system_agent, :skill_curation, :archive  # actually apply

  `:report` (default) computes exactly the same decisions and records them, but
  performs NO destructive filesystem write — it never creates `.archived` or
  `.disabled`. `:off` disables the curator entirely. `:archive` opts in to the
  old behaviour, still subject to pinning.

  ## Pinning

  A skill is never staled or archived when ANY of these hold:

    - the skill directory contains a `.pin` (or `.pinned`) marker file
    - its `SKILL.md` frontmatter contains `pinned: true`
    - its name appears in `config :optimal_system_agent, :skill_curation_pins`

  `pin/1` and `unpin/1` manage the marker file.

  ## Never-used skills

  A skill with no usage record used to be treated as 999 days idle, so a
  freshly hand-written skill was eligible for archiving on the curator's very
  first pass. Idleness for an unused skill now falls back to the age of its
  `SKILL.md` on disk.

  ## Getting a skill back

  `unarchive/1` removes `.archived`, `.disabled` and `.stale`. Every run also
  writes a machine-readable report to `<skills_dir>/.curation-report.json` and
  logs the affected skill names, so what the curator did is always visible.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Skills.Frontmatter
  alias OptimalSystemAgent.Tools.Registry.SkillUsage

  @interval_ms 24 * 60 * 60 * 1000
  @stale_days 14
  @archive_days 30
  @archive_min_uses 3

  @report_file ".curation-report.json"
  @pin_markers [".pin", ".pinned"]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def curate_now, do: GenServer.cast(__MODULE__, :curate)

  @doc """
  Last run's stats plus the per-skill decisions it made (or *would* have made
  in `:report` mode). This is the in-process surface for "what did the curator
  do to my skills?"; the same content is mirrored to
  `<skills_dir>/#{@report_file}`.
  """
  @spec report() :: map()
  def report, do: GenServer.call(__MODULE__, :report)

  # ── Curation mode ──────────────────────────────────────────────────────

  @doc """
  Effective curation mode: `:off` | `:report` (default) | `:archive`.

  Only `:archive` performs destructive writes. `true` is accepted as an alias
  for `:archive` and `false` for `:off` so a boolean config still means
  something sensible.
  """
  @spec mode() :: :off | :report | :archive
  def mode do
    case Application.get_env(:optimal_system_agent, :skill_curation, :report) do
      :archive -> :archive
      true -> :archive
      :off -> :off
      false -> :off
      _ -> :report
    end
  end

  # ── Pinning ────────────────────────────────────────────────────────────

  @doc "Pin a skill so the curator never stales or archives it."
  @spec pin(String.t()) :: {:ok, String.t()} | {:error, term()}
  def pin(name) when is_binary(name) do
    with {:ok, dir} <- skill_dir(name) do
      case File.write(Path.join(dir, ".pin"), "pinned at #{now_iso()}\n") do
        :ok -> {:ok, name}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Remove a skill's pin marker (no-op when it was not pinned)."
  @spec unpin(String.t()) :: {:ok, String.t()} | {:error, term()}
  def unpin(name) when is_binary(name) do
    with {:ok, dir} <- skill_dir(name) do
      Enum.each(@pin_markers, fn m -> File.rm(Path.join(dir, m)) end)
      {:ok, name}
    end
  end

  @doc "True when `name` is pinned (marker file, frontmatter, or config list)."
  @spec pinned?(String.t()) :: boolean()
  def pinned?(name) when is_binary(name) do
    case skill_dir(name) do
      {:ok, dir} -> pinned_dir?(name, dir)
      _ -> false
    end
  end

  # ── Un-archive ─────────────────────────────────────────────────────────

  @doc """
  Undo a curation decision: removes `.archived`, `.disabled` and `.stale` so
  the skill is live again. This is the missing return path — before it existed,
  an archived skill could only be recovered by knowing to delete two marker
  files by hand.
  """
  @spec unarchive(String.t()) :: {:ok, String.t()} | {:error, term()}
  def unarchive(name) when is_binary(name) do
    with {:ok, dir} <- skill_dir(name) do
      Enum.each([".archived", ".disabled", ".stale"], fn m -> File.rm(Path.join(dir, m)) end)
      Logger.info("[Curator] Un-archived skill '#{name}' — it is live again")
      {:ok, name}
    end
  end

  @doc "Names of every currently archived skill."
  @spec archived() :: [String.t()]
  def archived do
    skills_dir()
    |> skill_entries()
    |> Enum.filter(&File.exists?(Path.join(&1.dir, ".archived")))
    |> Enum.map(& &1.name)
  end

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.send_after(self(), :curate, 5 * 60 * 1000)
    {:ok, %{last_run: nil, stats: %{}, decisions: []}}
  end

  @impl true
  def handle_info(:curate, state) do
    {stats, decisions} = do_curate()
    Process.send_after(self(), :curate, @interval_ms)
    {:noreply, %{state | last_run: DateTime.utc_now(), stats: stats, decisions: decisions}}
  end

  @impl true
  def handle_cast(:curate, state) do
    {stats, decisions} = do_curate()
    {:noreply, %{state | last_run: DateTime.utc_now(), stats: stats, decisions: decisions}}
  end

  @impl true
  def handle_call(:report, _from, state) do
    {:reply, %{last_run: state.last_run, stats: state.stats, decisions: state.decisions}, state}
  end

  # ── Curation pass ──────────────────────────────────────────────────────

  # Run one curation pass and return `{stats, decisions}`.
  #
  # Public (`@doc false`) so the decision logic is testable without a running
  # GenServer or a 24h timer.
  @doc false
  @spec do_curate() :: {map(), [map()]}
  def do_curate do
    mode = mode()
    skills_dir = skills_dir()
    now = DateTime.utc_now()
    entries = skill_entries(skills_dir)

    decisions =
      entries
      |> Enum.map(fn %{name: name, dir: dir} -> decide(name, dir, now) end)
      |> Enum.map(fn d -> apply_decision(d, mode, now) end)

    stats = %{
      total: length(entries),
      unclassifiable: Enum.count(decisions, &(&1.provenance == :unclassifiable)),
      staled: count(decisions, :stale),
      archived: count(decisions, :archive),
      reactivated: count(decisions, :reactivate),
      pinned: Enum.count(decisions, & &1.pinned),
      mode: mode,
      applied: mode == :archive
    }

    write_report(skills_dir, stats, decisions, now)
    log_run(stats, decisions, mode)

    {stats, decisions}
  end

  # Decide what SHOULD happen to one skill. Pure w.r.t. the filesystem except
  # for the reads it needs; performs no mutation. Separated from
  # `apply_decision/3` so "what would the curator do" is answerable in every
  # mode, including the default report-only one.
  defp decide(name, skill_dir, now) do
    usage = SkillUsage.get_usage(name)
    days_idle = idle_days(usage, skill_dir, now)
    pinned = pinned_dir?(name, skill_dir)
    provenance = provenance(skill_dir)
    already_archived = File.exists?(Path.join(skill_dir, ".archived"))
    stale_marked = File.exists?(Path.join(skill_dir, ".stale"))

    action =
      cond do
        already_archived ->
          :none

        pinned ->
          if stale_marked, do: :reactivate, else: :none

        # A skill whose SKILL.md the curator cannot even parse is a population
        # it does not understand. Switching it off on an idleness timer is a
        # guess, and the failure mode (a working skill silently disabled, with
        # no frontmatter left to explain what it was) is not recoverable by
        # anyone who does not already know about `.disabled`. Refuse.
        provenance == :unclassifiable ->
          if stale_marked, do: :reactivate, else: :none

        days_idle >= @archive_days and usage.use_count < @archive_min_uses ->
          :archive

        days_idle >= @stale_days ->
          if stale_marked, do: :none, else: :stale

        stale_marked ->
          :reactivate

        true ->
          :none
      end

    %{
      name: name,
      dir: skill_dir,
      action: action,
      applied: false,
      pinned: pinned,
      provenance: provenance,
      days_idle: days_idle,
      use_count: usage.use_count
    }
  end

  # Perform the filesystem mutation for a decision — but ONLY the ones this
  # mode permits. `:reactivate` (removing a `.stale` marker) is a restorative
  # write and always runs; `:stale` and `:archive` are the destructive ones and
  # require `mode == :archive`.
  defp apply_decision(%{action: :reactivate} = d, mode, _now) when mode != :off do
    File.rm(Path.join(d.dir, ".stale"))
    %{d | applied: true}
  end

  defp apply_decision(%{action: :archive} = d, :archive, now) do
    stamp = "archived at #{DateTime.to_iso8601(now)}"
    File.write(Path.join(d.dir, ".archived"), stamp)
    File.write(Path.join(d.dir, ".disabled"), stamp)
    %{d | applied: true}
  end

  defp apply_decision(%{action: :stale} = d, :archive, now) do
    File.write(Path.join(d.dir, ".stale"), "stale at #{DateTime.to_iso8601(now)}")
    %{d | applied: true}
  end

  defp apply_decision(d, _mode, _now), do: d

  defp count(decisions, action), do: Enum.count(decisions, &(&1.action == action))

  # ── Idleness ───────────────────────────────────────────────────────────

  # Days since a skill was last used. A skill with NO usage record is not
  # "999 days idle" — that made every hand-written skill instantly archivable
  # on the first pass. Fall back to how long its SKILL.md has been on disk,
  # which is the only honest signal available.
  defp idle_days(%{last_used_at: %DateTime{} = last}, _dir, now), do: days_between(last, now)

  defp idle_days(_usage, skill_dir, now) do
    case File.stat(Path.join(skill_dir, "SKILL.md"), time: :posix) do
      {:ok, %{mtime: mtime}} ->
        max(div(DateTime.to_unix(now) - mtime, 86_400), 0)

      _ ->
        0
    end
  end

  defp days_between(last, now), do: DateTime.diff(now, last, :second) |> div(86_400)

  # ── Pinning helpers ────────────────────────────────────────────────────

  defp pinned_dir?(name, skill_dir) do
    Enum.any?(@pin_markers, &File.exists?(Path.join(skill_dir, &1))) or
      name in config_pins() or
      frontmatter_pinned?(Path.join(skill_dir, "SKILL.md"))
  end

  defp config_pins do
    :optimal_system_agent
    |> Application.get_env(:skill_curation_pins, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  # `pinned: true` in the SKILL.md YAML frontmatter (the leading `---` block).
  defp frontmatter_pinned?(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.take(40)
        |> Enum.any?(&Regex.match?(~r/^\s*pinned\s*:\s*(true|yes)\s*$/i, &1))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # ── Reporting ──────────────────────────────────────────────────────────

  defp write_report(skills_dir, stats, decisions, now) do
    payload = %{
      "ran_at" => DateTime.to_iso8601(now),
      "mode" => to_string(stats.mode),
      "applied" => stats.applied,
      "stats" => Map.new(stats, fn {k, v} -> {to_string(k), to_string_value(v)} end),
      "decisions" =>
        decisions
        |> Enum.reject(&(&1.action == :none))
        |> Enum.map(fn d ->
          %{
            "skill" => d.name,
            "action" => to_string(d.action),
            "applied" => d.applied,
            "pinned" => d.pinned,
            "provenance" => to_string(d.provenance),
            "days_idle" => d.days_idle,
            "use_count" => d.use_count
          }
        end)
    }

    File.mkdir_p(skills_dir)
    File.write(Path.join(skills_dir, @report_file), Jason.encode_to_iodata!(payload))
    :ok
  rescue
    _ -> :ok
  end

  defp to_string_value(v) when is_atom(v), do: to_string(v)
  defp to_string_value(v), do: v

  defp log_run(stats, decisions, mode) do
    changed = Enum.reject(decisions, &(&1.action == :none))

    if changed != [] do
      names = fn action ->
        changed |> Enum.filter(&(&1.action == action)) |> Enum.map(& &1.name) |> Enum.join(", ")
      end

      verb = if mode == :archive, do: "applied", else: "WOULD apply (report-only)"

      Logger.info(
        "[Curator] #{stats.total} skills — #{verb}: " <>
          "#{stats.staled} stale [#{names.(:stale)}], " <>
          "#{stats.archived} archived [#{names.(:archive)}], " <>
          "#{stats.reactivated} reactivated [#{names.(:reactivate)}]"
      )

      archived_names = names.(:archive)

      if archived_names != "" and mode == :archive do
        by_provenance =
          changed
          |> Enum.filter(&(&1.action == :archive))
          |> Enum.group_by(& &1.provenance)
          |> Enum.map_join(", ", fn {p, ds} -> "#{length(ds)} #{p}" end)

        Logger.warning(
          "[Curator] Disabled skill(s): #{archived_names} (#{by_provenance}). " <>
            "Restore with Skills.Curator.unarchive/1, or keep them forever with " <>
            "Skills.Curator.pin/1."
        )
      end
    end

    unclassifiable = Enum.filter(decisions, &(&1.provenance == :unclassifiable))

    if unclassifiable != [] do
      Logger.warning(
        "[Curator] Left #{length(unclassifiable)} skill(s) alone — their SKILL.md frontmatter " <>
          "will not parse, so the curator cannot classify them and refuses to act: " <>
          Enum.map_join(unclassifiable, ", ", & &1.name)
      )
    end

    :ok
  end

  # ── Provenance ─────────────────────────────────────────────────────────

  @doc """
  Who wrote this skill:

    * `:generated`      — `Memory.SkillGenerator`, frontmatter `source: auto:<pattern_id>`
    * `:managed`        — `Tools.Builtins.SkillManager`, frontmatter `source: skill_manager`
    * `:authored`       — a human, or any writer that left a parseable SKILL.md
    * `:unclassifiable` — no SKILL.md, or frontmatter that will not parse

  The directory the curator walks holds all of these populations mixed
  together and it used to apply one idleness rule to the lot without ever
  asking which was which. It still applies one rule — but it will not perform
  a destructive write against a skill it cannot classify, because "I could not
  read this file" is not evidence that switching it off is safe.
  """
  @spec provenance(Path.t()) :: :generated | :managed | :authored | :unclassifiable
  def provenance(skill_dir) do
    case File.read(Path.join(skill_dir, "SKILL.md")) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _body} -> classify_source(to_string(meta["source"] || ""))
          {:error, :missing} -> :authored
          {:error, _} -> :unclassifiable
        end

      _ ->
        :unclassifiable
    end
  rescue
    _ -> :unclassifiable
  end

  defp classify_source("auto:" <> _), do: :generated
  defp classify_source("skill_manager"), do: :managed
  defp classify_source(_), do: :authored

  # ── Filesystem helpers ─────────────────────────────────────────────────

  defp skills_dir do
    Path.expand(Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills"))
  end

  # Every skill under the configured skills dir, at ANY depth. The old
  # `File.ls!` + `File.dir?` walk saw only immediate children, so a skill
  # nested under a category directory had no pin, no un-archive and no
  # `skill_dir/1` — `pin/1` on it just returned `:not_found`.
  #
  # Deliberately scoped to the configured skills dir: the loader also
  # discovers project- and bundled-scope skills, and the curator must never
  # write marker files into a checked-out repo or a read-only install tree.
  defp skill_entries(skills_dir) do
    if File.dir?(skills_dir) do
      skills_dir
      |> Path.join("**/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        dir = Path.dirname(path)
        %{name: entry_name(path, dir), dir: dir}
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  # Usage records are keyed by the name the registry surfaced, which comes
  # from frontmatter — not from the directory.
  defp entry_name(path, dir) do
    with {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(content),
         name when is_binary(name) and name != "" <- meta["name"] do
      name
    else
      _ -> Path.basename(dir)
    end
  rescue
    _ -> Path.basename(dir)
  end

  # Resolve by the name the registry uses, then by directory basename, so both
  # a flat `<skills_dir>/<name>/` and a nested `<skills_dir>/<cat>/<name>/`
  # are reachable. Containment is proven on the resolved directory.
  defp skill_dir(name) do
    root = skills_dir()
    flat = Path.join(root, name)

    cond do
      File.dir?(flat) and File.exists?(Path.join(flat, "SKILL.md")) ->
        {:ok, flat}

      true ->
        entry =
          root
          |> skill_entries()
          |> Enum.find(fn e -> e.name == name or Path.basename(e.dir) == name end)

        case entry do
          %{dir: dir} -> if contained?(dir, root), do: {:ok, dir}, else: {:error, :not_found}
          nil -> {:error, :not_found}
        end
    end
  end

  defp contained?(dir, root) do
    dir = Path.expand(dir)
    root = Path.expand(root)
    dir != root and String.starts_with?(dir, root <> "/")
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
