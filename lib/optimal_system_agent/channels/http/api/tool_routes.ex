defmodule OptimalSystemAgent.Channels.HTTP.API.ToolRoutes do
  @moduledoc """
  Tools, skills, and commands routes.

  This module is forwarded to from three prefixes in the parent router:
    forward "/tools"    → GET /, POST /:name/execute
    forward "/skills"   → GET /, POST /create
    forward "/commands" → GET /, POST /execute

  Effective endpoints:
    GET  /tools
    POST /tools/:name/execute
    GET  /skills
    POST /skills/create
    GET  /commands           — list all commands
    GET  /commands?q=term    — fuzzy-search commands + skills, ranked by relevance
    POST /commands/execute
    POST /permissions/respond — resume a parked interactive permission request
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Tools.Registry, as: Tools

  plug(:match)
  plug(:dispatch)

  # ── GET / ─────────────────────────────────────────────────────────
  # Handles GET /tools, GET /skills, GET /commands after prefix strip.
  # Disambiguate by path_info on the conn.

  get "/" do
    case conn.path_info do
      _ ->
        # Determine which resource by looking at the script_name
        # (the stripped prefix is in conn.script_name after forward)
        case List.last(conn.script_name) do
          "skills" -> handle_list_skills(conn)
          "commands" -> handle_list_commands(conn)
          _ -> handle_list_tools(conn)
        end
    end
  end

  # ── POST /create (skills) ─────────────────────────────────────────

  post "/create" do
    with %{"name" => name, "description" => desc, "instructions" => instructions}
         when is_binary(name) and is_binary(desc) and is_binary(instructions) <- conn.body_params do
      tools = conn.body_params["tools"] || []
      triggers = conn.body_params["triggers"] || []

      skill = %{
        name: name,
        description: desc,
        instructions: instructions,
        tools: tools,
        triggers: triggers,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # Store in persistent_term alongside existing skills
      try do
        existing = :persistent_term.get({Tools, :skills}, %{})
        :persistent_term.put({Tools, :skills}, Map.put(existing, name, skill))
      rescue
        _ -> :ok
      end

      json(conn, 201, %{skill: skill, status: "created"})
    else
      _ ->
        json_error(
          conn,
          400,
          "invalid_request",
          "Missing required fields: name, description, instructions"
        )
    end
  end

  # ── POST /execute (commands) ───────────────────────────────────────

  # Commands that must NOT be executed via HTTP (they kill the process or block)
  @blocked_http_commands ~w(exit quit setup)

  # Capability-gated slash commands: a command name → the backend tool(s) that
  # must exist in the current session for it to be useful. Commands absent from
  # this map require nothing and are ALWAYS available (empty `required_tools`),
  # keeping the change fully backward-compatible. The TUI hides a command from
  # the `/` palette and `/help` until every listed tool is present, so there are
  # no "dead" commands pointing at capabilities the session doesn't have.
  @command_capabilities %{
    "memory" => ["memory_recall"],
    "mem-search" => ["memory_recall"],
    "mem-recall" => ["memory_recall"],
    "mem-save" => ["memory_save"],
    "desktop" => ["computer_use"]
  }

  # Tool names a slash command requires; `[]` (always available) when ungated.
  defp required_tools_for(name), do: Map.get(@command_capabilities, name, [])

  post "/execute" do
    with %{"command" => command} when is_binary(command) <- conn.body_params do
      cmd_name = command |> String.split() |> List.first() |> String.downcase()

      # Reconstruct the full command line from the SEPARATE `command` and `arg`
      # JSON fields the TUI sends, BEFORE any routing decision. The auto/
      # permission-mode handlers classify on tokens, and the on/off argument
      # lives in `arg` — matching on `command` alone made `/auto off` re-enable
      # the auto tier because the "off" token never arrived.
      full_command =
        case conn.body_params["arg"] do
          a when is_binary(a) and a != "" -> command <> " " <> a
          _ -> command
        end

      cond do
        auto_mode_command?(full_command) ->
          handle_auto_mode_command(conn, full_command)

        cmd_name in ~w(plan_approve plan_reject plan_edit) ->
          handle_plan_command(conn, cmd_name)

        cmd_name == "coordinator" ->
          handle_coordinator_command(conn, conn.body_params["arg"] || "")

        cmd_name in @blocked_http_commands ->
          body =
            Jason.encode!(%{
              output: "Command '#{cmd_name}' is not available via HTTP.",
              command: command
            })

          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        custom = custom_command(cmd_name) ->
          handle_custom_command(conn, custom, conn.body_params["arg"] || "")

        cmd_name in ~w(reasoning mem-save mem-search mem-recall reload debug desktop) ->
          handle_api_only_command(conn, cmd_name, conn.body_params["arg"] || "")

        true ->
          execute_cli_command(conn, full_command)
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: command")
    end
  end

  # Plan review round-trip — the TUI plan_review dialog POSTs plan_approve /
  # plan_reject / plan_edit here. Delegates to Agent.PlanMode, which reads the
  # stashed plan from PlanStore and resumes/revises execution asynchronously.
  defp handle_plan_command(conn, cmd_name) do
    session_id = conn.body_params["session_id"]
    feedback = conn.body_params["arg"] || ""

    result =
      cond do
        not is_binary(session_id) or session_id == "" ->
          {:error, "Missing session_id for #{cmd_name}."}

        cmd_name == "plan_approve" ->
          OptimalSystemAgent.Agent.PlanMode.approve(session_id)

        cmd_name == "plan_reject" ->
          OptimalSystemAgent.Agent.PlanMode.reject(session_id)

        cmd_name == "plan_edit" ->
          OptimalSystemAgent.Agent.PlanMode.edit(session_id, feedback)
      end

    output =
      case result do
        {:ok, msg} -> msg
        {:error, msg} -> msg
      end

    body = Jason.encode!(%{output: output, command: cmd_name})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # `/coordinator [on|off|toggle|status]`: the TUI coordinator posture toggle.
  # Applied IN PLACE on the live loop (no session restart / id churn), recorded
  # in the sticky `Agent.CoordinatorMode` store, and echoed as a `coordinator_mode`
  # system_event so the status-bar chip tracks it. `status` reads without changing.
  defp handle_coordinator_command(conn, arg) do
    session_id =
      conn.body_params["session_id"] || "http_#{:erlang.unique_integer([:positive])}"

    verb = arg |> to_string() |> String.trim() |> String.downcase()
    current = coordinator_active?(session_id)

    desired =
      case verb do
        v when v in ~w(on true 1 yes enable) -> true
        v when v in ~w(off false 0 no disable) -> false
        v when v in ["status", ""] -> current
        _ -> not current
      end

    {:ok, active} = OptimalSystemAgent.Agent.Loop.set_coordinator(session_id, desired)

    output =
      if active,
        do: "Coordinator mode ON (delegation and messaging only).",
        else: "Coordinator mode OFF (full tool access)."

    body = Jason.encode!(%{output: output, command: "coordinator", active: active})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp coordinator_active?(session_id) do
    case OptimalSystemAgent.Agent.Loop.get_coordinator(session_id) do
      {:ok, on?} -> on?
      _ -> false
    end
  end

  # Matches `auto_mode`, `auto_mode on/off`, `set_permission_mode auto|full`,
  # and the TUI mode-sync verbs: `permission_mode <mode>` (sent on every
  # Shift+Tab cycle) and `dangerous_mode on|off` (sent by /overdrive). The
  # latter two previously fell through to CLI dispatch as unknown commands, so
  # permission-mode changes made in the TUI never reached the backend gate.
  defp auto_mode_command?(command) do
    normalized = command |> String.trim() |> String.downcase()

    String.starts_with?(normalized, "auto_mode") or
      String.starts_with?(normalized, "set_permission_mode") or
      String.starts_with?(normalized, "permission_mode") or
      String.starts_with?(normalized, "dangerous_mode")
  end

  defp handle_auto_mode_command(conn, command) do
    tokens = command |> String.trim() |> String.downcase() |> String.split()

    session_id =
      conn.body_params["session_id"] || "http_#{:erlang.unique_integer([:positive])}"

    # A `set_permission_mode <mode>` naming one of the higher-level modes (the
    # Shift+Tab cycle: ask / accept-edits / plan / overdrive) sets permission_MODE.
    # `auto_mode` and `set_permission_mode auto|full` keep their historical
    # meaning — the unattended :auto tier / restore-to-:full.
    case classify_permission_mode(tokens) do
      {:mode, mode} -> apply_permission_mode(conn, session_id, command, mode)
      :tier -> apply_auto_mode_tier(conn, session_id, command, tokens)
    end
  end

  # Recognise an explicit permission-mode token. `auto`/`full`/`off` deliberately
  # fall through to the tier path (unchanged behavior).
  defp classify_permission_mode(tokens) do
    cond do
      # `dangerous_mode on|off` (the /overdrive toggle): ON is overdrive, OFF
      # returns to ask. Checked before the generic scan — the command token
      # itself is "dangerous_mode", which must not match the "dangerous" alias.
      "dangerous_mode" in tokens ->
        if Enum.any?(tokens, &(&1 in ~w(off false 0 no))),
          do: {:mode, :ask},
          else: {:mode, :overdrive}

      Enum.any?(tokens, &(&1 in ~w(overdrive bypass yolo dangerous))) -> {:mode, :overdrive}
      Enum.any?(tokens, &(&1 in ~w(accept-edits accept_edits auto-edit auto_edit edits))) ->
        {:mode, :accept_edits}

      Enum.any?(tokens, &(&1 in ~w(plan plan-mode plan_mode))) -> {:mode, :plan}
      Enum.any?(tokens, &(&1 in ~w(ask default prompt))) -> {:mode, :ask}
      true -> :tier
    end
  end

  defp apply_permission_mode(conn, session_id, command, mode) do
    output =
      case OptimalSystemAgent.Agent.Loop.set_permission_mode(session_id, mode) do
        {:ok, ^mode} -> "Permission mode set to #{mode}."
        {:error, :invalid_mode} -> "Unknown permission mode."
        {:error, :no_session} -> "No active session #{session_id} to set permission mode."
      end

    body = Jason.encode!(%{output: output, command: command, mode: mode})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp apply_auto_mode_tier(conn, session_id, command, tokens) do
    {tier, label} = resolve_auto_mode_tier(tokens)

    output =
      case OptimalSystemAgent.Agent.Loop.set_permission_tier(session_id, tier) do
        {:ok, ^tier} ->
          if tier == :full,
            do: "Auto-mode disabled — permission tier restored to :full.",
            else: "Auto-mode enabled — unattended execution gated by the safety Guardian."

        {:error, :no_session} ->
          "No active session #{session_id} to set permission mode #{label}."
      end

    body = Jason.encode!(%{output: output, command: command, tier: tier})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # `off`/`full`/`disable` turns auto-mode off (back to :full); anything else on.
  defp resolve_auto_mode_tier(tokens) do
    off? = Enum.any?(tokens, &(&1 in ~w(off full disable disabled stop)))
    if off?, do: {:full, "full"}, else: {:auto, "auto"}
  end

  # Return a user-defined custom command (`~/.osa/commands/<name>.md`) for
  # `cmd_name`, but only when it does NOT collide with a built-in CLI command —
  # a custom file can never shadow a core command like /help or /status.
  defp custom_command(cmd_name) do
    builtin? =
      try do
        cmd_name in OptimalSystemAgent.Channels.CLI.Commands.list()
      rescue
        _ -> false
      end

    if builtin? do
      nil
    else
      OptimalSystemAgent.Tools.Registry.CommandLoader.get(cmd_name)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # A custom command expands its Markdown body (with `$ARGUMENTS` / `{{args}}`
  # substituted) and returns it as a `kind: "prompt"` result. The TUI's command
  # handler recognises "prompt" and submits the body as the turn's prompt.
  defp handle_custom_command(conn, cmd, arg) do
    prompt = OptimalSystemAgent.Tools.Registry.CommandLoader.expand(cmd, arg)

    body =
      Jason.encode!(%{
        kind: "prompt",
        output: prompt,
        command: cmd.name
      })

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp execute_cli_command(conn, command) do
    cmd_name = command |> String.split() |> List.first() |> String.downcase()

    if cmd_name in @blocked_http_commands do
        body =
          Jason.encode!(%{
            output: "Command '#{cmd_name}' is not available via HTTP.",
            command: command
          })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      else
        session_id =
          conn.body_params["session_id"] || "http_#{:erlang.unique_integer([:positive])}"

        output =
          try do
            {:ok, string_io} = StringIO.open("")
            original_gl = Process.group_leader()
            Process.group_leader(self(), string_io)

            try do
              OptimalSystemAgent.Channels.CLI.Commands.dispatch(command, session_id)
            after
              Process.group_leader(self(), original_gl)
            end

            {_, captured} = StringIO.close(string_io)
            captured
          rescue
            e -> "Error: #{Exception.message(e)}"
          end

        clean_output =
          output
          |> String.replace(~r/\e\[[0-9;]*m/, "")
          |> String.trim()

        body = Jason.encode!(%{output: clean_output, command: command})
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      end
  end

  # ── POST /:name/execute (tools) ────────────────────────────────────

  post "/:name/execute" do
    tool_name = conn.params["name"]
    arguments = conn.body_params["arguments"] || %{}

    case Tools.execute(tool_name, arguments) do
      {:ok, result} ->
        body =
          Jason.encode!(%{
            tool: tool_name,
            status: "completed",
            result: result
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        json_error(conn, 422, "tool_error", to_string(reason))
    end
  end

  # ── POST /match — dry-run skill matching for a message ──────────────
  # Returns which skills would be triggered for a given message, without
  # actually running any agent. Useful for debugging and UI previews.

  post "/match" do
    message = conn.body_params["message"]

    cond do
      not (is_binary(message) && message != "") ->
        json_error(conn, 400, "missing_message", "'message' (non-empty string) is required")

      true ->
        matched = Tools.match_skill_triggers(message)

        skills =
          Enum.map(matched, fn {name, skill} ->
            %{
              name: name,
              description: Map.get(skill, :description, ""),
              triggers: Map.get(skill, :triggers, []),
              has_instructions: Map.get(skill, :instructions, "") != ""
            }
          end)

        body =
          Jason.encode!(%{
            message_preview: String.slice(message, 0, 120),
            matched_count: length(skills),
            skills: skills
          })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  # ── POST /respond (permissions) ────────────────────────────────────
  # The TUI permission dialog POSTs its decision here to resume the parked
  # tool call. `decision` ∈ allow | session | always | deny | deny_always |
  # clarify (aliases accepted); `note` carries clarify/steer text. Reaches the
  # blocked executing process via PermissionBroker's ETS response table.
  post "/respond" do
    request_id = conn.body_params["request_id"]

    # Canonical `decision` string preferred; legacy TUI `{allowed: bool}`
    # payloads (optionally with `allow_always`) are mapped for compatibility so
    # older clients never wedge a parked tool call into the 300s timeout.
    decision =
      conn.body_params["decision"] || conn.body_params["response"] ||
        legacy_decision(conn.body_params)

    note =
      conn.body_params["note"] || conn.body_params["clarify"] || conn.body_params["arg"]

    cond do
      not (is_binary(request_id) and request_id != "") ->
        json_error(conn, 400, "invalid_request", "Missing required field: request_id")

      not (is_binary(decision) and decision != "") ->
        json_error(conn, 400, "invalid_request", "Missing required field: decision")

      true ->
        OptimalSystemAgent.Agent.Loop.PermissionBroker.respond(
          request_id,
          %{"decision" => decision, "note" => note}
        )

        body =
          Jason.encode!(%{status: "ok", request_id: request_id, decision: decision})

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Tool endpoint not found")
  end

  # ── Private handlers ────────────────────────────────────────────────

  # Compat: older TUI builds POST `{allowed: bool}` (plus `allow_always: true`
  # from the Always button) instead of the canonical decision string. Map onto
  # the canonical vocabulary PermissionBroker.canonical/1 understands. A
  # non-boolean `allowed` falls through to nil → 400 upstream.
  defp legacy_decision(%{"allowed" => allowed} = params) when is_boolean(allowed) do
    always = params["allow_always"] == true or params["always"] == true

    case {allowed, always} do
      {true, true} -> "always"
      {true, false} -> "allow"
      {false, true} -> "deny_always"
      {false, false} -> "deny"
    end
  end

  defp legacy_decision(_), do: nil

  # ── API-only slash commands ─────────────────────────────────────────
  # Commands advertised in GET /commands (api_only entries) or emitted by the
  # TUI (`/reasoning` selector, `/desktop`) that have no CLI @commands handler.
  # Without these branches they fell through to CLI.Commands.dispatch and the
  # user saw an "Unknown command" suggestion instead of the command running.

  defp handle_api_only_command(conn, "reasoning", arg) do
    # The TUI reasoning selector sends off|fast|medium|high|xhigh|ultra; the
    # backend's canonical implementation is /effort
    # (fast|medium|high|xhigh|ultra). "off" maps to the lowest effort tier
    # (fast). Legacy low/max pass through and are normalized by /effort.
    level =
      case arg |> String.trim() |> String.downcase() do
        "off" -> "fast"
        other -> other
      end

    line = if level == "", do: "effort", else: "effort " <> level
    execute_cli_command(conn, line)
  end

  defp handle_api_only_command(conn, "mem-save", arg) do
    output =
      case String.trim(arg) do
        "" ->
          "Usage: /mem-save <text to remember>"

        content ->
          case OptimalSystemAgent.Memory.save(content, source: :user) do
            {:ok, _entry} -> "Saved to memory."
            {:error, reason} -> "Memory save failed: #{inspect(reason)}"
          end
      end

    respond_output(conn, "mem-save", output)
  rescue
    _ -> respond_output(conn, "mem-save", "Memory not available.")
  end

  defp handle_api_only_command(conn, cmd, arg) when cmd in ["mem-search", "mem-recall"] do
    query = String.trim(arg)

    output =
      cond do
        cmd == "mem-search" and query == "" ->
          "Usage: /mem-search <query>"

        query == "" ->
          case OptimalSystemAgent.Memory.recent(10) do
            {:ok, entries} when entries != [] -> format_memory_entries(entries)
            _ -> "No memory entries yet."
          end

        true ->
          case OptimalSystemAgent.Memory.recall(query, limit: 10) do
            {:ok, entries} when entries != [] -> format_memory_entries(entries)
            _ -> "No memories matched \"#{query}\"."
          end
      end

    respond_output(conn, cmd, output)
  rescue
    _ -> respond_output(conn, cmd, "Memory not available.")
  end

  defp handle_api_only_command(conn, "reload", _arg) do
    output =
      try do
        OptimalSystemAgent.Tools.Registry.reload_skills()
        skills = OptimalSystemAgent.Tools.Registry.load_skill_definitions()
        "Reloaded skills from disk — #{length(skills)} loaded."
      rescue
        _ -> "Skill reload failed."
      catch
        :exit, _ -> "Skill reload failed."
      end

    respond_output(conn, "reload", output)
  end

  defp handle_api_only_command(conn, "debug", _arg) do
    Logger.configure(level: :debug)
    respond_output(conn, "debug", "Debug logging enabled for this backend (level: debug).")
  end

  defp handle_api_only_command(conn, "desktop", _arg) do
    output =
      case System.find_executable("osa-desktop") do
        nil ->
          "OSA Desktop app not found on PATH. Build it from desktop/ (see desktop/README.md) or install the osa-desktop package."

        path ->
          spawn(fn -> System.cmd(path, [], stderr_to_stdout: true) end)
          "Launching OSA Desktop..."
      end

    respond_output(conn, "desktop", output)
  end

  defp respond_output(conn, command, output) do
    body = Jason.encode!(%{output: output, command: command})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp format_memory_entries(entries) do
    entries
    |> Enum.map(fn entry ->
      content = entry[:content] || entry["content"] || entry[:key] || inspect(entry)
      "• " <> String.slice(to_string(content), 0, 120)
    end)
    |> Enum.join("\n")
  end

  defp handle_list_tools(conn) do
    tools = Tools.list_tools()

    body =
      Jason.encode!(%{
        tools: tools,
        count: length(tools)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp handle_list_skills(conn) do
    skills = Tools.load_skill_definitions()

    summaries =
      Enum.map(skills, &Map.take(&1, [:name, :description, :category, :triggers, :priority]))

    body = Jason.encode!(%{skills: summaries, count: length(summaries)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp build_commands_list do
    # Pull from the actual CLI Commands module for single source of truth
    cli_commands =
      try do
        OptimalSystemAgent.Channels.CLI.Commands.list_with_descriptions()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    cli_entries =
      Enum.map(cli_commands, fn {name, desc} ->
        category = categorize_command(name)

        %{
          name: name,
          description: desc,
          category: category,
          required_tools: required_tools_for(name)
        }
      end)

    # Add API-only commands not in the CLI
    api_only = [
      %{
        name: "mem-search",
        description: "Search persistent memory",
        category: "memory",
        required_tools: required_tools_for("mem-search")
      },
      %{
        name: "mem-save",
        description: "Save a note to persistent memory",
        category: "memory",
        required_tools: required_tools_for("mem-save")
      },
      %{
        name: "mem-recall",
        description: "Recall recent memory entries",
        category: "memory",
        required_tools: required_tools_for("mem-recall")
      },
      %{
        name: "reload",
        description: "Reload skills and configuration",
        category: "system",
        required_tools: []
      },
      %{
        name: "debug",
        description: "Enable debug logging for the current session",
        category: "dev",
        required_tools: []
      }
    ]

    # User-defined slash commands from ~/.osa/commands/*.md. Tagged "custom" so
    # the TUI completion menu can visually distinguish them from built-ins.
    custom_entries =
      try do
        OptimalSystemAgent.Tools.Registry.CommandLoader.list_with_descriptions()
        |> Enum.map(fn {name, desc} ->
          %{name: name, description: desc, category: "custom", required_tools: []}
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    # Merge, dedup by name. Built-ins listed first so a custom command can never
    # shadow a core command (uniq_by keeps the first occurrence).
    all = cli_entries ++ api_only ++ custom_entries
    all |> Enum.uniq_by(& &1.name)
  end

  defp categorize_command(name) do
    cond do
      name in ~w(help status version doctor exit release-notes) -> "system"
      name in ~w(clear new compact init) -> "session"
      name in ~w(model login logout sandbox permissions) -> "config"
      name in ~w(context cost mcp files) -> "info"
      name in ~w(sessions export copy rename tag) -> "data"
      name in ~w(agents tools skills memory) -> "browse"
      name in ~w(tasks plan coordinator effort fast steer bg) -> "workflow"
      true -> "commands"
    end
  end

  defp handle_list_commands(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    q = conn.query_params["q"]

    if is_binary(q) and q != "" do
      handle_command_palette_search(conn, q)
    else
      commands = build_commands_list()
      body = Jason.encode!(%{commands: commands, count: length(commands)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  # Fuzzy command palette: merges commands and skills, ranked by relevance score.
  #
  # Scoring uses a simple substring match strategy:
  #   - name exact match:      1.0
  #   - name starts with q:   0.8
  #   - name contains q:      0.6
  #   - description contains q: 0.3
  #   - trigger exact match:   0.9
  #   - trigger contains q:    0.5
  #
  # Commands and skills with score > 0.0 are included. Results are sorted
  # descending by score. Type field distinguishes "command" from "skill".
  defp handle_command_palette_search(conn, q) do
    q_lower = String.downcase(q)

    command_results =
      build_commands_list()
      |> Enum.map(fn cmd ->
        score = fuzzy_score(cmd.name, cmd.description, q_lower)
        Map.put(cmd, :score, score) |> Map.put(:type, "command")
      end)
      |> Enum.filter(fn cmd -> cmd.score > 0.0 end)

    skill_results =
      :persistent_term.get({Tools, :skills}, %{})
      |> Enum.map(fn {name, skill} ->
        desc = Map.get(skill, :description, "")
        triggers = Map.get(skill, :triggers, [])
        category = Map.get(skill, :category, "skill")

        base_score = fuzzy_score(name, desc, q_lower)

        trigger_score =
          Enum.reduce(triggers, 0.0, fn t, acc ->
            t_lower = String.downcase(to_string(t))

            cond do
              t_lower == q_lower -> max(acc, 0.9)
              String.contains?(t_lower, q_lower) -> max(acc, 0.5)
              String.contains?(q_lower, t_lower) -> max(acc, 0.4)
              true -> acc
            end
          end)

        score = max(base_score, trigger_score)
        %{type: "skill", name: name, description: desc, category: category, score: score}
      end)
      |> Enum.filter(fn s -> s.score > 0.0 end)

    all =
      (command_results ++ skill_results)
      |> Enum.sort_by(fn item -> item.score end, :desc)

    body = Jason.encode!(%{results: all, count: length(all), query: q})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Score a name + description pair against a lowercase query token.
  defp fuzzy_score(name, description, q_lower) do
    name_lower = String.downcase(name)
    desc_lower = String.downcase(description)

    cond do
      name_lower == q_lower -> 1.0
      String.starts_with?(name_lower, q_lower) -> 0.8
      String.contains?(name_lower, q_lower) -> 0.6
      String.contains?(desc_lower, q_lower) -> 0.3
      true -> 0.0
    end
  end
end
