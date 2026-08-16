defmodule OptimalSystemAgent.Workspace.ProjectResource do
  @moduledoc """
  The ONE boundary every project-scoped resource loader passes through.

  ## The property

  **A project-scoped resource cannot escalate.** A repository you clone may
  narrow what the agent does (context, instructions, disabled markers) but it
  may never widen it — not permissions, not the tool set, not the system
  prompt, not what gets executed — until the user accepts trust for that
  directory.

  ## Why this module exists rather than a gate per loader

  Trust gating grew one call site at a time: `Settings.trusted_layer/1` for
  `.osa/settings.json`, then `.osa/settings.local.json` after the first gate
  was bypassed by renaming the file, then `MCP.Config.load_startup/0`, then
  `Agents.Registry.discover_agent_dirs/1`. Four hand-rolled copies of the same
  predicate, each written when its own hole was found. `SkillLoader` was the
  fifth such loader and had no gate at all — a checked-out repo's
  `.osa/skills/<name>/SKILL.md` was discovered, and because the `:local` scope
  outranks `:bundled`, it **silently replaced a bundled skill's instructions**.
  That is the same class as a repo replacing the system prompt.

  A per-loader gate is a thing someone has to remember. This module is the
  thing they cannot forget, because it classifies **by where the file lives**,
  not by what the calling loader claims its scope is:

    * `machine_authored?/1` — the path is under a config directory this user
      owns (`~/.osa`, `~/.claude`, …, `$OSA_HOME`, the configured skills dir)
      or inside the application's own `priv/`. Always admitted.
    * everything else reachable from the working directory is
      **workspace-supplied** and is withheld until trust is accepted.

  So a loader that mislabels its scopes, or a new resource type wired up by
  someone who has never read this file, still lands inside the gate as long as
  its roots go through `admit/3`. `test/security/untrusted_project_resources_test.exs`
  carries a source-level guard that fails when a new `.osa`/`.claude` project
  subtree scan appears outside the set of modules known to route through here.

  ## Behaviour under overdrive

  Nothing changes. Workspace trust is a **provenance gate on loading config**,
  not a runtime permission prompt, and it is evaluated independently of
  `permission_mode`. Under `overdrive` (full auto, no prompts) a hostile clone's
  `.osa/settings.json`, agents, MCP servers and skills are still withheld —
  overdrive means "do not ask me before each action", not "trust whatever
  directory I happen to be standing in". This matters precisely because
  overdrive is the mode where a silently-granted `bypassPermissions` would
  never produce a prompt for the user to notice.

  Automation that legitimately needs policy without a trust prompt uses the
  machine-authored path: `OSA_SETTINGS` / `--settings` (the `:flag` layer),
  `~/.osa/**`, or an explicit `/trust accept`. The safe path is the default one.

  ## Fail closed

  Every predicate rescues and catches to `false` / "withhold". A Trust store
  that is corrupt, unreadable or raising must never read as "trusted", and an
  unresolvable path must never be admitted with default trust.
  """

  require Logger

  alias OptimalSystemAgent.Workspace.Cwd
  alias OptimalSystemAgent.Workspace.Trust

  # Config directory names a project may carry. Kept in one place so the
  # source-level coverage guard and the loaders agree on what counts.
  @config_dir_names ~w(.osa .claude .agents .grok .cursor)

  @doc "The config directory basenames that make a subtree project-scoped config."
  @spec config_dir_names() :: [String.t()]
  def config_dir_names, do: @config_dir_names

  # ── Trust ─────────────────────────────────────────────────────────────

  @doc """
  True when `cwd` (default: the process working directory) has accepted trust.

  This is the single fail-closed definition; `Settings.project_trusted?/0` and
  the loaders below all resolve through it so there is exactly one answer to
  "is this workspace trusted" in the codebase.
  """
  @spec trusted?(String.t() | nil) :: boolean()
  def trusted?(cwd \\ nil) do
    Trust.trusted?(cwd || Cwd.get())
  rescue
    _ -> false
  catch
    :exit, _ -> false
    _, _ -> false
  end

  # ── Classification ────────────────────────────────────────────────────

  @doc """
  True when `path` was authored on this machine by the operator rather than
  supplied by the checked-out workspace.

  Machine-authored means: under one of this user's home config directories,
  under `$OSA_HOME`, under the configured `:skills_dir`, or inside the
  application's own `priv/` tree (bundled assets that ship with OSA).

  Note the deliberate ordering with `workspace_scoped?/2`: when the working
  directory *is* the home config dir, machine-authored wins. `Trust` already
  refuses to persist a grant over `$HOME`, and a user's own `~/.osa` is not a
  repository someone handed them.
  """
  @spec machine_authored?(String.t()) :: boolean()
  def machine_authored?(path) do
    abs = expand(path)
    Enum.any?(machine_roots(), &under?(abs, &1))
  rescue
    # Cannot classify ⇒ not machine-authored ⇒ gated. Fail closed.
    _ -> false
  end

  @doc """
  True when `path` is supplied by the workspace: it lives under `cwd` or under
  one of `cwd`'s ancestors, and it is not machine-authored.

  Ancestors count because every project loader in this codebase walks upward
  (to the git root, or bounded) collecting config directories — a `.osa/skills`
  two levels above the cwd is still delivered by the same clone.
  """
  @spec workspace_scoped?(String.t(), String.t() | nil) :: boolean()
  def workspace_scoped?(path, cwd \\ nil) do
    abs = expand(path)
    root = expand(cwd || Cwd.get())

    not machine_authored?(abs) and Enum.any?(ancestor_chain(root), &under?(abs, &1))
  rescue
    # An unresolvable path is treated as workspace-supplied, i.e. withheld.
    _ -> true
  end

  # ── The gate ──────────────────────────────────────────────────────────

  @doc """
  Admit a list of resource roots, withholding every workspace-supplied one
  until the workspace is trusted.

  Accepts a list of bare paths or of `{tag, path}` tuples (the shape both
  `SkillLoader` and `Agents.Registry` already use) and returns the same shape.

  `kind` is an atom naming the resource for the log line — `:skills`,
  `:agents`, … — and is used only for diagnostics.

  Options:
    * `:cwd`  — working directory the roots were discovered from.
    * `:why`  — one clause explaining what this resource type can do if
      admitted, appended to the withholding warning. A silently dropped
      resource is its own bug: the operator must be told the files are being
      WITHHELD pending trust, not that they are missing or broken.
  """
  @spec admit([entry], atom(), keyword()) :: [entry] when entry: String.t() | {term(), String.t()}
  def admit(entries, kind, opts \\ []) when is_list(entries) do
    cwd = Keyword.get(opts, :cwd) || Cwd.get()

    {workspace, machine} =
      Enum.split_with(entries, fn entry -> workspace_scoped?(path_of(entry), cwd) end)

    cond do
      workspace == [] -> machine
      trusted?(cwd) -> entries
      true -> warn_withheld(workspace, machine, kind, cwd, Keyword.get(opts, :why))
    end
  rescue
    e ->
      # A crash in the gate must not admit the workspace. Drop everything we
      # cannot prove is machine-authored.
      Logger.warning("[ProjectResource] admit/#{kind} failed closed: #{Exception.message(e)}")
      Enum.filter(entries, fn entry -> machine_authored?(path_of(entry)) end)
  end

  defp path_of({_tag, path}), do: path
  defp path_of(path) when is_binary(path), do: path

  # Once per {kind, cwd, root set} so it is visible without spamming a session.
  defp warn_withheld(workspace, machine, kind, cwd, why) do
    key = {__MODULE__, :withheld, kind, cwd, :erlang.phash2(Enum.map(workspace, &path_of/1))}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.warning(
        "[ProjectResource] WITHHOLDING #{length(workspace)} workspace-supplied #{kind} " <>
          "source(s) (#{Enum.map_join(workspace, ", ", &path_of/1)}) — this workspace has not " <>
          "been trusted yet." <>
          if(why, do: " " <> why, else: "") <>
          " They are ignored, not broken: run `/trust accept` (or accept the trust dialog) to " <>
          "apply them. This holds in overdrive too — overdrive skips permission prompts, it " <>
          "does not trust the directory. Automation should express policy through " <>
          "OSA_SETTINGS / --settings, which needs no workspace trust."
      )
    end

    machine
  rescue
    _ -> machine
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp machine_roots do
    home = expand("~")

    configured =
      [
        System.get_env("OSA_HOME"),
        Application.get_env(:optimal_system_agent, :skills_dir),
        Application.get_env(:optimal_system_agent, :commands_dir)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&expand/1)

    priv =
      case :code.priv_dir(:optimal_system_agent) do
        {:error, _} -> []
        dir -> [expand(to_string(dir))]
      end

    Enum.map(@config_dir_names, &Path.join(home, &1)) ++ configured ++ priv
  rescue
    _ -> []
  end

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp ancestor_chain(path), do: collect_up(path, [])

  defp collect_up(dir, acc) do
    parent = Path.dirname(dir)
    if parent == dir, do: [dir | acc], else: collect_up(parent, [dir | acc])
  end

  defp expand(path), do: Path.expand(path)
end
