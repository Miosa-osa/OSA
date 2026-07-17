defmodule OptimalSystemAgent.Channels.HTTP.API.OrchestrateRoutes do
  @moduledoc """
  Phase 0 orchestrate endpoint — routes directly to Agent.Loop
  (bypasses the full orchestrator which is stripped in this build).

  The Rust TUI sends user messages as POST /api/v1/orchestrate with body:
    {"input": "...", "session_id": "...", "working_dir": "..."}

  Also handles swarm launch (POST /launch) and swarm status (GET /:swarm_id)
  when mounted at /api/v1/swarm by the parent router.
  """
  use Plug.Router
  # Shared helpers not needed — using Jason.encode! directly
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Runtime.SessionManager

  plug(:match)
  plug(:dispatch)

  # Valid swarm execution patterns (BUG-015 fix: validate against this list).
  @valid_patterns ~w(parallel pipeline debate review pact)

  # ETS table for in-memory swarm registry (lightweight, no Ecto required).
  # Rows: {swarm_id, %{status, task, pattern, started_at}}
  @swarm_table :osa_swarm_registry

  # Ensure the swarm ETS table exists. Called lazily so we don't need
  # a supervisor change — :ets.new is idempotent via try/rescue.
  defp ensure_swarm_table do
    :ets.new(@swarm_table, [:named_table, :public, :set])
  rescue
    ArgumentError -> :ok
  end

  # Cap on retained TERMINAL (completed/failed) swarm rows. Without this every
  # swarm ever launched accumulates for the life of the node, growing memory and
  # inflating the /tasks listing + active_count scan. "running" rows are kept.
  @max_terminal_swarms 500

  defp prune_swarm_terminal do
    ensure_swarm_table()

    terminal =
      @swarm_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_id, info} -> Map.get(info, :status) in ["completed", "failed"] end)

    if length(terminal) > @max_terminal_swarms do
      # ISO8601 started_at sorts lexicographically = chronologically; drop oldest.
      terminal
      |> Enum.sort_by(fn {_id, info} -> Map.get(info, :started_at, "") end, :desc)
      |> Enum.drop(@max_terminal_swarms)
      |> Enum.each(fn {id, _info} -> :ets.delete(@swarm_table, id) end)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # POST /api/v1/orchestrate — direct agent loop invocation
  post "/" do
    input = conn.body_params["input"] || ""
    session_id = conn.body_params["session_id"] || "session-#{System.unique_integer([:positive])}"
    user_id = conn.assigns[:user_id] || "anonymous"
    working_dir = conn.body_params["working_dir"]
    images = conn.body_params["images"] || []

    if input == "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        400,
        Jason.encode!(%{error: "invalid_request", details: "Missing required field: input"})
      )
    else
      # Set working directory if provided
      if working_dir && working_dir != "" do
        Application.put_env(:optimal_system_agent, :working_dir, working_dir)
      end

      # Ensure a Loop GenServer is running for this session. Pass working_dir so
      # the session persists a real directory (directory-scoped resume) rather
      # than relying on the global mutable :working_dir app-env.
      case SessionManager.ensure_loop(session_id,
             user_id: user_id,
             channel: :http,
             working_dir: working_dir
           ) do
        :ok ->
          # Register Bus handlers that bridge events to PubSub for SSE delivery.
          # The SSE stream (agent_routes.ex) listens on "osa:session:{id}" for {:osa_event, event}.
          for event_type <- [:agent_response, :system_event, :llm_response, :tool_call] do
            Bus.register_handler(event_type, fn event ->
              if Map.get(event, :session_id) == session_id do
                Phoenix.PubSub.broadcast(
                  OptimalSystemAgent.PubSub,
                  "osa:session:#{session_id}",
                  {:osa_event, event}
                )
              end
            end)
          end

          # Process the message asynchronously through the agent loop
          Task.Supervisor.async_nolink(OptimalSystemAgent.Events.TaskSupervisor, fn ->
            try do
              result = SessionManager.process_message(session_id, input, images: images)

              case result do
                {:ok, response} when is_binary(response) ->
                  Logger.info("[OrchestrateRoutes] Got response (#{byte_size(response)} bytes)")

                  Bus.emit(:system_event, %{
                    type: :orchestrate_complete,
                    session_id: session_id,
                    response: response
                  })

                {:error, reason} ->
                  Logger.warning("[OrchestrateRoutes] Agent loop error: #{inspect(reason)}")

                  Bus.emit(:system_event, %{
                    type: :cli_agent_response_ready,
                    session_id: session_id,
                    response: "Error: #{inspect(reason)}"
                  })

                other ->
                  Logger.info("[OrchestrateRoutes] Agent loop returned: #{inspect(other)}")
              end
            rescue
              e ->
                Logger.error("[OrchestrateRoutes] Agent loop crashed: #{Exception.message(e)}")

                Bus.emit(:system_event, %{
                  type: :cli_agent_response_ready,
                  session_id: session_id,
                  response: "Agent error: #{Exception.message(e)}"
                })
            end
          end)

          # Return 202 Accepted — response comes via SSE stream
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            202,
            Jason.encode!(%{
              status: "processing",
              session_id: session_id,
              message: "Message dispatched to agent loop."
            })
          )

        {:error, reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            500,
            Jason.encode!(%{error: "Failed to start agent loop", details: inspect(reason)})
          )
      end
    end
  end

  # POST /api/v1/orchestrate/complex — multi-agent orchestration with task validation
  post "/complex" do
    task = conn.body_params["task"]

    cond do
      is_nil(task) or task == "" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "invalid_request", details: "Missing required field: task"})
        )

      not is_binary(task) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "invalid_request", details: "Field 'task' must be a string"})
        )

      true ->
        session_id =
          conn.body_params["session_id"] || "complex-#{System.unique_integer([:positive])}"

        user_id = conn.assigns[:user_id] || "anonymous"

        case SessionManager.ensure_loop(session_id, user_id, :http) do
          :ok ->
            Task.Supervisor.async_nolink(OptimalSystemAgent.Events.TaskSupervisor, fn ->
              try do
                SessionManager.process_message(session_id, task)
              rescue
                e ->
                  Logger.error(
                    "[OrchestrateRoutes] Complex task crashed: #{Exception.message(e)}"
                  )
              end
            end)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              202,
              Jason.encode!(%{
                status: "running",
                task_id: session_id,
                session_id: session_id,
                message: "Complex orchestration dispatched."
              })
            )

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(422, Jason.encode!(%{error: "swarm_error", details: inspect(reason)}))
        end
    end
  end

  # POST /api/v1/swarm/launch — launch a swarm with pattern validation (BUG-015 fix)
  #
  # BUG-015: when `pattern` is provided but invalid, return 400 immediately.
  # Only fall back to the default pattern when no `pattern` was specified at all.
  post "/launch" do
    task = conn.body_params["task"]
    pattern_param = conn.body_params["pattern"]

    cond do
      is_nil(task) or task == "" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "invalid_request", details: "Missing required field: task"})
        )

      not is_binary(task) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "invalid_request", details: "Field 'task' must be a string"})
        )

      true ->
        # Validate pattern only when the caller explicitly supplied one.
        # If no pattern was supplied, default to "pipeline" silently.
        case validate_swarm_pattern(pattern_param) do
          {:error, msg} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "invalid_pattern", details: msg}))

          {:ok, pattern} ->
            swarm_id = "swarm-#{System.unique_integer([:positive, :monotonic])}"
            session_id = conn.body_params["session_id"] || swarm_id
            user_id = conn.assigns[:user_id] || "anonymous"

            ensure_swarm_table()

            started_at = DateTime.utc_now() |> DateTime.to_iso8601()

            :ets.insert(
              @swarm_table,
              {swarm_id,
               %{
                 status: "running",
                 task: task,
                 pattern: pattern,
                 session_id: session_id,
                 started_at: started_at
               }}
            )

            # Bound the registry: evict oldest terminal rows past the cap.
            prune_swarm_terminal()

            # Launch in background
            Task.start(fn ->
              try do
                case SessionManager.ensure_loop(session_id, user_id, :http) do
                  :ok ->
                    SessionManager.process_message(session_id, task)

                    ensure_swarm_table()

                    case :ets.lookup(@swarm_table, swarm_id) do
                      [{^swarm_id, info}] ->
                        :ets.insert(@swarm_table, {swarm_id, %{info | status: "completed"}})

                      _ ->
                        :ok
                    end

                  {:error, _reason} ->
                    ensure_swarm_table()

                    case :ets.lookup(@swarm_table, swarm_id) do
                      [{^swarm_id, info}] ->
                        :ets.insert(@swarm_table, {swarm_id, %{info | status: "failed"}})

                      _ ->
                        :ok
                    end
                end
              rescue
                e ->
                  Logger.error(
                    "[OrchestrateRoutes] Swarm #{swarm_id} crashed: #{Exception.message(e)}"
                  )

                  ensure_swarm_table()

                  case :ets.lookup(@swarm_table, swarm_id) do
                    [{^swarm_id, info}] ->
                      :ets.insert(@swarm_table, {swarm_id, %{info | status: "failed"}})

                    _ ->
                      :ok
                  end
              end
            end)

            Bus.emit(:system_event, %{event: :swarm_started, swarm_id: swarm_id, pattern: pattern})

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              202,
              Jason.encode!(%{
                swarm_id: swarm_id,
                status: "running",
                pattern: pattern,
                session_id: session_id,
                task: task
              })
            )
        end
    end
  end

  # GET /api/v1/orchestrate/tasks — list active orchestration tasks
  # NOTE: must appear before /:swarm_id so the literal path "tasks" is not
  # captured by the wildcard segment.
  get "/tasks" do
    ensure_swarm_table()

    tasks =
      :ets.tab2list(@swarm_table)
      |> Enum.map(fn {id, info} -> Map.put(info, :id, id) end)

    active_count = Enum.count(tasks, fn t -> Map.get(t, :status) == "running" end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{tasks: tasks, count: length(tasks), active_count: active_count})
    )
  end

  # GET /api/v1/orchestrate/:task_id/progress — task progress by ID
  # NOTE: must appear before /:swarm_id to claim the two-segment form.
  get "/:task_id/progress" do
    ensure_swarm_table()

    case :ets.lookup(@swarm_table, task_id) do
      [{^task_id, info}] ->
        body = Jason.encode!(Map.put(info, :id, task_id))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      [] ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{error: "not_found", details: "Task '#{task_id}' not found"})
        )
    end
  end

  # GET /api/v1/swarm/:swarm_id — swarm status
  get "/:swarm_id" do
    ensure_swarm_table()

    case :ets.lookup(@swarm_table, swarm_id) do
      [{^swarm_id, info}] ->
        body = Jason.encode!(Map.put(info, :id, swarm_id))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      [] ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{error: "not_found", details: "Swarm '#{swarm_id}' not found"})
        )
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end

  # ── Private helpers ────────────────────────────────────────────────────

  # Validate a swarm pattern parameter.
  #
  # BUG-015: Returns {:error, msg} when pattern is explicitly provided but
  # is not in @valid_patterns.  Returns {:ok, default} when pattern is nil
  # (omitted by caller) so that omitting the field is a valid no-op.
  defp validate_swarm_pattern(nil), do: {:ok, "pipeline"}

  defp validate_swarm_pattern(pattern) when is_binary(pattern) do
    if pattern in @valid_patterns do
      {:ok, pattern}
    else
      valid_list = Enum.join(@valid_patterns, ", ")
      {:error, "Unknown pattern '#{pattern}'. Valid patterns are: #{valid_list}"}
    end
  end

  defp validate_swarm_pattern(_other) do
    valid_list = Enum.join(@valid_patterns, ", ")
    {:error, "Pattern must be a string. Valid patterns are: #{valid_list}"}
  end
end

# Alias so existing tests referencing OrchestrationRoutes compile without changes.
defmodule OptimalSystemAgent.Channels.HTTP.API.OrchestrationRoutes do
  defdelegate call(conn, opts), to: OptimalSystemAgent.Channels.HTTP.API.OrchestrateRoutes
  defdelegate init(opts), to: OptimalSystemAgent.Channels.HTTP.API.OrchestrateRoutes
end
