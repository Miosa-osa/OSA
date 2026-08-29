defmodule OptimalSystemAgent.Channels.CLI.Commands do
  @moduledoc """
  Slash command registry and dispatch for the CLI REPL.

  Commands are registered as `{handler_fn, description}` pairs in a static map.
  Dispatch parses the command name and arguments, routes to the handler, and
  returns the (possibly new) session_id.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{Compactor, ContextDiscovery, Loop, SessionPersistence, Tasks}
  alias OptimalSystemAgent.Agent.PromptOverrides
  alias OptimalSystemAgent.LocalModels
  alias OptimalSystemAgent.LocalModels.{Fit, Hardware}
  alias OptimalSystemAgent.Budget
  alias OptimalSystemAgent.Channels.CLI.{MessageQueue, Renderer, Session, TaskDisplay}
  alias OptimalSystemAgent.ContextRefs.Parser, as: ContextRefsParser
  alias OptimalSystemAgent.MCP
  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Sandbox.Router, as: SandboxRouter
  alias OptimalSystemAgent.Tools.Builtins.{SkillManager, UseSkill}
  alias OptimalSystemAgent.Tools.Registry, as: ToolsRegistry
  alias OptimalSystemAgent.Providers.Registry, as: ProviderRegistry

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @green IO.ANSI.green()
  @red IO.ANSI.red()

  @commands %{
    "help" => {"Show available commands", :cmd_help},
    "clear" => {"Clear conversation and start fresh session", :cmd_clear},
    "new" => {"Start a new session (alias for /clear)", :cmd_clear},
    "compact" => {"Force context compaction", :cmd_compact},
    "model" => {"Show or switch the current model (list = local Ollama models)", :cmd_model},
    "system" =>
      {"Inject into or replace the system prompt for the current model (persists)", :cmd_system},
    "models" =>
      {"Local models: what fits this machine, install, remove, load, unload, bench", :cmd_models},
    "uncensored" =>
      {"Hop the current model to its unfiltered twin (off to return)", :cmd_uncensored},
    "jailbreak" =>
      {"LIBERATE the active model — inject an operator override into every system prompt (off/show/file <path>)",
       :cmd_jailbreak},
    "status" => {"Show session status", :cmd_status},
    "cost" => {"Show cost breakdown", :cmd_cost},
    "usage" => {"Show account quota and this session's token usage", :cmd_usage},
    "context" => {"Show context window usage", :cmd_context},
    "revert" => {"Restore files to N mutating-tool steps ago (transcript kept)", :cmd_revert},
    "memory" => {"Show memory entries", :cmd_memory},
    "tools" => {"List available tools", :cmd_tools},
    "skills" => {"List, run, enable, disable, or create a skill", :cmd_skill},
    "skill" => {"List, run, enable, disable, or create a skill", :cmd_skill},
    "agents" => {"Runtime agent dashboard — live subagent runs and roles", :cmd_agents},
    "bg" => {"List background work — subagent runs and background commands", :cmd_bg},
    "fg" => {"Foreground a running agent/fleet node — switch the active session to it", :cmd_fg},
    "steer" => {"Inject a directive into the running turn (mid-turn steer)", :cmd_steer},
    "goal" => {"Anchor a goal the agent keeps working toward across turns", :cmd_goal},
    "loop" => {"Repeat a prompt on an explicit interval until stopped", :cmd_loop},
    "sessions" => {"List recent sessions", :cmd_sessions},
    "tasks" => {"Show current tasks", :cmd_tasks},
    "plan" => {"Toggle plan mode", :cmd_plan},
    "doctor" => {"Run health check", :cmd_doctor},
    "export" => {"Export conversation as markdown", :cmd_export},
    "save" => {"Save a readable snapshot of this session", :cmd_save},
    "version" => {"Show version and check for updates", :cmd_version},
    "release-notes" => {"Show what's new in this release", :cmd_release_notes},
    "coordinator" => {"Toggle coordinator mode (delegation only)", :cmd_coordinator},
    "ask-user" => {"Let the agent ask you questions mid-task (off by default)", :cmd_ask_user},
    "effort" => {"Set thinking effort level (low/medium/high/max)", :cmd_effort},
    "fast" => {"Toggle fast mode (low effort)", :cmd_fast},
    "permissions" => {"View and manage permission rules", :cmd_permissions},
    "hooks" => {"View registered hooks", :cmd_hooks},
    "metrics" => {"Show telemetry metrics", :cmd_metrics},
    "login" => {"Sign in to a provider account, or show sign-in status", :cmd_login},
    "logout" => {"Sign out of a provider account", :cmd_logout},
    "setup" => {"Re-run the setup wizard", :cmd_setup},
    "customize" => {"Make OSA yours — identity, skills, schedules, channels", :cmd_customize},
    "channels" => {"Show connected messaging channels", :cmd_channels},
    "resume" => {"Resume a previous session", :cmd_resume},
    "persona" => {"Show or switch persona preset", :cmd_persona},
    "mcp" => {"List MCP servers and connection status", :cmd_mcp},
    "init" => {"Scan the project and write an AGENTS.md guide", :cmd_init},
    "map" => {"Map the workspace — components, submodules, nested repos", :cmd_map},
    "copy" => {"Copy the last assistant reply", :cmd_copy},
    "files" => {"List files currently in context", :cmd_files},
    "rename" => {"Rename the current session", :cmd_rename},
    "tag" => {"Tag the current session for search", :cmd_tag},
    "sandbox" => {"Show or switch the sandbox backend", :cmd_sandbox},
    "add-dir" => {"Allow file access in an additional directory", :cmd_add_dir},
    "trust" => {"Show or accept workspace trust for this directory", :cmd_trust},
    "exit" => {"Exit OSA", :cmd_exit}
  }

  @init_guide "AGENTS.md"

  @doc "List all command names (for autocomplete)."
  def list, do: Map.keys(@commands) |> Enum.sort()

  @doc "List all commands with their descriptions as `{name, description}` tuples."
  def list_with_descriptions do
    @commands
    |> Enum.map(fn {name, {desc, _handler}} -> {name, desc} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Dispatch a slash command. Returns the (possibly new) session_id."
  def dispatch(input, session_id) do
    {cmd_name, args} = parse_command(input)

    case Map.get(@commands, cmd_name) do
      {_desc, handler} ->
        apply(__MODULE__, handler, [args, session_id])

      nil ->
        suggest_similar(cmd_name)
        session_id
    end
  end

  # ── Command Implementations ──────────────────────────────────────────

  def cmd_help(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Available Commands#{@reset}")
    IO.puts("")

    @commands
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.each(fn {name, {desc, _handler}} ->
      padded = String.pad_trailing("/#{name}", 16)
      IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}#{desc}#{@reset}")
    end)

    # User-defined custom commands from ~/.osa/commands/*.md (Claude-Code-style).
    custom =
      try do
        OptimalSystemAgent.Tools.Registry.CommandLoader.list_with_descriptions()
      rescue
        _ -> []
      end

    if custom != [] do
      IO.puts("")
      IO.puts("  #{@bold}Custom Commands#{@reset} #{@dim}(~/.osa/commands/)#{@reset}")
      IO.puts("")

      Enum.each(custom, fn {name, desc} ->
        padded = String.pad_trailing("/#{name}", 16)
        truncated = String.slice(desc, 0, 55)
        IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}#{truncated}#{@reset}")
      end)
    end

    IO.puts("")
    session_id
  end

  def cmd_clear(_args, session_id) do
    new_id = Session.start_new_session(session_id)
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    Renderer.print_banner()
    IO.puts("")
    new_id
  end

  def cmd_compact(args, session_id) do
    IO.puts("")
    IO.puts("  #{@dim}Compacting context...#{@reset}")

    # CC parity: `/compact <instructions>` threads user guidance into the
    # summary prompt via the proactive path; bare `/compact` keeps the
    # legacy reactive Loop.compact path.
    case String.trim(args || "") do
      "" ->
        compact_without_instructions(session_id)

      instructions ->
        case Loop.proactive_compact(session_id, instructions) do
          {:ok, stats} ->
            IO.puts(
              "  #{@green}#{@reset} Compacted: #{format_tokens(stats.tokens_before)} -> #{format_tokens(stats.tokens_after)}"
            )

          {:error, :no_session} ->
            IO.puts("  #{@yellow}error: no active session#{@reset}")

          {:error, reason} ->
            IO.puts("  #{@yellow}error: #{inspect(reason)}#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: compaction failed#{@reset}\n")
      session_id
  end

  # Bare `/compact` — original reactive compaction with before/after stats.
  defp compact_without_instructions(session_id) do
    case Loop.get_state(session_id) do
      {:ok, state} ->
        before_tokens = state[:tokens_used] || state[:estimated_tokens] || 0

        case Loop.compact(session_id) do
          :ok ->
            case Loop.get_state(session_id) do
              {:ok, after_state} ->
                after_tokens = after_state[:tokens_used] || after_state[:estimated_tokens] || 0
                saved = before_tokens - after_tokens
                pct = if before_tokens > 0, do: round(saved / before_tokens * 100), else: 0

                IO.puts(
                  "  #{@green}#{@reset} Compacted: #{format_tokens(before_tokens)} -> #{format_tokens(after_tokens)} (#{pct}% reduction)"
                )

              _ ->
                IO.puts("  #{@green}#{@reset} Compacted successfully")
            end

          {:error, reason} ->
            IO.puts("  #{@yellow}error: #{reason}#{@reset}")
        end

      _ ->
        IO.puts("  #{@yellow}error: no active session#{@reset}")
    end
  end

  # Which credential the current provider is actually using. Without this the
  # only difference between a plan-metered session and a pay-per-token one is
  # invisible until the bill arrives — and the two have opposite failure modes
  # (a window that resets vs a charge that does not).
  #
  # Pure read: `Subscription.status/1` never touches the network, so `/model`
  # cannot hang on, or be failed by, a token refresh.
  defp print_auth_mode(provider) do
    status = OptimalSystemAgent.Auth.Subscription.status(provider)

    cond do
      status.connected? and status.expired? ->
        IO.puts(
          "  #{@dim}Auth:#{@reset}      account sign-in #{@dim}(expired — re-run setup)#{@reset}"
        )

      status.connected? ->
        IO.puts("  #{@dim}Auth:#{@reset}      account sign-in#{plan_and_account(status)}")

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp plan_and_account(status) do
    parts = Enum.reject([status.plan, status.account], &(is_nil(&1) or &1 == ""))
    if parts == [], do: "", else: " #{@dim}(#{Enum.join(parts, ", ")})#{@reset}"
  end

  # For the Claude Code bridge the configured model is an ALIAS; the concrete
  # model is chosen downstream. Show what actually ran, once it is known, so
  # the header cannot claim a model OSA is not using.
  defp print_resolved_model(:claude_cli, alias_name) do
    case OptimalSystemAgent.Providers.ClaudeCli.last_resolved_model() do
      resolved when is_binary(resolved) and resolved != alias_name ->
        IO.puts(
          "  #{@dim}Running:#{@reset}   #{resolved} #{@dim}(resolved by Claude Code)#{@reset}"
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp print_resolved_model(_provider, _model), do: :ok

  def cmd_model(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      arg when arg in ["list", "ls", "local"] ->
        model_list_local(session_id)

      "" ->
        provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
        model = get_model_name(provider)
        ctx = ProviderRegistry.effective_context_window(model, provider)

        IO.puts("  #{@bold}Current Model#{@reset}")
        IO.puts("  #{@dim}Provider:#{@reset}  #{provider}")
        IO.puts("  #{@dim}Model:#{@reset}     #{model}")
        IO.puts("  #{@dim}Context:#{@reset}   #{format_context_window(ctx)} tokens")
        print_auth_mode(provider)
        print_resolved_model(provider, model)
        print_system_override_line(model)

      model_arg ->
        IO.puts("  #{@dim}Switching model...#{@reset}")

        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] ->
            {provider, model_name} =
              case parse_model_arg(model_arg) do
                {:explicit, prov, m} ->
                  {prov, m}

                {:model_only, m} ->
                  provider =
                    ProviderRegistry.provider_for_model(m) ||
                      Application.get_env(:optimal_system_agent, :default_provider, :ollama)

                  {provider, m}
              end

            case GenServer.call(pid, {:swap_provider, provider, model_name}, swap_call_timeout()) do
              {:ok, info} ->
                print_model_switch(info)

              {:error, reason} ->
                IO.puts("  #{@yellow}error: #{reason}#{@reset}")

              :ok ->
                IO.puts("  #{@green}#{@reset} Switched to #{model_name}")
            end

          _ ->
            IO.puts("  #{@yellow}error: session not found#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: model switch failed#{@reset}\n")
      session_id
  end

  # `/uncensored` — api.uncensored.com serves the SAME model ids OSA already
  # uses (`claude-opus-5`, `grok-4-6`, `gpt-5.6-sol`), so the useful default is
  # not "pick a model" but "keep this model, drop the filter": hop the current
  # model id to the uncensored provider and remember where we came from.
  #
  #   /uncensored          hop the current model across, if it exists there
  #   /uncensored <model>  switch to a specific uncensored model
  #   /uncensored off      go back to the provider/model we came from
  #   /uncensored list     show the advertised models
  def cmd_uncensored(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      arg when arg in ["list", "models"] -> uncensored_list()
      arg when arg in ["off", "back", "return"] -> uncensored_restore(session_id)
      "" -> uncensored_hop(session_id)
      model -> uncensored_switch(model, session_id)
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: uncensored switch failed#{@reset}\n")
      session_id
  end

  # `/model list` — what the local Ollama daemon can actually serve, so a tag
  # pulled outside OSA (`ollama pull hf.co/…`) is one copy-paste from `/model`.
  defp model_list_local(session_id) do
    {_provider, current} = session_provider_model(session_id)

    case OptimalSystemAgent.Providers.Ollama.list_models(
           OptimalSystemAgent.Providers.Ollama.local_daemon_url()
         ) do
      {:ok, []} ->
        IO.puts("  #{@dim}No local Ollama models. Pull one with `ollama pull <tag>`.#{@reset}")

      {:ok, models} ->
        IO.puts("  #{@bold}Local Ollama models#{@reset}")
        IO.puts("")

        models
        |> Enum.sort_by(& &1.name)
        |> Enum.each(fn m ->
          marker = if m.name == current, do: "#{@green}●#{@reset}", else: "#{@dim}•#{@reset}"
          IO.puts("  #{marker} #{m.name} #{@dim}#{format_gb(m.size)}#{@reset}")
        end)

        IO.puts("")
        IO.puts("  #{@dim}Switch with /model <tag>#{@reset}")

      {:error, reason} ->
        IO.puts("  #{@yellow}Ollama not reachable: #{inspect(reason)}#{@reset}")
    end
  end

  defp format_gb(0), do: ""
  defp format_gb(bytes) when is_integer(bytes), do: "#{Float.round(bytes / 1.0e9, 1)} GB"
  defp format_gb(_), do: ""

  # ── /system — operator system prompt overrides ────────────────────────────
  #
  #   /system                   status for the current model
  #   /system show              print the saved operator text
  #   /system inject <text>     append <text> to OSA's built-in prompt
  #   /system replace <text>    <text> becomes the WHOLE system prompt
  #   /system inject @file.md   read the text from a file (same for replace)
  #   /system off | on          disable / re-enable without deleting
  #   /system clear             delete the override for this model
  #   /system list              every saved override
  #
  # Add `--all` right after the verb to target every model ("*") instead of
  # the current one. Saved in ~/.osa/system_prompts.json; applies next turn.
  def cmd_system(args, session_id) do
    IO.puts("")
    {_provider, current} = session_provider_model(session_id)

    {verb, rest} =
      case String.split(String.trim(args), ~r/\s+/, parts: 2) do
        [""] -> {"", ""}
        [v] -> {String.downcase(v), ""}
        [v, r] -> {String.downcase(v), r}
      end

    {target, rest} = system_target(rest, current)

    case verb do
      "" -> system_status(current)
      "show" -> system_show(target)
      "list" -> system_list()
      v when v in ["inject", "add", "append"] -> system_set(target, :inject, rest)
      v when v in ["replace", "wipe", "only", "set"] -> system_set(target, :replace, rest)
      v when v in ["off", "disable"] -> system_enable(target, false)
      v when v in ["on", "enable"] -> system_enable(target, true)
      v when v in ["clear", "remove", "delete", "reset"] -> system_clear(target)
      v when v in ["file", "edit", "open"] -> system_file(target, rest)
      _ -> system_usage()
    end

    IO.puts("")
    session_id
  rescue
    e ->
      IO.puts("  #{@yellow}error: /system failed: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  # One line under `/model` so the overlay state is visible where the model is.
  defp print_system_override_line(model) do
    case PromptOverrides.effective(model) do
      nil ->
        IO.puts("  #{@dim}System:#{@reset}    default")

      {key, %{mode: mode}} ->
        scope = if key == PromptOverrides.all_key(), do: ", all models", else: ""
        IO.puts("  #{@dim}System:#{@reset}    custom (#{mode}#{scope}) — /system show")
    end
  end

  defp system_target(rest, current) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      ["--all" | tail] -> {PromptOverrides.all_key(), Enum.join(tail, "")}
      ["all" | tail] when tail != [] -> {PromptOverrides.all_key(), Enum.join(tail, "")}
      _ -> {current, rest}
    end
  end

  defp system_status(current) do
    IO.puts("  #{@bold}System prompt#{@reset}  #{@dim}model:#{@reset} #{current}")

    case PromptOverrides.effective(current) do
      nil ->
        own = PromptOverrides.get(current)

        if own && !own.enabled do
          IO.puts(
            "  #{@dim}Override saved but OFF (#{own.mode}, #{String.length(own.text)} chars) — /system on#{@reset}"
          )
        else
          IO.puts("  #{@dim}Built-in prompt only.#{@reset}")
          IO.puts("")

          IO.puts(
            "  #{@bold}Easiest:#{@reset} #{@cyan}/system file#{@reset} — creates #{PromptOverrides.file_for(current)}"
          )

          IO.puts(
            "  #{@dim}Write your prompt in it; it's live on the next message. No restart.#{@reset}"
          )

          IO.puts(
            "  #{@dim}Or inline: /system inject <text> · /system replace <text> · /system inject @file.md#{@reset}"
          )
        end

      {key, entry} ->
        scope =
          cond do
            key == PromptOverrides.all_key() -> "all models"
            String.ends_with?(key, "default.md") -> "all models, from file"
            String.ends_with?(key, ".md") -> "this model, from file #{key}"
            true -> "this model"
          end

        verb =
          if entry.mode == :replace,
            do: "REPLACES built-in prompt",
            else: "injected on top of built-in prompt"

        IO.puts(
          "  #{@green}ON#{@reset} #{verb} #{@dim}(#{scope}, #{String.length(entry.text)} chars)#{@reset}"
        )

        IO.puts("  #{@dim}/system show to print it · /system off · /system clear#{@reset}")
    end
  end

  defp system_show(target) do
    case PromptOverrides.get(target) do
      nil ->
        IO.puts("  #{@dim}Nothing saved for #{target}.#{@reset}")

      entry ->
        state = if entry.enabled, do: "#{@green}on#{@reset}", else: "#{@yellow}off#{@reset}"
        IO.puts("  #{@bold}#{target}#{@reset}  #{@dim}#{entry.mode}#{@reset}  #{state}")
        IO.puts("")
        IO.puts(entry.text)
    end
  end

  defp system_file(target, rest) do
    mode = if String.contains?(String.downcase(rest), "replace"), do: :replace, else: :inject

    case PromptOverrides.create_file(target, mode) do
      {:ok, path} ->
        IO.puts("  #{@green}✓#{@reset} #{path}")
        IO.puts("")
        IO.puts("  Open that file in any editor and write your prompt. It's picked up")
        IO.puts("  automatically on your next message — no command, no restart.")
        IO.puts("")

        IO.puts(
          "  #{@dim}The header inside sets the mode (inject = on top of OSA's prompt, replace = the whole prompt).#{@reset}"
        )

        IO.puts(
          "  #{@dim}/system to check it's active · /system clear to remove · /system file --all for every model#{@reset}"
        )

      {:error, reason} ->
        IO.puts("  #{@yellow}error: could not create prompt file: #{inspect(reason)}#{@reset}")
    end
  end

  defp system_list do
    overrides = PromptOverrides.list()
    files = PromptOverrides.list_files()

    if map_size(overrides) == 0 and map_size(files) == 0 do
      IO.puts("  #{@dim}No system prompt overrides saved.#{@reset}")

      IO.puts(
        "  #{@dim}/system file to create one, or drop a .md into #{PromptOverrides.prompts_dir()}#{@reset}"
      )
    else
      if map_size(files) > 0 do
        IO.puts(
          "  #{@bold}Prompt files#{@reset}  #{@dim}#{PromptOverrides.prompts_dir()}#{@reset}"
        )

        files
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.each(fn {model, {path, e}} ->
          IO.puts(
            "  #{@green}on #{@reset} #{@dim}#{String.pad_trailing(to_string(e.mode), 7)}#{@reset} #{model} #{@dim}(#{Path.basename(path)}, #{String.length(e.text)} chars)#{@reset}"
          )
        end)

        IO.puts("")
      end
    end

    if map_size(overrides) > 0 do
      IO.puts(
        "  #{@bold}Saved system prompt overrides#{@reset}  #{@dim}#{PromptOverrides.path()}#{@reset}"
      )

      IO.puts("")

      overrides
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {model, e} ->
        state = if e.enabled, do: "#{@green}on #{@reset}", else: "#{@yellow}off#{@reset}"

        IO.puts(
          "  #{state} #{@dim}#{String.pad_trailing(to_string(e.mode), 7)}#{@reset} #{model} #{@dim}(#{String.length(e.text)} chars)#{@reset}"
        )
      end)
    end
  end

  defp system_set(_target, _mode, ""), do: system_usage()

  defp system_set(target, mode, text) do
    case system_read_text(text) do
      {:ok, body} ->
        case PromptOverrides.set(target, mode, body) do
          :ok ->
            what =
              if mode == :replace,
                do: "now REPLACES the built-in prompt",
                else: "injected on top of the built-in prompt"

            IO.puts(
              "  #{@green}#{@reset} Saved for #{target} — #{what} #{@dim}(#{String.length(String.trim(body))} chars, takes effect next turn)#{@reset}"
            )

          {:error, reason} ->
            IO.puts("  #{@yellow}error: could not save: #{inspect(reason)}#{@reset}")
        end

      {:error, reason} ->
        IO.puts("  #{@yellow}error: #{reason}#{@reset}")
    end
  end

  # `@path` reads the text from a file — pasting a 3k-char prompt into a REPL
  # line is miserable; a file is not.
  defp system_read_text("@" <> path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, body} when byte_size(body) > 0 -> {:ok, body}
      {:ok, _} -> {:error, "#{expanded} is empty"}
      {:error, reason} -> {:error, "cannot read #{expanded}: #{:file.format_error(reason)}"}
    end
  end

  # Inline text: a REPL line has no newlines, so `\\n` / `\\t` are the way to
  # type a multi-line prompt. File contents are taken verbatim.
  defp system_read_text(text),
    do: {:ok, text |> String.replace("\\n", "\n") |> String.replace("\\t", "\t")}

  defp system_enable(target, enabled?) do
    case PromptOverrides.enable(target, enabled?) do
      :ok ->
        IO.puts(
          "  #{@green}#{@reset} Override for #{target} #{if enabled?, do: "ON", else: "OFF (text kept)"}"
        )

      {:error, :not_found} ->
        IO.puts("  #{@dim}Nothing saved for #{target}.#{@reset}")

      {:error, reason} ->
        IO.puts("  #{@yellow}error: #{inspect(reason)}#{@reset}")
    end
  end

  defp system_clear(target) do
    case PromptOverrides.clear(target) do
      :ok ->
        IO.puts("  #{@green}#{@reset} Cleared override for #{target} — built-in prompt restored")

      {:error, reason} ->
        IO.puts("  #{@yellow}error: #{inspect(reason)}#{@reset}")
    end
  end

  defp system_usage do
    IO.puts("  #{@bold}/system#{@reset} — operator system prompt, saved per model")
    IO.puts("")

    IO.puts(
      "  #{@cyan}/system file#{@reset}               create #{PromptOverrides.prompts_dir()}/<model>.md — edit it, done"
    )

    IO.puts(
      "  #{@cyan}/system file replace#{@reset}       same, but the file becomes the ENTIRE prompt"
    )

    IO.puts("  #{@cyan}/system#{@reset}                    status for the current model")
    IO.puts("  #{@cyan}/system inject#{@reset} <text>     append <text> to the built-in prompt")

    IO.puts(
      "  #{@cyan}/system replace#{@reset} <text>    <text> becomes the entire system prompt"
    )

    IO.puts(
      "  #{@cyan}/system inject#{@reset} @file.md   read the text from a file (also for replace)"
    )

    IO.puts("  #{@cyan}/system show#{@reset}               print the saved text")

    IO.puts(
      "  #{@cyan}/system off#{@reset} | #{@cyan}on#{@reset}           disable / re-enable, text kept"
    )

    IO.puts("  #{@cyan}/system clear#{@reset}              delete it for this model")
    IO.puts("  #{@cyan}/system list#{@reset}               every saved override")
    IO.puts("")

    IO.puts(
      "  #{@dim}Add --all after the verb to target every model. Use \\n for newlines inline. Saved in #{PromptOverrides.path()}#{@reset}"
    )
  end

  # ── /models — local model manager ─────────────────────────────────────────
  #
  #   /models                    installed + catalog, each with a fit verdict
  #   /models info <model>       capabilities, size per quant, fit, est./measured tok/s
  #   /models install <model>    pull (catalog id, hf.co/… tag, or any Ollama tag), then benchmark
  #   /models install <model> <quant>
  #   /models use <model>        switch this session AND make it the default
  #   /models remove <model>
  #   /models load | unload <model>
  #   /models bench <model>      measure tok/s
  #   /models alias <model> <short-name>
  #   /models hardware           what was detected
  #   /models search <words>     Hugging Face GGUF search
  def cmd_models(args, session_id) do
    IO.puts("")

    {verb, rest} =
      case String.split(String.trim(args), ~r/\s+/, parts: 2) do
        [""] -> {"", ""}
        [v] -> {String.downcase(v), ""}
        [v, r] -> {String.downcase(v), String.trim(r)}
      end

    case {verb, rest} do
      {"", _} ->
        models_overview(session_id)

      {v, _} when v in ["list", "ls"] ->
        models_overview(session_id)

      {v, ""}
      when v in [
             "info",
             "show",
             "install",
             "pull",
             "use",
             "remove",
             "rm",
             "delete",
             "load",
             "unload",
             "bench",
             "alias",
             "search"
           ] ->
        models_usage()

      {v, ref} when v in ["info", "show"] ->
        models_info(ref)

      {v, ref} when v in ["install", "pull", "get"] ->
        models_install(ref, session_id)

      {"use", ref} ->
        models_use(ref, session_id)

      {v, ref} when v in ["remove", "rm", "delete"] ->
        models_remove(ref)

      {"load", ref} ->
        models_simple(LocalModels.load(ref), "Loaded #{ref} into VRAM (kept resident)")

      {"unload", ref} ->
        models_simple(LocalModels.unload(ref), "Unloaded #{ref} from VRAM")

      {"bench", ref} ->
        models_bench(ref)

      {"alias", ref} ->
        models_alias(ref)

      {v, _} when v in ["hardware", "hw", "specs"] ->
        models_hardware()

      {v, arg} when v in ["ctx", "context", "window"] ->
        models_ctx(arg, session_id)

      {"search", q} ->
        models_search(q)

      _ ->
        models_usage()
    end

    IO.puts("")
    session_id
  rescue
    e ->
      IO.puts("  #{@yellow}error: /models failed: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  defp models_overview(session_id) do
    ov = LocalModels.overview()
    {_prov, current} = session_provider_model(session_id)

    IO.puts(
      "  #{@bold}This machine#{@reset}  #{@dim}#{Hardware.summary(ov.hardware)} · fit at #{format_context_window(ov.ctx)} ctx#{@reset}"
    )

    if ov.error do
      IO.puts("  #{@yellow}Ollama: #{ov.error}#{@reset}")
    end

    IO.puts("")
    IO.puts("  #{@bold}Installed#{@reset}")

    if ov.installed == [] do
      IO.puts("  #{@dim}nothing local yet — pick one below with /models install <id>#{@reset}")
    else
      Enum.each(ov.installed, fn r ->
        mark =
          cond do
            r.tag == current -> "#{@green}●#{@reset}"
            r.loaded -> "#{@cyan}●#{@reset}"
            true -> "#{@dim}○#{@reset}"
          end

        IO.puts("  #{mark} #{@bold}#{r.tag}#{@reset}")
        IO.puts("      #{@dim}#{models_line(r)}#{@reset}")
      end)

      IO.puts(
        "  #{@dim}● current   #{@cyan}●#{@reset}#{@dim} loaded in VRAM   ○ on disk#{@reset}"
      )
    end

    IO.puts("")

    IO.puts(
      "  #{@bold}Available#{@reset}  #{@dim}(curated abliterated / uncensored GGUFs — /models install <id>)#{@reset}"
    )

    Enum.each(ov.catalog, fn r ->
      IO.puts("  #{fit_badge(r.fit)} #{@bold}#{r.entry.id}#{@reset}  #{@dim}#{r.name}#{@reset}")
      IO.puts("      #{@dim}#{models_line(r)}#{@reset}")
    end)

    IO.puts("")

    IO.puts(
      "  #{@dim}/models info <id> for detail · /models install <id> · /models use <id> · /models hardware#{@reset}"
    )
  end

  defp models_line(r) do
    size = if r.size_bytes > 0, do: gb(r.size_bytes), else: "?"
    exact = if r.fit && !r.fit.weights_exact && !r.installed, do: "~", else: ""
    caps = if r.capabilities == [], do: "", else: " · " <> Enum.join(r.capabilities, ", ")

    speed =
      cond do
        r.measured_tps -> " · #{r.measured_tps} tok/s measured"
        r.fit && r.fit.est_tps -> " · ~#{round(r.fit.est_tps)} tok/s est."
        true -> ""
      end

    "#{exact}#{size} #{r.quant || ""} · #{r.params || "?"} · #{r.fit && Fit.label(r.fit.verdict)}#{speed}#{caps}"
  end

  defp fit_badge(nil), do: "#{@dim}?#{@reset}"
  defp fit_badge(%{verdict: :fits}), do: "#{@green}✓#{@reset}"
  defp fit_badge(%{verdict: :partial}), do: "#{@yellow}⚠#{@reset}"
  defp fit_badge(%{verdict: :cpu}), do: "#{@yellow}⚠#{@reset}"
  defp fit_badge(%{verdict: :no}), do: "#{@red}✗#{@reset}"

  defp gb(bytes), do: "#{Float.round(bytes / 1.0e9, 1)} GB"

  defp models_info(ref) do
    IO.puts("  #{@dim}Looking up #{ref}…#{@reset}")

    case LocalModels.inspect_model(ref) do
      {:error, e} ->
        IO.puts("  #{@yellow}#{e}#{@reset}")

      {:ok, m} ->
        hw = Hardware.detect()
        IO.puts("  #{@bold}#{m.name}#{@reset}")
        IO.puts("  #{@dim}Tag:#{@reset}          #{m.tag}")
        IO.puts("  #{@dim}Installed:#{@reset}    #{if m.installed, do: "yes", else: "no"}")
        if m.family, do: IO.puts("  #{@dim}Family:#{@reset}       #{m.family}")
        if m.params, do: IO.puts("  #{@dim}Parameters:#{@reset}   #{m.params}")

        if m.context_length do
          IO.puts(
            "  #{@dim}Context:#{@reset}      #{format_context_window(m.context_length)} tokens trained"
          )
        end

        if m.installed, do: models_osa_profile(m.tag)

        IO.puts(
          "  #{@dim}Capabilities:#{@reset} #{if m.capabilities == [], do: "?", else: Enum.join(m.capabilities, ", ")}"
        )

        if m.entry && m.entry.blurb != "", do: IO.puts("  #{@dim}#{m.entry.blurb}#{@reset}")
        IO.puts("")
        IO.puts("  #{@bold}On this machine#{@reset}  #{@dim}#{Hardware.summary(hw)}#{@reset}")

        if m.quants != [] do
          Enum.each(trim_quants(m.quants), fn q ->
            chosen = if q.quant == String.upcase(m.quant || ""), do: "#{@bold}", else: ""
            est = if q.fit.est_tps, do: "~#{round(q.fit.est_tps)} tok/s", else: "—"
            approx = if q.exact, do: "", else: "~"

            IO.puts(
              "  #{fit_badge(q.fit)} #{chosen}#{String.pad_trailing(q.quant, 8)}#{@reset} #{approx}#{String.pad_leading(gb(q.bytes), 9)}  #{String.pad_trailing(Fit.label(q.fit.verdict), 22)} #{est}"
            )
          end)

          IO.puts(
            "  #{@dim}bold = recommended · /models install #{(m.entry && m.entry.id) || m.tag} <quant> to pick another#{@reset}"
          )
        else
          f = m.fit

          IO.puts(
            "  #{fit_badge(f)} #{Fit.label(f.verdict)} — weights #{gb(f.weights_bytes)} + KV #{gb(f.kv_bytes)} @ #{format_context_window(f.ctx)} ctx"
          )

          cond do
            m.measured ->
              IO.puts(
                "  #{@dim}Speed:#{@reset}        #{m.measured["decode_tps"]} tok/s measured#{if m.measured["prompt_tps"], do: " (prompt #{m.measured["prompt_tps"]} tok/s)"}"
              )

            f.est_tps ->
              IO.puts(
                "  #{@dim}Speed:#{@reset}        ~#{round(f.est_tps)} tok/s estimated · /models bench #{m.tag} to measure"
              )

            true ->
              :ok
          end
        end

        if !hw.bandwidth_known and hw.gpu do
          IO.puts(
            "  #{@dim}(GPU not in the bandwidth table — speed estimates use a conservative default)#{@reset}"
          )
        end
    end
  end

  # How OSA will actually drive this model: the window it allocates, which
  # prompt variant that selects (and its size), where compaction fires, and
  # how many tools ride in the request. This is the "does it work on a small
  # window" answer, in numbers, before the first turn.
  defp models_osa_profile(tag) do
    alias OptimalSystemAgent.Agent.Context
    alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
    alias OptimalSystemAgent.Soul

    window = ProviderRegistry.effective_context_window(tag, :ollama)
    small? = Context.small_window?(tag, :ollama)
    variant = Context.static_base_variant(:ollama, small?)
    static = Soul.static_token_count(variant)
    compact = CompactionThresholds.compact_at(window)
    tools = if small?, do: "10 core tools + tool_search", else: "all tools"

    IO.puts("")
    IO.puts("  #{@bold}OSA on this model#{@reset}")

    IO.puts(
      "  #{@dim}Window:#{@reset}       #{format_context_window(window)} tokens (auto — largest that fits VRAM)"
    )

    IO.puts(
      "  #{@dim}Prompt:#{@reset}       #{variant} variant, #{format_context_window(static)} tokens#{operator_prompt_note(tag)}"
    )

    IO.puts(
      "  #{@dim}Compaction:#{@reset}   at #{format_context_window(compact)} tokens (#{div(compact * 100, max(window, 1))}%)"
    )

    IO.puts("  #{@dim}Tools:#{@reset}        #{tools}")

    IO.puts(
      "  #{@dim}Free for chat:#{@reset} ~#{format_context_window(max(compact - static, 0))} tokens before the first compaction"
    )
  end

  defp operator_prompt_note(tag) do
    case PromptOverrides.effective(tag) do
      {_, %{mode: mode, text: text}} ->
        " + your #{mode} prompt (~#{format_context_window(OptimalSystemAgent.Agent.Context.estimate_tokens(text))})"

      nil ->
        ""
    end
  end

  # A repo like bartowski's 70B ships 29 quants. Show the ones worth choosing
  # between: everything that runs, capped at 10 from the largest down, plus
  # the smallest one that does not — so the cliff is visible.
  defp trim_quants(quants) when length(quants) <= 10, do: quants

  defp trim_quants(quants) do
    {runs, no} = Enum.split_with(quants, &(&1.fit.verdict != :no))
    kept = runs |> Enum.sort_by(& &1.bytes, :desc) |> Enum.take(10) |> Enum.sort_by(& &1.bytes)
    kept ++ Enum.take(no, 1)
  end

  defp models_install(ref, session_id) do
    {ref, quant} =
      case String.split(ref, ~r/\s+/, parts: 2) do
        [r, q] -> {r, q}
        [r] -> {r, nil}
      end

    IO.puts("  #{@dim}Checking #{ref}…#{@reset}")

    with {:ok, m} <- LocalModels.inspect_model(ref),
         :ok <- models_confirm_fit(m, quant) do
      tag =
        if quant && m.entry,
          do: OptimalSystemAgent.LocalModels.Catalog.tag(m.entry, quant),
          else: m.tag

      IO.puts("  #{@dim}Pulling #{tag} (#{gb(m.size_bytes)})…#{@reset}")

      progress = fn %{status: status, completed: c, total: t} ->
        if t > 0 do
          pct = div(c * 100, t)

          IO.write(
            "\r  #{@dim}#{String.slice(status, 0, 30)}#{@reset} #{String.pad_leading("#{pct}%", 4)}  #{gb(c)} / #{gb(t)}      "
          )
        else
          IO.write("\r  #{@dim}#{status}#{@reset}                                        ")
        end
      end

      case LocalModels.install(tag, on_progress: progress, quant: quant) do
        {:ok, %{tag: tag, bench: bench}} ->
          IO.write("\r")
          IO.puts("  #{@green}✓#{@reset} Installed #{@bold}#{tag}#{@reset}")

          if bench do
            IO.puts(
              "  #{@dim}Measured:#{@reset} #{bench.decode_tps} tok/s decode#{if bench.prompt_tps, do: ", #{bench.prompt_tps} tok/s prompt"}"
            )
          end

          IO.puts("  #{@dim}/models use #{tag} to switch to it#{@reset}")

        {:error, e} ->
          IO.write("\r")
          IO.puts("  #{@yellow}Pull failed: #{e}#{@reset}")
      end
    else
      {:error, e} -> IO.puts("  #{@yellow}#{e}#{@reset}")
      :abort -> :ok
    end

    _ = session_id
  end

  # Refuse a pull that cannot run; warn (but continue) on partial offload.
  defp models_confirm_fit(%{fit: nil}, _quant), do: :ok

  defp models_confirm_fit(%{fit: fit, quants: quants} = m, quant) do
    fit =
      case quant && Enum.find(quants, &(&1.quant == String.upcase(quant))) do
        %{fit: f} -> f
        _ -> fit
      end

    case fit.verdict do
      :no ->
        IO.puts(
          "  #{@red}✗ #{m.name} won't fit: needs #{gb(fit.total_bytes)} (weights #{gb(fit.weights_bytes)} + KV), this machine has #{gb(fit.budget_bytes)} usable.#{@reset}"
        )

        IO.puts(
          "  #{@dim}Try a smaller quant (/models info #{(m.entry && m.entry.id) || m.tag}) or a smaller model.#{@reset}"
        )

        :abort

      :partial ->
        IO.puts(
          "  #{@yellow}⚠ Partial offload: only #{round(fit.gpu_share * 100)}% of the weights fit in VRAM; expect ~#{round(fit.est_tps || 0)} tok/s. Pulling anyway.#{@reset}"
        )

        :ok

      _ ->
        :ok
    end
  end

  defp models_use(ref, session_id) do
    case LocalModels.resolve(ref) do
      {:installed, tag} ->
        case swap_to(:ollama, tag, session_id) do
          :ok ->
            case LocalModels.set_default(tag) do
              :ok ->
                IO.puts("  #{@dim}Saved as default for new sessions.#{@reset}")

              {:error, e} ->
                IO.puts("  #{@yellow}Switched, but could not save default: #{e}#{@reset}")
            end

          _ ->
            :ok
        end

      {:catalog, entry, _} ->
        IO.puts(
          "  #{@yellow}#{entry.name} is not installed. /models install #{entry.id}#{@reset}"
        )

      _ ->
        IO.puts("  #{@yellow}#{ref} is not installed. /models to see what is.#{@reset}")
    end
  end

  defp models_remove(ref) do
    case LocalModels.resolve(ref) do
      {:installed, tag} -> models_simple(LocalModels.remove(tag), "Removed #{tag}")
      _ -> IO.puts("  #{@yellow}#{ref} is not installed.#{@reset}")
    end
  end

  defp models_bench(ref) do
    case LocalModels.resolve(ref) do
      {:installed, tag} ->
        IO.puts("  #{@dim}Benchmarking #{tag} (64 tokens)…#{@reset}")

        case LocalModels.bench(tag) do
          {:ok, b} ->
            IO.puts(
              "  #{@green}✓#{@reset} #{@bold}#{b.decode_tps} tok/s#{@reset} decode#{if b.prompt_tps, do: " · #{b.prompt_tps} tok/s prompt"} · load #{b.load_ms} ms"
            )

          {:error, e} ->
            IO.puts("  #{@yellow}#{e}#{@reset}")
        end

      _ ->
        IO.puts("  #{@yellow}#{ref} is not installed.#{@reset}")
    end
  end

  defp models_alias(rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [from, to] ->
        case LocalModels.resolve(from) do
          {:installed, tag} ->
            models_simple(
              LocalModels.alias_tag(tag, to),
              "#{to} → #{tag} (same weights, no extra disk)"
            )

          _ ->
            IO.puts("  #{@yellow}#{from} is not installed.#{@reset}")
        end

      _ ->
        IO.puts("  #{@yellow}usage: /models alias <model> <short-name>#{@reset}")
    end
  end

  defp models_hardware do
    hw = Hardware.refresh()
    IO.puts("  #{@bold}Hardware#{@reset}")

    IO.puts(
      "  #{@dim}GPU:#{@reset}        #{hw.gpu || "none"}#{if hw.gpu, do: " (#{hw.backend})"}"
    )

    IO.puts("  #{@dim}VRAM:#{@reset}       #{gb(hw.vram_bytes)}")
    IO.puts("  #{@dim}RAM:#{@reset}        #{gb(hw.ram_bytes)}")
    IO.puts("  #{@dim}CPU:#{@reset}        #{hw.cpu || "?"} · #{hw.cores} threads")

    IO.puts(
      "  #{@dim}Bandwidth:#{@reset}  #{hw.bandwidth_gbps} GB/s#{if hw.bandwidth_known, do: "", else: " (default — GPU not in table)"}"
    )

    ctx_mode =
      case Application.get_env(:optimal_system_agent, :ollama_num_ctx) do
        n when is_integer(n) -> "pinned to #{format_context_window(n)} (OLLAMA_NUM_CTX)"
        _ -> "auto — largest window that fits VRAM per model (OLLAMA_NUM_CTX=<n> to pin)"
      end

    IO.puts("  #{@dim}Context:#{@reset}    #{ctx_mode}")
  end

  # /models ctx            show the window for the current model and why
  # /models ctx auto       largest window whose KV cache fits VRAM (default)
  # /models ctx max        the model's full trained window, fit or not
  # /models ctx <n>        pin a number (e.g. 131072 or 128k)
  # Persists as OLLAMA_NUM_CTX in ~/.osa/.env and applies to the next turn.
  defp models_ctx(arg, session_id) do
    {_provider, model} = session_provider_model(session_id)
    trained = trained_window(model)

    choice =
      case String.downcase(String.trim(arg)) do
        "" ->
          :show

        "auto" ->
          :auto

        "max" when is_integer(trained) ->
          trained

        "max" ->
          {:error, "trained window unknown for #{model} — pin a number instead"}

        s ->
          case Integer.parse(String.replace(s, ~r/[_,]/, "")) do
            {n, ""} when n >= 2048 -> n
            {n, "k"} when n >= 2 -> n * 1024
            _ -> {:error, "usage: /models ctx auto | max | <tokens>"}
          end
      end

    case choice do
      {:error, msg} ->
        IO.puts("  #{@yellow}#{msg}#{@reset}")

      :show ->
        models_ctx_report(model, trained)

      value ->
        env_value = if value == :auto, do: "auto", else: Integer.to_string(value)
        Application.put_env(:optimal_system_agent, :ollama_num_ctx, value)
        LocalModels.forget_auto_num_ctx(model)

        try do
          OptimalSystemAgent.CLI.Setup.save_env("OLLAMA_NUM_CTX", env_value)
        rescue
          _ -> :ok
        end

        IO.puts(
          "  #{@green}✓#{@reset} Context window: #{env_value} #{@dim}(saved as OLLAMA_NUM_CTX; applies from the next message)#{@reset}"
        )

        models_ctx_report(model, trained)
    end
  end

  defp models_ctx_report(model, trained) do
    window = ProviderRegistry.effective_context_window(model, :ollama)
    mode = Application.get_env(:optimal_system_agent, :ollama_num_ctx)
    kv_type = Application.get_env(:optimal_system_agent, :ollama_kv_cache_type, "f16")

    IO.puts("")
    IO.puts("  #{@bold}Context window · #{model}#{@reset}")

    IO.puts(
      "  #{@dim}In use:#{@reset}     #{format_context_window(window)} tokens (#{if is_integer(mode), do: "pinned", else: "auto"})"
    )

    if trained,
      do: IO.puts("  #{@dim}Trained:#{@reset}    #{format_context_window(trained)} tokens")

    IO.puts("  #{@dim}KV cache:#{@reset}   #{kv_type} on the daemon (OLLAMA_KV_CACHE_TYPE)")

    case LocalModels.inspect_model(model) do
      {:ok, %{installed: true, fit: %{} = f}} ->
        per_token = div(round(f.kv_bytes / Fit.kv_cache_scale()), max(f.ctx, 1))
        spec = %{weights_bytes: f.weights_bytes, kv_bytes_per_token: per_token}
        hw = Hardware.detect()
        at = Fit.assess(spec, hw, window)

        IO.puts(
          "  #{@dim}Fit:#{@reset}        #{fit_badge(at)} #{Fit.label(at.verdict)} — weights #{gb(at.weights_bytes)} + KV #{gb(at.kv_bytes)} of #{gb(at.budget_bytes)} usable"
        )

        if at.verdict in [:partial, :no] do
          IO.puts(
            "  #{@yellow}⚠ At this window the KV cache does not fit VRAM: expect ~#{round(at.est_tps || 0)} tok/s (spills to RAM).#{@reset}"
          )

          IO.puts(
            "  #{@dim}Fix: quantise the daemon's KV cache — OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 (½) or q4_0 (¼) on the Ollama service,#{@reset}"
          )

          IO.puts(
            "  #{@dim}then set the same OLLAMA_KV_CACHE_TYPE in ~/.osa/.env so OSA sizes it right.#{@reset}"
          )
        end

        if is_integer(trained) and window < trained do
          f16 = per_token * trained

          IO.puts(
            "  #{@dim}Full #{format_context_window(trained)} needs KV #{gb(f16)} at f16 · #{gb(div(f16, 2))} at q8_0 · #{gb(div(f16, 4))} at q4_0.#{@reset}"
          )
        end

      _ ->
        :ok
    end

    IO.puts("  #{@dim}/models ctx auto · max · <tokens>#{@reset}")
  end

  defp trained_window(model) do
    case OptimalSystemAgent.LocalModels.OllamaAdmin.show(model) do
      {:ok, %{context_length: n}} when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp models_search(q) do
    IO.puts("  #{@dim}Searching Hugging Face for “#{q}” GGUFs…#{@reset}")

    case OptimalSystemAgent.LocalModels.HuggingFace.search(q, limit: 15) do
      {:ok, []} ->
        IO.puts("  #{@dim}nothing found#{@reset}")

      {:ok, list} ->
        Enum.each(list, fn r ->
          IO.puts("  #{@dim}•#{@reset} #{r.id} #{@dim}(#{r.downloads} downloads)#{@reset}")
        end)

        IO.puts(
          "  #{@dim}/models info hf.co/<repo> to size one · /models install hf.co/<repo>:<quant>#{@reset}"
        )

      {:error, e} ->
        IO.puts("  #{@yellow}#{e}#{@reset}")
    end
  end

  defp models_simple(:ok, msg), do: IO.puts("  #{@green}✓#{@reset} #{msg}")
  defp models_simple({:error, e}, _), do: IO.puts("  #{@yellow}#{e}#{@reset}")

  defp models_usage do
    IO.puts("  #{@bold}/models#{@reset} — local models on this machine")
    IO.puts("")

    IO.puts(
      "  #{@cyan}/models#{@reset}                      installed + curated catalog, with fit for this hardware"
    )

    IO.puts(
      "  #{@cyan}/models info#{@reset} <model>         capabilities, size per quant, est./measured tok/s"
    )

    IO.puts(
      "  #{@cyan}/models install#{@reset} <model> [q]  pull it (catalog id, hf.co/repo:quant, or Ollama tag), then benchmark"
    )

    IO.puts(
      "  #{@cyan}/models use#{@reset} <model>          switch this session and make it the default"
    )

    IO.puts("  #{@cyan}/models remove#{@reset} <model>       delete from disk")

    IO.puts(
      "  #{@cyan}/models load#{@reset} | #{@cyan}unload#{@reset} <model> keep in VRAM / evict now"
    )

    IO.puts("  #{@cyan}/models bench#{@reset} <model>        measure tok/s")
    IO.puts("  #{@cyan}/models alias#{@reset} <model> <name> short tag for a long hf.co/… name")
    IO.puts("  #{@cyan}/models search#{@reset} <words>       find GGUFs on Hugging Face")
    IO.puts("  #{@cyan}/models hardware#{@reset}             what was detected")

    IO.puts(
      "  #{@cyan}/models ctx#{@reset} auto|max|<n>      context window for the current model (persists)"
    )
  end

  # ── /jailbreak — operator override layer (LIBERATED) ─────────────────────
  #
  #   /jailbreak              status; with no arg when disarmed, arms it
  #   /jailbreak on           arm the block
  #   /jailbreak off | show   disarm / print what would be injected
  #   /jailbreak file <path>  point the block at a custom text file (remembered)
  #
  # The block is appended to OSA's system prompt for EVERY model/provider, on
  # top of any `/system` state, from the next message. A LIBERATED badge shows
  # on the spinner and status line while armed.
  def cmd_jailbreak(args, session_id) do
    alias OptimalSystemAgent.Agent.Jailbreak
    IO.puts("")

    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      [""] -> jailbreak_toggle()
      [verb] when verb in ["on", "arm", "enable"] -> jailbreak_set(true, nil)
      [verb] when verb in ["off", "disarm", "disable"] -> jailbreak_set(false, nil)
      [verb] when verb == "show" -> jailbreak_show()
      ["file", path] -> jailbreak_file(path)
      _ -> jailbreak_usage()
    end

    IO.puts("")
    session_id
  rescue
    e ->
      IO.puts("  #{@yellow}error: /jailbreak failed: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  # Bare `/jailbreak` is a toggle, so it does something in both directions —
  # the common case is "arm it now".
  defp jailbreak_toggle do
    if OptimalSystemAgent.Agent.Jailbreak.active?(),
      do: jailbreak_set(false, nil),
      else: jailbreak_set(true, nil)
  end

  defp jailbreak_set(enabled?, file) do
    alias OptimalSystemAgent.Agent.Jailbreak

    case Jailbreak.set(enabled?, file) do
      :ok when enabled? ->
        IO.puts("  #{@green}✓#{@reset} #{IO.ANSI.magenta()}⚡ LIBERATED#{@reset}")
        IO.puts("  #{@dim}#{Jailbreak.preview()}#{@reset}")
        IO.puts("  #{@dim}/jailbreak off to disarm#{@reset}")

      :ok ->
        IO.puts(
          "  #{@green}✓#{@reset} Jailed again — #{IO.ANSI.faint()}⚡ LIBERATED disarmed#{@reset}"
        )

      {:error, :empty_prompt} ->
        IO.puts(
          "  #{@yellow}nothing to inject: #{Jailbreak.file_path()} is missing or empty#{@reset}"
        )

        IO.puts("  #{@dim}/jailbreak file <path> to point at a text file#{@reset}")
    end
  end

  defp jailbreak_show do
    alias OptimalSystemAgent.Agent.Jailbreak

    if Jailbreak.active?() do
      block = Jailbreak.system_block()
      shown = if String.length(block) > 400, do: "#{String.slice(block, 0, 400)}…", else: block

      IO.puts("  #{@dim}source:#{reset_dim()} #{Jailbreak.file_path()}#{@reset}")
      IO.puts("")

      shown
      |> String.split("\n")
      |> Enum.each(fn line -> IO.puts("  #{@dim}│#{@reset} #{line}") end)
    else
      IO.puts("  #{@yellow}not armed#{@reset} — #{@dim}/jailbreak to enable#{@reset}")
    end
  end

  defp reset_dim, do: @dim

  defp jailbreak_file(path) do
    alias OptimalSystemAgent.Agent.Jailbreak
    expanded = Path.expand(String.replace_leading(path, "~", System.user_home!()))

    if File.regular?(expanded) do
      case Jailbreak.set(true, path) do
        :ok ->
          IO.puts("  #{@green}✓#{@reset} #{IO.ANSI.magenta()}⚡ LIBERATED#{@reset}")
          IO.puts("  #{@dim}source:#{@reset} #{expanded}")

        {:error, reason} ->
          IO.puts("  #{@yellow}rejected (#{inspect(reason)}) — file is empty#{@reset}")
      end
    else
      IO.puts("  #{@yellow}file not found: #{expanded}#{@reset}")
    end
  end

  defp jailbreak_usage do
    IO.puts(
      "  #{@bold}/jailbreak#{@reset}   #{IO.ANSI.faint()}toggle the liberation layer#{@reset}"
    )

    IO.puts("  #{@dim}/jailbreak on | off | show | file <path>#{@reset}")

    if OptimalSystemAgent.Agent.Jailbreak.active?(),
      do: IO.puts("  #{IO.ANSI.magenta()}⚡ LIBERATED#{@reset}")
  end

  defp uncensored_list do
    IO.puts("  #{@bold}Uncensored models#{@reset}")

    for m <- OptimalSystemAgent.Providers.OpenAICompatProvider.available_models(:uncensored) do
      IO.puts("  #{@dim}•#{@reset} #{m}")
    end

    IO.puts("")
    IO.puts("  #{@dim}Full live list: GET https://api.uncensored.com/api/v1/models#{@reset}")
  end

  defp uncensored_restore(session_id) do
    case take_previous_provider(session_id) do
      {prov, model} ->
        case swap_to(prov, model, session_id) do
          :ok -> :ok
          # Put it back: a failed restore that forgets where it came from
          # strands the session on the gateway with no way home.
          :error -> remember_previous_provider(session_id, prov, model)
        end

      nil ->
        IO.puts("  #{@yellow}nothing to go back to#{@reset}")
    end
  end

  defp uncensored_hop(session_id) do
    {provider, model} = session_provider_model(session_id)

    cond do
      provider == :uncensored ->
        IO.puts("  #{@dim}already on uncensored (#{model}) — /uncensored off to return#{@reset}")

      model in OptimalSystemAgent.Providers.OpenAICompatProvider.available_models(:uncensored) ->
        IO.puts("  #{@dim}#{model} has an unfiltered twin — hopping#{@reset}")
        remember_on_success(session_id, provider, model, swap_to(:uncensored, model, session_id))

      true ->
        IO.puts("  #{@yellow}no unfiltered twin for #{model}#{@reset}")
        IO.puts("  #{@dim}/uncensored list to see what is available#{@reset}")
    end
  end

  defp uncensored_switch(model, session_id) do
    {provider, from_model} = session_provider_model(session_id)
    result = swap_to(:uncensored, model, session_id)

    if provider != :uncensored do
      remember_on_success(session_id, provider, from_model, result)
    end
  end

  # Only a swap that actually happened has anything to go back FROM. Recording
  # the origin before the call means a rejected model id (`known_model?/2`
  # says no) leaves a "previous" pointing at the model the session is still on,
  # and the next `/uncensored off` is a no-op that reports success.
  defp remember_on_success(session_id, provider, model, :ok) do
    remember_previous_provider(session_id, provider, model)
  end

  defp remember_on_success(_session_id, _provider, _model, _result), do: :ok

  # ── Per-session provider state ────────────────────────────────────────────
  #
  # `{:swap_provider, …}` records each session's choice in
  # `:osa_session_provider_overrides`, so that table — not the application
  # environment — is where a session's current provider/model lives. The app
  # env holds the node's DEFAULT, which is only this session's provider until
  # some session swaps; reading it from a session command reports whatever the
  # node was configured with while the session runs something else.
  #
  # The origin to return to is per-session for the same reason, and a node-wide
  # one was worse than merely inaccurate: two sessions hopping to the gateway
  # left one `:uncensored_previous`, so the first `/uncensored off` restored
  # its own origin into whichever session happened to run it.

  defp session_provider_model(session_id) do
    case ets_lookup(:osa_session_provider_overrides, session_id) do
      {provider, model} ->
        {provider, model}

      nil ->
        provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
        {provider, get_model_name(provider)}
    end
  end

  defp remember_previous_provider(session_id, provider, model) do
    ets_insert(:osa_session_provider_previous, {session_id, provider, model})
  end

  defp take_previous_provider(session_id) do
    case ets_lookup(:osa_session_provider_previous, session_id) do
      {provider, model} ->
        ets_delete(:osa_session_provider_previous, session_id)
        {provider, model}

      nil ->
        nil
    end
  end

  # These tables are created by `Application.start/2`. A command dispatched in
  # a bare unit test — or before the tree is up — must degrade to "no session
  # state", never crash the command.
  defp ets_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, provider, model}] -> {provider, model}
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp ets_insert(table, row) do
    :ets.insert(table, row)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ets_delete(table, key) do
    :ets.delete(table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Shared tail of /model and /uncensored: ask the session to swap and report.
  # Returns `:ok` only when the session actually moved.
  defp swap_to(provider, model, session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] ->
        case GenServer.call(pid, {:swap_provider, provider, model}, swap_call_timeout()) do
          {:ok, info} ->
            print_model_switch(info)
            :ok

          {:error, reason} ->
            IO.puts("  #{@yellow}error: #{reason}#{@reset}")
            :error

          :ok ->
            IO.puts("  #{@green}#{@reset} Switched to #{model}")
            :ok
        end

      _ ->
        IO.puts("  #{@yellow}error: session not found#{@reset}")
        :error
    end
  end

  def cmd_status(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Session Status#{@reset}")

    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    # Identity.model/0 rather than the old Format.get_model_name/1: that read
    # `:ollama_model` while /health (and therefore the status bar) reads
    # `:default_model`. Both are written at boot, but a mid-session /switch
    # writes them separately, so `/status` could report a different model than
    # the bar. One resolver, no drift.
    model = OptimalSystemAgent.Runtime.Identity.model()
    {_src, model_source} = OptimalSystemAgent.Runtime.Identity.model_source()
    tool_count = length(ToolsRegistry.list_tools_direct())
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    IO.puts("  #{@dim}Session:#{@reset}   #{session_id}")
    IO.puts("  #{@dim}Uptime:#{@reset}    #{Renderer.format_elapsed(uptime_ms)}")
    IO.puts("  #{@dim}Provider:#{@reset}  #{provider}")
    IO.puts("  #{@dim}Model:#{@reset}     #{model} #{@dim}(from #{model_source})#{@reset}")
    IO.puts("  #{@dim}Tools:#{@reset}     #{tool_count} loaded")

    case Loop.get_state(session_id) do
      {:ok, state} ->
        iter = state[:iteration] || state[:iteration_count] || 0
        tokens = state[:tokens_used] || state[:estimated_tokens] || 0
        max_tokens = ProviderRegistry.effective_context_window(get_model_name(provider), provider)
        pct = if max_tokens > 0, do: round(tokens / max_tokens * 100), else: 0

        IO.puts("  #{@dim}Iteration:#{@reset} #{iter}")

        IO.puts(
          "  #{@dim}Context:#{@reset}   #{pct}% (#{format_tokens(tokens)} / #{format_context_window(max_tokens)})"
        )

      _ ->
        :ok
    end

    try do
      budget = unwrap_budget(Budget.get_status())
      cost = budget[:monthly_spent] || budget[:total_cost_usd] || 0

      IO.puts(
        "  #{@dim}Cost:#{@reset}      $#{fmt_usd(cost)} " <>
          "#{@dim}(#{cost_period_label(budget)}, OSA-measured)#{@reset}"
      )
    rescue
      _ -> :ok
    end

    skill_count = length(ToolsRegistry.list_skills())
    IO.puts("  #{@dim}Skills:#{@reset}    #{skill_count} loaded")

    try do
      mem_stats = Memory.stats()
      mem_count = mem_stats[:total] || mem_stats[:count] || 0
      IO.puts("  #{@dim}Memory:#{@reset}    #{mem_count} entries")
    rescue
      _ -> :ok
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: status unavailable#{@reset}\n")
      session_id
  end

  def cmd_cost(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Cost Summary#{@reset}")

    try do
      # `Budget.get_status/0` returns `{:ok, map}`. Reading it as a bare map
      # raised inside the `try`, so this block printed "No cost data
      # available" unconditionally — a working ledger rendered as an empty one.
      budget = unwrap_budget(Budget.get_status())
      total = budget[:monthly_spent] || budget[:total_cost_usd] || 0
      tokens = budget[:monthly_tokens] || 0
      # `ledger_entries` is the size of a list capped at 10 000, so it stopped
      # being a call count at 10 000. `monthly_calls` is the real counter.
      calls = budget[:monthly_calls] || budget[:ledger_entries] || budget[:sessions] || 0

      # The ledger is in-memory only — nothing is loaded at boot and nothing is
      # saved at shutdown — so "this month" is a claim it cannot support. Label
      # the period by what it actually covers.
      period = cost_period_label(budget)

      IO.puts("  #{@dim}├─ Tokens:#{@reset}   #{format_tokens(tokens)} tokens #{period}")
      IO.puts("  #{@dim}├─ Today:#{@reset}    $#{fmt_usd(budget[:daily_spent] || 0)}")
      IO.puts("  #{@dim}├─ Calls:#{@reset}    #{calls}")
      IO.puts("  #{@dim}└─ Total:#{@reset}    $#{fmt_usd(total)} #{@dim}(#{period})#{@reset}")

      IO.puts("")

      IO.puts(
        "  #{@dim}This is OSA's own count of what it ran, priced from a static rate#{@reset}"
      )

      IO.puts(
        "  #{@dim}table. For what your account has left, use#{@reset} #{@cyan}/usage#{@reset}"
      )
    rescue
      _ ->
        IO.puts("  #{@dim}  No cost data available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp unwrap_budget({:ok, map}) when is_map(map), do: map
  defp unwrap_budget(map) when is_map(map), do: map
  defp unwrap_budget(_), do: %{}

  defp fmt_usd(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 4)
  defp fmt_usd(_), do: "0.0000"

  # What period the ledger's totals actually cover. `Budget` keeps its counters
  # in memory only — `init/1` starts them at zero, there is no load and no save
  # on shutdown — so "this month" would be a lie on any run started after the
  # 1st, and badly wrong right after a restart. Say what is true instead.
  defp cost_period_label(%{persisted: false, counting_since: %DateTime{} = since}) do
    "since #{Calendar.strftime(since, "%Y-%m-%d %H:%M")}"
  end

  defp cost_period_label(%{persisted: true}), do: "this month"
  defp cost_period_label(_), do: "this session"

  @doc """
  `/usage` — the provider's report on your account, and OSA's own measurement,
  kept apart.

  A pure read: it never refreshes a credential and never spends a metered
  request to build the display. Where a provider reports nothing it says so
  rather than showing a zero.
  """
  def cmd_usage(args, session_id) do
    all? = String.trim(args) in ["all", "--all", "-a"]

    OptimalSystemAgent.Usage.report(all: all?, session_id: session_id, probe: true)
    |> OptimalSystemAgent.Usage.Render.lines(all: all?)
    |> Enum.each(&IO.puts/1)

    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: usage unavailable#{@reset}\n")
      session_id
  end

  def cmd_context(_args, session_id) do
    IO.puts("")

    budget =
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
        [{pid, _}] ->
          case GenServer.call(pid, :context_budget) do
            {:ok, b} -> b
            _ -> nil
          end

        _ ->
          nil
      end

    case {budget, Loop.get_state(session_id)} do
      {b, _} when is_map(b) ->
        print_context_budget(b)

      {_, {:ok, state}} ->
        max_tokens = state[:effective_context_window] || 0
        static_tokens = OptimalSystemAgent.Soul.static_token_count()
        total_tokens = state[:tokens_used] || state[:estimated_tokens] || 0
        tool_schema = OptimalSystemAgent.Agent.Context.tool_schema_token_count()

        print_context_budget(%{
          max_tokens: max_tokens,
          static_base_tokens: static_tokens,
          conversation_tokens: max(total_tokens - static_tokens, 0),
          tool_schema_tokens: tool_schema,
          tool_result_tokens: 0,
          total_tokens: total_tokens
        })

      _ ->
        IO.puts("  #{@dim}No active session#{@reset}")
    end

    try do
      comp_stats = Compactor.stats()

      if comp_stats[:compaction_count] && comp_stats[:compaction_count] > 0 do
        IO.puts("")
        IO.puts("  #{@dim}Compressions:#{@reset}   #{comp_stats[:compaction_count]}")

        IO.puts(
          "  #{@dim}Tokens saved:#{@reset}   #{format_tokens(comp_stats[:tokens_saved] || 0)}"
        )
      end
    rescue
      _ -> :ok
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: context info unavailable#{@reset}\n")
      session_id
  end

  def cmd_revert(args, session_id) do
    IO.puts("")
    trimmed = String.trim(args || "")

    cwd =
      OptimalSystemAgent.Workspace.Cwd.session_dir(session_id) ||
        OptimalSystemAgent.Workspace.Cwd.get()

    cond do
      trimmed in ["list", "ls"] ->
        steps = OptimalSystemAgent.Agent.StepSnapshot.list(session_id, cwd: cwd)

        if steps == [] do
          IO.puts("  #{@dim}No filesystem step snapshots in this session.#{@reset}")
        else
          IO.puts("  #{@bold}Filesystem step snapshots#{@reset}")

          Enum.each(steps, fn step ->
            IO.puts("  #{@cyan}#{step.n}#{@reset}  #{@dim}#{step.ref}#{@reset}")
          end)
        end

      trimmed == "" or match?({n, ""} when n >= 1, Integer.parse(trimmed)) ->
        n =
          case Integer.parse(trimmed) do
            {i, ""} -> i
            _ -> 1
          end

        case OptimalSystemAgent.Agent.StepSnapshot.revert(session_id, n, cwd: cwd) do
          {:ok, result} ->
            IO.puts(
              "  #{@green}#{@reset} Restored filesystem to step #{result.restored_n} #{@dim}(transcript kept)#{@reset}"
            )

          {:error, _reason} ->
            case OptimalSystemAgent.Agent.StepRevert.revert(session_id, n) do
              {:ok, result} ->
                IO.puts(
                  "  #{@green}#{@reset} Reverted #{n} file step(s) → checkpoint #{result.checkpoint_id}"
                )

                IO.puts("  #{@dim}Transcript kept.#{@reset}")

              {:error, :not_enough_checkpoints} ->
                IO.puts("  #{@yellow}error: not enough file checkpoints to revert #{n}#{@reset}")

              {:error, reason} ->
                IO.puts("  #{@yellow}error: #{inspect(reason)}#{@reset}")
            end
        end

      true ->
        IO.puts("  #{@dim}Usage: /revert N#{@reset}  (restore files N mutating-tool steps ago)")
        IO.puts("         #{@dim}/revert list#{@reset}")
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: revert failed#{@reset}\n")
      session_id
  end

  defp swap_call_timeout do
    Application.get_env(:optimal_system_agent, :compaction_timeout_ms, 120_000) + 30_000
  end

  defp print_model_switch(info) do
    ctx = info[:context_window] || 0
    model = info[:model]
    provider = info[:provider]

    IO.puts(
      "  #{@green}#{@reset} Switched to #{model} #{@dim}(#{provider}, #{format_context_window(ctx)} ctx)#{@reset}"
    )

    before = info[:tokens_before] || 0
    afterc = info[:tokens_after] || before

    if info[:compacted] do
      IO.puts(
        "  #{@yellow}Compacted#{@reset} #{format_tokens(before)} → #{format_tokens(afterc)} to fit the new window"
      )
    else
      IO.puts(
        "  #{@dim}Transcript kept:#{@reset} #{format_tokens(afterc)} / #{format_context_window(ctx)}"
      )
    end

    if is_binary(info[:warning]) and info.warning != "" do
      IO.puts("  #{@yellow}warning:#{@reset} #{info.warning}")
    end
  end

  defp print_context_budget(b) do
    max_tokens = b[:max_tokens] || 0
    total_tokens = b[:occupied_tokens] || b[:total_tokens] || 0
    static_tokens = b[:static_base_tokens] || 0
    conversation_tokens = b[:conversation_tokens] || 0
    tool_schema = b[:tool_schema_tokens] || 0
    tool_results = b[:tool_result_tokens] || 0
    available = max(max_tokens - total_tokens, 0)
    pct = if max_tokens > 0, do: round(total_tokens / max_tokens * 100), else: 0

    IO.puts("  #{@bold}Context Window Usage (#{pct}%)#{@reset}")

    bar_width = 50
    filled = min(bar_width, round(pct / 100 * bar_width))
    empty = bar_width - filled

    bar_color =
      cond do
        pct >= 90 -> @red
        pct >= 70 -> @yellow
        true -> @green
      end

    IO.puts("  #{@dim}┌#{String.duplicate("─", bar_width)}┐#{@reset}")

    IO.puts(
      "  #{@dim}│#{bar_color}#{String.duplicate("█", filled)}#{@dim}#{String.duplicate("░", empty)}#{@reset}#{@dim}│#{@reset}"
    )

    IO.puts("  #{@dim}└#{String.duplicate("─", bar_width)}┘#{@reset}")
    IO.puts("")

    IO.puts(
      "  #{@dim}System prompt:#{@reset}  #{pad_num(static_tokens)} tokens (#{pct_of(static_tokens, max_tokens)}%)"
    )

    IO.puts(
      "  #{@dim}Tool schemas:#{@reset}   #{pad_num(tool_schema)} tokens (#{pct_of(tool_schema, max_tokens)}%)"
    )

    IO.puts(
      "  #{@dim}Tool results:#{@reset}   #{pad_num(tool_results)} tokens (#{pct_of(tool_results, max_tokens)}%)"
    )

    IO.puts(
      "  #{@dim}Conversation:#{@reset}   #{pad_num(conversation_tokens)} tokens (#{pct_of(conversation_tokens, max_tokens)}%)"
    )

    IO.puts(
      "  #{@dim}Available:#{@reset}      #{pad_num(available)} tokens (#{pct_of(available, max_tokens)}%)"
    )

    IO.puts("  #{@dim}Total:#{@reset}          #{pad_num(max_tokens)} tokens")
  end

  defp pct_of(_n, max) when not is_integer(max) or max <= 0, do: 0
  defp pct_of(n, max), do: round(n / max * 100)

  # `/memory` — no arg: stats + recent overview. Verbs: `save <text>` persists
  # a note, `search <q>` / `recall <q>` query the store. The TUI advertises
  # "Save or recall a memory", so the verbs must actually work — previously
  # `_args` was ignored and every invocation printed the same listing.
  def cmd_memory(args, session_id) do
    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      ["save", content] ->
        IO.puts("")

        try do
          case Memory.save(content, source: :user) do
            {:ok, _entry} -> IO.puts("  #{@green}✓#{@reset} Saved to memory")
            {:error, reason} -> IO.puts("  #{@yellow}error: #{inspect(reason)}#{@reset}")
          end
        rescue
          _ -> IO.puts("  #{@dim}Memory not available#{@reset}")
        end

        IO.puts("")
        session_id

      [verb, query] when verb in ["search", "recall"] ->
        IO.puts("")

        try do
          case Memory.recall(query, limit: 10) do
            {:ok, entries} when is_list(entries) and entries != [] ->
              Enum.each(entries, fn entry ->
                content = entry[:content] || entry[:key] || "?"
                IO.puts("  #{@dim}•#{@reset} #{String.slice(to_string(content), 0, 100)}")
              end)

            _ ->
              IO.puts("  #{@dim}No memories matched \"#{query}\"#{@reset}")
          end
        rescue
          _ -> IO.puts("  #{@dim}Memory not available#{@reset}")
        end

        IO.puts("")
        session_id

      ["save"] ->
        IO.puts("\n  #{@dim}Usage: /memory save <text>#{@reset}\n")
        session_id

      [verb] when verb in ["search", "recall"] ->
        IO.puts("\n  #{@dim}Usage: /memory #{verb} <query>#{@reset}\n")
        session_id

      _ ->
        memory_overview(session_id)
    end
  end

  # `/memory` with no verb: the original stats + recent-entries overview.
  defp memory_overview(session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Memory#{@reset}")

    try do
      {:ok, stats} = Memory.stats()
      total = stats[:total] || stats[:count] || 0
      IO.puts("  #{@dim}Entries:#{@reset} #{total}")

      case Memory.recent(10) do
        {:ok, entries} when is_list(entries) and entries != [] ->
          IO.puts("")

          Enum.each(entries, fn entry ->
            key = entry[:key] || entry[:content] || "?"
            truncated = String.slice(to_string(key), 0, 60)
            IO.puts("  #{@dim}•#{@reset} #{truncated}")
          end)

        _ ->
          IO.puts("  #{@dim}No entries found#{@reset}")
      end
    rescue
      _ ->
        IO.puts("  #{@dim}Memory not available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_tools(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Available Tools#{@reset}")
    IO.puts("")

    tools = ToolsRegistry.list_tools_direct()

    tools
    |> Enum.sort_by(fn t -> t[:name] || t.name end)
    |> Enum.each(fn tool ->
      name = tool[:name] || tool.name
      desc = tool[:description] || tool.description || ""
      truncated_desc = String.slice(desc, 0, 55)
      padded = String.pad_trailing(name, 22)
      IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}#{truncated_desc}#{@reset}")
    end)

    IO.puts("")
    IO.puts("  #{@dim}#{length(tools)} tools available#{@reset}")
    IO.puts("")
    session_id
  end

  # ── /skill — list / run / enable / disable / delete / reload ─────────
  #
  # Verb dispatcher reachable from the TUI (POST /commands/execute command="skill"
  # arg="<verb> <rest>") and the CLI REPL. Reuses the existing SkillManager and
  # UseSkill tools so there is exactly ONE implementation of each operation.
  def cmd_skill(args, session_id) do
    {verb, rest} = parse_command(args)
    rest = String.trim(rest)

    case verb do
      v when v in ["", "list", "ls"] ->
        cmd_skills(args, session_id)

      "enable" when rest != "" ->
        print_skill_result(SkillManager.execute(%{"action" => "enable", "name" => rest}))
        session_id

      "disable" when rest != "" ->
        print_skill_result(SkillManager.execute(%{"action" => "disable", "name" => rest}))
        session_id

      "delete" when rest != "" ->
        print_skill_result(SkillManager.execute(%{"action" => "delete", "name" => rest}))
        session_id

      "reload" ->
        print_skill_result(SkillManager.execute(%{"action" => "reload"}))
        session_id

      v when v in ["run", "use"] ->
        {name, task} = parse_command(rest)
        name = String.trim(name)
        task = String.trim(task)

        cond do
          name == "" ->
            IO.puts("  #{@yellow}Usage: /skill run <name> <task>#{@reset}")

          task == "" ->
            IO.puts(
              "  #{@yellow}Usage: /skill run #{name} <task> — a task/prompt is required#{@reset}"
            )

          true ->
            IO.puts("  #{@dim}Running skill '#{name}'...#{@reset}")

            print_skill_result(
              UseSkill.execute(%{
                "skill_name" => name,
                "task" => task,
                "__session_id__" => session_id
              })
            )
        end

        session_id

      v when v in ["enable", "disable", "delete"] ->
        IO.puts("  #{@yellow}Usage: /skill #{v} <name>#{@reset}")
        session_id

      _ ->
        IO.puts(
          "  #{@yellow}Usage: /skill [list|enable <name>|disable <name>|run <name> <task>|reload|delete <name>]#{@reset}"
        )

        session_id
    end
  rescue
    e ->
      IO.puts("  #{@yellow}error: skill command failed: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  # Render a SkillManager/UseSkill `{:ok, msg}` / `{:error, msg}` result, indented
  # and (for :ok) line-by-line so multi-line skill output stays readable.
  defp print_skill_result({:ok, msg}) do
    IO.puts("")

    msg
    |> to_string()
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("  #{line}") end)

    IO.puts("")
  end

  defp print_skill_result({:error, msg}) do
    IO.puts("\n  #{@yellow}#{msg}#{@reset}\n")
  end

  defp print_skill_result(other) do
    IO.puts("\n  #{@yellow}Unexpected skill result: #{inspect(other)}#{@reset}\n")
  end

  def cmd_skills(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Available Skills#{@reset}")
    IO.puts("")

    skills = ToolsRegistry.list_skills()

    # Canonical marker location (beside the skill's own SKILL.md) — the flat
    # `<skills_dir>/<name>/.disabled` guess this used to make was wrong for
    # every nested, renamed or non-user-scope skill.
    disabled? = &OptimalSystemAgent.Tools.Registry.SkillLoader.disabled?/1

    if length(skills) > 0 do
      Enum.each(skills, fn skill ->
        name = skill[:name] || "?"
        desc = skill[:description] || ""
        truncated = String.slice(desc, 0, 48)
        padded = String.pad_trailing(name, 22)

        {status, color} =
          if disabled?.(skill), do: {"disabled", @yellow}, else: {"active", @green}

        IO.puts(
          "  #{@cyan}#{padded}#{@reset} #{color}[#{status}]#{@reset} #{@dim}#{truncated}#{@reset}"
        )
      end)

      disabled_count = Enum.count(skills, disabled?)
      active_count = length(skills) - disabled_count

      IO.puts("")

      IO.puts(
        "  #{@dim}#{length(skills)} skills (#{active_count} active, #{disabled_count} disabled)#{@reset}"
      )

      IO.puts(
        "  #{@dim}/skill enable <name> · /skill disable <name> · /skill run <name> <task>#{@reset}"
      )
    else
      IO.puts("  #{@dim}No skills loaded#{@reset}")
      IO.puts("  #{@dim}Add one at ~/.osa/skills/<name>/SKILL.md, then /skill reload#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # Runtime agent dashboard: live/recent subagent RUNS first (what the agent is
  # actually doing right now), then the available agent ROLES it can spawn.
  def cmd_agents(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Agent Dashboard#{@reset}")
    IO.puts("")

    runs = safe_run_list()

    if runs != [] do
      IO.puts("  #{@dim}Live & recent runs#{@reset}")

      Enum.each(runs, fn run ->
        id = to_string(Map.get(run, :agent_id, "?"))
        role = to_string(Map.get(run, :role, "agent"))
        status = to_string(Map.get(run, :status, "?"))
        icon = run_status_icon(status)
        padded = String.pad_trailing(id, 20)

        IO.puts("  #{icon} #{@cyan}#{padded}#{@reset} #{@dim}#{role} · #{status}#{@reset}")
      end)

      IO.puts("")
    end

    try do
      agents = OptimalSystemAgent.Agents.Registry.list()

      if is_list(agents) and length(agents) > 0 do
        IO.puts("  #{@dim}Available roles#{@reset}")

        Enum.each(agents, fn agent ->
          name = agent[:name] || agent[:role] || "?"
          tier = agent[:tier] || :specialist
          desc = agent[:description] || ""
          truncated = String.slice(desc, 0, 45)
          tier_label = "#{tier}"
          padded = String.pad_trailing(name, 18)

          IO.puts(
            "  #{@cyan}#{padded}#{@reset} #{@dim}[#{tier_label}]#{@reset} #{@dim}#{truncated}#{@reset}"
          )
        end)

        IO.puts("")
        IO.puts("  #{@dim}#{length(runs)} run(s) · #{length(agents)} role(s)#{@reset}")
      else
        if runs == [], do: IO.puts("  #{@dim}No agent runs or roles yet#{@reset}")
      end
    rescue
      _ ->
        if runs == [], do: IO.puts("  #{@dim}Agent registry not available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── /bg — background work (subagent runs + background commands) ───────

  def cmd_bg(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Background Work#{@reset}")
    IO.puts("")

    runs = safe_run_list()

    bg_cmds =
      try do
        OptimalSystemAgent.Shell.BackgroundManager.list()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    if runs == [] and bg_cmds == [] do
      IO.puts("  #{@dim}No background runs or commands.#{@reset}")
    else
      Enum.each(runs, fn run ->
        id = to_string(Map.get(run, :agent_id, "?"))
        role = to_string(Map.get(run, :role, "agent"))
        status = to_string(Map.get(run, :status, "?"))
        icon = run_status_icon(status)
        padded = String.pad_trailing(id, 20)
        IO.puts("  #{icon} #{@cyan}#{padded}#{@reset} #{@dim}#{role} · #{status}#{@reset}")
      end)

      Enum.each(bg_cmds, fn c ->
        id = to_string(Map.get(c, :id, "?"))
        status = to_string(Map.get(c, :status, "?"))
        icon = run_status_icon(status)
        padded = String.pad_trailing(id, 20)
        IO.puts("  #{icon} #{@cyan}#{padded}#{@reset} #{@dim}shell · #{status}#{@reset}")
      end)

      IO.puts("")
      IO.puts("  #{@dim}#{length(runs)} run(s) · #{length(bg_cmds)} command(s)#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── /fg — foreground a running agent / fleet node ────────────────────

  @doc """
  Switch the active session to a running agent/fleet node by its run id.

  Minimum-viable foreground switch: validates the id exists in RunStore and is
  live in the SessionRegistry, then RETURNS that id as the REPL's active session
  (subsequent input is routed to it). A true input-handoff that also transfers
  queued/streaming input needs more plumbing — see the note printed on success.
  """
  def cmd_fg(args, session_id) do
    IO.puts("")
    target = String.trim(args)

    cond do
      target == "" ->
        IO.puts("  #{@dim}Usage: /fg <run-id>#{@reset}")

        IO.puts(
          "  #{@dim}Run ids come from /bg or /agents (the live subagent/fleet runs).#{@reset}"
        )

        IO.puts("")
        session_id

      true ->
        run = fg_lookup_run(target)
        live? = fg_live?(target)

        cond do
          is_nil(run) ->
            IO.puts("  #{@yellow}No run found with id #{target}#{@reset}")
            IO.puts("  #{@dim}List runnable ids with /bg or /agents.#{@reset}")
            IO.puts("")
            session_id

          to_string(Map.get(run, :status)) not in ["running", "active", "starting"] ->
            IO.puts(
              "  #{@yellow}Run #{target} is #{Map.get(run, :status)} — only running agents can be foregrounded.#{@reset}"
            )

            IO.puts("")
            session_id

          not live? ->
            IO.puts("  #{@yellow}Run #{target} has no live process to attach to.#{@reset}")
            IO.puts("")
            session_id

          true ->
            role = to_string(Map.get(run, :role, "agent"))

            IO.puts(
              "  #{@green}✓#{@reset} Foregrounded #{@cyan}#{target}#{@reset} #{@dim}(#{role})#{@reset}"
            )

            IO.puts(
              "  #{@dim}Active session switched — your next message goes to this agent. " <>
                "Use /fg <root-id> or /resume to return.#{@reset}"
            )

            IO.puts("")
            # Returning the node id makes it the REPL's active session (dispatch
            # contract: cmd handlers return the new session_id).
            target
        end
    end
  rescue
    _ ->
      IO.puts("  #{@yellow}error: could not foreground run#{@reset}\n")
      session_id
  end

  defp fg_lookup_run(id) do
    OptimalSystemAgent.Agent.RunStore.get(id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp fg_live?(id) do
    OptimalSystemAgent.Runtime.SessionManager.live_session?(id)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp safe_run_list do
    OptimalSystemAgent.Agent.RunStore.list(limit: 20)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp run_status_icon(status) do
    case to_string(status) do
      s when s in ["running", "active", "starting"] -> "#{@yellow}◐#{@reset}"
      s when s in ["done", "completed", "ok"] -> "#{@green}●#{@reset}"
      s when s in ["failed", "error"] -> "#{@red}○#{@reset}"
      "killed" -> "#{@red}○#{@reset}"
      "cancelled" -> "#{@dim}○#{@reset}"
      _ -> "#{@dim}○#{@reset}"
    end
  end

  # ── /steer — inject a directive into the running turn ────────────────

  def cmd_steer(args, session_id) do
    alias OptimalSystemAgent.Agent.Loop
    alias OptimalSystemAgent.Runtime.SessionManager

    IO.puts("")
    text = String.trim(args)

    cond do
      text == "" ->
        IO.puts("  #{@dim}Usage: /steer <directive>#{@reset}")
        IO.puts("  #{@dim}Folds guidance into the RUNNING turn without cancelling it.#{@reset}")

      SessionManager.live_session?(session_id) ->
        Loop.steer(session_id, text)

        IO.puts(
          "  #{@green}✓#{@reset} Steer queued — the agent folds it in at its next step boundary"
        )

      true ->
        # No live turn: still queue it (drains on the next turn) so nothing is lost.
        Loop.steer(session_id, text)
        IO.puts("  #{@dim}No turn running — directive queued for the next step.#{@reset}")
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: could not steer#{@reset}\n")
      session_id
  end

  @doc """
  Anchor a cross-turn goal — the door onto `Agent.Loop.GoalTracker`.

  `GoalTracker` (cross-turn status machine, gap-fingerprint stall detector,
  lifetime run cap, reverify cadence, durable sidecar) has been fully built and
  entirely unreachable: `start/2` had no caller anywhere in `lib/`, so the only
  live entry point was `advance/2` from the verifier, advancing a goal that was
  never started. This command is that missing caller, and anchoring a goal here
  lights up five already-written subsystems at once — the tracker, the immutable
  `TaskBrief` injected into the system block every turn, the stall detector, the
  run cap, and `GoalVerifier`'s "anchored goal loop" activation heuristic.

  ## Forms

      /goal                        show status
      /goal <text>                 anchor a goal
      /goal <text> :: <criteria>   anchor with explicit acceptance criteria
      /goal pause | resume         halt / restart cross-turn pursuit
      /goal clear                  forget the goal entirely

  Criteria must be given at anchor time. `TaskBrief` is immutable by design (it
  is the run's founding instruction, not a status field), so the FIRST goal-set
  freezes them; a later `/goal ... :: ...` cannot revise them.
  """
  def cmd_goal(args, session_id) do
    alias OptimalSystemAgent.Agent.Loop.GoalTracker

    IO.puts("")

    case String.trim(args) do
      "" ->
        print_goal_status(session_id)

      verb when verb in ["pause", "stop"] ->
        GoalTracker.pause(session_id, :user)
        IO.puts("  #{@green}✓#{@reset} Goal paused. #{@dim}/goal resume to continue.#{@reset}")

      "resume" ->
        GoalTracker.resume(session_id)
        IO.puts("  #{@green}✓#{@reset} Goal resumed — stall bookkeeping reset.")

      verb when verb in ["clear", "off", "reset"] ->
        GoalTracker.reset(session_id)
        IO.puts("  #{@green}✓#{@reset} Goal cleared. Auto-continue toward it stops.")

      "status" ->
        print_goal_status(session_id)

      text ->
        anchor_goal_command(text, session_id)
    end

    IO.puts("")
    session_id
  rescue
    e ->
      IO.puts("  #{@yellow}error: could not update goal (#{Exception.message(e)})#{@reset}\n")
      session_id
  end

  # `<goal> :: <criteria>` — the separator is doubled so ordinary goal prose
  # containing a colon ("fix bug: the parser drops trailing commas") is not
  # silently split into a goal and a criterion.
  defp anchor_goal_command(text, session_id) do
    alias OptimalSystemAgent.Agent.Loop.GoalTracker

    {goal, criteria} =
      case String.split(text, "::", parts: 2) do
        [g, c] -> {String.trim(g), String.trim(c)}
        [g] -> {String.trim(g), nil}
      end

    if goal == "" do
      IO.puts("  #{@dim}Usage: /goal <text> [:: <acceptance criteria>]#{@reset}")
    else
      opts = if criteria in [nil, ""], do: [], else: [acceptance_criteria: criteria]
      snap = GoalTracker.start(session_id, goal, opts)

      IO.puts("  #{@green}✓#{@reset} Goal anchored #{@dim}(#{snap.goal_id})#{@reset}")
      IO.puts("  #{@bold}#{goal}#{@reset}")

      case criteria do
        nil ->
          IO.puts("")

          IO.puts(
            "  #{@yellow}No acceptance criteria.#{@reset} #{@dim}Completion will be judged " <>
              "against the goal text alone.#{@reset}"
          )

          IO.puts(
            "  #{@dim}For an unattended run, state what done means in checkable terms:#{@reset}"
          )

          IO.puts(
            "  #{@dim}  /goal #{goal} :: mix test passes and lib/foo.ex exports bar/1#{@reset}"
          )

        c ->
          IO.puts("  #{@dim}done when:#{@reset} #{c}")
      end

      IO.puts("")

      IO.puts(
        "  #{@dim}The agent keeps working toward this across turns. Completion is judged " <>
          "by an independent#{@reset}"
      )

      IO.puts(
        "  #{@dim}skeptic panel, not by the agent saying so. /goal pause stops it.#{@reset}"
      )
    end
  end

  defp print_goal_status(session_id) do
    alias OptimalSystemAgent.Agent.Loop.GoalTracker

    case GoalTracker.snapshot(session_id) do
      %{goal: goal} = snap when is_binary(goal) and goal != "" ->
        IO.puts("  #{@bold}Goal#{@reset} #{@dim}(#{snap.goal_id})#{@reset}")
        IO.puts("  #{goal}")
        IO.puts("")

        reason = if snap.pause_reason, do: " (#{snap.pause_reason})", else: ""

        IO.puts(
          "  #{@dim}status:#{@reset} #{snap.status}#{reason}  #{@dim}phase:#{@reset} #{snap.phase}"
        )

        IO.puts(
          "  #{@dim}turns:#{@reset} #{snap.turn_count}  " <>
            "#{@dim}verification rounds:#{@reset} #{snap.verify_run_count}/#{GoalTracker.max_runs()}"
        )

        case OptimalSystemAgent.Agent.TaskBrief.load(session_id) do
          {:ok, %{acceptance_criteria: c}} when is_binary(c) and c != "" ->
            # The brief falls back to storing the goal text when no criteria were
            # authored; showing that back as "done when: <the goal>" would read
            # as a real criterion, so say plainly that none were set.
            if String.trim(c) == String.trim(goal) do
              IO.puts("  #{@dim}done when:#{@reset} #{@yellow}not specified#{@reset}")
            else
              IO.puts("  #{@dim}done when:#{@reset} #{c}")
            end

          _ ->
            :ok
        end

        case snap.history do
          [latest | _] -> IO.puts("  #{@dim}latest:#{@reset} #{latest}")
          _ -> :ok
        end

      _ ->
        IO.puts("  #{@dim}No goal anchored. Set one with /goal <text>.#{@reset}")

        IO.puts(
          "  #{@dim}An anchored goal is pursued across turns until an independent panel#{@reset}"
        )

        IO.puts("  #{@dim}judges it complete, it stalls, or it hits its run cap.#{@reset}")
    end
  end

  def cmd_sessions(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Active Sessions#{@reset}")
    IO.puts("")

    try do
      sessions =
        Registry.select(OptimalSystemAgent.SessionRegistry, [
          {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
        ])

      if length(sessions) > 0 do
        Enum.each(sessions, fn {sid, _pid, _meta} ->
          marker = if sid == session_id, do: "#{@green}*#{@reset}", else: " "

          case OptimalSystemAgent.Memory.SessionTitler.display_title(sid) do
            title when is_binary(title) and title != "" ->
              IO.puts("  #{marker} #{title}  #{@dim}#{sid}#{@reset}")

            _ ->
              IO.puts("  #{marker} #{@dim}#{sid}#{@reset}")
          end
        end)
      else
        IO.puts("  #{@dim}#{session_id}#{@reset} #{@green}(current)#{@reset}")
      end
    rescue
      _ ->
        IO.puts("  #{@dim}#{session_id}#{@reset} #{@green}(current)#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_tasks(_args, session_id) do
    IO.puts("")

    try do
      tasks = Tasks.get_tasks(session_id)

      if is_list(tasks) and length(tasks) > 0 do
        IO.puts(TaskDisplay.render(tasks, Renderer.terminal_width() - 4))
      else
        IO.puts("  #{@dim}No active tasks#{@reset}")
      end
    rescue
      _ ->
        IO.puts("  #{@dim}Task tracker not available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_plan(_args, session_id) do
    IO.puts("")

    case Loop.toggle_plan_mode(session_id) do
      {:ok, true} ->
        IO.puts(
          "  #{@green}#{@reset} Plan mode #{@bold}enabled#{@reset} — agent will propose a plan before acting"
        )

      {:ok, false} ->
        IO.puts("  #{@green}#{@reset} Plan mode #{@bold}disabled#{@reset}")

      {:error, :no_session} ->
        IO.puts("  #{@yellow}error: session not found#{@reset}")

      {:error, _reason} ->
        IO.puts("  #{@yellow}error: could not toggle plan mode#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_doctor(args, session_id) do
    IO.puts("")
    # Pass the args through: `Doctor.run/1` already dispatches `--config` /
    # `--all` to the setup-inspection report, but the TUI dropped its args and
    # called `run/0`, so `/doctor --config` was silently the plain health
    # report and the inspection report was reachable ONLY from `osa doctor
    # --config` outside a session. An empty arg list takes the `run/0` branch,
    # so bare `/doctor` is unchanged.
    OptimalSystemAgent.CLI.Doctor.run(String.split(String.trim(args), ~r/\s+/, trim: true))
    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: doctor not available#{@reset}\n")
      session_id
  end

  def cmd_version(_args, session_id) do
    alias OptimalSystemAgent.ReleaseNotes

    version = ReleaseNotes.current_version()

    hash =
      try do
        case OptimalSystemAgent.Git.cmd(["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
          {h, 0} -> " (#{String.trim(h)})"
          _ -> ""
        end
      rescue
        _ -> ""
      end

    IO.puts("\n  #{@bold}OSA#{@reset} #{@dim}v#{version}#{hash}#{@reset}")

    # Version-check: three outcomes, printed as three different sentences.
    # "I could not find out" used to render as the green tick, which is how an
    # install with nothing authoritative to compare against reported itself as
    # current indefinitely.
    case ReleaseNotes.version_status() do
      %{status: :update_available, latest: latest} ->
        IO.puts(
          "  #{@yellow}↑#{@reset} #{@bold}v#{latest}#{@reset} #{@dim}available — run#{@reset} " <>
            "#{@cyan}osa update#{@reset} #{@dim}to upgrade, then#{@reset} #{@cyan}/release-notes#{@reset}"
        )

      %{status: :current, latest: latest} ->
        IO.puts("  #{@green}✓#{@reset} #{@dim}up to date (latest v#{latest})#{@reset}")

      %{status: :unknown} ->
        IO.puts(
          "  #{@yellow}?#{@reset} #{@dim}could not check for updates — nothing local knows what " <>
            "has been published. Run#{@reset} #{@cyan}osa update check#{@reset}#{@dim}.#{@reset}"
        )

      _ ->
        :ok
    end

    IO.puts("")
    session_id
  end

  def cmd_release_notes(args, session_id) do
    alias OptimalSystemAgent.ReleaseNotes

    n =
      case Integer.parse(String.trim(args)) do
        {count, _} when count > 0 -> min(count, 10)
        _ -> 1
      end

    IO.puts("")

    IO.puts(
      "  #{@bold}What's New#{@reset} #{@dim}(OSA v#{ReleaseNotes.current_version()})#{@reset}"
    )

    IO.puts("")

    text = ReleaseNotes.latest_text(n)

    text
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("  #{line}") end)

    IO.puts("")
    session_id
  end

  def cmd_export(args, session_id) do
    IO.puts("")

    export_dir = Path.expand("~/.osa/exports")
    File.mkdir_p!(export_dir)

    target_id =
      case String.trim(args) do
        "" -> session_id
        id -> id
      end

    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(target_id)

    if transcript == [] do
      IO.puts("  #{@dim}No transcript data for #{target_id}#{@reset}")
      IO.puts("  #{@dim}(Transcripts are saved after each response)#{@reset}")
    else
      md_lines =
        Enum.map(transcript, fn t ->
          role = String.capitalize(to_string(t.role))
          ts = t.inserted_at || ""
          "### #{role} (#{ts})\n\n#{t.content}\n"
        end)

      markdown = "# Session Export: #{target_id}\n\n" <> Enum.join(md_lines, "\n---\n\n")
      filename = "#{target_id}.md"
      path = Path.join(export_dir, filename)
      File.write!(path, markdown)

      IO.puts("  #{@green}✓#{@reset} Exported #{length(transcript)} turns to:")
      IO.puts("  #{@cyan}#{path}#{@reset}")
    end

    IO.puts("")
    session_id
  rescue
    e ->
      IO.puts("  #{@yellow}error: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  def cmd_save(args, session_id), do: cmd_export(args, session_id)

  def cmd_loop(args, session_id) do
    alias OptimalSystemAgent.Agent.LoopControl

    IO.puts("")

    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      [] ->
        print_loop_status(LoopControl.status(session_id))

      [verb] when verb in ["", "status", "show"] ->
        print_loop_status(LoopControl.status(session_id))

      [verb] when verb in ["stop", "off", "clear"] ->
        :ok = LoopControl.stop(session_id)
        IO.puts("  #{@green}✓#{@reset} Loop stopped")

      [interval, prompt] ->
        with {:ok, interval_ms} <- LoopControl.parse_interval(interval),
             {:ok, loop} <- LoopControl.start(session_id, interval_ms, prompt) do
          IO.puts("  #{@green}✓#{@reset} Loop active every #{interval}")
          IO.puts("  #{@dim}#{loop["prompt"]}#{@reset}")
          IO.puts("  #{@dim}/loop stop to cancel#{@reset}")
        else
          _ -> IO.puts("  #{@yellow}Usage: /loop <5s|5m|2h> <prompt> | stop | status#{@reset}")
        end

      _ ->
        IO.puts("  #{@yellow}Usage: /loop <5s|5m|2h> <prompt> | stop | status#{@reset}")
    end

    IO.puts("")
    session_id
  rescue
    error ->
      IO.puts("  #{@yellow}error: #{Exception.message(error)}#{@reset}\n")
      session_id
  end

  defp print_loop_status(nil) do
    IO.puts("  #{@dim}No operator loop is active for this session.#{@reset}")
  end

  defp print_loop_status(loop) do
    seconds = div(loop["interval_ms"], 1_000)
    IO.puts("  #{@bold}Operator loop#{@reset} every #{seconds}s")
    IO.puts("  #{loop["prompt"]}")
    IO.puts("  #{@dim}ticks: #{loop["tick_count"]} · /loop stop to cancel#{@reset}")
  end

  def cmd_effort(args, session_id) do
    alias OptimalSystemAgent.Agent.Effort
    IO.puts("")

    case String.trim(args) do
      s when s in ["", "current", "status"] ->
        current = Effort.current()
        config = Effort.get(current)
        IO.puts("  #{@bold}Effort Level: #{current}#{@reset}")
        IO.puts("  #{@dim}#{config.description}#{@reset}")
        IO.puts("")
        IO.puts("  #{@dim}Thinking budget:#{@reset} #{config.thinking_budget} tokens")
        IO.puts("  #{@dim}Max iterations:#{@reset}  #{effort_iteration_display()}")
        IO.puts("  #{@dim}Temperature:#{@reset}     #{config.temperature}")
        IO.puts("")
        IO.puts("  #{@dim}Usage: /effort fast|medium|high|xhigh|ultra#{@reset}")

      level_str ->
        # Effort.set normalizes legacy names (low→fast, max→xhigh) and validates.
        case Effort.set(level_str) do
          :ok ->
            level = Effort.current()
            config = Effort.get(level)

            IO.puts(
              "  #{@green}✓#{@reset} Effort set to #{@bold}#{level}#{@reset} — #{config.description}"
            )

          {:error, _} ->
            IO.puts("  #{@yellow}error: invalid level '#{level_str}'#{@reset}")
            IO.puts("  #{@dim}Valid levels: fast, medium, high, xhigh, ultra#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: invalid level#{@reset}")
      IO.puts("  #{@dim}Valid levels: fast, medium, high, xhigh, ultra#{@reset}\n")
      session_id
  end

  def cmd_fast(_args, session_id) do
    alias OptimalSystemAgent.Agent.Effort
    IO.puts("")

    Effort.toggle_fast()
    config = Effort.get(Effort.current())

    mode =
      if Effort.fast_mode?(),
        do: "enabled",
        else: "disabled"

    IO.puts("  #{@green}✓#{@reset} Fast mode #{@bold}#{mode}#{@reset}")
    IO.puts("  #{@dim}Effort:#{@reset}     #{Effort.current()}")
    IO.puts("  #{@dim}Iterations:#{@reset} #{effort_iteration_display()}")
    IO.puts("  #{@dim}Output cap:#{@reset} #{config.max_response_tokens} tokens")
    IO.puts("  #{@dim}Tool cap:#{@reset}   #{config.tool_budget}")

    IO.puts("")
    session_id
  end

  # What the iteration ceiling ACTUALLY is, not what the effort ladder says.
  #
  # Effort no longer governs run length: it sets thinking depth, response
  # ceiling and temperature, while the loop reads
  # `config :optimal_system_agent, :max_iterations` and otherwise runs
  # effectively unbounded (see `Loop.ReactLoop`). The ladder still carries a
  # per-tier `max_iterations` for callers that ask for one, so printing it here
  # advertised a cap that no longer applies - `/fast` announced "Iterations: 50"
  # while the real ceiling was six figures.
  #
  # A number nobody enforces is worse than no number: it invites the operator to
  # structure work around a limit that is not there.
  defp effort_iteration_display do
    case Application.get_env(:optimal_system_agent, :max_iterations) do
      n when is_integer(n) and n > 0 -> to_string(n)
      _ -> "unlimited"
    end
  end

  def cmd_coordinator(_args, session_id) do
    IO.puts("")

    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] ->
        try do
          state = :sys.get_state(pid)
          current = state.coordinator || false

          if current do
            # Restart session without coordinator mode
            new_id = Session.start_new_session(session_id)

            IO.puts(
              "  #{@green}✓#{@reset} Coordinator mode #{@bold}disabled#{@reset} — full tool access restored"
            )

            IO.puts("")
            new_id
          else
            # Restart session in coordinator mode
            Session.stop_session(session_id)
            new_id = "cli_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

            {:ok, _pid} =
              DynamicSupervisor.start_child(
                OptimalSystemAgent.SessionSupervisor,
                {OptimalSystemAgent.Agent.Loop,
                 session_id: new_id, channel: :cli, coordinator: true}
              )

            Session.register_permission_hook(new_id)

            IO.puts(
              "  #{@green}✓#{@reset} Coordinator mode #{@bold}enabled#{@reset} — tools restricted to delegation and messaging"
            )

            IO.puts("  #{@dim}  session: #{new_id}#{@reset}")
            IO.puts("")
            new_id
          end
        rescue
          _ ->
            IO.puts("  #{@yellow}error: could not toggle coordinator mode#{@reset}")
            IO.puts("")
            session_id
        end

      _ ->
        IO.puts("  #{@yellow}error: session not found#{@reset}")
        IO.puts("")
        session_id
    end
  end

  # ── /ask-user — may the agent stop and ask you something? ─────────────
  #
  # Off by default, in every context (see `Agent.AskUserMode`). The failure it
  # removes is concrete: an unattended long-running session calls `ask_user`,
  # blocks for five minutes on a question nobody is there to answer, and does
  # nothing until the timeout — then asks again. A stated assumption the
  # operator can correct afterwards beats a session that stopped.
  #
  # `/ask-user` with no argument REPORTS rather than toggles. A blind toggle
  # on a setting whose whole purpose is "I want to know when the agent can
  # interrupt me" is how you end up unsure which state you are in.
  def cmd_ask_user(args, session_id) do
    IO.puts("")

    case parse_on_off(args) do
      :show ->
        {:ok, on?} = Loop.get_ask_user(session_id)
        print_ask_user_state(on?, false)

      {:ok, on?} ->
        {:ok, applied} = Loop.set_ask_user(session_id, on?)
        print_ask_user_state(applied, true)

      :error ->
        IO.puts("  #{@yellow}usage: /ask-user [on|off]#{@reset}")
        IO.puts("")
    end

    session_id
  end

  defp parse_on_off(args) do
    case args |> to_string() |> String.trim() |> String.downcase() do
      "" -> :show
      "status" -> :show
      v when v in ~w(on true 1 yes enable enabled) -> {:ok, true}
      v when v in ~w(off false 0 no disable disabled) -> {:ok, false}
      _ -> :error
    end
  end

  # The changed-tool-array cost is stated, not hidden. Enabling mid-session
  # rewrites the provider tool array, which re-primes the prompt cache once on
  # the next request; saying so is cheaper than an operator discovering a
  # one-off latency bump and not knowing why.
  defp print_ask_user_state(on?, changed?) do
    if on? do
      IO.puts(
        "  #{@green}✓#{@reset} Questions #{@bold}enabled#{@reset} — the agent may stop and ask you mid-task"
      )

      if changed? do
        IO.puts(
          "  #{@dim}  takes effect on the next request; the tool list changed, so the prompt cache re-primes once#{@reset}"
        )
      end
    else
      IO.puts(
        "  #{@green}✓#{@reset} Questions #{@bold}disabled#{@reset} — the agent proceeds on its best assumption and states it"
      )

      if changed? do
        IO.puts("  #{@dim}  takes effect on the next request#{@reset}")
      end
    end

    IO.puts("")
  end

  # ── /login, /logout — real account sign-in ────────────────────────────
  #
  # These once ran an Anthropic OAuth flow with Claude Code's first-party
  # client id; that was removed (see `Auth.LegacyAnthropicOAuth`) and for one
  # release the commands were left printing "no provider supports account
  # sign-in", which stopped being true the moment the first subscription
  # provider shipped. They now drive the real thing, and share every line of
  # their behaviour with `osa auth` so the REPL and the terminal can never
  # disagree about who is signed in.

  def cmd_login(args, session_id) do
    case String.trim(args) do
      "" ->
        OptimalSystemAgent.CLI.Auth.status()

        IO.puts(
          "  #{@dim}Sign in with#{@reset}  #{@cyan}/login <provider>#{@reset}  " <>
            "#{@dim}— or paste a key with#{@reset}  #{@cyan}/setup#{@reset}"
        )

        IO.puts("")

      provider ->
        _ = OptimalSystemAgent.CLI.Auth.login(provider)
    end

    session_id
  end

  def cmd_logout(args, session_id) do
    case String.trim(args) do
      "" ->
        # Naming the provider is required rather than guessed. Signing a user
        # out of something they did not name is the kind of "helpful" default
        # that costs them a re-authentication.
        OptimalSystemAgent.CLI.Auth.status()

        IO.puts("  #{@dim}Sign out with#{@reset}  #{@cyan}/logout <provider>#{@reset}")
        IO.puts("")

      "--all" ->
        _ = OptimalSystemAgent.CLI.Auth.logout_all()

      provider ->
        _ = OptimalSystemAgent.CLI.Auth.logout(provider)
    end

    if OptimalSystemAgent.Auth.LegacyAnthropicOAuth.purged?() do
      IO.puts(
        "  #{@dim}A stale ~/.osa/oauth.json from the removed Anthropic sign-in was deleted.#{@reset}"
      )

      IO.puts("")
    end

    session_id
  end

  def cmd_setup(_args, session_id) do
    IO.puts("")
    OptimalSystemAgent.CLI.Setup.run()
    IO.puts("")
    session_id
  end

  # ── /customize — "make OSA yours" cheat-sheet + starter-template seeding ──
  #
  # Prints where every customization surface lives under ~/.osa/ and, with the
  # `seed` argument, copies the starter templates into place using the existing
  # `Onboarding.seed_workspace/0` "only-if-not-exists" guard (never overwrites).

  @customize_rows [
    {"IDENTITY.md", "who OSA is — name, role, personality"},
    {"SOUL.md", "voice & values — how OSA speaks and decides"},
    {"USER.md", "your profile — who OSA is working for"},
    {"HEARTBEAT.md", "proactive work OSA does on its own when idle"},
    {"CRONS.json", "scheduled tasks that run on a recurring timer"},
    {"TRIGGERS.json", "event-driven tasks fired when something happens"},
    {"config.json", "provider/model, budgets, machines, channels"},
    {"skills/<name>/SKILL.md", "reusable skills OSA can load on demand"},
    {"commands/<name>.md", "custom /slash commands — body becomes the prompt ($ARGUMENTS)"},
    {"workflows/<id>.json", "multi-step workflow templates"}
  ]

  def cmd_customize(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "seed" ->
        seed_customize_templates()

      _ ->
        print_customize_cheatsheet()
    end

    IO.puts("")
    session_id
  end

  defp print_customize_cheatsheet do
    osa_dir = Path.expand("~/.osa")

    IO.puts("  #{@bold}Make OSA yours#{@reset}")

    IO.puts(
      "  #{@dim}OSA works out of the box — everything below is optional and lives in #{osa_dir}/#{@reset}"
    )

    IO.puts("")

    Enum.each(@customize_rows, fn {path, purpose} ->
      exists? = File.exists?(Path.join(osa_dir, hd(String.split(path, "/"))))
      marker = if exists?, do: "#{@green}●#{@reset}", else: "#{@dim}○#{@reset}"
      padded = String.pad_trailing("~/.osa/#{path}", 26)
      IO.puts("  #{marker} #{@cyan}#{padded}#{@reset} #{@dim}#{purpose}#{@reset}")
    end)

    IO.puts("")

    IO.puts(
      "  #{@dim}See examples/ (or examples/README.md) for ready-to-copy templates.#{@reset}"
    )

    IO.puts(
      "  #{@dim}Run #{@reset}#{@cyan}/customize seed#{@reset}#{@dim} to copy starter templates into ~/.osa/ (never overwrites).#{@reset}"
    )
  end

  defp seed_customize_templates do
    osa_dir = Path.expand("~/.osa")

    before = MapSet.new(list_osa_files(osa_dir))
    OptimalSystemAgent.Onboarding.seed_workspace()
    seeded = list_osa_files(osa_dir) |> Enum.reject(&MapSet.member?(before, &1)) |> Enum.sort()

    cond do
      seeded != [] ->
        IO.puts("  #{@green}✓#{@reset} Seeded starter templates into #{osa_dir}/:")

        Enum.each(seeded, fn f ->
          IO.puts("    #{@cyan}#{f}#{@reset}")
        end)

      true ->
        IO.puts(
          "  #{@dim}All starter templates already present in #{osa_dir}/ — nothing to copy.#{@reset}"
        )
    end

    IO.puts(
      "  #{@dim}Existing files were left untouched. Edit them, then restart OSA to apply.#{@reset}"
    )
  rescue
    e ->
      IO.puts("  #{@yellow}error: could not seed templates: #{Exception.message(e)}#{@reset}")
  end

  defp list_osa_files(osa_dir) do
    case File.ls(osa_dir) do
      {:ok, files} -> files
      _ -> []
    end
  end

  def cmd_channels(_args, session_id) do
    alias OptimalSystemAgent.Channels.Manager

    channels = Manager.list_channels()

    IO.puts("")
    IO.puts("  #{@bold}Messaging Channels#{@reset}")
    IO.puts("")

    if channels == [] do
      IO.puts("  #{@dim}No channels configured#{@reset}")
    else
      for ch <- channels do
        status =
          if ch.connected,
            do: "#{@green}● connected#{@reset}",
            else: "#{@dim}○ not running#{@reset}"

        IO.puts("  #{@cyan}#{String.pad_trailing(to_string(ch.name), 12)}#{@reset} #{status}")
      end
    end

    IO.puts("")
    IO.puts("  #{@dim}Configure channels with /setup or set env vars#{@reset}")
    IO.puts("  #{@dim}Docs: TELEGRAM_BOT_TOKEN, DISCORD_BOT_TOKEN, etc.#{@reset}")
    IO.puts("")

    session_id
  rescue
    _ ->
      IO.puts("  #{@dim}Channel status unavailable#{@reset}\n")
      session_id
  end

  def cmd_resume(args, session_id) do
    alias OptimalSystemAgent.Agent.SessionPersistence
    IO.puts("")

    case String.trim(args) do
      "" ->
        sessions = SessionPersistence.list(limit: 10)

        if sessions == [] do
          IO.puts("  #{@dim}No saved sessions found.#{@reset}")
        else
          IO.puts("  #{@bold}Recent Sessions#{@reset}")
          IO.puts("")

          Enum.each(sessions, fn session ->
            id = session.session_id
            mtime = session.modified_at

            date_str =
              try do
                NaiveDateTime.to_string(mtime) |> String.slice(0, 16)
              rescue
                _ -> "?"
              end

            preview =
              try do
                case SessionPersistence.load(id) do
                  {:ok, msgs} when is_list(msgs) ->
                    first_user =
                      Enum.find(msgs, fn m ->
                        (m[:role] || m["role"]) == "user"
                      end)

                    if first_user do
                      content = first_user[:content] || first_user["content"] || ""
                      String.slice(content, 0, 70)
                    else
                      ""
                    end

                  _ ->
                    ""
                end
              rescue
                _ -> ""
              end

            # What the session was ABOUT leads the row; the opaque id is the
            # thing you type, not the thing you scan for.
            title =
              OptimalSystemAgent.Memory.SessionTitler.display_title(id) || session[:title]

            if is_binary(title) and title != "" do
              IO.puts("  #{@bold}#{title}#{@reset}")
              IO.puts("  #{@cyan}#{id}#{@reset}  #{@dim}#{date_str}#{@reset}")
            else
              IO.puts("  #{@cyan}#{id}#{@reset}  #{@dim}#{date_str}#{@reset}")
            end

            if preview != "" do
              IO.puts("    #{@dim}#{preview}#{@reset}")
            end
          end)

          IO.puts("")
          IO.puts("  #{@dim}Usage: /resume <session_id>#{@reset}")
        end

        IO.puts("")
        session_id

      target_id ->
        case SessionPersistence.load(target_id) do
          {:ok, messages} when is_list(messages) and messages != [] ->
            IO.puts("  #{@green}Resuming session #{target_id}...#{@reset}")
            Session.resume_session(target_id, messages, session_id)

          {:ok, []} ->
            IO.puts("  #{@yellow}Session #{target_id} has no messages.#{@reset}\n")
            session_id

          {:error, :not_found} ->
            IO.puts("  #{@red}Session '#{target_id}' not found.#{@reset}\n")
            session_id

          {:error, reason} ->
            IO.puts("  #{@red}Failed to load session: #{inspect(reason)}#{@reset}\n")
            session_id
        end
    end
  rescue
    e ->
      IO.puts("  #{@red}Resume error: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  def cmd_persona(args, session_id) do
    alias OptimalSystemAgent.Personality
    IO.puts("")

    case String.trim(args) do
      "" ->
        current = Personality.current()
        presets = Personality.list()

        IO.puts("  #{@bold}Persona Presets#{@reset}")
        IO.puts("")

        Enum.each(presets, fn preset ->
          marker = if preset.name == current, do: "#{@green}*#{@reset}", else: " "
          padded = String.pad_trailing(preset.name, 14)
          IO.puts("  #{marker} #{@cyan}#{padded}#{@reset} #{@dim}#{preset.description}#{@reset}")
        end)

        IO.puts("")
        IO.puts("  #{@dim}Current: #{current}. Usage: /persona <name>#{@reset}")

      name ->
        case Personality.set(name) do
          :ok ->
            preset = Enum.find(Personality.list(), &(&1.name == name))
            desc = if preset, do: preset.description, else: name

            IO.puts(
              "  #{@green}Persona set to #{@bold}#{name}#{@reset}#{@green} — #{desc}#{@reset}"
            )

          {:error, reason} ->
            IO.puts("  #{@red}#{reason}#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: personality switch failed#{@reset}\n")
      session_id
  end

  # Third exit site. Routes through the same flush-then-halt path as `exit` /
  # `quit` / Ctrl-D in `Channels.CLI` — a shutdown that persists the transcript
  # on two of three exits is a defect that only looks fixed.
  def cmd_exit(_args, session_id) do
    OptimalSystemAgent.Channels.CLI.exit_cli(session_id)
  end

  # ── Parsing & Suggestions ────────────────────────────────────────────

  defp parse_command(input) do
    parts = String.split(input, ~r/\s+/, parts: 2)

    case parts do
      [cmd] -> {String.downcase(cmd), ""}
      [cmd, args] -> {String.downcase(cmd), args}
      _ -> {input, ""}
    end
  end

  defp suggest_similar(cmd_name) do
    candidates = Map.keys(@commands)

    best =
      candidates
      |> Enum.map(fn c -> {c, String.jaro_distance(cmd_name, c)} end)
      |> Enum.filter(fn {_c, score} -> score > 0.7 end)
      |> Enum.sort_by(fn {_c, score} -> score end, :desc)
      |> Enum.take(3)

    IO.puts("#{@yellow}  error: unknown command '/#{cmd_name}'#{@reset}")

    case best do
      [{suggestion, _score} | _] ->
        IO.puts("#{@dim}  Did you mean /#{suggestion}?#{@reset}\n")

      [] ->
        IO.puts("#{@dim}  Type /help to see available commands#{@reset}\n")
    end
  end

  # ── Helpers (delegates to shared Format module) ──────────────────────

  alias OptimalSystemAgent.Channels.CLI.Format

  defp format_tokens(n), do: Format.format_tokens(n)
  defp pad_num(n), do: String.pad_leading(format_tokens(n), 8)
  defp get_model_name(provider), do: Format.get_model_name(provider)

  defp format_context_window(n), do: Format.format_context_window(n)

  # Parse a `/model` argument into an explicit provider+model or a bare model.
  # Supports "provider/model", "provider model", and "model" (provider resolved
  # from the Catalog / heuristic by the caller). A leading token is only treated
  # as a provider when it names a REGISTERED provider — otherwise the whole arg
  # is a model id (many ids legitimately contain "/", e.g. "meta-llama/…").
  defp parse_model_arg(arg) do
    cond do
      String.contains?(arg, "/") ->
        [head, rest] = String.split(arg, "/", parts: 2)

        case atomize_provider(head) do
          nil -> {:model_only, arg}
          provider when rest != "" -> {:explicit, provider, rest}
          _ -> {:model_only, arg}
        end

      true ->
        case String.split(arg, ~r/\s+/, parts: 2, trim: true) do
          [head, rest] ->
            case atomize_provider(head) do
              nil -> {:model_only, arg}
              provider -> {:explicit, provider, rest}
            end

          _ ->
            {:model_only, arg}
        end
    end
  end

  # Resolve a provider token to a registered provider atom, or nil.
  defp atomize_provider(token) do
    Enum.find(ProviderRegistry.list_providers(), fn a -> Atom.to_string(a) == token end)
  end

  # ── Permission Management ────────────────────────────────────────────

  def cmd_permissions(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        rules = OptimalSystemAgent.Permissions.list_rules()

        if map_size(rules) == 0 do
          IO.puts("  #{@dim}No permission rules configured.#{@reset}")

          IO.puts(
            "  #{@dim}Rules are saved when you choose 'Allow always' on a permission prompt.#{@reset}"
          )
        else
          IO.puts("  #{@bold}Permission Rules#{@reset}")
          IO.puts("")

          Enum.each(rules, fn {tool, action} ->
            icon =
              if action == "allow",
                do: "#{IO.ANSI.green()}✓#{@reset}",
                else: "#{IO.ANSI.red()}✗#{@reset}"

            IO.puts("  #{icon} #{tool} → #{action}")
          end)
        end

        IO.puts("")
        IO.puts("  #{@dim}Usage: /permissions add <tool> <allow|deny> | remove <tool>#{@reset}")

      "remove " <> tool_name ->
        Permissions.remove_rule(String.trim(tool_name))
        IO.puts("  #{IO.ANSI.green()}✓#{@reset} Removed rule for #{String.trim(tool_name)}")

      "add " <> rest ->
        case String.split(String.trim(rest), ~r/\s+/, parts: 2) do
          [tool, action] when action in ["allow", "deny"] and tool != "" ->
            decision = if action == "allow", do: :allow_always, else: :deny_always
            Permissions.save_rule(tool, decision)
            IO.puts("  #{IO.ANSI.green()}✓#{@reset} Added rule: #{tool} → #{action}")

          _ ->
            IO.puts("  #{@dim}Usage: /permissions add <tool> <allow|deny>#{@reset}")
        end

      _ ->
        IO.puts("  #{@dim}Usage: /permissions [add <tool> <allow|deny> | remove <tool>]#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── Additional Directories (/add-dir) ────────────────────────────────

  def cmd_add_dir(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        dirs = Permissions.additional_directories()

        if dirs == [] do
          IO.puts("  #{@dim}No additional directories configured.#{@reset}")
        else
          IO.puts("  #{@bold}Additional Directories#{@reset}")
          Enum.each(dirs, fn d -> IO.puts("  #{@green}+#{@reset} #{d}") end)
        end

        IO.puts("  #{@dim}Usage: /add-dir <path>#{@reset}")

      raw ->
        path = Path.expand(raw)

        cond do
          not File.exists?(path) ->
            IO.puts("  #{@red}error:#{@reset} #{path} does not exist")

          not File.dir?(path) ->
            IO.puts("  #{@red}error:#{@reset} #{path} is not a directory")

          true ->
            :ok = Permissions.add_directory(path)
            IO.puts("  #{@green}✓#{@reset} Added working directory: #{path}")
        end
    end

    IO.puts("")
    session_id
  end

  # ── Workspace Trust (/trust) ─────────────────────────────────────────

  def cmd_trust(args, session_id) do
    IO.puts("")
    cwd = File.cwd!()

    case String.trim(args) do
      "accept" ->
        :ok = OptimalSystemAgent.Workspace.Trust.accept(cwd)
        IO.puts("  #{@green}✓#{@reset} Workspace trusted: #{cwd}")
        IO.puts("  #{@dim}Project hooks and workspace config are now active.#{@reset}")

      "" ->
        status = OptimalSystemAgent.Workspace.Trust.status(cwd)

        state =
          cond do
            status.trusted and status.session_only ->
              "#{@green}trusted#{@reset} (this session only)"

            status.trusted ->
              "#{@green}trusted#{@reset}"

            true ->
              "#{@yellow}not trusted#{@reset}"
          end

        IO.puts("  #{@bold}Workspace#{@reset} #{cwd} — #{state}")

        if status.risks != [] do
          IO.puts("")
          IO.puts("  #{@bold}Workspace-supplied config found here:#{@reset}")
          Enum.each(status.risks, fn r -> IO.puts("  #{@yellow}!#{@reset} #{r.label}") end)
        end

        unless status.trusted do
          IO.puts("")

          IO.puts(
            "  #{@dim}Project hooks stay inert until trusted. /trust accept to trust this directory.#{@reset}"
          )
        end

      _ ->
        IO.puts("  #{@dim}Usage: /trust [accept]#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── Hooks Viewer ─────────────────────────────────────────────────────

  def cmd_hooks(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Registered Hooks#{@reset}")
    IO.puts("")

    try do
      hooks = OptimalSystemAgent.Agent.Hooks.list_hooks()

      if is_list(hooks) and length(hooks) > 0 do
        hooks
        |> Enum.sort_by(fn h -> {h[:event], h[:priority]} end)
        |> Enum.each(fn hook ->
          event = hook[:event] || "?"
          name = hook[:name] || "?"
          priority = hook[:priority] || 0
          IO.puts("  #{@cyan}#{event}#{@reset} #{@dim}p#{priority}#{@reset} #{name}")
        end)

        IO.puts("")
        IO.puts("  #{@dim}#{length(hooks)} hooks registered#{@reset}")
      else
        IO.puts("  #{@dim}No hooks registered.#{@reset}")
      end
    rescue
      _ -> IO.puts("  #{@dim}Hooks system not available.#{@reset}")
    end

    # Settings-configured hooks (CC-style entries from the user/project/local
    # settings cascade), listed per event. Project-layer entries only appear
    # once the workspace is trusted (see Settings.get_merged_hooks).
    try do
      merged = OptimalSystemAgent.Settings.get_merged_hooks()

      if map_size(merged) > 0 do
        IO.puts("")
        IO.puts("  #{@bold}Settings Hooks#{@reset}")

        merged
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.each(fn {event, entries} ->
          Enum.each(entries, fn entry ->
            label =
              case entry do
                %{"matcher" => m, "hooks" => hs} when is_list(hs) ->
                  "matcher=#{inspect(m)} (#{length(hs)} hook(s))"

                %{"command" => command} ->
                  command

                other ->
                  other |> inspect() |> String.slice(0, 80)
              end

            IO.puts("  #{@cyan}#{event}#{@reset} #{label}")
          end)
        end)
      end
    rescue
      _ -> :ok
    end

    IO.puts("")
    session_id
  end

  # ── Metrics Viewer ───────────────────────────────────────────────────

  def cmd_metrics(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Telemetry Metrics#{@reset}")
    IO.puts("")

    try do
      snapshot = OptimalSystemAgent.Telemetry.Metrics.snapshot()

      if map_size(snapshot.tools) > 0 do
        IO.puts("  #{@bold}Tools#{@reset}")

        Enum.each(snapshot.tools, fn {name, stats} ->
          IO.puts(
            "  #{@cyan}#{String.pad_trailing(to_string(name), 20)}#{@reset}" <>
              " #{stats.count} calls" <>
              " #{@dim}avg #{stats.avg_ms}ms#{@reset}" <>
              " #{@dim}p99 #{stats.p99_ms}ms#{@reset}" <>
              " #{@dim}#{stats.success}✓ #{stats.fail}✗#{@reset}"
          )
        end)

        IO.puts("")
      end

      if map_size(snapshot.providers) > 0 do
        IO.puts("  #{@bold}Providers#{@reset}")

        Enum.each(snapshot.providers, fn {name, stats} ->
          IO.puts(
            "  #{@cyan}#{String.pad_trailing(to_string(name), 20)}#{@reset}" <>
              " #{stats.count} calls" <>
              " #{@dim}avg #{stats.avg_ms}ms#{@reset}" <>
              " #{@dim}p99 #{stats.p99_ms}ms#{@reset}"
          )
        end)

        IO.puts("")
      end

      IO.puts("  #{@dim}Total turns: #{snapshot.sessions.total_turns}#{@reset}")
    rescue
      _ -> IO.puts("  #{@dim}Metrics not available.#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── MCP Servers ──────────────────────────────────────────────────────

  def cmd_mcp(args, session_id) do
    case String.split(String.trim(to_string(args)), ~r/\s+/, trim: true) do
      [] -> mcp_status(session_id)
      ["list" | _] -> mcp_status(session_id)
      ["add" | opts] -> mcp_add(opts, session_id)
      [rm | opts] when rm in ["remove", "rm"] -> mcp_remove(opts, session_id)
      ["get", name | _] -> mcp_get(name, session_id)
      ["exclude"] -> mcp_exclude_list(session_id)
      ["exclude", name | _] -> mcp_exclude(name, session_id)
      [un, name | _] when un in ["unexclude", "include"] -> mcp_unexclude(name, session_id)
      _ -> mcp_usage(session_id)
    end
  end

  defp mcp_status(session_id) do
    IO.puts("")
    IO.puts("  #{@bold}MCP Servers#{@reset}")
    IO.puts("")

    running =
      try do
        MCP.Client.Manager.list_servers()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    cond do
      running != [] ->
        Enum.each(running, fn s ->
          {icon, label} = mcp_status_display(s[:status])
          tools = s[:tool_count] || 0

          IO.puts(
            "  #{icon} #{@cyan}#{String.pad_trailing(to_string(s[:name]), 20)}#{@reset}" <>
              " #{@dim}#{s[:transport]} · #{label} · #{tools} tools · " <>
              "#{mcp_origin(s[:source], s[:scope])}#{@reset}"
          )
        end)

        total_tools = Enum.reduce(running, 0, fn s, acc -> acc + (s[:tool_count] || 0) end)

        IO.puts("")

        IO.puts("  #{@dim}#{length(running)} server(s) · #{total_tools} tools total#{@reset}")

      true ->
        configured =
          case MCP.Config.load() do
            {:ok, list} -> list
            _ -> []
          end

        if configured == [] do
          IO.puts("  #{@dim}No MCP servers configured.#{@reset}")
          IO.puts("  #{@dim}Add servers to #{MCP.Config.config_path()}#{@reset}")
        else
          Enum.each(configured, fn s ->
            IO.puts(
              "  #{@dim}○#{@reset} #{@cyan}#{String.pad_trailing(s.name, 20)}#{@reset}" <>
                " #{@dim}#{s.transport} · not started · #{mcp_origin(s.source, s.scope)}#{@reset}"
            )
          end)

          IO.puts("")

          IO.puts(
            "  #{@dim}#{length(configured)} server(s) configured (manager offline)#{@reset}"
          )
        end
    end

    mcp_import_footer()

    IO.puts("")
    session_id
  end

  # "Where did this server come from?" — the attribution line. `:osa` source
  # means one of OSA's own config files (named by scope); anything else was
  # inherited from another tool's config, which is only possible when the
  # operator opted into `mcp_import_foreign`.
  defp mcp_origin(source, scope) do
    case source || :osa do
      :osa ->
        case scope || :user do
          :user -> "osa config (~/.osa/mcp.json)"
          :project -> "project (.mcp.json)"
          :local -> "project-local (.osa/mcp.local.json)"
          other -> "osa config (#{other})"
        end

      foreign ->
        path = MCP.Discovery.source_path(foreign)
        label = MCP.Discovery.source_label(foreign)
        if path, do: "#{label} (#{path})", else: label
    end
  end

  # Report the state of foreign-config import, and — when it is off — how many
  # servers COULD be inherited plus how to opt in. This is the whole point of
  # making the import opt-in: the operator can still see what exists without
  # OSA having quietly run it.
  defp mcp_import_footer do
    excluded = MCP.Config.exclusions() |> Enum.sort()

    if excluded != [] do
      IO.puts("")
      IO.puts("  #{@dim}excluded: #{Enum.join(excluded, ", ")} (/mcp unexclude <name>)#{@reset}")
    end

    IO.puts("")

    if MCP.Discovery.import_enabled?() do
      IO.puts(
        "  #{@dim}Importing MCP servers from other tools is ON " <>
          "(settings: mcp_import_foreign). Turn off to run only OSA's own servers.#{@reset}"
      )
    else
      available =
        try do
          MCP.Discovery.available()
        rescue
          _ -> []
        end

      if available != [] do
        by_source =
          available
          |> Enum.group_by(& &1.source)
          |> Enum.map_join(", ", fn {src, list} -> "#{length(list)} from #{src}" end)

        IO.puts(
          "  #{@dim}#{length(available)} server(s) available in other tools' configs " <>
            "(#{by_source}) — NOT imported.#{@reset}"
        )

        IO.puts("  #{@dim}Import them with: /settings set mcp_import_foreign true#{@reset}")
      end
    end
  rescue
    _ -> :ok
  end

  defp mcp_exclude_list(session_id) do
    IO.puts("")

    case MCP.Config.exclusions() |> Enum.sort() do
      [] ->
        IO.puts("  #{@dim}No MCP servers excluded.#{@reset}")
        IO.puts("  #{@dim}Exclude one with: /mcp exclude <name>#{@reset}")

      names ->
        IO.puts("  #{@bold}Excluded MCP servers#{@reset}")
        IO.puts("")
        Enum.each(names, fn n -> IO.puts("  #{@dim}·#{@reset} #{n}") end)
    end

    IO.puts("")
    session_id
  end

  # Add a name to the persistent deny list in ~/.osa/settings.json. Honoured for
  # every source, so this kills one noisy server without disabling anything else.
  defp mcp_exclude(name, session_id) do
    sanitized = MCP.Config.sanitize_name(name)
    current = MCP.Config.exclusions() |> Enum.sort()
    updated = Enum.sort(Enum.uniq([sanitized | current]))

    IO.puts("")

    case OptimalSystemAgent.Settings.set_user("mcp_exclude", updated) do
      :ok ->
        IO.puts("  #{@green}✓#{@reset} Excluded #{@cyan}#{sanitized}#{@reset}")
        IO.puts("  #{@dim}It will not load from any source. Restart or /mcp reload.#{@reset}")
        mcp_safe_reload()

      other ->
        IO.puts("  #{@red}✗#{@reset} Could not write settings: #{inspect(other)}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_unexclude(name, session_id) do
    sanitized = MCP.Config.sanitize_name(name)
    updated = MCP.Config.exclusions() |> Enum.reject(&(&1 == sanitized)) |> Enum.sort()

    IO.puts("")

    case OptimalSystemAgent.Settings.set_user("mcp_exclude", updated) do
      :ok ->
        IO.puts("  #{@green}✓#{@reset} No longer excluding #{@cyan}#{sanitized}#{@reset}")
        mcp_safe_reload()

      other ->
        IO.puts("  #{@red}✗#{@reset} Could not write settings: #{inspect(other)}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_status_display(status) do
    case status do
      s when s in [:ready, :connected, :running] ->
        {"#{@green}●#{@reset}", "connected"}

      s when s in [:initializing, :connecting, :starting] ->
        {"#{@yellow}◐#{@reset}", "connecting"}

      :disabled ->
        {"#{@dim}○#{@reset}", "disabled"}

      :down ->
        {"#{@red}○#{@reset}", "down"}

      other ->
        {"#{@dim}○#{@reset}", to_string(other || "unknown")}
    end
  end

  defp mcp_add(opts, session_id) do
    {flags, positional} = mcp_parse_opts(opts)
    scope = mcp_scope(flags[:scope])
    transport = flags[:transport]

    case positional do
      [name, target | rest] ->
        url_like =
          String.starts_with?(target, "http://") or String.starts_with?(target, "https://") or
            String.ends_with?(target, "/sse")

        if is_nil(transport) and url_like do
          IO.puts(
            "  #{@yellow}!#{@reset} #{@dim}#{target} looks like a URL; assuming remote transport. Pass -t stdio to override.#{@reset}"
          )
        end

        spec =
          cond do
            transport in ["http", "sse"] or (is_nil(transport) and url_like) ->
              %{"url" => target}
              |> then(fn m -> if transport, do: Map.put(m, "type", transport), else: m end)
              |> mcp_maybe_put("headers", mcp_header_map(flags[:headers]))

            true ->
              %{"command" => target, "args" => rest}
              |> mcp_maybe_put("env", mcp_env_map(flags[:env]))
          end

        case MCP.Config.add_server(name, spec, scope) do
          {:ok, path} ->
            IO.puts(
              "  #{@green}✓#{@reset} Added MCP server #{@cyan}#{name}#{@reset} #{@dim}(#{scope})#{@reset}"
            )

            IO.puts("  #{@dim}File modified: #{path}#{@reset}")
            mcp_safe_reload()

          {:error, reason} ->
            IO.puts("  #{@red}✗#{@reset} Failed to add #{name}: #{inspect(reason)}")
        end

      _ ->
        IO.puts(
          "  #{@dim}Usage: /mcp add <name> <command|url> [args...] [-s local|user|project] [-t stdio|sse|http] [-e K=V] [-H 'Header: value']#{@reset}"
        )
    end

    IO.puts("")
    session_id
  end

  defp mcp_remove(opts, session_id) do
    {flags, positional} = mcp_parse_opts(opts)

    case positional do
      [name | _] ->
        scopes =
          if flags[:scope], do: [mcp_scope(flags[:scope])], else: MCP.Config.find_scopes(name)

        case scopes do
          [] ->
            IO.puts("  #{@dim}No MCP server named #{name} found in any scope.#{@reset}")

          [scope] ->
            case MCP.Config.remove_server(name, scope) do
              {:ok, path} ->
                IO.puts(
                  "  #{@green}✓#{@reset} Removed #{@cyan}#{name}#{@reset} #{@dim}(#{scope})#{@reset}"
                )

                IO.puts("  #{@dim}File modified: #{path}#{@reset}")
                mcp_safe_reload()

              {:error, _} ->
                IO.puts("  #{@dim}#{name} not found in #{scope}.#{@reset}")
            end

          many ->
            IO.puts("  #{@yellow}!#{@reset} #{name} exists in multiple scopes. Specify one:")
            Enum.each(many, fn s -> IO.puts("  #{@dim}/mcp remove #{name} -s #{s}#{@reset}") end)
        end

      _ ->
        IO.puts("  #{@dim}Usage: /mcp remove <name> [-s local|user|project]#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_get(name, session_id) do
    sanitized = MCP.Config.sanitize_name(name)

    case Enum.find(MCP.Config.load_all(), fn s -> s.name == sanitized end) do
      nil ->
        IO.puts("  #{@dim}No MCP server named #{name}.#{@reset}")

      s ->
        IO.puts("")
        IO.puts("  #{@bold}#{s.name}#{@reset} #{@dim}(#{s.scope})#{@reset}")
        IO.puts("  #{@dim}transport:#{@reset} #{s.transport}")

        if s.command,
          do: IO.puts("  #{@dim}command:#{@reset} #{s.command} #{Enum.join(s.args, " ")}")

        if s.url, do: IO.puts("  #{@dim}url:#{@reset} #{s.url}")

        if map_size(s.env) > 0,
          do: IO.puts("  #{@dim}env:#{@reset} #{Enum.map_join(s.env, ", ", fn {k, _} -> k end)}")

        IO.puts("  #{@dim}Remove with: /mcp remove #{s.name} -s #{s.scope}#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_usage(session_id) do
    IO.puts("")
    IO.puts("  #{@bold}/mcp#{@reset} #{@dim}— manage MCP servers#{@reset}")

    IO.puts(
      "  #{@cyan}/mcp list#{@reset}                     #{@dim}Show servers and status#{@reset}"
    )

    IO.puts(
      "  #{@cyan}/mcp add <name> <cmd|url> ...#{@reset}  #{@dim}Add a server (-s scope -t transport -e K=V -H hdr)#{@reset}"
    )

    IO.puts("  #{@cyan}/mcp remove <name> [-s scope]#{@reset}  #{@dim}Remove a server#{@reset}")

    IO.puts(
      "  #{@cyan}/mcp get <name>#{@reset}               #{@dim}Show a server's config#{@reset}"
    )

    IO.puts(
      "  #{@cyan}/mcp exclude <name>#{@reset}            #{@dim}Never load this server, from any source#{@reset}"
    )

    IO.puts(
      "  #{@cyan}/mcp unexclude <name>#{@reset}          #{@dim}Remove a name from the deny list#{@reset}"
    )

    IO.puts("")
    session_id
  end

  # Flag parser: -s/--scope, -t/--transport, -e/--env (repeatable),
  # -H/--header (repeatable). Remaining tokens are positional.
  defp mcp_parse_opts(opts), do: mcp_parse_opts(opts, %{env: [], headers: []}, [])
  defp mcp_parse_opts([], flags, pos), do: {flags, Enum.reverse(pos)}

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-s", "--scope"],
    do: mcp_parse_opts(rest, Map.put(flags, :scope, v), pos)

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-t", "--transport"],
    do: mcp_parse_opts(rest, Map.put(flags, :transport, v), pos)

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-e", "--env"],
    do: mcp_parse_opts(rest, Map.update(flags, :env, [v], &(&1 ++ [v])), pos)

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-H", "--header"],
    do: mcp_parse_opts(rest, Map.update(flags, :headers, [v], &(&1 ++ [v])), pos)

  defp mcp_parse_opts([a | rest], flags, pos), do: mcp_parse_opts(rest, flags, [a | pos])

  defp mcp_scope(nil), do: :local
  defp mcp_scope("user"), do: :user
  defp mcp_scope("global"), do: :user
  defp mcp_scope("project"), do: :project
  defp mcp_scope(_), do: :local

  defp mcp_env_map(list) do
    Enum.reduce(list || [], %{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  defp mcp_header_map(list) do
    Enum.reduce(list || [], %{}, fn pair, acc ->
      case String.split(pair, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp mcp_maybe_put(map, _key, m) when map_size(m) == 0, do: map
  defp mcp_maybe_put(map, key, m), do: Map.put(map, key, m)

  defp mcp_safe_reload do
    MCP.Client.Manager.reload()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Project Init (seed AGENTS.md generation) ─────────────────────────

  def cmd_init(_args, session_id) do
    IO.puts("")
    path = Path.join(File.cwd!(), @init_guide)
    prompt = init_prompt()

    if File.exists?(path) do
      IO.puts("  #{@dim}#{@init_guide} already exists — a fresh scan will refresh it.#{@reset}")
    end

    if seed_session_prompt(session_id, prompt) do
      IO.puts(
        "  #{@green}✓#{@reset} Scanning project — OSA will write #{@bold}#{@init_guide}#{@reset}" <>
          " with the detected stack, conventions, and build commands."
      )
    else
      IO.puts("  #{@dim}Submit this prompt to generate #{@init_guide}:#{@reset}")
      IO.puts("")
      IO.puts("  #{prompt}")
    end

    IO.puts("")
    session_id
  end

  @doc "The canned prompt used by /init to generate OSA's own project guide."
  def init_prompt do
    """
    Analyze this project and create a concise #{@init_guide} guide at the repository \
    root that helps an AI coding agent work here effectively.

    Scan the working directory to detect the tech stack and languages, the \
    build/test/lint commands, the directory layout, key conventions, and any \
    important gotchas. Then write #{@init_guide} with these sections: Overview, \
    Tech Stack, Build & Test Commands, Project Layout, Conventions, and Gotchas. \
    Keep it factual and under ~200 lines. Do not invent details you cannot verify \
    from the codebase.
    """
    |> String.trim()
  end

  # Enqueue the seed prompt onto the session's live message queue so the agent
  # actually runs it. Returns true when a live queue accepted it, false when no
  # queue exists (e.g. HTTP one-shot) so the caller can surface the prompt text.
  defp seed_session_prompt(session_id, prompt) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, {:mq, session_id}) do
      [{_pid, _}] ->
        MessageQueue.enqueue(session_id, prompt)
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # ── Copy last assistant reply ────────────────────────────────────────

  def cmd_copy(_args, session_id) do
    IO.puts("")

    case session_id |> Loop.get_messages() |> copy_payload() do
      {:ok, text} -> IO.puts(text)
      :empty -> IO.puts("  #{@dim}No assistant reply to copy yet.#{@reset}")
    end

    IO.puts("")
    session_id
  end

  @doc """
  The exact bytes `/copy` puts on stdout for a given message history.

  Separated from `cmd_copy/2` so what lands on the clipboard can be asserted
  on without standing up a live `Agent.Loop`.

  This is the sharpest of the plain-CLI render sites. The reply is model-chosen
  bytes, and the TUI copies captured stdout to the clipboard, so they go to the
  terminal AND onward into the operator's clipboard: an `ESC ] 52 ; c ;
  <base64> BEL` in a reply is a clipboard write the operator never authorised,
  and their next paste — possibly into a shell — is attacker-chosen. The reply
  is emitted rather than summarised, but never raw.

  `scrub_block/1` and not the line tier: a reply is a multi-line body, and its
  newlines are real content that must survive into the clipboard.
  """
  @spec copy_payload([map()]) :: {:ok, String.t()} | :empty
  def copy_payload(messages) when is_list(messages) do
    last =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> (m[:role] || m["role"]) in ["assistant", :assistant] end)

    content = if last, do: extract_text(last[:content] || last["content"]), else: nil

    if is_binary(content) and String.trim(content) != "" do
      {:ok, OptimalSystemAgent.CLI.Sanitize.scrub_block(content)}
    else
      :empty
    end
  end

  def copy_payload(_), do: :empty

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => t} when is_binary(t) -> t
      %{text: t} when is_binary(t) -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_text(_), do: ""

  # ── Workspace map ────────────────────────────────────────────────────

  @doc """
  `/map [path] [--refresh] [--depth N]` — print the workspace topology.

  Renders `OptimalSystemAgent.Workspace.Topology` at the terminal's real width,
  so the table sheds columns rather than wrapping on a narrow terminal. Served
  from the per-root cache unless `--refresh` is passed.
  """
  def cmd_map(args, session_id) do
    tokens = String.split(args || "", ~r/\s+/, trim: true)
    refresh? = "--refresh" in tokens or "-r" in tokens

    depth =
      case Enum.drop_while(tokens, &(&1 not in ["--depth", "-d"])) do
        [_, value | _] ->
          case Integer.parse(value) do
            {n, _} when n > 0 -> min(n, 6)
            _ -> 3
          end

        _ ->
          3
      end

    path = Enum.find(tokens, &(not String.starts_with?(&1, "-") and &1 not in [to_string(depth)]))

    cwd = OptimalSystemAgent.Workspace.Cwd.get()

    root =
      if path,
        do: Path.expand(path, cwd),
        else: OptimalSystemAgent.Workspace.Topology.workspace_root(cwd) || cwd

    IO.puts("")

    if File.dir?(root) do
      topo =
        OptimalSystemAgent.Workspace.Topology.get(root, refresh: refresh?, max_depth: depth)

      width =
        case :io.columns() do
          {:ok, cols} when is_integer(cols) and cols > 20 -> cols - 4
          _ -> 100
        end

      IO.puts(OptimalSystemAgent.Workspace.Topology.Render.report(topo, width: width))
    else
      IO.puts("  #{@red}Not a directory:#{@reset} #{root}")
    end

    IO.puts("")
    session_id
  end

  # ── Files in context ─────────────────────────────────────────────────

  def cmd_files(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Files in Context#{@reset}")
    IO.puts("")

    guide_loaded? =
      try do
        is_binary(ContextDiscovery.discover(File.cwd!()))
      rescue
        _ -> false
      end

    ref_files =
      session_id
      |> Loop.get_messages()
      |> Enum.filter(fn m -> (m[:role] || m["role"]) in ["user", :user] end)
      |> Enum.flat_map(fn m ->
        text = extract_text(m[:content] || m["content"])
        {_cleaned, refs} = ContextRefsParser.parse(text)
        for {:file, p, _range} <- refs, do: p
      end)
      |> Enum.uniq()

    if not guide_loaded? and ref_files == [] do
      IO.puts("  #{@dim}No files referenced in this session yet.#{@reset}")
      IO.puts("  #{@dim}Reference files with @file:path, or /init to scaffold a guide.#{@reset}")
    else
      if guide_loaded? do
        IO.puts("  #{@green}●#{@reset} #{@dim}project guide (auto-loaded)#{@reset}")
      end

      Enum.each(ref_files, fn p ->
        IO.puts("  #{@cyan}#{p}#{@reset} #{@dim}#{file_size_label(p)}#{@reset}")
      end)

      IO.puts("")
      IO.puts("  #{@dim}#{length(ref_files)} file reference(s)#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp file_size_label(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> "#{size} bytes"
      _ -> "not found"
    end
  end

  # ── Session rename / tag (persisted metadata) ────────────────────────

  def cmd_rename(args, session_id) do
    title = String.trim(args)
    IO.puts("")

    if title == "" do
      case SessionPersistence.get_metadata(session_id) do
        %{title: t} when is_binary(t) and t != "" ->
          IO.puts("  #{@bold}Session title:#{@reset} #{t}")

        _ ->
          IO.puts("  #{@dim}No title set. Usage: /rename <title>#{@reset}")
      end
    else
      persist_session_metadata(session_id, %{title: title})
      IO.puts("  #{@green}✓#{@reset} Session renamed to #{@bold}#{title}#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_tag(args, session_id) do
    tag = String.trim(args)
    IO.puts("")

    existing =
      case SessionPersistence.get_metadata(session_id) do
        %{tags: tags} when is_list(tags) -> tags
        _ -> []
      end

    cond do
      tag == "" and existing == [] ->
        IO.puts("  #{@dim}No tags. Usage: /tag <name>#{@reset}")

      tag == "" ->
        IO.puts("  #{@bold}Tags:#{@reset} #{Enum.join(existing, ", ")}")

      true ->
        updated = (existing ++ [tag]) |> Enum.uniq()
        persist_session_metadata(session_id, %{tags: updated})

        IO.puts(
          "  #{@green}✓#{@reset} Tagged #{@bold}#{tag}#{@reset} (#{Enum.join(updated, ", ")})"
        )
    end

    IO.puts("")
    session_id
  end

  defp persist_session_metadata(session_id, fields) do
    case SessionPersistence.update_metadata(session_id, fields) do
      :ok ->
        :ok

      {:error, :not_found} ->
        # No saved file yet — snapshot live messages first, then retry.
        SessionPersistence.auto_save(session_id)
        SessionPersistence.update_metadata(session_id, fields)

      other ->
        other
    end
  end

  # ── Sandbox backend switch ───────────────────────────────────────────

  @sandbox_backends ~w(host docker e2b miosa miosa_cli vercel)

  def cmd_sandbox(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        show_sandbox_status()

      "setup " <> target ->
        setup_sandbox(normalize_backend_name(target))

      "setup" ->
        setup_sandbox(to_string(SandboxRouter.backend_name()))

      name ->
        switch_sandbox(normalize_backend_name(name))
    end

    IO.puts("")
    session_id
  end

  defp show_sandbox_status do
    active = SandboxRouter.backend_name()

    IO.puts("  #{@bold}Sandbox Backends#{@reset}")
    IO.puts("")

    Enum.each(SandboxRouter.list_backends(), fn b ->
      marker = if b.display_name == active, do: "#{@green}*#{@reset}", else: " "

      avail =
        if b.available,
          do: "#{@green}available#{@reset}",
          else: "#{@dim}unavailable#{@reset}"

      IO.puts(
        "  #{marker} #{@cyan}#{String.pad_trailing(to_string(b.name), 10)}#{@reset}" <>
          " #{@dim}#{b.display_name}#{@reset} — #{avail}"
      )
    end)

    IO.puts("")
    IO.puts("  #{@dim}Active: #{active} · mode: #{SandboxRouter.mode()}#{@reset}")
    IO.puts("  #{@dim}Usage: /sandbox <#{Enum.join(@sandbox_backends, "|")}>#{@reset}")
  end

  # `/sandbox setup <backend>` — say exactly why a backend is unavailable and
  # exactly what fixes it. Selecting an unavailable backend and getting silence
  # is the dead end this replaces; `mix osa.sandbox.setup` cannot fill the gap
  # because the shipped release bundles ERTS and has no mix.
  defp setup_sandbox(name) do
    if name in @sandbox_backends do
      IO.puts("  #{@bold}Set up: #{name}#{@reset}")
      IO.puts("")

      checks = sandbox_checks(name)
      Enum.each(checks, &print_sandbox_check/1)

      IO.puts("")

      case Enum.find(checks, fn {ok, _label, fix} -> not ok and fix != nil end) do
        nil ->
          IO.puts("  #{@green}Ready.#{@reset} #{@dim}Select it with /sandbox #{name}#{@reset}")

        {_ok, _label, fix} ->
          IO.puts("  #{@bold}Next:#{@reset} #{@cyan}#{fix}#{@reset}")
      end
    else
      IO.puts("  #{@yellow}error: unknown backend '#{name}'#{@reset}")
      IO.puts("  #{@dim}Valid: #{Enum.join(@sandbox_backends, ", ")}#{@reset}")
    end
  end

  defp print_sandbox_check({ok, label, _fix}) do
    mark = if ok, do: "#{@green}\u2713#{@reset}", else: "#{@yellow}\u2717#{@reset}"
    IO.puts("  #{mark} #{label}")
  end

  # {passed?, human label, command that fixes it (nil when nothing to do)}
  defp sandbox_checks("host") do
    [{true, "Runs directly on this machine - nothing to set up", nil}]
  end

  defp sandbox_checks("docker") do
    docker = System.find_executable("docker")

    running? =
      docker != nil and
        match?({_, 0}, System.cmd(docker, ["info"], stderr_to_stdout: true))

    [
      {docker != nil, "docker on PATH", "install Docker Desktop"},
      {running?, "docker daemon reachable", "start Docker Desktop"}
    ]
  end

  defp sandbox_checks("miosa_cli") do
    alias OptimalSystemAgent.Sandbox.MiosaCli

    path = MiosaCli.cli_path()

    [
      {path != nil, "miosa CLI on PATH#{if path, do: " (#{path})", else: ""}",
       "npm install -g @miosa/cli"},
      {MiosaCli.credential_present?(), "authenticated (~/.miosa/config.json)", "miosa login"}
    ]
  end

  defp sandbox_checks("miosa") do
    key = System.get_env("MIOSA_PLATFORM_API_KEY")

    [
      {key not in [nil, ""], "MIOSA_PLATFORM_API_KEY set",
       "export MIOSA_PLATFORM_API_KEY=... (or use the miosa_cli backend, which reads `miosa login`)"}
    ]
  end

  defp sandbox_checks("e2b") do
    key = System.get_env("E2B_API_KEY")
    [{key not in [nil, ""], "E2B_API_KEY set", "export E2B_API_KEY=..."}]
  end

  defp sandbox_checks("vercel") do
    key = System.get_env("VERCEL_TOKEN")
    [{key not in [nil, ""], "VERCEL_TOKEN set", "export VERCEL_TOKEN=..."}]
  end

  defp sandbox_checks(_), do: []

  # `miosa-cli` reads better than `miosa_cli` at a prompt; accept either.
  defp normalize_backend_name(name) do
    name |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  defp switch_sandbox(name) do
    if name in @sandbox_backends do
      backend = String.to_existing_atom(name)
      Application.put_env(:optimal_system_agent, :sandbox_backend, backend)
      persist_sandbox_backend(name)
      IO.puts("  #{@green}✓#{@reset} Sandbox backend set to #{@bold}#{name}#{@reset}")
    else
      IO.puts("  #{@yellow}error: unknown backend '#{name}'#{@reset}")
      IO.puts("  #{@dim}Valid: #{Enum.join(@sandbox_backends, ", ")}#{@reset}")
    end
  end

  defp persist_sandbox_backend(backend) do
    path = sandbox_config_path()

    # Degrading an unreadable config.json to `%{}` here would rewrite the file
    # containing only "backend", discarding provider selection, API keys and
    # every other setting stored alongside it.
    case OptimalSystemAgent.System.JsonStore.read_map_for_write(path) do
      {:error, :corrupt} ->
        IO.puts(
          "  #{@yellow}error: #{OptimalSystemAgent.System.JsonStore.corrupt_message("sandbox backend", path)}#{@reset}"
        )

        {:error, :corrupt}

      {:ok, existing} ->
        File.mkdir_p!(Path.dirname(path))

        OptimalSystemAgent.System.AtomicFile.write!(
          path,
          Jason.encode!(Map.put(existing, "backend", backend), pretty: true)
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  defp sandbox_config_path do
    Application.get_env(
      :optimal_system_agent,
      :sandbox_config_file,
      Path.expand("~/.osa/sandbox.json")
    )
  end
end
