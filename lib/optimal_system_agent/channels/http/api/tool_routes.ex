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

  post "/execute" do
    with %{"command" => command} when is_binary(command) <- conn.body_params do
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
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: command")
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

  match _ do
    json_error(conn, 404, "not_found", "Tool endpoint not found")
  end

  # ── Private handlers ────────────────────────────────────────────────

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
        %{name: name, description: desc, category: category}
      end)

    # Add API-only commands not in the CLI
    api_only = [
      %{name: "mem-search", description: "Search persistent memory", category: "memory"},
      %{name: "mem-save", description: "Save a note to persistent memory", category: "memory"},
      %{name: "mem-recall", description: "Recall recent memory entries", category: "memory"},
      %{name: "reload", description: "Reload skills and configuration", category: "system"},
      %{
        name: "debug",
        description: "Enable debug logging for the current session",
        category: "dev"
      }
    ]

    # Merge, dedup by name
    all = cli_entries ++ api_only
    all |> Enum.uniq_by(& &1.name)
  end

  defp categorize_command(name) do
    cond do
      name in ~w(help status version doctor exit) -> "system"
      name in ~w(clear new compact) -> "session"
      name in ~w(model login logout) -> "config"
      name in ~w(context cost) -> "info"
      name in ~w(sessions export) -> "data"
      name in ~w(agents tools skills memory) -> "browse"
      name in ~w(tasks plan coordinator effort fast) -> "workflow"
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
