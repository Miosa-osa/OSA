defmodule OptimalSystemAgent.Channels.HTTP.API.SessionRoutes do
  @moduledoc """
  Session management routes.

    GET    /sessions
    POST   /sessions
    GET    /sessions/:id
    GET    /sessions/:id/messages
    GET    /sessions/:id/stream   — SSE event stream for the session
    POST   /sessions/:id/message
    POST   /sessions/:id/cancel
    POST   /sessions/:id/survey/answer
    POST   /sessions/:id/survey/skip
    DELETE /sessions/:id
  """
  use Plug.Router
  import Plug.Conn
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.SDK.Memory
  alias OptimalSystemAgent.Agent.Loop

  plug :match
  plug :dispatch

  # ── ETS session tracking ────────────────────────────────────────────
  # HTTP-created sessions are not backed by a Registry process, so we maintain
  # a lightweight ETS table to track them within the process lifetime.

  @http_sessions_table :osa_http_sessions

  defp ensure_session_table do
    case :ets.whereis(@http_sessions_table) do
      :undefined ->
        :ets.new(@http_sessions_table, [:named_table, :set, :public])
      _ -> :ok
    end
  end

  defp track_session(session_id) do
    ensure_session_table()
    :ets.insert(@http_sessions_table, {session_id, %{created_at: DateTime.utc_now() |> DateTime.to_iso8601()}})
  end

  defp http_session_exists?(session_id) do
    ensure_session_table()
    :ets.member(@http_sessions_table, session_id)
  end

  defp list_http_sessions do
    ensure_session_table()
    :ets.tab2list(@http_sessions_table) |> Enum.map(fn {id, _meta} -> id end)
  end

  # ── GET /sessions ──────────────────────────────────────────────────

  get "/" do
    {page, per_page} = pagination_params(conn)

    live_ids =
      try do
        Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      rescue
        _ -> []
      end

    http_ids = list_http_sessions()

    all_ids = Enum.uniq(live_ids ++ http_ids)

    sessions =
      Enum.map(all_ids, fn sid ->
        alive = sid in live_ids

        %{
          id: sid,
          title: nil,
          message_count: 0,
          created_at: nil,
          last_active: nil,
          alive: alive
        }
      end)

    total = length(sessions)

    paginated =
      sessions
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    body = Jason.encode!(%{sessions: paginated, count: total, page: page, per_page: per_page})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /sessions ─────────────────────────────────────────────────

  post "/" do
    user_id = conn.assigns[:user_id] || "anonymous"

    case OptimalSystemAgent.SDK.Session.create(user_id: user_id, channel: :http) do
      {:ok, %{session_id: session_id}} ->
        track_session(session_id)
        body = Jason.encode!(%{id: session_id, status: "created"})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, body)

      {:error, _reason} ->
        json_error(conn, 500, "session_create_failed", "An internal error occurred while creating the session")
    end
  end

  # ── GET /sessions/:id ──────────────────────────────────────────────

  get "/:id" do
    session_id = conn.params["id"]

    in_registry =
      try do
        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{_pid, _}] -> true
          [] -> false
        end
      rescue
        _ -> false
      end

    in_http_store = http_session_exists?(session_id)
    # A session is considered alive if it has an active Registry process OR was
    # created via this HTTP endpoint (no agent loop process yet, but the session
    # is valid and accepting messages).
    alive = in_registry || in_http_store

    if alive do
      messages = Memory.load_session(session_id) || []

      formatted_messages =
        messages
        |> Enum.reject(fn m -> m["role"] == "system" end)
        |> Enum.map(fn m ->
          %{
            role: m["role"],
            content: m["content"],
            timestamp: m["timestamp"]
          }
        end)

      body =
        Jason.encode!(%{
          id: session_id,
          title: nil,
          message_count: length(messages),
          created_at: nil,
          last_active: nil,
          alive: alive,
          messages: formatted_messages
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
    end
  end

  # ── GET /sessions/:id/context ──────────────────────────────────────

  get "/:id/context" do
    session_id = conn.params["id"]

    case Loop.get_state(session_id) do
      {:ok, state} ->
        max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
        total_tokens = state[:tokens_used] || state[:estimated_tokens] || 0
        static_tokens = OptimalSystemAgent.Soul.static_token_count()
        conversation_tokens = max(total_tokens - static_tokens, 0)

        body = Jason.encode!(%{
          system_tokens: static_tokens,
          conversation_tokens: conversation_tokens,
          tool_result_tokens: 0,
          max_tokens: max_tokens,
          used_tokens: total_tokens
        })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)

      _ ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found or not active")
    end
  rescue
    _ ->
      json_error(conn, 500, "context_error", "Failed to retrieve context stats")
  end

  # ── GET /sessions/:id/messages ─────────────────────────────────────

  get "/:id/messages" do
    session_id = conn.params["id"]
    messages = Memory.load_session(session_id) || []

    formatted =
      messages
      |> Enum.reject(fn m -> m["role"] == "system" end)
      |> Enum.map(fn m ->
        %{
          role: m["role"],
          content: m["content"],
          timestamp: m["timestamp"]
        }
      end)

    body = Jason.encode!(%{messages: formatted, count: length(formatted)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /sessions/:id/stream — SSE event stream ────────────────────
  #
  # Convenience alias for GET /stream/:id handled by AgentRoutes.
  # Subscribes to the session-scoped PubSub topic "osa:session:{id}" and
  # streams {:osa_event, event} messages as SSE frames until the client
  # disconnects. A `: keepalive` comment is sent every 30 s to prevent
  # proxy timeouts.
  #
  # Event frame format:
  #   event: <event_type>\n
  #   data: <json>\n\n
  #
  # system_event sub-events are unwrapped so that the TUI SSE parser
  # receives the sub-event name as the SSE event type, matching the
  # behaviour in AgentRoutes.sse_loop/2.

  get "/:id/stream" do
    session_id = conn.params["id"]
    user_id = conn.assigns[:user_id] || "anonymous"

    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} =
      chunk(conn, "event: connected\ndata: {\"session_id\": \"#{session_id}\"}\n\n")

    Logger.debug("[SSE] /sessions/#{session_id}/stream opened by #{user_id}")

    session_sse_loop(conn, session_id)
  end

  # ── DELETE /sessions/:id ───────────────────────────────────────────

  delete "/:id" do
    session_id = conn.params["id"]

    # Cancel active loop if running (ignore if already stopped)
    Loop.cancel(session_id)

    # Remove the session JSONL file from disk
    sessions_dir =
      Application.get_env(:optimal_system_agent, :sessions_dir, "~/.osa/sessions")
      |> Path.expand()

    session_file = Path.join(sessions_dir, "#{session_id}.jsonl")

    case File.rm(session_file) do
      :ok ->
        body = Jason.encode!(%{status: "deleted", session_id: session_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :enoent} ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")

      {:error, _reason} ->
        json_error(conn, 500, "delete_failed", "An internal error occurred while deleting the session")
    end
  end

  # ── POST /sessions/:id/cancel ──────────────────────────────────────

  post "/:id/cancel" do
    session_id = conn.params["id"]

    case Loop.cancel(session_id) do
      :ok ->
        body = Jason.encode!(%{status: "cancel_requested", session_id: session_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_running} ->
        json_error(conn, 404, "not_running", "No active agent loop for session #{session_id}")
    end
  end

  # ── POST /sessions/:id/survey/answer ──────────────────────────────

  post "/:id/survey/answer" do
    session_id = conn.params["id"]
    body = conn.body_params

    survey_id = body["survey_id"]
    answers = body["answers"]

    unless survey_id && answers do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing survey_id or answers"}))
      |> halt()
    end

    key = {session_id, survey_id}
    :ets.insert(:osa_survey_answers, {key, answers})

    # Bridge to ask_user tool: if this survey_id matches a pending ask_user question,
    # send the answer to the waiting process so it can continue.
    try do
      case :ets.lookup(:osa_pending_questions, survey_id) do
        [{^survey_id, %{session_id: _sid} = _pending}] ->
          # Build the answer text from the survey answers
          answer_text =
            Enum.map(answers, fn a ->
              case a do
                %{"free_text" => ft} when is_binary(ft) and ft != "" -> ft
                %{"selected" => selected} when is_list(selected) -> Enum.join(selected, ", ")
                _ -> ""
              end
            end)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("; ")

          # Parse the ref back from the string representation
          # The ask_user tool stores its ref as inspect(make_ref()), we use it as the survey_id
          # Send to ALL processes waiting on ask_user (broadcast approach)
          Phoenix.PubSub.broadcast(
            OptimalSystemAgent.PubSub,
            "osa:ask_user:#{survey_id}",
            {:ask_user_answer, survey_id, answer_text}
          )

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end

    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :survey_answered,
      session_id: session_id,
      data: %{
        survey_id: survey_id,
        summary:
          Enum.map(answers, fn a ->
            answer_text =
              case a do
                %{"free_text" => ft} when is_binary(ft) and ft != "" -> ft
                %{"selected" => selected} -> Enum.join(selected, ", ")
                _ -> ""
              end

            {a["question_text"] || "", answer_text}
          end)
      }
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  # ── POST /sessions/:id/survey/skip ───────────────────────────────

  post "/:id/survey/skip" do
    session_id = conn.params["id"]
    body = conn.body_params

    survey_id = body["survey_id"]

    unless survey_id do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing survey_id"}))
      |> halt()
    end

    key = {session_id, survey_id}
    :ets.insert(:osa_survey_answers, {key, :skipped})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "skipped"}))
  end

  # ── POST /sessions/:id/proactive ───────────────────────────────

  post "/:id/proactive" do
    json_error(conn, 501, "not_implemented", "Proactive mode not available in this build")
  end

  get "/:id/activity" do
    body = Jason.encode!(%{activity: [], count: 0})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # ── POST /sessions/:id/message ─────────────────────────────────

  post "/:id/message" do
    session_id = conn.params["id"]
    body = conn.body_params

    message = body["message"]

    unless is_binary(message) && message != "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing or empty message"}))
      |> halt()
    end

    # Check session exists before dispatching async
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        # Pre-filter noise before dispatching to the agent loop.
        # Mirrors the same check done in orchestration_routes.ex.
        case OptimalSystemAgent.Channels.NoiseFilter.check(message, nil) do
          {:filtered, _ack} ->
            resp = Jason.encode!(%{status: "filtered", session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

          {:clarify, prompt} ->
            resp = Jason.encode!(%{status: "clarify", prompt: prompt, session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

          :pass ->
            # Fire-and-forget — the loop processes in background.
            # Client polls GET /sessions/:id/messages for results.
            # Uses Task.Supervisor to ensure the task survives long LLM calls
            # (Task.start would create an unsupervised process that may be reaped).
            Task.Supervisor.start_child(
              OptimalSystemAgent.TaskSupervisor,
              fn -> Loop.process_message(session_id, message) end,
              restart: :temporary
            )

            resp = Jason.encode!(%{status: "processing", session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(202, resp)
        end

      [] ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
    end
  end

  # ── POST /sessions/:id/replay ──────────────────────────────────────

  post "/:id/replay" do
    source_session_id = conn.params["id"]
    body = conn.body_params

    opts =
      []
      |> then(fn o -> if b = body["session_id"], do: Keyword.put(o, :session_id, b), else: o end)
      |> then(fn o -> if b = body["provider"], do: Keyword.put(o, :provider, b), else: o end)
      |> then(fn o -> if b = body["model"], do: Keyword.put(o, :model, b), else: o end)

    _ = {source_session_id, opts}
    json_error(conn, 501, "not_implemented", "Session replay not yet available")
  end

  # ── POST /sessions/:id/provider ── hot-swap LLM provider ──────────

  post "/:id/provider" do
    session_id = conn.params["id"]
    body = conn.body_params

    provider = body["provider"]
    model = body["model"]

    if not (is_binary(provider) and provider != "") do
      conn
      |> send_resp(400, Jason.encode!(%{error: "provider is required"}))
      |> halt()
    else
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
        [{pid, _}] ->
          case GenServer.call(pid, {:swap_provider, provider, model}) do
            :ok ->
              resp =
                Jason.encode!(%{
                  status: "ok",
                  session_id: session_id,
                  provider: provider,
                  model: model
                })

              conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

            {:error, reason} ->
              json_error(conn, 500, "swap_failed", inspect(reason))
          end

        [] ->
          json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
      end
    end
  end

  # ── GET /:id/pending_questions ─────────────────────────────────────────

  get "/:id/pending_questions" do
    session_id = conn.params["id"]

    questions =
      try do
        :ets.tab2list(:osa_pending_questions)
        |> Enum.filter(fn {_ref, meta} -> meta.session_id == session_id end)
        |> Enum.map(fn {ref, meta} ->
          %{
            ref: ref,
            question: meta.question,
            options: meta.options,
            asked_at: meta.asked_at
          }
        end)
      rescue
        _ -> []
      end

    body = Jason.encode!(%{pending_questions: questions, count: length(questions)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Session endpoint not found")
  end

  # ── SSE loop for session stream ──────────────────────────────────────
  #
  # Mirrors the loop in AgentRoutes so both entry points behave identically.
  # Receives {:osa_event, event} messages from Phoenix.PubSub and writes
  # each as an SSE frame. Sends a keepalive comment after 30 s of silence.
  # Exits when the client disconnects (chunk/2 returns {:error, _}).

  defp session_sse_loop(conn, session_id) do
    receive do
      {:osa_event, event} ->
        # Transform ask_user events to the format the TUI survey dialog expects
        {event_type, event_data} =
          case event do
            %{type: :system_event, event: :ask_user, question: q, options: opts, ref: ref} ->
              survey_data = %{
                survey_id: ref,
                questions: [
                  %{
                    text: q,
                    multi_select: false,
                    options: Enum.map(opts || [], fn opt ->
                      %{label: to_string(opt), description: nil}
                    end),
                    skippable: true
                  }
                ],
                skippable: true
              }
              {"ask_user_question", survey_data}

            %{type: :system_event, event: sub} ->
              {to_string(sub), event}

            %{type: t} ->
              {to_string(t), event}

            _ ->
              {"unknown", event}
          end

        case Jason.encode(event_data) do
          {:ok, data} ->
            Logger.debug("[SSE] session=#{session_id} sending #{event_type}")

            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                session_sse_loop(conn, session_id)

              {:error, _reason} ->
                Logger.debug("[SSE] client disconnected: session=#{session_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning("[SSE] session=#{session_id} encode failed for #{event_type}: #{inspect(reason)}")
            session_sse_loop(conn, session_id)
        end

    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> session_sse_loop(conn, session_id)
          {:error, _} -> conn
        end
    end
  end

  # ── Cross-Session Search Routes ─────────────────────────────────────

  get "/search" do
    query = conn.params["q"] || ""
    limit = parse_int(conn.params["limit"], 20)

    if query == "" do
      json(conn, 400, %{error: "Missing required query parameter: q"})
    else
      results = OptimalSystemAgent.Store.SessionTranscript.search(query, limit: limit)
      json(conn, 200, %{results: results, query: query, count: length(results)})
    end
  end

  get "/recent" do
    limit = parse_int(conn.params["limit"], 50)
    sessions = OptimalSystemAgent.Store.SessionTranscript.list_sessions(limit: limit)
    json(conn, 200, %{sessions: sessions})
  end

  get "/:id/export" do
    format = conn.params["format"] || "md"
    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(id)

    case format do
      "json" ->
        turns = Enum.map(transcript, fn t ->
          %{role: t.role, content: t.content, tool_name: t.tool_name, timestamp: t.inserted_at}
        end)
        json(conn, 200, %{session_id: id, format: "json", turns: turns})

      _ ->
        # Markdown export
        md_lines =
          Enum.map(transcript, fn t ->
            role_label = String.capitalize(t.role)
            timestamp = t.inserted_at || ""
            "### #{role_label} (#{timestamp})\n\n#{t.content}\n"
          end)

        markdown = "# Session Export: #{id}\n\n" <> Enum.join(md_lines, "\n---\n\n")

        conn
        |> put_resp_content_type("text/markdown")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{id}.md\"")
        |> send_resp(200, markdown)
    end
  end

  get "/:id/transcript" do
    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(id)
    json(conn, 200, %{session_id: id, turns: transcript, count: length(transcript)})
  end

  # ── Permission Decision Route ─────────────────────────────────────

  post "/:id/permission/:perm_id" do
    decision = conn.body_params["decision"] || "deny"

    atom_decision =
      case decision do
        "allow_once" -> :allow_once
        "allow_always" -> :allow_always
        "deny" -> :deny
        _ -> :deny
      end

    # Broadcast decision to the waiting tool executor
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:permission:#{perm_id}",
      {:permission_decision, atom_decision}
    )

    # If allow_always, persist the rule
    if atom_decision == :allow_always do
      tool_name = conn.body_params["tool_name"]
      if tool_name, do: OptimalSystemAgent.Permissions.save_rule(tool_name, :allow_always)
    end

    json(conn, 200, %{status: "ok", decision: decision})
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default
end
