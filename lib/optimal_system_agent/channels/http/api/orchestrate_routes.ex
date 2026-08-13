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

  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Protocol.ContextRefs
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
    raw_input = conn.body_params["input"] || ""
    session_id = conn.body_params["session_id"] || "session-#{System.unique_integer([:positive])}"
    user_id = conn.assigns[:user_id] || "anonymous"
    working_dir = conn.body_params["working_dir"]
    images = normalize_images(conn.body_params["images"])
    image_source = MessageHandler.normalize_source(conn.body_params["image_source"])
    context_refs = conn.body_params["context_refs"]

    # Deferred composer @-mentions piece: non-image `@file`/`@agent` refs
    # arrive as structured `context_refs` (image refs already ride `images`).
    # Resolve them into a context block appended to the prompt here, at the
    # request/prompt-assembly boundary — Agent.Loop / ReactLoop only ever see
    # the resulting plain string, so this is purely additive: an absent or
    # empty `context_refs` leaves `input` byte-for-byte unchanged.
    input = ContextRefs.inject(raw_input, context_refs, working_dir)

    if raw_input == "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        400,
        Jason.encode!(%{error: "invalid_request", details: "Missing required field: input"})
      )
    else
      # Ensure a Loop GenServer is running for this session. Pass working_dir so
      # the session persists a real directory (directory-scoped resume) rather
      # than relying on the global mutable :working_dir app-env.
      case SessionManager.ensure_loop(session_id,
             user_id: user_id,
             channel: :http,
             working_dir: working_dir
           ) do
        :ok ->
          # NOTE: this route used to register a per-request Bus -> PubSub bridge
          # here for [:agent_response, :system_event, :llm_response, :tool_call].
          # It was redundant and harmful: those events are already broadcast
          # directly onto "osa:session:{id}" by their producers (agent_response
          # in loop.ex, llm_response in llm_client.ex, tool_call in
          # tool_executor.ex) and Bus-only :system_event sub-events already reach
          # the TUI via the supervised, allowlisted, dedup'd
          # OptimalSystemAgent.Events.TuiForwarder. Re-registering it every POST
          # double-delivered the assistant response/token counts/tool cards on
          # the first turn, was never unregistered (leaking handlers on a `:bag`
          # table across a keep-alive connection), and monitored the ephemeral
          # request process — so it could vanish mid-turn depending on
          # connection lifecycle. The SSE stream (agent_routes.ex) still gets
          # everything via the direct broadcasts + TuiForwarder.

          # Process the message asynchronously through the agent loop.
          #
          # R2 fix: `rescue` alone does NOT catch `:exit` — and
          # `SessionManager.process_message/3` is a `GenServer.call(..., :infinity)`,
          # so if the Loop crashes inside `handle_call` (e.g. TurnPipeline.run
          # raises before it gets a chance to broadcast anything), the caller
          # here receives an `:exit` signal, not a rescuable exception. Left
          # uncaught, that killed this Task silently: no `agent_response`/`done`
          # ever reached the SSE topic, so the TUI's SSE loop just kept sending
          # `: keepalive` forever and the spinner never resolved. We now `catch`
          # both `:error`/raised exceptions (via `rescue`) and `:exit`, and in
          # every failure path broadcast a terminal SSE frame directly (mirroring
          # the normal-completion shape: an `agent_response` with the error text
          # followed by `done`) so the turn always ends client-side.
          Task.Supervisor.async_nolink(OptimalSystemAgent.Events.TaskSupervisor, fn ->
            try do
              result =
                SessionManager.process_message(session_id, input,
                  images: images,
                  image_source: image_source,
                  working_dir: working_dir
                )

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
                  emit_terminal_error(session_id, "Error: #{inspect(reason)}")

                other ->
                  Logger.info("[OrchestrateRoutes] Agent loop returned: #{inspect(other)}")
              end
            rescue
              e ->
                Logger.error("[OrchestrateRoutes] Agent loop crashed: #{Exception.message(e)}")
                emit_terminal_error(session_id, "Agent error: #{Exception.message(e)}")
            catch
              :exit, reason ->
                Logger.error("[OrchestrateRoutes] Agent loop exited: #{inspect(reason)}")

                emit_terminal_error(session_id, "Agent error: the agent loop crashed")
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

                  emit_terminal_error(session_id, "Agent error: #{Exception.message(e)}")
              catch
                :exit, reason ->
                  Logger.error("[OrchestrateRoutes] Complex task exited: #{inspect(reason)}")
                  emit_terminal_error(session_id, "Agent error: the agent loop crashed")
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
                    # Honor the validated pattern: dispatch through the swarm
                    # engine instead of running a single plain agent loop.
                    _ = OptimalSystemAgent.Swarm.Patterns.dispatch(pattern, session_id, task)

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

  # R2 fix: always emit a terminal SSE frame when the async agent task fails
  # (whether via a raised exception or an `:exit`, e.g. the Loop GenServer
  # crashing inside `handle_call`), so the SSE loop's receive in
  # agent_routes.ex gets a message instead of looping on keepalives forever.
  # Broadcasts directly onto the session's PubSub topic — the same shape a
  # normal turn ends with (`agent_response` then `done`) — so the TUI both
  # shows the error and resolves its spinner.
  defp emit_terminal_error(session_id, message) do
    # Claimed, not merely sent. This fallback exists for the crash and `:exit`
    # cases, where nothing broadcast anything and the SSE loop would otherwise
    # spin on keepalives forever. But it also fires for a plain
    # `{:error, reason}` — and TurnPipeline already broadcasts a terminal frame
    # before returning one for the turn/budget limit gate and for a
    # UserPromptSubmit hook block. Those turns were terminated twice.
    #
    # The second `done` is not harmless: the TUI gates its message-queue drain
    # on `done`, so done #1 drains the queue, the drained message opens a new
    # turn, and done #2 then lands mid-turn — the early-drain bug the gate was
    # added to fix, reproduced through a narrower door.
    if OptimalSystemAgent.Agent.TurnTermination.claim(session_id) do
      do_emit_terminal_error(session_id, message)
    else
      :ok
    end
  end

  defp do_emit_terminal_error(session_id, message) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :agent_response,
         session_id: session_id,
         response: message,
         response_type: "agent"
       }}
    )

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, %{type: :done, session_id: session_id}}
    )
  rescue
    _ -> :ok
  end

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

  # `images` is caller-supplied and each entry is either inline base64 bytes or
  # a filesystem PATH that `MessageHandler.build_messages/4` will read. The
  # security decision lives there (canonicalisation + a trust-aware
  # `PathPolicy` check + magic-byte sniffing + a per-image byte cap); what
  # belongs at the request boundary is shape: a list of non-empty strings,
  # bounded in count, so a 10_000-entry body cannot turn one request into
  # 10_000 file reads.
  #
  # The companion `image_source` field is the trust marker. It is absent on
  # every body that does not set it, which `MessageHandler.normalize_source/1`
  # maps to `:model` — so an unmarked request keeps the v1.0.79 confinement and
  # only a caller that explicitly says `"user"` (the TUI, on a real
  # drag-and-drop / paste / `@file`) gets the unconfined-location path.
  @max_images 16

  defp normalize_images(images) when is_list(images) do
    images
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.take(@max_images)
  end

  defp normalize_images(_), do: []
end

# Alias so existing tests referencing OrchestrationRoutes compile without changes.
defmodule OptimalSystemAgent.Channels.HTTP.API.OrchestrationRoutes do
  defdelegate call(conn, opts), to: OptimalSystemAgent.Channels.HTTP.API.OrchestrateRoutes
  defdelegate init(opts), to: OptimalSystemAgent.Channels.HTTP.API.OrchestrateRoutes
end
