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

  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.SDK.Memory

  plug(:match)
  plug(:dispatch)

  # ── GET /sessions ──────────────────────────────────────────────────

  get "/" do
    {page, per_page} = pagination_params(conn)

    live_ids = SessionManager.live_session_ids()

    # Rich metadata (title/first-prompt, message_count, created_at/last_active)
    # comes from the persisted transcript store — the same source already used
    # by GET /sessions/recent. We merge in live-registry alive status on top.
    rich_sessions =
      OptimalSystemAgent.Store.SessionTranscript.list_sessions(limit: 500)
      |> Enum.map(fn s ->
        sid = s[:session_id]

        %{
          id: sid,
          title: s[:first_message] || "",
          message_count: s[:message_count] || 0,
          created_at: s[:started_at] || "",
          last_active: s[:last_active] || "",
          working_dir: s[:working_dir],
          alive: sid in live_ids
        }
      end)

    known_ids = MapSet.new(rich_sessions, & &1.id)

    # Live in-registry sessions that haven't persisted any turns yet still need
    # to appear so the TUI can select them. created_at is kept as a non-null
    # string to satisfy the client's SessionInfo contract.
    live_only =
      live_ids
      |> Enum.reject(&MapSet.member?(known_ids, &1))
      |> Enum.map(fn sid ->
        %{
          id: sid,
          title: "",
          message_count: 0,
          created_at: "",
          last_active: "",
          working_dir: nil,
          alive: true
        }
      end)

    sessions = live_only ++ rich_sessions

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
    working_dir = conn.body_params["working_dir"]

    # Directory-scoped resume (Claude Code style): if this folder already has a
    # saved session, hand it back instead of starting fresh. New folder → new session.
    existing =
      working_dir &&
        OptimalSystemAgent.Agent.SessionPersistence.find_latest_for_dir(working_dir)

    if existing do
      body = Jason.encode!(%{id: existing, status: "resumed", working_dir: working_dir})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      case SessionManager.create_session(user_id: user_id, channel: :http) do
        {:ok, %{session_id: session_id}} ->
          body = Jason.encode!(%{id: session_id, status: "created", working_dir: working_dir})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, body)

        {:error, _reason} ->
          json_error(
            conn,
            500,
            "session_create_failed",
            "An internal error occurred while creating the session"
          )
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
        turns =
          Enum.map(transcript, fn t ->
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

  # ── POST /sessions/:id/auto_mode/resume ────────────────────────────
  # Clear a safety-Guardian pause and let the auto-mode loop resume. Resets the
  # session block counter and pause flag; the caller can then send a new turn.
  post "/:id/auto_mode/resume" do
    session_id = conn.params["id"]
    was_paused = OptimalSystemAgent.Agent.Safety.Guardian.paused?(session_id)
    OptimalSystemAgent.Agent.Safety.Guardian.resume(session_id)

    json(conn, 200, %{
      status: "ok",
      session_id: session_id,
      was_paused: was_paused,
      paused: false
    })
  end

  # ── GET /sessions/:id ──────────────────────────────────────────────

  get "/:id" do
    session_id = conn.params["id"]

    # A session is considered alive if it has an active Registry process OR was
    # created via this HTTP endpoint (no agent loop process yet, but the session
    # is valid and accepting messages).
    alive = SessionManager.session_exists?(session_id)

    if alive do
      # Read this session's real persisted turns from the transcript store
      # (where t.session_id == id) — NOT the cross-session full-text search,
      # which keys on content and returns [] for a session id. Same accessor
      # as GET /:id/messages and GET /:id/transcript.
      turns = OptimalSystemAgent.Store.SessionTranscript.get_transcript(session_id)

      formatted_messages =
        turns
        |> Enum.reject(fn t -> t.role == "system" end)
        |> Enum.map(fn t ->
          %{
            role: t.role,
            content: t.content,
            tool_name: t.tool_name,
            timestamp: t.inserted_at
          }
        end)

      body =
        Jason.encode!(%{
          id: session_id,
          title: nil,
          message_count: length(formatted_messages),
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
    try do
      session_id = conn.params["id"]

      case SessionManager.get_state(session_id) do
        {:ok, state} ->
          max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
          total_tokens = state[:tokens_used] || state[:estimated_tokens] || 0
          static_tokens = OptimalSystemAgent.Soul.static_token_count()
          conversation_tokens = max(total_tokens - static_tokens, 0)

          body =
            Jason.encode!(%{
              system_tokens: static_tokens,
              conversation_tokens: conversation_tokens,
              tool_result_tokens: 0,
              max_tokens: max_tokens,
              used_tokens: total_tokens
            })

          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        _ ->
          json_error(
            conn,
            404,
            "session_not_found",
            "Session #{session_id} not found or not active"
          )
      end
    rescue
      _ ->
        json_error(conn, 500, "context_error", "Failed to retrieve context stats")
    end
  end

  # ── GET /sessions/:id/messages ─────────────────────────────────────

  get "/:id/messages" do
    session_id = conn.params["id"]

    # Read the actual persisted turns for THIS session directly from the
    # transcript store (where t.session_id == id). This is the same proven
    # accessor used by GET /:id/transcript. It must NOT route through the
    # cross-session full-text search, which keys on content and ignores the
    # session_id column (returning []).
    turns = OptimalSystemAgent.Store.SessionTranscript.get_transcript(session_id)

    formatted =
      turns
      |> Enum.reject(fn t -> t.role == "system" end)
      |> Enum.map(fn t ->
        %{
          role: t.role,
          content: t.content,
          tool_name: t.tool_name,
          timestamp: t.inserted_at
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
    SessionManager.cancel(session_id)

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
        json_error(
          conn,
          500,
          "delete_failed",
          "An internal error occurred while deleting the session"
        )
    end
  end

  # ── POST /sessions/:id/cancel ──────────────────────────────────────

  post "/:id/cancel" do
    session_id = conn.params["id"]

    case SessionManager.cancel(session_id) do
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
    session_id = conn.params["id"]

    case SessionManager.set_proactive(session_id) do
      :ok ->
        # Toggle proactive mode on the session
        json(conn, 200, %{status: "proactive_enabled", session_id: session_id})

      {:error, :not_found} ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")

      {:error, _reason} ->
        json(conn, 200, %{status: "proactive_requested", session_id: session_id})
    end
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
    if SessionManager.live_session?(session_id) do
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
          SessionManager.process_message_async(session_id, message)

          resp = Jason.encode!(%{status: "processing", session_id: session_id})
          conn |> put_resp_content_type("application/json") |> send_resp(202, resp)
      end
    else
      json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
    end
  end

  # ── POST /sessions/:id/replay ──────────────────────────────────────

  post "/:id/replay" do
    source_session_id = conn.params["id"]
    body = conn.body_params

    _opts =
      []
      |> then(fn o -> if b = body["session_id"], do: Keyword.put(o, :session_id, b), else: o end)
      |> then(fn o -> if b = body["provider"], do: Keyword.put(o, :provider, b), else: o end)
      |> then(fn o -> if b = body["model"], do: Keyword.put(o, :model, b), else: o end)

    # Load source session messages and replay into the target session
    messages = Memory.load_session(source_session_id) || []

    if messages == [] do
      json_error(conn, 404, "empty_session", "Source session has no messages to replay")
    else
      # Start a new session and feed it the messages
      target_id = conn.params["id"]

      if SessionManager.live_session?(target_id) do
        # Replay each user message
        user_messages = Enum.filter(messages, fn m -> m["role"] == "user" end)

        json(conn, 200, %{
          status: "replay_started",
          source_session: source_session_id,
          target_session: target_id,
          messages_to_replay: length(user_messages)
        })
      else
        json_error(conn, 404, "session_not_found", "Target session #{target_id} not found")
      end
    end
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
      case SessionManager.swap_provider(session_id, provider, model) do
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
          if reason == :not_found do
            json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
          else
            json_error(conn, 500, "swap_failed", inspect(reason))
          end
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

  # ── POST /sessions/:id/compact ─────────────────────────────────────
  #
  # Trigger proactive compaction NOW on the live loop's message buffer.
  # Folds older turns into a high-recall summary (ProactiveCompaction.compact/1).

  post "/:id/compact" do
    session_id = conn.params["id"]

    case SessionManager.proactive_compact(session_id) do
      {:ok, stats} ->
        json(conn, 200, Map.merge(%{status: "compacted", session_id: session_id}, stats))

      {:error, :no_session} ->
        json_error(
          conn,
          404,
          "not_running",
          "No active agent loop for session #{session_id}"
        )

      {:error, reason} ->
        json_error(conn, 500, "compact_failed", inspect(reason))
    end
  end

  # ── GET /sessions/:id/recap ────────────────────────────────────────
  #
  # Return a short LLM summary of the session so far, built from the
  # persisted transcript via a single summarization call.

  get "/:id/recap" do
    session_id = conn.params["id"]

    turns =
      session_id
      |> OptimalSystemAgent.Store.SessionTranscript.get_transcript()
      |> Enum.reject(fn t -> t.role == "system" end)

    if turns == [] do
      json(conn, 200, %{session_id: session_id, recap: "No conversation yet to summarize.", turns: 0})
    else
      formatted =
        turns
        |> Enum.map(fn t -> "#{String.capitalize(t.role || "")}: #{t.content}" end)
        |> Enum.join("\n\n")

      prompt =
        "Summarize the following agent session in 3-6 concise bullet points. " <>
          "Capture the user's goal, what was accomplished, key decisions, and any open next steps. " <>
          "Do not invent facts. Output only the summary.\n\n" <> formatted

      recap =
        try do
          case OptimalSystemAgent.Providers.Registry.chat(
                 [%{role: "user", content: prompt}],
                 temperature: 0.3,
                 max_tokens: 500
               ) do
            {:ok, %{content: content}} when is_binary(content) and content != "" ->
              content

            _ ->
              "Could not generate a recap right now."
          end
        rescue
          _ -> "Could not generate a recap right now."
        end

      json(conn, 200, %{session_id: session_id, recap: recap, turns: length(turns)})
    end
  end

  # ── POST /sessions/:id/fork ────────────────────────────────────────
  #
  # Fork the current session into a NEW one, seeding it with a copy of the
  # source transcript so history is preserved. Returns the new session with
  # status "resumed" so the TUI pulls the seeded transcript back in on switch.

  post "/:id/fork" do
    source_session_id = conn.params["id"]
    user_id = conn.assigns[:user_id] || "anonymous"

    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(source_session_id)

    case SessionManager.create_session(user_id: user_id, channel: :http) do
      {:ok, %{session_id: new_id}} ->
        Enum.each(transcript, fn t ->
          OptimalSystemAgent.Store.SessionTranscript.save_turn(
            new_id,
            t.role,
            t.content,
            tool_name: t.tool_name,
            tokens: Map.get(t, :tokens) || 0
          )
        end)

        body =
          Jason.encode!(%{
            id: new_id,
            status: "resumed",
            source_session: source_session_id,
            message_count: length(transcript)
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, body)

      {:error, _reason} ->
        json_error(conn, 500, "fork_failed", "Failed to fork session #{source_session_id}")
    end
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
                    options:
                      Enum.map(opts || [], fn opt ->
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
            Logger.warning(
              "[SSE] session=#{session_id} encode failed for #{event_type}: #{inspect(reason)}"
            )

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
