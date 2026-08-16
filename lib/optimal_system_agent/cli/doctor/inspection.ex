defmodule OptimalSystemAgent.CLI.Doctor.Inspection do
  @moduledoc """
  `osa doctor --config` — what is actually loaded, from where, and why.

  ## The problem this exists to solve

  OSA reads instructions from at least fourteen filesystem locations across four
  precedence systems that do not share a resolver: `PromptLoader`'s two-tier
  prompt override, `Soul`'s bootstrap directory, `ContextDiscovery`'s
  seven-filename first-match-wins scan, `ProjectInstructions`' upward walk,
  `SkillLoader`'s four scopes, and `Settings`' five-layer cascade. Every one of
  them fails **silently and successfully**: a missing file, a file whose YAML
  frontmatter does not parse, a `.osa/settings.json` withheld pending workspace
  trust, and a `BOOTSTRAP.md` switched off because `USER.md` has a name in it are
  all indistinguishable from "working fine" at every existing surface.

  That is the failure this report is for. It answers three questions:

    * **which markdown files are loaded**, from where, in what precedence,
    * **which skills are loaded**, from which directory, and why each is or is
      not surfaced,
    * **which file and which layer produced a given effective setting.**

  ## Design: a parallel resolver, never an instrumented one

  Every check here re-reads the same inputs in the same order purely to report
  on them, and cannot change what wins — the pattern `Runtime.Identity.describe/0`
  already sets for the model-resolution chain. Nothing in this module is on a
  hot path, so it re-stats files rather than trusting a cache: a report that
  agrees with a stale cache instead of the disk would defeat its own purpose.

  Where a gate is private (`Agent.Context`'s `user_known?/1` used to be)
  the condition is now delegated to that function rather than re-implemented.

  ## Reporting rules

    * Never print a bare value. Every line carries a path and a layer.
    * "Absent" is a finding, not a blank. An expected-and-missing file is stated.
    * "Loaded but malformed" is the loudest state, because a silently
      misparsed instruction file is the exact failure this surface exists to
      catch — the agent reads *something*, just not what the author wrote.
    * "Loaded but inert" (shadowed, withheld, gated off) is distinguished from
      "not there". Those need opposite fixes and used to look identical.
  """

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  @app :optimal_system_agent
  @separator "────────────────────────────────────────────────────────────"

  @doc """
  Kept so existing `osa doctor --config` tests still compile.

  The BOOTSTRAP.md gate is no longer a private copy — `user_known_regex/0`
  and `user_known?/1` now come from `Agent.Context`.
  """
  @spec mirrors_private_gate?() :: boolean()
  def mirrors_private_gate?, do: false

  @doc "The regex `Agent.Context.user_known?/1` uses to decide the BOOTSTRAP.md gate."
  @spec user_known_regex() :: Regex.t()
  def user_known_regex, do: Context.user_known_regex()

  @doc "Print the full inspection report."
  @spec run() :: :ok
  def run do
    _ = Application.load(@app)

    IO.puts("")
    IO.puts("OSA Setup Inspection")
    IO.puts(@separator)

    Enum.each(sections(), fn {title, rows} -> section(title, rows) end)

    print_legend()
    :ok
  end

  @doc """
  The same report as data, for the TUI and the `/doctor` HTTP endpoint.

  Shape: `%{sections: [%{title, rows: [%{status, label, path, layer, detail}]}]}`
  with `status` one of `:loaded | :absent | :inert | :malformed`. Kept
  structurally identical to what `run/0` prints so the two can never disagree.
  """
  @spec report() :: %{sections: [map()]}
  def report do
    _ = Application.load(@app)

    %{sections: Enum.map(sections(), fn {title, rows} -> %{title: title, rows: rows} end)}
  end

  # Each section is computed behind its own guard. A diagnostic that dies
  # halfway through is worse than one that reports a broken section: the reader
  # cannot tell "settings are fine" from "the settings check crashed", and the
  # sections after it vanish with no indication they were ever meant to be there.
  defp sections do
    [
      {"INSTRUCTION FILES — static base (Soul / PromptLoader)", &prompt_rows/0},
      {"INSTRUCTION FILES — per-turn (Agent.Context)", &dynamic_rows/0},
      {"SKILLS", &skill_rows/0},
      {"SETTINGS — layers", &settings_layer_rows/0},
      {"SETTINGS — effective keys", &settings_key_rows/0}
    ]
    |> Enum.map(fn {title, fun} -> {title, guarded(title, fun)} end)
  end

  defp guarded(title, fun) do
    fun.()
  rescue
    e ->
      [
        row(
          :malformed,
          "(section failed)",
          "-",
          "inspection",
          "this check itself raised #{inspect(e.__struct__)}: #{Exception.message(e)} — " <>
            "the section below is missing, not empty. Treat '#{title}' as unknown."
        )
      ]
  catch
    :exit, reason ->
      [
        row(
          :malformed,
          "(section failed)",
          "-",
          "inspection",
          "this check exited: #{inspect(reason)} — '#{title}' is unknown, not empty."
        )
      ]
  end

  # ── Section 1: static prompt tier ─────────────────────────────────────

  defp prompt_rows do
    prompt_override_rows() ++ soul_rows() ++ [rules_row()] ++ static_base_rows()
  end

  # PromptLoader: `~/.osa/prompts/<KEY>.md` beats `priv/prompts/<KEY>.md`.
  # Reported as ONE row per key naming the winner, plus the loser when a loser
  # exists — "which of my two SYSTEM.md files is live" being the entire question.
  defp prompt_override_rows do
    user_dir = Path.expand("~/.osa/prompts")
    bundled_dir = priv_subdir("prompts")

    for key <- ~w(SYSTEM IDENTITY SOUL compactor_summary compactor_key_facts cortex_synthesis) do
      filename = "#{key}.md"
      user_path = Path.join(user_dir, filename)
      bundled_path = bundled_dir && Path.join(bundled_dir, filename)

      cond do
        readable_nonempty?(user_path) ->
          shadowed =
            if bundled_path && readable_nonempty?(bundled_path),
              do: " (shadows bundled #{tilde(bundled_path)})",
              else: ""

          row(:loaded, key, user_path, "user override", "#{bytes(user_path)}#{shadowed}")

        File.exists?(user_path) ->
          # Present but empty — PromptLoader trims and treats it as nil, so the
          # bundled default silently wins. Looks like an override; is not one.
          row(
            :malformed,
            key,
            user_path,
            "user override",
            "file exists but is empty after trim — PromptLoader discards it and the " <>
              "bundled default is used instead"
          )

        bundled_path && readable_nonempty?(bundled_path) ->
          row(:loaded, key, bundled_path, "bundled", bytes(bundled_path))

        true ->
          row(
            :absent,
            key,
            user_path,
            "user override",
            "no user override and no bundled default — callers fall back to inline text"
          )
      end
    end
  end

  # Soul's own files, out of the configurable bootstrap dir.
  defp soul_rows do
    dir = bootstrap_dir()

    base =
      for name <- ~w(USER.md IDENTITY.md SOUL.md) do
        path = Path.join(dir, name)

        cond do
          readable_nonempty?(path) ->
            row(:loaded, name, path, "bootstrap dir", bytes(path))

          File.exists?(path) ->
            row(
              :malformed,
              name,
              path,
              "bootstrap dir",
              "exists but is empty after trim — Soul stores nil, so the corresponding " <>
                "prompt placeholder is interpolated away entirely"
            )

          true ->
            row(:absent, name, path, "bootstrap dir", "not present; placeholder renders empty")
        end
      end

    base ++ agent_soul_rows(dir)
  end

  defp agent_soul_rows(dir) do
    agents_dir = Path.join(dir, "agents")

    case File.ls(agents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        |> Enum.sort()
        |> Enum.map(fn agent ->
          agent_dir = Path.join(agents_dir, agent)

          present =
            Enum.filter(~w(IDENTITY.md SOUL.md), &readable_nonempty?(Path.join(agent_dir, &1)))

          case present do
            [] ->
              row(
                :inert,
                "agents/#{agent}",
                agent_dir,
                "per-agent soul",
                "directory exists but neither IDENTITY.md nor SOUL.md is readable and " <>
                  "non-empty, so Soul.for_agent/1 falls back to the default soul"
              )

            files ->
              row(
                :loaded,
                "agents/#{agent}",
                agent_dir,
                "per-agent soul",
                Enum.join(files, " + ")
              )
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        [
          row(
            :malformed,
            "agents/",
            agents_dir,
            "per-agent soul",
            "cannot be listed: #{:file.format_error(reason)} — per-agent souls are silently skipped"
          )
        ]
    end
  end

  defp rules_row do
    dir = priv_subdir("rules")

    cond do
      is_nil(dir) or not File.dir?(dir) ->
        row(
          :absent,
          "{{RULES}}",
          dir || "priv/rules",
          "bundled",
          "priv/rules/ not found — the RULES placeholder interpolates to empty"
        )

      true ->
        files = Path.wildcard(Path.join(dir, "**/*.md")) |> Enum.sort()

        case files do
          [] ->
            row(:absent, "{{RULES}}", dir, "bundled", "directory exists but holds no .md files")

          fs ->
            names = fs |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.join(", ")
            row(:loaded, "{{RULES}}", dir, "bundled", "#{length(fs)} rule file(s): #{names}")
        end
    end
  end

  # The one row that reports the OUTPUT rather than an input: whether the cached
  # static base was actually built, and how big it is. A 0-token base with every
  # input file present means interpolation failed, which no input row can show.
  # Deliberately a NON-forcing read.
  #
  # `Soul.static_token_count/0` calls `static_base/0`, which on a cache miss
  # assembles the prompt and `:persistent_term.put/2`s the result. That is a
  # global mutation — and `:persistent_term.put/2` additionally triggers a
  # system-wide GC scan across every live process. Calling it from a diagnostic
  # made an otherwise-green suite fail eighteen unrelated tests, because the
  # report was building the very cache the rest of the system was observing.
  #
  # A diagnostic must not perturb what it measures. So this reads the cached
  # slot directly and reports "not assembled yet" as a genuine state rather than
  # manufacturing a value to print.
  # One row per VARIANT, because there is no single "the static base".
  #
  # This read only the `:full` slot, so it reported ~31k while an Anthropic
  # session — which uses the `:native_tools` variant, with the spans that
  # duplicate the request's own tool schemas removed — actually sends ~16k. A
  # diagnostic that is 15k tokens wrong about the prefix is worse than silent:
  # it is what someone budgets a context window against.
  #
  # Still strictly NON-FORCING (see below): a variant that has never been
  # assembled is simply not reported, rather than being built to be printed.
  defp static_base_rows do
    case cached_static_variants() do
      [] ->
        [static_base_row(:full, nil)]

      variants ->
        Enum.map(variants, fn {variant, tokens} -> static_base_row(variant, tokens) end)
    end
  end

  # Which slot a live request actually uses is decided per turn by
  # `Agent.Context.static_base_variant/2`, so each row says who it is for.
  defp variant_label(:full), do: "static base (assembled)"
  defp variant_label(:lite), do: "static base (lite)"
  defp variant_label(:native_tools), do: "static base (native-tools dedup)"

  defp variant_note(:full), do: "used by providers that inline every tool schema in the prompt"

  defp variant_note(:lite),
    do:
      "used by local providers and windows under 40k — core tools inlined, the rest via tool_search"

  defp variant_note(:native_tools),
    do:
      "used when the transport carries the tool schemas itself (e.g. Anthropic) — this is the size those sessions send"

  defp static_base_row(variant, tokens) do
    cond do
      is_nil(tokens) ->
        row(
          :absent,
          variant_label(variant),
          "(persistent_term cache)",
          "runtime",
          "not assembled yet — the cache is populated lazily on the first turn, and this " <>
            "report deliberately does not trigger it. Run `/doctor --config` from inside a " <>
            "live session to see the assembled size."
        )

      tokens > 0 and not registry_running?() ->
        # `osa doctor` runs from a cold VM (`mix run --no-start`), where
        # Tools.Registry is not up and `{{TOOL_DEFINITIONS}}` interpolates to
        # nothing. Reporting the resulting ~87 tokens as *the* static base would
        # be off by more than two orders of magnitude — precisely the kind of
        # confidently-wrong number a diagnostic must never print.
        row(
          :inert,
          variant_label(variant),
          "(persistent_term cache)",
          "runtime",
          "#{tokens} tokens measured WITHOUT tool definitions — Tools.Registry is not " <>
            "running, so {{TOOL_DEFINITIONS}} interpolated to empty. This is not the size " <>
            "a live session sends. Run `/doctor --config` inside a session for the real figure."
        )

      tokens > 0 ->
        row(
          :loaded,
          variant_label(variant),
          "(persistent_term cache)",
          "runtime",
          "#{tokens} tokens — #{variant_note(variant)}"
        )

      true ->
        row(
          :malformed,
          variant_label(variant),
          "(persistent_term cache)",
          "runtime",
          "assembled to 0 tokens — the template resolved but produced nothing. Every " <>
            "turn is being sent without a system prompt."
        )
    end
  end

  # ── Section 2: per-turn dynamic tier ──────────────────────────────────

  defp dynamic_rows do
    [bootstrap_row()] ++ project_context_rows() ++ project_instruction_rows()
  end

  # BOOTSTRAP.md is the sharpest "loaded but inert" case in the codebase: it is
  # switched off by a name appearing in a DIFFERENT file, so a user looking at a
  # present, well-formed BOOTSTRAP.md has no way to see that it is not in the
  # prompt.
  defp bootstrap_row do
    dir = bootstrap_dir()
    path = Path.join(dir, "BOOTSTRAP.md")
    user_md = Path.join(dir, "USER.md")
    known? = Context.user_known?(dir)

    cond do
      not File.exists?(path) ->
        row(
          :absent,
          "BOOTSTRAP.md",
          path,
          "bootstrap dir",
          "not present — no 'get to know the user' block is injected"
        )

      not readable_nonempty?(path) ->
        row(
          :malformed,
          "BOOTSTRAP.md",
          path,
          "bootstrap dir",
          "exists but is empty after trim — treated as absent"
        )

      known? ->
        row(
          :inert,
          "BOOTSTRAP.md",
          path,
          "bootstrap dir",
          "present and well-formed, but NOT injected: #{tilde(user_md)} already has a " <>
            "'- **Name:** …' line, which is the completion signal that switches this " <>
            "block off. Clear that line to re-enable it."
        )

      true ->
        row(
          :loaded,
          "BOOTSTRAP.md",
          path,
          "bootstrap dir",
          "injected each turn as '## GET TO KNOW THE USER' — will switch itself off once " <>
            "#{tilde(user_md)} has a '- **Name:** …' line"
        )
    end
  end

  # ContextDiscovery: first match wins across BOTH loops, and exactly one file is
  # front-loaded. Every other candidate is reported as shadowed, because "I added
  # CLAUDE.md and nothing changed" is precisely the AGENTS.md-already-exists case.
  @context_files [
    ".osa/context.md",
    ".osa/CONTEXT.md",
    "AGENTS.md",
    "agents.md",
    "CLAUDE.md",
    "claude.md",
    ".cursorrules"
  ]

  defp project_context_rows do
    dirs = context_search_dirs()

    candidates =
      for d <- dirs, f <- @context_files, path = Path.join(d, f), File.regular?(path), do: path

    case candidates do
      [] ->
        [
          row(
            :absent,
            "project context",
            Enum.join(Enum.map(dirs, &tilde/1), ", "),
            "ContextDiscovery",
            "none of #{Enum.join(@context_files, ", ")} found in any search directory"
          )
        ]

      [winner | shadowed] ->
        [
          context_row(
            winner,
            :loaded,
            "front-loaded as '## Project Context (#{Path.basename(winner)})'"
          )
        ] ++
          Enum.map(shadowed, fn p ->
            context_row(
              p,
              :inert,
              "present but NOT loaded — #{tilde(winner)} won on precedence (directory " <>
                "order first, then filename order). Only ONE project-context file is ever used."
            )
          end)
    end
  end

  # The injection scanner is the reason a perfectly readable file can end up
  # contributing nothing, so it is evaluated per candidate rather than assumed.
  defp context_row(path, status, detail) do
    case injection_status(path) do
      {:blocked, reason} ->
        row(
          :malformed,
          "project context",
          path,
          "ContextDiscovery",
          "REJECTED by the prompt-injection scanner (#{inspect(reason)}) — the file is " <>
            "readable but contributes NOTHING to the prompt, and only a debug log says so"
        )

      :ok ->
        row(status, "project context", path, "ContextDiscovery", detail)
    end
  end

  @instruction_files [
    "AGENTS.md",
    "agents.md",
    "CLAUDE.md",
    "claude.md",
    "GROK.md",
    ".grok/GROK.md"
  ]

  # ProjectInstructions is lazy — it only fires for directories the agent has
  # actually touched — so a static report cannot say "this WILL load". It says
  # what exists and what would gate it, which is the honest version.
  defp project_instruction_rows do
    root = workspace_root()

    found =
      for f <- @instruction_files,
          path = Path.join(root, f),
          File.regular?(path),
          do: path

    # PRUNE while walking, do not filter afterwards.
    #
    # This was `Path.wildcard("**/{AGENTS.md,...}", match_dot: true)` followed
    # by `reject(&vendored?/1)`. `Path.wildcard` has no exclusions, so it
    # enumerated the ENTIRE tree first — `.git` included, because of
    # `match_dot: true` — and only then discarded the vendored hits.
    #
    # Measured in this repository: 604,157 files. `Inspection.report/0` did not
    # complete in 300 seconds, so `osa doctor` was effectively broken, and the
    # doctor test suite was burning six and a half minutes at 213% CPU. It grew
    # unbounded with the checkout, so any repo with a large `_build`, `deps`,
    # `node_modules` or a directory of build artefacts hit it.
    #
    # Pruned descent visits only directories that can contain a hit, and stops
    # at a bounded depth: these files live near the root by convention, and an
    # unbounded search for them was never buying anything.
    nested =
      root
      |> find_agent_docs(@agent_doc_max_depth)
      |> Enum.reject(fn p -> Path.dirname(p) == root end)
      |> Enum.sort()
      |> Enum.take(20)

    root_rows =
      case found do
        [] ->
          [
            row(
              :absent,
              "root instructions",
              root,
              "ProjectInstructions",
              "no #{Enum.join(@instruction_files, "/")} at the workspace root"
            )
          ]

        [w | rest] ->
          [
            row(
              :loaded,
              "root instructions",
              w,
              "ProjectInstructions",
              "front-loaded by ContextDiscovery; explicitly EXCLUDED from the upward walk " <>
                "so it is never injected twice"
            )
          ] ++
            Enum.map(rest, fn p ->
              row(
                :inert,
                "root instructions",
                p,
                "ProjectInstructions",
                "shadowed by #{Path.basename(w)} — one file per directory, first filename wins"
              )
            end)
      end

    nested_rows =
      Enum.map(nested, fn p ->
        row(
          :loaded,
          "nested instructions",
          p,
          "ProjectInstructions",
          "LAZY — injected only after the agent reads or edits a file under " <>
            "#{tilde(Path.dirname(p))}, then claimed for the rest of the session"
        )
      end)

    root_rows ++ nested_rows
  end

  # ── Section 3: skills ─────────────────────────────────────────────────

  # Delegates surfacing to `SkillLoader.surfaced?/2` and `path_matches_glob?/2`
  # — the real predicates the model-facing listing uses — rather than restating
  # the rule, so this report cannot drift from the behaviour it describes.
  defp skill_rows do
    skills = SkillLoader.load_skills()
    touched = touched_paths()

    if map_size(skills) == 0 do
      [
        row(
          :absent,
          "(no skills)",
          skill_roots_hint(),
          "SkillLoader",
          "no SKILL.md found in any local/repo/user/bundled scope"
        )
      ]
    else
      skills
      |> Map.values()
      |> Enum.sort_by(&{&1.scope, &1.name})
      |> Enum.map(&skill_row(&1, touched))
    end
  rescue
    e ->
      [
        row(
          :malformed,
          "(skill scan failed)",
          "-",
          "SkillLoader",
          "#{inspect(e.__struct__)}: #{Exception.message(e)}"
        )
      ]
  end

  defp skill_row(entry, touched) do
    scope = "#{entry.scope} scope"

    cond do
      fallback_parse?(entry) ->
        row(
          :malformed,
          entry.name,
          entry.path,
          scope,
          "YAML frontmatter missing, unterminated within the first 4096 bytes, or " <>
            "invalid — the loader fell back to naming the skill after its directory and " <>
            "using the first 100 raw characters as its description. It IS listed to the " <>
            "model, just not as authored: triggers, tools and paths were all dropped."
        )

      is_list(entry.paths) and entry.paths != [] ->
        matched =
          Enum.find(touched, fn p ->
            Enum.any?(entry.paths, &SkillLoader.path_matches_glob?(p, &1))
          end)

        if matched do
          row(
            :loaded,
            entry.name,
            entry.path,
            scope,
            "surfaced — paths: #{Enum.join(entry.paths, ", ")} matched touched path #{matched}"
          )
        else
          row(
            :inert,
            entry.name,
            entry.path,
            scope,
            "NOT surfaced — gated behind paths: #{Enum.join(entry.paths, ", ")}, and " <>
              "#{touched_summary(touched)}. It loads only once a matching file is read or edited."
          )
        end

      disabled?(entry) ->
        row(
          :inert,
          entry.name,
          entry.path,
          scope,
          "NOT surfaced — a .disabled marker exists beside it in the skills directory"
        )

      true ->
        row(
          :loaded,
          entry.name,
          entry.path,
          scope,
          "surfaced unconditionally (no paths: gate) — priority #{entry.priority}, " <>
            "triggers: #{trigger_summary(entry)}"
        )
    end
  end

  # ── Section 4/5: settings ─────────────────────────────────────────────

  @layers [:user, :project, :local, :flag, :session]

  defp settings_layer_rows do
    paths = layer_paths()

    Enum.map(@layers, fn layer ->
      path = Map.get(paths, layer)
      data = safe_layer(layer)

      cond do
        layer == :session ->
          row(
            if(map_size(data) == 0, do: :absent, else: :loaded),
            "session",
            "(in-memory)",
            "session",
            "#{map_size(data)} key(s) — not persisted, lost on exit"
          )

        is_nil(path) ->
          row(
            :absent,
            to_string(layer),
            "(unset)",
            to_string(layer),
            "OSA_SETTINGS is not set, so there is no flag-file layer"
          )

        not File.exists?(path) ->
          row(:absent, to_string(layer), path, to_string(layer), "file not present")

        true ->
          settings_file_row(layer, path, data)
      end
    end)
  end

  defp settings_file_row(layer, path, data) do
    issues = safe_validate(path)
    errors = Enum.filter(issues, &(&1.severity == :error))

    # BOTH workspace-supplied layers are withheld until trust is accepted:
    # `.osa/settings.json` (:project) and `.osa/settings.local.json` (:local).
    withheld? = layer in [:project, :local] and map_size(data) > 0 and not trusted?()

    cond do
      errors != [] ->
        # The read path silently degrades a corrupt file to `%{}` with no
        # warning, so "my settings do nothing" and "my settings are invalid
        # JSON" look identical everywhere else in the system.
        row(
          :malformed,
          to_string(layer),
          path,
          to_string(layer),
          "PARSE/SCHEMA ERRORS — the file is ignored entirely and silently: " <>
            Enum.map_join(errors, "; ", fn i -> "#{i.key}: #{i.message} (#{i.tip})" end)
        )

      withheld? ->
        row(
          :inert,
          to_string(layer),
          path,
          to_string(layer),
          "#{map_size(data)} key(s) present but WITHHELD — this workspace has not been " <>
            "trusted, so permission rules, permission_mode and env from it are ignored. " <>
            "They are inert, not broken: run `/trust accept`."
        )

      issues != [] ->
        row(
          :loaded,
          to_string(layer),
          path,
          to_string(layer),
          "#{map_size(data)} key(s); #{length(issues)} warning(s): " <>
            Enum.map_join(issues, "; ", fn i -> "#{i.key}: #{i.message}" end)
        )

      true ->
        row(:loaded, to_string(layer), path, to_string(layer), "#{map_size(data)} key(s)")
    end
  end

  # Per-key provenance. The cascade folds layer identity away in `merged/0`, so
  # this recomputes the winner by walking the SAME layers in the SAME order,
  # highest first — reporting only, never deciding.
  defp settings_key_rows do
    by_layer = Map.new(@layers, fn l -> {l, safe_layer(l)} end)
    paths = layer_paths()

    keys =
      by_layer |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

    rows =
      if keys == [] do
        [row(:absent, "(no settings)", "-", "cascade", "every settings layer is empty")]
      else
        Enum.map(keys, fn key -> key_row(key, by_layer, paths) end)
      end

    unparseable_pin_rows() ++ rows
  end

  # The rows above read the RAW layers. That is right for provenance and wrong
  # for EFFECT: while any layer fails to parse, `Settings.merged/0` pins
  # `permission_mode` to "ask" and `permissions.defaultMode` to "default", and
  # nothing below would say so. Doctor would print the `bypassPermissions` the
  # operator configured beside a runtime that is in fact asking — a diagnostic
  # disagreeing with reality about permissions, which is worse than no
  # diagnostic, because the operator reads it as confirmation.
  #
  # `Settings.unparseable_sources/0` exists to report exactly this and had no
  # caller anywhere in `lib/`: the fail-closed pin was in force with no surface
  # that admitted it. This is that surface.
  defp unparseable_pin_rows do
    case safe_unparseable() do
      [] ->
        []

      paths ->
        [
          row(
            :malformed,
            "permission_mode",
            Enum.join(paths, ", "),
            "cascade (PINNED)",
            "the settings file(s) named here exist but do not parse, so Settings.merged/0 " <>
              "forces permission_mode=\"ask\" and permissions.defaultMode=\"default\" " <>
              "REGARDLESS of the values reported below. The deny rules in the broken file(s) " <>
              "cannot be recovered, so nothing is auto-approved while they are missing. Fix " <>
              "the JSON and the pin lifts."
          )
        ]
    end
  end

  defp safe_unparseable do
    Settings.unparseable_sources() |> Enum.filter(&is_binary/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp key_row(key, by_layer, paths) do
    present = Enum.filter(Enum.reverse(@layers), &Map.has_key?(by_layer[&1], key))
    [winner | shadowed] = present
    value = Map.fetch!(by_layer[winner], key)
    where = Map.get(paths, winner) || "(in-memory)"

    shadow_note =
      case shadowed do
        [] -> ""
        ls -> " — also set in #{Enum.map_join(ls, ", ", &to_string/1)}, shadowed"
      end

    # `deep_merge/2` recurses into maps and CONCATENATES lists, so for those the
    # effective value has contributors rather than a single winner. Saying "from
    # user" about a `permissions` list that three files fed into would be a
    # confident lie, which is worse than no report at all.
    cond do
      length(present) > 1 and is_list(value) ->
        combined = present |> Enum.flat_map(&Map.get(by_layer[&1], key, [])) |> Enum.uniq()

        row(
          :loaded,
          key,
          contributor_paths(present, paths),
          "MERGED (concat)",
          "list key — #{length(combined)} entries CONCATENATED across " <>
            "#{Enum.map_join(present, " + ", &to_string/1)}; no single layer owns it"
        )

      length(present) > 1 and is_map(value) ->
        row(
          :loaded,
          key,
          contributor_paths(present, paths),
          "MERGED (deep)",
          "map key — merged key-by-key across #{Enum.map_join(present, " + ", &to_string/1)}; " <>
            "run with a specific sub-key to see per-leaf provenance"
        )

      # `merged/0` (what `get/2` reads) includes the project layer; `merged_trusted/0`
      # (what every security-relevant read uses) does not. Reporting a
      # project-sourced key as plainly "loaded" would contradict the layer
      # section three lines above, and the contradiction is the interesting part:
      # the key applies to ordinary reads and is inert for permissions, hooks
      # and env until the workspace is trusted.
      winner in [:project, :local] and not trusted?() ->
        row(
          :inert,
          key,
          where,
          "#{winner} (untrusted)",
          "#{truncate(inspect(value), 70)}#{shadow_note} — visible to Settings.get/2 but " <>
            "WITHHELD from Settings.get_trusted/2, so it does not apply to permission " <>
            "rules, permission_mode, hooks or env. Run `/trust accept` to make it effective."
        )

      true ->
        row(
          :loaded,
          key,
          where,
          to_string(winner),
          "#{truncate(inspect(value), 90)}#{shadow_note}"
        )
    end
  end

  defp contributor_paths(layers, paths) do
    layers |> Enum.map(&(Map.get(paths, &1) || "(in-memory)")) |> Enum.join(" + ")
  end

  # ── Rendering ─────────────────────────────────────────────────────────

  defp section(title, rows) do
    IO.puts("")
    IO.puts(title)
    IO.puts(String.duplicate("─", String.length(title)))

    if rows == [] do
      IO.puts("  (nothing)")
    else
      Enum.each(rows, &print_row/1)
    end
  end

  defp print_row(%{status: status, label: label, path: path, layer: layer, detail: detail}) do
    IO.puts("  #{icon(status)} #{label}")
    IO.puts("      #{tilde(path)}  [#{layer}]")
    IO.puts("      #{wrap(detail)}")
  end

  defp icon(:loaded), do: "✓"
  defp icon(:absent), do: "○"
  defp icon(:inert), do: "–"
  defp icon(:malformed), do: "✗"

  defp print_legend do
    IO.puts("")
    IO.puts(@separator)
    IO.puts("  ✓ loaded     in effect right now")
    IO.puts("  – inert      present and well-formed, but NOT in effect (see reason)")
    IO.puts("  ✗ malformed  read, but not as authored — fix this first")
    IO.puts("  ○ absent     not present")
    IO.puts("")
  end

  defp wrap(text), do: text |> String.replace(~r/\s+/, " ") |> soft_wrap(92, "      ")

  defp soft_wrap(text, width, indent) do
    text
    |> String.split(" ")
    |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
      cond do
        cur == "" -> {lines, word}
        String.length(cur) + String.length(word) + 1 <= width -> {lines, cur <> " " <> word}
        true -> {[cur | lines], word}
      end
    end)
    |> then(fn {lines, cur} -> Enum.reverse([cur | lines]) end)
    |> Enum.join("\n" <> indent)
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp row(status, label, path, layer, detail) do
    %{
      status: status,
      label: to_string(label),
      path: to_string(path),
      layer: to_string(layer),
      detail: detail
    }
  end

  defp bootstrap_dir do
    Application.get_env(@app, :bootstrap_dir, "~/.osa") |> Path.expand()
  end

  defp priv_subdir(name) do
    case :code.priv_dir(@app) do
      {:error, _} -> if File.dir?("priv/#{name}"), do: Path.expand("priv/#{name}"), else: nil
      dir -> Path.join(to_string(dir), name)
    end
  end

  defp readable_nonempty?(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content) != ""
      _ -> false
    end
  end

  defp bytes(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> "#{s} bytes"
      _ -> "size unknown"
    end
  end

  defp context_search_dirs do
    OptimalSystemAgent.Agent.ContextDiscovery.search_dirs(cwd())
  rescue
    _ -> [cwd()]
  end

  defp injection_status(path) do
    case File.read(path) do
      {:ok, content} -> OptimalSystemAgent.Agent.ContextDiscovery.scan_for_injection(content)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp workspace_root do
    OptimalSystemAgent.Workspace.Cwd.get()
  rescue
    _ -> cwd()
  catch
    :exit, _ -> cwd()
  end

  defp cwd, do: File.cwd!()

  # `nil` = never assembled. Mirrors the key `Soul` writes; read-only by design,
  # see the comment on `static_base_row/0`.
  # The three variant slots `Soul` writes, in the order a reader wants them.
  # Kept as data so a new variant is one line here rather than a new branch.
  @static_slots [
    {:full, :static_base, :static_token_count},
    {:lite, :static_base_lite, :static_token_count_lite},
    {:native_tools, :static_base_native, :static_token_count_native}
  ]

  # Every variant that has ALREADY been assembled, with its token count.
  # Read-only by design, see the comment on `static_base_rows/0`: a slot that is
  # empty stays empty, and is simply absent from the report.
  defp cached_static_variants do
    Enum.flat_map(@static_slots, fn {variant, base_key, count_key} ->
      case :persistent_term.get({OptimalSystemAgent.Soul, base_key}, nil) do
        nil -> []
        _ -> [{variant, :persistent_term.get({OptimalSystemAgent.Soul, count_key}, 0)}]
      end
    end)
  rescue
    _ -> []
  end

  defp registry_running? do
    is_pid(Process.whereis(OptimalSystemAgent.Tools.Registry))
  rescue
    _ -> false
  end

  @vendored ~w(node_modules .git _build deps vendor target dist build .elixir_ls .venv)

  # How deep to look for AGENTS.md / CLAUDE.md / GROK.md. They are a
  # project-root convention; a handful of levels covers every real layout and
  # keeps the walk bounded regardless of checkout size.
  @agent_doc_max_depth 4

  @agent_doc_names ~w(AGENTS.md CLAUDE.md GROK.md)

  # Directories never worth descending into. Pruned BEFORE recursing, which is
  # the whole point — `vendored?/1` filtering results still pays for the walk.
  @never_descend ~w(.git _build deps node_modules .elixir_ls target
                    .venv venv __pycache__ dist .next .cache runs)

  defp find_agent_docs(_dir, depth) when depth < 0, do: []

  defp find_agent_docs(dir, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            entry in @agent_doc_names and File.regular?(path) ->
              [path]

            entry in @never_descend ->
              []

            String.starts_with?(entry, ".") ->
              # Dotfile directories are not where a project puts its agent doc,
              # and `.git` alone can be tens of thousands of files.
              []

            File.dir?(path) ->
              find_agent_docs(path, depth - 1)

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp vendored?(path) do
    parts = Path.split(path)
    Enum.any?(@vendored, &(&1 in parts))
  end

  defp touched_paths do
    case Process.get(:osa_session_id) do
      nil -> []
      sid -> SkillLoader.touched_paths(sid)
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp touched_summary([]),
    do:
      "no files have been touched this session (this report runs outside a live session, " <>
        "so the touched-path set is empty by construction)"

  defp touched_summary(paths), do: "none of the #{length(paths)} touched path(s) match"

  # The fallback entry is what SkillLoader produces when frontmatter fails to
  # parse: description becomes raw file text and every structured field is lost.
  defp fallback_parse?(entry) do
    is_nil(entry[:triggers]) or
      (entry[:description] || "") |> String.starts_with?("---")
  end

  # Canonical check, shared with the prompt builder and the CLI listing so the
  # doctor can never report "NOT surfaced" for a skill the prompt is shipping.
  defp disabled?(entry), do: OptimalSystemAgent.Tools.Registry.SkillLoader.disabled?(entry)

  defp trigger_summary(entry) do
    case entry[:triggers] do
      [] -> "none"
      nil -> "none"
      ts -> ts |> Enum.take(4) |> Enum.join(", ")
    end
  end

  defp skill_roots_hint do
    "#{cwd()}/{.osa,.claude,.agents,.grok}/skills, ~/.osa/skills, priv/skills"
  end

  defp layer_paths do
    [user, project, local | rest] = Settings.source_paths()

    %{user: user, project: project, local: local, flag: List.first(rest), session: nil}
  rescue
    _ -> %{}
  end

  defp safe_layer(layer) do
    Settings.layer(layer)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp safe_validate(path) do
    OptimalSystemAgent.Settings.Schema.validate_file(path)
  rescue
    _ -> []
  end

  defp trusted? do
    Settings.project_trusted?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp tilde(path) when is_binary(path) do
    home = System.user_home!()
    if String.starts_with?(path, home), do: "~" <> String.trim_leading(path, home), else: path
  rescue
    _ -> path
  end

  defp tilde(other), do: to_string(other)

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: String.slice(s, 0, n) <> "…"
end
